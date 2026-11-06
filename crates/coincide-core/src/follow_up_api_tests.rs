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
        Dispatch::Steer
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
        .choose_native_follow_up(&source, Behavior::Queue)
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
    unrelated["selection"]["accountID"] = json!(Uuid::new_v4().to_string());
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
