//! Exercise the real popup-menu click and anchored review layout on TestPlatform.
use super::{review_pointer_position, review_popover};
use gpui_kit::{
    App, AppContext, ClickEvent, Context, Entity, InteractiveElement, IntoElement, Modifiers,
    MouseButton, ParentElement, Pixels, Point, Render, Styled, TestAppContext, VisualTestContext,
    WeakEntity, Window,
    component::menu::{ContextMenuExt as _, PopupMenuItem},
    div, point,
    prelude::FluentBuilder,
    px, size,
};

const CHILD: &str = "COINCIDE_HEADLESS_SIDEBAR_REVIEW_CHILD";

struct Harness {
    anchor: Option<Point<Pixels>>,
}

fn row(id: &'static str, x: f32, y: f32, parent: WeakEntity<Harness>) -> impl IntoElement {
    div()
        .id(id)
        .absolute()
        .left(px(x))
        .top(px(y))
        .w(px(60.))
        .h(px(30.))
        .context_menu(move |menu, _, _| {
            let parent = parent.clone();
            menu.item(
                PopupMenuItem::element(|_, _| {
                    div()
                        .debug_selector(|| "delete-review-menu-item".into())
                        .child("Delete…")
                })
                .on_click(move |event, _, cx| {
                    let _ = parent.update(cx, |this, cx| {
                        this.anchor = review_pointer_position(event);
                        cx.notify();
                    });
                }),
            )
        })
}

impl Render for Harness {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let parent = cx.entity().downgrade();
        div()
            .size_full()
            .child(row("bot-row", 40., 60., parent.clone()))
            .child(row("bottom-row", 710., 530., parent))
            .when_some(self.anchor, |view, anchor| {
                view.child(review_popover(
                    anchor,
                    div()
                        .debug_selector(|| "sidebar-review-test-panel".into())
                        .w(px(300.))
                        .h(px(180.)),
                ))
            })
    }
}

fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}

#[gpui_kit::test]
#[ignore = "private-child wrapper only"]
fn headless_menu_review_follows_click_and_fits_window(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let (view, vcx): (Entity<Harness>, &mut VisualTestContext) =
        cx.add_window_view(|_, _| Harness { anchor: None });
    vcx.simulate_resize(size(px(800.), px(600.)));
    vcx.update(|window, cx| {
        window.activate_window();
        draw(window, cx);
    });

    for press in [point(px(55.), px(75.)), point(px(735.), px(545.))] {
        view.update(vcx, |this, cx| {
            this.anchor = None;
            cx.notify();
        });
        vcx.update(draw);
        vcx.simulate_mouse_down(press, MouseButton::Right, Modifiers::default());
        vcx.simulate_mouse_up(press, MouseButton::Right, Modifiers::default());
        vcx.run_until_parked();
        vcx.update(draw);
        let menu = vcx
            .debug_bounds("delete-review-menu-item")
            .expect("delete menu item is visible");
        let click = menu.center();
        vcx.simulate_mouse_move(click, None, Modifiers::default());
        vcx.simulate_click(click, Modifiers::default());
        vcx.run_until_parked();
        vcx.update(draw);
        assert_eq!(view.read_with(vcx, |this, _| this.anchor), Some(click));
        let panel = vcx
            .debug_bounds("sidebar-review-test-panel")
            .expect("review panel is visible");
        assert!(panel.left() >= px(0.) && panel.right() <= px(800.));
        assert!(panel.top() >= px(0.) && panel.bottom() <= px(600.));
        let dx = (panel.left() - click.x)
            .max(click.x - panel.right())
            .max(px(0.));
        let dy = (panel.top() - click.y)
            .max(click.y - panel.bottom())
            .max(px(0.));
        assert!(
            dx <= px(7.) && dy <= px(7.),
            "review {panel:?} is far from {click:?}"
        );
    }
    assert_eq!(review_pointer_position(&ClickEvent::default()), None);
}

#[test]
fn private_headless_sidebar_review_child() {
    let root =
        std::env::temp_dir().join(format!("coincide-sidebar-review-{}", uuid::Uuid::new_v4()));
    coincide_core::native_file::private_directory(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        coincide_core::native_file::private_directory(&root.join(child)).unwrap();
    }
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args(["--ignored", "sidebar_lifecycle::sidebar_lifecycle_ui_tests::headless_menu_review_follows_click_and_fits_window", "--nocapture", "--test-threads=1"])
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
        "sidebar review child failed at {}\n{stdout}\n{stderr}",
        root.display()
    );
    std::fs::remove_dir_all(root).unwrap();
}
