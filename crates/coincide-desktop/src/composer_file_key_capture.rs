//! Shared production capture wiring. Test fixtures render the same callbacks
//! around a real Textarea; ownership and completion stay in the caller.
use super::keys::Key;
use gpui_kit::{
    App, Context, Div, InteractiveElement, KeyBinding, KeyDownEvent, KeyUpEvent, Window,
};

#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_file_suggestions, no_json, no_register)]
struct FileSuggestionUp;
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_file_suggestions, no_json, no_register)]
struct FileSuggestionDown;
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_file_suggestions, no_json, no_register)]
struct FileSuggestionEnter;
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_file_suggestions, no_json, no_register)]
struct FileSuggestionTab;
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_file_suggestions, no_json, no_register)]
struct FileSuggestionEscape;

/// Register after Kit's Input bindings. Both match at the Input depth; the
/// later exact binding gets first refusal, then a declined action falls through
/// to the existing Input action. No built-in action is unbound or intercepted.
pub(super) fn init(cx: &mut App) {
    const CONTEXT: &str = "CoincideFileSuggestions > Input";
    cx.bind_keys([
        KeyBinding::new("up", FileSuggestionUp, Some(CONTEXT)),
        KeyBinding::new("down", FileSuggestionDown, Some(CONTEXT)),
        KeyBinding::new("enter", FileSuggestionEnter, Some(CONTEXT)),
        KeyBinding::new("tab", FileSuggestionTab, Some(CONTEXT)),
        KeyBinding::new("escape", FileSuggestionEscape, Some(CONTEXT)),
    ]);
}

pub(super) fn attach<T: 'static>(
    scope: Div,
    cx: &mut Context<T>,
    bound: fn(&mut T, Key, &mut Window, &mut Context<T>),
    raw: fn(&mut T, Key, bool, &mut Window, &mut Context<T>),
    release: fn(&mut T, Key, &mut Context<T>),
) -> Div {
    // Keep the context mounted when the pane closes: a held activation key
    // still belongs to the file picker until its physical key-up. Capture
    // callbacks that decline return without stopping GPUI's binding fallback.
    scope
        .key_context("CoincideFileSuggestions")
        .capture_action(
            cx.listener(move |this, _: &FileSuggestionEnter, window, cx| {
                bound(this, Key::Enter, window, cx);
            }),
        )
        .capture_action(cx.listener(move |this, _: &FileSuggestionUp, window, cx| {
            bound(this, Key::Up, window, cx)
        }))
        .capture_action(
            cx.listener(move |this, _: &FileSuggestionDown, window, cx| {
                bound(this, Key::Down, window, cx)
            }),
        )
        .capture_action(cx.listener(move |this, _: &FileSuggestionTab, window, cx| {
            bound(this, Key::Tab, window, cx)
        }))
        .capture_action(
            cx.listener(move |this, _: &FileSuggestionEscape, window, cx| {
                bound(this, Key::Escape, window, cx)
            }),
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
