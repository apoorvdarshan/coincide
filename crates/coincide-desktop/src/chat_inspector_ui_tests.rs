//! Real TestPlatform compositor with production columns/geometry and retained
//! synthetic panels. No Coincide constructor, native WebView/PTY, Git or network.
use super::{Panel, columns};
use gpui_kit::{
    App, AppContext, Bounds, Context, Entity, Focusable, IntoElement, ParentElement, Pixels,
    Render, Styled, TestAppContext, Window, WindowBounds, WindowOptions,
    component::input::{Textarea, TextareaState},
    div, point, px, size,
};
use std::{cell::RefCell, rc::Rc};
const CHILD: &str = "COINCIDE_HEADLESS_CHAT_INSPECTOR_CHILD";
struct FakePanel {
    thread: String,
}
impl Render for FakePanel {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.thread.clone())
    }
}
struct Harness {
    input: Entity<TextareaState>,
    panels: Vec<(Panel, Entity<FakePanel>)>,
    shown: Option<Panel>,
    share: f64,
    measured: Rc<RefCell<Vec<Bounds<Pixels>>>>,
}
impl Render for Harness {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let chat = div()
            .id("synthetic-chat")
            .flex()
            .flex_col()
            .flex_1()
            .min_w_0()
            .h_full()
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child("Synthetic retained transcript"),
            )
            .child(Textarea::new(&self.input).h(px(120.)))
            .into_any_element();
        let inspector = self.shown.map(|shown| {
            let panel = self
                .panels
                .iter()
                .find(|(kind, _)| *kind == shown)
                .unwrap()
                .1
                .clone();
            let available = f64::from(f32::from(window.viewport_size().width));
            div()
                .w(px(
                    crate::terminal_layout::inspector_width(self.share, available) as f32,
                ))
                .h_full()
                .flex_shrink_0()
                .child(panel)
                .into_any_element()
        });
        let measured = self.measured.clone();
        columns(chat, inspector).on_children_prepainted(move |bounds, _, _| {
            *measured.borrow_mut() = bounds;
        })
    }
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_real_columns_keep_composer_focus_draft_geometry_and_retained_panel_entities(
    cx: &mut TestAppContext,
) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let measured = Rc::new(RefCell::new(Vec::new()));
    let (handle, view) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    point(px(0.), px(0.)),
                    size(px(1000.), px(700.)),
                ))),
                ..WindowOptions::default()
            },
            cx,
            |window, cx| {
                cx.new(|cx| Harness {
                    input: cx.new(|cx| {
                        let mut input = TextareaState::new(window, cx);
                        input.set_value("Unsent synthetic draft 👩🏽‍💻", window, cx);
                        input
                    }),
                    panels: [
                        Panel::Workspace,
                        Panel::ConversationSchedules,
                        Panel::Terminal,
                        Panel::Browser,
                    ]
                    .into_iter()
                    .map(|kind| {
                        (
                            kind,
                            cx.new(|_| FakePanel {
                                thread: "thread-one".into(),
                            }),
                        )
                    })
                    .collect(),
                    shown: None,
                    share: 0.5,
                    measured: measured.clone(),
                })
            },
        )
        .unwrap()
    });
    let (input, identities) = cx.read(|cx| {
        let state = view.read(cx);
        (
            state.input.clone(),
            state
                .panels
                .iter()
                .map(|(_, entity)| entity.entity_id())
                .collect::<Vec<_>>(),
        )
    });
    cx.update_window(handle, |_, window, cx| {
        window.activate_window();
        input.read(cx).focus_handle(cx).focus(window, cx);
        draw(window, cx);
    })
    .unwrap();
    cx.run_until_parked();
    for shown in [
        Some(Panel::Workspace),
        Some(Panel::ConversationSchedules),
        Some(Panel::Browser),
        Some(Panel::Terminal),
        None,
    ] {
        view.update(cx, |state, cx| {
            state.shown = shown;
            cx.notify();
        });
        cx.update_window(handle, |_, window, cx| {
            draw(window, cx);
            assert!(
                input.read(cx).focus_handle(cx).is_focused(window),
                "inspector switches cannot steal the composer focus"
            );
            assert_eq!(input.read(cx).value().as_ref(), "Unsent synthetic draft 👩🏽‍💻");
        })
        .unwrap();
        let bounds = measured.borrow().clone();
        assert_eq!(bounds.len(), if shown.is_some() { 2 } else { 1 });
        assert!(f32::from(bounds[0].size.height) > 0. && f32::from(bounds[0].size.height) <= 700.);
        if shown.is_some() {
            assert!(f32::from(bounds[0].size.width) >= 420.);
            assert_eq!(f32::from(bounds[1].size.width), 500.);
            assert!(
                bounds[1].origin.x >= bounds[0].right(),
                "right inspector must sit beside rather than replace or cover the transcript/composer"
            );
            assert!(
                f32::from(bounds[1].size.height) > 0. && f32::from(bounds[1].size.height) <= 700.
            );
        } else {
            assert_eq!(f32::from(bounds[0].size.width), 1000.);
        }
        assert_eq!(
            cx.read(|cx| view
                .read(cx)
                .panels
                .iter()
                .map(|(_, entity)| entity.entity_id())
                .collect::<Vec<_>>()),
            identities
        );
    }
    view.update(cx, |state, cx| {
        state.shown = Some(Panel::Workspace);
        state.share = 0.9;
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| draw(window, cx))
        .unwrap();
    let bounds = measured.borrow().clone();
    assert_eq!(f32::from(bounds[0].size.width), 420.);
    assert_eq!(f32::from(bounds[1].size.width), 580.);
    cx.update_window(handle, |_, window, _| window.remove_window())
        .unwrap();
}
#[::core::prelude::v1::test]
fn private_actual_chat_inspector_compositor_child() {
    use std::{fs, process::Command};
    let root = std::env::temp_dir().join(format!(
        "coincide-chat-inspector-fixture-{}",
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
            "chat_inspector::native_tests::headless_",
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
        output.status.success() && stdout.contains("1 passed"),
        "actual compositor child failed; fixture retained at {}\n{stdout}\n{stderr}",
        root.display()
    );
    fs::remove_dir_all(root).unwrap();
}
