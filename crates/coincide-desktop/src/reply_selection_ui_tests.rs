//! Real GPUI rendered Markdown selection on synthetic TestPlatform only. No
//! Coincide constructor, native host, clipboard fallback, agent or user files.
use super::{TextViewState, focused_reply_projection, managed_markdown};
use gpui_kit::{
    App, AppContext, Context, Entity, Focusable, InteractiveElement, IntoElement, Modifiers,
    MouseButton, ParentElement, Render, Styled, TestAppContext, VisualTestContext, Window,
    component::input::TextareaState,
    component::menu::{ContextMenuExt as _, PopupMenuItem},
    div, point, px,
};
use std::{cell::RefCell, rc::Rc};
const CHILD: &str = "COINCIDE_HEADLESS_REPLY_SELECTION_CHILD";
const SOURCE: &str = "one **bold** café 👩🏽‍💻\n\nrepeat and `repeat`";
const ITEM: &str = "12345678-1234-1234-1234-123456789ABC";
struct Harness {
    state: Entity<TextViewState>,
    input: Entity<TextareaState>,
    thread: String,
    item: String,
    menu_reply: Rc<RefCell<Option<String>>>,
}
impl Render for Harness {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let expected_thread = self.thread.clone();
        let expected_item = self.item.clone();
        let reply = self.menu_reply.clone();
        let message = div()
            .id("reply-selection-menu-test")
            .w_full()
            .child(managed_markdown(
                &self.thread,
                &self.item,
                &self.state,
                window,
                cx,
            ))
            .context_menu(move |menu, window, cx| {
                let selection = focused_reply_projection(window, cx).filter(|selection| {
                    selection.thread == expected_thread && selection.item == expected_item
                });
                let reply = reply.clone();
                menu.item(PopupMenuItem::new("Reply to selection").on_click(
                    move |_, window, cx| {
                        if let Some(selection) = &selection
                            && selection.current_in_menu(window, cx)
                        {
                            *reply.borrow_mut() = Some(selection.selected_text().to_owned());
                        }
                    },
                ))
            });
        div()
            .w(px(560.))
            .h(px(300.))
            .flex()
            .flex_col()
            .child(message)
            .child(gpui_kit::component::input::Textarea::new(&self.input).h(px(80.)))
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
fn setup(cx: &mut TestAppContext) -> (Entity<Harness>, &mut VisualTestContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let (view, vcx) = cx.add_window_view(|window, cx| Harness {
        state: cx.new(|cx| TextViewState::markdown(SOURCE, cx).selectable(true)),
        input: cx.new(|cx| TextareaState::new(window, cx)),
        thread: "thread-one".into(),
        item: ITEM.into(),
        menu_reply: Rc::new(RefCell::new(None)),
    });
    vcx.update(|window, cx| {
        window.activate_window();
        let state = view.read(cx).state.clone();
        let focus = state.read(cx).focus_handle().clone();
        focus.focus(window, cx);
        draw(window, cx);
        state.update(cx, |state, cx| state.select_all(cx));
        draw(window, cx);
    });
    vcx.run_until_parked();
    vcx.update(draw);
    (view, vcx)
}

#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_reply_menu_keeps_selection_after_popup_clears_it(cx: &mut TestAppContext) {
    let (view, vcx) = setup(cx);
    let press = point(px(20.), px(12.));
    vcx.simulate_mouse_down(press, MouseButton::Right, Modifiers::default());
    vcx.simulate_mouse_up(press, MouseButton::Right, Modifiers::default());
    vcx.run_until_parked();
    vcx.update(draw);
    // Native popup interaction can clear the selected text before activation.
    vcx.update(|window, cx| {
        let state = view.read(cx).state.clone();
        state.update(cx, |state, cx| state.clear_selection(cx));
        draw(window, cx);
    });
    let item = point(press.x + px(30.), press.y + px(17.));
    vcx.simulate_mouse_move(item, None, Modifiers::default());
    vcx.simulate_click(item, Modifiers::default());
    vcx.run_until_parked();
    let reply = view.read_with(vcx, |view, _| view.menu_reply.borrow().clone());
    assert!(reply.is_some_and(|text| text.contains("one bold café 👩🏽‍💻")));
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_exact_owned_native_reply_selection_and_core_projection(cx: &mut TestAppContext) {
    let (_view, vcx) = setup(cx);
    let projection = vcx.update(|window, cx| {
        focused_reply_projection(window, cx).expect("actual selected native renderer")
    });
    assert_eq!(projection.thread, "thread-one");
    assert_eq!(projection.item, ITEM);
    assert_eq!(projection.source(), SOURCE);
    let text = &projection.rendered.as_str()[projection.rendered_range.clone()];
    assert!(text.contains("one bold café 👩🏽‍💻"));
    assert!(text.contains("repeat and repeat"));
    assert!(!text.contains("**bold**"));
    assert!(vcx.update(|window, cx| projection.current(window, cx)));
    assert!(projection.into_native("assistant").is_ok());
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_native_focus_selection_reparse_and_semantic_rebind_revoke_the_projection(
    cx: &mut TestAppContext,
) {
    let (view, vcx) = setup(cx);
    let initial = vcx.update(|window, cx| focused_reply_projection(window, cx).unwrap());
    vcx.update(|window, cx| {
        let state = view.read(cx).state.clone();
        state.update(cx, |state, cx| state.clear_selection(cx));
        draw(window, cx);
    });
    assert!(!vcx.update(|window, cx| initial.current(window, cx)));
    assert!(
        vcx.update(|window, cx| focused_reply_projection(window, cx))
            .is_none()
    );
    vcx.update(|window, cx| {
        let state = view.read(cx).state.clone();
        state.update(cx, |state, cx| state.select_all(cx));
        draw(window, cx);
    });
    let selected = vcx.update(|window, cx| focused_reply_projection(window, cx).unwrap());
    vcx.update(|window, cx| {
        let input = view.read(cx).input.clone();
        input.read(cx).focus_handle(cx).focus(window, cx);
        draw(window, cx);
    });
    assert!(!vcx.update(|window, cx| selected.current(window, cx)));
    assert!(vcx.update(|window, cx| selected.current_in_menu(window, cx)));
    // A real popup click can clear the text selection before its handler.
    vcx.update(|window, cx| {
        let state = view.read(cx).state.clone();
        state.update(cx, |state, cx| state.clear_selection(cx));
        draw(window, cx);
    });
    assert!(vcx.update(|window, cx| selected.current_in_menu(window, cx)));
    assert!(
        vcx.update(|window, cx| focused_reply_projection(window, cx))
            .is_none()
    );
    vcx.update(|window, cx| {
        let state = view.read(cx).state.clone();
        let focus = state.read(cx).focus_handle().clone();
        focus.focus(window, cx);
        state.update(cx, |state, cx| state.select_all(cx));
        draw(window, cx);
    });
    let rebound = vcx.update(|window, cx| focused_reply_projection(window, cx).unwrap());
    view.update(vcx, |this, cx| {
        this.thread = "thread-two".into();
        this.item = "87654321-1234-1234-1234-123456789ABC".into();
        cx.notify();
    });
    vcx.update(draw);
    assert!(!vcx.update(|window, cx| rebound.current(window, cx)));
    let before = vcx.update(|window, cx| focused_reply_projection(window, cx).unwrap());
    vcx.update(|window, cx| {
        let state = view.read(cx).state.clone();
        state.update(cx, |state, cx| state.set_text("Changed reply", cx));
        draw(window, cx);
    });
    vcx.run_until_parked();
    vcx.update(draw);
    assert!(!vcx.update(|window, cx| before.current(window, cx)));
}
#[::core::prelude::v1::test]
fn actual_native_reply_selection_in_private_child() {
    use std::{fs, process::Command};
    let root = std::env::temp_dir().join(format!(
        "coincide-reply-selection-fixture-{}",
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
            "transcript::reply_selection_tests::headless_",
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
        output.status.success(),
        "native selection child failed; fixture retained at {}\n{stdout}\n{stderr}",
        root.display()
    );
    assert!(
        stdout.contains("3 passed"),
        "all actual native selection cases must run\n{stdout}\n{stderr}"
    );
    fs::remove_dir_all(root).unwrap();
}
