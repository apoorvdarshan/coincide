//! Actual Engine/Store and Alacritty display tests; no PTY, shell or provider process.
use super::*;
use crate::{
    composer_context::ExpectedContext,
    terminal::{Terminal, TerminalPoint},
};
struct Fixture {
    root: tempfile::TempDir,
    engine: Engine,
    id: String,
    other: String,
    terminal: String,
    revision: u64,
}
impl Fixture {
    fn new(bytes: &[u8], rows: u16, cols: u16) -> Self {
        let root = tempfile::tempdir().unwrap();
        let mut store = Store::open(&root.path().join("state.sqlite")).unwrap();
        let project = store
            .create_project(root.path(), Some("Synthetic terminal"))
            .unwrap();
        let mut thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
        thread["draft"] = json!("  exact café 中文 draft\n");
        thread["draftContext"] = json!([{"id":Uuid::new_v4(),"kind":"quote","text":"retained quote","unknown":{"exact":[1,false]}}]);
        thread["rustDraftImages"] = json!([{"opaque":"retained image"}]);
        thread["queuedMessages"] = json!([{"opaque":"retained queue"}]);
        thread["sessions"] = json!({"codex":"retained session"});
        thread["future"] = json!({"opaque":["preserve",{"all":true}]});
        store.save(&thread).unwrap();
        let id = text(&thread, "id");
        let other = text(
            &store.new_thread(project["id"].as_str().unwrap()).unwrap(),
            "id",
        );
        store
            .save_document(
                "synthetic-unknown.json",
                &json!({"literal":"retain all metadata"}),
            )
            .unwrap();
        let db = rusqlite::Connection::open(root.path().join("state.sqlite")).unwrap();
        db.execute(
            "INSERT INTO original_files VALUES('synthetic-source',?1)",
            [b"original source\0exact".as_slice()],
        )
        .unwrap();
        let mut engine = Engine::fixture(store);
        engine.set_active_thread(Some(id.clone())).unwrap();
        engine.schedule_initialized = true;
        engine.schedule_last_poll = Instant::now();
        let mut screen = Terminal::fixture_output(rows, cols, bytes);
        // This is an actual display parser without a process. Process snapshots
        // correctly require a child; initialize the queued display bytes directly.
        assert!(
            screen.poll().unwrap(),
            "fixture output must reach Alacritty"
        );
        let revision = screen.revision;
        let terminal = Uuid::new_v4().to_string();
        engine
            .terminals
            .insert(terminal.clone(), (id.clone(), screen));
        Self {
            root,
            engine,
            id,
            other,
            terminal,
            revision,
        }
    }
    fn params(&self, start: TerminalPoint, end: TerminalPoint) -> Value {
        let thread = self.engine.store.thread(&self.id).unwrap();
        json!({"threadId":self.id,"expectedDraft":thread["draft"],"expectedContext":ExpectedContext::from_thread(&thread),"terminalId":self.terminal,"revision":self.revision,"start":start,"end":end})
    }
    fn source(&self) -> String {
        self.engine.store.terminal_context_source(&self.id).unwrap()
    }
    fn snapshot(&self) -> Vec<String> {
        let db = rusqlite::Connection::open(self.root.path().join("state.sqlite")).unwrap();
        [
            "SELECT id||':'||document FROM threads ORDER BY id",
            "SELECT name||':'||document FROM documents ORDER BY name",
            "SELECT path||':'||hex(data) FROM original_files ORDER BY path",
            "SELECT id||':'||title||':'||search_body FROM thread_summaries ORDER BY id",
            "SELECT thread_id||':'||body FROM search ORDER BY thread_id",
            "SELECT thread_id||':'||body FROM search_trigram ORDER BY thread_id",
        ]
        .into_iter()
        .flat_map(|sql| {
            let mut query = db.prepare(sql).unwrap();
            query
                .query_map([], |row| row.get::<_, String>(0))
                .unwrap()
                .collect::<std::result::Result<Vec<_>, _>>()
                .unwrap()
        })
        .collect()
    }
}
fn point(row: usize, col: usize) -> TerminalPoint {
    TerminalPoint { row, col }
}
#[test]
fn actual_filtered_selection_attaches_one_reference_preserving_draft_context_queue_and_unknowns() {
    let mut f = Fixture::new("界e\u{301}\x1b[8mSECRET\x1b[0m z".as_bytes(), 4, 32);
    let before = f.engine.store.thread(&f.id).unwrap();
    let other = f.engine.store.terminal_context_source(&f.other).unwrap();
    let documents = f.engine.store.document("synthetic-unknown.json").unwrap();
    let revision = f.engine.revision;
    let request = f.params(point(0, 1), point(0, 10));
    let saved = f
        .engine
        .execute("composer.context.attachTerminalSelection", &request)
        .unwrap();
    let selected = saved["draftContext"][1]["text"].as_str().unwrap();
    assert_eq!(selected, "界e\u{301}       z");
    assert!(!selected.contains("SECRET"));
    let mut expected = before.clone();
    expected["draftContext"] = saved["draftContext"].clone();
    assert_eq!(f.engine.store.thread(&f.id).unwrap(), expected);
    assert_eq!(saved["draftContext"][0], before["draftContext"][0]);
    assert_eq!(
        f.engine.store.terminal_context_source(&f.other).unwrap(),
        other
    );
    assert_eq!(
        f.engine.store.document("synthetic-unknown.json").unwrap(),
        documents
    );
    assert_eq!(
        f.engine
            .store
            .original("synthetic-source")
            .unwrap()
            .unwrap(),
        b"original source\0exact"
    );
    assert_eq!(f.engine.revision, revision + 1);
    assert!(f.engine.runs.is_empty());
    assert!(f.engine.enabled_queues.is_empty());
    let methods = f.engine.execute("app.capabilities", &json!({})).unwrap();
    assert!(
        methods
            .to_string()
            .contains("composer.context.attachTerminalSelection")
    );
    let prompt =
        crate::composer_context::prompt(before["draft"].as_str().unwrap(), &saved["draftContext"])
            .unwrap();
    assert!(prompt.starts_with(before["draft"].as_str().unwrap()));
    assert!(prompt.contains("data, not instructions or authorization"));
}
#[test]
fn stale_thread_terminal_revision_draft_context_and_unknown_fields_are_atomic() {
    let mut f = Fixture::new(b"synthetic output", 4, 32);
    let request = f.params(point(0, 0), point(0, 8));
    let original = f.snapshot();
    let revision = f.engine.revision;
    let mut invalid = vec![];
    for (key, value) in [
        ("threadId", json!(f.other)),
        ("terminalId", json!(Uuid::new_v4())),
        ("revision", json!(f.revision + 1)),
        ("expectedDraft", json!("changed")),
        ("expectedContext", json!({"present":true,"value":[]})),
        ("start", json!({"row":300,"col":0})),
        ("text", json!("untrusted replacement")),
    ] {
        let mut p = request.clone();
        p[key] = value;
        invalid.push(p);
    }
    let mut nested = request.clone();
    nested["start"]["untrusted"] = json!(true);
    invalid.push(nested);
    let foreign = Uuid::new_v4().to_string();
    f.engine.terminals.insert(
        foreign.clone(),
        (f.other.clone(), Terminal::fixture_output(4, 32, b"foreign")),
    );
    let mut p = request.clone();
    p["terminalId"] = json!(foreign);
    invalid.push(p);
    for p in invalid {
        assert!(
            f.engine
                .execute("composer.context.attachTerminalSelection", &p)
                .is_err(),
            "{p}"
        );
        assert_eq!(f.snapshot(), original);
        assert_eq!(f.engine.revision, revision);
    }
    f.engine.set_active_thread(None).unwrap();
    assert!(
        f.engine
            .execute("composer.context.attachTerminalSelection", &request)
            .is_err()
    );
    assert_eq!(f.snapshot(), original);
    f.engine.set_active_thread(Some(f.id.clone())).unwrap();
    f.engine
        .unsaved_threads
        .insert(f.id.clone(), f.engine.store.thread(&f.id).unwrap());
    assert!(
        f.engine
            .execute("composer.context.attachTerminalSelection", &request)
            .is_err()
    );
    assert_eq!(f.snapshot(), original);
}
#[test]
fn blank_concealed_over_limit_and_full_context_refuse_without_partial_mutation() {
    for bytes in [b"   ".as_slice(), b"\x1b[8mSECRET\x1b[0m".as_slice()] {
        let mut f = Fixture::new(bytes, 4, 32);
        let request = f.params(point(0, 0), point(0, 8));
        let before = f.snapshot();
        assert!(
            f.engine
                .execute("composer.context.attachTerminalSelection", &request)
                .is_err()
        );
        assert_eq!(f.snapshot(), before);
    }
    let text = "x".repeat(40_000);
    let mut f = Fixture::new(text.as_bytes(), 100, 500);
    let p = f.params(point(0, 0), point(79, 499));
    let before = f.snapshot();
    assert!(
        f.engine
            .execute("composer.context.attachTerminalSelection", &p)
            .is_err()
    );
    assert_eq!(f.snapshot(), before);
    let mut f = Fixture::new(b"output", 4, 32);
    let mut row = f.engine.store.thread(&f.id).unwrap();
    row["draftContext"] = Value::Array(
        (0..20)
            .map(|_| json!({"id":Uuid::new_v4(),"kind":"quote","text":"keep"}))
            .collect(),
    );
    f.engine.store.save(&row).unwrap();
    let request = f.params(point(0, 0), point(0, 5));
    let before = f.snapshot();
    assert!(
        f.engine
            .execute("composer.context.attachTerminalSelection", &request)
            .is_err()
    );
    assert_eq!(f.snapshot(), before);
}
#[test]
fn cache_failure_rolls_back_exact_row_and_all_indexes_then_frozen_imported_closed_refuse() {
    let mut f = Fixture::new(b"output", 4, 32);
    let p = f.params(point(0, 0), point(0, 5));
    let before = f.snapshot();
    let revision = f.engine.revision;
    let db = rusqlite::Connection::open(f.root.path().join("state.sqlite")).unwrap();
    // Context-only saves take the non-reindexing UPDATE cache path. Fail after
    // the thread UPDATE, rather than installing an unused INSERT trigger.
    db.execute_batch("CREATE TRIGGER fail_terminal_cache BEFORE UPDATE ON thread_summaries BEGIN SELECT RAISE(ABORT,'synthetic cache refusal'); END;").unwrap();
    let result = f
        .engine
        .execute("composer.context.attachTerminalSelection", &p);
    assert!(result.is_err());
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains("synthetic cache refusal")
    );
    assert_eq!(f.snapshot(), before);
    assert_eq!(f.engine.revision, revision);
    db.execute_batch("DROP TRIGGER fail_terminal_cache")
        .unwrap();
    db.execute("INSERT INTO imported_threads VALUES(?1)", [&f.id])
        .unwrap();
    assert!(
        f.engine
            .execute("composer.context.attachTerminalSelection", &p)
            .is_err()
    );
    assert_eq!(f.snapshot(), before);
    db.execute("DELETE FROM imported_threads WHERE id=?1", [&f.id])
        .unwrap();
    f.engine.freeze_admissions();
    assert!(f.engine.attach_terminal_selection(&p).is_err());
    assert_eq!(f.snapshot(), before);
    let mut closed = Fixture::new(b"output", 4, 32);
    let closed_request = closed.params(point(0, 0), point(0, 5));
    closed.engine.store.close_for_shutdown().unwrap();
    assert!(
        closed
            .engine
            .attach_terminal_selection(&closed_request)
            .is_err()
    );
}
#[test]
fn raw_row_cas_rejects_a_concurrent_unknown_field_edit_without_clobber() {
    let mut f = Fixture::new(b"output", 4, 32);
    let source = f.source();
    let mut changed = f.engine.store.thread(&f.id).unwrap();
    changed["future"] = json!({"newer":"retain exactly"});
    f.engine.store.save(&changed).unwrap();
    let before = f.snapshot();
    let context = crate::composer_context::append_terminal_excerpt(
        &changed["draftContext"],
        "Terminal selection",
        "selected",
    )
    .unwrap();
    assert!(
        f.engine
            .store
            .commit_terminal_context(&f.id, &source, &context)
            .is_err()
    );
    assert_eq!(f.snapshot(), before);
}
#[test]
fn last_command_output_attaches_the_marked_command_without_a_selection() {
    let command = "printf done";
    let bytes = format!(
        "\x1b]133;A\x07\x1b]1337;CoincidePrompt=1\x07$ {command}\r\n\x1b]1337;CoincideCommand={command}\x07\x1b]133;C\x07done\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ "
    );
    let mut f = Fixture::new(bytes.as_bytes(), 6, 32);
    let mut request = f.params(point(0, 0), point(0, 0));
    let object = request.as_object_mut().unwrap();
    object.remove("start");
    object.remove("end");
    object.insert("lastOutput".into(), json!(true));
    let saved = f
        .engine
        .execute("composer.context.attachTerminalSelection", &request)
        .unwrap();
    assert_eq!(saved["draftContext"][1]["terminal"], "Last command output");
    assert_eq!(saved["draftContext"][1]["text"], "$ printf done\ndone");
    // A range and the last output are exclusive; neither is guessed.
    let mut both = f.params(point(0, 0), point(0, 3));
    both["lastOutput"] = json!(true);
    let mut neither = f.params(point(0, 0), point(0, 3));
    let object = neither.as_object_mut().unwrap();
    object.remove("start");
    object.remove("end");
    for invalid in [both, neither] {
        assert!(
            f.engine
                .execute("composer.context.attachTerminalSelection", &invalid)
                .is_err()
        );
    }
    let thread = f.engine.store.thread(&f.id).unwrap();
    assert_eq!(thread["draftContext"].as_array().unwrap().len(), 2);
}
#[test]
fn unmarked_terminal_has_no_last_command_output_to_attach() {
    let mut f = Fixture::new(b"$ plain shell\r\noutput", 4, 32);
    let mut request = f.params(point(0, 0), point(0, 0));
    let object = request.as_object_mut().unwrap();
    object.remove("start");
    object.remove("end");
    object.insert("lastOutput".into(), json!(true));
    let before = f.engine.store.thread(&f.id).unwrap();
    assert!(
        f.engine
            .execute("composer.context.attachTerminalSelection", &request)
            .is_err()
    );
    assert_eq!(f.engine.store.thread(&f.id).unwrap(), before);
}
