//! Real TestPlatform rendering of the production Diff panel with a synthetic diff
//! injected as a finished load. No Coincide constructor, Git, provider or network;
//! the Engine store lives in the private child's fixture directory.
use super::*;
// The glob brings GPUI's `test` attribute, which expands to `#[test]` again.
use ::core::prelude::v1::test;
use coincide_core::{
    api::Engine,
    store::Store,
    workspace_diff::{ChangeStatus, DiffHunk, DiffLine, FileDiff, LineKind},
};
use gpui_kit::{TestAppContext, VisualTestContext};
use std::sync::Mutex;
const CHILD: &str = "COINCIDE_HEADLESS_DIFF_PANEL_CHILD";

struct Harness {
    panel: Entity<DiffPanel>,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .w(px(720.))
            .h(px(560.))
            .flex()
            .flex_col()
            .child(self.panel.clone())
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
fn message(panel: &DiffPanel) -> Option<Message> {
    match &panel.content {
        Content::Empty(message) => Some(message.clone()),
        _ => None,
    }
}
fn line(kind: LineKind, text: &str, old: Option<usize>, new: Option<usize>) -> DiffLine {
    DiffLine {
        kind,
        text: text.into(),
        old_line: old,
        new_line: new,
    }
}
fn synthetic() -> GitDiff {
    let mut long = FileDiff::new("src/long.rs", ChangeStatus::Modified);
    let mut lines = vec![line(LineKind::Deletion, "let value = 1;", Some(1), None)];
    lines.push(line(
        LineKind::Addition,
        "let value = 22;\tdone",
        None,
        Some(1),
    ));
    for index in 2..400 {
        lines.push(line(
            LineKind::Context,
            &format!("context {index} {}", "x".repeat(index % 120)),
            Some(index),
            Some(index),
        ));
    }
    lines.push(line(
        LineKind::NoNewline,
        "\\ No newline at end of file",
        None,
        None,
    ));
    long.hunks.push(DiffHunk {
        old_start: 1,
        old_count: 399,
        new_start: 1,
        new_count: 399,
        section: "fn synthetic()".into(),
        lines,
    });
    long.additions = 1;
    long.deletions = 1;
    let mut second = FileDiff::new("src/second.rs", ChangeStatus::Added);
    let mut lines = vec![line(LineKind::Addition, "added", None, Some(1))];
    for index in 2..122 {
        lines.push(line(
            LineKind::Context,
            &format!("second {index}"),
            Some(index - 1),
            Some(index),
        ));
    }
    second.hunks.push(DiffHunk {
        old_start: 1,
        old_count: 120,
        new_start: 1,
        new_count: 121,
        section: String::new(),
        lines,
    });
    second.additions = 1;
    let mut image = FileDiff::new("assets/image.png", ChangeStatus::Untracked);
    image.is_binary = true;
    let mut renamed = FileDiff::new("docs/new name.md", ChangeStatus::Renamed);
    renamed.old_path = Some("docs/old name.md".into());
    GitDiff {
        files: vec![long, second, image, renamed],
        is_truncated: true,
        base_label: Some("HEAD".into()),
    }
}

#[gpui_kit::test]
#[ignore = "launched by private-child wrapper"]
fn headless_diff_panel_renders_follows_collapses_and_copies(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    exercise(cx);
}

fn exercise(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let data = std::env::current_dir().unwrap().join("data");
    coincide_core::native_file::private_directory(&data).unwrap();
    let engine: SharedEngine = Arc::new(Mutex::new(Engine::new(
        Store::open(&data.join("state.sqlite")).unwrap(),
    )));
    let (view, vcx): (Entity<Harness>, &mut VisualTestContext) =
        cx.add_window_view(|window, cx| Harness {
            panel: cx.new(|cx| DiffPanel::new(engine.clone(), window, cx)),
        });
    let panel = view.read_with(vcx, |harness, _| harness.panel.clone());
    vcx.update(|window, cx| {
        window.activate_window();
        draw(window, cx);
    });
    assert!(matches!(
        panel.read_with(vcx, |panel, _| message(panel)),
        Some(Message::NoThread)
    ));
    // A finished load, as the worker would deliver it; no thread is bound, so the
    // panel never starts Git of its own.
    vcx.update(|window, cx| {
        panel.update(cx, |panel, cx| {
            let diff = synthetic();
            let presentation = Presentation::make(&diff);
            panel.apply(
                Outcome::Diff {
                    root: PathBuf::from("synthetic"),
                    diff: Arc::new(diff),
                    presentation: Arc::new(presentation),
                },
                cx,
            );
        });
        draw(window, cx);
    });
    vcx.run_until_parked();
    vcx.update(draw);
    let (rows, file_rows, selected) = panel.read_with(vcx, |panel, _| {
        (
            panel.document.rows.len(),
            panel.document.file_rows.clone(),
            panel.selected_file,
        )
    });
    assert_eq!(rows, 403 + 123 + 2 + 2, "headers, hunks, lines and notes");
    assert_eq!(file_rows, [0, 403, 526, 528]);
    assert_eq!(selected, Some(0), "the file list follows the top file");
    // Scrolling into the second file moves the list selection with it.
    vcx.update(|window, cx| {
        panel.update(cx, |panel, _| {
            panel.document.list.scroll_to(ListOffset {
                item_ix: 430,
                offset_in_item: px(2.),
            })
        });
        draw(window, cx);
        draw(window, cx);
    });
    assert_eq!(
        panel.read_with(vcx, |panel, _| (
            panel.document.visible_file(),
            panel.selected_file
        )),
        (Some(1), Some(1))
    );
    // Pinned gutters and headers render while text scrolls sideways.
    vcx.update(|window, cx| {
        panel.update(cx, |panel, _| {
            panel.document.list.scroll_to(ListOffset {
                item_ix: 30,
                offset_in_item: px(0.),
            });
            panel
                .document
                .horizontal
                .set_offset(point(px(-120.), px(0.)));
        });
        draw(window, cx);
        draw(window, cx);
    });
    // Row selection copies the line's source text.
    vcx.update(|window, cx| {
        panel.update(cx, |panel, cx| {
            panel.click_row(3, false, false, None, window, cx)
        });
        draw(window, cx);
        window.dispatch_action(Box::new(gpui_kit::base::input::Copy), cx);
    });
    vcx.run_until_parked();
    assert_eq!(
        vcx.read(|cx| cx.read_from_clipboard().and_then(|item| item.text())),
        Some("let value = 22;\tdone".to_owned())
    );
    // Side by side keeps the file at the top and pairs the replacement.
    vcx.update(|window, cx| {
        panel.update(cx, |panel, cx| {
            panel.change_layout(DiffLayout::SideBySide, cx)
        });
        draw(window, cx);
        draw(window, cx);
    });
    let (rows, layout, top) = panel.read_with(vcx, |panel, _| {
        (
            panel.document.rows.len(),
            panel.document.layout,
            panel.document.visible_file(),
        )
    });
    assert_eq!(layout, DiffLayout::SideBySide);
    assert_eq!(rows, 402 + 123 + 2 + 2, "the replacement shares one row");
    assert_eq!(top, Some(0));
    // Collapsing keeps the header; Collapse All Files leaves only headers.
    vcx.update(|window, cx| {
        panel.update(cx, |panel, cx| panel.toggle_file(0, cx));
        draw(window, cx);
    });
    assert_eq!(
        panel.read_with(vcx, |panel, _| panel.document.rows.len()),
        1 + 123 + 2 + 2
    );
    vcx.update(|window, cx| {
        panel.update(cx, |panel, cx| panel.toggle_collapse_all(cx));
        draw(window, cx);
    });
    assert!(panel.read_with(vcx, |panel, _| panel.document.all_collapsed()));
    assert_eq!(
        panel.read_with(vcx, |panel, _| panel.document.rows.len()),
        4
    );
    // An empty scope replaces the diff with Swift's message.
    vcx.update(|window, cx| {
        panel.update(cx, |panel, cx| {
            panel.apply(
                Outcome::Empty(Message::NoBranchChanges(Some("main".into()))),
                cx,
            )
        });
        draw(window, cx);
    });
    assert!(matches!(
        panel.read_with(vcx, |panel, _| message(panel)),
        Some(Message::NoBranchChanges(Some(base))) if base == "main"
    ));
    assert!(panel.read_with(vcx, |panel, _| panel.document.rows.is_empty()));
}

#[::core::prelude::v1::test]
fn private_headless_diff_panel_child() {
    let root = std::env::temp_dir().join(format!(
        "coincide-diff-panel-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    coincide_core::native_file::private_directory(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        coincide_core::native_file::private_directory(&root.join(child)).unwrap();
    }
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--ignored",
            "diff_panel::native_tests::headless_diff_panel_renders_follows_collapses_and_copies",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .env(CHILD, "1")
        .env("HOME", root.join("home"))
        .env("USERPROFILE", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("TMP", root.join("tmp"))
        .env("TEMP", root.join("tmp"))
        .env("PATH", root.join("empty-path"))
        .env("LANG", "en_US.UTF-8")
        .current_dir(&root);
    #[cfg(windows)]
    for key in ["SystemRoot", "WINDIR"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    let output = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success() && stdout.contains("1 passed"),
        "headless Diff panel fixture failed; retained {}\n{stdout}\n{stderr}",
        root.display()
    );
    std::fs::remove_dir_all(root).unwrap();
}
