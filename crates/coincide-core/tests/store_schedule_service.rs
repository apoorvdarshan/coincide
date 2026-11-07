use chrono::{DateTime, Utc};
use coincide_core::{
    schedule_service::{Outcome, ScheduleService, TargetState},
    store::Store,
};
use serde_json::{Value, json};
fn at(text: &str) -> DateTime<Utc> {
    text.parse().unwrap()
}
fn start() -> DateTime<Utc> {
    at("2026-11-05T00:00:00Z")
}
fn due() -> DateTime<Utc> {
    at("2026-11-05T00:05:00Z")
}
fn fixture() -> (tempfile::TempDir, Store, Value) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("data/db.sqlite")).unwrap();
    let project = store.create_project(dir.path(), Some("Test")).unwrap();
    let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    (dir, store, thread)
}
fn input(thread: &Value) -> Value {
    json!({"name":"Check","prompt":"Check status","projectID":thread["projectID"],"threadID":thread["id"],"recurrence":{"kind":"interval","timeZoneID":"UTC","date":"2026-11-05T00:00:00Z","hour":0,"minute":0,"weekday":1,"intervalMinutes":5}})
}
fn create_approved(store: &mut Store, thread: &Value) -> String {
    let mut service = ScheduleService::new(store);
    let v = service.create(&input(thread), start()).unwrap();
    let id = v["id"].as_str().unwrap().to_owned();
    service.approve(&id, start()).unwrap();
    id
}
#[test]
fn store_schedule_requires_approval_and_claim_is_durable_and_idempotent() {
    let (_dir, mut store, thread) = fixture();
    let mut service = ScheduleService::new(&mut store);
    let v = service.create(&input(&thread), start()).unwrap();
    let id = v["id"].as_str().unwrap();
    assert!(service.plan_due(due()).unwrap().is_empty());
    assert!(service.plan_now(id, due()).is_err());
    service.approve(id, start()).unwrap();
    let job = service.plan_due(due()).unwrap().remove(0);
    let claim = service
        .claim(&job, TargetState::Ready, due())
        .unwrap()
        .unwrap();
    let saved = service.list().unwrap().remove(0);
    assert_eq!(saved["rustClaim"]["claimId"], claim.claim_id);
    assert_eq!(saved["activeThreadID"], thread["id"]);
    assert!(
        service
            .claim(&job, TargetState::Ready, due())
            .unwrap()
            .is_none()
    );
    assert!(
        service
            .complete(&claim.claim_id, Outcome::Completed, None, due())
            .unwrap()
    );
    assert!(
        !service
            .complete(&claim.claim_id, Outcome::Failed, Some("stale retry"), due())
            .unwrap()
    );
    assert_eq!(service.list().unwrap()[0]["lastOutcome"], "completed");
    assert!(
        service
            .claim(&job, TargetState::Ready, due())
            .unwrap()
            .is_none()
    );
}
#[test]
fn store_schedule_busy_thread_defers_one_run_without_backlog() {
    let (_dir, mut store, thread) = fixture();
    create_approved(&mut store, &thread);
    let mut service = ScheduleService::new(&mut store);
    let job = service.plan_due(due()).unwrap().remove(0);
    assert!(
        service
            .claim(&job, TargetState::Busy, due())
            .unwrap()
            .is_none()
    );
    let later = at("2026-11-05T00:25:00Z");
    let pending = service.plan_due(later).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].occurrence, due());
    assert!(
        service
            .claim(&pending[0], TargetState::Busy, later)
            .unwrap()
            .is_none()
    );
    let claim = service
        .claim(&pending[0], TargetState::Ready, later)
        .unwrap()
        .unwrap();
    assert_eq!(claim.occurrence, due());
    assert!(service.plan_due(later).unwrap().is_empty());
    assert!(
        service
            .claim(&pending[0], TargetState::Ready, later)
            .unwrap()
            .is_none()
    );
    assert!(service.list().unwrap()[0]["pendingDelivery"].is_null());
}
#[test]
fn store_schedule_restart_interrupts_claims_and_skips_pending_and_missed_occurrences() {
    let (dir, mut store, thread) = fixture();
    let id = create_approved(&mut store, &thread);
    let claim = {
        let mut service = ScheduleService::new(&mut store);
        let job = service.plan_due(due()).unwrap().remove(0);
        service
            .claim(&job, TargetState::Ready, due())
            .unwrap()
            .unwrap()
    };
    drop(store);
    let mut store = Store::open(&dir.path().join("data/db.sqlite")).unwrap();
    let later = at("2026-11-05T01:00:00Z");
    let mut service = ScheduleService::new(&mut store);
    assert_eq!(service.recover(later, true).unwrap(), 1);
    assert!(service.plan_due(later).unwrap().is_empty());
    assert_eq!(service.list().unwrap()[0]["lastOutcome"], "interrupted");
    assert!(
        !service
            .complete(&claim.claim_id, Outcome::Completed, None, later)
            .unwrap()
    );
    let job = service.plan_now(&id, later).unwrap();
    assert!(
        service
            .claim(&job, TargetState::Busy, later)
            .unwrap()
            .is_none()
    );
    service.recover(later, true).unwrap();
    assert!(service.list().unwrap()[0]["pendingDelivery"].is_null());
    assert!(service.plan_due(later).unwrap().is_empty());
}
#[test]
fn store_schedule_patch_preserves_live_claim_and_requires_reapproval() {
    let (_dir, mut store, thread) = fixture();
    let id = create_approved(&mut store, &thread);
    let mut service = ScheduleService::new(&mut store);
    let stale = service.plan_due(due()).unwrap().remove(0);
    let claim = service
        .claim(&stale, TargetState::Ready, due())
        .unwrap()
        .unwrap();
    let changed = service
        .patch(&id, &json!({"prompt":"New prompt"}), due())
        .unwrap();
    assert_eq!(changed["rustClaim"]["claimId"], claim.claim_id);
    assert_eq!(changed["awaitingApproval"], true);
    assert!(service.claim(&stale, TargetState::Ready, due()).is_err());
    assert!(service.plan_now(&id, due()).is_err());
    assert!(
        service
            .complete(&claim.claim_id, Outcome::Completed, None, due())
            .unwrap()
    );
    service.approve(&id, due()).unwrap();
    let later = at("2026-11-05T00:10:00Z");
    let job = service.plan_due(later).unwrap().remove(0);
    assert_eq!(
        service
            .claim(&job, TargetState::Ready, later)
            .unwrap()
            .unwrap()
            .prompt,
        "New prompt"
    );
}
#[test]
fn store_schedule_preserves_unknown_envelope_task_and_original_fields() {
    let (_dir, mut store, thread) = fixture();
    let id = create_approved(&mut store, &thread);
    let mut document = store.document("scheduled-tasks.json").unwrap().unwrap();
    document["future"] = json!({"envelope":true});
    document["tasks"][0]["future"] = json!({"task":[1,2,3]});
    document["tasks"][0]["recurrence"]["future"] = json!(7);
    store
        .save_document("scheduled-tasks.json", &document)
        .unwrap();
    let mut service = ScheduleService::new(&mut store);
    service.set_paused(&id, true, due()).unwrap();
    service
        .patch(&id, &json!({"name":"Renamed"}), due())
        .unwrap();
    let saved = store.document("scheduled-tasks.json").unwrap().unwrap();
    assert_eq!(saved["future"], document["future"]);
    assert_eq!(saved["tasks"][0]["future"], document["tasks"][0]["future"]);
    assert_eq!(saved["tasks"][0]["recurrence"]["future"], 7);
}
#[test]
fn store_schedule_malformed_document_cannot_be_overwritten_and_fields_are_not_privilege_controls() {
    let (_dir, mut store, thread) = fixture();
    store
        .save_document("scheduled-tasks.json", &json!({"version":99,"tasks":[]}))
        .unwrap();
    let before = store.document("scheduled-tasks.json").unwrap();
    assert!(
        ScheduleService::new(&mut store)
            .create(&input(&thread), start())
            .is_err()
    );
    assert_eq!(store.document("scheduled-tasks.json").unwrap(), before);
    store
        .save_document("scheduled-tasks.json", &json!({"version":1,"tasks":[]}))
        .unwrap();
    let mut bad = input(&thread);
    bad["awaitingApproval"] = json!(false);
    assert!(
        ScheduleService::new(&mut store)
            .create(&bad, start())
            .is_err()
    );
    let id = create_approved(&mut store, &thread);
    assert!(
        ScheduleService::new(&mut store)
            .patch(&id, &json!({"awaitingApproval":false}), start())
            .is_err()
    );
}
#[test]
fn store_schedule_archived_target_pauses_and_manual_resume_checks_real_thread() {
    let (_dir, mut store, thread) = fixture();
    let id = create_approved(&mut store, &thread);
    store
        .patch_thread(thread["id"].as_str().unwrap(), &json!({"isArchived":true}))
        .unwrap();
    let mut service = ScheduleService::new(&mut store);
    let job = service.plan_due(due()).unwrap().remove(0);
    assert!(
        service
            .claim(&job, TargetState::Archived, due())
            .unwrap()
            .is_none()
    );
    assert_eq!(service.list().unwrap()[0]["pauseReason"], "threadArchived");
    assert!(service.set_paused(&id, false, due()).is_err());
    assert!(service.delete(&id).unwrap());
    assert!(!service.delete(&id).unwrap());
    assert!(store.thread(thread["id"].as_str().unwrap()).is_ok());
}
#[test]
fn store_schedule_project_claim_binding_and_old_completion_cannot_touch_new_run() {
    let (_dir, mut store, thread) = fixture();
    let mut project_input = input(&thread);
    project_input.as_object_mut().unwrap().remove("threadID");
    let mut service = ScheduleService::new(&mut store);
    let v = service.create(&project_input, start()).unwrap();
    let id = v["id"].as_str().unwrap();
    service.approve(id, start()).unwrap();
    let job = service.plan_due(due()).unwrap().remove(0);
    let first = service
        .claim(&job, TargetState::Ready, due())
        .unwrap()
        .unwrap();
    assert!(first.thread_id.is_none());
    assert!(
        service
            .attach_thread(&first.claim_id, thread["id"].as_str().unwrap())
            .unwrap()
    );
    assert!(
        service
            .complete(&first.claim_id, Outcome::Completed, None, due())
            .unwrap()
    );
    let later = at("2026-11-05T00:10:00Z");
    let job = service.plan_due(later).unwrap().remove(0);
    let second = service
        .claim(&job, TargetState::Ready, later)
        .unwrap()
        .unwrap();
    assert!(
        !service
            .complete(&first.claim_id, Outcome::Failed, None, later)
            .unwrap()
    );
    assert_eq!(
        service.list().unwrap()[0]["rustClaim"]["claimId"],
        second.claim_id
    );
}

#[test]
fn store_schedule_only_project_tasks_move_to_another_existing_project() {
    let (dir, mut store, thread) = fixture();
    let other_path = dir.path().join("other");
    std::fs::create_dir(&other_path).unwrap();
    let other = store.create_project(&other_path, Some("Other")).unwrap();
    let mut project_input = input(&thread);
    project_input.as_object_mut().unwrap().remove("threadID");
    let mut service = ScheduleService::new(&mut store);
    let project_task = service.create(&project_input, start()).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let thread_task = service.create(&input(&thread), start()).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    service.approve(&project_task, start()).unwrap();
    let moved = service
        .patch(&project_task, &json!({"projectID":other["id"]}), start())
        .unwrap();
    assert_eq!(moved["projectID"], other["id"]);
    assert!(moved.get("threadID").is_none());
    assert_ne!(
        service.approval_state(&project_task).unwrap(),
        coincide_core::schedule_service::ApprovalState::Approved
    );
    assert!(
        service
            .patch(&thread_task, &json!({"projectID":other["id"]}), start())
            .is_err()
    );
    assert!(
        service
            .patch(
                &project_task,
                &json!({"projectID":"7E57AB1E-0000-4000-8000-000000000000"}),
                start()
            )
            .is_err()
    );
    let saved = service.list().unwrap();
    assert_eq!(saved[0]["projectID"], other["id"]);
    assert_eq!(saved[1]["projectID"], thread["projectID"]);
}
#[test]
fn store_schedule_manual_once_never_rearms_on_pause_or_name_edit() {
    let (_dir, mut store, thread) = fixture();
    let mut once = input(&thread);
    once["recurrence"]["kind"] = json!("once");
    once["recurrence"]["date"] = json!("2026-11-06T00:00:00Z");
    let mut service = ScheduleService::new(&mut store);
    let created = service.create(&once, start()).unwrap();
    let id = created["id"].as_str().unwrap();
    service.approve(id, start()).unwrap();
    let job = service.plan_now(id, due()).unwrap();
    let claim = service
        .claim(&job, TargetState::Ready, due())
        .unwrap()
        .unwrap();
    service
        .complete(&claim.claim_id, Outcome::Completed, None, due())
        .unwrap();
    service.set_paused(id, true, due()).unwrap();
    service.set_paused(id, false, due()).unwrap();
    service
        .patch(id, &json!({"name":"Renamed"}), due())
        .unwrap();
    service.approve(id, due()).unwrap();
    assert!(service.list().unwrap()[0]["nextRunAt"].is_null());
    assert!(
        service
            .plan_due(at("2026-11-06T00:00:00Z"))
            .unwrap()
            .is_empty()
    );
}
#[test]
fn store_schedule_spent_once_can_be_renamed_and_allowed_after_its_date() {
    let (_dir, mut store, thread) = fixture();
    let mut once = input(&thread);
    once["recurrence"]["kind"] = json!("once");
    once["recurrence"]["date"] = json!("2026-11-05T00:04:00Z");
    let mut service = ScheduleService::new(&mut store);
    let id = service.create(&once, start()).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    service.approve(&id, start()).unwrap();
    let job = service.plan_due(due()).unwrap().remove(0);
    let claim = service
        .claim(&job, TargetState::Ready, due())
        .unwrap()
        .unwrap();
    service
        .complete(&claim.claim_id, Outcome::Completed, None, due())
        .unwrap();
    let later = at("2026-11-07T00:00:00Z");
    service
        .patch(&id, &json!({"name":"Renamed"}), later)
        .unwrap();
    let allowed = service.approve(&id, later).unwrap();
    assert!(allowed.newly_approved);
    assert!(allowed.task["nextRunAt"].is_null());
    assert!(service.plan_due(later).unwrap().is_empty());
    // Choosing another past date is still refused.
    let mut past = once["recurrence"].clone();
    past["date"] = json!("2026-11-06T00:00:00Z");
    assert!(
        service
            .patch(&id, &json!({"recurrence":past}), later)
            .is_err()
    );
}
#[test]
fn store_schedule_project_completion_skips_overlapping_slots() {
    let (_dir, mut store, thread) = fixture();
    let mut input = input(&thread);
    input.as_object_mut().unwrap().remove("threadID");
    let mut service = ScheduleService::new(&mut store);
    let created = service.create(&input, start()).unwrap();
    service
        .approve(created["id"].as_str().unwrap(), start())
        .unwrap();
    let job = service.plan_due(due()).unwrap().remove(0);
    let claim = service
        .claim(&job, TargetState::Ready, due())
        .unwrap()
        .unwrap();
    let later = at("2026-11-05T00:26:00Z");
    let stale = service.plan_due(later).unwrap().remove(0);
    service
        .complete(&claim.claim_id, Outcome::Completed, None, later)
        .unwrap();
    assert!(service.plan_due(later).unwrap().is_empty());
    assert!(
        service
            .claim(&stale, TargetState::Ready, later)
            .unwrap()
            .is_none()
    );
}

#[test]
fn store_schedule_imported_swift_approval_never_authorizes_rust_execution() {
    use coincide_core::schedule_service::ApprovalState;
    let (_dir, mut store, thread) = fixture();
    let id = create_approved(&mut store, &thread);
    let mut document = store.document("scheduled-tasks.json").unwrap().unwrap();
    document["tasks"][0]
        .as_object_mut()
        .unwrap()
        .remove("rustRevision");
    document["tasks"][0]
        .as_object_mut()
        .unwrap()
        .remove("rustApprovedRevision");
    document["tasks"][0]
        .as_object_mut()
        .unwrap()
        .remove("awaitingApproval");
    store
        .save_document("scheduled-tasks.json", &document)
        .unwrap();
    let mut service = ScheduleService::new(&mut store);
    assert!(service.plan_due(due()).unwrap().is_empty());
    assert!(service.plan_now(&id, due()).is_err());
    assert_eq!(
        service.approval_state(&id).unwrap(),
        ApprovalState::AwaitingRustApproval
    );
    let approved = service.approve(&id, start()).unwrap();
    assert!(approved.newly_approved);
    assert_eq!(approved.state, ApprovalState::Approved);
    assert!(!service.approve(&id, start()).unwrap().newly_approved);
    let stale = service.plan_due(due()).unwrap().remove(0);
    service
        .patch(&id, &json!({"name":"Edited"}), start())
        .unwrap();
    assert!(service.plan_due(due()).unwrap().is_empty());
    assert!(service.claim(&stale, TargetState::Ready, due()).is_err());
    service.approve(&id, start()).unwrap();
    service.set_paused(&id, true, start()).unwrap();
    service.set_paused(&id, false, start()).unwrap();
    assert_eq!(
        service.approval_state(&id).unwrap(),
        ApprovalState::Approved
    );
    assert_eq!(service.plan_due(due()).unwrap().len(), 1);
}

#[test]
fn store_schedule_unavailable_consumes_pending_without_replaying_when_ready() {
    let (_dir, mut store, thread) = fixture();
    create_approved(&mut store, &thread);
    let mut service = ScheduleService::new(&mut store);
    let job = service.plan_due(due()).unwrap().remove(0);
    assert!(
        service
            .claim(&job, TargetState::Busy, due())
            .unwrap()
            .is_none()
    );
    let later = at("2026-11-05T00:12:00Z");
    let pending = service.plan_due(later).unwrap().remove(0);
    assert!(
        service
            .claim(&pending, TargetState::Unavailable, later)
            .unwrap()
            .is_none()
    );
    let saved = service.list().unwrap().remove(0);
    assert!(saved["pendingDelivery"].is_null());
    assert_eq!(saved["lastOutcome"], "missed");
    assert!(service.plan_due(later).unwrap().is_empty());
    assert!(
        service
            .claim(&pending, TargetState::Ready, later)
            .unwrap()
            .is_none()
    );
    assert_eq!(service.list().unwrap()[0], saved);
    let next = at("2026-11-05T00:15:00Z");
    let job = service.plan_due(next).unwrap().remove(0);
    let claim = service
        .claim(&job, TargetState::Ready, next)
        .unwrap()
        .unwrap();
    assert_eq!(claim.occurrence, next);
}
