//! Derived, bounded sidebar metadata. Reads never reopen transcript documents.
//! Older writers invalidate this additive cache through lightweight triggers;
//! current writes refresh it within the existing thread transaction.
use super::*;

pub(super) fn create(db: &Connection) -> Result<()> {
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS thread_navigation(
        id TEXT PRIMARY KEY COLLATE NOCASE,
        metadata TEXT CHECK(metadata IS NULL OR json_valid(metadata))
    );",
    )?;
    Ok(())
}

pub(super) fn install(db: &mut Connection) -> Result<()> {
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    create(&tx)?;
    tx.execute_batch("CREATE TRIGGER IF NOT EXISTS thread_navigation_insert_v1 AFTER INSERT ON threads BEGIN
        DELETE FROM thread_navigation WHERE id=NEW.id; END;
        CREATE TRIGGER IF NOT EXISTS thread_navigation_update_v1 AFTER UPDATE OF id,document ON threads BEGIN
        DELETE FROM thread_navigation WHERE id=OLD.id OR id=NEW.id; END;
        CREATE TRIGGER IF NOT EXISTS thread_navigation_delete_v1 AFTER DELETE ON threads BEGIN
        DELETE FROM thread_navigation WHERE id=OLD.id; END;")?;
    {
        // A warm launch checks scalar IDs only. Decode a document only when an
        // older writer invalidated its derived metadata or this cache is new.
        let mut rows = tx.prepare(
            "SELECT id,document FROM threads WHERE NOT EXISTS(
            SELECT 1 FROM thread_navigation WHERE thread_navigation.id=threads.id COLLATE NOCASE)",
        )?;
        let records = rows.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for record in records {
            let (id, document) = record?;
            let thread: Value = serde_json::from_str(&document)?;
            ensure!(
                validate_thread(&thread)? == id,
                "Navigation source identity changed"
            );
            write(&tx, &thread)?;
        }
    }
    tx.commit()?;
    Ok(())
}

fn metadata(thread: &Value) -> Option<ThreadNavigation> {
    let bot_id = thread["botID"]
        .as_str()
        .filter(|id| Uuid::parse_str(id).is_ok())
        .map(str::to_owned);
    let preview = bot_id.as_ref().and_then(|_| {
        thread["items"].as_array()?.iter().rev().find_map(|item| {
            if !matches!(item["kind"].as_str(), Some("user" | "assistant")) {
                return None;
            }
            let text = item["text"].as_str()?.chars().take(560).collect::<String>();
            let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
            if line.is_empty() {
                return None;
            }
            Some(if line.chars().count() > 140 {
                line.chars().take(139).collect::<String>() + "…"
            } else {
                line
            })
        })
    });
    let value = ThreadNavigation {
        bot_id,
        branch: thread["branch"]
            .as_str()
            .filter(|branch| !branch.is_empty())
            .map(|branch| branch.chars().take(1024).collect()),
        created_at: snooze_timestamp(&thread["createdAt"]),
        updated_at: snooze_timestamp(&thread["updatedAt"]),
        preview,
        item_count: thread["items"].as_array().map(Vec::len),
        has_draft: Some(
            thread["draft"]
                .as_str()
                .is_some_and(|text| !text.is_empty())
                || ["draftContext", "rustDraftImages"].iter().any(|key| {
                    thread[*key]
                        .as_array()
                        .is_some_and(|items| !items.is_empty())
                }),
        ),
    };
    (value.bot_id.is_some()
        || value.branch.is_some()
        || value.created_at.is_some()
        || value.updated_at.is_some())
    .then_some(value)
}

pub(super) fn write(db: &Connection, thread: &Value) -> Result<()> {
    let id = validate_thread(thread)?;
    let metadata = metadata(thread)
        .as_ref()
        .map(serde_json::to_string)
        .transpose()?;
    db.execute(
        "INSERT INTO thread_navigation(id,metadata) VALUES (?1,?2)
        ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata",
        params![id, metadata],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_writer_invalidates_metadata_and_reopen_backfills_before_cache_only_reads() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("cache.sqlite");
        let mut store = Store::open(&path).unwrap();
        let mut thread = store.new_thread("").unwrap();
        let id = text(&thread, "id");
        thread["botID"] = json!(Uuid::new_v4());
        thread["items"] = json!([{"kind":"assistant","text":"Original preview"}]);
        store.save(&thread).unwrap();
        assert_eq!(
            store.summaries("", false).unwrap()[0]
                .navigation
                .as_ref()
                .unwrap()
                .preview
                .as_deref(),
            Some("Original preview")
        );
        let before = store.thread(&id).unwrap();
        thread["items"] = json!([{"kind":"assistant","text":"Changed by an older writer"}]);
        thread["draft"] = json!("Keep exact draft");
        let old = Connection::open(&path).unwrap();
        old.execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            params![id, thread.to_string()],
        )
        .unwrap();
        assert!(store.summaries("", false).unwrap()[0].navigation.is_none());
        drop(old);
        store.close_for_shutdown().unwrap();
        let reopened = Store::open(&path).unwrap();
        assert_eq!(reopened.thread(&id).unwrap(), thread);
        assert_ne!(before, thread);
        let summary = reopened.summaries("", false).unwrap().remove(0);
        let navigation = summary.navigation.unwrap();
        assert_eq!(
            navigation.preview.as_deref(),
            Some("Changed by an older writer")
        );
        assert_eq!(navigation.has_draft, Some(true));
        // Actual summaries cannot depend on the transcript table, even for the
        // new bot/date/draft metadata. Keep the existing cache-only contract.
        reopened
            .connection()
            .unwrap()
            .execute_batch("DROP TABLE threads;")
            .unwrap();
        assert_eq!(
            reopened.summaries("", false).unwrap()[0]
                .navigation
                .as_ref()
                .unwrap()
                .preview,
            navigation.preview
        );
    }
}
