//! The toolbar's run status reads `app.status` `runClocks`; synthetic workers only.
use super::*;
use std::sync::mpsc;
use std::time::Duration;

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
fn a_run_connects_on_its_first_provider_event_and_its_clock_ends_with_it() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
    let project = store.create_project(dir.path(), Some("fixture")).unwrap();
    let mut thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    thread["selection"] = json!({"provider":"unsupported-clock-fixture","modelID":"default"});
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
    engine.insert_running(id.clone(), running(session));
    let status = |engine: &mut Engine| {
        engine.dispatch(json!({"method":"app.status","params":{}}))["result"]["runClocks"].clone()
    };
    let clock = status(&mut engine)[&id].clone();
    assert_eq!(clock["connecting"], true);
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
