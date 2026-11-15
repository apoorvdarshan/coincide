//! Exercise the real project sheet shell over a scrollable conversation.
use super::{project_form_header, project_form_shell};
use gpui_kit::component::button::Button;
use gpui_kit::{
    App, AppContext, Context, InteractiveElement, IntoElement, ParentElement, Render, ScrollDelta,
    ScrollEvent, ScrollHandle, StatefulInteractiveElement, Styled, TestAppContext,
    VisualTestContext, Window, div, point, px, rgba,
};
use std::sync::{Arc, Mutex};

const CHILD: &str = "COINCIDE_HEADLESS_PROJECT_DIALOG_CHILD";

struct Harness {
    behind: ScrollHandle,
    clicks: Arc<Mutex<Vec<&'static str>>>,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let cancel = self.clicks.clone();
        let confirm = self.clicks.clone();
        let header = project_form_header(
            "Add existing folder",
            div()
                .flex()
                .gap_2()
                .child(
                    div()
                        .debug_selector(|| "project-cancel-action".into())
                        .child(
                            Button::new("fixture-project-cancel")
                                .label("Cancel")
                                .on_click(move |_, _, _| cancel.lock().unwrap().push("cancel")),
                        ),
                )
                .child(
                    div()
                        .debug_selector(|| "project-confirm-action".into())
                        .child(
                            Button::new("fixture-project-confirm")
                                .label("Add folder")
                                .on_click(move |_, _, _| confirm.lock().unwrap().push("confirm")),
                        ),
                )
                .into_any_element(),
            rgba(0x303030ff),
        );
        let mut rows = div()
            .debug_selector(|| "project-folder-content".into())
            .flex()
            .flex_col();
        for index in 0..50 {
            rows = rows.child(div().h(px(32.)).child(format!("Folder {index}")));
        }
        let body = div()
            .id("project-folder-list")
            .debug_selector(|| "project-folder-list".into())
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .child(rows)
            .into_any_element();
        let form = project_form_shell(header, body, rgba(0x303030ff), rgba(0x111111ff));
        div()
            .relative()
            .size_full()
            .child(
                div()
                    .id("synthetic-chat")
                    .size_full()
                    .track_scroll(&self.behind)
                    .overflow_y_scroll()
                    .child(div().h(px(2500.)).child("Conversation")),
            )
            .child(
                crate::chat_layout::modal_backdrop()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(div().w(px(460.)).max_h(px(280.)).child(form)),
            )
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}

#[gpui_kit::test]
#[ignore = "launched by private-child wrapper"]
fn headless_folder_actions_stay_visible_and_scroll_is_contained(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let clicks = Arc::new(Mutex::new(Vec::new()));
    let (view, vcx): (_, &mut VisualTestContext) = cx.add_window_view(|_, _| Harness {
        behind: ScrollHandle::new(),
        clicks: clicks.clone(),
    });
    vcx.update(|window, cx| {
        window.activate_window();
        draw(window, cx);
        draw(window, cx);
    });
    let before = view.read_with(vcx, |view, _| view.behind.offset());
    let cancel = vcx.debug_bounds("project-cancel-action").unwrap();
    let confirm = vcx.debug_bounds("project-confirm-action").unwrap();
    let body = vcx.debug_bounds("project-folder-list").unwrap();
    let initial_y = vcx.debug_bounds("project-folder-content").unwrap().origin.y;
    assert!(cancel.origin.y < body.origin.y && confirm.origin.y < body.origin.y);
    let position = body.center();
    vcx.simulate_mouse_move(position, None, Default::default());
    for _ in 0..12 {
        vcx.simulate_event(ScrollEvent {
            position,
            delta: ScrollDelta::Pixels(point(px(0.), px(-250.))),
            ..Default::default()
        });
        vcx.update(draw);
    }
    assert!(vcx.debug_bounds("project-folder-content").unwrap().origin.y < initial_y);
    assert_eq!(vcx.debug_bounds("project-cancel-action").unwrap(), cancel);
    assert_eq!(vcx.debug_bounds("project-confirm-action").unwrap(), confirm);
    assert_eq!(view.read_with(vcx, |view, _| view.behind.offset()), before);
    vcx.simulate_click(cancel.center(), Default::default());
    vcx.simulate_click(confirm.center(), Default::default());
    assert_eq!(*clicks.lock().unwrap(), ["cancel", "confirm"]);
    let outside = point(px(10.), px(10.));
    vcx.simulate_mouse_move(outside, None, Default::default());
    vcx.simulate_event(ScrollEvent {
        position: outside,
        delta: ScrollDelta::Pixels(point(px(0.), px(-150.))),
        ..Default::default()
    });
    vcx.update(draw);
    assert_eq!(view.read_with(vcx, |view, _| view.behind.offset()), before);
}

#[::core::prelude::v1::test]
fn private_headless_project_dialog_child() {
    let root = tempfile::tempdir().unwrap();
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command.args(["--ignored", "project_management_mount::ui_tests::headless_folder_actions_stay_visible_and_scroll_is_contained", "--nocapture", "--test-threads=1"])
        .env_clear().env(CHILD, "1").env("HOME", root.path()).env("USERPROFILE", root.path())
        .env("TMPDIR", root.path()).env("TMP", root.path()).env("TEMP", root.path())
        .env("LANG", "en_US.UTF-8").current_dir(root.path());
    #[cfg(windows)]
    for key in ["SystemRoot", "WINDIR"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
