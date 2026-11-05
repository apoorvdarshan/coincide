use super::*;
fn capture() -> Capture {
    let mut capture = Capture::default();
    capture.bind_thread("existing-native-session");
    capture.bind_turn(&json!("turn-fixture"));
    capture
}
fn update() -> Value {
    json!({"threadId":"existing-native-session","turnId":"turn-fixture","tokenUsage":{"last":{"totalTokens":123,"outputTokens":7,"cachedInputTokens":11,"future":42},"total":{"totalTokens":99999},"modelContextWindow":200000,"future":{"retain":true}}})
}
fn complete() -> Value {
    json!({"threadId":"existing-native-session","turn":{"id":"turn-fixture","status":"completed"}})
}
#[test]
fn matching_source_turn_retains_raw_snapshot_without_additive_or_cost_inference() {
    let mut capture = capture();
    capture.update(&update());
    let snapshot = capture.complete(&complete()).unwrap();
    assert!(capture.complete(&complete()).is_none());
    let context = TurnContext::new(
        &json!({"id":Uuid::new_v4(),"projectID":Uuid::nil(),"selection":{"provider":"codex","modelID":"default","accountID":""}}),
    );
    let record = context.finish(snapshot).0;
    assert_eq!(
        record["usage"],
        json!({"inputTokens":123,"outputTokens":7,"cachedInputTokens":11,"contextWindow":200000})
    );
    assert!(record["usage"].get("turnTotals").is_none());
    assert!(record["usage"].get("costUSD").is_none());
    assert_eq!(
        record["provenance"]["rawTokenUsage"],
        update()["tokenUsage"]
    );
    assert_eq!(record["accountID"], "");
}
#[test]
fn mismatched_missing_stale_and_unbound_source_ids_cannot_capture() {
    for field in ["threadId", "turnId"] {
        for value in [Value::Null, json!("different"), json!("")] {
            let mut capture = capture();
            let mut wrong = update();
            wrong[field] = value;
            capture.update(&wrong);
            assert!(capture.complete(&complete()).is_none());
        }
    }
    let mut unbound = Capture::default();
    unbound.update(&update());
    assert!(unbound.complete(&complete()).is_none());
    let mut capture = capture();
    capture.update(&update());
    let mut wrong = complete();
    wrong["turn"]["id"] = json!("stale");
    assert!(capture.complete(&wrong).is_none());
    assert!(capture.complete(&complete()).is_some());
    capture.update(&update());
    assert!(capture.complete(&complete()).is_none());
}
#[test]
fn invalid_metrics_remain_raw_without_becoming_reported_zero_and_history_is_exact_idempotent() {
    let mut capture = capture();
    let mut raw = update();
    raw["tokenUsage"]["last"] =
        json!({"totalTokens":-1,"outputTokens":"bad","cachedInputTokens":null});
    capture.update(&raw);
    let record = TurnContext::new(&json!({}))
        .finish(capture.complete(&complete()).unwrap())
        .0;
    assert_eq!(record["usage"], json!({"contextWindow":200000}));
    let old = json!([{"id":Uuid::new_v4(),"unknown":{"untouched":true}}]);
    let next = append_history(Some(&old), &record).unwrap();
    assert_eq!(next[0], old[0]);
    assert_eq!(append_history(Some(&next), &record).unwrap(), next);
    let mut conflicting = record.clone();
    conflicting["outcome"] = json!("failed");
    assert!(append_history(Some(&next), &conflicting).is_err());
    assert!(append_history(Some(&json!({"invalid":"history"})), &record).is_err());
}

#[test]
fn source_failed_and_interrupted_outcomes_are_not_relabelled_success() {
    for status in ["failed", "interrupted"] {
        let mut capture = capture();
        capture.update(&update());
        let mut finish = complete();
        finish["turn"]["status"] = json!(status);
        let record = TurnContext::new(&json!({}))
            .finish(capture.complete(&finish).unwrap())
            .0;
        assert_eq!(record["outcome"], status);
    }
}

#[test]
fn early_usage_is_retained_until_matching_response_or_provisional_start_binds_identity() {
    for provisional in [false, true] {
        let mut capture = Capture::default();
        capture.bind_thread("existing-native-session");
        if provisional {
            assert!(capture.bind_turn(&json!("turn-fixture")));
        }
        assert!(capture.update(&update()));
        assert!(capture.bind_turn(&json!("turn-fixture")));
        assert!(!capture.bind_turn(&json!("different")));
        let snapshot = capture.complete(&complete()).unwrap();
        assert_eq!(snapshot.raw, update()["tokenUsage"]);
    }
    let mut capture = Capture::default();
    capture.bind_thread("existing-native-session");
    for n in 0..8 {
        let mut frame = update();
        frame["turnId"] = json!(format!("turn-{n}"));
        assert!(capture.update(&frame));
    }
    assert!(!capture.update(&update()));
}
