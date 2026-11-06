use coincide_core::scheduling::{format_local_datetime, parse_local_datetime};
use serde_json::json;

#[test]
fn editor_round_trip_uses_schedule_zone_and_accepts_legacy_epoch() {
    let date = parse_local_datetime("2026-11-05", "09:30", "Asia/Kolkata").unwrap();
    assert_eq!(date.to_rfc3339(), "2026-11-05T04:00:00+00:00");
    assert_eq!(
        format_local_datetime(&json!(date.to_rfc3339()), "Asia/Kolkata").unwrap(),
        ("2026-11-05".into(), "09:30".into())
    );
    assert_eq!(
        format_local_datetime(&json!(0), "Asia/Kolkata").unwrap(),
        ("2001-01-01".into(), "05:30".into())
    );
}

#[test]
fn editor_matches_recurrence_gap_and_fold_policy() {
    let gap = parse_local_datetime("2026-03-08", "02:30", "America/New_York").unwrap();
    assert_eq!(gap.to_rfc3339(), "2026-03-08T07:00:00+00:00");
    assert_eq!(
        format_local_datetime(&json!(gap.to_rfc3339()), "America/New_York")
            .unwrap()
            .1,
        "03:00"
    );
    let fold = parse_local_datetime("2026-11-01", "01:30", "America/New_York").unwrap();
    assert_eq!(fold.to_rfc3339(), "2026-11-01T05:30:00+00:00");
    assert!(parse_local_datetime("2011-12-30", "12:00", "Pacific/Apia").is_err());
}

#[test]
fn editor_rejects_invalid_dates_times_and_zones() {
    for (date, time, zone) in [
        ("2026-02-30", "12:00", "UTC"),
        ("2026-11-05", "24:00", "UTC"),
        ("2026-11-05", "12:60", "UTC"),
        ("2026-11-05", "1:30", "UTC"),
        ("2026-11-05", "12:30", "Invalid/Zone"),
        ("2026-11-05", "😀1", "UTC"),
    ] {
        assert!(parse_local_datetime(date, time, zone).is_err());
    }
    assert!(format_local_datetime(&json!("bad-date"), "UTC").is_err());
}

#[test]
fn full_editor_patch_preserves_imported_timing_and_revokes_approval_for_every_kind() {
    use coincide_core::{schedule_service::ScheduleService, store::Store};
    let directory = tempfile::tempdir().unwrap();
    let mut store = Store::open(&directory.path().join("data/db.sqlite")).unwrap();
    let project = store
        .create_project(directory.path(), Some("Editor test"))
        .unwrap();
    let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    let now = "2026-11-05T00:00:00Z".parse().unwrap();
    let mut service = ScheduleService::new(&mut store);
    for kind in [
        "once", "daily", "weekly", "weekdays", "days", "interval", "cron",
    ] {
        // These seconds and this offset are absent from the minute-precision
        // editor. A rename must retain them, including an interval's phase.
        let recurrence = json!({
            "kind":kind,"timeZoneID":"Asia/Kolkata",
            "date":"2026-11-05T09:30:17.125+05:30",
            "hour":9,"minute":30,"weekday":5,"weekdays":[2,5],
            "intervalMinutes":17,"cron":"30 9 * * 1-5",
            "futureCalendarOptions":{"preserve":true}
        });
        let created = service
            .create(
                &json!({
                    "name":"Before","prompt":"Original prompt",
                    "projectID":thread["projectID"],"threadID":thread["id"],"recurrence":recurrence
                }),
                now,
            )
            .unwrap();
        let id = created["id"].as_str().unwrap();
        let approved = service.approve(id, now).unwrap().task;
        let patched = service
            .patch(
                id,
                &json!({
                    "name":"After","prompt":"Original prompt","recurrence":recurrence
                }),
                now,
            )
            .unwrap();
        assert_eq!(patched["recurrence"], recurrence, "{kind}");
        assert_eq!(patched["nextRunAt"], approved["nextRunAt"], "{kind}");
        assert_ne!(patched["rustRevision"], approved["rustRevision"], "{kind}");
        assert_eq!(patched["awaitingApproval"], true, "{kind}");
        assert!(patched["rustApprovedRevision"].is_null(), "{kind}");
        assert!(service.plan_now(id, now).is_err(), "{kind}");
    }
    let recurrence = json!({
        "kind":"interval","timeZoneID":"UTC","date":815544017.125,
        "hour":0,"minute":0,"weekday":1,"intervalMinutes":17
    });
    let created = service
        .create(
            &json!({
                "name":"Numeric date","prompt":"Check","projectID":thread["projectID"],
                "threadID":thread["id"],"recurrence":recurrence
            }),
            now,
        )
        .unwrap();
    let patched = service
        .patch(
            created["id"].as_str().unwrap(),
            &json!({
                "name":"Numeric date renamed","prompt":"Check","recurrence":recurrence
            }),
            now,
        )
        .unwrap();
    assert_eq!(patched["recurrence"]["date"], recurrence["date"]);
    assert_eq!(patched["nextRunAt"], created["nextRunAt"]);
}

#[test]
fn invalid_editor_patch_does_not_mutate_an_approved_schedule() {
    use coincide_core::{schedule_service::ScheduleService, store::Store};
    let directory = tempfile::tempdir().unwrap();
    let mut store = Store::open(&directory.path().join("data/db.sqlite")).unwrap();
    let project = store
        .create_project(directory.path(), Some("Editor test"))
        .unwrap();
    let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    let now = "2026-11-05T00:00:00Z".parse().unwrap();
    let mut service = ScheduleService::new(&mut store);
    let created = service
        .create(
            &json!({
                "name":"Preserve me","prompt":"Original prompt","projectID":thread["projectID"],
                "threadID":thread["id"],"recurrence":{
                    "kind":"once","timeZoneID":"UTC","date":"2026-11-06T12:00:00Z",
                    "hour":12,"minute":0,"weekday":1
                }
            }),
            now,
        )
        .unwrap();
    let id = created["id"].as_str().unwrap();
    let approved = service.approve(id, now).unwrap().task;
    for (field, invalid) in [
        ("timeZoneID", json!("Invalid/Zone")),
        ("date", json!("2026-11-04T12:00:00Z")),
        ("kind", json!("unknown")),
    ] {
        let mut recurrence = approved["recurrence"].clone();
        recurrence[field] = invalid;
        assert!(service.patch(id, &json!({
            "name":"Must not be saved","prompt":"Must not replace prompt","recurrence":recurrence
        }), now).is_err());
        assert_eq!(service.list().unwrap()[0], approved);
        assert!(service.plan_now(id, now).is_ok());
    }
}

#[test]
fn unchanged_fold_date_must_not_be_reconstructed_from_displayed_minutes() {
    // The editor preserves the original raw timestamp on unchanged date/time.
    // Re-parsing the display would silently shift a second-fold imported run.
    let original = json!("2026-11-01T01:30:47.125-05:00");
    let displayed = format_local_datetime(&original, "America/New_York").unwrap();
    assert_eq!(displayed, ("2026-11-01".into(), "01:30".into()));
    let reparsed = parse_local_datetime(&displayed.0, &displayed.1, "America/New_York").unwrap();
    let original_instant = coincide_core::scheduling::parse_date(&original).unwrap();
    assert_eq!(
        original_instant
            .signed_duration_since(reparsed)
            .num_milliseconds(),
        3_647_125
    );
}
