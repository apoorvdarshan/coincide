use super::*;
use std::sync::mpsc;

#[test]
fn startup_model_refresh_waits_for_provider_discovery() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "api::desktop_poll_tests::startup_model_refresh_fixture_child",
        ])
        .env_remove("COINCIDE_CODEX_EXECUTABLE")
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
}

#[test]
#[ignore = "Run by the isolated provider-discovery parent test"]
fn startup_model_refresh_fixture_child() {
    let directory = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&directory.path().join("state.sqlite")).unwrap());
    engine.provider_discovery_pending = true;
    let error = engine
        .execute("agent.models.refresh", &json!({"provider":"codex"}))
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("Provider discovery is still in progress")
    );
    assert_eq!(engine.model_catalog.shutdown_status().running, 0);
    engine.provider_discovery_pending = false;
    let result = engine
        .execute("agent.models.refresh", &json!({"provider":"codex"}))
        .unwrap();
    assert_eq!(result["state"], "loading");
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.model_catalog.shutdown_status().running != 0 {
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
}

fn fixture() -> (
    tempfile::TempDir,
    Engine,
    String,
    mpsc::Sender<Event>,
    mpsc::Receiver<()>,
) {
    let directory = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&directory.path().join("state.sqlite")).unwrap());
    let thread = engine.execute("threads.create", &json!({})).unwrap();
    let id = text(&thread, "id");
    let (send, receive) = mpsc::channel::<Event>();
    let (delivered, ready) = mpsc::channel();
    let session = Session::fixture_worker(move |_, output| {
        while let Ok(event) = receive.recv() {
            let finished = matches!(event, Event::Finished | Event::Failed(_));
            output.send(event).unwrap();
            delivered.send(()).unwrap();
            if finished {
                break;
            }
        }
    });
    engine.insert_running(
        id.clone(),
        Running {
            configuration: None,
            usage_context: None,
            session,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
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
    (directory, engine, id, send, ready)
}

fn deliver(send: &mpsc::Sender<Event>, ready: &mpsc::Receiver<()>, event: Event) {
    send.send(event).unwrap();
    ready.recv_timeout(Duration::from_secs(5)).unwrap();
}

#[test]
fn desktop_snapshots_leave_provider_events_for_the_background_poller() {
    let (_directory, mut engine, id, send, ready) = fixture();
    deliver(&send, &ready, Event::Finished);
    for (method, params) in [
        ("app.status", json!({})),
        ("agent.pending", json!({"threadId":id})),
        ("settings.read", json!({})),
        ("threads.list", json!({})),
        ("threads.read", json!({"threadId":id})),
        // Even a rejected discovery request must not drain an active turn.
        ("agent.models.refresh", json!({"provider":"unknown"})),
        ("providers.antigravity.status", json!({})),
        ("providers.codex.profiles.status", json!({})),
        ("usage.codexLimits.status", json!({})),
        ("usage.claudeLimits.status", json!({})),
        ("providers.codex.profiles.limits.status", json!({})),
    ] {
        engine.dispatch_desktop(json!({"method":method,"params":params}));
        assert!(
            engine.is_thread_running(&id),
            "{method} drained a provider event"
        );
    }
    // Actions still poll first, preserving their ordering with the completed turn.
    let response =
        engine.dispatch_desktop(json!({"method":"settings.patch","params":{"patch":{}}}));
    assert!(response.get("error").is_none(), "{response}");
    assert!(!engine.is_thread_running(&id));
}

#[cfg(unix)]
#[test]
fn background_poller_advances_turns_even_when_command_line_control_is_off() {
    use std::os::unix::fs::PermissionsExt;

    let (directory, mut engine, id, send, ready) = fixture();
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    engine
        .store
        .save_document("settings.json", &json!({"commandLineControl":false}))
        .unwrap();
    let engine = Arc::new(Mutex::new(engine));
    let server =
        crate::control::serve(directory.path().join("control.sock"), engine.clone()).unwrap();
    deliver(&send, &ready, Event::Finished);
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.lock().unwrap().is_thread_running(&id) {
        assert!(
            Instant::now() < deadline,
            "the background poller did not finish the turn"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    drop(server);
}

#[test]
fn ignored_notifications_do_not_rewrite_the_transcript_or_hide_requests() {
    let (directory, mut engine, id, send, ready) = fixture();
    let before = engine.store.thread(&id).unwrap();
    let db = rusqlite::Connection::open(directory.path().join("state.sqlite")).unwrap();
    db.execute_batch(
        "CREATE TRIGGER forbid_stream_write BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'unexpected transcript write'); END;"
    ).unwrap();
    for frame in [
        json!({"method":"thread/tokenUsage/updated","params":{"usage":123}}),
        json!({"method":"item/commandExecution/outputDelta","params":{"delta":"text"}}),
        json!({"method":"provider/event","params":{"providerFrame":{"type":"heartbeat"}}}),
    ] {
        deliver(&send, &ready, Event::Frame(frame));
        engine.poll();
    }
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert!(engine.runs[&id].persistence_error.is_none());
    assert!(engine.run_clocks[&id].connected);
    assert!(engine.answered_runs.contains(&id));

    db.execute_batch("DROP TRIGGER forbid_stream_write;")
        .unwrap();
    deliver(
        &send,
        &ready,
        Event::Frame(json!({"id":42,"method":"unrecognized/request","params":{}})),
    );
    engine.poll();
    let saved = engine.store.thread(&id).unwrap();
    assert!(saved["items"].as_array().unwrap().iter().any(|item| {
        item["kind"] == "error"
            && item["text"]
                .as_str()
                .unwrap_or("")
                .contains("unrecognized/request")
    }));
    deliver(
        &send,
        &ready,
        Event::Frame(
            json!({"method":"item/agentMessage/delta","params":{"itemId":"reply","delta":"still delivered"}}),
        ),
    );
    engine.poll();
    assert!(
        engine.store.thread(&id).unwrap()["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["text"] == "still delivered")
    );
    deliver(&send, &ready, Event::Finished);
    engine.poll();
    assert!(!engine.is_thread_running(&id));
}

#[test]
fn ignored_notifications_still_detect_a_missing_conversation() {
    let (directory, mut engine, id, send, ready) = fixture();
    let db = rusqlite::Connection::open(directory.path().join("state.sqlite")).unwrap();
    db.execute("DELETE FROM threads WHERE id=?1", [&id])
        .unwrap();
    deliver(
        &send,
        &ready,
        Event::Frame(json!({"method":"thread/tokenUsage/updated","params":{}})),
    );
    engine.poll();
    assert!(
        engine.runs[&id]
            .persistence_error
            .as_deref()
            .is_some_and(|message| message.starts_with("Transcript read failed:"))
    );
}
