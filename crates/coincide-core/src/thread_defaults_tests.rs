use super::*;

fn fixture() -> (tempfile::TempDir, Engine) {
    let dir = tempfile::tempdir().unwrap();
    let engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    (dir, engine)
}
fn defaults() -> Value {
    json!({"selection":{"provider":"claude","modelID":"synthetic-custom","accountID":"default"},"accessMode":"approval","interactionMode":"build"})
}
fn configure(engine: &mut Engine, project: &str, defaults: Value, chats: bool) {
    engine.store.save_document("projects.json", &json!([{"id":project,"name":"Synthetic","isChats":chats,"threadDefaults":defaults,"future":{"keep":true}}])).unwrap();
}
fn rows(engine: &mut Engine) -> Value {
    engine
        .execute("threads.list", &json!({"includeArchived":true}))
        .unwrap()
}

#[test]
fn project_override_is_lazy_and_preserves_exact_selection_and_source_documents() {
    let (_dir, mut engine) = fixture();
    let project = Uuid::new_v4().to_string();
    configure(&mut engine, &project, defaults(), false);
    engine
        .store
        .save_document(
            "settings.json",
            &json!("malformed lower-priority settings shape"),
        )
        .unwrap();
    let projects = engine.store.document("projects.json").unwrap();
    let settings = engine.store.document("settings.json").unwrap();
    let thread = engine
        .execute(
            "threads.create",
            &json!({"projectId":project.to_uppercase()}),
        )
        .unwrap();
    assert_eq!(thread["selection"], defaults()["selection"]);
    assert_eq!(thread["accessMode"], "approval");
    assert_eq!(thread["interactionMode"], "build");
    assert_eq!(engine.store.document("projects.json").unwrap(), projects);
    assert_eq!(engine.store.document("settings.json").unwrap(), settings);
    assert_eq!(
        engine.store.thread(thread["id"].as_str().unwrap()).unwrap(),
        thread
    );
}

#[test]
fn chats_and_missing_project_defaults_inherit_global_without_merging_project_fields() {
    let (_dir, mut engine) = fixture();
    let project = Uuid::new_v4().to_string();
    engine.store.save_document("settings.json", &json!({"defaultSelection":defaults()["selection"],"defaultAccessMode":"approval","future":42})).unwrap();
    for (local, chats) in [
        (json!({"selection":{"provider":"invalid"}}), true),
        (Value::Null, false),
    ] {
        configure(&mut engine, &project, local, chats);
        let thread = engine
            .execute("threads.create", &json!({"projectId":project}))
            .unwrap();
        assert_eq!(thread["selection"], defaults()["selection"]);
        assert_eq!(thread["interactionMode"], "build");
    }
}

#[test]
fn no_defaults_preserves_api_and_store_fallbacks_and_existing_bot_snapshots() {
    let (_dir, mut engine) = fixture();
    let mut existing = engine.store.new_thread("").unwrap();
    assert_eq!(existing["selection"]["provider"], "claude");
    existing["rustBotContext"] =
        json!({"selection":{"provider":"codex","modelID":"default"},"immutable":"synthetic"});
    existing["future"] = json!({"preserved":true});
    engine.store.save(&existing).unwrap();
    let thread = engine.execute("threads.create", &json!({})).unwrap();
    assert_eq!(
        thread["selection"],
        json!({"provider":"codex","modelID":"default"})
    );
    assert_eq!(thread["accessMode"], "approval");
    assert_eq!(thread["interactionMode"], "build");
    assert_eq!(
        engine
            .store
            .thread(existing["id"].as_str().unwrap())
            .unwrap(),
        existing
    );
}

#[test]
fn unsupported_defaults_reject_before_any_row_revision_or_document_write() {
    let (_dir, mut engine) = fixture();
    let project = Uuid::new_v4().to_string();
    let mut invalid = Vec::new();
    for (key, value) in [
        ("effort", json!("high")),
        ("speed", json!("fast")),
        ("accountID", json!("named")),
        ("modelID", json!("--flag")),
        ("future", json!(true)),
    ] {
        let mut candidate = defaults();
        candidate["selection"][key] = value;
        invalid.push(candidate);
    }
    for (key, value) in [("interactionMode", json!("plan")), ("future", json!(true))] {
        let mut candidate = defaults();
        candidate[key] = value;
        invalid.push(candidate);
    }
    invalid.push(json!({}));
    invalid.push(json!({"selection":{"provider":"antigravity","modelID":"default"}}));
    for candidate in invalid {
        configure(&mut engine, &project, candidate, false);
        let before = rows(&mut engine);
        let revision = engine.revision;
        let projects = engine.store.document("projects.json").unwrap();
        assert!(
            engine
                .execute("threads.create", &json!({"projectId":project}))
                .is_err()
        );
        assert_eq!(rows(&mut engine), before);
        assert_eq!(engine.revision, revision);
        assert_eq!(engine.store.document("projects.json").unwrap(), projects);
    }
    configure(&mut engine, &project, Value::Null, false);
    engine
        .store
        .save_document(
            "settings.json",
            &json!({"defaultSelection":{"provider":"claude","modelID":"--flag"},"defaultAccessMode":"approval"}),
        )
        .unwrap();
    let before = rows(&mut engine);
    let revision = engine.revision;
    assert!(
        engine
            .execute("threads.create", &json!({"projectId":project}))
            .is_err()
    );
    assert_eq!(rows(&mut engine), before);
    assert_eq!(engine.revision, revision);
}

#[test]
fn default_aliases_remain_exact_and_duplicate_project_identity_fails_atomically() {
    let (_dir, mut engine) = fixture();
    let project = Uuid::new_v4().to_string();
    for alias in [Value::Null, json!(""), json!("default")] {
        let mut candidate = defaults();
        candidate["selection"]["accountID"] = alias;
        configure(&mut engine, &project, candidate.clone(), false);
        let thread = engine
            .execute("threads.create", &json!({"projectId":project}))
            .unwrap();
        assert_eq!(thread["selection"], candidate["selection"]);
    }
    engine.store.save_document("projects.json", &json!([{"id":project,"threadDefaults":defaults()},{"id":project.to_uppercase(),"threadDefaults":defaults()}])).unwrap();
    let before = rows(&mut engine);
    let revision = engine.revision;
    assert!(
        engine
            .execute("threads.create", &json!({"projectId":project}))
            .is_err()
    );
    assert_eq!(rows(&mut engine), before);
    assert_eq!(engine.revision, revision);
}

#[test]
fn configured_antigravity_metadata_validates_without_launch_and_preserves_account_identity() {
    let (_dir, mut engine) = fixture();
    let project = Uuid::new_v4().to_string();
    let named = Uuid::new_v4().to_string();
    let mut accounts = json!({"default":{"auth":"login"}});
    accounts[&named] = json!({"auth":"login"});
    engine.store.save_document("rust-antigravity.json", &json!({"version":1,"accounts":accounts,"riskAcknowledgement":{"key":"provider:antigravity-account-risk","accepted":true}})).unwrap();
    for alias in [Value::Null, json!(""), json!("default"), json!(named)] {
        let candidate = json!({"selection":{"provider":"antigravity","modelID":"synthetic-custom","accountID":alias}});
        configure(&mut engine, &project, candidate.clone(), false);
        let thread = engine
            .execute("threads.create", &json!({"projectId":project}))
            .unwrap();
        assert_eq!(thread["selection"], candidate["selection"]);
        assert_eq!(thread["accessMode"], "approval");
        assert_eq!(thread["interactionMode"], "build");
    }
    configure(
        &mut engine,
        &project,
        json!({"selection":{"provider":"antigravity","modelID":"default","accountID":Uuid::new_v4().to_string()}}),
        false,
    );
    let before = rows(&mut engine);
    let revision = engine.revision;
    assert!(
        engine
            .execute("threads.create", &json!({"projectId":project}))
            .is_err()
    );
    assert_eq!(rows(&mut engine), before);
    assert_eq!(engine.revision, revision);
}
