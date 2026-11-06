//! Cross-layer synthetic fixtures: real service-created opaque IDs and owned image
//! files -> actual recovery persistence/readback -> exact token -> explicit ack.
//! No live data, native picker, provider, API or visibility relaxation.
#![cfg(unix)]

use coincide_core::{
    legacy_media::{ApprovedRoot, MediaBatch, Status},
    legacy_media_recovery::{DurableOwnership, RecoveryError, RecoveryStore},
    legacy_media_service::{
        CompletionReceipt, LegacyMediaService, OperationId, ReceiptId, RootCapability,
        SelectionToken, ServiceConfig, ServiceError, ServiceEvent,
    },
    store::Store,
};
use image::{DynamicImage, ImageFormat};
use serde_json::{Value, json};
use std::{
    fs,
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};

// Exercise the REAL parent worker/controller, without bringing GPUI into core or
// editing manifests. This module depends only on coincide-core + std.
#[path = "../../coincide-desktop/src/legacy_media_recovery.rs"]
mod parent_controller;
use parent_controller::ParentRecoveryOwner;

const ITEM: &str = "00000000-0000-4000-8000-000000000002";
struct Fixture {
    _temporary: tempfile::TempDir,
    config: ServiceConfig,
    thread: Value,
    original_thread_bytes: Vec<u8>,
    source: PathBuf,
    png: Vec<u8>,
}
impl Fixture {
    fn new() -> Self {
        let temporary = tempfile::tempdir().unwrap();
        let base = temporary.path().canonicalize().unwrap();
        let source = base.join("approved-source");
        fs::create_dir(&source).unwrap();
        let mut bytes = std::io::Cursor::new(Vec::new());
        DynamicImage::new_rgba8(2, 2)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();
        let png = bytes.into_inner();
        for name in ["one.png", "duplicate.png", "changed.png"] {
            fs::write(source.join(name), &png).unwrap();
        }
        let database_path = base.join("rust-owned/state.sqlite");
        let mut store = Store::open(&database_path).unwrap();
        let mut thread = store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        // Keep the ACTUAL native Store ID/casing. No opaque ID is constructed here.
        let id = thread["id"].as_str().unwrap().to_owned();
        assert_eq!(id, id.to_ascii_uppercase());
        thread["draft"] = json!("Retain this unsent synthetic draft");
        thread["items"] = json!([{"id":ITEM,"kind":"user","text":"historical fixture",
            "attachments":["/old-images/one.png","/old-images/duplicate.png","/old-images/changed.png"],
            "unknown":{"keep":[1,"two",true]}}]);
        store.save(&thread).unwrap();
        store
            .save_document("bots.json", &json!({"synthetic":"unchanged"}))
            .unwrap();
        let original_thread_bytes = serde_json::to_vec(&thread).unwrap();
        let db = rusqlite::Connection::open(&database_path).unwrap();
        db.execute(
            "INSERT INTO original_files(path,data) VALUES (?1,?2)",
            rusqlite::params![format!("threads/{id}.json"), &original_thread_bytes],
        )
        .unwrap();
        let expected_data_directory = database_path.parent().unwrap().to_owned();
        drop(db);
        drop(store);
        Self {
            _temporary: temporary,
            config: ServiceConfig {
                database_path,
                expected_data_directory,
            },
            thread,
            original_thread_bytes,
            source,
            png,
        }
    }
    fn service(&self) -> (LegacyMediaService, SelectionToken, RootCapability) {
        let mut service = LegacyMediaService::spawn(self.config.clone());
        let selected = service.select_thread(Some(self.thread["id"].as_str().unwrap().into()));
        let root = ApprovedRoot::new(
            "synthetic-native-approval".into(),
            PathBuf::from("/old-images"),
            self.source.clone(),
        )
        .unwrap();
        let capability = service
            .approve_roots_native(&selected, vec![root], None)
            .unwrap();
        (service, selected, capability)
    }
    fn assert_originals(&self) {
        let store = Store::open_existing_for_legacy_media(
            &self.config.database_path,
            &self.config.expected_data_directory,
        )
        .unwrap();
        let id = self.thread["id"].as_str().unwrap();
        assert_eq!(store.thread(id).unwrap(), self.thread);
        assert_eq!(
            store
                .original(&format!("threads/{id}.json"))
                .unwrap()
                .unwrap(),
            self.original_thread_bytes
        );
        assert_eq!(
            store.document("bots.json").unwrap().unwrap(),
            json!({"synthetic":"unchanged"})
        );
        assert_eq!(fs::read(self.source.join("one.png")).unwrap(), self.png);
        assert_eq!(
            fs::read(self.source.join("duplicate.png")).unwrap(),
            self.png
        );
    }
}
fn event_id(event: &ServiceEvent) -> OperationId {
    match event {
        ServiceEvent::Inspected { operation_id, .. }
        | ServiceEvent::Validated { operation_id, .. }
        | ServiceEvent::Finished { operation_id, .. }
        | ServiceEvent::Rendered { operation_id, .. }
        | ServiceEvent::Failed { operation_id, .. } => *operation_id,
    }
}
fn wait(service: &mut LegacyMediaService, operation: OperationId) -> ServiceEvent {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let mut events = service.poll();
        assert!(
            events.len() <= 1,
            "unexpected concurrent service fixture results"
        );
        if let Some(event) = events.pop() {
            assert_eq!(
                event_id(&event),
                operation,
                "unexpected service fixture operation"
            );
            return event;
        }
        assert!(Instant::now() < deadline, "service fixture timeout");
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn create_receipt(
    f: &Fixture,
    service: &mut LegacyMediaService,
    selected: &SelectionToken,
    capability: &RootCapability,
    reject_overlay: bool,
) -> (ReceiptId, Arc<CompletionReceipt>) {
    let operation = service.inspect(selected, capability, 0).unwrap();
    let ServiceEvent::Inspected {
        plan_id,
        candidates,
        ..
    } = wait(service, operation)
    else {
        panic!("expected real inspection")
    };
    assert_eq!(candidates.len(), 3);
    let ids = candidates
        .into_iter()
        .map(|c| c.candidate_id)
        .collect::<Vec<_>>();
    let operation = service.validate(selected, plan_id, ids.clone()).unwrap();
    let ServiceEvent::Validated {
        preview_id,
        references,
        ..
    } = wait(service, operation)
    else {
        panic!("expected real preview")
    };
    assert!(references.iter().all(|r| r.status == Status::Ready));
    // Deterministic external source change AFTER real preview; first two copies
    // remain valid and reuse one real ingested StoredImage identity.
    fs::write(
        f.source.join("changed.png"),
        b"synthetic external source change",
    )
    .unwrap();
    if reject_overlay {
        let db = rusqlite::Connection::open(&f.config.database_path).unwrap();
        db.execute_batch("CREATE TRIGGER reject_fixture_overlay BEFORE INSERT ON documents WHEN NEW.name LIKE 'rust-legacy-media-%' BEGIN SELECT RAISE(ABORT,'synthetic overlay commit failure'); END;").unwrap();
    }
    let operation = service.confirm(selected, preview_id, ids).unwrap();
    let ServiceEvent::Finished { receipt_id, .. } = wait(service, operation) else {
        panic!("expected real materialization receipt")
    };
    let receipt = service.receipt(receipt_id).unwrap();
    assert_eq!(receipt.operation_id, operation);
    assert_eq!(receipt.thread_id, f.thread["id"].as_str().unwrap());
    assert_eq!(receipt.batch.references.len(), 3);
    let first = receipt.batch.references[0].image.as_ref().unwrap();
    let duplicate = receipt.batch.references[1].image.as_ref().unwrap();
    assert_eq!(first.id, duplicate.id);
    assert_eq!(first.path, duplicate.path);
    assert!(first.path.is_file() && first.original_path.is_file());
    assert_eq!(
        receipt.batch.references[2].reference.status,
        Status::Changed
    );
    assert!(receipt.batch.references[2].image.is_none());
    (receipt_id, receipt)
}
fn snapshot(id: ReceiptId, receipt: &CompletionReceipt) -> Value {
    // Exact existing recovery snapshot schema; batch Serialize is authoritative.
    json!({"receiptId":id.to_string(),"operationId":receipt.operation_id.to_string(),
        "threadId":receipt.thread_id,"generation":receipt.generation,"committed":receipt.committed,
        "error":receipt.error.as_ref().map(ToString::to_string),"batch":receipt.batch,
        "committedCandidateIds":receipt.committed_candidate_ids})
}
fn wait_owner(owner: &mut ParentRecoveryOwner, expected: ReceiptId) -> DurableOwnership {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(outcome) = owner.poll() {
            assert_eq!(outcome.receipt_id, expected);
            return outcome.result.unwrap();
        }
        assert!(Instant::now() < deadline, "recovery owner fixture timeout");
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn reopen(config: &ServiceConfig) -> RecoveryStore {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match RecoveryStore::open(config) {
            Ok(store) => return store,
            Err(RecoveryError::Busy) => {} // previous controller worker is releasing its flock
            Err(error) => panic!("unexpected recovery reopen failure: {error:?}"),
        }
        assert!(Instant::now() < deadline, "recovery reopen fixture timeout");
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn controller_lifecycle(reject_overlay: bool) {
    let f = Fixture::new();
    let (mut service, selected, capability) = f.service();
    let (id, receipt) = create_receipt(&f, &mut service, &selected, &capability, reject_overlay);
    assert_eq!(receipt.committed, !reject_overlay);
    if reject_overlay {
        assert_eq!(receipt.error, Some(ServiceError::CommitFailed));
        assert_eq!(service.pending_recovery(), vec![id]);
        assert!(receipt.committed_candidate_ids.is_empty());
    } else {
        assert!(receipt.error.is_none());
        assert_eq!(receipt.committed_candidate_ids.len(), 2);
    }
    let expected = snapshot(id, &receipt);
    assert!(expected["batch"]["threadSha256"].is_string());
    assert!(expected["batch"].get("thread_sha256").is_none());
    let image = receipt.batch.references[0].image.as_ref().unwrap().clone();
    let mut owner = ParentRecoveryOwner::spawn(f.config.clone());
    assert!(!owner.shutdown_ready(false, 1));
    owner.take_ownership(id, receipt.clone()).unwrap();
    // Queueing/selection change/panel hide is not durable ownership or acknowledgment.
    service.select_thread(None);
    assert!(service.receipt(id).is_some());
    assert_eq!(owner.pending_receipts().len(), 1);
    assert!(!owner.shutdown_ready(true, 1));
    let token = wait_owner(&mut owner, id);
    assert!(token.matches(id, &receipt));
    assert_eq!(token.receipt_id(), id.to_string());
    assert_eq!(token.operation_id(), receipt.operation_id.to_string());
    assert_eq!(token.thread_id(), receipt.thread_id);
    assert!(owner.durable_ownership(id).unwrap().matches(id, &receipt));
    assert!(service.receipt(id).is_some());
    assert!(!owner.shutdown_ready(false, 1));
    // Exact typed token matches live retained receipt BEFORE controller/service ack.
    let current = service.receipt(id).unwrap();
    assert!(token.matches(id, &current));
    service.acknowledge_receipt(id).unwrap();
    assert!(service.receipt(id).is_none());
    // Failed/late acknowledgment cannot imply another materialization or deletion.
    assert!(service.acknowledge_receipt(id).is_err());
    assert_eq!(owner.pending_receipts().len(), 1);
    owner.acknowledged(id, &token).unwrap();
    assert!(owner.shutdown_ready(false, 0));
    assert!(owner.pending_receipts().is_empty());
    drop(owner);
    let recovered = reopen(&f.config);
    let records = recovered.retained().unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].private_receipt(), &expected);
    assert_eq!(records[0].digest(), token.digest());
    assert!(records[0].database_identity_current());
    assert_eq!(records[0].thread_id(), receipt.thread_id);
    assert!(image.path.is_file() && image.original_path.is_file()); // ack is never cleanup
    f.assert_originals();
}
#[test]
fn real_partial_duplicate_service_receipt_roundtrips_through_parent_controller_before_ack() {
    controller_lifecycle(false);
}
#[test]
fn real_failed_overlay_receipt_is_owned_durably_before_ack_without_deleting_copies() {
    controller_lifecycle(true);
}
#[test]
fn injected_final_validation_and_commit_unknown_metadata_preserve_real_ids_but_cannot_ack_another_snapshot()
 {
    let f = Fixture::new();
    let (mut service, selected, capability) = f.service();
    let (id, original) = create_receipt(&f, &mut service, &selected, &capability, true);
    // Explicit metadata injection from an actual service batch, NOT a claimed
    // deterministic internal service failure. Opaque IDs/files are still real;
    // no private constructors, cfg hooks or visibility changes are used.
    let mut references = original.batch.references.clone();
    references[0].reference.status = Status::IoError;
    references[0].normalized_sha256 = None;
    references[0].validation_error = Some("synthetic final managed validation failure".into());
    let image = references[0].image.as_ref().unwrap().clone();
    assert_eq!(image.id, references[1].image.as_ref().unwrap().id);
    let injected = CompletionReceipt {
        operation_id: original.operation_id,
        thread_id: original.thread_id.clone(),
        generation: original.generation,
        committed: false,
        error: Some(ServiceError::CommitUnknown),
        batch: MediaBatch {
            thread_sha256: original.batch.thread_sha256.clone(),
            references,
        },
        committed_candidate_ids: Vec::new(),
    };
    let expected = snapshot(id, &injected);
    let mut recovery = RecoveryStore::open(&f.config).unwrap();
    let token = recovery.persist(id, &injected).unwrap();
    assert!(token.matches(id, &injected));
    assert!(!token.matches(id, &original)); // exact snapshot authority, not merely matching ID strings
    let record = recovery.retained().unwrap().pop().unwrap();
    assert_eq!(record.private_receipt(), &expected);
    assert_eq!(record.private_receipt()["error"], "CommitUnknown");
    assert_eq!(record.private_receipt()["committed"], false); // never interpreted as rollback
    let rows = record.private_receipt()["batch"]["references"]
        .as_array()
        .unwrap();
    assert_eq!(rows[0]["image"], rows[1]["image"]);
    assert!(rows[0]["normalizedSha256"].is_null());
    assert_eq!(rows[0]["reference"]["status"], "ioError");
    assert!(rows[0]["validationError"].is_string());
    assert!(image.path.is_file() && image.original_path.is_file());
    assert!(service.receipt(id).is_some()); // mismatched token must NOT acknowledge original
    assert_eq!(service.pending_recovery(), vec![id]);
    drop(recovery);
    let mut owner = ParentRecoveryOwner::spawn(f.config.clone());
    owner.take_ownership(id, original.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(outcome) = owner.poll() {
            assert_eq!(outcome.receipt_id, id);
            assert!(matches!(outcome.result, Err(RecoveryError::Conflict)));
            break;
        }
        assert!(
            Instant::now() < deadline,
            "conflicting ownership fixture timeout"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(owner.durable_ownership(id).is_none());
    assert_eq!(owner.pending_receipts().len(), 1);
    assert!(!owner.shutdown_ready(false, 1));
    assert!(service.receipt(id).is_some());
    assert!(image.path.is_file() && image.original_path.is_file());
    f.assert_originals();
}
