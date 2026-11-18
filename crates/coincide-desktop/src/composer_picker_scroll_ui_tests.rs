use super::picker_scroll_body;
use gpui_kit::{
    App, Context, InteractiveElement, IntoElement, ParentElement, Render, ScrollHandle,
    StatefulInteractiveElement, Styled, Window, div, point, px, size,
};

#[gpui_kit::test]
fn model_picker_wheel_keeps_header_footer_and_chat_in_place(cx: &mut gpui_kit::TestAppContext) {
    use gpui_kit::{ScrollDelta, ScrollEvent};
    struct Harness(ScrollHandle);
    impl Render for Harness {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
                .relative()
                .size_full()
                .child(
                    div()
                        .id("picker-test-chat")
                        .size_full()
                        .overflow_y_scroll()
                        .track_scroll(&self.0)
                        .child(div().h(px(1800.))),
                )
                .child(
                    div()
                        .absolute()
                        .top(px(12.))
                        .left(px(12.))
                        .w(px(300.))
                        .max_h(px(230.))
                        .overflow_hidden()
                        .flex()
                        .flex_col()
                        .occlude()
                        .child(
                            div()
                                .debug_selector(|| "picker-test-tabs".into())
                                .flex_shrink_0()
                                .h(px(34.)),
                        )
                        .child(picker_scroll_body(
                            "picker-test-models",
                            div()
                                .debug_selector(|| "picker-test-rows".into())
                                .h(px(146. * 30.)),
                        ))
                        .child(
                            div()
                                .debug_selector(|| "picker-test-footer".into())
                                .flex_shrink_0()
                                .h(px(38.)),
                        ),
                )
        }
    }

    cx.update(gpui_kit::init);
    let (view, cx) = cx.add_window_view(|_, _| Harness(ScrollHandle::new()));
    cx.simulate_resize(size(px(380.), px(265.)));
    let draw = |window: &mut Window, cx: &mut App| {
        window.refresh();
        window.draw(cx).clear(cx);
    };
    cx.update(draw);
    let tabs = cx.debug_bounds("picker-test-tabs").unwrap();
    let footer = cx.debug_bounds("picker-test-footer").unwrap();
    assert!(footer.bottom() <= px(242.));
    let rows = cx.debug_bounds("picker-test-rows").unwrap();
    let position = point(tabs.center().x, (tabs.bottom() + footer.top()) / 2.);
    let chat_offset = view.read_with(cx, |view, _| view.0.offset());
    cx.simulate_mouse_move(position, None, Default::default());
    for step in [160., 5000., 5000.] {
        cx.simulate_event(ScrollEvent {
            position,
            delta: ScrollDelta::Pixels(point(px(0.), px(-step))),
            ..Default::default()
        });
        cx.update(draw);
        assert_eq!(cx.debug_bounds("picker-test-tabs").unwrap(), tabs);
        assert_eq!(cx.debug_bounds("picker-test-footer").unwrap(), footer);
        assert_eq!(view.read_with(cx, |view, _| view.0.offset()), chat_offset);
    }
    assert!(cx.debug_bounds("picker-test-rows").unwrap().top() < rows.top());
}
