use super::*;
use rusqlite::Connection;
const PROJECT: &str = "00000000-0000-0000-0000-000000000000";
fn fixture() -> (tempfile::TempDir, Engine, Vec<String>) {
    let root = tempfile::tempdir().unwrap();
    let mut store = Store::open(&root.path().join("state.sqlite")).unwrap();
    let mut ids = Vec::new();
    for name in ["One café", "Two 中文", "Unrelated"] {
        let mut row = store.new_thread(PROJECT).unwrap();
        row["title"] = json!(name);
        row["draft"] = json!("  unsubmitted draft\n");
        row["draftContext"] = json!([{"opaque":true}]);
        row["sessions"] = json!({"codex":{"opaque":"source-session"}});
        row["future"] = json!({"keep":[1,"café"]});
        row["items"] = json!([{"id":Uuid::new_v4().to_string(),"kind":"assistant","text":"search needle","future":42}]);
        store.save(&row).unwrap();
        ids.push(text(&row, "id"));
    }
    store
        .save_document("future.json", &json!({"keep":true}))
        .unwrap();
    let external = Connection::open(root.path().join("state.sqlite")).unwrap();
    external
        .execute(
            "INSERT INTO original_files(path,data) VALUES ('sentinel',?1)",
            [b"captured source bytes".as_slice()],
        )
        .unwrap();
    drop(external);
    (root, Engine::fixture(store), ids)
}
fn raw(root: &tempfile::TempDir, id: &str) -> String {
    Connection::open(root.path().join("state.sqlite"))
        .unwrap()
        .query_row("SELECT document FROM threads WHERE id=?1", [id], |r| {
            r.get(0)
        })
        .unwrap()
}
#[test]
fn transaction_changes_one_flag_and_undo_restores_exact_raw_unknowns_drafts_sessions_and_search() {
    let (root, mut engine, ids) = fixture();
    let originals: Vec<_> = ids.iter().map(|id| raw(&root, id)).collect();
    let before_search = engine.store.summaries("needle", true).unwrap().len();
    let preview = engine
        .prepare_thread_flags(&ids[..2], ThreadFlagAction::Archive)
        .unwrap();
    assert_eq!(preview.count(), 2);
    assert_eq!(preview.selected_count(), 2);
    let undo = engine.apply_thread_flags(&preview).unwrap();
    assert_eq!(undo.count(), 2);
    for (id, original) in ids.iter().zip(&originals).take(2) {
        let mut expected: Value = serde_json::from_str(original).unwrap();
        expected["isArchived"] = json!(true);
        assert_eq!(engine.store.thread(id).unwrap(), expected);
    }
    assert_eq!(raw(&root, &ids[2]), originals[2]);
    assert_eq!(
        engine.store.summaries("needle", true).unwrap().len(),
        before_search
    );
    assert_eq!(engine.store.summaries("", false).unwrap().len(), 1);
    assert_eq!(
        engine.store.document("future.json").unwrap(),
        Some(json!({"keep":true}))
    );
    assert_eq!(
        engine.store.original("sentinel").unwrap(),
        Some(b"captured source bytes".to_vec())
    );
    engine.undo_thread_flags(&undo).unwrap();
    for (id, before) in ids.iter().zip(originals) {
        assert_eq!(raw(&root, id), before);
    }
    assert_eq!(engine.store.summaries("", false).unwrap().len(), 3);
}
#[test]
fn changed_other_connection_refuses_entire_apply_and_stale_undo_never_clobbers_later_edits() {
    let (root, mut engine, ids) = fixture();
    let preview = engine
        .prepare_thread_flags(&ids[..2], ThreadFlagAction::Pin)
        .unwrap();
    let first = raw(&root, &ids[0]);
    let mut other = Store::open(&root.path().join("state.sqlite")).unwrap();
    other
        .patch_thread(&ids[1], &json!({"draft":"later draft"}))
        .unwrap();
    let second = raw(&root, &ids[1]);
    assert!(engine.apply_thread_flags(&preview).is_err());
    assert_eq!(raw(&root, &ids[0]), first);
    assert_eq!(raw(&root, &ids[1]), second);
    let preview = engine
        .prepare_thread_flags(&ids[..2], ThreadFlagAction::Pin)
        .unwrap();
    let undo = engine.apply_thread_flags(&preview).unwrap();
    other
        .patch_thread(&ids[1], &json!({"title":"later rename"}))
        .unwrap();
    let after: Vec<_> = ids.iter().map(|id| raw(&root, id)).collect();
    assert!(engine.undo_thread_flags(&undo).is_err());
    for (id, expected) in ids.iter().zip(after) {
        assert_eq!(raw(&root, id), expected);
    }
    assert!(engine.store.thread(&ids[0]).unwrap()["isPinned"] == true);
}
#[test]
fn sqlite_failure_after_first_write_rolls_back_all_rows_and_summary_flags() {
    let (root, mut engine, ids) = fixture();
    let preview = engine
        .prepare_thread_flags(&ids[..2], ThreadFlagAction::Archive)
        .unwrap();
    let original: Vec<_> = ids.iter().map(|id| raw(&root, id)).collect();
    let external = Connection::open(root.path().join("state.sqlite")).unwrap();
    external.execute_batch(&format!("CREATE TRIGGER reject_second BEFORE UPDATE ON threads WHEN NEW.id='{}' BEGIN SELECT RAISE(ABORT,'synthetic batch failure'); END;",ids[1])).unwrap();
    assert!(engine.apply_thread_flags(&preview).is_err());
    for (id, before) in ids.iter().zip(original) {
        assert_eq!(raw(&root, id), before);
    }
    assert_eq!(engine.store.summaries("", false).unwrap().len(), 3);
    external
        .execute_batch("DROP TRIGGER reject_second;")
        .unwrap();
    assert_eq!(engine.apply_thread_flags(&preview).unwrap().count(), 2);
}
#[test]
fn mixed_noops_and_missing_flags_preserve_raw_rows_and_undo_original_field_absence() {
    let (root, mut engine, ids) = fixture();
    let mut first = engine.store.thread(&ids[0]).unwrap();
    first.as_object_mut().unwrap().remove("isPinned");
    engine.store.save(&first).unwrap();
    engine
        .store
        .patch_thread(&ids[1], &json!({"isPinned":true}))
        .unwrap();
    let before_first = raw(&root, &ids[0]);
    let before_second = raw(&root, &ids[1]);
    let preview = engine
        .prepare_thread_flags(&ids[..2], ThreadFlagAction::Pin)
        .unwrap();
    assert_eq!(preview.count(), 1);
    let undo = engine.apply_thread_flags(&preview).unwrap();
    assert_eq!(undo.count(), 1);
    assert_eq!(raw(&root, &ids[1]), before_second);
    engine.undo_thread_flags(&undo).unwrap();
    assert_eq!(raw(&root, &ids[0]), before_first);
    assert!(
        engine
            .store
            .thread(&ids[0])
            .unwrap()
            .get("isPinned")
            .is_none()
    );
    assert_eq!(raw(&root, &ids[1]), before_second);
    let preview = engine
        .prepare_thread_flags(&[ids[1].clone()], ThreadFlagAction::Pin)
        .unwrap();
    assert_eq!(preview.count(), 0);
    let revision = engine.revision;
    assert_eq!(engine.apply_thread_flags(&preview).unwrap().count(), 0);
    assert_eq!(engine.revision, revision);
}
#[test]
fn owner_admission_running_and_unsaved_guards_are_rechecked_before_apply_and_undo() {
    let (root, mut engine, ids) = fixture();
    let preview = engine
        .prepare_thread_flags(&ids[..2], ThreadFlagAction::Archive)
        .unwrap();
    let original = raw(&root, &ids[0]);
    engine
        .unsaved_threads
        .insert(ids[1].clone(), engine.store.thread(&ids[1]).unwrap());
    assert!(engine.apply_thread_flags(&preview).is_err());
    assert_eq!(raw(&root, &ids[0]), original);
    engine.unsaved_threads.clear();
    let mut foreign = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
    assert!(foreign.apply_thread_flags(&preview).is_err());
    let undo = engine.apply_thread_flags(&preview).unwrap();
    assert!(foreign.undo_thread_flags(&undo).is_err());
    engine
        .unsaved_threads
        .insert(ids[0].clone(), engine.store.thread(&ids[0]).unwrap());
    assert!(engine.undo_thread_flags(&undo).is_err());
    engine.unsaved_threads.clear();
    assert!(
        require_idle(
            ids[..2].iter().map(String::as_str),
            [ids[1].to_lowercase().as_str()].into_iter(),
            std::iter::empty()
        )
        .is_err()
    );
    assert!(
        require_idle(
            ids[..2].iter().map(String::as_str),
            [ids[2].as_str()].into_iter(),
            std::iter::empty()
        )
        .is_ok()
    );
    let after = raw(&root, &ids[0]);
    engine.freeze_admissions();
    assert!(engine.undo_thread_flags(&undo).is_err());
    assert!(
        engine
            .prepare_thread_flags(&ids[..2], ThreadFlagAction::Restore)
            .is_err()
    );
    assert_eq!(raw(&root, &ids[0]), after);
}
#[test]
fn invalid_selection_bounds_duplicate_identity_malformed_flags_and_closed_store_do_not_write() {
    let (root, mut engine, ids) = fixture();
    let before = raw(&root, &ids[0]);
    for bad in [
        vec![],
        vec![ids[0].clone(); 51],
        vec![ids[0].clone(), ids[0].to_lowercase()],
        vec!["not-a-thread".into()],
        vec![Uuid::new_v4().to_string()],
    ] {
        assert!(
            engine
                .prepare_thread_flags(&bad, ThreadFlagAction::Pin)
                .is_err()
        );
    }
    assert_eq!(raw(&root, &ids[0]), before);
    let mut malformed = engine.store.thread(&ids[0]).unwrap();
    malformed["isPinned"] = json!({"unknown":true});
    engine.store.save(&malformed).unwrap();
    let saved = raw(&root, &ids[0]);
    assert!(
        engine
            .prepare_thread_flags(&ids[..2], ThreadFlagAction::Pin)
            .is_err()
    );
    assert_eq!(raw(&root, &ids[0]), saved);
    let preview = engine
        .prepare_thread_flags(&[ids[1].clone()], ThreadFlagAction::Archive)
        .unwrap();
    let before = raw(&root, &ids[1]);
    engine.store.close_for_shutdown().unwrap();
    assert!(engine.apply_thread_flags(&preview).is_err());
    assert_eq!(raw(&root, &ids[1]), before);
}
