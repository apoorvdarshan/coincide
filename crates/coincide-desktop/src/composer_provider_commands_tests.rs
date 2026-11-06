//! Actual Engine/Store selection gateway, with a cleared private child and no
//! provider execution. Availability means the current static runtime contract,
//! never discovered/authenticated readiness or a restored model/account grant.
use super::*;
use crate::composer_commands::{Command, Submission, intercept, standalone};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command as ProcessCommand,
};

struct Fixture {
    engine: Engine,
    id: String,
    other: Value,
}
fn fixture(root: &Path) -> Fixture {
    fs::create_dir_all(root).unwrap();
    let mut engine = Engine::new(Store::open(&root.join("state.sqlite")).unwrap());
    let project = selection_response(
        &mut engine,
        "projects.create",
        json!({"path":root,"name":"Synthetic provider commands"}),
    )
    .unwrap();
    let thread = selection_response(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    )
    .unwrap();
    let other = selection_response(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    )
    .unwrap();
    let id = text(&thread, "id");
    let mut thread = thread;
    thread["selection"] = json!({"provider":"claude","modelID":"previous-model"});
    thread["accessMode"] = json!("approval");
    thread["interactionMode"] = json!("build");
    thread["draft"] = json!(" /CoDeX\n");
    thread["draftContext"] = json!([]);
    thread["rustDraftImages"] = json!([]);
    thread["items"] = json!([{"id":uuid::Uuid::new_v4(),"kind":"assistant","provider":"codex","modelID":"historical-unverified-model","text":"Synthetic café 中文 history","future":{"keep":true}}]);
    thread["sessions"] =
        json!({"claude":{"sessionID":"synthetic-old-session","future":{"keep":true}}});
    thread["future"] = json!({"retained":[true,42]});
    engine.store.save(&thread).unwrap();
    engine
        .store
        .save_document(
            "provider-command-fixture.json",
            &json!({"future":{"keep":true}}),
        )
        .unwrap();
    engine.set_active_thread(Some(id.clone())).unwrap();
    Fixture { engine, id, other }
}
fn saved(f: &Fixture) -> Value {
    f.engine.store.thread(&f.id).unwrap()
}
fn submission(f: &Fixture) -> Submission {
    let t = saved(f);
    Submission::new(&t, t["draft"].as_str().unwrap())
}
fn assert_no_execution(f: &mut Fixture) {
    if f.engine.admissions_frozen() {
        let refused = f
            .engine
            .dispatch(json!({"method":"app.status","params":{}}));
        assert_eq!(refused["error"]["message"], "Engine admissions are frozen");
        assert!(refused.get("result").is_none());
    } else {
        let status = selection_response(&mut f.engine, "app.status", json!({})).unwrap();
        assert!(status["running"].as_array().unwrap().is_empty());
    }
    let providers = f.engine.provider_workers_status();
    assert_eq!(providers.running, 0);
    assert_eq!(providers.returned, 0);
    assert_eq!(providers.panicked, 0);
    assert_eq!(providers.unclassified, 0);
    // This is the final assertion for each private Engine. The owned catalog
    // shutdown ledger is readable only after admissions have been frozen.
    f.engine.freeze_admissions();
    let reads = f.engine.model_catalog_shutdown_status().unwrap();
    assert_eq!(reads.running, 0);
    assert_eq!(reads.returned, 0);
    assert_eq!(reads.panicked, 0);
    assert_eq!(reads.unclassified, 0);
    assert_eq!(
        f.engine.store.thread(&text(&f.other, "id")).unwrap(),
        f.other
    );
    assert_eq!(
        f.engine
            .store
            .document("provider-command-fixture.json")
            .unwrap(),
        Some(json!({"future":{"keep":true}}))
    );
}

#[::core::prelude::v1::test]
fn provider_commands_select_without_send_in_private_child() {
    let root = std::env::temp_dir().join(format!(
        "coincide-provider-command-{}",
        uuid::Uuid::new_v4()
    ));
    fs::create_dir(&root).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    }
    fs::create_dir(root.join("home")).unwrap();
    fs::create_dir(root.join("tmp")).unwrap();
    fs::create_dir(root.join("empty-path")).unwrap();
    let out = ProcessCommand::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "composer_selection::provider_command_tests::provider_commands_engine_child",
            "--nocapture",
        ])
        .env_clear()
        .env("HOME", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("PATH", root.join("empty-path"))
        .env("COINCIDE_PROVIDER_COMMAND_ROOT", &root)
        .current_dir(&root)
        .output()
        .unwrap();
    fs::remove_dir_all(&root).unwrap();
    assert!(
        out.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("1 passed"),
        "actual Engine child must run"
    );
}

#[::core::prelude::v1::test]
#[ignore = "Outer test owns a cleared private HOME/PATH and never launches a provider"]
fn provider_commands_engine_child() {
    let root = PathBuf::from(
        std::env::var_os("COINCIDE_PROVIDER_COMMAND_ROOT").expect("run private wrapper"),
    );
    let mut f = fixture(&root.join("success"));
    let before = saved(&f);
    let pending = submission(&f);
    let command = intercept(&before, &pending.draft, |c| c).unwrap();
    assert_eq!(command, Command::Provider("codex"));
    let actual = engine_command_transaction(&mut f.engine, &pending, command, false, None).unwrap();
    let mut expected = before.clone();
    expected["rustProviderSelections"] = json!({"claude": before["selection"]});
    expected["rustAccountSelections"]["claude/default"] = before["selection"].clone();
    expected["selection"]["provider"] = json!("codex");
    expected["selection"]["modelID"] = json!("default");
    expected["draft"] = json!("");
    assert_eq!(actual, expected);
    assert_eq!(saved(&f), expected);
    assert_no_execution(&mut f);

    // Missing/null modes retain their exact stored shape on acknowledged switch.
    let mut f = fixture(&root.join("null-modes"));
    let mut t = saved(&f);
    t.as_object_mut().unwrap().remove("accessMode");
    t["interactionMode"] = Value::Null;
    f.engine.store.save(&t).unwrap();
    let pending = submission(&f);
    let actual = engine_command_transaction(
        &mut f.engine,
        &pending,
        Command::Provider("codex"),
        false,
        None,
    )
    .unwrap();
    let mut expected = t.clone();
    expected["rustProviderSelections"] = json!({"claude": t["selection"]});
    expected["rustAccountSelections"]["claude/default"] = t["selection"].clone();
    expected["selection"]["provider"] = json!("codex");
    expected["selection"]["modelID"] = json!("default");
    expected["draft"] = json!("");
    assert_eq!(actual, expected);
    assert_no_execution(&mut f);

    for case in [
        "busy",
        "same-provider",
        "configured-target",
        "unsupported-target",
        "named-source",
        "unknown-selection",
        "effort",
        "speed",
        "stale-draft",
        "stale-selection",
        "inactive",
        "closing",
    ] {
        let mut f = fixture(&root.join(case));
        let pending = submission(&f);
        let mut command = Command::Provider("codex");
        match case {
            "same-provider" => command = Command::Provider("claude"),
            "configured-target" => command = Command::Provider("antigravity"),
            "unsupported-target" => command = Command::Provider("unknown-runtime"),
            "named-source" => {
                let mut t = saved(&f);
                t["selection"]["accountID"] = json!(uuid::Uuid::new_v4());
                f.engine.store.save(&t).unwrap();
            }
            "unknown-selection" => {
                let mut t = saved(&f);
                t["selection"]["future"] = json!({"opaque":17});
                f.engine.store.save(&t).unwrap();
            }
            "effort" => {
                let mut t = saved(&f);
                t["selection"]["effort"] = json!("high");
                f.engine.store.save(&t).unwrap();
            }
            "speed" => {
                let mut t = saved(&f);
                t["selection"]["speed"] = json!("priority");
                f.engine.store.save(&t).unwrap();
            }
            "stale-draft" => {
                let mut t = saved(&f);
                t["draft"] = json!("newer unsent café");
                f.engine.store.save(&t).unwrap();
            }
            "stale-selection" => {
                let mut t = saved(&f);
                t["selection"]["modelID"] = json!("external");
                f.engine.store.save(&t).unwrap();
            }
            "inactive" => f
                .engine
                .set_active_thread(Some(text(&f.other, "id")))
                .unwrap(),
            "closing" => f.engine.freeze_admissions(),
            _ => {}
        }
        let pending = if matches!(
            case,
            "named-source" | "unknown-selection" | "effort" | "speed"
        ) {
            submission(&f)
        } else {
            pending
        };
        let before = saved(&f);
        assert!(
            engine_command_transaction(&mut f.engine, &pending, command, case == "busy", None)
                .is_err(),
            "{case}"
        );
        assert_eq!(saved(&f), before, "{case}: saved data must survive refusal");
        assert_no_execution(&mut f);
    }

    let mut f = fixture(&root.join("incompatible-modes"));
    let mut t = saved(&f);
    t["selection"]["provider"] = json!("codex");
    t["accessMode"] = json!("fullAccess");
    f.engine.store.save(&t).unwrap();
    let pending = submission(&f);
    let before = saved(&f);
    assert!(
        engine_command_transaction(
            &mut f.engine,
            &pending,
            Command::Provider("claude"),
            false,
            None
        )
        .is_err()
    );
    assert_eq!(saved(&f), before);
    assert_no_execution(&mut f);

    // Origin protection comes from the actual imported-thread marker, not a
    // claimed JSON flag. Source bytes and original captured metadata survive.
    let source = root.join("legacy-source");
    fs::create_dir_all(source.join("threads")).unwrap();
    let imported_id = uuid::Uuid::new_v4().to_string();
    let imported = json!({"id":imported_id,"title":"Synthetic imported","items":[],"draft":"/codex","selection":{"provider":"claude","modelID":"default"},"accessMode":"approval","interactionMode":"build","future":{"keep":true}});
    let bytes = serde_json::to_vec_pretty(&imported).unwrap();
    let source_file = source.join("threads").join(format!("{imported_id}.json"));
    fs::write(&source_file, &bytes).unwrap();
    let mut store = Store::open(&root.join("imported/state.sqlite")).unwrap();
    store.import_legacy(&source).unwrap();
    let mut engine = Engine::new(store);
    engine.set_active_thread(Some(imported_id.clone())).unwrap();
    assert!(engine.store.is_imported(&imported_id).unwrap());
    let before = engine.store.thread(&imported_id).unwrap();
    let pending = Submission::new(&before, "/codex");
    assert!(
        engine_command_transaction(
            &mut engine,
            &pending,
            Command::Provider("codex"),
            false,
            None
        )
        .is_err()
    );
    assert_eq!(engine.store.thread(&imported_id).unwrap(), before);
    assert_eq!(fs::read(source_file).unwrap(), bytes);

    for raw in [
        "/codex extra text",
        "/claude\nmore",
        "/codex/path",
        "/unknown",
    ] {
        assert!(standalone(raw).is_none());
    }
    for field in ["draftContext", "rustDraftImages"] {
        let mut t = before.clone();
        t[field] = json!([{"future":"literal content"}]);
        assert!(intercept(&t, "/codex", |_| panic!("content must remain literal")).is_none());
    }
}

#[::core::prelude::v1::test]
fn provider_acknowledgement_must_match_target_before_command_clear() {
    let thread = json!({"id":"synthetic","draft":"/codex","selection":{"provider":"claude","modelID":"default"},"accessMode":"approval","interactionMode":"build"});
    let pending = Submission::new(&thread, "/codex");
    let caps = coincide_core::composer_selection::capabilities();
    let mut calls = Vec::new();
    let result = command_transaction(
        &pending,
        Command::Provider("codex"),
        false,
        None,
        |method, _| {
            calls.push(method.to_owned());
            match method {
                "threads.read" => Ok(thread.clone()),
                "agent.selection.capabilities" => Ok(caps.clone()),
                "agent.provider.select" => Ok(
                    json!({"thread":thread,"model":"default","restored":false,"provenance":"provider_default","authenticationChecked":false,"accountRestored":false}),
                ),
                _ => panic!("must not clear, send or refresh after wrong acknowledgement"),
            }
        },
    );
    assert!(result.is_err());
    assert_eq!(
        calls,
        vec![
            "threads.read",
            "agent.selection.capabilities",
            "agent.provider.select"
        ]
    );
}

#[::core::prelude::v1::test]
fn restored_model_receipt_must_match_saved_selection_before_draft_clear() {
    for mismatched in [false, true] {
        let mut thread = json!({"id":"synthetic","draft":"/codex","selection":{"provider":"claude","modelID":"default"},"accessMode":"approval","interactionMode":"build"});
        let pending = Submission::new(&thread, "/codex");
        let caps = coincide_core::composer_selection::capabilities();
        let mut calls = Vec::new();
        let result = command_transaction(
            &pending,
            Command::Provider("codex"),
            false,
            None,
            |method, p| {
                calls.push(method.to_owned());
                match method {
                    "threads.read" => Ok(thread.clone()),
                    "agent.selection.capabilities" => Ok(caps.clone()),
                    "agent.provider.select" => {
                        assert_eq!(p["expected"], pending.thread);
                        thread["selection"]["provider"] = json!("codex");
                        thread["selection"]["modelID"] = json!("reported-history-model");
                        Ok(
                            json!({"thread":thread,"model":if mismatched { "wrong-model" }else{ "reported-history-model" },"restored":true,"provenance":"latest_default_catalog","authenticationChecked":false,"accountRestored":false}),
                        )
                    }
                    "threads.patch" => {
                        assert!(!mismatched, "a mismatched receipt must retain the draft");
                        assert_eq!(p["patch"], json!({"draft":""}));
                        thread["draft"] = json!("");
                        Ok(thread.clone())
                    }
                    _ => panic!("provider switch must not refresh, send or queue"),
                }
            },
        );
        assert_eq!(result.is_ok(), !mismatched);
        assert_eq!(thread["draft"], if mismatched { "/codex" } else { "" });
        assert_eq!(
            calls
                .iter()
                .filter(|method| *method == "threads.patch")
                .count(),
            usize::from(!mismatched)
        );
    }
}

#[::core::prelude::v1::test]
fn named_restore_pending_retains_command_and_retry_binds_exact_request() {
    let thread = json!({"id":"synthetic","draft":"/codex","selection":{"provider":"claude","modelID":"default"},"sessions":{"codex":{"accountID":"synthetic-account-a","sessionID":"old-native"}},"accessMode":"approval","interactionMode":"build"});
    let mut pending = Submission::new(&thread, "/codex");
    for retry in [false, true] {
        if retry {
            pending.restore_request = Some("synthetic-request".into());
        }
        let mut calls = Vec::new();
        let result = command_transaction(&pending, Command::Provider("codex"), false, None, |method, params| {
            calls.push(method.to_owned());
            match method {
                "threads.read" => Ok(thread.clone()),
                "agent.selection.capabilities" => Ok(coincide_core::composer_selection::capabilities()),
                "agent.provider.select" => {
                    assert_eq!(params["expected"], pending.thread);
                    assert_eq!(params["restoreRequestId"], if retry { json!("synthetic-request") } else { Value::Null });
                    Ok(json!({"pending":true,"requestId":"synthetic-request","provider":"codex","accountID":"synthetic-account-a","authenticationChecked":false}))
                }
                _ => panic!("a pending restoration must not clear, send, queue or discover independently"),
            }
        }).unwrap();
        assert_eq!(result["pending"], true);
        assert_eq!(
            calls,
            vec![
                "threads.read",
                "agent.selection.capabilities",
                "agent.provider.select"
            ]
        );
        assert_eq!(thread["draft"], "/codex");
    }
}

#[::core::prelude::v1::test]
fn named_restore_clears_only_exact_acknowledged_command() {
    for mismatch in [
        "none",
        "account",
        "receipt-account",
        "model",
        "authentication",
        "mode",
        "content",
        "provenance",
    ] {
        let mut thread = json!({"id":"synthetic","draft":" /codex\n","selection":{"provider":"claude","modelID":"default"},"sessions":{"codex":{"accountID":"synthetic-account-a","sessionID":"old-native"}},"accessMode":"approval","interactionMode":"build","future":{"keep":true}});
        let pending = Submission::new(&thread, " /codex\n");
        let mut clears = 0;
        let result = command_transaction(
            &pending,
            Command::Provider("codex"),
            false,
            None,
            |method, params| match method {
                "threads.read" => Ok(thread.clone()),
                "agent.selection.capabilities" => {
                    Ok(coincide_core::composer_selection::capabilities())
                }
                "agent.provider.select" => {
                    thread["selection"] = json!({"provider":"codex","modelID":"synthetic-a","accountID":"synthetic-account-a"});
                    if mismatch == "account" {
                        thread["selection"]["accountID"] = json!("synthetic-account-b");
                    }
                    if mismatch == "model" {
                        thread["selection"]["modelID"] = json!("synthetic-b");
                    }
                    if mismatch == "mode" {
                        thread["accessMode"] = json!("fullAccess");
                    }
                    if mismatch == "content" {
                        thread["draft"] = json!("newer unsent text");
                    }
                    Ok(
                        json!({"thread":thread,"accountID":if mismatch=="receipt-account"{"synthetic-account-b"}else{"synthetic-account-a"},"model":"synthetic-a","restored":true,"accountRestored":true,"authenticationChecked":mismatch!="authentication","provenance":if mismatch=="provenance"{"latest_default_catalog"}else{"latest_authenticated_named_catalog"}}),
                    )
                }
                "threads.patch" => {
                    assert_eq!(mismatch, "none");
                    assert_eq!(params["patch"], json!({"draft":""}));
                    clears += 1;
                    thread["draft"] = json!("");
                    Ok(thread.clone())
                }
                _ => panic!("restore completion must not launch or refresh a provider"),
            },
        );
        assert_eq!(result.is_ok(), mismatch == "none", "{mismatch}");
        assert_eq!(clears, usize::from(mismatch == "none"), "{mismatch}");
        assert_eq!(thread["future"], json!({"keep":true}));
        if mismatch != "none" && mismatch != "content" {
            assert_eq!(thread["draft"], " /codex\n");
        }
    }
}

#[::core::prelude::v1::test]
fn unavailable_source_catalog_does_not_block_switching_to_another_provider() {
    let mut thread = json!({"id":"synthetic","draft":"/claude","selection":{"provider":"codex","modelID":"synthetic-a","accountID":"account-a","effort":"high"},"accessMode":"approval","interactionMode":"build"});
    let pending = Submission::new(&thread, "/claude");
    let mut caps = coincide_core::composer_selection::capabilities();
    caps["locked"] = json!(true);
    caps["lockReason"] = json!("Saved named catalog was revoked after restart");
    let mut clears = 0;
    let result = command_transaction(
        &pending,
        Command::Provider("claude"),
        false,
        None,
        |method, params| match method {
            "threads.read" => Ok(thread.clone()),
            "agent.selection.capabilities" => Ok(caps.clone()),
            "agent.provider.select" => {
                thread["selection"] = json!({"provider":"claude","modelID":"default"});
                Ok(
                    json!({"thread":thread,"model":"default","restored":false,"accountRestored":false,"authenticationChecked":false,"provenance":"provider_default"}),
                )
            }
            "threads.patch" => {
                assert_eq!(params["patch"], json!({"draft":""}));
                clears += 1;
                thread["draft"] = json!("");
                Ok(thread.clone())
            }
            _ => panic!("switch-away must not refresh the old account or start a turn"),
        },
    );
    assert!(result.is_ok());
    assert_eq!(clears, 1);
    assert_eq!(thread["selection"]["provider"], "claude");
}

#[::core::prelude::v1::test]
fn fallback_receipts_bind_original_intent_each_candidate_and_explicit_account_scope() {
    let thread = json!({"id":"synthetic","selection":{"provider":"claude","modelID":"default"},"sessions":{"codex":{"accountID":"account-a"}}});
    let pending = json!({"pending":true,"requestId":"intent-a","catalogRequestId":"observation-default","provider":"codex","accountID":"default","requestedAccountID":"account-a","explicitAccount":false,"candidateAccountIDs":["account-a","default","account-b"],"fallback":true,"authenticationChecked":false});
    assert!(restore_receipt_scope(&pending, &thread, "codex", None, Some("intent-a")).is_ok());
    for fault in ["token", "requested", "candidate", "explicit", "fallback"] {
        let mut bad = pending.clone();
        match fault {
            "token" => bad["requestId"] = json!("another-intent"),
            "requested" => bad["requestedAccountID"] = json!("account-b"),
            "candidate" => bad["accountID"] = json!("unknown-account"),
            "explicit" => bad["explicitAccount"] = json!(true),
            "fallback" => bad["fallback"] = json!(false),
            _ => unreachable!(),
        }
        assert!(
            restore_receipt_scope(&bad, &thread, "codex", None, Some("intent-a")).is_err(),
            "{fault}"
        );
    }
    assert!(
        restore_receipt_scope(
            &pending,
            &thread,
            "codex",
            Some(&json!("account-a")),
            Some("intent-a")
        )
        .is_err(),
        "an explicit account pick cannot silently fall back"
    );
    let ready = json!({"requestId":"intent-a","accountID":"account-b","requestedAccountID":"account-a","explicitAccount":false,"candidateAccountIDs":["account-a","default","account-b"],"fallback":true,"authenticationChecked":true,"accountRestored":true,"restored":true,"model":"synthetic-b","provenance":"latest_authenticated_named_catalog"});
    assert_eq!(
        restore_receipt_scope(&ready, &thread, "codex", None, Some("intent-a")).unwrap(),
        json!("account-b")
    );
    let mut borrowed = ready;
    borrowed["provenance"] = json!("latest_default_catalog");
    assert!(restore_receipt_scope(&borrowed, &thread, "codex", None, Some("intent-a")).is_err());
}

#[::core::prelude::v1::test]
fn saved_account_warmup_receipt_preserves_exact_selection_even_for_default_model() {
    for model in ["synthetic-low", "default"] {
        let thread = json!({"id":"synthetic","selection":{"provider":"codex","accountID":"account-a","modelID":model,"effort":if model=="default"{Value::Null}else{json!("low")}},"modelPreferences":{"codex/account-a":{"effort":"high"}}});
        let receipt = json!({"requestId":"warmup","accountID":"account-a","requestedAccountID":"account-a","candidateAccountIDs":["account-a"],"explicitAccount":false,"fallback":false,"selectionUnchanged":true,"executionReady":true,"thread":thread,"model":model,"restored":false,"accountRestored":false,"authenticationChecked":true,"provenance":"selected_account_catalog"});
        assert!(restore_receipt_scope(&receipt, &thread, "codex", None, Some("warmup")).is_ok());
        for field in ["modelID", "effort", "accountID"] {
            let mut changed = receipt.clone();
            changed["thread"]["selection"][field] = json!("different");
            assert!(
                restore_receipt_scope(&changed, &thread, "codex", None, Some("warmup")).is_err(),
                "{field}"
            );
        }
        let mut unavailable = receipt.clone();
        unavailable["executionReady"] = json!(false);
        unavailable["reason"] = json!("Saved model unavailable");
        assert!(
            restore_receipt_scope(&unavailable, &thread, "codex", None, Some("warmup")).is_ok(),
            "an observed catalog can be available while Send remains proof-locked"
        );
    }
}
