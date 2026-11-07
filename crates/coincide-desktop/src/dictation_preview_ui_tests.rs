//! Actual private TestPlatform input/history, without microphones or Speech.
use gpui_base::input::{NativeTextRevision, TransientEditError, TransientReplacement};
use gpui_kit::{
    App, AppContext, Context, Entity, EntityInputHandler, Focusable, IntoElement, ParentElement,
    Render, Subscription, TestAppContext, Window,
    component::input::{InputEvent, Paste, Redo, Textarea, TextareaState, Undo},
    div, px,
};
use std::{cell::Cell, rc::Rc};
const CHILD: &str = "COINCIDE_NATIVE_DICTATION_PREVIEW_CHILD";
struct Harness {
    input: Entity<TextareaState>,
    _changes: Subscription,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .child(Textarea::new(&self.input).h(px(180.0)))
    }
}
fn setup(
    cx: &mut TestAppContext,
) -> (
    Entity<Harness>,
    gpui_kit::VisualTestContext,
    Rc<Cell<usize>>,
) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let changes = Rc::new(Cell::new(0));
    let count = changes.clone();
    let (view, vcx) = cx.add_window_view(|window, cx| {
        let input = cx.new(|cx| TextareaState::new(window, cx));
        let changes = cx.subscribe(&input, move |_, _, event, _| {
            if matches!(event, InputEvent::Change) {
                count.set(count.get() + 1);
            }
        });
        Harness {
            input,
            _changes: changes,
        }
    });
    (view, vcx, changes)
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
fn seed(view: &Entity<Harness>, window: &mut Window, cx: &mut App) -> Entity<TextareaState> {
    window.activate_window();
    let input = view.read(cx).input.clone();
    input.update(cx, |state, cx| {
        state.set_value("old", window, cx);
        state.replace_all("before 🦀 after", window, cx);
        state.set_selected_range(7..11, cx);
    });
    let focus = input.read(cx).focus_handle(cx).clone();
    focus.focus(window, cx);
    draw(window, cx);
    input
}
fn preview(
    input: &Entity<TextareaState>,
    text: &str,
    window: &mut Window,
    cx: &mut App,
) -> NativeTextRevision {
    input.update(cx, |state, cx| {
        let expected = state.value().to_string();
        let range = state.selected_range();
        let end = range.start + text.len();
        let revision = state.native_text_revision(cx);
        state
            .replace_without_undo(
                &revision,
                TransientReplacement {
                    expected: &expected,
                    range,
                    replacement: text,
                    selection_after: end..end,
                    reversed: false,
                },
                window,
                cx,
            )
            .unwrap()
    })
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_native_preview_final_single_undo_and_panic_keep_prior_history(cx: &mut TestAppContext) {
    let (view, mut vcx, changes) = setup(cx);
    vcx.update(|window, cx| {
        let input = seed(&view, window, cx);
        let mut receipt = preview(&input, "合成 café", window, cx);
        input.update(cx, |state, cx| {
            let expected = state.value().to_string();
            let end = 7 + "合成 café 👩🏽‍💻".len();
            receipt = state
                .replace_without_undo(
                    &receipt,
                    TransientReplacement {
                        expected: &expected,
                        range: 7..7 + "合成 café".len(),
                        replacement: "合成 café 👩🏽‍💻",
                        selection_after: end..end,
                        reversed: false,
                    },
                    window,
                    cx,
                )
                .unwrap();
            assert!(state.has_native_preview(&receipt, cx));
            assert!(state.native_transient_unwind_fixture());
            assert!(state.restore_native_preview(cx));
            assert_eq!(state.value(), "before 🦀 after");
            assert_eq!(state.selected_range(), 7..11);
            state.replace_all("before final 👩🏽‍💻 after", window, cx);
        });
        draw(window, cx);
        assert!(input.read(cx).focus_handle(cx).is_focused(window));
        window.dispatch_action(Box::new(Undo), cx);
        assert_eq!(input.read(cx).value().as_ref(), "before 🦀 after");
        window.dispatch_action(Box::new(Undo), cx);
        assert_eq!(input.read(cx).value().as_ref(), "old");
        window.dispatch_action(Box::new(Redo), cx);
        assert_eq!(input.read(cx).value().as_ref(), "before 🦀 after");
        window.dispatch_action(Box::new(Redo), cx);
        assert_eq!(input.read(cx).value().as_ref(), "before final 👩🏽‍💻 after");
        draw(window, cx);
        assert!(input.read(cx).focus_handle(cx).is_focused(window));
    });
    assert_eq!(
        changes.get(),
        6,
        "only prior/final ordinary edits and undo/redo emit Change"
    );
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_native_preview_restores_before_real_paste_and_undo(cx: &mut TestAppContext) {
    let (view, mut vcx, _) = setup(cx);
    vcx.update(|window, cx| {
        let input = seed(&view, window, cx);
        preview(&input, "partial", window, cx);
        draw(window, cx);
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string("pasted 🍎"));
        window.dispatch_action(Box::new(Paste), cx);
        assert_eq!(
            input.read(cx).value().as_ref(),
            "before pasted 🍎 after",
            "paste must apply to original selection, never partial text"
        );
        window.dispatch_action(Box::new(Undo), cx);
        assert_eq!(input.read(cx).value().as_ref(), "before 🦀 after");
        preview(&input, "another partial", window, cx);
        window.dispatch_action(Box::new(Undo), cx);
        assert_eq!(
            input.read(cx).value().as_ref(),
            "old",
            "undo restores original source before replaying previous history"
        );
        window.dispatch_action(Box::new(Redo), cx);
        assert_eq!(input.read(cx).value().as_ref(), "before 🦀 after");
        window.dispatch_action(Box::new(Redo), cx);
        assert_eq!(
            input.read(cx).value().as_ref(),
            "before pasted 🍎 after",
            "the pre-existing redo entry survives transient text and cancellation"
        );
    });
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_native_preview_restores_before_ime_and_selection(cx: &mut TestAppContext) {
    let (view, mut vcx, _) = setup(cx);
    vcx.update(|window, cx| {
        let input = seed(&view, window, cx);
        preview(&input, "途中の音声", window, cx);
        input.update(cx, |state, cx| {
            EntityInputHandler::replace_and_mark_text_in_range(
                state,
                None,
                "あ",
                Some(1..1),
                window,
                cx,
            );
            assert_eq!(
                state.value(),
                "before あ after",
                "IME preedit begins against original selection"
            );
            EntityInputHandler::replace_text_in_range(state, None, "愛", window, cx);
            assert_eq!(state.value(), "before 愛 after");
        });
        window.dispatch_action(Box::new(Undo), cx);
        assert_eq!(input.read(cx).value().as_ref(), "before 🦀 after");
        input.update(cx, |state, cx| state.set_selected_range(7..11, cx));
        let receipt = preview(&input, "new partial", window, cx);
        input.update(cx, |state, cx| {
            state.set_selected_range(0..0, cx);
            assert_eq!(state.value(), "before 🦀 after");
            assert_eq!(state.selected_range(), 0..0);
            assert!(!state.matches_native_text_revision(&receipt, cx));
        });
        draw(window, cx);
        assert!(input.read(cx).focus_handle(cx).is_focused(window));
    });
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_native_preview_rejects_stale_source_ime_readonly_tokens_and_bad_graphemes(
    cx: &mut TestAppContext,
) {
    let (view, mut vcx, _) = setup(cx);
    vcx.update(|window, cx| {
        let input = seed(&view, window, cx);
        input.update(cx, |state, cx| {
            let expected = state.value().to_string();
            let receipt = state.native_text_revision(cx);
            let invalid = TransientReplacement {
                expected: &expected,
                range: 8..8,
                replacement: "x",
                selection_after: 9..9,
                reversed: false,
            };
            assert!(matches!(
                state.replace_without_undo(&receipt, invalid, window, cx),
                Err(TransientEditError::Bounds)
            ));
            state.set_readonly(true, cx);
            assert!(matches!(
                state.replace_without_undo(
                    &receipt,
                    TransientReplacement {
                        expected: &expected,
                        range: 7..11,
                        replacement: "x",
                        selection_after: 8..8,
                        reversed: false
                    },
                    window,
                    cx
                ),
                Err(TransientEditError::NotEditable)
            ));
            state.set_readonly(false, cx);
            EntityInputHandler::replace_and_mark_text_in_range(
                state,
                None,
                "あ",
                Some(1..1),
                window,
                cx,
            );
            let marked = state.value().to_string();
            let fresh = state.native_text_revision(cx);
            assert!(matches!(
                state.replace_without_undo(
                    &fresh,
                    TransientReplacement {
                        expected: &marked,
                        range: 0..0,
                        replacement: "x",
                        selection_after: 1..1,
                        reversed: false
                    },
                    window,
                    cx
                ),
                Err(TransientEditError::Composition)
            ));
            EntityInputHandler::replace_text_in_range(state, None, "愛", window, cx);
            state.set_value("new route typed draft", window, cx);
            assert!(!state.restore_native_preview(cx));
            assert_eq!(state.value(), "new route typed draft");
            assert!(matches!(
                state.replace_without_undo(
                    &receipt,
                    TransientReplacement {
                        expected: &expected,
                        range: 7..11,
                        replacement: "x",
                        selection_after: 8..8,
                        reversed: false
                    },
                    window,
                    cx
                ),
                Err(TransientEditError::Changed)
            ));
            state.set_value("@file", window, cx);
            state
                .replace_range_with_token(
                    0..5,
                    gpui_kit::component::input::InlineToken::new("fixture-file", "@file"),
                    window,
                    cx,
                )
                .unwrap();
            let tokens = state.tokens().to_vec();
            let fresh = state.native_text_revision(cx);
            let expected = state.value().to_string();
            assert!(matches!(
                state.replace_without_undo(
                    &fresh,
                    TransientReplacement {
                        expected: &expected,
                        range: 0..5,
                        replacement: "x",
                        selection_after: 1..1,
                        reversed: false
                    },
                    window,
                    cx
                ),
                Err(TransientEditError::Unsupported)
            ));
            assert_eq!(state.tokens(), tokens);
            assert_eq!(state.value(), "@file");
        });
    });
}
#[::core::prelude::v1::test]
fn private_actual_dictation_preview_history_child() {
    use std::{fs, process::Command};
    let root = std::env::temp_dir().join(format!(
        "coincide-native-preview-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    fs::create_dir(&root).unwrap();
    for name in ["home", "tmp", "empty-path"] {
        fs::create_dir(root.join(name)).unwrap();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "dictation_preview_ui_tests::headless_",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .env(CHILD, "1")
        .env("HOME", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("PATH", root.join("empty-path"))
        .env("LANG", "en_US.UTF-8")
        .current_dir(&root)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success() && stdout.contains("4 passed"),
        "actual native preview fixtures failed; retained {}\n{stdout}\n{stderr}",
        root.display()
    );
    fs::remove_dir_all(root).unwrap();
}
