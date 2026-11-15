//! Keep the app-owned Remote and notification services alive when its last
//! window closes. The Engine remains owned by the running application.
use super::*;
use coincide_core::platform_host::notifications::DesktopActivity;

pub(super) fn background_activity() -> DesktopActivity {
    DesktopActivity {
        app_active: false,
        visible_thread: None,
        idle_seconds: u64::MAX,
        locked: false,
        display_asleep: false,
    }
}

pub(super) fn install(cx: &mut App) {
    cx.spawn(async move |cx| {
        let mut last_open_attempt = None;
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            if !cx.update(|cx| tick(cx, &mut last_open_attempt)) {
                break;
            }
        }
    })
    .detach();
}

fn tick(cx: &mut App, last_open_attempt: &mut Option<Instant>) -> bool {
    let Some(launch) = cx.try_global::<Launch>().cloned() else {
        return false;
    };
    let window_open = cx
        .try_global::<MainWindow>()
        .is_some_and(|main| cx.windows().contains(&main.0) && main.1.upgrade().is_some());
    if window_open {
        *last_open_attempt = None;
        return true;
    }

    let _ = launch
        .notification_panel
        .read(cx)
        .update_activity(background_activity());
    launch.remote_panel.update(cx, |panel, cx| panel.poll(cx));
    for (thread, generation) in launch.remote_panel.read(cx).pending_seen() {
        if launch.notification_panel.read(cx).clear_remote_seen(thread) {
            launch
                .remote_panel
                .read(cx)
                .acknowledge_seen(thread, generation);
        }
    }
    // The native delegate still owns the application's quit request after the
    // last window disappears. Transfer it to the existing quit driver.
    if launch
        .native_quit
        .as_ref()
        .is_some_and(|guard| guard.take_requested())
    {
        launch
            .quit_requested
            .store(true, std::sync::atomic::Ordering::Release);
    }
    let (shutdown, activate) = match launch.engine.try_lock() {
        Ok(mut engine) => {
            engine.ui_available = false;
            (engine.shutdown, engine.activation_requested)
        }
        Err(_) => return true,
    };
    let quit_requested = launch
        .quit_requested
        .load(std::sync::atomic::Ordering::Acquire);
    if (shutdown || activate || quit_requested)
        && last_open_attempt.is_none_or(|last| last.elapsed() >= Duration::from_secs(2))
    {
        *last_open_attempt = Some(Instant::now());
        if shutdown {
            // Recreate the drain owner without showing a window: API Quit can
            // arrive after the last visible window has already been closed.
            if let Err(error) = open_main_window_with_visibility(cx, false) {
                eprintln!("Unable to resume Coincide shutdown: {error}");
            }
        } else if quit_requested {
            // A user-initiated quit can need a visible work-stopping prompt.
            if let Err(error) = open_main_window_with_visibility(cx, true) {
                eprintln!("Unable to resume Coincide quit: {error}");
            }
        } else {
            reopen_main_window(cx);
        }
    }
    true
}
