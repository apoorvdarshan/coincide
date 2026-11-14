//! Apply the user's pointing-hand preference to every Coincide window.
use gpui_kit::{App, ClickableCursorPolicy};
use serde_json::Value;

fn enabled(settings: &Value) -> bool {
    settings["showsPointingHand"].as_bool().unwrap_or(true)
}

pub(super) fn configure(settings: &Value, cx: &mut App) {
    let policy = ClickableCursorPolicy {
        enabled: enabled(settings),
    };
    if cx.try_global::<ClickableCursorPolicy>() != Some(&policy) {
        cx.set_global(policy);
        cx.refresh_windows();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui_kit::{
        AnyWindowHandle, AppContext, Context, CursorStyle, InteractiveElement, IntoElement,
        ParentElement, Render, StatefulInteractiveElement, Styled, TestAppContext, Window, div,
        point, px,
    };
    use serde_json::json;

    #[test]
    fn defaults_to_hand_and_honors_an_explicit_opt_out() {
        assert!(enabled(&json!({})));
        assert!(enabled(&json!({"showsPointingHand": true})));
        assert!(!enabled(&json!({"showsPointingHand": false})));
        assert!(enabled(&json!({"showsPointingHand": null})));
    }

    struct CursorProbe;

    impl Render for CursorProbe {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
                .size_full()
                .flex()
                .child(
                    div()
                        .id("clickable")
                        .size(px(40.))
                        .on_click(|_, _, _| {})
                        .child(div().size_full()),
                )
                .child(
                    div()
                        .id("parent")
                        .size(px(40.))
                        .on_click(|_, _, _| {})
                        .child(
                            gpui_kit::base::Button::new("disabled")
                                .size(px(40.))
                                .disabled(true)
                                .on_click(|_, _, _| {}),
                        ),
                )
                .child(
                    div()
                        .id("input")
                        .size(px(40.))
                        .cursor_text()
                        .on_click(|_, _, _| {}),
                )
                .child(
                    div()
                        .id("resize")
                        .size(px(40.))
                        .cursor(CursorStyle::ResizeLeftRight)
                        .on_click(|_, _, _| {}),
                )
                .child(div().size(px(40.)).cursor_pointer())
                .child(
                    gpui_kit::component::button::Button::new("styled-button")
                        .size(px(40.))
                        .on_click(|_, _, _| {}),
                )
                .child(
                    gpui_kit::component::switch::Switch::new("switch")
                        .size(px(40.))
                        .on_click(|_, _, _| {}),
                )
        }
    }

    #[gpui_kit::test]
    fn clickable_cursor_updates_without_changing_text_and_resize_cursors(cx: &mut TestAppContext) {
        cx.update(gpui_kit::init);
        let window = AnyWindowHandle::from(cx.add_window(|_, _| CursorProbe));
        let draw = |cx: &mut TestAppContext| {
            cx.update_window(window, |_, window, cx| {
                window.refresh();
                window.draw(cx).clear(cx);
            })
            .unwrap();
        };
        let cursor_at = |cx: &mut TestAppContext, x, y| {
            cx.update_window(window, |_, window, cx| {
                window.simulate_mouse_move(point(px(x), px(y)), cx);
                window.cursor_style_for_test(cx)
            })
            .unwrap()
        };
        let cursor = |cx: &mut TestAppContext, x| cursor_at(cx, x, 20.);

        // The framework's existing behavior is unchanged until an app opts in.
        draw(cx);
        assert_eq!(cursor(cx, 20.), CursorStyle::Arrow);
        assert_eq!(cursor(cx, 180.), CursorStyle::PointingHand);

        cx.update(|cx| configure(&json!({}), cx));
        draw(cx);
        assert_eq!(cursor(cx, 20.), CursorStyle::PointingHand);
        assert_eq!(cursor(cx, 60.), CursorStyle::Arrow);
        assert_eq!(cursor(cx, 100.), CursorStyle::IBeam);
        assert_eq!(cursor(cx, 140.), CursorStyle::ResizeLeftRight);
        assert_eq!(cursor(cx, 180.), CursorStyle::PointingHand);
        assert_eq!(cursor(cx, 220.), CursorStyle::PointingHand);
        assert_eq!(cursor_at(cx, 250., 10.), CursorStyle::PointingHand);

        cx.update(|cx| configure(&json!({"showsPointingHand": false}), cx));
        draw(cx);
        assert_eq!(cursor(cx, 20.), CursorStyle::Arrow);
        assert_eq!(cursor(cx, 100.), CursorStyle::IBeam);
        assert_eq!(cursor(cx, 140.), CursorStyle::ResizeLeftRight);
        assert_eq!(cursor(cx, 180.), CursorStyle::Arrow);
        assert_eq!(cursor(cx, 220.), CursorStyle::Arrow);
        assert_eq!(cursor_at(cx, 250., 10.), CursorStyle::Arrow);

        cx.update(|cx| configure(&json!({"showsPointingHand": true}), cx));
        draw(cx);
        assert_eq!(cursor(cx, 20.), CursorStyle::PointingHand);
    }
}
