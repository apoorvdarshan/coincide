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

#[cfg(test)]
#[path = "main_window_poll_tests.rs"]
mod tests;
