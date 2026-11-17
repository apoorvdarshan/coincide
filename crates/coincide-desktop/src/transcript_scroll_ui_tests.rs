//! Exercise the transcript's anchor against actual headless GPUI list layout.
use super::{ListAlignment, ListOffset, ListState, update_transcript_rows};
use gpui_kit::{
    AppContext, Context, IntoElement, Render, ScrollDelta, ScrollEvent, Styled, TestAppContext,
    Window, div, list, point, px, size,
};
use std::{cell::RefCell, rc::Rc};

struct Probe {
    state: ListState,
    heights: Rc<RefCell<Vec<f32>>>,
}

impl Render for Probe {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let heights = self.heights.clone();
        list(self.state.clone(), move |index, _, _| {
            div()
                .w_full()
                .h(px(heights.borrow()[index]))
                .into_any_element()
        })
        .w_full()
        .h_full()
    }
}

#[gpui_kit::test]
#[ignore = "invoked in an isolated HOME by actual_transcript_scroll_keeps_reader_position"]
fn headless_updates_preserve_the_users_scroll(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let cx = cx.add_empty_window();
    let heights = Rc::new(RefCell::new(vec![100.; 200]));
    let state = ListState::new(200, ListAlignment::Bottom, px(300.));
    let view = cx.update(|_, cx| {
        cx.new(|_| Probe {
            state: state.clone(),
            heights: heights.clone(),
        })
    });
    let draw = |cx: &mut gpui_kit::VisualTestContext| {
        cx.draw(point(px(0.), px(0.)), size(px(400.), px(300.)), |_, _| {
            view.clone().into_any_element()
        });
    };
    draw(cx);
    state.scroll_to(ListOffset {
        item_ix: 80,
        offset_in_item: px(35.),
    });
    draw(cx);
    let original = state.logical_scroll_top();
    assert_eq!(
        original,
        ListOffset {
            item_ix: 80,
            offset_in_item: px(35.)
        }
    );
    // A live row growing while it is under the viewport must not pull the
    // reader to the top of that row or to the end of the conversation.
    heights.borrow_mut()[80] = 180.;
    update_transcript_rows(&state, 200, 80..81, 1);
    draw(cx);
    assert_eq!(state.logical_scroll_top(), original);
    // Inserting earlier messages keeps the same item and offset visible.
    heights.borrow_mut().insert(0, 100.);
    update_transcript_rows(&state, 200, 0..0, 1);
    draw(cx);
    assert_eq!(
        state.logical_scroll_top(),
        ListOffset {
            item_ix: 81,
            ..original
        }
    );
    heights.borrow_mut().push(100.);
    update_transcript_rows(&state, 201, 201..201, 1);
    draw(cx);
    assert_eq!(
        state.logical_scroll_top(),
        ListOffset {
            item_ix: 81,
            ..original
        }
    );
    // The reader can explicitly return to the bottom and keep following.
    state.scroll_to_end();
    draw(cx);
    heights.borrow_mut().push(100.);
    update_transcript_rows(&state, 202, 202..202, 1);
    draw(cx);
    assert_eq!(state.completed_layout_visible_range().unwrap().end, 203);
    // A physical upward scroll restores the reader's control for later updates.
    cx.simulate_event(ScrollEvent {
        position: point(px(200.), px(150.)),
        delta: ScrollDelta::Pixels(point(px(0.), px(150.))),
        ..Default::default()
    });
    draw(cx);
    let after_scroll = state.logical_scroll_top();
    assert!(after_scroll.item_ix < 203);
    heights.borrow_mut().push(100.);
    update_transcript_rows(&state, 203, 203..203, 1);
    draw(cx);
    assert_eq!(state.logical_scroll_top(), after_scroll);
}

#[::core::prelude::v1::test]
fn actual_transcript_scroll_keeps_reader_position() {
    let home = tempfile::tempdir().unwrap();
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--ignored",
            "--exact",
            "transcript_scroll_ui_tests::headless_updates_preserve_the_users_scroll",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .env("HOME", home.path())
        .env("USERPROFILE", home.path())
        .env("TMPDIR", home.path())
        .env("TMP", home.path())
        .env("TEMP", home.path())
        .env("PATH", "")
        .env("LANG", "en_US.UTF-8")
        .current_dir(home.path());
    #[cfg(windows)]
    for key in ["SystemRoot", "WINDIR"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    let output = command.output().unwrap();
    assert!(
        output.status.success() && String::from_utf8_lossy(&output.stdout).contains("1 passed"),
        "Transcript scroll fixture failed\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
