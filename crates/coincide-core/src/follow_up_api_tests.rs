use super::*;
use std::sync::mpsc;
struct Fixture {
    _dir: tempfile::TempDir,
    engine: Engine,
    id: String,
    server: agent::codex_steering::Server,
    release: mpsc::Sender<()>,
    observed: mpsc::Receiver<()>,
    control: mpsc::Receiver<agent::Control>,
}

#[test]
fn captured_compaction_and_unavailable_steer_wait_in_the_queue() {
    for kind in ["compact", "unavailable"] {
        let Fixture {
            _dir,
            mut engine,
            id,
            mut server,
            release,
            control,
            ..
        } = fixture();
        let mut captured = engine.store.thread(&id).unwrap();
        if kind == "compact" {
            captured["draft"] = json!("/compact");
        } else {
            server.observe(&json!({"method":"item/started","params":{"threadId":"native-thread","turnId":"native-turn","item":{"type":"agentMessage","id":"reply"}}}));
        }
        assert!(matches!(
            engine
                .admit_captured_native_send(&captured, false, Behavior::Steer, false)
                .unwrap(),
            CapturedNativeSend::Saved {
                ticket: None,
                error: None,
                ..
            }
        ));
        assert_eq!(
            engine.store.thread(&id).unwrap()["rustMessageQueue"][0]["state"],
            "pending"
        );
        assert!(engine.runs[&id].session.goal_queue_is_waiting());
        assert!(control.try_recv().is_err());
        engine.freeze_admissions();
        finish_fake(&mut engine, &id, release);
    }
}

#[test]
fn failed_image_import_keeps_the_captured_message_for_editing_without_auto_delivery() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        control,
        ..
    } = fixture();
    let captured = engine.store.thread(&id).unwrap();
    engine
        .store
        .patch_draft(&id, "new independent draft")
        .unwrap();
    engine
        .retain_failed_captured_native_send(&captured)
        .unwrap();
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "new independent draft");
    let messages = crate::message_queue::read(&saved).unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].text, captured["draft"]);
    assert_eq!(messages[0].state, crate::message_queue::State::Failed);
    assert!(
        messages[0]
            .error
            .as_ref()
            .unwrap()
            .contains("Image import failed")
    );
    assert!(!engine.enabled_queues.contains(&id));
    assert!(control.try_recv().is_err());
    finish_fake(&mut engine, &id, release);
}

#[test]
fn captured_steer_waits_for_previous_ack_and_then_steers_without_overwriting_new_text() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let first_source = engine.store.thread(&id).unwrap();
    let first = engine.send_native_follow_up(&first_source, false).unwrap();
    let first_request = server.next_request().unwrap();
    let mut second = first_source.clone();
    second["draft"] = json!("second message");
    engine.store.patch_draft(&id, "new draft").unwrap();
    assert!(matches!(
        engine
            .admit_captured_native_send(&second, false, Behavior::Steer, false)
            .unwrap(),
        CapturedNativeSend::Waiting
    ));
    assert!(
        crate::message_queue::read(&engine.store.thread(&id).unwrap())
            .unwrap()
            .is_empty()
    );
    server.response(&json!({"id":first_request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    engine.collect_native_follow_up(first).unwrap();
    let second_ticket = match engine
        .admit_captured_native_send(&second, false, Behavior::Steer, false)
        .unwrap()
    {
        CapturedNativeSend::Saved {
            ticket: Some(ticket),
            error: None,
            ..
        } => ticket,
        _ => panic!("Second message was not steered"),
    };
    let second_request = server.next_request().unwrap();
    assert_eq!(
        second_request["params"]["input"][0]["text"],
        "second message"
    );
    server.response(&json!({"id":second_request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert!(matches!(
        engine.native_follow_up_status(&second_ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            ..
        }
    ));
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "new draft");
    assert_eq!(saved["rustMessageQueue"][0]["state"], "completed");
    assert_eq!(
        saved["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["text"] == "second message")
            .count(),
        1
    );
    engine.collect_native_follow_up(second_ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn captured_queue_and_interrupt_respect_mode_for_every_provider() {
    for provider in [
        "codex",
        "claude",
        "opencode",
        "cursor",
        "grok",
        "antigravity",
    ] {
        for behavior in [Behavior::Queue, Behavior::Interrupt] {
            let Fixture {
                _dir,
                mut engine,
                id,
                release,
                control,
                ..
            } = fixture();
            let mut captured = engine.store.thread(&id).unwrap();
            captured["selection"] = json!({"provider":provider,"modelID":"default"});
            engine.store.save(&captured).unwrap();
            let run = engine.runs.get_mut(&id).unwrap();
            run.provider = provider.into();
            run.usage_context = Some(agent::usage_capture::TurnContext::new(&captured));
            let result = engine
                .admit_captured_native_send(&captured, false, behavior, false)
                .unwrap();
            match (behavior, result) {
                (
                    Behavior::Queue,
                    CapturedNativeSend::Saved {
                        ticket: None,
                        error: None,
                        ..
                    },
                ) => {
                    assert!(control.try_recv().is_err(), "queue stopped {provider}");
                }
                (
                    Behavior::Interrupt,
                    CapturedNativeSend::Saved {
                        ticket: Some(ticket),
                        error: None,
                        ..
                    },
                ) => {
                    assert!(
                        matches!(
                            control.recv_timeout(Duration::from_secs(5)).unwrap(),
                            agent::Control::Stop
                        ),
                        "{provider}"
                    );
                    assert_eq!(
                        engine.native_follow_up_status(&ticket).unwrap(),
                        NativeFollowUpStatus::Pending
                    );
                }
                _ => panic!("{provider} {behavior:?} did not retain its mode"),
            }
            let saved = engine.store.thread(&id).unwrap();
            assert_eq!(saved["draft"], captured["draft"], "{provider}");
            assert_eq!(crate::message_queue::read(&saved).unwrap().len(), 1);
            engine.freeze_admissions();
            finish_fake(&mut engine, &id, release);
        }
    }
}

#[test]
fn captured_sends_do_not_overtake_an_older_queued_message_or_a_model_change() {
    for change in ["older queue", "model"] {
        let Fixture {
            _dir,
            mut engine,
            id,
            release,
            control,
            ..
        } = fixture();
        let captured = engine.store.thread(&id).unwrap();
        let mut current = captured.clone();
        if change == "model" {
            current["selection"]["modelID"] = json!("different");
        } else {
            crate::message_queue::add(&mut current, "older queued message").unwrap();
        }
        engine.store.save(&current).unwrap();
        assert!(matches!(
            engine
                .admit_captured_native_send(&captured, false, Behavior::Interrupt, false)
                .unwrap(),
            CapturedNativeSend::Saved {
                ticket: None,
                error: None,
                ..
            }
        ));
        assert!(control.try_recv().is_err());
        let queue = crate::message_queue::read(&engine.store.thread(&id).unwrap()).unwrap();
        assert_eq!(queue.last().unwrap().selection, captured["selection"]);
        if change == "older queue" {
            assert_eq!(queue[0].text, "older queued message");
        }
        engine.freeze_admissions();
        finish_fake(&mut engine, &id, release);
    }
}

#[test]
fn captured_pending_send_is_queued_without_consuming_a_new_draft() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        ..
    } = fixture();
    let captured = engine.store.thread(&id).unwrap();
    let mut newer = captured.clone();
    newer["draft"] = json!("new independent draft");
    engine.store.save(&newer).unwrap();
    assert_eq!(
        engine.queue_captured_native_send(&captured, false).unwrap(),
        (true, false)
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "new independent draft");
    let queued = crate::message_queue::read(&saved).unwrap();
    assert_eq!(queued.len(), 1);
    assert_eq!(queued[0].text, "synthetic redirect");
    assert_eq!(queued[0].selection, captured["selection"]);
    release.send(()).unwrap();
}

#[test]
fn captured_sends_keep_order_for_every_provider_without_consuming_the_next_draft() {
    for provider in [
        "codex",
        "claude",
        "opencode",
        "cursor",
        "grok",
        "antigravity",
    ] {
        let Fixture {
            _dir,
            mut engine,
            id,
            release,
            ..
        } = fixture();
        let mut first = engine.store.thread(&id).unwrap();
        first["selection"] = json!({"provider":provider,"modelID":"default"});
        first["draft"] = json!("first submitted message");
        engine.store.save(&first).unwrap();
        let run = engine.runs.get_mut(&id).unwrap();
        run.provider = provider.into();
        run.usage_context = Some(agent::usage_capture::TurnContext::new(&first));
        let mut second = first.clone();
        second["draft"] = json!("second submitted message");
        let mut newer = first.clone();
        newer["draft"] = json!("still typing");
        engine.store.save(&newer).unwrap();

        assert_eq!(
            engine.queue_captured_native_send(&first, false).unwrap(),
            (true, false)
        );
        assert_eq!(
            engine.queue_captured_native_send(&second, false).unwrap(),
            (true, false)
        );
        let saved = engine.store.thread(&id).unwrap();
        let queue = crate::message_queue::read(&saved).unwrap();
        assert_eq!(
            queue
                .iter()
                .map(|message| message.text.as_str())
                .collect::<Vec<_>>(),
            vec!["first submitted message", "second submitted message"],
            "{provider}"
        );
        assert!(
            queue
                .iter()
                .all(|message| message.selection == first["selection"])
        );
        assert_eq!(saved["draft"], "still typing", "{provider}");
        release.send(()).unwrap();
    }
}

#[test]
fn captured_send_follows_its_original_conversation_after_a_thread_switch() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        ..
    } = fixture();
    let captured = engine.store.thread(&id).unwrap();
    let other = engine
        .execute("threads.create", &json!({"cwd":_dir.path()}))
        .unwrap();
    let other_id = text(&other, "id");
    engine
        .store
        .patch_thread(&other_id, &json!({"draft":"other draft"}))
        .unwrap();
    engine.set_active_thread(Some(other_id.clone())).unwrap();

    assert_eq!(
        engine.queue_captured_native_send(&captured, false).unwrap(),
        (true, false)
    );
    let queue = crate::message_queue::read(&engine.store.thread(&id).unwrap()).unwrap();
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0].text, "synthetic redirect");
    assert_eq!(
        engine.store.thread(&other_id).unwrap()["draft"],
        "other draft"
    );
    assert!(
        crate::message_queue::read(&engine.store.thread(&other_id).unwrap())
            .unwrap()
            .is_empty()
    );
    release.send(()).unwrap();
}

#[test]
fn captured_send_continues_an_enabled_queue_with_a_dispatch_in_flight() {
    for enabled in [true, false] {
        let Fixture {
            _dir,
            mut engine,
            id,
            release,
            ..
        } = fixture();
        let captured = engine.store.thread(&id).unwrap();
        let mut current = captured.clone();
        crate::message_queue::add(&mut current, "earlier message").unwrap();
        current["rustMessageQueue"][0]["state"] = json!("dispatching");
        engine.store.save(&current).unwrap();
        if enabled {
            engine.enabled_queues.insert(id.clone());
        }

        assert_eq!(
            engine.queue_captured_native_send(&captured, false).unwrap(),
            (enabled, false)
        );
        assert_eq!(engine.enabled_queues.contains(&id), enabled);
        let queue = crate::message_queue::read(&engine.store.thread(&id).unwrap()).unwrap();
        assert_eq!(queue.len(), 2);
        assert_eq!(queue[1].text, "synthetic redirect");
        release.send(()).unwrap();
    }
}

#[test]
fn captured_send_with_changed_model_is_saved_but_not_auto_dispatched() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        ..
    } = fixture();
    let captured = engine.store.thread(&id).unwrap();
    let mut newer = captured.clone();
    newer["draft"] = json!("new draft");
    newer["selection"]["modelID"] = json!("other-model");
    engine.store.save(&newer).unwrap();
    assert_eq!(
        engine.queue_captured_native_send(&captured, false).unwrap(),
        (false, false)
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "new draft");
    assert_eq!(saved["selection"], newer["selection"]);
    assert_eq!(
        crate::message_queue::read(&saved).unwrap()[0].selection,
        captured["selection"]
    );
    assert!(!engine.enabled_queues.contains(&id));
    release.send(()).unwrap();
}

#[test]
fn captured_send_clears_only_the_unchanged_submitted_draft() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        ..
    } = fixture();
    let captured = engine.store.thread(&id).unwrap();
    let mut newer = captured.clone();
    newer["selection"]["modelID"] = json!("other-model");
    engine.store.save(&newer).unwrap();
    assert_eq!(
        engine.queue_captured_native_send(&captured, true).unwrap(),
        (false, true)
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "");
    assert_eq!(
        crate::message_queue::read(&saved).unwrap()[0].text,
        "synthetic redirect"
    );
    release.send(()).unwrap();
}

#[test]
fn captured_send_preserves_an_identical_retyped_draft() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        ..
    } = fixture();
    let captured = engine.store.thread(&id).unwrap();
    let mut retyped = captured.clone();
    retyped["selection"]["modelID"] = json!("other-model");
    engine.store.save(&retyped).unwrap();
    assert_eq!(
        engine.queue_captured_native_send(&captured, false).unwrap(),
        (false, false)
    );
    assert_eq!(
        engine.store.thread(&id).unwrap()["draft"],
        "synthetic redirect"
    );
    release.send(()).unwrap();
}

#[test]
fn captured_send_never_borrows_changed_access_or_restarts_a_paused_queue() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        ..
    } = fixture();
    let captured = engine.store.thread(&id).unwrap();
    let mut newer = captured.clone();
    newer["accessMode"] = json!("fullAccess");
    engine.store.save(&newer).unwrap();
    assert!(engine.queue_captured_native_send(&captured, false).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), newer);
    newer["accessMode"] = captured["accessMode"].clone();
    crate::message_queue::add(&mut newer, "previous paused item").unwrap();
    engine.store.save(&newer).unwrap();
    assert_eq!(
        engine.queue_captured_native_send(&captured, false).unwrap(),
        (false, false)
    );
    assert!(!engine.enabled_queues.contains(&id));
    assert_eq!(
        crate::message_queue::read(&engine.store.thread(&id).unwrap())
            .unwrap()
            .len(),
        2
    );
    release.send(()).unwrap();
}
fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let thread = engine
        .execute("threads.create", &json!({"cwd":dir.path()}))
        .unwrap();
    let id = text(&thread, "id");
    let mut thread = engine.store.thread(&id).unwrap();
    thread["selection"] = json!({"provider":"codex","modelID":"default"});
    thread["draft"] = json!("synthetic redirect");
    engine.store.save(&thread).unwrap();
    engine.set_active_thread(Some(id.clone())).unwrap();
    let (release, held) = mpsc::channel();
    let (finished, observed) = mpsc::channel();
    let (control_sent, control) = mpsc::channel();
    let mut session = Session::fixture_worker(move |commands, events| {
        while let Ok(command) = commands.recv() {
            let stopping = matches!(command, agent::Control::Stop);
            let _ = control_sent.send(command);
            if stopping {
                break;
            }
        }
        let _ = events.send(Event::Finished);
        let _ = finished.send(());
        let _ = held.recv();
    });
    let mut server = session.fixture_steering();
    server.activate("native-thread", "native-turn");
    engine.insert_running(
        id.clone(),
        Running {
            configuration: None,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            session,
            usage_context: Some(agent::usage_capture::TurnContext::new(&thread)),
            provider: "codex".into(),
            transcript_start: 0,
            pending: HashMap::new(),
            schedule_claim: None,
            queue_claim: None,
            cancelled: false,
            events: VecDeque::new(),
            persistence_error: None,
        },
    );
    Fixture {
        _dir: dir,
        engine,
        id,
        server,
        release,
        observed,
        control,
    }
}
#[test]
fn native_steer_requires_actual_ack_and_persistence_before_clearing_draft() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Pending
    );
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], source["draft"]);
    let request = server.next_request().unwrap();
    assert_eq!(request["params"]["input"][0]["text"], "synthetic redirect");
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: true
        }
    );
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], "");
    assert_eq!(
        engine.store.thread(&id).unwrap()["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["steered"] == true)
            .count(),
        1
    );
    engine.collect_native_follow_up(ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn codex_compact_during_a_turn_is_queued_instead_of_steered_as_text() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    engine
        .store
        .patch_thread(&id, &json!({"draft":"/compact"}))
        .unwrap();
    let source = engine.store.thread(&id).unwrap();
    assert_eq!(
        engine.native_follow_up_dispatch(&source, false).unwrap(),
        Dispatch::Queue
    );
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Queue,
            draft_cleared: true,
        }
    );
    assert!(server.next_request().is_none());
    let queue = crate::message_queue::read(&engine.store.thread(&id).unwrap()).unwrap();
    assert_eq!(queue[0].text, "/compact");
    engine.collect_native_follow_up(ticket).unwrap();
    engine.freeze_admissions();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn goal_control_does_not_answer_an_existing_approval() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        control,
        ..
    } = fixture();
    engine
        .store
        .patch_thread(&id, &json!({"draft":"/goal pause"}))
        .unwrap();
    engine.runs.get_mut(&id).unwrap().pending.insert("approval".into(), json!({"id":77,"method":"item/commandExecution/requestApproval","params":{"availableDecisions":["accept","decline"]}}));
    let source = engine.store.thread(&id).unwrap();
    assert_eq!(
        engine.native_follow_up_dispatch(&source, false).unwrap(),
        Dispatch::Steer
    );
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    match control.recv_timeout(Duration::from_secs(5)).unwrap() {
        agent::Control::Steer { text, reply } => {
            assert_eq!(text, "/goal pause");
            reply.send(Ok(())).unwrap();
        }
        _ => panic!("goal control must not answer or stop the pending approval"),
    }
    engine.poll();
    assert!(engine.runs[&id].pending.contains_key("approval"));
    assert!(matches!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            draft_cleared: true,
            ..
        }
    ));
    engine.collect_native_follow_up(ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn staged_selection_yields_the_goal_without_discarding_queued_messages() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    engine
        .defer_goal_for_staged_selection(&source, true)
        .unwrap();
    assert!(engine.goal_selection_waiting.contains(&id));
    assert!(engine.runs[&id].session.goal_queue_is_waiting());
    let mut stale = source.clone();
    stale["selection"]["modelID"] = json!("other-model");
    assert!(
        engine
            .defer_goal_for_staged_selection(&stale, false)
            .is_err()
    );
    let mut current = engine.store.thread(&id).unwrap();
    crate::message_queue::add(&mut current, "queued message").unwrap();
    engine.store.save(&current).unwrap();
    engine.enabled_queues.insert(id.clone());
    engine
        .defer_goal_for_staged_selection(&source, false)
        .unwrap();
    assert!(!engine.goal_selection_waiting.contains(&id));
    assert!(
        engine.runs[&id].session.goal_queue_is_waiting(),
        "queue still owns the next turn"
    );
    assert_eq!(
        crate::message_queue::read(&engine.store.thread(&id).unwrap()).unwrap()[0].text,
        "queued message"
    );
    engine.freeze_admissions();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn live_turn_accepts_follow_up_without_a_new_model_catalog() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let mut thread = engine.store.thread(&id).unwrap();
    thread["selection"] = json!({"provider":"codex","modelID":"synthetic-model","effort":"high"});
    engine.store.save(&thread).unwrap();
    engine.runs.get_mut(&id).unwrap().usage_context =
        Some(agent::usage_capture::TurnContext::new(&thread));
    assert!(engine.composer_thread_effort_proof(&thread).is_err());

    let ticket = engine.send_native_follow_up(&thread, false).unwrap();
    let request = server.next_request().unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert!(matches!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered { .. }
    ));
    engine.collect_native_follow_up(ticket).unwrap();

    let mut changed = engine.store.thread(&id).unwrap();
    changed["selection"]["modelID"] = json!("other-model");
    assert!(engine.validate_native_follow_up_policy(&changed).is_err());
    finish_fake(&mut engine, &id, release);
}
#[test]
fn interrupt_waits_for_actual_return_and_refuses_changed_source_without_launch() {
    let Fixture {
        _dir,
        mut engine,
        id,
        server: _server,
        release,
        observed,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let source = engine
        .choose_native_follow_up(&source, Behavior::Interrupt)
        .unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    observed.recv_timeout(Duration::from_secs(5)).unwrap();
    for _ in 0..3 {
        engine.poll();
    }
    assert!(!engine.runs.contains_key(&id));
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Pending,
        "semantic Finished cannot release next delivery before actual join"
    );
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], source["draft"]);
    engine
        .store
        .patch_thread(&id, &json!({"draft":"edited while stopping"}))
        .unwrap();
    release.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.native_follow_up_status(&ticket).unwrap() == NativeFollowUpStatus::Pending {
        engine.poll();
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    assert!(matches!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Retained(_)
    ));
    assert!(engine.runs.is_empty());
    assert_eq!(
        engine.store.thread(&id).unwrap()["draft"],
        "edited while stopping"
    );
    assert!(engine.steering_operations.is_empty());
}
#[test]
fn approval_redirect_uses_actual_request_denials_and_alternate_queue() {
    let Fixture {
        _dir,
        mut engine,
        id,
        server: _server,
        release,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let source = engine
        .choose_native_follow_up(&source, Behavior::Interrupt)
        .unwrap();
    engine.runs.get_mut(&id).unwrap().pending.insert("real-request".into(),json!({"id":77,"method":"item/commandExecution/requestApproval","params":{"availableDecisions":["accept"]}}));
    assert_eq!(
        engine.native_follow_up_dispatch(&source, false).unwrap(),
        Dispatch::Interrupt
    );
    assert!(engine.send_native_follow_up(&source, false).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), source);
    assert!(engine.runs[&id].pending.contains_key("real-request"));
    engine.runs.get_mut(&id).unwrap().pending.clear();
    let ticket = engine.send_native_follow_up(&source, true).unwrap();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Queue,
            draft_cleared: true
        }
    );
    assert!(!engine.runs[&id].cancelled);
    engine.freeze_admissions();
    engine.poll();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn frozen_admission_abandons_pending_interrupt_and_keeps_the_saved_draft() {
    let Fixture {
        _dir,
        mut engine,
        id,
        server: _server,
        release,
        observed,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let source = engine
        .choose_native_follow_up(&source, Behavior::Interrupt)
        .unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    observed.recv_timeout(Duration::from_secs(5)).unwrap();
    engine.freeze_admissions();
    engine.poll();
    assert!(matches!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Retained(_)
    ));
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], source["draft"]);
    finish_fake(&mut engine, &id, release);
    assert!(engine.runs.is_empty());
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], source["draft"]);
    assert!(engine.send_native_follow_up(&source, false).is_err());
}

fn finish_fake(engine: &mut Engine, id: &str, release: mpsc::Sender<()>) {
    let _ = engine.request_provider_stop(id);
    let _ = release.send(());
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.provider_workers_status().running != 0 {
        engine.poll();
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
}

#[test]
fn redirect_declines_only_offered_approval_and_dismisses_question_before_actual_steer() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        control,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let source = engine
        .choose_native_follow_up(&source, Behavior::Steer)
        .unwrap();
    engine.runs.get_mut(&id).unwrap().pending.insert("approval".into(), json!({"id":77,"method":"item/commandExecution/requestApproval","params":{"availableDecisions":["accept","decline"]}}));
    engine.runs.get_mut(&id).unwrap().pending.insert("question".into(), json!({"id":78,"method":"item/tool/requestUserInput","params":{"questions":[{"id":"synthetic-question"}]}}));
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    let mut replies = HashMap::new();
    for _ in 0..2 {
        match control.recv_timeout(Duration::from_secs(5)).unwrap() {
            agent::Control::Reply { id, result } => {
                replies.insert(id.as_i64().unwrap(), result);
            }
            agent::Control::Stop => panic!("Redirect must not stop the steerable turn"),
            agent::Control::Steer { .. } => panic!("Redirect must not steer the turn"),
        }
    }
    assert_eq!(replies[&77], json!({"decision":"decline"}));
    assert_eq!(replies[&78], json!({"answers":{}}));
    assert!(engine.runs[&id].pending.is_empty());
    assert!(!engine.runs[&id].cancelled);
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], source["draft"]);
    let request = server.next_request().unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: true
        }
    );
    finish_fake(&mut engine, &id, release);
}

#[test]
fn unknown_after_primary_finished_keeps_exact_native_context_denied_across_reopen() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        observed,
        ..
    } = fixture();
    let mut source = engine.store.thread(&id).unwrap();
    source["sessions"] = json!({"codex":{"sessionID":"native-thread","seenItemCount":0}});
    engine.store.save(&source).unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    let guard = engine.runs[&id].resume_safe.clone();
    let _request = server.next_request().unwrap(); // No ACK is ever returned.
    engine
        .runs
        .get_mut(&id)
        .unwrap()
        .events
        .push_back(Event::Finished);
    engine.poll(); // Primary saved/removed while steering outcome is still pending.
    assert!(!engine.runs.contains_key(&id));
    assert!(!guard.load(std::sync::atomic::Ordering::Acquire));
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Pending
    );
    observed.recv_timeout(Duration::from_secs(5)).unwrap();
    finish_fake(&mut engine, &id, release);
    server.close(); // Transport close publishes Unknown after primary finalization.
    engine.poll();
    assert!(matches!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Retained(_)
    ));
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], source["draft"]);
    assert!(
        engine
            .unrevoked_provider_session(&saved, "codex")
            .unwrap()
            .is_none()
    );
    assert!(!guard.load(std::sync::atomic::Ordering::Acquire));
    let mut unrelated = saved.clone();
    let unrelated_account = Uuid::new_v4().to_string();
    unrelated["selection"]["accountID"] = json!(unrelated_account);
    // A different selection cannot adopt the current default session. Supply
    // its own account-bound cached descriptor, deliberately with the same ID,
    // to prove the uncertainty denial is scoped to the original account.
    unrelated["accountSessions"] = json!({format!("codex/{unrelated_account}"):{"accountID":unrelated_account,"sessionID":"native-thread","seenItemCount":0}});
    assert_eq!(
        engine
            .unrevoked_provider_session(&unrelated, "codex")
            .unwrap()
            .as_deref(),
        Some("native-thread")
    );
    engine.collect_native_follow_up(ticket).unwrap();
    drop(engine);
    let engine = Engine::fixture(Store::open(&_dir.path().join("state.sqlite")).unwrap());
    assert!(
        engine
            .unrevoked_provider_session(&engine.store.thread(&id).unwrap(), "codex")
            .unwrap()
            .is_none()
    );
}

#[test]
fn rejected_steer_keeps_primary_running_and_removes_only_its_own_uncertainty() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    let request = server.next_request().unwrap();
    server
        .response(&json!({"id":request["id"],"error":{"code":-1,"message":"synthetic rejection"}}));
    engine.poll();
    assert!(matches!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Retained(_)
    ));
    assert!(!engine.runs[&id].cancelled);
    assert!(
        engine.runs[&id]
            .resume_safe
            .load(std::sync::atomic::Ordering::Acquire)
    );
    assert!(
        !engine
            .store
            .is_native_session_uncertain(&id, "default", "native-thread")
            .unwrap()
    );
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], source["draft"]);
    finish_fake(&mut engine, &id, release);
}

#[test]
fn disabled_provider_refuses_every_native_follow_up_before_request_or_worker_changes() {
    let Fixture {
        _dir,
        mut engine,
        id,
        server: _server,
        release,
        control,
        ..
    } = fixture();
    engine
        .store
        .save_document(
            "settings.json",
            &json!({"providers":{"codex":{"isEnabled":false}}}),
        )
        .unwrap();
    engine.runs.get_mut(&id).unwrap().pending.insert("approval".into(),
        json!({"id":7,"method":"item/commandExecution/requestApproval","params":{"availableDecisions":["accept","decline"]}}));
    let pending = engine.runs[&id].pending.clone();
    for behavior in [Behavior::Steer, Behavior::Queue, Behavior::Interrupt] {
        let source = engine.store.thread(&id).unwrap();
        let source = engine.choose_native_follow_up(&source, behavior).unwrap();
        let error = engine
            .send_native_follow_up(&source, false)
            .err()
            .expect("Disabled follow-up was admitted");
        assert!(error.to_string().contains("disabled"));
        assert_eq!(engine.store.thread(&id).unwrap(), source);
        assert_eq!(engine.runs[&id].pending, pending);
        assert!(!engine.runs[&id].cancelled);
        assert!(engine.native_follow_up.operations.is_empty());
        assert!(engine.steering_operations.is_empty());
        assert!(control.try_recv().is_err());
    }
    let source = engine.store.thread(&id).unwrap();
    let error = engine
        .steer_command("agent.steer", &json!({"threadId":id,"text":"No transport"}))
        .unwrap_err();
    assert!(error.to_string().contains("disabled"));
    assert_eq!(engine.store.thread(&id).unwrap(), source);
    assert_eq!(engine.runs[&id].pending, pending);
    assert!(engine.steering_operations.is_empty());
    finish_fake(&mut engine, &id, release);
}

#[test]
fn queued_send_now_requires_real_steering_ack_and_keeps_separate_composer() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let mut source = engine.store.thread(&id).unwrap();
    crate::message_queue::add(&mut source, "synthetic queued immediate steer").unwrap();
    source["draftContext"] = json!([{"future":"unopened context"}]);
    source["rustDraftImages"] = json!([{"future":"unopened image"}]);
    source["rustMessageQueue"][0]["future"] = json!({"keep":true});
    engine.store.save(&source).unwrap();
    engine.enabled_queues.remove(&id);
    let visible = serde_json::to_value(&crate::message_queue::read(&source).unwrap()[0]).unwrap();
    let expected = Value::Object(
        [
            "id",
            "rustMessageQueue",
            "selection",
            "projectID",
            "projectPath",
            "worktreePath",
            "botID",
            "rustBotContext",
            "accessMode",
            "interactionMode",
        ]
        .into_iter()
        .filter_map(|key| source.get(key).map(|value| (key.into(), value.clone())))
        .collect(),
    );
    let ticket = engine.native_send_queued_now(&expected, &visible).unwrap();
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Pending
    );
    assert_eq!(
        engine.store.thread(&id).unwrap()["rustMessageQueue"][0]["state"],
        "dispatching"
    );
    let request = server.next_request().unwrap();
    assert_eq!(
        request["params"]["input"][0]["text"],
        "synthetic queued immediate steer"
    );
    engine
        .store
        .patch_thread(&id, &json!({"draft":"new unrelated draft during ACK"}))
        .unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: false
        }
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "new unrelated draft during ACK");
    for field in ["draftContext", "rustDraftImages"] {
        assert_eq!(saved[field], source[field]);
    }
    assert_eq!(saved["rustMessageQueue"][0]["state"], "completed");
    assert_eq!(saved["rustMessageQueue"][0]["future"], json!({"keep":true}));
    assert!(!engine.enabled_queues.contains(&id));
    engine.collect_native_follow_up(ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn queued_interrupt_waits_for_owned_worker_and_rejects_changed_execution_context() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        observed,
        ..
    } = fixture();
    server.close();
    let mut source = engine.store.thread(&id).unwrap();
    let message = crate::message_queue::add(&mut source, "synthetic queued interrupt").unwrap();
    engine.store.save(&source).unwrap();
    let ticket = engine
        .native_send_queued_now(&source, &serde_json::to_value(message).unwrap())
        .unwrap();
    observed.recv_timeout(Duration::from_secs(5)).unwrap();
    for _ in 0..3 {
        engine.poll();
    }
    assert!(!engine.runs.contains_key(&id));
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Pending,
        "semantic Finished must not launch replacement before actual worker return"
    );
    let mut changed = engine.store.thread(&id).unwrap();
    changed["draft"] = json!("unrelated new draft");
    changed["projectPath"] = json!("/synthetic/changed-project");
    engine.store.save(&changed).unwrap();
    release.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.native_follow_up_status(&ticket).unwrap() == NativeFollowUpStatus::Pending {
        engine.poll();
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    assert!(matches!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Retained(_)
    ));
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "unrelated new draft");
    assert_eq!(
        saved["rustMessageQueue"][0]["state"], "dispatching",
        "unconfirmed claim is retained, never replayed"
    );
    assert!(!engine.enabled_queues.contains(&id));
    assert!(engine.runs.is_empty());
    engine.collect_native_follow_up(ticket).unwrap();
}

fn private_image(engine: &Engine, directory: &std::path::Path) -> crate::attachments::StoredImage {
    let path = directory.join("synthetic-follow-up.png");
    image::RgbImage::from_pixel(2, 2, image::Rgb([12, 34, 56]))
        .save(&path)
        .unwrap();
    crate::attachments::ingest_image(&engine.store.data_directory().unwrap(), &path).unwrap()
}
#[test]
fn captured_send_preserves_new_images_and_references() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        ..
    } = fixture();
    let original_image = private_image(&engine, _dir.path());
    let next_image = private_image(&engine, _dir.path());
    let original_context = json!([{"id":Uuid::new_v4(),"kind":"quote","text":"original"}]);
    let next_context = json!([{"id":Uuid::new_v4(),"kind":"quote","text":"next"}]);
    let mut captured = engine.store.thread(&id).unwrap();
    captured["rustDraftImages"] = json!([original_image]);
    captured["draftContext"] = original_context.clone();
    engine.store.save(&captured).unwrap();
    let mut newer = captured.clone();
    newer["draft"] = json!("next draft");
    newer["rustDraftImages"] = json!([original_image, next_image]);
    newer["draftContext"] = next_context.clone();
    engine.store.save(&newer).unwrap();
    assert_eq!(
        engine.queue_captured_native_send(&captured, false).unwrap(),
        (true, false)
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "next draft");
    assert_eq!(saved["rustDraftImages"], json!([next_image]));
    assert_eq!(saved["draftContext"], next_context);
    let queued = crate::message_queue::read(&saved).unwrap();
    assert_eq!(queued[0].images.len(), 1);
    assert_eq!(queued[0].context, original_context);
    release.send(()).unwrap();
}
#[test]
fn native_image_and_reference_steering_delivers_exact_payload_before_cas_cleanup() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let image = private_image(&engine, _dir.path());
    let context = json!([{"id":Uuid::new_v4(),"kind":"quote","text":"Synthetic quoted café 👩🏽‍💻", "future":{"keep":7}}]);
    let mut source = engine.store.thread(&id).unwrap();
    source["draft"] = json!("");
    source["draftContext"] = context.clone();
    source["rustDraftImages"] = json!([image]);
    engine.store.save(&source).unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    let request = server.next_request().unwrap();
    assert!(
        request["params"]["input"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Synthetic quoted café 👩🏽‍💻")
    );
    assert_eq!(request["params"]["input"][1]["type"], "localImage");
    assert_eq!(
        request["params"]["input"][1]["path"],
        source["rustDraftImages"][0]["path"]
    );
    engine.poll();
    assert_eq!(engine.store.thread(&id).unwrap()["draftContext"], context);
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: true
        }
    );
    let saved = engine.store.thread(&id).unwrap();
    assert!(saved["draftContext"].is_null());
    assert_eq!(saved["rustDraftImages"], json!([]));
    let user = saved["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["steered"] == true)
        .unwrap();
    assert_eq!(user["context"], context);
    assert_eq!(user["rustImages"], source["rustDraftImages"]);
    assert_eq!(user["text"], "");
    engine.collect_native_follow_up(ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}
#[test]
fn accepted_image_is_removed_even_when_a_new_draft_arrives_during_ack() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let first = private_image(&engine, _dir.path());
    let second = private_image(&engine, _dir.path());
    let mut source = engine.store.thread(&id).unwrap();
    source["draft"] = json!("First message");
    source["rustDraftImages"] = json!([first]);
    engine.store.save(&source).unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    let request = server.next_request().unwrap();

    let mut next = engine.store.thread(&id).unwrap();
    next["draft"] = json!("New message");
    next["rustDraftImages"] = json!([first, second]);
    engine.store.save(&next).unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: false,
        }
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "New message");
    assert_eq!(saved["rustDraftImages"], json!([second]));
    engine.collect_native_follow_up(ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}
#[test]
fn invalid_follow_up_image_is_rejected_before_stop_or_steer() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        control,
        ..
    } = fixture();
    let mut image = private_image(&engine, _dir.path());
    image.path = _dir
        .path()
        .join("unrelated-outside-private-image-directory.png");
    let mut source = engine.store.thread(&id).unwrap();
    source["rustDraftImages"] = json!([image]);
    engine.store.save(&source).unwrap();
    let source = engine
        .choose_native_follow_up(&source, Behavior::Interrupt)
        .unwrap();
    assert!(engine.send_native_follow_up(&source, false).is_err());
    assert!(control.try_recv().is_err());
    assert!(server.next_request().is_none());
    assert!(!engine.runs[&id].cancelled);
    assert_eq!(engine.store.thread(&id).unwrap(), source);
    finish_fake(&mut engine, &id, release);
}
#[test]
fn native_queue_atomically_transfers_full_payload_and_preserves_neighbor_unknowns() {
    let Fixture {
        _dir,
        mut engine,
        id,
        server: _server,
        release,
        ..
    } = fixture();
    let image = private_image(&engine, _dir.path());
    let mut source = engine.store.thread(&id).unwrap();
    crate::message_queue::add(&mut source, "existing queued neighbor").unwrap();
    source["rustMessageQueue"][0]["future"] = json!({"keep":8});
    source["draftContext"] = json!([{"id":Uuid::new_v4(),"kind":"file","path":"/synthetic/missing-reference-never-opened"}]);
    source["rustDraftImages"] = json!([image]);
    engine.store.save(&source).unwrap();
    let source = engine
        .choose_native_follow_up(&source, Behavior::Queue)
        .unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Queue,
            draft_cleared: true
        }
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["rustMessageQueue"][0], source["rustMessageQueue"][0]);
    assert_eq!(
        saved["rustMessageQueue"][1]["context"],
        source["draftContext"]
    );
    assert_eq!(
        saved["rustMessageQueue"][1]["rustImages"],
        source["rustDraftImages"]
    );
    assert!(saved["draftContext"].is_null());
    assert_eq!(saved["rustDraftImages"], json!([]));
    engine.collect_native_follow_up(ticket).unwrap();
    engine.enabled_queues.remove(&id);
    finish_fake(&mut engine, &id, release);
}

#[test]
fn accepted_payload_preserves_a_newer_composer_and_rejects_only_identical_resubmission() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let mut source = engine.store.thread(&id).unwrap();
    source["draftContext"] = json!([{"id":Uuid::new_v4(),"kind":"quote","text":"First reference"}]);
    engine.store.save(&source).unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    let request = server.next_request().unwrap();
    // The user explicitly retyped the same text for the next message.
    engine
        .store
        .patch_draft(&id, source["draft"].as_str().unwrap())
        .unwrap();
    let mut newer = engine.store.thread(&id).unwrap();
    newer["draftContext"][0]["text"] = json!("Newer reference typed during ACK");
    engine.store.save(&newer).unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: false
        }
    );
    assert_eq!(
        engine.store.thread(&id).unwrap()["draftContext"],
        newer["draftContext"]
    );
    engine.collect_native_follow_up(ticket).unwrap();
    // Text is unchanged; an actually changed native payload is a new message.
    let new_ticket = engine.send_native_follow_up(&newer, false).unwrap();
    let new_request = server.next_request().unwrap();
    assert!(
        new_request["params"]["input"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Newer reference typed during ACK")
    );
    server.response(&json!({"id":new_request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    engine.collect_native_follow_up(new_ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn accepted_steer_clears_sent_text_when_next_context_changes_during_ack() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    let request = server.next_request().unwrap();
    let mut next = engine.store.thread(&id).unwrap();
    next["draftContext"] = json!([{"id":Uuid::new_v4(),"kind":"quote","text":"Next reference"}]);
    engine.store.save(&next).unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: true,
        }
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "");
    assert_eq!(saved["draftContext"], next["draftContext"]);
    assert!(
        saved["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| { item["kind"] == "user" && item["text"] == source["draft"] })
    );
    engine.collect_native_follow_up(ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn explicit_retype_of_same_message_can_be_sent_again_after_ack() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let first = engine.send_native_follow_up(&source, false).unwrap();
    let request = server.next_request().unwrap();
    engine
        .store
        .patch_draft(&id, source["draft"].as_str().unwrap())
        .unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert!(matches!(
        engine.native_follow_up_status(&first).unwrap(),
        NativeFollowUpStatus::Delivered {
            draft_cleared: false,
            ..
        }
    ));
    engine.collect_native_follow_up(first).unwrap();
    let next = engine.store.thread(&id).unwrap();
    assert_eq!(next["draft"], source["draft"]);
    let second = engine.send_native_follow_up(&next, false).unwrap();
    let request = server.next_request().unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    assert!(matches!(
        engine.native_follow_up_status(&second).unwrap(),
        NativeFollowUpStatus::Delivered {
            draft_cleared: true,
            ..
        }
    ));
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], "");
    engine.collect_native_follow_up(second).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn queue_keeps_pending_approval_and_does_not_signal_the_running_provider() {
    let Fixture {
        _dir,
        mut engine,
        id,
        release,
        control,
        ..
    } = fixture();
    let source = engine.store.thread(&id).unwrap();
    let source = engine
        .choose_native_follow_up(&source, Behavior::Queue)
        .unwrap();
    engine.runs.get_mut(&id).unwrap().pending.insert("approval".into(),
        json!({"id":77,"method":"item/commandExecution/requestApproval","params":{"availableDecisions":["accept"]}}));
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Queue,
            draft_cleared: true,
        }
    );
    assert!(engine.runs[&id].pending.contains_key("approval"));
    assert!(control.try_recv().is_err());
    assert_eq!(
        crate::message_queue::read(&engine.store.thread(&id).unwrap()).unwrap()[0].text,
        "synthetic redirect"
    );
    engine.collect_native_follow_up(ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn unavailable_steering_saves_a_queue_row_before_accepting_a_new_draft() {
    let Fixture {
        _dir,
        mut engine,
        id,
        mut server,
        release,
        control,
        ..
    } = fixture();
    // An in-progress assistant item temporarily makes Codex steering unsafe.
    server.observe(&json!({"method":"item/started","params":{
        "threadId":"native-thread","turnId":"native-turn",
        "item":{"type":"agentMessage","id":"reply"}
    }}));
    let source = engine.store.thread(&id).unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Queue,
            draft_cleared: true,
        }
    );
    assert!(control.try_recv().is_err());
    let queued = engine.store.thread(&id).unwrap();
    assert_eq!(queued["draft"], "");
    assert_eq!(
        crate::message_queue::read(&queued).unwrap()[0].text,
        "synthetic redirect"
    );
    engine
        .store
        .patch_thread(&id, &json!({"draft":"a separate new draft"}))
        .unwrap();
    assert_eq!(
        engine.store.thread(&id).unwrap()["draft"],
        "a separate new draft"
    );
    engine.collect_native_follow_up(ticket).unwrap();
    finish_fake(&mut engine, &id, release);
}

#[test]
fn prefix_proof_accepts_long_history_and_detects_changes_or_truncation() {
    let prefix = vec![json!({"kind":"user","text":"x".repeat(9 * 1024 * 1024)})];
    let proof = PrefixProof::capture(&prefix, 1).unwrap();
    let mut extended = prefix.clone();
    extended.push(json!({"kind":"assistant","text":"later"}));
    assert!(proof.matches(&extended).unwrap());
    extended[0]["text"] = json!("changed");
    assert!(!proof.matches(&extended).unwrap());
    assert!(!proof.matches(&[]).unwrap());
}

fn text_steer_waits_for_ack_without_blocking_and_preserves_new_draft(provider: &str) {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let mut thread = engine
        .execute("threads.create", &json!({"cwd":dir.path()}))
        .unwrap();
    let id = text(&thread, "id");
    thread["selection"] = json!({"provider":provider,"modelID":"default"});
    thread["draft"] = json!("first steering message");
    engine.store.save(&thread).unwrap();
    engine.set_active_thread(Some(id.clone())).unwrap();
    let (observed_tx, observed) = mpsc::channel();
    let (ack_tx, ack) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        while let Ok(command) = commands.recv() {
            match command {
                agent::Control::Steer { text, reply } => {
                    observed_tx.send(text).unwrap();
                    ack.recv().unwrap();
                    reply.send(Ok(())).unwrap();
                }
                agent::Control::Stop => break,
                _ => {}
            }
        }
        let _ = events.send(Event::Finished);
    });
    engine.insert_running(
        id.clone(),
        Running {
            configuration: None,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            session,
            usage_context: Some(agent::usage_capture::TurnContext::new(&thread)),
            provider: provider.into(),
            transcript_start: 0,
            pending: HashMap::new(),
            schedule_claim: None,
            queue_claim: None,
            cancelled: false,
            events: VecDeque::new(),
            persistence_error: None,
        },
    );
    let start = Instant::now();
    let ticket = engine.send_native_follow_up(&thread, false).unwrap();
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "admission blocked waiting for provider"
    );
    assert_eq!(
        observed.recv_timeout(Duration::from_secs(5)).unwrap(),
        "first steering message"
    );
    if provider == "opencode"
        && let Some(Delivery::TextSteer { started, .. }) = engine
            .native_follow_up
            .operations
            .get_mut(&ticket.id)
            .unwrap()
            .delivery
            .as_mut()
    {
        // A catalog read can legitimately take longer than the old 10-second
        // limit. Its eventual ACK must still deliver exactly this message.
        *started = Instant::now() - Duration::from_secs(11);
    }
    engine.poll();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Pending
    );
    engine
        .store
        .patch_thread(&id, &json!({"draft":"new draft"}))
        .unwrap();
    let mut next = thread.clone();
    next["draft"] = json!("second steering message");
    assert!(matches!(
        engine
            .admit_captured_native_send(&next, false, Behavior::Steer, false)
            .unwrap(),
        CapturedNativeSend::Waiting
    ));
    ack_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.native_follow_up_status(&ticket).unwrap() == NativeFollowUpStatus::Pending {
        engine.poll();
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: false,
        }
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "new draft");
    assert_eq!(
        saved["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["text"] == "first steering message" && item["steered"] == true)
            .count(),
        1
    );
    engine.collect_native_follow_up(ticket).unwrap();

    let second = match engine
        .admit_captured_native_send(&next, false, Behavior::Steer, false)
        .unwrap()
    {
        CapturedNativeSend::Saved {
            ticket: Some(ticket),
            error: None,
            ..
        } => ticket,
        _ => panic!("{provider} did not start the second steer"),
    };
    assert_eq!(
        observed.recv_timeout(Duration::from_secs(5)).unwrap(),
        "second steering message"
    );
    ack_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.native_follow_up_status(&second).unwrap() == NativeFollowUpStatus::Pending {
        engine.poll();
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    assert!(matches!(
        engine.native_follow_up_status(&second).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            ..
        }
    ));
    engine.collect_native_follow_up(second).unwrap();

    // Sending a queued row now must steer that row, never the separate draft.
    let mut queued = engine.store.thread(&id).unwrap();
    crate::message_queue::add(&mut queued, "queued OpenCode message").unwrap();
    engine.store.save(&queued).unwrap();
    let visible =
        serde_json::to_value(crate::message_queue::read(&queued).unwrap().last().unwrap()).unwrap();
    let ticket = engine.native_send_queued_now(&queued, &visible).unwrap();
    assert_eq!(
        observed.recv_timeout(Duration::from_secs(5)).unwrap(),
        "queued OpenCode message"
    );
    ack_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.native_follow_up_status(&ticket).unwrap() == NativeFollowUpStatus::Pending {
        engine.poll();
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Steer,
            draft_cleared: false,
        }
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "new draft");
    assert_eq!(
        saved["rustMessageQueue"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["state"],
        "completed"
    );
    engine.collect_native_follow_up(ticket).unwrap();
    engine.request_provider_stop(&id).unwrap();
}

#[test]
fn opencode_steer_waits_for_ack_without_blocking_and_preserves_new_draft() {
    text_steer_waits_for_ack_without_blocking_and_preserves_new_draft("opencode");
}
#[test]
fn claude_steer_waits_for_ack_without_blocking_and_preserves_new_draft() {
    text_steer_waits_for_ack_without_blocking_and_preserves_new_draft("claude");
}

#[test]
fn queue_and_interrupt_target_only_the_running_worker_for_every_provider() {
    for provider in [
        "codex",
        "opencode",
        "claude",
        "cursor",
        "grok",
        "antigravity",
    ] {
        for behavior in [Behavior::Queue, Behavior::Interrupt] {
            let Fixture {
                _dir,
                mut engine,
                id,
                release,
                observed,
                control,
                ..
            } = fixture();
            let mut source = engine.store.thread(&id).unwrap();
            source["selection"] = json!({"provider":provider,"modelID":"default"});
            engine.store.save(&source).unwrap();
            let run = engine.runs.get_mut(&id).unwrap();
            run.provider = provider.into();
            run.usage_context = Some(agent::usage_capture::TurnContext::new(&source));
            let source = engine.choose_native_follow_up(&source, behavior).unwrap();
            let ticket = engine
                .send_native_follow_up(&source, false)
                .unwrap_or_else(|error| panic!("{provider} {behavior:?}: {error}"));
            match behavior {
                Behavior::Queue => {
                    assert_eq!(
                        engine.native_follow_up_status(&ticket).unwrap(),
                        NativeFollowUpStatus::Delivered {
                            dispatch: Dispatch::Queue,
                            draft_cleared: true,
                        }
                    );
                    assert!(control.try_recv().is_err(), "queue signalled {provider}");
                    engine.collect_native_follow_up(ticket).unwrap();
                    finish_fake(&mut engine, &id, release);
                }
                Behavior::Interrupt => {
                    assert!(matches!(
                        control.recv_timeout(Duration::from_secs(5)).unwrap(),
                        agent::Control::Stop
                    ));
                    observed.recv_timeout(Duration::from_secs(5)).unwrap();
                    engine
                        .store
                        .patch_thread(&id, &json!({"draft":"edited while stopping"}))
                        .unwrap();
                    release.send(()).unwrap();
                    let deadline = Instant::now() + Duration::from_secs(5);
                    while engine.native_follow_up_status(&ticket).unwrap()
                        == NativeFollowUpStatus::Pending
                    {
                        engine.poll();
                        assert!(Instant::now() < deadline);
                        std::thread::yield_now();
                    }
                    assert!(matches!(
                        engine.native_follow_up_status(&ticket).unwrap(),
                        NativeFollowUpStatus::Retained(_)
                    ));
                    assert_eq!(
                        engine.store.thread(&id).unwrap()["draft"],
                        "edited while stopping"
                    );
                    engine.collect_native_follow_up(ticket).unwrap();
                }
                Behavior::Steer => unreachable!(),
            }
        }
    }
}
