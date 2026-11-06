use super::*;

const ID: &str = "00000000-0000-4000-8000-000000000001";
fn fixture() -> (tempfile::TempDir, Engine) {
    let root = tempfile::tempdir().unwrap();
    let engine = Engine::new(Store::open(&root.path().join("rust.sqlite")).unwrap());
    (root, engine)
}
fn envelope() -> Value {
    json!({"addedStarters":true,"starterLineup":7,"futureEnvelope":{"keep":[1,2,3]},
        "bots":[{"id":ID,"name":"Original","persona":"old instructions","avatar":{"futureShape":"keep"},
        "personality":{"future":"keep"},"selection":{"provider":"claude","modelID":"custom","accountID":"keep"},
        "accessMode":"future-mode","folder":"/never/write/here","futureBot":[{"keep":true}]}]})
}
#[test]
fn imported_envelope_and_unknown_fields_survive_local_edit_and_restart() {
    let (root, mut engine) = fixture();
    let source = root.path().join("original");
    std::fs::create_dir_all(source.join("threads")).unwrap();
    let original = envelope();
    let bytes = serde_json::to_vec_pretty(&original).unwrap();
    std::fs::write(source.join("bots.json"), &bytes).unwrap();
    let instruction_path = source.join("AGENTS.md");
    std::fs::write(&instruction_path, "global fixture must remain unchanged").unwrap();
    engine.store.import_legacy(&source).unwrap();
    let listed = engine.execute("bots.list", &json!({})).unwrap();
    assert_eq!(listed["origin"], "imported");
    assert_eq!(listed["bots"], original["bots"]);
    let read = engine.execute("bots.read", &json!({"botId":ID})).unwrap();
    assert_eq!(read["baseline"], listed["baseline"]);
    let revision = engine.revision;
    let persona = "\n  Instructions stay exactly as entered. 中文\n\t";
    let saved = engine.execute("bots.patch", &json!({"botId":ID,"baseline":read["baseline"],"patch":{"name":"  Renamed  ","persona":persona}})).unwrap();
    assert_eq!(saved["origin"], "local");
    assert_eq!(saved["instructionsScope"], "bot-local");
    assert_eq!(saved["executionConnected"], false);
    assert_eq!(engine.revision, revision + 1);
    let mut expected = original.clone();
    expected["bots"][0]["name"] = json!("Renamed");
    expected["bots"][0]["persona"] = json!(persona);
    assert_eq!(
        engine.store.local_document(DOCUMENT).unwrap(),
        Some(expected.clone())
    );
    assert_eq!(engine.store.original(DOCUMENT).unwrap().unwrap(), bytes);
    assert_eq!(std::fs::read(source.join("bots.json")).unwrap(), bytes);
    assert_eq!(
        std::fs::read_to_string(instruction_path).unwrap(),
        "global fixture must remain unchanged"
    );
    assert!(engine.store.summaries("", true).unwrap().is_empty());
    drop(engine);
    let mut restarted = Engine::new(Store::open(&root.path().join("rust.sqlite")).unwrap());
    let read = restarted
        .execute("bots.read", &json!({"botId":ID}))
        .unwrap();
    assert_eq!(read["bot"], expected["bots"][0]);
    assert_eq!(read["baseline"], saved["baseline"]);
}

#[test]
fn create_and_update_keep_uuid_and_stale_saves_leave_state_and_revision_intact() {
    let (root, mut engine) = fixture();
    let empty = engine.execute("bots.list", &json!({})).unwrap();
    assert_eq!(empty["origin"], "empty");
    let created = engine.execute("bots.save", &json!({"baseline":empty["baseline"],"patch":{"name":"New bot","persona":"local only"}})).unwrap();
    let id = created["bot"]["id"].as_str().unwrap();
    assert!(Uuid::parse_str(id).is_ok());
    assert_eq!(created["bot"]["accessMode"], "approval");
    let mut second = Engine::new(Store::open(&root.path().join("rust.sqlite")).unwrap());
    let second_baseline = second.execute("bots.list", &json!({})).unwrap()["baseline"].clone();
    let updated = engine.execute("bots.save", &json!({"botId":id.to_lowercase(),"baseline":created["baseline"],"patch":{"name":"Updated"}})).unwrap();
    assert_eq!(updated["bot"]["id"], id);
    let revision = second.revision;
    let error = second
        .execute(
            "bots.patch",
            &json!({"botId":id,"baseline":second_baseline,"patch":{"persona":"stale"}}),
        )
        .unwrap_err();
    assert!(error.to_string().contains("reload"));
    assert_eq!(second.revision, revision);
    assert_eq!(
        second.execute("bots.read", &json!({"botId":id})).unwrap()["bot"],
        updated["bot"]
    );
    assert!(
        engine
            .execute(
                "bots.save",
                &json!({"baseline":empty["baseline"],"patch":{"name":"retry must not duplicate"}})
            )
            .is_err()
    );
    assert_eq!(
        engine.execute("bots.list", &json!({})).unwrap()["bots"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn store_compare_and_save_guards_a_writer_between_api_read_and_write() {
    let (root, mut engine) = fixture();
    let mut other = Store::open(&root.path().join("rust.sqlite")).unwrap();
    let first = envelope();
    engine
        .store
        .save_bots_document_if_unchanged(None, &first)
        .unwrap();
    assert!(
        other
            .save_bots_document_if_unchanged(None, &json!({"bots":[]}))
            .is_err()
    );
    let mut second = first.clone();
    second["bots"][0]["persona"] = json!("other writer");
    other
        .save_bots_document_if_unchanged(Some(&first), &second)
        .unwrap();
    assert!(
        engine
            .store
            .save_bots_document_if_unchanged(Some(&first), &json!({"bots":[]}))
            .is_err()
    );
    assert_eq!(engine.store.local_document(DOCUMENT).unwrap(), Some(second));
}

#[test]
fn malformed_envelopes_duplicate_ids_and_unsafe_patches_fail_without_writes() {
    let (_root, mut engine) = fixture();
    let baseline = engine.execute("bots.list", &json!({})).unwrap()["baseline"].clone();
    for patch in [
        json!({"name":""}),
        json!({"name":"x".repeat(201)}),
        json!({"name":"new","persona":"x".repeat(20_001)}),
        json!({"name":"new","persona":"bad\u{0000}"}),
        json!({"name":"new","instructions":"global"}),
        json!({"name":"new","folder":"/tmp"}),
        json!({"name":"new","accessMode":"fullAccess"}),
        json!({"id":ID,"name":"new"}),
        json!({}),
    ] {
        assert!(
            engine
                .execute("bots.save", &json!({"baseline":baseline,"patch":patch}))
                .is_err()
        );
        assert!(engine.store.local_document(DOCUMENT).unwrap().is_none());
    }
    assert!(
        engine
            .execute(
                "bots.patch",
                &json!({"baseline":baseline,"patch":{"name":"new"}})
            )
            .is_err()
    );
    assert!(
        engine
            .execute("bots.list", &json!({"path":"/tmp/AGENTS.md"}))
            .is_err()
    );
    let original = envelope();
    for invalid in [
        json!([]),
        json!({}),
        json!({"bots":[original["bots"][0],original["bots"][0]]}),
        json!({"bots":[{"id":"bad"}]}),
    ] {
        engine.store.save_document(DOCUMENT, &invalid).unwrap();
        assert!(engine.execute("bots.list", &json!({})).is_err());
        assert!(
            engine
                .execute(
                    "bots.save",
                    &json!({"baseline":baseline,"patch":{"name":"must not discard"}})
                )
                .is_err()
        );
        assert_eq!(
            engine.store.local_document(DOCUMENT).unwrap(),
            Some(invalid)
        );
    }
}

#[test]
fn methods_are_registered_once_in_public_capabilities() {
    let (_root, mut engine) = fixture();
    let response = engine.dispatch(json!({"method":"app.capabilities","params":{}}));
    let methods = response["result"].as_array().unwrap();
    for method in METHODS {
        assert_eq!(
            methods
                .iter()
                .filter(|value| value.as_str() == Some(*method))
                .count(),
            1
        );
    }
    let response = engine.dispatch(json!({"method":"bots.list","params":{}}));
    assert_eq!(response["result"]["bots"], json!([]));
}
