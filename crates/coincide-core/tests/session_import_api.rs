//! Public Engine routes only; synthetic source transcripts, no CLI execution.
use coincide_core::{api::Engine, store::Store};
use serde_json::{Value, json};

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    engine.dispatch(json!({"id":"import-fixture","method":method,"params":params}))
}

#[test]
fn session_import_capabilities_match_platform_support() {
    let directory = tempfile::tempdir().unwrap();
    let mut engine = Engine::new(Store::open(&directory.path().join("store.sqlite")).unwrap());
    let reply = call(&mut engine, "app.capabilities", json!({}));
    let methods = reply["result"].as_array().unwrap();
    for method in ["cli.sessions.preview", "cli.sessions.import"] {
        assert_eq!(methods.iter().any(|value| value == method), cfg!(unix));
        let response = call(&mut engine, method, json!({}));
        let error = response["error"]["message"].as_str().unwrap();
        if cfg!(unix) {
            assert!(error.contains("Missing"), "{error}");
        } else {
            assert!(error.contains("not supported"), "{error}");
        }
    }
}

#[cfg(unix)]
#[test]
fn public_import_changes_revision_once_preserves_source_and_cannot_execute() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let path = root.join("session.jsonl");
    let bytes = [
        json!({"type":"session_meta","payload":{"id":"00000000-0000-4000-8000-000000000001","cwd":"/synthetic","unknown":{"preserve":true}}}),
        json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"synthetic question"}]}}),
    ].iter().map(Value::to_string).collect::<Vec<_>>().join("\n");
    std::fs::write(&path, &bytes).unwrap();
    let database = root.join("store.sqlite");
    let mut engine = Engine::new(Store::open(&database).unwrap());
    let params = json!({"provider":"codex","path":path});
    let preview = call(&mut engine, "cli.sessions.preview", params.clone());
    assert!(preview["error"].is_null(), "{preview}");
    assert_eq!(preview["result"]["executable"], false);
    assert!(engine.store.summaries("", true).unwrap().is_empty());
    let mut params = params;
    params["sha256"] = preview["result"]["sha256"].clone();

    // Discovery is unrelated asynchronous revision activity. Freeze its result
    // by observing it before asserting the exact import revision increment.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while call(&mut engine, "providers.list", json!({}))["result"]["discovery"].is_null() {
        assert!(
            std::time::Instant::now() < deadline,
            "discovery did not settle"
        );
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    // poll applies discovery completions after its limits-context phase. Once
    // discovery is visible, settle that dependent context before measuring the
    // import itself; otherwise its next dispatch also advances that context.
    engine.poll();
    let revision = engine.revision;
    let imported = call(&mut engine, "cli.sessions.import", params.clone());
    assert!(imported["error"].is_null(), "{imported}");
    assert_eq!(engine.revision, revision + 1);
    let id = imported["result"]["threadId"].as_str().unwrap().to_owned();
    assert!(engine.store.is_imported(&id).unwrap());
    assert_eq!(std::fs::read(&path).unwrap(), bytes.as_bytes());
    let duplicate = call(&mut engine, "cli.sessions.import", params);
    assert!(duplicate["error"].is_object());
    assert_eq!(engine.revision, revision + 1);
    assert_eq!(engine.store.summaries("", true).unwrap().len(), 1);
    let execution = call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"never execute"}),
    );
    assert!(
        execution["error"]["message"]
            .as_str()
            .unwrap()
            .contains("read-only")
    );
    assert_eq!(
        engine.store.thread(&id).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        call(&mut engine, "app.status", json!({}))["result"]["running"],
        json!([])
    );
    drop(engine);
    let store = Store::open(&database).unwrap();
    assert!(store.is_imported(&id).unwrap());
    assert_eq!(store.thread(&id).unwrap()["sessions"], json!({}));
}
