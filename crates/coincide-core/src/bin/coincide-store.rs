use anyhow::{Result, bail};
use coincide_core::store::Store;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::path::Path;
use uuid::Uuid;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("import") if args.len() == 4 => {
            let mut store = Store::open(Path::new(&args[3]))?;
            println!(
                "{}",
                serde_json::to_string_pretty(&store.import_legacy(Path::new(&args[2]))?)?
            );
        }
        Some("import-forked") if args.len() == 4 => {
            println!(
                "{}",
                serde_json::to_string_pretty(&import_forked(&args[2], &args[3])?)?,
            );
        }
        Some("check") if args.len() == 3 => {
            let store = Store::open(Path::new(&args[2]))?;
            println!("{} threads readable", store.summaries("", true)?.len());
        }
        _ => bail!(
            "Usage: coincide-store import SOURCE_DIRECTORY NEW_DATABASE | import-forked SOURCE_DIRECTORY NEW_DATABASE | check DATABASE"
        ),
    }
    Ok(())
}

/// Imports the Swift data, then replaces every read-only imported thread with
/// a native fork that keeps its full transcript, title, project, bot, draft,
/// pins, archive state and timestamps. The imported originals and their
/// search/index rows are removed from the new database.
fn import_forked(source: &str, destination: &str) -> Result<Value> {
    let source = Path::new(source);
    let database = Path::new(destination);
    let mut store = Store::open(database)?;
    let report = store.import_legacy(source)?;
    let threads = store.summaries("", true)?;
    let mut forks = Vec::new();
    for summary in &threads {
        let id = summary.id.as_str();
        let original = store.thread(id)?;
        let mut fork = original.clone();
        let fork_id = Uuid::new_v4().to_string().to_uppercase();
        fork["id"] = json!(fork_id);
        if let Some(fields) = fork.as_object_mut() {
            fields.remove("sessions");
            fields.remove("accountSessions");
            fields.remove("isImported");
            fields.insert("accessMode".into(), json!("approval"));
            fields.insert("interactionMode".into(), json!("build"));
        }
        store.save(&fork)?;
        forks.push(json!({
            "source": id,
            "fork": fork["id"],
            "title": summary.title,
        }));
    }
    // Persisted Swift preferences arrive as documents during import. New
    // threads must resolve their own provider defaults, not inherit a fixed
    // selection, and every installed agent must be selectable.
    if let Some(mut settings) = store.document("settings.json")? {
        settings["defaultSelection"] = Value::Null;
        settings["defaultAccessMode"] = Value::Null;
        if let Some(entries) = settings["providers"].as_array_mut() {
            for pair in entries.chunks_exact_mut(2) {
                let Some(id) = pair[0].as_str() else { continue };
                if matches!(id, "codex" | "claude" | "cursor" | "grok" | "opencode") {
                    pair[1]["isEnabled"] = json!(true);
                }
            }
        }
        store.save_document("settings.json", &settings)?;
    }
    // The old selection and the imported transcripts are not part of the
    // forked history.
    drop(store);
    let connection = Connection::open(database)?;
    connection.execute_batch(
        "CREATE TEMP TABLE doomed(id TEXT PRIMARY KEY);
         INSERT INTO doomed SELECT id FROM imported_threads;
         DELETE FROM search WHERE thread_id IN (SELECT id FROM doomed);
         DELETE FROM search_trigram WHERE thread_id IN (SELECT id FROM doomed);
         DELETE FROM thread_summaries WHERE id IN (SELECT id FROM doomed);
         DELETE FROM thread_navigation WHERE id IN (SELECT id FROM doomed);
         DELETE FROM threads WHERE id IN (SELECT id FROM doomed);
         DELETE FROM imported_threads;
         DELETE FROM original_files WHERE path LIKE 'threads/%'
            OR path LIKE 'ImportedSessions/%'
            OR path LIKE 'checkpoints/%';
         DELETE FROM documents WHERE name IN ('ui-state.json', 'scheduled-tasks.json', 'settings-window.json');
         DELETE FROM original_files WHERE path IN ('ui-state.json', 'scheduled-tasks.json');
         VACUUM;",
    )?;
    let _ = connection.close();
    let store = Store::open(database)?;
    let remaining = store.summaries("", true)?;
    Ok(json!({
        "imported": report.threads,
        "forks": forks.len(),
        "remaining": remaining.len(),
        "forked": forks,
    }))
}
