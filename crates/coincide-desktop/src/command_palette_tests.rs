use super::{
    Activation, MAX_BYTES, MAX_ENTRIES, MenuContent, Model, PaletteCommand as Command,
    PaletteEntry, PaletteEvent, PaletteGroup as Group, PaletteList, PaletteMenu, PaletteSnapshot,
    Row, SearchKind, SearchRequest, ThreadFacts, validate,
};

const NOW: f64 = 800_000_000.0;

fn entry(id: &str, title: &str) -> PaletteEntry {
    PaletteEntry::new(
        Command::OpenThread {
            thread_id: id.into(),
        },
        title,
        Group::Threads,
    )
}
fn thread(id: &str, title: &str, days: f64) -> PaletteEntry {
    let mut entry = entry(id, title);
    entry.thread = Some(ThreadFacts {
        updated_at: NOW - days * 86_400.0,
        ..Default::default()
    });
    entry
}
fn action(id: &str, title: &str, group: Group) -> PaletteEntry {
    PaletteEntry::new(Command::Action { id: id.into() }, title, group)
}
fn snapshot(revision: u64, entries: Vec<PaletteEntry>) -> PaletteSnapshot {
    PaletteSnapshot {
        revision,
        entries,
        menus: Vec::new(),
        branch_prefix: String::new(),
        now: NOW,
    }
}
fn titles(model: &Model) -> Vec<&str> {
    model
        .items()
        .map(|(entry, _)| entry.title.as_str())
        .collect()
}
fn headers(model: &Model) -> Vec<&str> {
    model
        .rows
        .iter()
        .filter_map(|row| match row {
            Row::Header(title) => Some(title.as_str()),
            Row::Item { .. } => None,
        })
        .collect()
}
fn activated(model: &mut Model, command: &Command) -> Option<PaletteEvent> {
    match model.activate(command) {
        Some(Activation::Event(event)) => Some(event),
        _ => None,
    }
}

#[test]
fn an_empty_query_lists_actions_then_recent_threads_then_more_actions() {
    let mut entries = vec![
        action("action:new-chat", "New Chat", Group::Actions),
        action("action:settings", "Open Settings", Group::MoreActions),
        action("setting:general", "General Settings", Group::Settings),
    ];
    entries.extend((0..14).map(|i| thread(&format!("t{i}"), &format!("Thread {i}"), 1.0)));
    entries[3].secondary = true;
    let m = Model::new(snapshot(1, entries)).unwrap();
    assert_eq!(headers(&m), ["Actions", "Recent Threads", "More Actions"]);
    let listed = titles(&m);
    // Twelve recent threads; the open one goes last.
    assert_eq!(listed.len(), 1 + 12 + 1);
    assert_eq!(listed[1], "Thread 1");
    assert_eq!(listed[12], "Thread 0");
    assert_eq!(listed[13], "Open Settings");
    assert!(!listed.contains(&"General Settings"));
}

#[test]
fn a_query_ranks_groups_by_their_best_match_and_shows_bold_ranges() {
    let mut project = PaletteEntry::new(
        Command::SelectProject {
            project_id: Some("p".into()),
        },
        "Sidebar app",
        Group::Projects,
    );
    project.keywords = vec!["/code/sidebar".into()];
    let entries = vec![
        action("action:sidebar", "Show Sidebar", Group::MoreActions),
        thread("a", "Fix sidebar lag", 1.0),
        project,
        action("setting:general", "General Settings", Group::Settings),
    ];
    let mut m = Model::new(snapshot(1, entries)).unwrap();
    m.query("sidebar");
    assert_eq!(headers(&m), ["Actions", "Threads", "Projects"]);
    let (first, ranges) = m.items().next().unwrap();
    assert_eq!(first.title, "Show Sidebar");
    assert_eq!(ranges, [5..12]);
    // Typos are forgiven when nothing matches at a word start.
    m.query("sidbear");
    assert!(titles(&m).contains(&"Fix sidebar lag"));
    m.query("posthog");
    assert!(m.rows.is_empty());
    assert!(m.selected.is_none());
}

#[test]
fn next_to_matching_threads_other_groups_show_their_best_three() {
    let mut entries = (0..5)
        .map(|i| {
            action(
                &format!("a{i}"),
                &format!("Deploy step {i}"),
                Group::Actions,
            )
        })
        .collect::<Vec<_>>();
    entries.extend((0..25).map(|i| thread(&format!("t{i}"), &format!("Deploy {i}"), 1.0)));
    let mut m = Model::new(snapshot(1, entries)).unwrap();
    m.query("deploy");
    let actions = m
        .items()
        .filter(|(entry, _)| entry.group == Group::Actions)
        .count();
    let threads = m
        .items()
        .filter(|(entry, _)| entry.group == Group::Threads)
        .count();
    assert_eq!((actions, threads), (3, 20));
    // ">" lists actions only, without the limit.
    m.query(">deploy");
    assert_eq!(headers(&m), ["Actions"]);
    assert_eq!(m.total(), 5);
    m.query(">");
    assert_eq!(m.total(), 5);
    assert_eq!(m.empty_label(), "No matching actions.");
}

#[test]
fn the_open_thread_is_listed_last_and_never_lifts_its_group() {
    let mut current = thread("current", "Settings", 0.0);
    current.secondary = true;
    let entries = vec![
        current,
        thread("other", "Settings sync", 3.0),
        action("action:settings", "Open Settings", Group::MoreActions),
    ];
    let mut m = Model::new(snapshot(1, entries)).unwrap();
    m.query("settings");
    assert_eq!(headers(&m), ["Actions", "Threads"]);
    assert_eq!(titles(&m), ["Open Settings", "Settings sync", "Settings"]);
}

#[test]
fn nested_lists_filter_their_entries_and_go_back_to_the_parent_query() {
    let projects = vec![
        PaletteEntry::new(
            Command::NewThread {
                project_id: Some("one".into()),
            },
            "Coincide",
            Group::Projects,
        ),
        PaletteEntry::new(
            Command::NewThread {
                project_id: Some("two".into()),
            },
            "Website",
            Group::Projects,
        ),
    ];
    let mut snap = snapshot(
        1,
        vec![PaletteEntry::new(
            Command::OpenMenu { id: "new".into() },
            "New Thread in…",
            Group::Actions,
        )],
    );
    snap.menus.push(PaletteMenu {
        id: "new".into(),
        title: "New Thread in…".into(),
        placeholder: "Search projects…".into(),
        content: MenuContent::Lists(vec![PaletteList {
            title: "Projects".into(),
            entries: projects,
        }]),
    });
    let mut m = Model::new(snap).unwrap();
    m.query("new");
    let open = Command::OpenMenu { id: "new".into() };
    assert_eq!(m.activate(&open), Some(Activation::Opened));
    assert!(m.open);
    assert_eq!(m.query, "");
    assert_eq!(m.placeholder(), "Search projects…");
    assert_eq!(titles(&m), ["Coincide", "Website"]);
    assert!(m.hints().iter().any(|hint| hint.contains("Back")));
    m.query("web");
    assert_eq!(titles(&m), ["Website"]);
    assert_eq!(m.back().as_deref(), Some("new"));
    assert_eq!(titles(&m), ["New Thread in…"]);
    assert!(m.back().is_none());
    // A pushed list's entries activate with the snapshot's revision.
    m.activate(&open);
    let website = Command::NewThread {
        project_id: Some("two".into()),
    };
    assert_eq!(
        activated(&mut m, &website),
        Some(PaletteEvent::Activated {
            revision: 1,
            command: website
        })
    );
}

#[test]
fn searching_lists_request_results_and_ignore_stale_ones() {
    let mut snap = snapshot(
        3,
        vec![PaletteEntry::new(
            Command::OpenMenu { id: "files".into() },
            "Go to File…",
            Group::MoreActions,
        )],
    );
    let kind = SearchKind::Files {
        root: "/repo".into(),
    };
    snap.menus.push(PaletteMenu {
        id: "files".into(),
        title: "Go to File…".into(),
        placeholder: "Search files…".into(),
        content: MenuContent::Search(kind.clone()),
    });
    let mut m = Model::new(snap).unwrap();
    assert!(m.take_request().is_none());
    m.activate(&Command::OpenMenu { id: "files".into() });
    let first = m.take_request().unwrap();
    assert_eq!(
        (first.kind.clone(), first.query.as_str()),
        (kind.clone(), "")
    );
    m.query("main");
    let second = m.take_request().unwrap();
    assert_eq!(
        second,
        SearchRequest {
            generation: second.generation,
            kind,
            query: "main".into()
        }
    );
    let file = |path: &str| {
        PaletteEntry::new(
            Command::OpenFile {
                root: "/repo".into(),
                path: path.into(),
                line: None,
            },
            path,
            Group::Actions,
        )
    };
    let lists = |path: &str| {
        vec![PaletteList {
            title: "Files".into(),
            entries: vec![file(path)],
        }]
    };
    assert!(!m.set_results(first.generation, lists("old.rs")).unwrap());
    assert!(m.rows.is_empty());
    assert!(m.set_results(second.generation, lists("main.rs")).unwrap());
    assert_eq!(headers(&m), ["Files"]);
    assert_eq!(titles(&m), ["main.rs"]);
    // Results are shown as they are, not filtered again.
    assert_eq!(
        m.items().next().unwrap().1,
        &[] as &[std::ops::Range<usize>]
    );
    m.back();
    assert!(m.take_request().is_none());
    assert!(!m.set_results(second.generation, lists("main.rs")).unwrap());
}

#[test]
fn folder_paths_browse_with_tab_completion() {
    let mut m = Model::new(snapshot(1, vec![entry("t", "Thread")])).unwrap();
    m.query("~/co");
    assert_eq!(
        m.placeholder(),
        "Enter a folder path, e.g. ~/projects/my-app"
    );
    assert!(m.hints().iter().any(|hint| hint.contains("Add Project")));
    let request = m.take_request().unwrap();
    assert_eq!(request.kind, SearchKind::Folders);
    let mut code = PaletteEntry::new(
        Command::AddProject {
            path: "/Users/me/code".into(),
        },
        "code",
        Group::Projects,
    );
    code.completion = Some("~/code/".into());
    m.set_results(
        request.generation,
        vec![PaletteList {
            title: "Folders".into(),
            entries: vec![code],
        }],
    )
    .unwrap();
    assert_eq!(m.completion().as_deref(), Some("~/code/"));
    m.query("~/zzz");
    let request = m.take_request().unwrap();
    m.set_results(request.generation, Vec::new()).unwrap();
    assert_eq!(m.empty_label(), "No folders match this path.");
    m.query("code");
    assert!(m.take_request().is_none());
    assert_eq!(titles(&m), Vec::<&str>::new());
}

#[test]
fn page_moves_eight_rows_and_stops_at_the_ends() {
    let entries = (0..20)
        .map(|i| thread(&format!("t{i}"), &format!("Thread {i}"), 1.0))
        .collect();
    let mut m = Model::new(snapshot(1, entries)).unwrap();
    m.query("thread");
    m.move_by(8);
    assert_eq!(
        m.selected,
        Some(Command::OpenThread {
            thread_id: "t8".into()
        })
    );
    m.move_by(100);
    assert_eq!(
        m.selected,
        Some(Command::OpenThread {
            thread_id: "t19".into()
        })
    );
    m.move_by(-8);
    m.move_by(-8);
    m.move_by(-8);
    assert_eq!(
        m.selected,
        Some(Command::OpenThread {
            thread_id: "t0".into()
        })
    );
}

#[test]
fn every_token_must_match_title_or_supplied_keyword() {
    let mut target = action("build", "Build preview", Group::Actions);
    target.keywords = vec!["Swift".into(), "Rust".into(), "desktop".into()];
    let mut m = Model::new(snapshot(
        1,
        vec![target, action("server", "Build server", Group::Actions)],
    ))
    .unwrap();
    m.query("rust desktop build");
    assert_eq!(titles(&m), vec!["Build preview"]);
    m.query("rust absent");
    assert!(m.rows.is_empty());
    m.query(&"中".repeat(300));
    assert_eq!(m.query.chars().count(), 256);
    assert!(m.query.is_char_boundary(m.query.len()));
}

#[test]
fn revision_replacement_preserves_identity_across_reorder_and_refuses_removed_click() {
    let a = entry("a", "Same title");
    let b = entry("b", "Same title");
    let mut m = Model::new(snapshot(5, vec![a.clone(), b.clone()])).unwrap();
    m.move_by(1);
    assert_eq!(m.selected, Some(b.command.clone()));
    m.replace(snapshot(6, vec![b.clone(), a.clone()])).unwrap();
    assert_eq!(m.selected, Some(b.command.clone()));
    m.replace(snapshot(7, vec![a.clone()])).unwrap();
    assert_eq!(m.selected, Some(a.command.clone()));
    assert!(m.activate(&b.command).is_none());
    assert!(m.open);
    assert_eq!(
        activated(&mut m, &a.command),
        Some(PaletteEvent::Activated {
            revision: 7,
            command: a.command.clone()
        })
    );
    assert!(m.activate(&a.command).is_none());
}

#[test]
fn a_replaced_snapshot_keeps_an_open_list_only_while_it_exists() {
    let menu = |id: &str| PaletteMenu {
        id: id.into(),
        title: "Search in Project…".into(),
        placeholder: "Search text in files…".into(),
        content: MenuContent::Search(SearchKind::Text {
            root: "/repo".into(),
        }),
    };
    let open = PaletteEntry::new(
        Command::OpenMenu { id: "text".into() },
        "Search in Project…",
        Group::MoreActions,
    );
    let mut first = snapshot(1, vec![open.clone()]);
    first.menus.push(menu("text"));
    let mut m = Model::new(first).unwrap();
    m.query("sea");
    m.activate(&open.command);
    m.query("needle");
    let pending = m.take_request().unwrap();
    let mut same = snapshot(2, vec![open.clone()]);
    same.menus.push(menu("text"));
    m.replace(same).unwrap();
    assert_eq!(m.stack.len(), 1);
    assert!(m.take_request().is_none(), "the same search keeps running");
    assert_eq!(m.generation, pending.generation);
    m.replace(snapshot(3, vec![entry("t", "Thread")])).unwrap();
    assert!(m.stack.is_empty());
    assert_eq!(m.query, "sea");
}

#[test]
fn disabled_selection_is_replaced_and_navigation_skips_unavailable_rows() {
    let a = entry("a", "A");
    let mut disabled = entry("b", "B");
    disabled.enabled = false;
    disabled.disabled_reason = Some("Unavailable".into());
    let c = entry("c", "C");
    let mut m = Model::new(snapshot(1, vec![a.clone(), disabled.clone(), c.clone()])).unwrap();
    m.move_by(1);
    assert_eq!(m.selected, Some(c.command.clone()));
    m.move_by(1);
    assert_eq!(m.selected, Some(c.command.clone()));
    m.move_by(-1);
    assert_eq!(m.selected, Some(a.command.clone()));
    m.move_by(-1);
    assert_eq!(m.selected, Some(a.command.clone()));
    assert!(m.activate(&disabled.command).is_none());
    let mut changed = a;
    changed.enabled = false;
    m.replace(snapshot(2, vec![changed, disabled, c.clone()]))
        .unwrap();
    assert_eq!(m.selected, Some(c.command));
}

#[test]
fn none_semantics_are_typed_distinct_and_never_resolve_current_project() {
    let all = Command::SelectProject { project_id: None };
    let projectless = Command::NewThread { project_id: None };
    assert_ne!(all, projectless);
    assert_ne!(all.key(), projectless.key());
    let item = PaletteEntry::new(all.clone(), "All projects", Group::Projects);
    let other = PaletteEntry::new(projectless.clone(), "New Chat", Group::Actions);
    let mut m = Model::new(snapshot(9, vec![item, other])).unwrap();
    m.query("all projects");
    assert_eq!(
        activated(&mut m, &all),
        Some(PaletteEvent::Activated {
            revision: 9,
            command: all
        })
    );
}

#[test]
fn escape_dismisses_without_activation_and_empty_snapshots_select_nothing() {
    let a = entry("a", "Z recent");
    let b = entry("b", "A older");
    let mut m = Model::new(snapshot(1, vec![a.clone(), b])).unwrap();
    assert_eq!(titles(&m), vec!["Z recent", "A older"]);
    assert_eq!(m.dismiss(), Some(PaletteEvent::Dismissed));
    assert!(m.activate(&a.command).is_none());
    assert!(m.dismiss().is_none());
    let mut m = Model::new(snapshot(1, vec![])).unwrap();
    m.move_by(1);
    m.move_by(-1);
    assert!(m.selected.is_none());
}

#[test]
fn invalid_or_stale_snapshot_replacement_is_atomic() {
    let a = entry("a", "A");
    let mut m = Model::new(snapshot(10, vec![a.clone()])).unwrap();
    assert!(m.replace(snapshot(10, vec![entry("b", "B")])).is_err());
    assert!(m.replace(snapshot(9, vec![])).is_err());
    assert!(m.replace(snapshot(11, vec![a.clone(), a.clone()])).is_err());
    let mut missing_menu = snapshot(12, vec![a.clone()]);
    missing_menu.entries[0].command = Command::OpenMenu { id: "gone".into() };
    assert!(m.replace(missing_menu).is_err());
    assert_eq!(m.snapshot.revision, 10);
    assert_eq!(m.selected, Some(a.command));
    assert_eq!(titles(&m), vec!["A"]);
}

#[test]
fn per_entry_strings_keywords_ids_and_paths_are_bounded() {
    let mut e = entry("id", &"中".repeat(512));
    assert!(validate(&snapshot(1, vec![e.clone()])).is_ok());
    e.title.push('中');
    assert!(validate(&snapshot(1, vec![e])).is_err());
    let mut e = entry("id", "title");
    e.subtitle = Some("x".repeat(1025));
    assert!(validate(&snapshot(1, vec![e])).is_err());
    let mut e = entry("id", "title");
    e.keywords = vec!["word".into(); 33];
    assert!(validate(&snapshot(1, vec![e])).is_err());
    let mut e = entry("id", "title");
    e.trailing = Some("x".repeat(65));
    assert!(validate(&snapshot(1, vec![e])).is_err());
    assert!(validate(&snapshot(1, vec![entry(&"x".repeat(129), "title")])).is_err());
    assert!(validate(&snapshot(1, vec![entry("id", "text\0text")])).is_err());
    let blank = action(" ", "Blank", Group::Actions);
    assert!(validate(&snapshot(1, vec![blank])).is_err());
    let file = PaletteEntry::new(
        Command::OpenFile {
            root: "/repo".into(),
            path: "a\0b".into(),
            line: Some(1),
        },
        "a",
        Group::Actions,
    );
    assert!(validate(&snapshot(1, vec![file])).is_err());
}

#[test]
fn total_memory_and_row_count_bounds_include_reserved_capacity() {
    let mut e = entry("id", "small");
    let mut overallocated = String::with_capacity(MAX_BYTES + 1);
    overallocated.push('x');
    e.title = overallocated;
    assert!(validate(&snapshot(1, vec![e])).is_err());
    let rows = (0..=MAX_ENTRIES)
        .map(|i| entry(&i.to_string(), "row"))
        .collect();
    assert!(validate(&snapshot(1, rows)).is_err());
}

#[test]
fn distinct_commands_have_distinct_keys() {
    let keys = [
        Command::OpenSettings,
        Command::ShowSchedules,
        Command::Action {
            id: "settings".into(),
        },
        Command::OpenMenu {
            id: "settings".into(),
        },
        Command::AddProject {
            path: "settings".into(),
        },
        Command::OpenFile {
            root: "/a".into(),
            path: "b".into(),
            line: Some(2),
        },
        Command::OpenFile {
            root: "/a".into(),
            path: "b".into(),
            line: None,
        },
    ]
    .map(|command| command.key());
    let unique = keys.iter().collect::<std::collections::HashSet<_>>();
    assert_eq!(unique.len(), keys.len());
}
