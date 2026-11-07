//! Retained scroll owners expose clipped Settings controls without rebuilding
//! their editor/controller entities or moving keyboard focus.
use gpui_kit::component::scroll::{Scrollbar, ScrollbarMode};
use gpui_kit::{
    AnyElement, InteractiveElement, IntoElement, ParentElement, ScrollHandle, SharedString,
    StatefulInteractiveElement, Styled, div,
};
use std::{cell::RefCell, collections::HashMap};
#[derive(Default)]
pub(super) struct State {
    handles: RefCell<HashMap<&'static str, ScrollHandle>>,
}
impl State {
    pub(super) fn frame<E: StatefulInteractiveElement + Styled + IntoElement>(
        &self,
        key: &'static str,
        viewport: E,
    ) -> AnyElement {
        let handle = self.handles.borrow_mut().entry(key).or_default().clone();
        div()
            .id(SharedString::from(format!("settings-scroll-frame/{key}")))
            .relative()
            .flex()
            .flex_col()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .overflow_hidden()
            .child(viewport.track_scroll(&handle).pr_4())
            .child(Scrollbar::vertical(&handle).mode(ScrollbarMode::Always))
            .into_any_element()
    }
}
