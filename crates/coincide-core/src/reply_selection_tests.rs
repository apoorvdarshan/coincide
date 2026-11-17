//! Private discovery-free source/CAS fixtures. Native projection inputs below
//! are synthetic; actual renderer extraction is tested separately in desktop.
use super::*;
fn fixture() -> (tempfile::TempDir, Engine, String, String, Value) {
    let directory = tempfile::tempdir().unwrap();
    let mut store = Store::open(&directory.path().join("state.sqlite")).unwrap();
    let mut thread = store.new_thread("").unwrap();
    let id = text(&thread, "id");
    let item = Uuid::new_v4().to_string();
    thread["items"] = json!([{"id":item,"kind":"assistant","text":"A **bold** fixture reply","provider":"codex","future":{"keep":1}}]);
    thread["draft"] = json!("Unsent draft 👩🏽‍💻");
    thread["future"] = json!({"keep":7});
    store.save(&thread).unwrap();
    let mut engine = Engine::fixture(store);
    engine.set_active_thread(Some(id.clone())).unwrap();
    (directory, engine, id, item, thread)
}
fn selection(item: &str) -> NativeReplySelection {
    NativeReplySelection::from_native_projection(
        item,
        "A **bold** fixture reply".into(),
        4..8,
        "A bold fixture reply".into(),
        2..6,
    )
    .unwrap()
}
fn attach(engine: &mut Engine, id: &str, item: &str, thread: &Value) -> Result<Value> {
    engine.native_attach_reply_selection(
        id,
        &text(thread, "draft"),
        ExpectedContext::from_thread(thread),
        selection(item),
    )
}
#[test]
fn selected_quote_preserves_entire_draft_history_context_and_unknown_fields() {
    let (_directory, mut engine, id, item, mut thread) = fixture();
    thread["draftContext"] =
        json!([{"id":Uuid::new_v4(),"kind":"file","path":"/fixture/path","future":5}]);
    engine.store.save(&thread).unwrap();
    let result = attach(&mut engine, &id, &item, &thread).unwrap();
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], thread["draft"]);
    assert_eq!(saved["items"], thread["items"]);
    assert_eq!(saved["future"], thread["future"]);
    assert_eq!(saved["draftContext"][0], thread["draftContext"][0]);
    assert_eq!(result["draftContext"][1]["text"], "bold");
    assert_eq!(result["draftContext"][1]["provider"], "codex");
    assert!(engine.runs.is_empty());
}
#[test]
fn selected_user_text_in_large_thread_keeps_a_newer_draft_and_tags_source() {
    let (_directory, mut engine, id, item, mut thread) = fixture();
    thread["items"][0]["kind"] = json!("user");
    thread["items"].as_array_mut().unwrap().push(json!({
        "id":Uuid::new_v4(), "kind":"assistant", "text":"x".repeat(9 * 1024 * 1024)
    }));
    let context = ExpectedContext::from_thread(&thread);
    thread["draft"] = json!("A different draft typed while selecting");
    engine.store.save(&thread).unwrap();
    let selected = NativeReplySelection::from_native_message_projection(
        &item,
        "A **bold** fixture reply".into(),
        4..8,
        "A bold fixture reply".into(),
        2..6,
        "user",
    )
    .unwrap();
    let result = engine
        .native_attach_reply_selection_preserve_draft(&id, context, selected)
        .unwrap();
    assert_eq!(result["draftContext"][0]["text"], "bold");
    assert_eq!(result["draftContext"][0]["sourceItemID"], item);
    assert_eq!(result["draftContext"][0]["sourceKind"], "user");
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], thread["draft"]);
}

#[test]
fn reply_previews_keep_their_identity_and_two_quick_quotes_both_save() {
    let (_directory, mut engine, id, item, thread) = fixture();
    let expected = ExpectedContext::from_thread(&thread);
    let first = selection(&item);
    let second = selection(&item);
    let first_preview = first.reference_preview(&Value::Null).unwrap();
    let second_preview = second.reference_preview(&Value::Null).unwrap();
    assert_eq!(first_preview["text"], "bold");
    assert_ne!(first_preview["id"], second_preview["id"]);
    engine
        .native_attach_reply_selection_preserve_draft(&id, expected.clone(), first)
        .unwrap();
    let saved = engine
        .native_attach_reply_selection_preserve_draft(&id, expected, second)
        .unwrap();
    assert_eq!(saved["draftContext"][0]["id"], first_preview["id"]);
    assert_eq!(saved["draftContext"][1]["id"], second_preview["id"]);
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], thread["draft"]);
    engine
        .remove_draft_context_card(&id, &saved["draftContext"][0])
        .unwrap();
    let after = engine.store.thread(&id).unwrap();
    assert_eq!(after["draftContext"], json!([saved["draftContext"][1]]));
}

#[test]
fn selection_remains_valid_if_a_streamed_reply_only_appends_text() {
    let (_directory, mut engine, id, item, mut thread) = fixture();
    let selection = selection(&item);
    let expected = ExpectedContext::from_thread(&thread);
    thread["items"][0]["text"] = json!("A **bold** fixture reply, with a streamed continuation");
    engine.store.save(&thread).unwrap();
    let result = engine
        .native_attach_reply_selection_preserve_draft(&id, expected, selection)
        .unwrap();
    assert_eq!(result["draftContext"][0]["text"], "bold");
}

#[test]
fn reference_finishes_in_its_original_thread_after_navigation() {
    let (_directory, mut engine, id, item, thread) = fixture();
    let expected = ExpectedContext::from_thread(&thread);
    let selected = selection(&item);
    engine.set_active_thread(None).unwrap();
    engine
        .native_attach_reply_selection_preserve_draft(&id, expected, selected)
        .unwrap();
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], thread["draft"]);
    assert_eq!(saved["draftContext"][0]["text"], "bold");
}
#[test]
fn late_item_text_kind_duplicate_identity_context_or_draft_change_is_refused() {
    for change in ["text", "kind", "duplicate", "context", "draft"] {
        let (_directory, mut engine, id, item, thread) = fixture();
        let mut changed = thread.clone();
        match change {
            "text" => changed["items"][0]["text"] = json!("A different reply"),
            "kind" => changed["items"][0]["kind"] = json!("user"),
            "duplicate" => {
                let row = changed["items"][0].clone();
                changed["items"].as_array_mut().unwrap().push(row);
            }
            "context" => changed["draftContext"] = json!([]),
            _ => changed["draft"] = json!("edited draft"),
        }
        engine.store.save(&changed).unwrap();
        assert!(
            attach(&mut engine, &id, &item, &thread).is_err(),
            "{change}"
        );
        assert_eq!(engine.store.thread(&id).unwrap(), changed);
    }
}
#[test]
fn switched_archived_imported_recovering_and_frozen_sources_have_no_write_side_effect() {
    for change in ["switch", "archive", "import", "recover", "freeze"] {
        let (directory, mut engine, id, item, thread) = fixture();
        match change {
            "switch" => {
                engine.set_active_thread(None).unwrap();
            }
            "archive" => {
                engine
                    .store
                    .patch_thread(&id, &json!({"isArchived":true}))
                    .unwrap();
            }
            "import" => {
                let other =
                    rusqlite::Connection::open(directory.path().join("state.sqlite")).unwrap();
                other
                    .execute("INSERT INTO imported_threads(id) VALUES (?1)", [&id])
                    .unwrap();
            }
            "recover" => {
                engine.unsaved_threads.insert(id.clone(), thread.clone());
            }
            _ => engine.freeze_admissions(),
        }
        let before = engine.store.thread(&id).unwrap();
        let changes = engine.store.mutation_serial().unwrap();
        assert!(
            attach(&mut engine, &id, &item, &thread).is_err(),
            "{change}"
        );
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(engine.store.mutation_serial().unwrap(), changes);
    }
}
#[test]
fn exact_raw_source_cas_rejects_external_edit_and_unsupported_context_stays_original() {
    let (directory, mut engine, id, _, thread) = fixture();
    let source = engine.store.native_reply_context_source(&id).unwrap();
    let mut changed = thread.clone();
    changed["draft"] = json!("External edit");
    let other = rusqlite::Connection::open(directory.path().join("state.sqlite")).unwrap();
    other
        .execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            rusqlite::params![id, changed.to_string()],
        )
        .unwrap();
    drop(other);
    assert!(
        engine
            .store
            .commit_native_reply_context(&id, &source, &json!([]))
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), changed);
    let (_directory, mut engine, id, item, mut thread) = fixture();
    thread["draftContext"] = json!([{"id":Uuid::new_v4(),"kind":"future","opaque":"retain"}]);
    engine.store.save(&thread).unwrap();
    assert!(attach(&mut engine, &id, &item, &thread).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
}
#[test]
fn native_selection_has_no_control_json_route() {
    let (_directory, mut engine, id, item, thread) = fixture();
    for method in [
        "composer.context.attachReplySelection",
        "reply.selection.attach",
        "native.reply.selection",
    ] {
        assert!(engine.dispatch(json!({"method":method,"params":{"threadId":id,"itemId":item,"text":"injected"}})).get("error").is_some());
    }
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
}
