use super::*;
fn fixture() -> (tempfile::TempDir, Engine, String) {
    let root = tempfile::tempdir().unwrap();
    let project = root.path().join("project");
    std::fs::create_dir(&project).unwrap();
    std::fs::create_dir(project.join("src")).unwrap();
    std::fs::write(project.join("src/café.rs"), b"synthetic private body\n").unwrap();
    let mut store = Store::open(&root.path().join("state.sqlite")).unwrap();
    let saved = store.create_project(&project, Some("Synthetic")).unwrap();
    let mut thread = store.new_thread(saved["id"].as_str().unwrap()).unwrap();
    thread["draft"] = json!("  exact café @src\n");
    thread["sessions"] = json!({"codex":"opaque-session"});
    thread["future"] = json!({"keep":[1,2]});
    thread["draftContext"] =
        json!([{"id":Uuid::new_v4(),"kind":"quote","text":"saved quote","future":{"keep":true}}]);
    store.save(&thread).unwrap();
    let id = text(&thread, "id");
    let mut engine = Engine::fixture(store);
    engine.set_active_thread(Some(id.clone())).unwrap();
    (root, engine, id)
}
fn scope(engine: &Engine, id: &str) -> Arc<FileReferenceScope> {
    let thread = engine.store.thread(id).unwrap();
    engine
        .prepare_file_reference_scope(
            id,
            thread["draft"].as_str().unwrap(),
            &ExpectedContext::from_thread(&thread),
        )
        .unwrap()
}
fn list(scope: &Arc<FileReferenceScope>) -> FileReferenceList {
    scope
        .search_with("src", |directory, query, limit| {
            assert!(directory.ends_with("project"));
            assert_eq!(query, "src");
            assert_eq!(limit, 80);
            Ok(json!({"files":["src/café.rs"],"total":1,"truncated":false}))
        })
        .unwrap()
}
#[test]
fn explicit_attach_preserves_text_context_unknowns_session_and_file_bytes_and_only_sends_path_data()
{
    let (root, mut engine, id) = fixture();
    let original = engine.store.thread(&id).unwrap();
    let bytes = std::fs::read(root.path().join("project/src/café.rs")).unwrap();
    let scope = scope(&engine, &id);
    let listing = list(&scope);
    assert_eq!(listing.files.len(), 1);
    let result = engine.attach_file_reference(&listing.files[0]).unwrap();
    assert!(result.changed);
    let mut expected = original.clone();
    expected["draftContext"] = result.context.clone();
    assert_eq!(engine.store.thread(&id).unwrap(), expected);
    assert_eq!(result.context[0], original["draftContext"][0]);
    assert_eq!(result.context[1]["path"], "src/café.rs");
    assert_eq!(result.context[1]["kind"], "file");
    assert_eq!(
        std::fs::read(root.path().join("project/src/café.rs")).unwrap(),
        bytes
    );
    let prompt =
        composer_context::prompt(original["draft"].as_str().unwrap(), &result.context).unwrap();
    assert!(prompt.starts_with(original["draft"].as_str().unwrap()));
    assert!(!prompt.contains("synthetic private body"));
    assert!(!prompt.contains("@src/café.rs"));
    assert!(prompt.contains("literal path references only"));
}
#[test]
fn changed_thread_draft_context_project_and_foreign_engine_refuse_without_overwrite() {
    let (root, mut engine, id) = fixture();
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    let mut external = Store::open(&root.path().join("state.sqlite")).unwrap();
    external
        .patch_thread(&id, &json!({"draft":"new draft"}))
        .unwrap();
    let changed = engine.store.file_reference_source(&id).unwrap();
    assert!(engine.attach_file_reference(&candidate).is_err());
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), changed);
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    let mut thread = external.thread(&id).unwrap();
    thread["draftContext"][0]["future"] = json!({"later":true});
    external.save(&thread).unwrap();
    let changed = engine.store.file_reference_source(&id).unwrap();
    assert!(engine.attach_file_reference(&candidate).is_err());
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), changed);
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    let mut projects = external.projects().unwrap();
    projects[0]["future"] = json!({"changed":true});
    external.save_document("projects.json", &projects).unwrap();
    assert!(engine.attach_file_reference(&candidate).is_err());
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), changed);
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    let mut foreign = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
    foreign.set_active_thread(Some(id.clone())).unwrap();
    assert!(foreign.attach_file_reference(&candidate).is_err());
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), changed);
}
#[test]
fn active_away_back_revision_unsaved_and_frozen_admissions_invalidate_candidates() {
    let (_root, mut engine, id) = fixture();
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    engine.set_active_thread(None).unwrap();
    engine.set_active_thread(Some(id.clone())).unwrap();
    assert!(engine.attach_file_reference(&candidate).is_err());
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    engine
        .unsaved_threads
        .insert(id.clone(), engine.store.thread(&id).unwrap());
    assert!(engine.attach_file_reference(&candidate).is_err());
    engine.unsaved_threads.clear();
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    let before = engine.store.file_reference_source(&id).unwrap();
    engine.freeze_admissions();
    assert!(engine.attach_file_reference(&candidate).is_err());
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), before);
}
#[test]
fn changed_file_metadata_symlinks_parent_absolute_and_directory_entries_never_gain_a_reference() {
    let (root, mut engine, id) = fixture();
    let captured = scope(&engine, &id);
    let listing=captured.search_with("",|_,_,_|Ok(json!({"files":["src/café.rs","../outside","/absolute","src","missing","src/./café.rs"],"total":6,"truncated":false}))).unwrap();
    // Components::CurDir is normalized in the middle by Path, but a normalized
    // duplicate must not create an extra selectable path spelling.
    assert_eq!(listing.files.len(), 1);
    assert_eq!(listing.skipped, 5);
    let before = engine.store.file_reference_source(&id).unwrap();
    std::fs::write(root.path().join("project/src/café.rs"), b"changed length").unwrap();
    assert!(engine.attach_file_reference(&listing.files[0]).is_err());
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), before);
    #[cfg(unix)]
    {
        let external = root.path().join("outside");
        std::fs::create_dir(&external).unwrap();
        std::fs::write(external.join("private"), b"outside bytes").unwrap();
        std::os::unix::fs::symlink(&external, root.path().join("project/escape")).unwrap();
        std::os::unix::fs::symlink("src/café.rs", root.path().join("project/link")).unwrap();
        let captured = scope(&engine, &id);
        let listing = captured
            .search_with("", |_, _, _| {
                Ok(json!({"files":["escape/private","link"],"total":2,"truncated":false}))
            })
            .unwrap();
        assert!(listing.files.is_empty());
        assert_eq!(listing.skipped, 2);
        assert_eq!(
            std::fs::read(external.join("private")).unwrap(),
            b"outside bytes"
        );
    }
}
#[test]
fn duplicate_reference_is_noop_and_unknown_or_full_context_is_retained_without_repair() {
    let (_root, mut engine, id) = fixture();
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    engine.attach_file_reference(&candidate).unwrap();
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    let before = engine.store.file_reference_source(&id).unwrap();
    let revision = engine.revision;
    assert!(!engine.attach_file_reference(&candidate).unwrap().changed);
    assert_eq!(engine.revision, revision);
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), before);
    for context in [
        json!({"future":"retain"}),
        json!([{"id":Uuid::new_v4(),"kind":"future","opaque":true}]),
    ] {
        let mut thread = engine.store.thread(&id).unwrap();
        thread["draftContext"] = context;
        engine.store.save(&thread).unwrap();
        let before = engine.store.file_reference_source(&id).unwrap();
        assert!(
            engine
                .prepare_file_reference_scope(
                    &id,
                    thread["draft"].as_str().unwrap(),
                    &ExpectedContext::from_thread(&thread)
                )
                .is_err()
        );
        assert_eq!(engine.store.file_reference_source(&id).unwrap(), before);
    }
    let mut thread = engine.store.thread(&id).unwrap();
    thread["draftContext"] = json!(
        (0..20)
            .map(|_| json!({"id":Uuid::new_v4(),"kind":"quote","text":"saved"}))
            .collect::<Vec<_>>()
    );
    engine.store.save(&thread).unwrap();
    let candidate = list(&scope(&engine, &id)).files.remove(0);
    let before = engine.store.file_reference_source(&id).unwrap();
    assert!(engine.attach_file_reference(&candidate).is_err());
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), before);
}
#[test]
fn sqlite_failure_closed_store_and_query_bounds_do_not_attach_or_rewrite_source() {
    let (root, mut engine, id) = fixture();
    let captured = scope(&engine, &id);
    let candidate = list(&captured).files.remove(0);
    let before = engine.store.file_reference_source(&id).unwrap();
    let external = rusqlite::Connection::open(root.path().join("state.sqlite")).unwrap();
    external.execute_batch("CREATE TRIGGER no_attach BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'synthetic context failure'); END;").unwrap();
    assert!(engine.attach_file_reference(&candidate).is_err());
    assert_eq!(engine.store.file_reference_source(&id).unwrap(), before);
    external.execute_batch("DROP TRIGGER no_attach;").unwrap();
    for query in ["a".repeat(257), "control\nquery".into()] {
        assert!(
            captured
                .search_with(&query, |_, _, _| panic!("invalid query reached listing"))
                .is_err()
        );
    }
    assert!(
        captured
            .search_with("", |_, _, _| Ok(
                json!({"files":vec!["src/café.rs";81],"total":81})
            ))
            .is_err()
    );
    engine.store.close_for_shutdown().unwrap();
    assert!(engine.attach_file_reference(&candidate).is_err());
}
