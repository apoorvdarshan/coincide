use coincide_core::composer_policy::*;
use serde_json::{Value, json};
fn thread() -> Value {
    json!({"selection":{"provider":"codex","modelID":"default","accountID":""},"accessMode":"approval","interactionMode":"build","unknown":{"keep":true}})
}
#[test]
fn approval_build_default_baseline_is_exact_and_source_is_immutable() {
    let value = thread();
    let before = value.clone();
    let policy = Policy::parse(&value, Origin::Ordinary).unwrap();
    assert_eq!(
        policy
            .codex_turn_fields("source", None, CollaborationHistory::NeverApplied)
            .unwrap(),
        json!({"approvalPolicy":"untrusted","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly"}})
    );
    assert_eq!(value, before);
}
#[test]
fn explicit_plan_and_full_access_use_actual_swift_schema_without_effort_speed_or_guessed_model() {
    let mut value = thread();
    value["selection"]["modelID"] = json!("fixture-exact-model");
    value["accessMode"] = json!("fullAccess");
    value["interactionMode"] = json!("plan");
    let before = value.clone();
    let policy = Policy::parse(&value, Origin::Ordinary).unwrap();
    assert_eq!(
        policy
            .codex_turn_fields("source", None, CollaborationHistory::NeverApplied)
            .unwrap(),
        json!({"model":"fixture-exact-model","approvalPolicy":"never","approvalsReviewer":"user","sandboxPolicy":{"type":"dangerFullAccess"},"collaborationMode":{"mode":"plan","settings":{"model":"fixture-exact-model","reasoning_effort":null,"developer_instructions":null}}})
    );
    assert_eq!(value, before);
}
#[test]
fn default_plan_and_clearing_sticky_plan_require_source_bound_resolved_model() {
    let mut value = thread();
    value["interactionMode"] = json!("plan");
    let plan = Policy::parse(&value, Origin::Ordinary).unwrap();
    assert!(
        plan.codex_turn_fields("source", None, CollaborationHistory::NeverApplied)
            .is_err()
    );
    let resolved = ResolvedCodexModel::from_thread_result(
        "source",
        &json!({"thread":{"id":"source"},"model":"fixture-provider-model","unknown":42}),
    )
    .unwrap();
    assert_eq!(
        plan.codex_turn_fields(
            "source",
            Some(&resolved),
            CollaborationHistory::NeverApplied
        )
        .unwrap()["collaborationMode"]["settings"]["model"],
        "fixture-provider-model"
    );
    assert!(
        plan.codex_turn_fields(
            "different",
            Some(&resolved),
            CollaborationHistory::NeverApplied
        )
        .is_err()
    );
    value["interactionMode"] = json!("build");
    let build = Policy::parse(&value, Origin::Ordinary).unwrap();
    for history in [
        CollaborationHistory::PreviouslyApplied,
        CollaborationHistory::Unknown,
    ] {
        assert!(build.codex_turn_fields("source", None, history).is_err());
        let fields = build
            .codex_turn_fields("source", Some(&resolved), history)
            .unwrap();
        assert_eq!(fields["collaborationMode"]["mode"], "default");
    }
}
#[test]
fn malformed_or_alias_resolved_models_cannot_authorize_collaboration_mode() {
    for model in [
        Value::Null,
        json!("default"),
        json!(""),
        json!(" model "),
        json!("--flag"),
        json!("line\nmodel"),
    ] {
        assert!(
            ResolvedCodexModel::from_thread_result(
                "source",
                &json!({"thread":{"id":"source"},"model":model})
            )
            .is_err()
        );
    }
    assert!(
        ResolvedCodexModel::from_thread_result(
            "source",
            &json!({"thread":{"id":"other"},"model":"fixture"})
        )
        .is_err()
    );
}
#[test]
fn other_provider_modes_effort_speed_named_accounts_and_imports_fail_without_downgrade() {
    for provider in ["claude", "cursor", "grok", "opencode", "antigravity"] {
        for (key, value) in [("accessMode", "fullAccess"), ("interactionMode", "plan")] {
            let mut source = thread();
            source["selection"]["provider"] = json!(provider);
            source[key] = json!(value);
            let before = source.clone();
            assert!(Policy::parse(&source, Origin::Ordinary).is_err());
            assert_eq!(source, before);
        }
    }
    for (key, value) in [
        ("effort", json!("high")),
        ("speed", json!("fast")),
        ("accountID", json!("named")),
        ("future", json!(true)),
    ] {
        let mut source = thread();
        source["selection"][key] = value;
        assert!(Policy::parse(&source, Origin::Ordinary).is_err());
    }
    assert!(Policy::parse(&thread(), Origin::Imported).is_err());
}
#[test]
fn frozen_bot_snapshot_never_gains_full_access_or_plan_even_with_resolved_model() {
    let mut source = thread();
    source["rustBotContext"] = json!({"selection":source["selection"],"unknown":"keep"});
    let before = source.clone();
    assert!(Policy::parse(&source, Origin::FrozenBot).is_ok());
    assert_eq!(source, before);
    for origin in [Origin::FrozenBot, Origin::Ordinary] {
        for (key, value) in [("accessMode", "fullAccess"), ("interactionMode", "plan")] {
            let mut changed = source.clone();
            changed[key] = json!(value);
            assert!(Policy::parse(&changed, origin).is_err());
        }
    }
    source["selection"]["modelID"] = json!("different");
    assert!(Policy::parse(&source, Origin::FrozenBot).is_err());
}
