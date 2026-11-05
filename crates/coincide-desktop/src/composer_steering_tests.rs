use super::*;
use std::sync::{Mutex, mpsc};
fn drive(controller: &mut SteeringController, thread: &str, phase: Phase) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        controller.last_poll = Instant::now() - Duration::from_secs(1);
        controller.poll();
        if controller
            .status(thread)
            .is_some_and(|view| view.phase == phase)
        {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "fake controller did not reach expected phase"
        );
        std::thread::yield_now();
    }
}
fn ready(controller: &mut SteeringController) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !controller.owner.can_start() {
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
}
fn backend(outcome: &str) -> (Backend, Arc<Mutex<Vec<(String, Value)>>>) {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let log = calls.clone();
    let outcome = outcome.to_owned();
    let id = uuid::Uuid::new_v4().to_string();
    (
        Arc::new(move |method, params| {
            log.lock().unwrap().push((method.into(), params.clone()));
            if method == "agent.steer" {
                Ok(
                    json!({"threadId":params["threadId"],"operationId":id,"status":"pending","persisted":false}),
                )
            } else {
                Ok(
                    json!({"threadId":params["threadId"],"operationId":id,"status":outcome,"persisted":outcome=="accepted"}),
                )
            }
        }),
        calls,
    )
}
#[test]
fn explicit_submit_waits_for_ack_and_retains_draft_with_no_automatic_repeat() {
    let (backend, calls) = backend("accepted");
    let mut controller = SteeringController::with_backend(backend);
    assert!(!controller.can_submit("thread", "draft", "claude", true));
    assert!(controller.submit("thread", "exact draft", "codex", true));
    assert_eq!(
        controller.status("thread").unwrap().phase,
        Phase::Submitting
    );
    drive(&mut controller, "thread", Phase::Accepted);
    ready(&mut controller);
    assert!(controller.status("thread").unwrap().draft_retained);
    for _ in 0..10 {
        controller.poll();
    }
    assert_eq!(
        calls
            .lock()
            .unwrap()
            .iter()
            .filter(|(method, _)| method == "agent.steer")
            .count(),
        1
    );
    assert!(!controller.submit("thread", "exact draft", "codex", true));
    controller.observe_draft("thread", "changed draft");
    assert!(controller.can_submit("thread", "changed draft", "codex", true));
}
#[test]
fn rejected_and_unknown_are_distinct_retained_results_and_thread_switch_does_not_unlock_duplicate()
{
    for outcome in ["rejected", "unknown"] {
        let (backend, _) = backend(outcome);
        let mut controller = SteeringController::with_backend(backend);
        assert!(controller.submit("a", "text a", "codex", true));
        drive(
            &mut controller,
            "a",
            if outcome == "rejected" {
                Phase::Rejected
            } else {
                Phase::Unknown
            },
        );
        ready(&mut controller);
        assert!(controller.status("b").is_none());
        assert!(controller.submit("b", "text b", "codex", true));
        drive(
            &mut controller,
            "b",
            if outcome == "rejected" {
                Phase::Rejected
            } else {
                Phase::Unknown
            },
        );
        ready(&mut controller);
        assert!(!controller.can_submit("a", "text a", "codex", true));
        controller.observe_draft("a", "");
        assert!(controller.can_submit("a", "text a", "codex", true));
    }
}
#[test]
fn malformed_or_wrong_scope_result_cannot_claim_acceptance_or_follow_visible_thread() {
    let id = uuid::Uuid::new_v4().to_string();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let log = calls.clone();
    let mut controller = SteeringController::with_backend(Arc::new(move |method, params| {
        log.lock().unwrap().push(params.clone());
        Ok(if method == "agent.steer" {
            json!({"threadId":"original","operationId":id,"status":"pending"})
        } else {
            json!({"threadId":"other","operationId":id,"status":"accepted","persisted":true})
        })
    }));
    assert!(controller.submit("original", "keep", "codex", true));
    drive(&mut controller, "original", Phase::Pending);
    controller.observe_draft("visible-other", "other draft");
    let deadline = Instant::now() + Duration::from_secs(5);
    while calls.lock().unwrap().len() < 2 {
        controller.last_poll = Instant::now() - Duration::from_secs(1);
        controller.poll();
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    controller.poll();
    assert_eq!(controller.status("original").unwrap().phase, Phase::Pending);
    assert!(controller.status("visible-other").is_none());
    assert!(
        calls
            .lock()
            .unwrap()
            .iter()
            .all(|params| params["threadId"] == "original")
    );
    controller.request_shutdown();
}
#[test]
fn accepted_pending_persistence_is_not_terminal_acceptance() {
    let (backend, _) = backend("accepted_pending_persistence");
    let mut controller = SteeringController::with_backend(backend);
    assert!(controller.submit("thread", "keep", "codex", true));
    drive(&mut controller, "thread", Phase::Pending);
    for _ in 0..20 {
        controller.last_poll = Instant::now() - Duration::from_secs(1);
        controller.poll();
        std::thread::yield_now();
    }
    assert_eq!(controller.status("thread").unwrap().phase, Phase::Pending);
    assert!(controller.pending.is_some());
    controller.request_shutdown();
}
#[test]
fn closing_controller_fences_late_reply_and_retains_actual_worker_until_join() {
    let (entered, seen) = mpsc::channel();
    let (release, gate) = mpsc::channel();
    let gate = Mutex::new(Some(gate));
    let mut controller = SteeringController::with_backend(Arc::new(move |_, _| {
        entered.send(()).unwrap();
        gate.lock().unwrap().take().unwrap().recv().unwrap();
        Ok(json!({"status":"accepted","persisted":true}))
    }));
    assert!(controller.submit("thread", "private draft", "codex", true));
    seen.recv().unwrap();
    controller.request_shutdown();
    assert_eq!(controller.shutdown_status().unjoined, 1);
    release.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while controller.shutdown_status().unjoined != 0 {
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    controller.poll();
    assert_ne!(controller.status("thread").unwrap().phase, Phase::Accepted);
    assert!(!controller.submit("thread", "new draft", "codex", true));
}
#[test]
fn unsupported_or_empty_input_never_calls_backend() {
    let mut controller = SteeringController::with_backend(Arc::new(|_, _| {
        panic!("unsupported input cannot dispatch")
    }));
    for (provider, running, text) in [
        ("claude", true, "x"),
        ("codex", false, "x"),
        ("codex", true, " "),
    ] {
        assert!(!controller.submit("thread", text, provider, running));
    }
    assert!(controller.view.is_none());
    assert!(controller.reply.is_none());
}
