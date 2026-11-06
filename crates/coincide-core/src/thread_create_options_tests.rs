//! Actual Engine/Store creation boundary, no provider/CLI process or native UI.
use super::*;
use rusqlite::{Connection, OpenFlags, types::ValueRef};
fn fixture() -> (tempfile::TempDir, Engine) {
    let dir = tempfile::tempdir().unwrap();
    let engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    (dir, engine)
}
fn snapshot(dir: &tempfile::TempDir) -> Value {
    let db = Connection::open_with_flags(
        dir.path().join("state.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let mut snapshot = serde_json::Map::new();
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
        let rows = statement
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
        snapshot.insert(table.into(), json!(rows));
    }
    Value::Object(snapshot)
}
fn without_new(mut snapshot: Value, id: &str) -> Value {
    for table in ["threads", "thread_summaries", "search", "search_trigram"] {
        snapshot[table]
            .as_array_mut()
            .unwrap()
            .retain(|row| row[0] != id);
    }
    snapshot
}
#[test]
fn structured_creation_preserves_defaults_originals_and_exact_unsent_text() {
    let (dir, mut engine) = fixture();
    let project = Uuid::new_v4().to_string();
    let defaults = json!({"selection":{"provider":"codex","modelID":"synthetic-base","accountID":"default","effort":null,"speed":null},"accessMode":"fullAccess","interactionMode":"plan"});
    engine.store.save_document("projects.json",&json!([{"id":project,"name":"Synthetic","threadDefaults":defaults,"futureProject":{"retain":[true,"中文"]}}])).unwrap();
    engine
        .store
        .save_document(
            "settings.json",
            &json!("malformed lower-priority defaults stay unread"),
        )
        .unwrap();
    let source = dir.path().join("original-source");
    std::fs::create_dir_all(source.join("threads")).unwrap();
    std::fs::create_dir_all(source.join("attachments")).unwrap();
    let original_id = Uuid::new_v4().to_string();
    let raw = format!(
        " \n{}\n ",
        json!({"id":original_id,"title":"Original","draft":"kept original","items":[{"kind":"future","text":"unchanged original"}],"sessions":{"codex":{"sessionID":"opaque"}},"future":{"retain":true}})
    );
    // Actual captured bytes include deliberate leading/trailing whitespace.
    std::fs::write(source.join(format!("threads/{original_id}.json")), &raw).unwrap();
    std::fs::write(source.join("attachments/opaque.bin"), [0_u8, 255, 7, 0]).unwrap();
    engine.store.import_legacy(&source).unwrap();
    let before = snapshot(&dir);
    let revision = engine.revision;
    let draft = "  👩🏽‍💻 café 中文 /plan\nsecond line  ";
    let title = "  CLI café 中文  ";
    let created=engine.execute("threads.create",&json!({"projectId":project.to_uppercase(),"cwd":dir.path(),"title":title,"draft":draft,"selection":{"modelID":"synthetic-target"},"accessMode":"approval","interactionMode":"build"})).unwrap();
    assert_eq!(created["title"], title);
    assert_eq!(created["draft"], draft);
    assert_eq!(
        created["selection"],
        json!({"provider":"codex","modelID":"synthetic-target","accountID":"default","effort":null,"speed":null})
    );
    assert_eq!(created["accessMode"], "approval");
    assert_eq!(created["interactionMode"], "build");
    assert_eq!(created["items"], json!([]));
    assert_eq!(created["sessions"], json!({}));
    assert_eq!(created["worktreePath"], json!(dir.path()));
    assert_eq!(engine.revision, revision + 1);
    assert!(engine.runs.is_empty());
    assert!(engine.active_thread().is_none());
    assert_eq!(
        without_new(snapshot(&dir), created["id"].as_str().unwrap()),
        before
    );
    assert_eq!(
        std::fs::read(source.join(format!("threads/{original_id}.json"))).unwrap(),
        raw.as_bytes()
    );
    assert_eq!(
        std::fs::read(source.join("attachments/opaque.bin")).unwrap(),
        vec![0, 255, 7, 0]
    );
}
#[test]
fn invalid_structured_inputs_cannot_create_partial_rows_caches_or_revision() {
    let (dir, mut engine) = fixture();
    let mut existing = engine.store.new_thread("").unwrap();
    existing["future"] = json!({"untouched":true});
    engine.store.save(&existing).unwrap();
    let cases = vec![
        Value::Null,
        json!([]),
        json!({"message":"must not be silently dropped"}),
        json!({"open":true}),
        json!({"provider":"claude"}),
        json!({"cwd":false}),
        json!({"cwd":dir.path().join("missing")}),
        json!({"projectId":17}),
        json!({"title":null}),
        json!({"title":" \t"}),
        json!({"title":"line\nbreak"}),
        json!({"title":"a".repeat(513)}),
        json!({"draft":false}),
        json!({"draft":"a".repeat(1024*1024+1)}),
        json!({"selection":null}),
        json!({"selection":[]}),
        json!({"selection":{"unknown":true}}),
        json!({"selection":{"provider":false}}),
        json!({"selection":{"provider":"claude"}}),
        json!({"selection":{"provider":"unknown","modelID":"default"}}),
        json!({"selection":{"modelID":"--flag"}}),
        json!({"selection":{"accountID":false}}),
        json!({"selection":{"accountID":Uuid::new_v4().to_string()}}),
        json!({"selection":{"effort":"high"}}),
        json!({"selection":{"speed":"priority"}}),
        json!({"selection":{"provider":"antigravity","modelID":"synthetic","accountID":Uuid::new_v4().to_string()}}),
        json!({"accessMode":null}),
        json!({"accessMode":"invalid"}),
        json!({"interactionMode":false}),
        json!({"interactionMode":"plan"}),
    ];
    let before = snapshot(&dir);
    let revision = engine.revision;
    for (index, request) in cases.into_iter().enumerate() {
        assert!(
            engine.execute("threads.create", &request).is_err(),
            "case {index}"
        );
        assert_eq!(snapshot(&dir), before, "case {index}");
        assert_eq!(engine.revision, revision, "case {index}");
        assert!(engine.runs.is_empty());
    }
}
#[test]
fn provider_change_never_reuses_another_model_or_silently_clears_account() {
    let (dir, mut engine) = fixture();
    let account = Uuid::new_v4().to_string();
    let project = Uuid::new_v4().to_string();
    let mut accounts = json!({});
    accounts[&account] = json!({"auth":"login"});
    engine.store.save_document("rust-antigravity.json",&json!({"version":1,"accounts":accounts,"riskAcknowledgement":{"key":"provider:antigravity-account-risk","accepted":true}})).unwrap();
    let defaults = json!({"selection":{"provider":"antigravity","modelID":"synthetic-antigravity","accountID":account}});
    engine
        .store
        .save_document(
            "projects.json",
            &json!([{"id":project,"threadDefaults":defaults,"future":42}]),
        )
        .unwrap();
    let before = snapshot(&dir);
    let revision = engine.revision;
    for overrides in [
        json!({"provider":"codex","accountID":null}),
        json!({"provider":"codex","modelID":"synthetic-codex"}),
    ] {
        assert!(
            engine
                .execute(
                    "threads.create",
                    &json!({"projectId":project,"selection":overrides})
                )
                .is_err()
        );
        assert_eq!(snapshot(&dir), before);
        assert_eq!(engine.revision, revision);
    }
    let created=engine.execute("threads.create",&json!({"projectId":project,"selection":{"provider":"codex","modelID":"synthetic-codex","accountID":null}})).unwrap();
    assert_eq!(
        created["selection"],
        json!({"provider":"codex","modelID":"synthetic-codex","accountID":null})
    );
    assert_eq!(
        without_new(snapshot(&dir), created["id"].as_str().unwrap()),
        before
    );
    engine.store.save_document("projects.json",&json!([{"id":project,"threadDefaults":{"selection":{"provider":"codex","modelID":"synthetic-codex","accountID":"default","effort":null,"speed":null},"accessMode":"fullAccess","interactionMode":"plan"},"future":42}])).unwrap();
    let before = snapshot(&dir);
    let revision = engine.revision;
    assert!(engine.execute("threads.create",&json!({"projectId":project,"selection":{"provider":"claude","modelID":"synthetic-claude"}})).is_err());
    assert_eq!(snapshot(&dir), before);
    assert_eq!(engine.revision, revision);
    let changed=engine.execute("threads.create",&json!({"projectId":project,"selection":{"provider":"claude","modelID":"synthetic-claude"},"accessMode":"approval","interactionMode":"build"})).unwrap();
    assert_eq!(
        changed["selection"],
        json!({"provider":"claude","modelID":"synthetic-claude","accountID":"default","effort":null,"speed":null})
    );
    assert_eq!(
        without_new(snapshot(&dir), changed["id"].as_str().unwrap()),
        before
    );
}
#[test]
fn unchanged_options_keep_default_and_legacy_nullable_cwd_project_semantics() {
    let (dir, mut engine) = fixture();
    let plain = engine.execute("threads.create", &json!({})).unwrap();
    assert_eq!(plain["projectID"], "00000000-0000-0000-0000-000000000000");
    assert_eq!(
        plain["selection"],
        json!({"provider":"codex","modelID":"default"})
    );
    assert_eq!(plain["draft"], "");
    assert_eq!(plain["title"], "New conversation");
    let nullable = engine
        .execute(
            "threads.create",
            &json!({"cwd":null,"projectId":null,"selection":{"provider":"codex"},"draft":""}),
        )
        .unwrap();
    assert_eq!(nullable["selection"], plain["selection"]);
    assert_eq!(nullable["projectID"], plain["projectID"]);
    assert!(nullable.get("worktreePath").is_none());
    let empty = engine
        .execute(
            "threads.create",
            &json!({"projectId":"","cwd":dir.path(),"title":"x"}),
        )
        .unwrap();
    assert_eq!(empty["projectID"], "");
    assert_eq!(empty["worktreePath"], json!(dir.path()));
}
#[test]
fn explicit_options_cannot_bypass_unsupported_saved_defaults_or_unproved_effort() {
    let (dir, mut engine) = fixture();
    let project = Uuid::new_v4().to_string();
    for selection in [
        json!({"provider":"codex","modelID":"synthetic-base","effort":"high"}),
        json!({"provider":"codex","modelID":"synthetic-base","speed":"priority"}),
        json!({"provider":"codex","modelID":"synthetic-base","futureOption":true}),
    ] {
        engine
            .store
            .save_document(
                "projects.json",
                &json!([{"id":project,"threadDefaults":{"selection":selection}}]),
            )
            .unwrap();
        let before = snapshot(&dir);
        let revision = engine.revision;
        assert!(engine.execute("threads.create",&json!({"projectId":project,"selection":{"provider":"codex","modelID":"default","effort":null,"speed":null}})).is_err());
        assert_eq!(snapshot(&dir), before);
        assert_eq!(engine.revision, revision);
    }
}
#[test]
fn cache_write_failure_rolls_back_new_row_and_all_indexes_before_revision() {
    let (dir, mut engine) = fixture();
    let before = snapshot(&dir);
    let revision = engine.revision;
    let db = Connection::open(dir.path().join("state.sqlite")).unwrap();
    db.execute_batch("CREATE TRIGGER reject_new_thread_cache BEFORE INSERT ON thread_summaries BEGIN SELECT RAISE(ABORT,'synthetic cache failure'); END;").unwrap();
    assert!(engine.execute("threads.create",&json!({"title":"No orphan","draft":"keep unsent","selection":{"provider":"codex","modelID":"synthetic"},"accessMode":"fullAccess","interactionMode":"plan"})).is_err());
    assert_eq!(snapshot(&dir), before);
    assert_eq!(engine.revision, revision);
    db.execute_batch("DROP TRIGGER reject_new_thread_cache")
        .unwrap();
    let created = engine
        .execute(
            "threads.create",
            &json!({"title":"One acknowledged row","draft":"unsent"}),
        )
        .unwrap();
    assert_eq!(created["draft"], "unsent");
    assert_eq!(engine.revision, revision + 1);
    assert_eq!(snapshot(&dir)["threads"].as_array().unwrap().len(), 1);
}
#[test]
fn frozen_admission_and_closed_store_create_no_partial_state() {
    let (dir, mut engine) = fixture();
    let before = snapshot(&dir);
    let revision = engine.revision;
    engine.admissions_frozen = true;
    assert!(
        engine
            .execute(
                "threads.create",
                &json!({"title":"refused","draft":"unsent"})
            )
            .is_err()
    );
    assert_eq!(snapshot(&dir), before);
    assert_eq!(engine.revision, revision);
    engine.admissions_frozen = false;
    engine.store.close_for_shutdown().unwrap();
    assert!(
        engine
            .execute(
                "threads.create",
                &json!({"title":"refused","draft":"unsent"})
            )
            .is_err()
    );
    assert_eq!(snapshot(&dir), before);
    assert_eq!(engine.revision, revision);
}
