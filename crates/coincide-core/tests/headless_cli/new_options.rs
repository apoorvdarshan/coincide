//! One shipped-parser → real subprocess Engine/Store composition regression.
//! All application/CLI environments are cleared; PATH contains owned deny bins.
use super::*;
use coincide_core::store::Store;
use rusqlite::{Connection, OpenFlags, types::ValueRef};

fn snapshot(data: &Path, created_ids: &[&str]) -> Value {
    let db = Connection::open_with_flags(
        data.join("coincide.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let mut captured = serde_json::Map::new();
    for (table, order) in [
        ("threads", "id"),
        ("documents", "name"),
        ("metadata", "key"),
        ("thread_summaries", "id"),
        ("search", "thread_id,title,body"),
        ("search_trigram", "thread_id,body"),
        ("original_files", "path"),
        ("imported_threads", "id"),
    ] {
        let mut statement = db
            .prepare(&format!("SELECT * FROM {table} ORDER BY {order}"))
            .unwrap();
        let columns = statement.column_count();
        let mut rows = statement
            .query_map([], |row| {
                Ok(Value::Array(
                    (0..columns)
                        .map(|i| {
                            Ok(match row.get_ref(i)? {
                                ValueRef::Null => Value::Null,
                                ValueRef::Integer(v) => json!(v),
                                ValueRef::Real(v) => json!(v),
                                ValueRef::Text(v) => json!(std::str::from_utf8(v).unwrap()),
                                ValueRef::Blob(v) => json!(v),
                            })
                        })
                        .collect::<rusqlite::Result<Vec<_>>>()?,
                ))
            })
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        if matches!(
            table,
            "threads" | "thread_summaries" | "search" | "search_trigram"
        ) {
            rows.retain(|row| !created_ids.iter().any(|id| row[0] == *id));
        }
        captured.insert(table.into(), json!(rows));
    }
    Value::Object(captured)
}
fn assert_unsent(
    fixture: &Fixture,
    thread: &Value,
    title: &str,
    draft: &str,
    model: &str,
    mode: &str,
) {
    assert_eq!(thread["title"], title);
    assert_eq!(thread["draft"], draft);
    assert_eq!(
        thread["selection"],
        json!({"provider":"codex","modelID":model,"accountID":"default","effort":null,"speed":null})
    );
    assert_eq!(thread["accessMode"], "approval");
    assert_eq!(thread["interactionMode"], mode);
    assert_eq!(thread["items"], json!([]));
    assert_eq!(thread["sessions"], json!({}));
    let id = thread["id"].as_str().unwrap();
    assert_eq!(fixture.api("threads.read", json!({"threadId":id})), *thread);
    let db = Connection::open_with_flags(
        fixture.data.join("coincide.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let raw: String = db
        .query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(serde_json::from_str::<Value>(&raw).unwrap(), *thread);
    let indexed: String = db
        .query_row(
            "SELECT title FROM thread_summaries WHERE id=?1",
            [id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(indexed, title);
    let indexed: String = db
        .query_row("SELECT title FROM search WHERE thread_id=?1", [id], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(indexed, title);
}
#[test]
fn shipped_new_options_are_atomic_unsent_and_preserve_owned_engine_storage() {
    let mut fixture = Fixture::new();
    let tools = fixture.dir.path().join("deny-bin");
    fs::create_dir(&tools).unwrap();
    let effect_log = fixture.dir.path().join("unexpected-command.log");
    let quoted_log = format!("'{}'", effect_log.to_str().unwrap().replace('\'', "'\\''"));
    let script =
        format!("#!/bin/sh\nprintf 'unexpected external command\\n' >> {quoted_log}\nexit 97\n");
    for name in ["codex", "claude", "git", "bw", "op"] {
        let path = tools.join(name);
        fs::write(&path, &script).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    fixture.path_override = Some(tools);
    let project_dir = fixture.dir.path().join("owned project");
    fs::create_dir(&project_dir).unwrap();
    let source = fixture.dir.path().join("captured-originals");
    fs::create_dir_all(source.join("threads")).unwrap();
    fs::create_dir_all(source.join("attachments")).unwrap();
    let original_id = uuid::Uuid::new_v4().to_string();
    let raw = format!(
        " \n{}\n ",
        json!({"id":original_id,"title":"Original untouched","draft":"keep original café","items":[{"kind":"future","text":"original FTS sentinel"}],"sessions":{"codex":{"sessionID":"opaque-preserved"}},"future":{"retain":[true,42]}})
    );
    let original_path = source.join(format!("threads/{original_id}.json"));
    fs::write(&original_path, &raw).unwrap();
    let blob_path = source.join("attachments/opaque.bin");
    fs::write(&blob_path, [0_u8, 255, 7, 0]).unwrap();
    let mut store = Store::open(&fixture.data.join("coincide.sqlite")).unwrap();
    store.import_legacy(&source).unwrap();
    let project = store
        .create_project(&project_dir, Some("Owned café project"))
        .unwrap();
    let project_id = project["id"].as_str().unwrap().to_owned();
    let mut project = project;
    project["threadDefaults"] = json!({"selection":{"provider":"codex","modelID":"synthetic-base","accountID":"default","effort":null,"speed":null},"accessMode":"fullAccess","interactionMode":"plan"});
    project["futureProject"] = json!({"keep":["中文",true]});
    store
        .save_document("projects.json", &json!([project]))
        .unwrap();
    store.save_document("settings.json",&json!({"defaultSelection":{"provider":"claude","modelID":"global-not-project"},"defaultAccessMode":"approval","futureSettings":{"keep":42}})).unwrap();
    let mut unrelated = store.new_thread("").unwrap();
    unrelated["draft"] = json!("  unsent unrelated\n café  ");
    unrelated["future"] = json!({"opaque":"retained"});
    store.save(&unrelated).unwrap();
    drop(store);
    let before = snapshot(&fixture.data, &[]);
    let mut server = fixture.start();
    assert_eq!(
        snapshot(&fixture.data, &[]),
        before,
        "Starting the real Engine must preserve seeded rows"
    );
    let title = "  CLI café 中文 exact  ";
    let created = fixture.cli(&[
        "new",
        "--project",
        "Owned café project",
        "--agent=codex",
        "--model",
        "synthetic-target",
        "--access=approval",
        "--plan",
        "--title",
        title,
        "--json",
    ]);
    let id = created["id"].as_str().unwrap();
    assert_eq!(created["projectID"], project_id);
    assert_unsent(&fixture, &created, title, "", "synthetic-target", "plan");
    assert_eq!(snapshot(&fixture.data, &[id]), before);
    // The parser deliberately has no new-message/draft effect. Its raw API
    // command still carries the approved Core draft field exactly, unsent.
    let draft = "  👩🏽‍💻 café 中文 /plan\nsecond line  ";
    let api_title = "  Raw API title café  ";
    let drafted=fixture.api("threads.create",json!({"projectId":project_id,"title":api_title,"draft":draft,"selection":{"modelID":"synthetic-draft"},"accessMode":"approval","interactionMode":"build"}));
    let draft_id = drafted["id"].as_str().unwrap();
    assert_unsent(
        &fixture,
        &drafted,
        api_title,
        draft,
        "synthetic-draft",
        "build",
    );
    assert_eq!(snapshot(&fixture.data, &[id, draft_id]), before);
    let accepted = snapshot(&fixture.data, &[]);
    for (args, input) in [
        (
            vec!["new", "--project", &project_id, "--agent", "claude"],
            None,
        ),
        (
            vec!["new", "--project", &project_id, "--title", "bad\ntitle"],
            None,
        ),
        (vec!["new", "--chat", "--wait"], None),
        (
            vec!["api"],
            Some(
                json!({"method":"threads.create","params":{"projectId":project_id,"title":"would be partial","draft":false,"selection":{"modelID":"synthetic-draft"}}}),
            ),
        ),
    ] {
        let rejected = fixture.run(&args, input).failure();
        assert!(rejected.get("error").is_some(), "{rejected}");
        assert_eq!(
            snapshot(&fixture.data, &[]),
            accepted,
            "A bad CLI/Core request must not leave partial row/cache/FTS writes"
        );
    }
    let status = fixture.cli(&["status"]);
    assert_eq!(status["running"], json!([]));
    assert!(
        status["activeThread"].is_null(),
        "new must not request Open"
    );
    assert_eq!(
        fixture.api("agent.pending", json!({"threadId":id})),
        json!([])
    );
    assert_eq!(
        fixture.api("agent.pending", json!({"threadId":draft_id})),
        json!([])
    );
    assert_unsent(&fixture, &created, title, "", "synthetic-target", "plan");
    assert_unsent(
        &fixture,
        &drafted,
        api_title,
        draft,
        "synthetic-draft",
        "build",
    );
    fixture.cli(&["quit"]);
    server.wait_stopped();
    drop(server);
    assert_eq!(
        snapshot(&fixture.data, &[]),
        accepted,
        "Normal quit must preserve committed storage"
    );
    assert_eq!(fs::read(&original_path).unwrap(), raw.as_bytes());
    assert_eq!(fs::read(&blob_path).unwrap(), vec![0, 255, 7, 0]);
    assert!(
        !effect_log.exists(),
        "No provider, vault or Git command may execute"
    );
}
