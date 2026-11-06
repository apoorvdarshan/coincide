//! The shared desktop Settings window. All controls render from the existing
//! Coincide owner, so this window never creates another Engine or service owner.
use super::*;

pub(super) struct SettingsWindow {
    owner: WeakEntity<Coincide>,
    _observation: Subscription,
}

impl SettingsWindow {
    fn new(owner: Entity<Coincide>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let weak = owner.downgrade();
        let closing = weak.clone();
        window.on_window_should_close(cx, move |_, cx| {
            closing
                .update(cx, |owner, cx| owner.settings_window_closed(cx))
                .ok();
            true
        });
        let observation = cx.observe(&owner, |_, _, cx| cx.notify());
        Self {
            owner: weak,
            _observation: observation,
        }
    }
}

impl Render for SettingsWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.owner
            .update(cx, |owner, cx| {
                if !owner.settings_open
                    || owner.media.shutdown_requested
                    || owner.media.close_requested
                {
                    owner.settings_window_closed(cx);
                    window.remove_window();
                    return div().into_any_element();
                }
                window.set_window_title(owner.settings_section.label());
                owner.sync_keyboard_recording(window, cx);
                div()
                    .id("settings-window")
                    .size_full()
                    .flex()
                    .track_focus(&owner.settings_focus)
                    .capture_key_down(cx.listener(|owner, event, window, cx| {
                        owner.settings_window_shortcut(event, window, cx);
                    }))
                    .bg(owner.color(0x10141c))
                    .text_color(owner.color(0xe4e9f2))
                    .child(owner.settings_surface(cx))
                    .into_any_element()
            })
            .unwrap_or_else(|_| {
                window.remove_window();
                div().into_any_element()
            })
    }
}

impl Coincide {
    pub(super) fn hide_inline_settings(&mut self) {
        if self.settings_window.is_none() && !self.settings_window_pending {
            self.settings_open = false;
        }
    }

    fn settings_window_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.record_shortcut_event(event, window, cx) {
            return;
        }
        if event.is_held || !window.is_window_active() {
            return;
        }
        let key = &event.keystroke;
        let command = if cfg!(target_os = "macos") {
            key.modifiers.platform
        } else {
            key.modifiers.control
        };
        if command && !key.modifiers.alt && !key.modifiers.shift {
            match key.key.as_str() {
                "w" => {
                    self.close_settings_panel(window, cx);
                    cx.stop_propagation();
                    return;
                }
                "f" => {
                    self.settings_search
                        .read(cx)
                        .focus_handle(cx)
                        .focus(window, cx);
                    cx.stop_propagation();
                    return;
                }
                "," => {
                    self.show_settings_window(cx);
                    cx.stop_propagation();
                    return;
                }
                _ => {}
            }
        }
        if let Some(command) = self.keyboard_command(key, false, false, false) {
            let main = self.main_window;
            let owner = cx.entity().downgrade();
            cx.defer(move |cx| {
                main.update(cx, |_, window, cx| {
                    window.activate_window();
                    owner
                        .update(cx, |owner, cx| {
                            owner.run_keyboard_command(command, window, cx);
                            cx.notify();
                        })
                        .ok();
                })
                .ok();
            });
            cx.stop_propagation();
        }
    }

    pub(super) fn settings_in_main_window(&self) -> bool {
        self.settings_open && self.settings_window.is_none() && !self.settings_window_pending
    }

    pub(super) fn close_settings_panel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let separate = self
            .settings_window
            .is_some_and(|handle| handle == window.window_handle());
        self.settings_window_closed(cx);
        if separate {
            window.remove_window();
        } else {
            self.navigation_focus.focus(window, cx);
        }
    }

    pub(super) fn settings_window_closed(&mut self, cx: &mut Context<Self>) {
        self.settings_window = None;
        self.settings_window_pending = false;
        self.settings_open = false;
        self.cancel_settings_shortcut();
        self.credential_panel
            .update(cx, |panel, cx| panel.cancel(cx));
        self.sync_transcription_binding(cx);
        cx.notify();
    }

    pub(super) fn show_settings_window(&mut self, cx: &mut Context<Self>) {
        if self.settings_window_pending {
            return;
        }
        self.settings_window_pending = true;
        let owner = cx.entity().downgrade();
        // Opening a GPUI window draws it immediately. Defer outside the owner's
        // update so Settings can safely render the same state on its first frame.
        cx.defer(move |cx| {
            let Ok((existing, open)) = owner.update(cx, |owner, _| {
                owner.settings_window_pending = false;
                (
                    owner.settings_window,
                    owner.settings_open
                        && !owner.media.shutdown_requested
                        && !owner.media.close_requested,
                )
            }) else {
                return;
            };
            if !open {
                return;
            }
            if let Some(existing) = existing {
                if existing
                    .update(cx, |_, window, _| {
                        window.activate_window();
                        window.refresh();
                    })
                    .is_ok()
                {
                    return;
                }
            }
            let Some(entity) = owner.upgrade() else {
                return;
            };
            let opened = gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                        None,
                        size(px(860.), px(640.)),
                        cx,
                    ))),
                    window_min_size: Some(size(px(640.), px(440.))),
                    ..Default::default()
                },
                cx,
                move |window, cx| cx.new(|cx| SettingsWindow::new(entity, window, cx)),
            );
            match opened {
                Ok((handle, _)) => {
                    owner
                        .update(cx, |owner, cx| {
                            owner.settings_window = Some(handle);
                            cx.notify();
                        })
                        .ok();
                    handle
                        .update(cx, |_, window, cx| {
                            window.activate_window();
                            owner
                                .update(cx, |owner, cx| owner.settings_focus.focus(window, cx))
                                .ok();
                            window.refresh();
                        })
                        .ok();
                }
                Err(error) => {
                    owner
                        .update(cx, |owner, cx| {
                            owner.settings_open = false;
                            owner.status = format!("Could not open Settings: {error}");
                            cx.notify();
                        })
                        .ok();
                }
            }
        });
    }
}
