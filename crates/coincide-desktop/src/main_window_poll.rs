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

/// A native chooser result belongs to the window that opened it. A later
/// Settings presentation must not inherit that choice. If the original window
/// disappeared, drain only window-free bookkeeping and release the real picker
/// custody; never replay the selected path in another window.
pub(super) fn complete_native_picker<T: 'static>(
    origin: AnyWindowHandle,
    owner: &WeakEntity<T>,
    cx: &mut impl AppContext,
    apply: impl FnOnce(&mut T, &mut Window, &mut Context<T>),
    abandoned: impl FnOnce(&mut T, &mut Context<T>),
) -> Result<()> {
    let mut apply = Some(apply);
    let result = self::update(origin, owner, cx, |owner, window, cx| {
        apply.take().expect("one native picker completion")(owner, window, cx)
    });
    if result.is_err() && apply.is_some() {
        owner.update(cx, abandoned)
    } else {
        result
    }
}

#[cfg(test)]
#[path = "main_window_poll_tests.rs"]
mod tests;
