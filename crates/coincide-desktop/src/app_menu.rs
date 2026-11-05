//! Global Quit requests enter the retained shutdown driver, never direct exit.
use gpui_kit::{App, KeyBinding, Menu, MenuItem, actions};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

actions!(coincide_app_menu, [Quit]);

/// Coalesced admission signal only. The owner consumes it in its ordinary tick.
/// Neither menu dispatch nor keyboard dispatch closes a Store, waits, or quits.
pub fn install(cx: &mut App) -> Arc<AtomicBool> {
    let requested = Arc::new(AtomicBool::new(false));
    let signal = requested.clone();
    cx.on_action(move |_: &Quit, _| {
        signal.store(true, Ordering::Release);
    });
    #[cfg(target_os = "macos")]
    cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
    #[cfg(not(target_os = "macos"))]
    cx.bind_keys([KeyBinding::new("ctrl-q", Quit, None)]);
    cx.set_menus(
        [Menu::new("Coincide Rust").items([MenuItem::action("Quit Coincide Rust", Quit)])],
    );
    requested
}
