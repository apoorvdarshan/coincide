use super::*;
use crate::browser_bookmarks::{self, Library};
fn plan() -> browser_bookmarks::Plan {
    browser_bookmarks::preview(
        br#"{"bookmarks":[{"url":"https://example.com/saved","title":"Saved title"}]}"#,
    )
    .unwrap()
}
fn fixture() -> (tempfile::TempDir, Engine, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let id = engine.execute("threads.create", &json!({})).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    (dir, engine, id)
}
#[test]
fn explicit_import_survives_restart_preserves_source_and_ignores_captured_library() {
    let (dir, mut engine, _id) = fixture();
    let original = json!({"bookmarks":[{"url":"https://legacy.example/","title":"Captured only"}]});
    engine
        .store
        .save_document("browser-library.json", &original)
        .unwrap();
    let source = dir.path().join("chosen-export.json");
    let bytes = br#"{"bookmarks":[{"url":"https://example.com/saved","title":"Saved title"}]}"#;
    std::fs::write(&source, bytes).unwrap();
    let plan = browser_bookmarks::preview(bytes).unwrap();
    assert!(
        engine
            .store
            .local_document(browser_bookmarks::DOCUMENT)
            .unwrap()
            .is_none()
    );
    assert_eq!(
        engine.saved_browser_bookmarks().unwrap(),
        Library::default()
    );
    let result = engine.import_browser_bookmarks(0, &plan).unwrap();
    assert_eq!(result.added, 1);
    assert!(engine.browser_requests.is_empty());
    assert!(engine.runs.is_empty());
    let saved = result.library;
    drop(engine);
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    assert_eq!(engine.saved_browser_bookmarks().unwrap(), saved);
    assert_eq!(std::fs::read(&source).unwrap(), bytes);
    assert_eq!(
        engine.store.document("browser-library.json").unwrap(),
        Some(original)
    );
    let replay = engine
        .import_browser_bookmarks(saved.revision, &plan)
        .unwrap();
    assert_eq!(replay.added, 0);
    assert_eq!(replay.library, saved);
}
#[test]
fn stale_malformed_closed_and_path_injection_fail_without_losing_saved_data() {
    let (_dir, mut engine, _id) = fixture();
    let saved = engine.import_browser_bookmarks(0, &plan()).unwrap().library;
    assert!(engine.import_browser_bookmarks(0, &plan()).is_err());
    assert_eq!(engine.saved_browser_bookmarks().unwrap(), saved);
    for params in [
        json!({"expectedRevision":saved.revision,"plan":plan(),"sourcePath":"/private/unknown"}),
        json!({"expectedRevision":saved.revision,"plan":{"bookmarks":[{"url":"file:///private/unknown","title":"x"}]}}),
    ] {
        assert!(engine.execute("browser.bookmarks.import", &params).is_err());
        assert_eq!(engine.saved_browser_bookmarks().unwrap(), saved);
    }
    let malformed =
        json!({"version":999,"revision":saved.revision,"bookmarks":[],"future":"retained"});
    engine
        .store
        .save_document(browser_bookmarks::DOCUMENT, &malformed)
        .unwrap();
    assert!(engine.saved_browser_bookmarks().is_err());
    assert!(
        engine
            .import_browser_bookmarks(saved.revision, &plan())
            .is_err()
    );
    assert_eq!(
        engine
            .store
            .local_document(browser_bookmarks::DOCUMENT)
            .unwrap(),
        Some(malformed)
    );
    engine.store.close_for_shutdown().unwrap();
    assert!(engine.saved_browser_bookmarks().is_err());
    assert!(engine.import_browser_bookmarks(0, &plan()).is_err());
    assert!(engine.store.is_closed());
}
#[test]
fn opening_resolves_saved_identity_and_only_queues_existing_browser_bridge_on_click() {
    let (_dir, mut engine, id) = fixture();
    let saved = engine.import_browser_bookmarks(0, &plan()).unwrap().library;
    let bookmark = saved.bookmarks[0].id;
    let thread = engine.store.thread(&id).unwrap();
    assert!(
        engine
            .open_browser_bookmark(&id, bookmark, saved.revision)
            .is_err()
    );
    assert!(engine.browser_requests.is_empty());
    engine.ui_available = true;
    engine.set_active_thread(Some(id.clone())).unwrap();
    assert!(
        engine
            .open_browser_bookmark(&id, bookmark, saved.revision + 1)
            .is_err()
    );
    assert!(engine.browser_requests.is_empty());
    assert!(engine.execute("browser.bookmarks.open",&json!({"threadId":id,"bookmarkId":bookmark,"expectedRevision":saved.revision,"url":"https://attacker.example/"})).is_err());
    let result = engine
        .open_browser_bookmark(&id, bookmark, saved.revision)
        .unwrap();
    assert!(result["navigateOperationId"].is_string());
    assert_eq!(engine.browser_requests.len(), 2);
    assert!(
        matches!(&engine.browser_requests[0].action,crate::browser_protocol::BrowserAction::NewTab{url:Some(url)} if url=="https://example.com/saved")
    );
    assert!(matches!(
        &engine.browser_requests[1].action,
        crate::browser_protocol::BrowserAction::Show
    ));
    assert!(
        engine
            .browser_requests
            .iter()
            .all(|request| request.thread_id == id)
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert_eq!(engine.saved_browser_bookmarks().unwrap(), saved);
}
#[test]
fn provider_scoped_channels_cannot_read_write_or_open_global_bookmarks() {
    let (_dir, mut engine, id) = fixture();
    let saved = engine.import_browser_bookmarks(0, &plan()).unwrap().library;
    let revision = engine.revision;
    for (method, params) in [
        ("browser.bookmarks.list", json!({})),
        (
            "browser.bookmarks.import",
            json!({"expectedRevision":saved.revision,"plan":plan()}),
        ),
        (
            "browser.bookmarks.open",
            json!({"threadId":id,"bookmarkId":saved.bookmarks[0].id,"expectedRevision":saved.revision}),
        ),
    ] {
        let response = engine.dispatch_scoped(
            json!({"id":1,"method":method,"params":params}),
            Uuid::parse_str(&id).unwrap(),
        );
        assert!(response.get("error").is_some());
        assert_eq!(engine.saved_browser_bookmarks().unwrap(), saved);
        assert!(engine.browser_requests.is_empty());
        assert_eq!(engine.revision, revision);
    }
}

#[test]
fn failed_sqlite_write_keeps_exact_prior_library_and_revision() {
    let (dir, mut engine, _id) = fixture();
    let saved = engine.import_browser_bookmarks(0, &plan()).unwrap().library;
    let revision = engine.revision;
    let connection = rusqlite::Connection::open(dir.path().join("state.sqlite")).unwrap();
    connection.execute_batch("CREATE TRIGGER reject_bookmark_update BEFORE UPDATE ON documents WHEN NEW.name='rust-browser-bookmarks.json' BEGIN SELECT RAISE(ABORT,'synthetic save failure'); END;").unwrap();
    let next = browser_bookmarks::preview(
        br#"{"bookmarks":[{"url":"https://another.example/new","title":"New"}]}"#,
    )
    .unwrap();
    assert!(
        engine
            .import_browser_bookmarks(saved.revision, &next)
            .is_err()
    );
    assert_eq!(engine.saved_browser_bookmarks().unwrap(), saved);
    assert_eq!(engine.revision, revision);
    assert!(engine.browser_requests.is_empty());
}

#[test]
fn preparation_never_queues_and_stale_revisions_or_thread_roundtrips_cannot_admit() {
    let (_dir, mut engine, id) = fixture();
    let library = engine.import_browser_bookmarks(0, &plan()).unwrap().library;
    let bookmark = library.bookmarks[0].id;
    engine.ui_available = true;
    engine.set_active_thread(Some(id.clone())).unwrap();
    let prepared = engine
        .prepare_browser_bookmark(&id, bookmark, library.revision)
        .unwrap();
    assert!(engine.browser_requests.is_empty());
    drop(prepared);
    assert!(
        engine.browser_requests.is_empty(),
        "closed panel can discard proof without queuing"
    );
    let prepared = engine
        .prepare_browser_bookmark(&id, bookmark, library.revision)
        .unwrap();
    let added = browser_bookmarks::preview(
        br#"{"bookmarks":[{"url":"https://other.example/new","title":"New"}]}"#,
    )
    .unwrap();
    let updated = engine
        .import_browser_bookmarks(library.revision, &added)
        .unwrap()
        .library;
    assert!(engine.admit_prepared_bookmark(prepared).is_err());
    assert!(engine.browser_requests.is_empty());
    let prepared = engine
        .prepare_browser_bookmark(&id, bookmark, updated.revision)
        .unwrap();
    engine.set_active_thread(None).unwrap();
    engine.set_active_thread(Some(id.clone())).unwrap();
    assert!(
        engine.admit_prepared_bookmark(prepared).is_err(),
        "A to B to A must not revive an old proof"
    );
    assert!(engine.browser_requests.is_empty());
    let prepared = engine
        .prepare_browser_bookmark(&id, bookmark, updated.revision)
        .unwrap();
    engine.freeze_admissions();
    assert!(engine.admit_prepared_bookmark(prepared).is_err());
    assert!(engine.browser_requests.is_empty());
}
#[test]
fn prepared_proof_cannot_cross_engines_and_closed_store_or_missing_ui_blocks_admission() {
    let (_dir, mut engine, id) = fixture();
    let library = engine.import_browser_bookmarks(0, &plan()).unwrap().library;
    engine.ui_available = true;
    engine.set_active_thread(Some(id.clone())).unwrap();
    let bookmark = library.bookmarks[0].id;
    let prepared = engine
        .prepare_browser_bookmark(&id, bookmark, library.revision)
        .unwrap();
    let (_other, mut other, _) = fixture();
    other
        .store
        .save(&engine.store.thread(&id).unwrap())
        .unwrap();
    other.set_active_thread(Some(id.clone())).unwrap();
    other.ui_available = true;
    other.revision = engine.revision;
    assert!(other.admit_prepared_bookmark(prepared).is_err());
    assert!(other.browser_requests.is_empty());
    let prepared = engine
        .prepare_browser_bookmark(&id, bookmark, library.revision)
        .unwrap();
    engine.ui_available = false;
    assert!(engine.admit_prepared_bookmark(prepared).is_err());
    assert!(engine.browser_requests.is_empty());
    engine.ui_available = true;
    let prepared = engine
        .prepare_browser_bookmark(&id, bookmark, library.revision)
        .unwrap();
    engine.store.close_for_shutdown().unwrap();
    assert!(engine.admit_prepared_bookmark(prepared).is_err());
    assert!(engine.store.is_closed());
    assert!(engine.browser_requests.is_empty());
}
#[test]
fn completed_browser_reply_survives_until_later_parent_operation_registration() {
    let (_dir, mut engine, id) = fixture();
    let library = engine.import_browser_bookmarks(0, &plan()).unwrap().library;
    engine.ui_available = true;
    engine.set_active_thread(Some(id.clone())).unwrap();
    let prepared = engine
        .prepare_browser_bookmark(&id, library.bookmarks[0].id, library.revision)
        .unwrap();
    let queued = engine.admit_prepared_bookmark(prepared).unwrap();
    // Native completion can arrive before the parent's next operation-map poll.
    for operation in [queued.navigate_operation, queued.show_operation] {
        engine.browser_reply(crate::browser_protocol::BrowserReply {
            id: operation.clone(),
            thread_id: id.clone(),
            result: json!({"tab":"synthetic"}),
        });
        let reply = engine
            .execute(
                "browser.result",
                &json!({"operationId":operation,"threadId":id}),
            )
            .unwrap();
        assert_eq!(reply["ready"], true);
        assert_eq!(reply["result"]["tab"], "synthetic");
    }
}

#[test]
fn native_current_page_toggle_persists_and_stale_removal_does_not_write() {
    let (dir, mut engine, _) = fixture();
    let candidate = browser_bookmarks::Candidate {
        url: "https://example.com/page".into(),
        title: "Current page".into(),
        folder: None,
    };
    let saved = engine
        .toggle_browser_bookmark(0, candidate.clone())
        .unwrap();
    assert_eq!(saved.bookmarks.len(), 1);
    assert!(
        engine
            .toggle_browser_bookmark(0, candidate.clone())
            .is_err()
    );
    assert_eq!(engine.saved_browser_bookmarks().unwrap(), saved);
    drop(engine);
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let removed = engine.toggle_browser_bookmark(1, candidate).unwrap();
    assert_eq!(removed.revision, 2);
    assert!(removed.bookmarks.is_empty());
    assert_eq!(engine.saved_browser_bookmarks().unwrap(), removed);
    assert!(engine.browser_requests.is_empty());
}
