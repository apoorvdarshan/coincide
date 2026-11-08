use coincide_core::composer_selection::{capabilities, default_account, select, validate_thread};
use serde_json::{Value, json};

fn thread() -> Value {
    json!({"id":"fixture","selection":{"provider":"codex","modelID":"default"},
        "accessMode":"approval","interactionMode":"build", "sessions":{"codex":{"sessionID":"native","seenItemCount":2}},
        "accountSessions":{"codex/other":{"sessionID":"other"}},"future":{"keep":true}})
}

#[test]
fn static_capabilities_never_claim_discovered_or_authenticated_models() {
    let value = capabilities();
    assert_eq!(value["provenance"], "static_runtime_contract");
    assert_eq!(value["authenticationChecked"], false);
    assert_eq!(value["modelsDiscovered"], false);
    assert_eq!(value["providers"].as_array().unwrap().len(), 6);
    for provider in value["providers"].as_array().unwrap() {
        assert_eq!(
            provider["models"],
            json!([{"id":"default","displayName":"Provider default","availability":"provider_resolved"}])
        );
        assert_eq!(provider["customModel"]["availability"], "unverified");
        assert_eq!(provider["effort"]["supported"], false);
        assert_eq!(provider["speed"]["supported"], false);
        assert_eq!(
            provider["accessModes"],
            if provider["provider"] == "codex" {
                json!(["approval", "fullAccess"])
            } else {
                json!(["approval"])
            }
        );
        assert_eq!(
            provider["interactionModes"],
            if provider["provider"] == "codex" {
                json!(["build", "plan"])
            } else {
                json!(["build"])
            }
        );
    }
}

#[test]
fn default_aliases_resolve_to_one_identity_without_mutating_input() {
    for alias in [Value::Null, json!(""), json!("default")] {
        let mut current = thread();
        current["selection"]["accountID"] = alias.clone();
        current["selection"]["effort"] = Value::Null;
        let before = current.clone();
        assert!(default_account(&alias));
        validate_thread(&current).unwrap();
        let selected = select(&json!({"threadId":"fixture","provider":"claude","model":"fixture-custom","accountId":alias}), &current).unwrap();
        assert_eq!(selected["provider"], "claude");
        assert_eq!(selected["modelID"], "fixture-custom");
        assert!(selected.get("accountID").is_none());
        assert!(
            selected.get("effort").is_some(),
            "supported null metadata is preserved"
        );
        assert_eq!(current, before);
    }
}

#[test]
fn unsupported_or_malformed_requests_are_atomic() {
    let current = thread();
    let before = current.clone();
    for (key, value) in [
        ("effort", json!("high")),
        ("effort", json!(false)),
        ("speed", json!("")),
        ("speed", json!([])),
        ("accessMode", json!("unknownAccess")),
        ("interactionMode", json!("plan")),
        ("accessMode", json!(0)),
        ("accessMode", Value::Null),
        ("interactionMode", Value::Null),
        ("provider", json!(false)),
        ("accountId", json!(false)),
        ("accountId", json!("other")),
        ("model", Value::Null),
        ("model", json!("")),
        ("model", json!("--flag")),
        ("model", json!("bad\nmodel")),
        ("model", json!("x".repeat(513))),
        ("futureOption", Value::Null),
    ] {
        let mut request = json!({"threadId":"fixture","provider":"codex","model":"default"});
        request[key] = value;
        assert!(select(&request, &current).is_err(), "accepted {request}");
        assert_eq!(current, before);
    }
}

#[test]
fn unsupported_saved_choices_are_never_replaced_by_defaults() {
    for (key, value) in [
        ("effort", json!("high")),
        ("speed", json!("priority")),
        ("accountID", json!("named")),
        ("accountID", json!([])),
        ("future", Value::Null),
    ] {
        let mut current = thread();
        current["selection"][key] = value;
        let before = current.clone();
        assert!(validate_thread(&current).is_err());
        assert!(select(&json!({"provider":"claude"}), &current).is_err());
        assert_eq!(current, before);
    }
    for (key, value) in [
        ("accessMode", json!("unknownAccess")),
        ("interactionMode", json!(false)),
    ] {
        let mut current = thread();
        current[key] = value;
        assert!(validate_thread(&current).is_err());
    }
}

#[test]
fn immutable_bot_snapshots_remain_exact_including_default_aliases() {
    for alias in [Value::Null, json!(""), json!("default")] {
        let mut current = thread();
        current["selection"]["accountID"] = alias;
        current["rustBotContext"] =
            json!({"selection":current["selection"],"instructions":"fixture"});
        let before = current.clone();
        assert!(
            select(&json!({"provider":"codex","model":"default"}), &current)
                .unwrap_err()
                .to_string()
                .contains("fixed")
        );
        assert_eq!(current, before);
    }
}

#[test]
fn antigravity_named_identity_is_preserved_for_engine_configuration_validation() {
    let selected = select(
        &json!({"provider":"antigravity","accountId":"fixture-account","model":"fixture-model"}),
        &thread(),
    )
    .unwrap();
    assert_eq!(selected["accountID"], "fixture-account");
    assert_eq!(selected["modelID"], "fixture-model");
    let mut next = thread();
    next["selection"] = selected;
    validate_thread(&next).unwrap();
}

#[test]
fn launch_capture_preserves_exact_custom_id_and_only_default_omits_override() {
    use coincide_core::{agent::Launch, composer_selection::launch_model};
    for model in ["default", "fixture/model-exact"] {
        let selected = select(&json!({"provider":"codex","model":model}), &thread()).unwrap();
        let captured = Launch {
            executable: "not-a-real-provider".into(),
            cwd: "/synthetic".into(),
            session: Some("fixture-session".into()),
            prompt: "fixture".into(),
            model: launch_model(&selected).unwrap(),
            variant: None,
        };
        assert_eq!(
            captured.model.as_deref(),
            (model != "default").then_some(model)
        );
        assert_eq!(captured.session.as_deref(), Some("fixture-session"));
    }
}
