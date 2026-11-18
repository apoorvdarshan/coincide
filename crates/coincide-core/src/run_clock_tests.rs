//! The toolbar's run status reads `app.status` `runClocks`; synthetic workers only.
use super::*;
use std::sync::mpsc;
use std::time::Duration;

#[test]
fn duration_is_written_only_to_the_run_opener() {
    let mut thread = json!({"items":[
        {"id":"a","kind":"user","text":"first"},
        {"id":"steer","kind":"user","steered":true},
        {"id":"b","kind":"user","text":"second"}
    ], "unknown":{"preserved":true}});
    let original_items = thread["items"].clone();
    record_turn_duration(&mut thread, "a", 42.5);
    record_turn_duration(&mut thread, "steer", 900.);
    record_turn_duration(&mut thread, "b", f64::NAN);
    assert_eq!(thread["rustTurnDurations"], json!({"a":42.5}));
    assert_eq!(thread["items"], original_items);
    assert_eq!(thread["unknown"]["preserved"], true);
    thread["rustTurnDurations"] = json!({"a":"preserve","unknown":1});
    record_turn_duration(&mut thread, "a", 100.);
    assert_eq!(
        thread["rustTurnDurations"],
        json!({"a":"preserve","unknown":1})
    );
    thread["rustTurnDurations"] = json!("unrecognized");
    record_turn_duration(&mut thread, "b", 10.);
    assert_eq!(thread["rustTurnDurations"], "unrecognized");
}

fn running(session: Session) -> Running {
    Running {
        configuration: None,
        resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
        usage_context: None,
        session,
        provider: "codex".into(),
        transcript_start: 0,
        pending: HashMap::new(),
        schedule_claim: None,
        queue_claim: None,
        cancelled: false,
        events: VecDeque::new(),
        persistence_error: None,
    }
}

#[test]
fn remote_reports_real_start_and_steering_readiness_for_every_provider() {
    for provider in [
        "codex",
        "claude",
        "grok",
        "opencode",
        "cursor",
        "antigravity",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let mut thread = store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        thread["selection"] = json!({"provider":provider,"modelID":"default"});
        store.save(&thread).unwrap();
        let id = text(&thread, "id");
        let mut engine = Engine::fixture(store);
        let mut session = Session::fixture_worker(|commands, _events| {
            let _ = commands.recv();
        });
        let mut steering = (provider == "codex").then(|| session.fixture_steering());
        if let Some(server) = &mut steering {
            server.activate("native-thread", "native-turn");
        }
        let mut run = running(session);
        run.provider = provider.into();
        run.usage_context = Some(agent::usage_capture::TurnContext::new(&thread));
        engine.insert_running(id.clone(), run);
        let expected = matches!(provider, "codex" | "opencode");
        assert_eq!(
            engine.remote_can_steer(&id, &thread),
            expected,
            "{provider}"
        );
        let mut changed = thread.clone();
        changed["interactionMode"] = json!("plan");
        assert!(!engine.remote_can_steer(&id, &changed), "{provider}");
        changed = thread.clone();
        changed["isArchived"] = json!(true);
        assert!(!engine.remote_can_steer(&id, &changed), "{provider}");
        engine
            .store
            .save_document(
                "settings.json",
                &json!({"providers":{(provider):{"isEnabled":false}}}),
            )
            .unwrap();
        assert!(!engine.remote_can_steer(&id, &thread), "{provider}");
        engine
            .store
            .save_document("settings.json", &json!({}))
            .unwrap();
        engine.runs.get_mut(&id).unwrap().cancelled = true;
        assert!(!engine.remote_can_steer(&id, &thread), "{provider}");
        engine.runs.get_mut(&id).unwrap().cancelled = false;
        let engine = Arc::new(Mutex::new(engine));
        let adapter = crate::remote::adapter::Adapter::new(engine, "fixture");
        let runs = adapter.runs().unwrap();
        let key = id.to_uppercase();
        assert!(runs.running.contains(&key), "{provider}");
        assert!(runs.starting.contains(&key), "{provider}");
        assert!(runs.started_at[&key] > 0., "{provider}");
        let turn = adapter.turn_state(&id, &thread, &runs).unwrap();
        assert!(turn.is_running && turn.is_starting, "{provider}");
        assert_eq!(turn.can_steer, expected, "{provider}");
        assert_eq!(turn.provider.as_deref(), Some(provider));
        assert_eq!(
            turn.started_at,
            runs.started_at.get(&key).copied(),
            "{provider}"
        );
    }
}

#[test]
fn a_run_connects_on_its_first_provider_event_and_its_clock_ends_with_it() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
    let project = store.create_project(dir.path(), Some("fixture")).unwrap();
    let mut thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    thread["selection"] = json!({"provider":"unsupported-clock-fixture","modelID":"default"});
    thread["items"] = json!([{"id":"fixture-prompt","kind":"user","text":"synthetic"}]);
    store.save(&thread).unwrap();
    let id = text(&thread, "id");
    let mut engine = Engine::fixture(store);
    let (send_tx, send_rx) = mpsc::channel::<Event>();
    let (sent_tx, sent_rx) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        while let Ok(event) = send_rx.recv() {
            let finished = matches!(event, Event::Finished);
            events.send(event).unwrap();
            sent_tx.send(()).unwrap();
            if finished {
                break;
            }
        }
        drop(commands);
    });
    let before = swift_timestamp();
    engine.insert_running_for_turn(id.clone(), running(session), Some("fixture-prompt".into()));
    let status = |engine: &mut Engine| {
        engine.dispatch(json!({"method":"app.status","params":{}}))["result"]["runClocks"].clone()
    };
    let clock = status(&mut engine)[&id].clone();
    assert_eq!(clock["connecting"], true);
    assert_eq!(clock["openerId"], "fixture-prompt");
    assert_eq!(
        engine.dispatch(json!({"method":"app.status","params":{}}))["result"]["starting"],
        json!([id.clone()])
    );
    assert!(clock["startedAt"].as_f64().unwrap() >= before);
    send_tx
        .send(Event::Session("synthetic-session".into()))
        .unwrap();
    sent_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while status(&mut engine)[&id]["connecting"] == true {
        assert!(Instant::now() < deadline, "first event was not observed");
        engine.poll();
    }
    assert_eq!(
        engine.dispatch(json!({"method":"app.status","params":{}}))["result"]["starting"],
        json!([])
    );
    send_tx.send(Event::Finished).unwrap();
    sent_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    while engine.runs.contains_key(&id) {
        assert!(Instant::now() < deadline, "finished run was not removed");
        engine.poll();
    }
    engine.poll();
    assert_eq!(status(&mut engine), json!({}));
}
