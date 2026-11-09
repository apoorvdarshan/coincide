//! The shared desktop Settings window. All controls render from the existing
//! Coincide owner, so this window never creates another Engine or service owner.
use super::*;

fn return_focus_to_main(main: AnyWindowHandle, focus: FocusHandle, cx: &mut App) {
    // Leave the closing window's update stack before restoring the main focus
    // tree. A closed main target never redirects focus to another window.
    cx.defer(move |cx| {
        main.update(cx, |_, window, cx| {
            window.activate_window();
            focus.focus(window, cx);
        })
        .ok();
    });
}

#[cfg(test)]
#[path = "settings_window_focus_tests.rs"]
mod focus_tests;

/// The Settings window's frame, kept across launches as Swift's
/// "CoincideSettings" autosave. Rust-owned and local to this computer.
const FRAME_DOCUMENT: &str = "settings-window.json";
const DEFAULT_SIZE: (f32, f32) = (860., 640.);
const MIN_SIZE: (f32, f32) = (760., 500.);

#[derive(Clone, Copy, Debug, PartialEq)]
struct Frame {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
}
impl Frame {
    fn read(value: &Value) -> Option<Self> {
        let number = |key: &str| {
            value[key]
                .as_f64()
                .map(|n| n as f32)
                .filter(|n| n.is_finite())
        };
        Some(Self {
            x: number("x")?,
            y: number("y")?,
            width: number("width")?,
            height: number("height")?,
        })
    }
    fn value(self) -> Value {
        json!({"version":1,"x":self.x,"y":self.y,"width":self.width,"height":self.height})
    }
    fn from_bounds(bounds: Bounds<Pixels>) -> Self {
        Self {
            x: f32::from(bounds.origin.x),
            y: f32::from(bounds.origin.y),
            width: f32::from(bounds.size.width),
            height: f32::from(bounds.size.height),
        }
    }
    /// A saved frame is reused only at a usable size with its title bar on a
    /// connected display; otherwise Settings opens centered again.
    fn restorable(self, displays: &[Bounds<Pixels>]) -> Option<Bounds<Pixels>> {
        if self.width < MIN_SIZE.0 || self.height < MIN_SIZE.1 {
            return None;
        }
        let bounds = Bounds::new(
            point(px(self.x), px(self.y)),
            size(px(self.width), px(self.height)),
        );
        let title = Bounds::new(bounds.origin, size(bounds.size.width, px(28.)));
        displays
            .iter()
            .any(|display| display.intersects(&title))
            .then_some(bounds)
    }
}

fn saved_frame(engine: &SharedEngine) -> Option<Frame> {
    Frame::read(
        &try_state(engine)
            .ok()?
            .store
            .local_document(FRAME_DOCUMENT)
            .ok()??,
    )
}

pub(super) struct SettingsWindow {
    owner: WeakEntity<Coincide>,
    frame: Option<Frame>,
    save_frame: Option<Task<()>>,
    _observation: Subscription,
    _window_observations: Vec<Subscription>,
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
        let window_observations = vec![
            cx.observe_window_activation(window, |this, window, cx| {
                this.sync_microphone_activity(window, cx);
            }),
            cx.observe_window_visibility(window, |this, _, window, cx| {
                this.sync_microphone_activity(window, cx);
            }),
            cx.observe_window_bounds(window, |this, window, cx| {
                this.remember_frame(window, cx);
            }),
        ];
        Self {
            owner: weak,
            frame: None,
            save_frame: None,
            _observation: observation,
            _window_observations: window_observations,
        }
    }

    /// Saves the windowed frame shortly after moving or resizing settles.
    fn remember_frame(&mut self, window: &Window, cx: &mut Context<Self>) {
        let WindowBounds::Windowed(bounds) = window.window_bounds() else {
            return;
        };
        let bounds = Bounds::new(bounds.origin, window_chrome::restorable_window_size(window));
        let frame = Frame::from_bounds(bounds);
        if self.frame == Some(frame) {
            return;
        }
        self.frame = Some(frame);
        let owner = self.owner.clone();
        self.save_frame = Some(cx.spawn(async move |_, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(400))
                .await;
            let _ = owner.update(cx, |owner, _| {
                if let Ok(mut engine) = try_state(&owner.engine) {
                    // A failed save keeps the previous frame; Settings still opens.
                    let _ = engine.store.save_document(FRAME_DOCUMENT, &frame.value());
                }
            });
        }));
    }

    fn sync_microphone_activity(&self, window: &Window, cx: &mut Context<Self>) {
        let active = window.is_window_active() && window.visibility().is_visible();
        self.owner
            .update(cx, |owner, cx| {
                owner.microphone_settings_active = active;
                owner.sync_transcription_binding(cx);
            })
            .ok();
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
                owner.microphone_settings_active =
                    window.is_window_active() && window.visibility().is_visible();
                owner.sync_transcription_binding(cx);
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
        if self.voice.recording_shortcut && self.voice_key_down(event, window, cx) {
            return;
        }
        if self.record_appshot_shortcut(event, window, cx) {
            return;
        }
        if self.record_shortcut_event(event, window, cx) {
            return;
        }
        if !window.is_window_active() {
            return;
        }
        let key = &event.keystroke;
        let command = if cfg!(target_os = "macos") {
            key.modifiers.platform
        } else {
            key.modifiers.control
        };
        if event.is_held {
            // A held key repeats nothing here, nor in a native menu item that
            // shares it (Command-W is Archive Thread in the main window).
            if (command
                && !key.modifiers.alt
                && !key.modifiers.shift
                && matches!(key.key.as_str(), "w" | "f" | ","))
                || self.keyboard_command(key, false, false, false).is_some()
            {
                cx.stop_propagation();
            }
            return;
        }
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
        let return_focus = self.settings_window.is_some()
            && !self.media.shutdown_requested
            && !self.media.close_requested;
        self.settings_navigation.cancel_drag();
        self.archive_settings.close_review();
        self.settings_window = None;
        self.settings_window_pending = false;
        self.microphone_settings_active = false;
        self.settings_open = false;
        self.cancel_settings_shortcut();
        if self.appshots.recording {
            self.appshots.recording = false;
            self.appshots.invalidate();
        }
        self.credential_panel
            .update(cx, |panel, cx| panel.cancel(cx));
        self.sync_transcription_binding(cx);
        if return_focus {
            let focus = if self.chat_visible() {
                self.composer.read(cx).focus_handle(cx)
            } else {
                self.navigation_focus.clone()
            };
            return_focus_to_main(self.main_window, focus, cx);
        }
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
            let displays = cx
                .displays()
                .iter()
                .map(|display| display.bounds())
                .collect::<Vec<_>>();
            let bounds = saved_frame(&entity.read(cx).engine)
                .and_then(|frame| frame.restorable(&displays))
                .unwrap_or_else(|| {
                    Bounds::centered(None, size(px(DEFAULT_SIZE.0), px(DEFAULT_SIZE.1)), cx)
                });
            let opened = gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    window_min_size: Some(size(px(MIN_SIZE.0), px(MIN_SIZE.1))),
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

impl Coincide {
    /// No Core owner is frozen while this native user decision is pending.
    pub(super) fn prompt_instruction_close(
        &mut self,
        quit: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.instruction_quit_prompt_pending {
            return;
        }
        self.instruction_quit_prompt_pending = true;
        window.activate_window();
        let target = self.instructions_panel.read(cx).native_target_label();
        let detail = format!("File: {target}\nYour changes will be lost if you don't save them.");
        let answer = window.prompt(
            PromptLevel::Warning,
            "Save changes to instructions?",
            Some(&detail),
            &["Save", "Don't Save", "Cancel"],
            cx,
        );
        self.instruction_quit_task = Some(cx.spawn_in(window, async move |this, cx| {
            let answer = answer.await.unwrap_or(2);
            this.update_in(cx, |this, window, cx| {
                this.instruction_quit_prompt_pending = false;
                let proceed = match answer {
                    0 => this.instructions_panel.update(cx, |panel, cx| panel.native_save(cx)),
                    1 => { this.instructions_panel.update(cx, |panel, cx| panel.native_discard(window, cx)); true },
                    _ => false,
                };
                if proceed {
                    if quit { this.media.shutdown_requested = true; }
                    else { this.media.close_requested = true; }
                } else {
                    if let Some(guard) = &this.native_quit { guard.cancel_request(); }
                    this.native_quit_observed = false;
                    if answer == 0 {
                        this.open_settings_panel(window, cx);
                        this.settings_section = settings::SettingsSection::Instructions;
                        this.status = "Instructions were not saved. Your edits are retained; review the editor before quitting.".into();
                    }
                }
                cx.notify();
            }).ok();
        }));
    }
}

#[cfg(test)]
mod frame_tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn saved_frames_restore_only_at_usable_sizes_on_a_connected_display() {
        let display = Bounds::new(point(px(0.), px(0.)), size(px(1440.), px(900.)));
        let frame =
            Frame::read(&json!({"version":1,"x":100,"y":80,"width":900,"height":700})).unwrap();
        assert_eq!(Frame::read(&frame.value()), Some(frame));
        assert_eq!(
            frame.restorable(&[display]),
            Some(Bounds::new(
                point(px(100.), px(80.)),
                size(px(900.), px(700.))
            ))
        );
        let detached = Frame { x: 3000., ..frame };
        assert_eq!(detached.restorable(&[display]), None);
        assert_eq!(
            Frame {
                width: 500.,
                ..frame
            }
            .restorable(&[display]),
            None
        );
        assert_eq!(frame.restorable(&[]), None);
        assert!(Frame::read(&json!({"x":"1","y":0,"width":900,"height":700})).is_none());
        assert!(Frame::read(&json!({})).is_none());
    }
}
