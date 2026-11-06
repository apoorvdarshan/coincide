//! Shared production capture wiring. Test fixtures render the same callbacks
//! around a real Textarea; ownership and completion stay in the caller.
use super::keys::Key;
use gpui_kit::{Context, Div, InteractiveElement, KeyDownEvent, KeyUpEvent, Modifiers, Window};

pub(super) fn attach<T: 'static>(
    scope: Div,
    cx: &mut Context<T>,
    bound: fn(&mut T, Key, &mut Window, &mut Context<T>),
    raw: fn(&mut T, Key, bool, &mut Window, &mut Context<T>),
    release: fn(&mut T, Key, &mut Context<T>),
) -> Div {
    use gpui_kit::component::input::{Enter, Escape, IndentInline, MoveDown, MoveUp};
    // Bound input actions dispatch before raw key listeners. Capture their
    // public actions before Textarea can emit PressEnter or insert a tab.
    scope
        .capture_action(cx.listener(move |this, action: &Enter, window, cx| {
            if !action.secondary && !action.shift {
                bound(this, Key::Enter, window, cx);
            }
        }))
        .capture_action(
            cx.listener(move |this, _: &MoveUp, window, cx| bound(this, Key::Up, window, cx)),
        )
        .capture_action(
            cx.listener(move |this, _: &MoveDown, window, cx| bound(this, Key::Down, window, cx)),
        )
        .capture_action(
            cx.listener(move |this, _: &IndentInline, window, cx| {
                bound(this, Key::Tab, window, cx)
            }),
        )
        .capture_action(
            cx.listener(move |this, _: &Escape, window, cx| bound(this, Key::Escape, window, cx)),
        )
        .capture_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
            if !event.prefer_character_input
                && let Some(key) = Key::named(&event.keystroke.key)
            {
                raw(this, key, event.keystroke.modifiers.modified(), window, cx);
            }
        }))
        .capture_key_up(cx.listener(move |this, event: &KeyUpEvent, _, cx| {
            if let Some(key) = Key::named(&event.keystroke.key) {
                release(this, key, cx);
            }
        }))
}

pub(super) fn bound_modified(key: Key, modifiers: Modifiers) -> bool {
    // These are already resolved plain Input bindings. macOS reports its
    // hardware Function flag for arrows; the public key parser removes it
    // from arrow keystrokes. Do not mistake that platform flag for Fn+Enter.
    modifiers.control
        || modifiers.alt
        || modifiers.shift
        || modifiers.platform
        || (modifiers.function && !matches!(key, Key::Up | Key::Down))
}
