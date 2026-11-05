//! Attachment worker/result integration against an isolated, discovery-free Engine.
use super::*;
use std::sync::mpsc;
use std::time::Duration;

fn saturated_import(valid_image: bool, expired: bool) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
    let project = store.create_project(dir.path(), Some("fixture")).unwrap();
    let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    let owner = thread["id"].as_str().unwrap().to_owned();
    let mut engine = Engine::fixture(store);
    let source = dir.path().join("source.png");
    if valid_image {
        image::RgbaImage::from_pixel(2, 2, image::Rgba([1, 2, 3, 255]))
            .save(&source)
            .unwrap();
    }
    let root = engine.store.data_directory().unwrap();
    let (tx, rx) = mpsc::sync_channel(32);
    engine.workspace_tx = tx.clone();
    engine.workspace_rx = rx;
    for index in 0..32 {
        tx.try_send((format!("unrelated-{index}"), json!({})))
            .unwrap();
    }
    // Register the same ownership as attachments.add, keeping the saturated
    // completion mailbox intact (dispatch normally polls before admission).
    let id = Uuid::new_v4().to_string();
    let age = if expired {
        Duration::from_secs(301)
    } else {
        Duration::ZERO
    };
    engine
        .workspace_pending
        .insert(id.clone(), (owner.clone(), Instant::now() - age));
    engine.attachment_operations.insert(id.clone());
    let operation = id.clone();
    let activity = engine.idle_sleep.background_job();
    let (done_tx, done_rx) = mpsc::channel();
    let (saturated_tx, saturated_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let _activity = activity;
        // The production attachments.add worker calls this exact ingestion +
        // completion path; no provider, native host, or environment discovery.
        import_attachment(root, source, tx, operation, || {
            saturated_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
        done_tx.send(()).unwrap();
    });
    // This acknowledgement is emitted only after the production completion
    // publisher receives TrySendError::Full for this ingested result. The
    // timeout is solely a deadlock watchdog, never evidence of saturation.
    saturated_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(engine.attachment_operations.contains(&id));
    assert_eq!(done_rx.try_recv(), Err(mpsc::TryRecvError::Empty));
    // Keep the worker gated while polling: poll must return without waiting for
    // publication. It drains exactly the unrelated, prefilled mailbox entries.
    engine.poll();
    if expired {
        assert!(!engine.workspace_pending.contains_key(&id));
    }
    assert!(engine.attachment_operations.contains(&id));
    assert!(!engine.workspace_results.contains_key(&id));
    release_tx.send(()).unwrap();
    done_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    worker.join().unwrap();
    engine.poll();
    assert!(!engine.attachment_operations.contains(&id));
    let persisted = engine.store.thread(&owner).unwrap();
    if expired {
        assert!(!engine.workspace_pending.contains_key(&id));
        assert!(!engine.workspace_results.contains_key(&id));
        assert!(
            persisted["rustDraftImages"]
                .as_array()
                .is_none_or(Vec::is_empty)
        );
    } else {
        let response = engine
            .execute(
                "workspace.result",
                &json!({
                    "threadId":owner,"operationId":id
                }),
            )
            .unwrap();
        assert_eq!(response["ready"], true);
        if valid_image {
            assert!(response["result"]["error"].is_null(), "{response}");
            assert_eq!(persisted["rustDraftImages"].as_array().unwrap().len(), 1);
            assert_eq!(
                persisted["rustDraftImages"][0],
                response["result"]["attachment"]
            );
        } else {
            assert!(response["result"]["error"].is_string(), "{response}");
            assert!(
                persisted["rustDraftImages"]
                    .as_array()
                    .is_none_or(Vec::is_empty)
            );
        }
        assert!(!engine.workspace_pending.contains_key(&id));
        assert!(!engine.workspace_results.contains_key(&id));
    }
    // Repeated polls cannot append the delivered attachment a second time.
    engine.poll();
    assert_eq!(engine.store.thread(&owner).unwrap(), persisted);
}

#[test]
fn saturated_attachment_success_is_delivered_and_persisted_once() {
    saturated_import(true, false);
}

#[test]
fn saturated_attachment_failure_is_delivered_and_releases_ownership() {
    saturated_import(false, false);
}

#[test]
fn expired_attachment_still_releases_ownership_after_saturated_delivery() {
    saturated_import(true, true);
}
