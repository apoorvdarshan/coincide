use super::*;
const A: &str = "12345678-1234-4234-8234-1234567890AB";
const B: &str = "ABCDEFAB-1234-4234-8234-ABCDEFABCDEF";
fn fixture() -> (tempfile::TempDir, Store) {
    let directory = tempfile::tempdir().unwrap();
    let mut store = Store::open(&directory.path().join("state.sqlite")).unwrap();
    for id in [A, B] {
        store.save(&json!({"id":id,"title":"Synthetic","draft":"Keep draft","items":[{"kind":"future","opaque":7}],"sessions":{"codex":{"sessionID":"display-only-not-authority"}},"future":{"keep":9}})).unwrap();
    }
    (directory, store)
}
#[test]
fn swift_panel_mapping_follows_each_thread_and_windowwide_exception() {
    use crate::inspector_preferences::{Change, follow, saved};
    let state = json!({"threadPanels":{A:"diff",B:"preview","future-non-uuid":{"opaque":true}}});
    assert_eq!(saved(&state, A).unwrap(), Some(Panel::Diff));
    assert_eq!(
        follow(Some(Panel::Preview), saved(&state, A).unwrap(), true),
        Change::Show(Panel::Diff)
    );
    assert_eq!(
        follow(Some(Panel::Schedules), saved(&state, A).unwrap(), true),
        Change::None
    );
    assert_eq!(
        follow(Some(Panel::Diff), Some(Panel::Terminal), false),
        Change::Close
    );
    assert_eq!(
        follow(None, Some(Panel::Terminal), true),
        Change::Show(Panel::Terminal)
    );
    assert_eq!(
        saved(&json!({"threadPanels":{A:"future-panel"}}), A).unwrap(),
        None
    );
    assert_eq!(follow(Some(Panel::Diff), None, true), Change::Close);
}
#[test]
fn legacy_migration_preserves_original_bytes_unknowns_and_all_conversation_content() {
    let (_directory, mut store) = fixture();
    let original=br#"{ "selectedThreadID":"12345678-1234-4234-8234-1234567890AB", "isInspectorOpen":true, "inspectorPanel":"pullRequests", "future":{"keep":[1,2]}, "previewTabs":{"opaque":7} }"#;
    store
        .connection()
        .unwrap()
        .execute(
            "INSERT INTO original_files(path,data) VALUES ('ui-state.json',?1)",
            [original.as_slice()],
        )
        .unwrap();
    let before: Vec<_> = [A, B].iter().map(|id| store.thread(id).unwrap()).collect();
    let source = store.document(DOCUMENT).unwrap();
    assert_eq!(
        preferences::saved(source.as_ref().unwrap(), A).unwrap(),
        Some(Panel::PullRequests)
    );
    assert_eq!(
        preferences::saved(source.as_ref().unwrap(), B).unwrap(),
        None
    );
    let next = store
        .remember_native_inspector_panel(source.as_ref(), B, Some(Panel::Preview))
        .unwrap();
    assert_eq!(next["threadPanels"][A], "pullRequests");
    assert_eq!(next["threadPanels"][B], "preview");
    assert_eq!(next["future"], source.as_ref().unwrap()["future"]);
    assert_eq!(next["previewTabs"], source.as_ref().unwrap()["previewTabs"]);
    assert_eq!(store.original(DOCUMENT).unwrap().unwrap(), original);
    for (id, expected) in [A, B].iter().zip(before) {
        assert_eq!(store.thread(id).unwrap(), expected);
    }
}
#[test]
fn stale_external_writer_and_ambiguous_or_malformed_mapping_never_write() {
    let (directory, mut store) = fixture();
    let source = json!({"threadPanels":{A:"diff",B:"future-panel"},"future":7});
    store.save_document(DOCUMENT, &source).unwrap();
    let external = Connection::open(directory.path().join("state.sqlite")).unwrap();
    let newer = json!({"threadPanels":{A:"preview",B:"future-panel"},"future":8});
    external
        .execute(
            "UPDATE documents SET document=?1 WHERE name='ui-state.json'",
            [newer.to_string()],
        )
        .unwrap();
    assert!(
        store
            .remember_native_inspector_panel(Some(&source), A, Some(Panel::Diff))
            .is_err()
    );
    assert_eq!(store.document(DOCUMENT).unwrap(), Some(newer));
    for malformed in [
        json!({"threadPanels":false}),
        json!({"threadPanels":{A:"diff",(A.to_lowercase()):"preview"}}),
    ] {
        store.save_document(DOCUMENT, &malformed).unwrap();
        assert!(
            store
                .remember_native_inspector_panel(Some(&malformed), A, None)
                .is_err()
        );
        assert_eq!(store.document(DOCUMENT).unwrap(), Some(malformed));
    }
}
#[test]
fn explicit_close_preserves_unrelated_future_panel_and_windowwide_never_overwrites() {
    let (_directory, mut store) = fixture();
    let source = json!({"threadPanels":{A:"diff",B:{"future":"preserve"}},"unknown":9});
    store.save_document(DOCUMENT, &source).unwrap();
    let serial = store.mutation_serial().unwrap();
    assert_eq!(
        store
            .remember_native_inspector_panel(Some(&source), A, Some(Panel::Schedules))
            .unwrap(),
        source
    );
    assert_eq!(store.mutation_serial().unwrap(), serial);
    let next = store
        .remember_native_inspector_panel(Some(&source), A, None)
        .unwrap();
    assert!(next["threadPanels"][A].is_null());
    assert_eq!(next["threadPanels"][B], source["threadPanels"][B]);
    assert_eq!(next["unknown"], 9);
}

#[test]
fn actual_selection_change_migrates_legacy_panel_before_replacing_selected_identity() {
    let (_directory, mut store) = fixture();
    let original = json!({"selectedThreadID":A,"isInspectorOpen":true,"inspectorPanel":"pullRequests","unknown":{"keep":7}});
    store.save_document(DOCUMENT, &original).unwrap();
    store.remember_native_selected_thread(Some(B)).unwrap();
    let next = store.document(DOCUMENT).unwrap().unwrap();
    assert_eq!(
        preferences::saved(&next, A).unwrap(),
        Some(Panel::PullRequests)
    );
    assert_eq!(
        preferences::saved(&next, B).unwrap(),
        None,
        "legacy panel cannot be rebound to a newly selected thread"
    );
    assert_eq!(next["unknown"], original["unknown"]);
    let mut newer = next.clone();
    newer["future"] = json!(9);
    store.save_document(DOCUMENT, &newer).unwrap();
    let serial = store.mutation_serial().unwrap();
    assert!(
        store
            .save_native_ui_document_if_unchanged(Some(&next), &original, Some(A))
            .is_err()
    );
    assert_eq!(store.mutation_serial().unwrap(), serial);
    assert_eq!(store.document(DOCUMENT).unwrap(), Some(newer));
}

#[test]
fn bounded_overlay_read_never_falls_back_or_overwrites_future_or_original_state() {
    let (_directory, mut store) = fixture();
    let original =
        br#"{"selectedThreadID":"12345678-1234-4234-8234-1234567890AB","isInspectorOpen":true}"#;
    store
        .connection()
        .unwrap()
        .execute(
            "INSERT INTO original_files(path,data) VALUES ('ui-state.json',?1)",
            [original.as_slice()],
        )
        .unwrap();
    assert_eq!(
        preferences::saved(&store.native_inspector_document().unwrap().unwrap(), A).unwrap(),
        Some(Panel::Diff),
        "Swift's legacy panel default is Diff"
    );
    let oversized = json!({"future":"x".repeat(2*1024*1024)});
    store.save_document(DOCUMENT, &oversized).unwrap();
    let serial = store.mutation_serial().unwrap();
    assert!(store.native_inspector_document().is_err());
    assert!(store.remember_native_selected_thread(Some(B)).is_err());
    assert_eq!(store.mutation_serial().unwrap(), serial);
    assert_eq!(store.original(DOCUMENT).unwrap().unwrap(), original);
    assert_eq!(store.document(DOCUMENT).unwrap(), Some(oversized));
    store
        .connection()
        .unwrap()
        .execute("DELETE FROM documents WHERE name='ui-state.json'", [])
        .unwrap();
    store
        .connection()
        .unwrap()
        .execute("DELETE FROM original_files WHERE path='ui-state.json'", [])
        .unwrap();
    let serial = store.mutation_serial().unwrap();
    store
        .remember_native_inspector_panel(None, A, Some(Panel::Schedules))
        .unwrap();
    assert!(store.native_inspector_document().unwrap().is_none());
    assert_eq!(
        store.mutation_serial().unwrap(),
        serial,
        "window-wide Scheduled never creates a per-thread preference"
    );
}
