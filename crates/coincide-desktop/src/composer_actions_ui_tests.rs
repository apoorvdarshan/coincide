//! Real layout and pointer dispatch through the production composer action row.
use super::*;
use ::core::prelude::v1::test;
use gpui_kit::{Modifiers, TestAppContext, VisualTestContext};
use std::{cell::Cell, rc::Rc};

const CHILD: &str = "COINCIDE_HEADLESS_COMPOSER_LAYOUT_CHILD";
const CHIPS: [(&str, &str); 6] = [
    ("layout-model", "GPT-6.1 Terra"),
    ("layout-effort", "Max"),
    ("layout-speed", "Fast"),
    ("layout-access", "Full access"),
    ("layout-follow", "Steer"),
    ("layout-mode", "Build"),
];
const ACTIONS: [(&str, &str); 4] = [
    ("layout-attach", "Attach"),
    ("layout-usage", "Usage"),
    ("layout-stop", "Stop"),
    ("layout-send", "Send"),
];

struct Harness {
    hits: Rc<Cell<usize>>,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let mut controls = composer_selection_controls();
        for (selector, label) in CHIPS {
            controls = controls.child(chip(selector, label, self.hits.clone()));
        }
        let mut actions = div()
            .flex()
            .flex_wrap()
            .items_center()
            .justify_end()
            .min_w_0()
            .gap(px(6.));
        for (selector, label) in ACTIONS {
            actions = actions.child(chip(selector, label, self.hits.clone()));
        }
        div().size_full().child(composer_actions(
            controls.into_any_element(),
            actions.into_any_element(),
        ))
    }
}
fn chip(selector: &'static str, label: &'static str, hits: Rc<Cell<usize>>) -> Div {
    div()
        .debug_selector(move || selector.into())
        .flex_shrink_0()
        .child(
            gpui_kit::component::button::Button::new(selector)
                .label(label)
                .h(px(28.))
                .on_click(move |_, _, _| hits.set(hits.get() + 1)),
        )
}
fn draw(window: &mut Window, cx: &mut App) {
    window.refresh();
    window.draw(cx).clear(cx);
}
fn disjoint(a: Bounds<Pixels>, b: Bounds<Pixels>) -> bool {
    a.right() <= b.left() || b.right() <= a.left() || a.bottom() <= b.top() || b.bottom() <= a.top()
}

#[gpui_kit::test]
#[ignore = "launched by private-child wrapper"]
fn headless_composer_controls_fit_and_remain_clickable_at_multiple_widths(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let hits = Rc::new(Cell::new(0));
    let (_view, cx): (Entity<Harness>, &mut VisualTestContext) =
        cx.add_window_view(|_, _| Harness { hits: hits.clone() });
    for width in [900., 600., 420., 300., 220.] {
        cx.simulate_resize(size(px(width), px(700.)));
        cx.update(|window, cx| {
            window.activate_window();
            draw(window, cx);
            draw(window, cx);
        });
        let mut bounds = Vec::new();
        for (selector, _) in CHIPS.into_iter().chain(ACTIONS) {
            let item = cx
                .debug_bounds(selector)
                .unwrap_or_else(|| panic!("missing {selector} at {width}"));
            assert!(
                item.left() >= px(0.) && item.right() <= px(width + 0.5),
                "{selector} escapes the {width}px composer: {item:?}"
            );
            for (other, other_bounds) in &bounds {
                assert!(
                    disjoint(item, *other_bounds),
                    "{selector} overlaps {other} at {width}px"
                );
            }
            bounds.push((selector, item));
        }
        for selector in [
            "layout-model",
            "layout-follow",
            "layout-attach",
            "layout-send",
        ] {
            let position = cx.debug_bounds(selector).unwrap().center();
            let before = hits.get();
            cx.simulate_mouse_move(position, None, Modifiers::default());
            cx.simulate_click(position, Modifiers::default());
            assert_eq!(
                hits.get(),
                before + 1,
                "{selector} must remain clickable at {width}px"
            );
        }
    }
}

#[::core::prelude::v1::test]
fn private_headless_composer_layout_child() {
    let root =
        std::env::temp_dir().join(format!("coincide-composer-layout-{}", uuid::Uuid::new_v4()));
    coincide_core::native_file::private_directory(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        coincide_core::native_file::private_directory(&root.join(child)).unwrap();
    }
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command.args(["--ignored", "chat_layout::composer_actions_ui_tests::headless_composer_controls_fit_and_remain_clickable_at_multiple_widths", "--nocapture", "--test-threads=1"])
        .env_clear().env(CHILD, "1").env("HOME", root.join("home"))
        .env("USERPROFILE", root.join("home")).env("TMPDIR", root.join("tmp"))
        .env("TMP", root.join("tmp")).env("TEMP", root.join("tmp"))
        .env("PATH", root.join("empty-path")).env("LANG", "en_US.UTF-8")
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
        "composer layout child failed at {}\n{stdout}\n{stderr}",
        root.display()
    );
    std::fs::remove_dir_all(root).unwrap();
}
