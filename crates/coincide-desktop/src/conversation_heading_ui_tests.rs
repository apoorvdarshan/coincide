//! Check the real header layout with and without a subtitle and at narrow widths.
use super::*;
use ::core::prelude::v1::test;
use gpui_kit::{TestAppContext, VisualTestContext};

const CHILD: &str = "COINCIDE_HEADLESS_HEADING_LAYOUT_CHILD";

struct Harness {
    subtitle: bool,
    mark_size: f32,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(heading_content(
            "A conversation title".into(),
            self.subtitle.then(|| "Project · branch".into()),
            Some(div().size(px(self.mark_size)).into_any_element()),
            rgb(0x888888),
        ))
    }
}

#[gpui_kit::test]
#[ignore = "launched by private-child wrapper"]
fn headless_heading_centers_mark_on_title_block(cx: &mut TestAppContext) {
    assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
    cx.update(gpui_kit::init);
    let (view, cx): (Entity<Harness>, &mut VisualTestContext) =
        cx.add_window_view(|_, _| Harness {
            subtitle: false,
            mark_size: 28.,
        });
    for width in [360., 180.] {
        cx.simulate_resize(size(px(width), px(120.)));
        for mark_size in [18., 28.] {
            for subtitle in [false, true] {
                view.update(cx, |this, cx| {
                    this.subtitle = subtitle;
                    this.mark_size = mark_size;
                    cx.notify();
                });
                cx.update(|window, cx| {
                    window.refresh();
                    window.draw(cx).clear(cx);
                });
                let mark = cx.debug_bounds("conversation-heading-mark").unwrap();
                let text = cx.debug_bounds("conversation-heading-text").unwrap();
                assert!(
                    (f32::from(mark.center().y) - f32::from(text.center().y)).abs() <= 0.5,
                    "mark and text must share a center at width={width}, subtitle={subtitle}: {mark:?}, {text:?}"
                );
                assert!(mark.right() <= text.left() && text.right() <= px(width + 0.5));
            }
        }
    }
}

#[::core::prelude::v1::test]
fn private_headless_conversation_heading_layout_child() {
    let root = std::env::temp_dir().join(format!("coincide-heading-{}", uuid::Uuid::new_v4()));
    coincide_core::native_file::private_directory(&root).unwrap();
    for child in ["home", "tmp", "empty-path"] {
        coincide_core::native_file::private_directory(&root.join(child)).unwrap();
    }
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--ignored",
            "conversation_toolbar::heading_ui_tests::headless_heading_centers_mark_on_title_block",
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
        "heading layout child failed at {}\n{stdout}\n{stderr}",
        root.display()
    );
    std::fs::remove_dir_all(root).unwrap();
}
