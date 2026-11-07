//! Private discovery-free fixtures only. No providers, sessions, timers or
//! native global hooks are started by these New Thread/snooze regressions.
use super::*;
fn fixture() -> (tempfile::TempDir, Engine, Value) {
    let directory = tempfile::tempdir().unwrap();
    let mut store = Store::open(&directory.path().join("state.sqlite")).unwrap();
    let project = store
        .create_project(directory.path(), Some("Fixture"))
        .unwrap();
    let engine = Engine::fixture(store);
    let params = json!({"projectId":project["id"],"cwd":directory.path()});
    (directory, engine, params)
}
fn new(engine: &mut Engine, params: &Value) -> Value {
    let prepared = engine.prepare_native_new_thread(params).unwrap();
    engine.apply_native_new_thread(prepared).unwrap()
}
#[test]
fn untouched_same_folder_and_defaults_reuses_exact_document_without_any_write() {
    let (_directory, mut engine, params) = fixture();
    let first = new(&mut engine, &params);
    let id = text(&first, "id");
    let mut edited = first.clone();
    edited["title"] = json!("A name the user chose");
    edited["future"] = json!({"keep":42});
    engine.store.save(&edited).unwrap();
    let changes = engine.store.mutation_serial().unwrap();
    let revision = engine.revision;
    assert_eq!(new(&mut engine, &params), edited);
    assert_eq!(engine.store.thread(&id).unwrap(), edited);
    assert_eq!(engine.store.mutation_serial().unwrap(), changes);
    assert_eq!(engine.revision, revision);
    let explicit = engine.execute("threads.create", &params).unwrap();
    assert_ne!(
        explicit["id"], id,
        "generic API New remains explicitly fresh"
    );
}
#[test]
fn touched_archived_snoozed_different_folder_or_defaults_are_never_reused() {
    for patch in [
        json!({"draft":" "}),
        json!({"draftContext":[{"future":"keep"}]}),
        json!({"draftContext":{"future":"keep"}}),
        json!({"rustDraftImages":[{"future":"keep"}]}),
        json!({"items":[{"kind":"user","text":"already used"}]}),
        json!({"isArchived":true}),
        json!({"snoozedUntil":swift_timestamp()+600.}),
        json!({"worktreePath":"/different/private/fixture"}),
        json!({"accessMode":"fullAccess"}),
        json!({"interactionMode":"plan"}),
        json!({"selection":{"provider":"claude","modelID":"default"}}),
        json!({"botID":Uuid::new_v4()}),
    ] {
        let (_directory, mut engine, params) = fixture();
        let mut first = new(&mut engine, &params);
        let id = text(&first, "id");
        for (key, value) in patch.as_object().unwrap() {
            first[key] = value.clone();
        }
        engine.store.save(&first).unwrap();
        let next = new(&mut engine, &params);
        assert_ne!(next["id"], id, "{patch}");
        assert_eq!(
            engine.store.thread(&id).unwrap(),
            first,
            "existing document retained: {patch}"
        );
    }
}
#[test]
fn settled_empty_thread_stays_settled_and_is_not_reused() {
    let (_directory, mut engine, params) = fixture();
    let first = new(&mut engine, &params);
    let id = text(&first, "id");
    let mut settled = json!({});
    settled[id.to_ascii_lowercase()] = json!(swift_timestamp() + 10.);
    engine
        .store
        .patch_document(
            "ui-state.json",
            &json!({"settledThreads":settled,"future":9}),
        )
        .unwrap();
    let before = engine.store.document("ui-state.json").unwrap();
    assert_ne!(new(&mut engine, &params)["id"], id);
    assert_eq!(engine.store.thread(&id).unwrap(), first);
    assert_eq!(engine.store.document("ui-state.json").unwrap(), before);
}
#[test]
fn prepared_reuse_rejects_late_draft_or_defaults_edit_and_cross_engine_owner() {
    for mutate in ["draft", "settings", "project"] {
        let (_directory, mut engine, params) = fixture();
        let first = new(&mut engine, &params);
        let id = text(&first, "id");
        let intent = engine.prepare_native_new_thread(&params).unwrap();
        match mutate {
            "draft" => {
                engine
                    .store
                    .patch_thread(&id, &json!({"draft":"do not lose"}))
                    .unwrap();
            }
            "settings" => {
                engine
                    .store
                    .patch_document("settings.json", &json!({"future":1}))
                    .unwrap();
            }
            _ => {
                let review = engine
                    .native_project_defaults(params["projectId"].as_str().unwrap())
                    .unwrap();
                engine.native_save_project_defaults(&review,Some(&json!({"selection":{"provider":"claude","modelID":"changed-default"},"accessMode":"approval","interactionMode":"build"}))).unwrap();
            }
        }
        let before = engine.store.thread(&id).unwrap();
        let changes = engine.store.mutation_serial().unwrap();
        assert!(engine.apply_native_new_thread(intent).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(engine.store.mutation_serial().unwrap(), changes);
    }
    let (_one, mut first, params) = fixture();
    let (_two, mut second, _) = fixture();
    let intent = first.prepare_native_new_thread(&params).unwrap();
    assert!(second.apply_native_new_thread(intent).is_err());
}
#[test]
fn external_writer_between_prepare_and_apply_is_detected_without_creating_a_thread() {
    let (directory, mut engine, params) = fixture();
    let first = new(&mut engine, &params);
    let id = text(&first, "id");
    let intent = engine.prepare_native_new_thread(&params).unwrap();
    let other = rusqlite::Connection::open(directory.path().join("state.sqlite")).unwrap();
    let mut changed = first.clone();
    changed["draft"] = json!("external edit");
    other
        .execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            rusqlite::params![id, changed.to_string()],
        )
        .unwrap();
    assert!(engine.apply_native_new_thread(intent).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), changed);
}
#[test]
fn due_snooze_wakes_once_persists_and_refreshes_order_without_touching_future_or_original() {
    let (directory, mut engine, params) = fixture();
    let mut due = engine.execute("threads.create", &params).unwrap();
    let id = text(&due, "id");
    due["draft"] = json!("preserved draft");
    due["future"] = json!({"keep":1});
    due["snoozedUntil"] = json!(10.);
    due["updatedAt"] = json!(1.);
    engine.store.save(&due).unwrap();
    let mut future = engine.execute("threads.create", &params).unwrap();
    future["snoozedUntil"] = json!(100.);
    future["updatedAt"] = json!(2.);
    engine.store.save(&future).unwrap();
    let source_bytes = b"private original fixture";
    let other = rusqlite::Connection::open(directory.path().join("state.sqlite")).unwrap();
    other
        .execute(
            "INSERT INTO original_files(path,data) VALUES ('fixture-original',?1)",
            [source_bytes.as_slice()],
        )
        .unwrap();
    drop(other);
    assert_eq!(engine.native_wake_due_snoozes_at(10.).unwrap(), 1);
    let woken = engine.store.thread(&id).unwrap();
    assert!(woken["snoozedUntil"].is_null());
    assert_eq!(woken["updatedAt"], 10.);
    due["snoozedUntil"] = Value::Null;
    due["updatedAt"] = json!(10.);
    assert_eq!(woken, due);
    assert_eq!(
        engine.store.thread(future["id"].as_str().unwrap()).unwrap(),
        future
    );
    assert_eq!(engine.store.summaries("", false).unwrap()[0].id, id);
    let changes = engine.store.mutation_serial().unwrap();
    assert_eq!(engine.native_wake_due_snoozes_at(10.).unwrap(), 0);
    assert_eq!(engine.store.mutation_serial().unwrap(), changes);
    assert_eq!(
        engine.store.original("fixture-original").unwrap().unwrap(),
        source_bytes
    );
    engine.store.close_for_shutdown().unwrap();
    let reopened = Store::open(&directory.path().join("state.sqlite")).unwrap();
    assert_eq!(reopened.thread(&id).unwrap(), woken);
}
#[test]
fn frozen_admissions_reject_native_new_and_wake_without_writes() {
    let (_directory, mut engine, params) = fixture();
    let first = new(&mut engine, &params);
    let id = text(&first, "id");
    engine
        .store
        .patch_thread(&id, &json!({"snoozedUntil":1.}))
        .unwrap();
    let intent = engine.prepare_native_new_thread(&params).unwrap();
    engine.freeze_admissions();
    let changes = engine.store.mutation_serial().unwrap();
    assert!(engine.apply_native_new_thread(intent).is_err());
    assert!(engine.prepare_native_new_thread(&params).is_err());
    assert!(engine.native_wake_due_snoozes_at(10.).is_err());
    assert_eq!(engine.store.mutation_serial().unwrap(), changes);
}

#[test]
fn stale_snooze_cache_rolls_back_the_entire_wake_batch_and_preserves_unknown_fields() {
    let (directory, mut engine, params) = fixture();
    let mut one = engine.execute("threads.create", &params).unwrap();
    let mut two = engine.execute("threads.create", &params).unwrap();
    one["snoozedUntil"] = json!(1.);
    two["snoozedUntil"] = json!(2.);
    engine.store.save(&one).unwrap();
    engine.store.save(&two).unwrap();
    // An older writer changed the row without updating its derived snooze cache.
    two["snoozedUntil"] = json!(100.);
    two["future"] = json!({"keep":8});
    let other = rusqlite::Connection::open(directory.path().join("state.sqlite")).unwrap();
    other
        .execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            rusqlite::params![two["id"].as_str().unwrap(), two.to_string()],
        )
        .unwrap();
    drop(other);
    assert!(engine.native_wake_due_snoozes_at(10.).is_err());
    assert_eq!(
        engine.store.thread(one["id"].as_str().unwrap()).unwrap(),
        one
    );
    assert_eq!(
        engine.store.thread(two["id"].as_str().unwrap()).unwrap(),
        two
    );
}
#[test]
fn recovering_and_imported_due_threads_are_retained_until_a_writable_source_is_available() {
    let (directory, mut engine, params) = fixture();
    let mut first = engine.execute("threads.create", &params).unwrap();
    let id = text(&first, "id");
    first["snoozedUntil"] = json!(1.);
    engine.store.save(&first).unwrap();
    engine.unsaved_threads.insert(id.clone(), first.clone());
    assert_eq!(engine.native_wake_due_snoozes_at(10.).unwrap(), 0);
    assert_eq!(engine.store.thread(&id).unwrap(), first);
    engine.unsaved_threads.remove(&id);
    let other = rusqlite::Connection::open(directory.path().join("state.sqlite")).unwrap();
    other
        .execute("INSERT INTO imported_threads(id) VALUES (?1)", [&id])
        .unwrap();
    drop(other);
    assert_eq!(engine.native_wake_due_snoozes_at(10.).unwrap(), 0);
    assert_eq!(engine.store.thread(&id).unwrap(), first);
    assert_ne!(new(&mut engine, &params)["id"], id);
}
#[test]
fn new_thread_on_a_branch_records_it_and_reuses_only_an_empty_thread_on_that_branch() {
    let (_directory, mut engine, params) = fixture();
    let plain = new(&mut engine, &params);
    let mut on_branch = params.clone();
    on_branch["branch"] = json!("feature/sidebar");
    let created = new(&mut engine, &on_branch);
    assert_ne!(
        created["id"], plain["id"],
        "an empty thread without the branch is not reused for it"
    );
    assert_eq!(created["branch"], "feature/sidebar");
    assert_eq!(
        new(&mut engine, &on_branch)["id"],
        created["id"],
        "the empty thread already on the branch is reused"
    );
    assert_eq!(
        engine.store.thread(&text(&plain, "id")).unwrap()["branch"],
        Value::Null
    );
    for branch in [json!(""), json!(" "), json!("a\nb"), json!(7)] {
        let mut invalid = params.clone();
        invalid["branch"] = branch;
        assert!(engine.prepare_native_new_thread(&invalid).is_err());
    }
}
