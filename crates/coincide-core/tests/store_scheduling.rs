use chrono::{DateTime, Utc};
use coincide_core::scheduling::{Cron, Recurrence, ScheduledTask};
use serde_json::{Value, json};

fn date(text: &str) -> DateTime<Utc> {
    text.parse().unwrap()
}
fn recurrence(patch: Value) -> Recurrence {
    let mut value = json!({"kind":"daily","timeZoneID":"America/New_York","date":"2026-01-01T00:00:00Z","hour":2,"minute":30,"weekday":2});
    for (key, value_patch) in patch.as_object().unwrap() {
        value[key] = value_patch.clone();
    }
    serde_json::from_value(value).unwrap()
}
#[test]
fn store_schedule_dst_gap_and_fold_match_mac() {
    let gap = recurrence(json!({}));
    assert_eq!(
        gap.next_after(date("2026-03-08T05:00:00Z")).unwrap(),
        Some(date("2026-03-08T07:00:00Z"))
    );
    let fold = recurrence(json!({"hour":1}));
    assert_eq!(
        fold.next_after(date("2026-11-01T04:00:00Z")).unwrap(),
        Some(date("2026-11-01T05:30:00Z"))
    );
    for now in ["2026-11-01T05:30:00Z", "2026-11-01T05:45:00Z"] {
        assert_eq!(
            fold.next_after(date(now)).unwrap(),
            Some(date("2026-11-02T06:30:00Z"))
        );
    }
}
#[test]
fn store_schedule_weekly_days_and_interval_keep_wall_clock_and_anchor() {
    let monday =
        recurrence(json!({"kind":"weekly","timeZoneID":"Asia/Kolkata","hour":9,"minute":15}));
    assert_eq!(
        monday.next_after(date("2026-10-28T12:00:00Z")).unwrap(),
        Some(date("2026-11-02T03:45:00Z"))
    );
    let interval = recurrence(json!({"kind":"interval","intervalMinutes":5}));
    assert_eq!(
        interval.next_after(date("2026-01-01T00:12:00Z")).unwrap(),
        Some(date("2026-01-01T00:15:00Z"))
    );
    let days =
        recurrence(json!({"kind":"days","weekdays":[2,4],"timeZoneID":"UTC","hour":9,"minute":0}));
    assert_eq!(
        days.next_after(date("2026-11-02T09:00:00Z")).unwrap(),
        Some(date("2026-11-04T09:00:00Z"))
    );
    let once = recurrence(json!({"kind":"once"}));
    assert_eq!(once.next_after(date("2026-01-01T00:00:00Z")).unwrap(), None);
}
#[test]
fn store_schedule_cron_names_steps_or_semantics_and_dst() {
    for valid in [
        "@hourly",
        "@daily",
        "@weekly",
        "@monthly",
        "@annually",
        "5/15 9-17/2 * jan,mar mon-fri",
        "0 0 30 feb mon",
    ] {
        Cron::parse(valid).unwrap();
    }
    for invalid in [
        "* * * * *",
        "*/2 * * * *",
        "0,59 * * * *",
        "0 0 30 feb *",
        "0 24 * * *",
        "0 0 * * 8",
        "0 0 * * mon-",
        "0//2 * * * *",
        "0 0 * * ,",
    ] {
        assert!(Cron::parse(invalid).is_err(), "{invalid}");
    }
    let cron = recurrence(json!({"kind":"cron","cron":"30 2 * * *"}));
    assert_eq!(
        cron.next_after(date("2026-03-08T05:00:00Z")).unwrap(),
        Some(date("2026-03-08T07:00:00Z"))
    );
    let or = recurrence(json!({"kind":"cron","timeZoneID":"UTC","cron":"0 9 1 * mon"}));
    assert_eq!(
        or.next_after(date("2026-11-02T09:00:00Z")).unwrap(),
        Some(date("2026-11-09T09:00:00Z"))
    );
}
#[test]
fn store_schedule_preserves_unknown_fields_and_pending_approval() {
    let raw = json!({"id":"11111111-1111-4111-8111-111111111111","projectID":"22222222-2222-4222-8222-222222222222","name":"Daily","prompt":"Check this","recurrence":recurrence(json!({"future":{"preserve":true}})),"isPaused":false,"awaitingApproval":true,"pendingDelivery":"2026-11-01T00:00:00Z","proposal":{"opaque":3},"future":{"data":[1,2,3]}});
    let mut task: ScheduledTask = serde_json::from_value(raw.clone()).unwrap();
    task.validate().unwrap();
    assert!(!task.is_active());
    task.is_paused = true;
    let roundtrip = serde_json::to_value(task).unwrap();
    for key in ["future", "proposal", "pendingDelivery"] {
        assert_eq!(roundtrip[key], raw[key]);
    }
    assert_eq!(
        roundtrip["recurrence"]["future"],
        raw["recurrence"]["future"]
    );
}
#[test]
fn store_schedule_invalid_inputs_fail_before_computing_next() {
    for patch in [
        json!({"timeZoneID":"not/a/zone"}),
        json!({"kind":"interval","intervalMinutes":4}),
        json!({"kind":"days","weekdays":[]}),
        json!({"kind":"days","weekdays":[8]}),
        json!({"kind":"future"}),
        json!({"date":"bad"}),
        json!({"hour":24}),
    ] {
        assert!(
            recurrence(patch)
                .next_after(date("2026-01-01T00:00:00Z"))
                .is_err()
        );
    }
}

#[test]
fn store_schedule_document_rejects_future_versions_duplicate_ids_and_bad_dates() {
    use coincide_core::scheduling::ScheduleDocument;
    let task = json!({"id":"11111111-1111-4111-8111-111111111111","projectID":"22222222-2222-4222-8222-222222222222","name":"Daily","prompt":"Check this","recurrence":recurrence(json!({})),"isPaused":false});
    for value in [
        json!({"version":2,"tasks":[]}),
        json!({"version":1,"tasks":[task.clone(),task.clone()]}),
    ] {
        assert!(
            serde_json::from_value::<ScheduleDocument>(value)
                .unwrap()
                .validate()
                .is_err()
        );
    }
    let mut invalid = task.clone();
    invalid["nextRunAt"] = json!("broken");
    assert!(
        serde_json::from_value::<ScheduledTask>(invalid)
            .unwrap()
            .validate()
            .is_err()
    );
    let doc: ScheduleDocument =
        serde_json::from_value(json!({"version":1,"tasks":[task],"future":{"keep":true}})).unwrap();
    doc.validate().unwrap();
    assert_eq!(
        serde_json::to_value(doc).unwrap()["future"],
        json!({"keep":true})
    );
}
