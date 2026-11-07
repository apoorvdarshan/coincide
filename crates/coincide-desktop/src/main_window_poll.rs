//! Main-owner work must use its captured window, rather than the most recently
//! rendered window of an entity that is also referenced by Settings.
use anyhow::Result;
use gpui_kit::{AnyWindowHandle, AppContext, Context, WeakEntity, Window};

pub(super) fn update<T: 'static, R>(
    main: AnyWindowHandle,
    owner: &WeakEntity<T>,
    cx: &mut impl AppContext,
    update: impl FnOnce(&mut T, &mut Window, &mut Context<T>) -> R,
) -> Result<R> {
    main.update(cx, |_, window, cx| {
        owner.update(cx, |owner, cx| update(owner, window, cx))
    })?
}

/// Retained child panels follow their live presentation window. After that
/// window closes they still drain receipts using the original owner window.
/// The Option also prevents repeating an effect if a framework error is ever
/// reported after invoking the callback.
pub(super) fn update_visible_or_owner<T: 'static, R>(
    main: AnyWindowHandle,
    owner: &WeakEntity<T>,
    cx: &mut impl AppContext,
    update: impl FnOnce(&mut T, &mut Window, &mut Context<T>) -> R,
) -> Result<R> {
    let mut update = Some(update);
    let result = owner.update_in(cx, |owner, window, cx| {
        update.take().expect("one child poll callback")(owner, window, cx)
    });
    if result.is_err()
        && let Some(update) = update
    {
        return self::update(main, owner, cx, update);
    }
    result
}

#[cfg(test)]
#[path = "main_window_poll_tests.rs"]
mod tests;
