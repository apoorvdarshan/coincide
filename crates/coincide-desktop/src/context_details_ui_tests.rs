//! This mounts only the production readonly text component in GPUI's synthetic
//! TestPlatform. It never constructs Coincide/native hosts or reads user state.
use super::readonly_reference_text;
use gpui_kit::base::input::{Copy, SelectAll};
use gpui_kit::component::input::TextareaState;
use gpui_kit::{
    App, AppContext, Context, Entity, EntityInputHandler, Focusable, IntoElement, ParentElement,
    Render, Styled, TestAppContext, VisualTestContext, Window, div, px,
};
const CHILD: &str = "COINCIDE_HEADLESS_CONTEXT_DETAILS_CHILD";
const TEXT: &str = "  SYNTHETIC attached text 👩🏽‍💻 café 中文\nsecond line\n  ";
struct Harness {
    input: Entity<TextareaState>,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().w(px(480.)).h(px(360.)).child(readonly_reference_text(
            &self.input,
            false,
            "Attached text",
            300.,
        ))
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
#[gpui_kit::test]
#[ignore = "launched by private-child wrapper"]
fn headless_readonly_details_preserves_selection_copy_and_rejects_native_text_edits(
    cx: &mut TestAppContext,
) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let (view, vcx): (Entity<Harness>, &mut VisualTestContext) =
        cx.add_window_view(|window, cx| {
            let input = cx.new(|cx| {
                let mut state = TextareaState::new(window, cx);
                state.set_value(TEXT, window, cx);
                state
            });
            Harness { input }
        });
    vcx.update(|window, cx| {
        window.activate_window();
        let input = view.read(cx).input.clone();
        input.read(cx).focus_handle(cx).focus(window, cx);
        draw(window, cx);
    });
    vcx.run_until_parked();
    vcx.update(draw);
    vcx.update(|window, cx| {
        window.dispatch_action(Box::new(SelectAll), cx);
    });
    vcx.run_until_parked();
    vcx.update(draw);
    let selected = view.read_with(vcx, |this, cx| this.input.read(cx).selected_range());
    assert_eq!(
        selected,
        0..TEXT.len(),
        "the readonly native input must actually select the full source"
    );
    vcx.update(|window, cx| {
        window.dispatch_action(Box::new(Copy), cx);
    });
    vcx.run_until_parked();
    let clipboard = vcx.read(|cx| cx.read_from_clipboard().and_then(|item| item.text()));
    assert_eq!(
        clipboard.as_deref(),
        Some(TEXT),
        "native copy preserves whitespace and Unicode"
    );
    vcx.update(|window, cx| {
        let input = view.read(cx).input.clone();
        input.update(cx, |state, cx| {
            EntityInputHandler::replace_text_in_range(state, None, "SHOULD NOT EDIT", window, cx)
        });
        draw(window, cx);
    });
    vcx.run_until_parked();
    assert_eq!(
        view.read_with(vcx, |this, cx| this.input.read(cx).value().to_string()),
        TEXT
    );
}
#[::core::prelude::v1::test]
fn native_readonly_context_details_in_private_child() {
    use std::{fs, process::Command};
    let root = std::env::temp_dir().join(format!(
        "coincide-context-details-fixture-{}",
        uuid::Uuid::new_v4()
    ));
    fs::create_dir(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        fs::create_dir(root.join(child)).unwrap();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let output=Command::new(std::env::current_exe().unwrap()).args(["--ignored","context_details_mount::tests::headless_readonly_details_preserves_selection_copy_and_rejects_native_text_edits","--nocapture","--test-threads=1"])
        .env_clear().env(CHILD,"1").env("HOME",root.join("home")).env("TMPDIR",root.join("tmp")).env("PATH",root.join("empty-path")).env("LANG","en_US.UTF-8").current_dir(&root).output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "private readonly details child failed; fixture retained at {}\n{stdout}\n{stderr}",
        root.display()
    );
    assert!(
        stdout.contains("1 passed"),
        "one actual readonly-dispatch test must run\n{stdout}\n{stderr}"
    );
    fs::remove_dir_all(root).unwrap();
}
