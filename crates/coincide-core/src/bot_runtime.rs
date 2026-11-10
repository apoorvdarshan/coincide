//! Creates isolated bot conversations. No launch, Send, globals, or source writes.
//! Parent registers `bots.conversations.create` -> create(&mut store, params).
use crate::{
    organization::{DOCUMENT_LIMIT, RECORD_LIMIT},
    store::{Store, swift_timestamp},
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub const BOTS_PROJECT_ID: &str = "B0B5B0B5-C01C-4D1E-B075-000000000001";
pub const INSTRUCTIONS_LIMIT: usize = 25_000;
/// Key for a Rust-owned immutable authorization record, never an imported file.
pub fn context_document_name(context: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(context)?;
    ensure!(
        context.is_object() && bytes.len() <= 512 * 1024,
        "Invalid bot context record"
    );
    Ok(format!(
        "rust-bot-context-{}.json",
        crate::digest_hex::lower_hex(Sha256::digest(bytes))
    ))
}

fn required<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key]
        .as_str()
        .with_context(|| format!("Missing {key}"))
}
fn snapshot(store: &Store) -> Result<(Option<Value>, Value, String)> {
    let source = if let Some(local) = store.local_document("bots.json")? {
        Some(local)
    } else if let Some(bytes) = store.original("bots.json")? {
        ensure!(
            bytes.len() <= DOCUMENT_LIMIT,
            "Bots document exceeds size limit"
        );
        Some(serde_json::from_slice(&bytes)?)
    } else {
        None
    };
    let document = source
        .clone()
        .unwrap_or(json!({"addedStarters":false,"bots":[],"starterLineup":1}));
    let bots = document["bots"]
        .as_array()
        .context("Invalid bots envelope")?;
    ensure!(bots.len() <= RECORD_LIMIT, "Too many bots");
    let mut ids = HashSet::new();
    for bot in bots {
        ensure!(
            bot.is_object() && ids.insert(Uuid::parse_str(required(bot, "id")?)?),
            "Invalid/duplicate bot identity"
        );
    }
    let bytes = serde_json::to_vec(&document)?;
    ensure!(
        bytes.len() <= DOCUMENT_LIMIT,
        "Bots document exceeds size limit"
    );
    let baseline = crate::digest_hex::lower_hex(Sha256::digest(bytes));
    Ok((source, document, baseline))
}
fn selection(bot: &Value) -> Result<Value> {
    let selection = &bot["selection"];
    let fields = selection
        .as_object()
        .context("Bot has no saved provider selection")?;
    ensure!(
        fields.keys().all(|key| matches!(
            key.as_str(),
            "provider" | "modelID" | "accountID" | "effort" | "speed"
        )),
        "Bot selection contains unsupported options"
    );
    ensure!(
        matches!(required(selection, "provider")?, "codex" | "claude"),
        "Bot runtime supports Codex/Claude only"
    );
    let model = required(selection, "modelID")?;
    ensure!(
        !model.is_empty()
            && model.len() <= 256
            && model.trim() == model
            && !model.starts_with('-')
            && !model.chars().any(char::is_control),
        "Invalid saved bot model"
    );
    ensure!(
        selection["accountID"].is_null()
            || matches!(selection["accountID"].as_str(), Some("" | "default")),
        "Alternate bot accounts are unsupported; selection was not changed"
    );
    ensure!(
        matches!(bot["accessMode"].as_str(), Some("approval" | "fullAccess"))
            && bot["interactionMode"] == "build",
        "Bot runtime requires a saved access mode and Build"
    );
    // Swift bots may save an effort or speed; a bot conversation always starts
    // at the provider default. Keep the provider and model, drop the rest.
    Ok(json!({
        "provider": required(selection, "provider")?,
        "modelID": model,
    }))
}
fn cwd(bot: &Value, home: &Path) -> Result<PathBuf> {
    ensure!(home.is_absolute(), "Home directory is not absolute");
    let path = match bot.get("folder").filter(|v| !v.is_null()) {
        None => home.to_owned(),
        Some(folder) => {
            let folder = folder.as_str().context("Bot folder must be text")?;
            ensure!(!folder.contains('\0'), "Invalid bot folder");
            if folder.is_empty() || folder == "~" {
                home.to_owned()
            } else if let Some(relative) = folder.strip_prefix("~/") {
                home.join(relative)
            } else {
                PathBuf::from(folder)
            }
        }
    };
    ensure!(
        path.is_absolute() && path.is_dir(),
        "Bot folder must be an existing absolute directory"
    );
    Ok(path.canonicalize()?)
}
fn instructions(bot: &Value, name: &str, persona: &str) -> Result<String> {
    let personality = if let Some(value) = bot.get("personality").filter(|v| !v.is_null()) {
        ensure!(value.is_object(), "Invalid bot personality");
        match value["preset"].as_str().filter(|s| !s.is_empty()) {
            Some(id) => preset(id).map(str::to_owned),
            None => {
                let text = value["custom"].as_str().unwrap_or("").trim();
                ensure!(
                    text.chars().count() <= 4000 && !text.contains('\0'),
                    "Invalid custom bot personality"
                );
                (!text.is_empty()).then(|| text.to_owned())
            }
        }
    } else {
        None
    };
    let persona = persona.trim();
    let who = format!(
        "You are {name}, one of the user's bots in Coincide, a desktop app for working with coding agents. Each bot is an ongoing conversation with its own personality and job."
    );
    let text = if let Some(personality) = personality {
        let mut text = who
            + " Stay in character, and ask before doing anything destructive or hard to undo.\n\n## Personality\nHow you talk and behave. It shapes your tone and manner only: your instructions, the user's requests and your safety rules always come first.\n\n"
            + &personality;
        if !persona.is_empty() {
            text.push_str("\n\n## Instructions\nYour job, in the user's words.\n\n");
            text.push_str(persona);
        }
        text
    } else {
        let mut text = who
            + " Stay in character, keep replies friendly and to the point, and ask before doing anything destructive or hard to undo.";
        if !persona.is_empty() {
            text.push_str("\n\n");
            text.push_str(persona);
        }
        text
    };
    ensure!(
        text.chars().count() <= INSTRUCTIONS_LIMIT
            && text.len() <= 65_536
            && !text.trim().is_empty()
            && !text.contains('\0'),
        "Formatted bot instructions exceed runtime limits (25,000 characters / 65,536 bytes) or contain NUL"
    );
    Ok(text)
}

pub fn create(store: &mut Store, params: &Value) -> Result<Value> {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .context("Home directory is unavailable")?;
    create_with_home(store, params, Path::new(&home))
}
fn create_with_home(store: &mut Store, params: &Value, home: &Path) -> Result<Value> {
    let fields = params
        .as_object()
        .context("Bot conversation params must be an object")?;
    ensure!(
        fields.len() == 2 && fields.contains_key("botId") && fields.contains_key("baseline"),
        "Expected exactly botId and baseline"
    );
    let bot_id = Uuid::parse_str(required(params, "botId")?)?;
    let expected = required(params, "baseline")?;
    ensure!(
        expected.len() == 64 && expected.bytes().all(|b| b.is_ascii_hexdigit()),
        "Invalid bot baseline"
    );
    let (source, envelope, baseline) = snapshot(store)?;
    ensure!(
        expected == baseline,
        "Bot document changed; reload before creating a conversation"
    );
    let bot = envelope["bots"]
        .as_array()
        .unwrap()
        .iter()
        .find(|bot| bot["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(bot_id))
        .context("Bot not found")?;
    let stored_id = required(bot, "id")?;
    let selection = selection(bot)?;
    let provider = required(&selection, "provider")?;
    let name = required(bot, "name")?.trim();
    ensure!(
        !name.is_empty() && name.chars().count() <= 200 && !name.chars().any(char::is_control),
        "Invalid bot name"
    );
    let persona = required(bot, "persona")?;
    ensure!(
        persona.chars().count() <= 20_000 && !persona.contains('\0'),
        "Invalid bot persona"
    );
    let cwd = cwd(bot, home)?;
    let cwd = cwd.to_str().context("Bot directory is not UTF-8")?;
    let instructions = instructions(bot, name, persona)?;
    let id = Uuid::new_v4().to_string().to_uppercase();
    let now = swift_timestamp();
    let access_mode = required(bot, "accessMode")?.to_owned();
    let context = json!({"version":1,"botId":stored_id,"sourceBaseline":baseline,"provider":provider,"selection":selection.clone(),"accessMode":access_mode.clone(),
        "cwd":cwd,"name":name,"persona":persona,"instructions":instructions});
    let thread = json!({"id":id,"projectID":BOTS_PROJECT_ID,"botID":stored_id,"title":"New conversation",
        "selection":selection,"worktreePath":cwd,"accessMode":access_mode,"interactionMode":"build",
        "createdAt":now,"updatedAt":now,"isPinned":false,"isArchived":false,"items":[],"sessions":{},
        "accountSessions":{},"draft":"","rustMessageQueue":[],"rustDraftImages":[],"rustBotContext":context});
    store.create_bot_thread_if_unchanged(source.as_ref(), &thread)?;
    Ok(
        json!({"threadId":id,"botId":stored_id,"created":true,"executionStarted":false,
        "selection":selection,"cwd":cwd,"instructionsScope":"bot-local"}),
    )
}

// Exact English personality prompt text from Swift BotPersonalityPreset.all.
fn preset(id: &str) -> Option<&'static str> {
    crate::bot_personality::preset(id).map(|preset| preset.prompt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    const BOT: &str = "ABCD1234-0000-4000-8000-000000000001";
    const OLD: &str = "00000000-0000-4000-8000-000000000002";
    fn bot() -> Value {
        json!({"id":BOT,"name":"Fixture bot","persona":"  \nPreserve exact persona\n  ",
        "selection":{"provider":"codex","modelID":"default"},"accessMode":"approval","interactionMode":"build",
        "personality":{"custom":"calm"},"unknown":{"preserve":true}})
    }
    fn envelope(bot: Value) -> Value {
        json!({"addedStarters":true,"starterLineup":7,"future":{"keep":true},"bots":[bot]})
    }
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf, Store, Value) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let home = root.join("synthetic-home");
        fs::create_dir(&home).unwrap();
        let db = root.join("rust/state.sqlite");
        let mut store = Store::open(&db).unwrap();
        let value = envelope(bot());
        store.save_document("bots.json", &value).unwrap();
        (dir, home, db, store, value)
    }
    fn params(store: &Store) -> Value {
        json!({"botId":BOT.to_lowercase(),"baseline":snapshot(store).unwrap().2})
    }
    #[test]
    fn creation_is_native_fresh_and_snapshot_survives_restart_and_bot_edits() {
        let (_dir, home, db, mut store, value) = fixture();
        for provider in ["codex", "claude"] {
            let mut document = value.clone();
            document["bots"][0]["selection"]["provider"] = json!(provider);
            store.save_document("bots.json", &document).unwrap();
            let p = params(&store);
            let result = create_with_home(&mut store, &p, &home).unwrap();
            assert_eq!(result["executionStarted"], false);
            let id = result["threadId"].as_str().unwrap();
            let thread = store.thread(id).unwrap();
            assert_eq!(thread["botID"], BOT);
            assert_eq!(thread["projectID"], BOTS_PROJECT_ID);
            assert_eq!(thread["selection"], document["bots"][0]["selection"]);
            assert_eq!(
                thread["rustBotContext"]["persona"],
                document["bots"][0]["persona"]
            );
            assert_eq!(thread["rustBotContext"]["provider"], provider);
            assert_eq!(thread["worktreePath"], home.to_str().unwrap());
            assert!(thread["items"].as_array().unwrap().is_empty());
            assert!(thread["sessions"].as_object().unwrap().is_empty());
            assert!(!store.is_imported(id).unwrap());
            let mut changed = document.clone();
            changed["bots"][0]["persona"] = json!("Changed later");
            store.save_document("bots.json", &changed).unwrap();
            let reopened = Store::open(&db).unwrap();
            assert_eq!(reopened.thread(id).unwrap(), thread);
            assert!(fs::read_dir(&home).unwrap().next().is_none());
            assert_eq!(
                reopened.summaries("New conversation", true).unwrap().len(),
                store.summaries("", true).unwrap().len()
            );
        }
    }
    #[test]
    fn rejects_stale_baseline_and_unsupported_selection_without_thread_writes() {
        let (_dir, home, _db, mut store, value) = fixture();
        let stale = params(&store);
        let mut next = value.clone();
        next["bots"][0]["name"] = json!("Changed");
        store.save_document("bots.json", &next).unwrap();
        assert!(create_with_home(&mut store, &stale, &home).is_err());
        for (field, invalid) in [
            ("provider", json!("grok")),
            ("accountID", json!("paid-alternate")),
            ("serviceTier", json!("priority")),
            ("modelID", json!("--flag")),
        ] {
            let mut next = value.clone();
            next["bots"][0]["selection"][field] = invalid;
            store.save_document("bots.json", &next).unwrap();
            let p = params(&store);
            assert!(create_with_home(&mut store, &p, &home).is_err(), "{field}");
        }
        for (field, invalid) in [("accessMode", "unknownMode"), ("interactionMode", "plan")] {
            let mut next = value.clone();
            next["bots"][0][field] = json!(invalid);
            store.save_document("bots.json", &next).unwrap();
            let p = params(&store);
            assert!(create_with_home(&mut store, &p, &home).is_err());
        }
        assert!(store.summaries("", true).unwrap().is_empty());
        // A Swift bot may save effort and speed; the conversation it starts
        // keeps only the provider and model.
        let mut next = value.clone();
        next["bots"][0]["selection"]["effort"] = json!("xhigh");
        next["bots"][0]["selection"]["speed"] = json!("priority");
        store.save_document("bots.json", &next).unwrap();
        let p = params(&store);
        let created = create_with_home(&mut store, &p, &home).unwrap();
        assert_eq!(
            created["selection"],
            json!({"provider":"codex","modelID":"default"})
        );
        let thread = store.thread(created["threadId"].as_str().unwrap()).unwrap();
        assert_eq!(thread["selection"], created["selection"]);

        // A full-access Swift bot keeps its access mode in its conversations.
        let mut next = value.clone();
        next["bots"][0]["accessMode"] = json!("fullAccess");
        store.save_document("bots.json", &next).unwrap();
        let p = params(&store);
        let created = create_with_home(&mut store, &p, &home).unwrap();
        let thread = store.thread(created["threadId"].as_str().unwrap()).unwrap();
        assert_eq!(thread["accessMode"], "fullAccess");
        assert_eq!(thread["rustBotContext"]["accessMode"], "fullAccess");
    }
    #[test]
    fn helper_compares_envelope_in_transaction_and_rolls_back_cache_failure() {
        let (_dir, home, db, mut store, value) = fixture();
        let p = params(&store);
        let result = create_with_home(&mut store, &p, &home).unwrap();
        let mut thread = store.thread(result["threadId"].as_str().unwrap()).unwrap();
        thread["id"] = json!(Uuid::new_v4().to_string());
        let id = thread["id"].as_str().unwrap().to_owned();
        let mut other = Store::open(&db).unwrap();
        let mut changed = value.clone();
        changed["future"] = json!("changed concurrently");
        other.save_document("bots.json", &changed).unwrap();
        assert!(
            store
                .create_bot_thread_if_unchanged(Some(&value), &thread)
                .is_err()
        );
        assert!(store.thread(&id).is_err());
        other.save_document("bots.json", &value).unwrap();
        let db = rusqlite::Connection::open(&db).unwrap();
        db.execute_batch("CREATE TRIGGER reject_bot_cache BEFORE INSERT ON thread_summaries BEGIN SELECT RAISE(ABORT,'fixture cache failure'); END;").unwrap();
        assert!(
            store
                .create_bot_thread_if_unchanged(Some(&value), &thread)
                .is_err()
        );
        assert!(store.thread(&id).is_err());
        assert!(!store.is_imported(&id).unwrap());
        assert_eq!(store.summaries("", true).unwrap().len(), 1);
        assert_eq!(store.document("bots.json").unwrap().unwrap(), value);
        for table in ["threads", "search", "thread_summaries", "search_trigram"] {
            let column = if table == "threads" || table == "thread_summaries" {
                "id"
            } else {
                "thread_id"
            };
            let count: i64 = db
                .query_row(
                    &format!("SELECT count(*) FROM {table} WHERE {column}=?1"),
                    [&id],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(count, 0);
        }
    }
    #[test]
    fn captured_bots_and_imported_threads_remain_unchanged_and_blocked() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let source = root.join("source");
        fs::create_dir_all(source.join("threads")).unwrap();
        let home = root.join("home");
        fs::create_dir(&home).unwrap();
        let original = serde_json::to_vec_pretty(&envelope(bot())).unwrap();
        fs::write(source.join("bots.json"), &original).unwrap();
        let old = json!({"id":OLD,"items":[],"sessions":{"codex":{"id":"owned-by-Swift"}},"botID":BOT,"projectID":BOTS_PROJECT_ID});
        let old_bytes = serde_json::to_vec(&old).unwrap();
        fs::write(source.join(format!("threads/{OLD}.json")), &old_bytes).unwrap();
        let mut store = Store::open(&root.join("rust/state.sqlite")).unwrap();
        store.import_legacy(&source).unwrap();
        let p = params(&store);
        let result = create_with_home(&mut store, &p, &home).unwrap();
        let id = result["threadId"].as_str().unwrap();
        assert!(store.is_imported(OLD).unwrap());
        assert!(!store.is_imported(id).unwrap());
        assert_eq!(store.thread(OLD).unwrap(), old);
        assert_eq!(store.original("bots.json").unwrap().unwrap(), original);
        assert_eq!(fs::read(source.join("bots.json")).unwrap(), original);
        assert!(store.local_document("bots.json").unwrap().is_none());
        assert!(
            store.thread(id).unwrap()["sessions"]
                .as_object()
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn folder_resolution_and_instruction_bytes_fail_closed_without_truncation() {
        let (_dir, home, _db, mut store, value) = fixture();
        fs::create_dir(home.join("work")).unwrap();
        let mut next = value.clone();
        next["bots"][0]["folder"] = json!("~/work");
        store.save_document("bots.json", &next).unwrap();
        let p = params(&store);
        let result = create_with_home(&mut store, &p, &home).unwrap();
        assert_eq!(result["cwd"], home.join("work").to_str().unwrap());
        let before = store.summaries("", true).unwrap().len();
        for persona in ["🦀".repeat(20_000), "a\0b".into()] {
            let mut next = value.clone();
            next["bots"][0]["persona"] = json!(persona);
            store.save_document("bots.json", &next).unwrap();
            let p = params(&store);
            assert!(create_with_home(&mut store, &p, &home).is_err());
        }
        assert_eq!(store.summaries("", true).unwrap().len(), before);
        let mut b = bot();
        b["personality"] = json!({"preset":"professional","custom":"ignored"});
        let text = instructions(&b, "Fixture bot", "  exact  ").unwrap();
        assert!(text.contains(preset("professional").unwrap()));
        assert!(text.ends_with("exact"));
        assert!(text.len() <= 65_536);
        assert_eq!(b["persona"], bot()["persona"]);
    }
    #[test]
    fn default_account_aliases_are_preserved_and_alternate_account_is_rejected() {
        let (_dir, home, _db, mut store, value) = fixture();
        for alias in [
            None,
            Some(Value::Null),
            Some(json!("")),
            Some(json!("default")),
        ] {
            let mut document = value.clone();
            if let Some(alias) = alias {
                document["bots"][0]["selection"]["accountID"] = alias;
            }
            store.save_document("bots.json", &document).unwrap();
            let p = params(&store);
            let result = create_with_home(&mut store, &p, &home).unwrap();
            let thread = store.thread(result["threadId"].as_str().unwrap()).unwrap();
            // Every default alias becomes the provider default account, and the
            // conversation starts without a saved effort or speed.
            let expected = json!({
                "provider": document["bots"][0]["selection"]["provider"],
                "modelID": document["bots"][0]["selection"]["modelID"],
            });
            assert_eq!(thread["selection"], expected);
            assert_eq!(thread["rustBotContext"]["selection"], expected);
        }
        let before = store.summaries("", true).unwrap().len();
        let mut document = value;
        document["bots"][0]["selection"]["accountID"] = json!("alternate-account");
        store.save_document("bots.json", &document).unwrap();
        let p = params(&store);
        assert!(create_with_home(&mut store, &p, &home).is_err());
        assert_eq!(store.summaries("", true).unwrap().len(), before);
    }
}
