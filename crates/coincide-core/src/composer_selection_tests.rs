//! API regressions use an isolated store and a constructor with no discovery.
use super::*;

fn fixture() -> (tempfile::TempDir, Engine, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let mut thread = engine.execute("threads.create", &json!({})).unwrap();
    let id = text(&thread, "id");
    thread["sessions"] =
        json!({"codex":{"sessionID":"fixture-native","seenItemCount":1,"future":42}});
    thread["accountSessions"] = json!({"codex/other":{"sessionID":"other-native"}});
    thread["future"] = json!({"keep":true});
    engine.store.save(&thread).unwrap();
    (dir, engine, id)
}

#[test]
fn strict_selection_rejects_atomically_without_touching_sessions_or_revision() {
    let (_dir, mut engine, id) = fixture();
    let before = engine.store.thread(&id).unwrap();
    let revision = engine.revision;
    for (key, value) in [
        ("effort", json!("high")),
        ("speed", json!("fast")),
        ("accountId", json!("named")),
        ("model", Value::Null),
        ("model", json!("--flag")),
        ("accessMode", json!("fullAccess")),
        ("interactionMode", json!("plan")),
        ("future", Value::Null),
    ] {
        let mut p = json!({"threadId":id,"provider":"claude","model":"fixture-model"});
        p[key] = value;
        assert!(engine.execute("agent.select", &p).is_err(), "accepted {p}");
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(engine.revision, revision);
    }
    assert!(
        engine
            .execute(
                "agent.select",
                &json!({"threadId":id,"provider":"antigravity"})
            )
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(engine.revision, revision);
}

#[test]
fn valid_default_alias_selection_persists_model_identity_and_all_other_fields() {
    let (_dir, mut engine, id) = fixture();
    for alias in [Value::Null, json!(""), json!("default")] {
        let before = engine.store.thread(&id).unwrap();
        let revision = engine.revision;
        let selected = engine.execute("agent.select", &json!({"threadId":id,"provider":"claude","model":"fixture-exact-model","accountId":alias})).unwrap();
        assert_eq!(
            selected["selection"],
            json!({"provider":"claude","modelID":"fixture-exact-model"})
        );
        for key in ["sessions", "accountSessions", "future", "items"] {
            assert_eq!(selected[key], before[key]);
        }
        assert_eq!(engine.revision, revision + 1);
        assert_eq!(engine.store.thread(&id).unwrap(), selected);
    }
}

#[test]
fn bot_snapshot_selection_is_locked_before_storage_and_capabilities_explain_it() {
    let (_dir, mut engine, id) = fixture();
    let mut thread = engine.store.thread(&id).unwrap();
    thread["selection"]["accountID"] = json!("default");
    thread["rustBotContext"] = json!({"selection":thread["selection"],"instructions":"fixture"});
    engine.store.save(&thread).unwrap();
    let revision = engine.revision;
    let reply = engine
        .execute("agent.selection.capabilities", &json!({"threadId":id}))
        .unwrap();
    assert_eq!(reply["locked"], true);
    assert!(reply["lockReason"].as_str().unwrap().contains("fixed"));
    assert!(
        engine
            .execute(
                "agent.select",
                &json!({"threadId":id,"provider":"codex","model":"default"})
            )
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert_eq!(engine.revision, revision);
}

#[test]
fn unsupported_saved_choices_block_send_before_provider_launch_or_transcript_write() {
    let (_dir, mut engine, id) = fixture();
    for (field, value) in [
        ("effort", json!("high")),
        ("speed", json!("priority")),
        ("futureOption", Value::Null),
    ] {
        let mut thread = engine.store.thread(&id).unwrap();
        thread["selection"] = json!({"provider":"codex","modelID":"default"});
        thread["selection"][field] = value;
        engine.store.save(&thread).unwrap();
        let revision = engine.revision;
        assert!(
            engine
                .execute(
                    "agent.send",
                    &json!({"threadId":id,"text":"must never launch"})
                )
                .is_err()
        );
        assert!(engine.runs.is_empty());
        assert_eq!(engine.store.thread(&id).unwrap(), thread);
        assert_eq!(engine.revision, revision);
        assert!(
            engine
                .execute("agent.select", &json!({"threadId":id,"provider":"claude"}))
                .is_err()
        );
        let capability = engine
            .execute("agent.selection.capabilities", &json!({"threadId":id}))
            .unwrap();
        assert_eq!(capability["locked"], true);
        assert_eq!(engine.revision, revision);
    }
}

#[test]
fn read_only_capabilities_are_advertised_and_do_not_touch_storage() {
    let (_dir, mut engine, id) = fixture();
    let before = engine.store.thread(&id).unwrap();
    let revision = engine.revision;
    let capability = engine
        .execute("agent.selection.capabilities", &json!({"threadId":id}))
        .unwrap();
    assert_eq!(capability["locked"], false);
    assert_eq!(capability["modelsDiscovered"], false);
    assert!(
        engine
            .execute("app.capabilities", &json!({}))
            .unwrap()
            .to_string()
            .contains("agent.selection.capabilities")
    );
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(engine.revision, revision);
}

#[test]
fn configured_antigravity_account_selection_preserves_exact_identity_without_probing() {
    let (_dir, mut engine, id) = fixture();
    let account = "11111111-1111-4111-8111-111111111111";
    engine.store.save_document("rust-antigravity.json", &json!({"version":1,
        "riskAcknowledgement":{"key":"provider:antigravity-account-risk","accepted":true},
        "accounts":{(account):{"name":"Synthetic profile","auth":"login","executable":"/synthetic/never-read","sourceProfile":"/synthetic/never-read-profile"}}})).unwrap();
    let before = engine.store.thread(&id).unwrap();
    let selected = engine.execute("agent.select", &json!({"threadId":id,"provider":"antigravity","accountId":account,"model":"fixture-model"})).unwrap();
    assert_eq!(
        selected["selection"],
        json!({"provider":"antigravity","modelID":"fixture-model","accountID":account})
    );
    assert_eq!(selected["sessions"], before["sessions"]);
    assert_eq!(selected["accountSessions"], before["accountSessions"]);
    assert!(engine.runs.is_empty());
    let revision = engine.revision;
    assert!(engine.execute("agent.select", &json!({"threadId":id,"provider":"claude","accountId":account,"model":"fixture-model"})).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), selected);
    assert_eq!(engine.revision, revision);
}

#[test]
fn recovery_lock_rejects_edits_without_touching_pending_or_persisted_state() {
    let (_dir, mut engine, id) = fixture();
    let before = engine.store.thread(&id).unwrap();
    engine
        .unsaved_threads
        .insert(id.clone(), json!({"fixture":"pending"}));
    let revision = engine.revision;
    let capabilities = engine
        .execute("agent.selection.capabilities", &json!({"threadId":id}))
        .unwrap();
    assert_eq!(capabilities["locked"], true);
    assert!(
        capabilities["lockReason"]
            .as_str()
            .unwrap()
            .contains("recovering")
    );
    assert!(
        engine
            .execute(
                "agent.select",
                &json!({"threadId":id,"provider":"claude","model":"fixture"})
            )
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(engine.unsaved_threads[&id], json!({"fixture":"pending"}));
    assert_eq!(engine.revision, revision);
}

#[test]
fn catalog_routes_reject_account_path_and_turn_options_without_mutation_or_launch() {
    let (_dir, mut engine, id) = fixture();
    let before = engine.store.thread(&id).unwrap();
    let revision = engine.revision;
    for params in [
        json!({"provider":"codex","accountId":"named"}),
        json!({"provider":"codex","executable":"/untrusted"}),
        json!({"provider":"codex","effort":null}),
        json!({"provider":"claude","threadId":id}),
    ] {
        assert!(engine.execute("agent.models.refresh", &params).is_err());
        assert_eq!(engine.revision, revision);
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert!(engine.runs.is_empty());
    }
    let refresh = engine
        .execute(
            "agent.models.refresh",
            &json!({"provider":"cursor","accountId":"default"}),
        )
        .unwrap();
    assert_eq!(refresh["state"], "unsupported");
    assert_eq!(refresh["accountID"], "default");
    assert_eq!(refresh["models"], json!([]));
    let status = engine
        .execute(
            "agent.models.status",
            &json!({"requestId":refresh["requestId"]}),
        )
        .unwrap();
    assert_eq!(status, refresh);
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert!(engine.runs.is_empty());
    assert!(
        engine
            .execute(
                "agent.models.status",
                &json!({"requestId":refresh["requestId"],"executable":"/untrusted"})
            )
            .is_err()
    );
}
