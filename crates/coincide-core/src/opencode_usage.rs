//! Read completed OpenCode v2 message usage without reading message content.
//!
//! The local database is supplemental: Coincide's saved turns remain the
//! authority for days where both sources could describe the same requests.
use crate::{
    cli_usage_logs::{LoggedEvent, Scan, SessionOwners, open_usage_database},
    usage_report::{Event, TokenTotals},
};
use anyhow::{Context, Result, ensure};
use chrono::{TimeZone, Utc};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::{path::Path, time::Duration};

const MAX_MESSAGES: usize = 500_000;

fn valid_name(value: Option<String>) -> Option<String> {
    value.filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
}

fn tokens(value: &str) -> Option<TokenTotals> {
    if value.len() > 16_384 {
        return None;
    }
    let value: Value = serde_json::from_str(value).ok()?;
    let count = |value: &Value| value.as_u64();
    let input = count(&value["input"])?;
    let output = count(&value["output"])?;
    let reasoning = count(&value["reasoning"])?;
    let cache_read = count(&value["cache"]["read"])?;
    let cache_write = count(&value["cache"]["write"])?;
    // OpenCode's schema counts reasoning separately from output. Our report
    // represents reasoning as a subset of output, so add it exactly once.
    let totals = TokenTotals::new(
        input,
        cache_read,
        cache_write,
        0,
        output.checked_add(reasoning)?,
        reasoning,
    );
    (!totals.is_empty()).then_some(totals)
}

fn verify_open_database(
    db: &Connection,
    path: &Path,
    identity: crate::native_file::Identity,
) -> Result<()> {
    ensure!(
        crate::native_file::path_identity(path)? == identity,
        "OpenCode usage store changed"
    );
    let mut moved: std::ffi::c_int = 0;
    // SAFETY: the connection is live and `moved` points to writable memory.
    let code = unsafe {
        rusqlite::ffi::sqlite3_file_control(
            db.handle(),
            c"main".as_ptr(),
            rusqlite::ffi::SQLITE_FCNTL_HAS_MOVED,
            (&mut moved as *mut std::ffi::c_int).cast(),
        )
    };
    let verified = code == rusqlite::ffi::SQLITE_OK && moved == 0;
    #[cfg(windows)]
    let verified = verified || code == rusqlite::ffi::SQLITE_NOTFOUND;
    ensure!(verified, "OpenCode usage store moved");
    Ok(())
}

/// Only extracts token, model, time and session metadata from a read-only
/// database. Message bodies and credentials are never returned or stored.
pub fn scan(path: &Path, owners: &SessionOwners, cancelled: &dyn Fn() -> bool) -> Result<Scan> {
    let held = open_usage_database(path)?;
    let identity = crate::native_file::file_identity(&held)?;
    let physical = path.canonicalize()?;
    ensure!(
        crate::native_file::path_identity(path)? == identity
            && crate::native_file::path_identity(&physical)? == identity,
        "OpenCode usage store changed"
    );
    let db = Connection::open_with_flags(
        &physical,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    ensure!(
        db.path().map(Path::new) == Some(physical.as_path())
            && crate::native_file::path_identity(path)? == identity,
        "OpenCode usage store changed"
    );
    verify_open_database(&db, &physical, identity)?;
    db.busy_timeout(Duration::from_secs(2))?;
    db.execute_batch("PRAGMA query_only=ON; BEGIN")?;
    let invalid: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM session_message WHERE type='assistant' AND NOT json_valid(data))",
        [],
        |row| row.get(0),
    )?;
    ensure!(!invalid, "OpenCode usage contains an invalid message");
    let mut statement = db.prepare(
        "SELECT m.session_id, json_extract(m.data,'$.time.completed'), \
         json_extract(m.data,'$.tokens'), json_extract(m.data,'$.model.id'), \
         s.fork_session_id FROM session_message m JOIN session_v2 s ON s.id=m.session_id \
         WHERE m.type='assistant' AND json_type(m.data,'$.tokens')='object' \
         AND json_extract(m.data,'$.time.completed') IS NOT NULL \
         ORDER BY m.time_created,m.id LIMIT ?1",
    )?;
    let mut rows = statement.query([(MAX_MESSAGES + 1) as i64])?;
    let mut result = Scan::default();
    result.supplemental_providers.push("opencode");
    let mut seen = 0;
    let mut incomplete = std::collections::BTreeSet::new();
    while let Some(row) = rows.next()? {
        if cancelled() {
            anyhow::bail!("OpenCode usage scan cancelled");
        }
        seen += 1;
        ensure!(seen <= MAX_MESSAGES, "Too many OpenCode usage messages");
        let session = valid_name(row.get(0)?)
            .context("OpenCode session is invalid")?
            .to_lowercase();
        let opencode = owners.get(&("opencode".into(), session.clone()));
        let lithos = owners.get(&("lithos".into(), session));
        let (provider, owner) = match (opencode, lithos) {
            (Some(Some(owner)), None) => ("opencode", Some(owner)),
            (None, Some(Some(owner))) => ("lithos", Some(owner)),
            _ => ("opencode", None),
        };
        if provider == "lithos" && !result.supplemental_providers.contains(&"lithos") {
            result.supplemental_providers.push("lithos");
        }
        if row.get::<_, Option<String>>(4)?.is_some() {
            // Forks can contain copied parent messages. Until their source
            // identities are provable, leave them out rather than duplicate.
            incomplete.insert(provider);
            continue;
        }
        let timestamp: i64 = row.get(1)?;
        let Some(date) = Utc.timestamp_millis_opt(timestamp).single() else {
            incomplete.insert(provider);
            continue;
        };
        let raw: String = row.get(2)?;
        let Some(tokens) = tokens(&raw) else {
            // An all-zero message need not create an event; malformed values
            // still make the source partial rather than inventing usage.
            let empty = serde_json::from_str::<Value>(&raw).ok().is_some_and(|v| {
                ["input", "output", "reasoning"]
                    .iter()
                    .all(|key| v[*key] == 0)
                    && v["cache"]["read"] == 0
                    && v["cache"]["write"] == 0
            });
            if !empty {
                incomplete.insert(provider);
            }
            continue;
        };
        result.events.push(LoggedEvent {
            event: Event {
                date,
                provider: provider.into(),
                account_id: owner
                    .map_or_else(|| "unknown".into(), |owner| owner.account_id.clone()),
                model: valid_name(row.get(3)?),
                prompt_tokens: tokens
                    .input
                    .saturating_add(tokens.cache_read)
                    .saturating_add(tokens.cache_write),
                tokens,
                project_id: owner.and_then(|owner| owner.project_id.clone()),
            },
            is_from_coincide: owner.is_some(),
        });
    }
    drop(rows);
    drop(statement);
    ensure!(
        crate::native_file::path_identity(path)? == identity,
        "OpenCode usage store changed"
    );
    verify_open_database(&db, &physical, identity)?;
    result.incomplete_providers.extend(incomplete);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli_usage_logs::SessionOwner;
    use serde_json::json;

    #[test]
    fn reads_completed_usage_and_excludes_fork_copies_without_message_content() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("opencode.db");
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE session_v2(id TEXT PRIMARY KEY, fork_session_id TEXT); CREATE TABLE session_message(id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT); INSERT INTO session_v2 VALUES('own',NULL),('external',NULL),('fork','own');").unwrap();
        let message = |id: &str| {
            json!({"time":{"completed":1763337600000_i64},"model":{"id":"model-fixture"},"tokens":{"input":100,"output":10,"reasoning":3,"cache":{"read":50,"write":5}},"content":"private-not-retained","id":id}).to_string()
        };
        for (id, session) in [("a", "own"), ("b", "external"), ("c", "fork")] {
            db.execute(
                "INSERT INTO session_message VALUES(?1,?2,'assistant',1763337600000,?3)",
                (id, session, message(id)),
            )
            .unwrap();
        }
        drop(db);
        let mut owners = SessionOwners::from([(
            ("lithos".into(), "own".into()),
            Some(SessionOwner {
                project_id: Some("project".into()),
                account_id: "account".into(),
            }),
        )]);
        let scan = scan(&path, &owners, &|| false).unwrap();
        assert_eq!(scan.events.len(), 2);
        assert_eq!(scan.supplemental_providers, vec!["opencode", "lithos"]);
        assert_eq!(scan.incomplete_providers, vec!["opencode"]);
        let own = scan.events.iter().find(|row| row.is_from_coincide).unwrap();
        assert_eq!(own.event.provider, "lithos");
        assert_eq!(own.event.account_id, "account");
        assert_eq!(own.event.tokens, TokenTotals::new(100, 50, 5, 0, 13, 3));
        assert_eq!(own.event.tokens.total(), 168);
        assert!(!format!("{scan:?}").contains("private-not-retained"));
        assert!(super::scan(&path, &owners, &|| true).is_err());
        owners.insert(
            ("lithos".into(), "fork".into()),
            Some(SessionOwner {
                project_id: None,
                account_id: "account".into(),
            }),
        );
        let scan = super::scan(&path, &owners, &|| false).unwrap();
        assert_eq!(scan.incomplete_providers, vec!["lithos"]);
    }
}
