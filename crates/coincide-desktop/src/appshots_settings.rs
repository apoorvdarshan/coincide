use super::*;
use crate::native_menu::AccessibleMenuExt as _;
use coincide_core::appshots::{self, Settings};
use gpui_kit::component::{menu::PopupMenuItem, switch::Switch};
impl Coincide {
    fn change_appshot_setting(
        &mut self,
        field: &str,
        value: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        let expected = self.settings.get("appshots").cloned();
        let result = (|| -> Result<Value> {
            let mut owner = try_state(&self.engine)?;
            let current = owner
                .store
                .document("settings.json")?
                .unwrap_or_else(|| json!({}));
            anyhow::ensure!(
                current.get("appshots") == expected.as_ref(),
                "Appshots settings changed; reload before editing"
            );
            let patch = appshots::patch(&current, field, value)?;
            let reply = owner.dispatch(json!({"method":"settings.patch","params":{"patch":patch}}));
            if let Some(error) = reply.get("error") {
                anyhow::bail!(
                    "{}",
                    error["message"]
                        .as_str()
                        .unwrap_or("Settings could not be saved")
                );
            }
            Ok(reply["result"].clone())
        })();
        match result {
            Ok(settings) => {
                self.accept_settings(settings, window, cx);
                self.appshots.sync(&self.settings);
            }
            Err(error) => self.appshots.outcome = error.to_string(),
        };
        cx.notify();
    }
    pub(super) fn record_appshot_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.appshots.recording {
            return false;
        }
        if !self.settings_open
            || self.settings_section != settings::SettingsSection::Appshots
            || !self.appshots.shortcut_focus.is_focused(window)
        {
            self.appshots.recording = false;
            self.appshots.invalidate();
            return false;
        }
        if event.is_held {
            cx.stop_propagation();
            return true;
        }
        let key = &event.keystroke;
        let plain = !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
            && !key.modifiers.shift;
        if key.key == "escape" && plain {
            self.appshots.recording = false;
            self.appshots.invalidate();
            cx.notify();
            return true;
        }
        if matches!(key.key.as_str(), "backspace" | "delete") && plain {
            self.appshots.recording = false;
            self.appshots.invalidate();
            self.change_appshot_setting("shortcut", Value::Null, window, cx);
            return true;
        }
        if key.key == "q" && (key.modifiers.platform || key.modifiers.control) {
            self.appshots.recording = false;
            self.appshots.invalidate();
            return false;
        }
        let mut text = String::new();
        if key.modifiers.platform {
            text.push_str("mod+");
        }
        if key.modifiers.control {
            text.push_str("ctrl+");
        }
        if key.modifiers.alt {
            text.push_str("alt+");
        }
        if key.modifiers.shift {
            text.push_str("shift+");
        }
        text.push_str(&key.key.to_lowercase());
        if appshots::valid_shortcut(&text) {
            self.appshots.recording = false;
            self.appshots.invalidate();
            // The native backend maps the recorded key rather than trusting a
            // foreign platform's imported hardware code.
            self.change_appshot_setting(
                "shortcut",
                json!({"keyCode":key_code(&key.key),"shortcut":text}),
                window,
                cx,
            );
        } else {
            self.appshots.outcome =
                "Use Command or Control with a letter or number. Escape cancels; Delete removes."
                    .into();
        }
        cx.stop_propagation();
        cx.notify();
        true
    }
    pub(super) fn appshots_settings_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let settings = Settings::read(&self.settings);
        let owner = cx.entity().downgrade();
        let trigger = Button::new("appshots-trigger")
            .label(if settings.custom {
                "Custom shortcut"
            } else if cfg!(target_os = "macos") {
                "Both ⌘ keys"
            } else {
                "Both primary modifier keys"
            })
            .small()
            .dropdown_caret(true)
            .accessibility_label("Take an appshot with")
            .accessible_menu(move |menu, _, _| {
                let custom = owner.clone();
                let both = owner.clone();
                menu.item(
                    PopupMenuItem::new(if cfg!(target_os = "macos") {
                        "Both ⌘ keys"
                    } else {
                        "Both primary modifier keys"
                    })
                    .checked(!settings.custom)
                    .on_click(move |_, window, cx| {
                        let _ = both.update(cx, |this, cx| {
                            this.change_appshot_setting(
                                "trigger",
                                json!("bothCommandKeys"),
                                window,
                                cx,
                            )
                        });
                    }),
                )
                .item(
                    PopupMenuItem::new("Custom shortcut")
                        .checked(settings.custom)
                        .on_click(move |_, window, cx| {
                            let _ = custom.update(cx, |this, cx| {
                                this.change_appshot_setting(
                                    "trigger",
                                    json!("shortcut"),
                                    window,
                                    cx,
                                )
                            });
                        }),
                )
            });
        let mut capture = div()
            .w_full()
            .flex()
            .flex_col()
            .child(
                self.labeled_row(
                    "Turn on Appshots",
                    Some("Capture the frontmost window and attach it to a chat.".into()),
                    Switch::new("appshots-enabled")
                        .accessibility_label("Turn on Appshots")
                        .color(self.color(0xe4e9f2))
                        .checked(settings.enabled)
                        .on_click(cx.listener(move |this, checked: &bool, window, cx| {
                            this.change_appshot_setting("enabled", json!(*checked), window, cx)
                        })),
                ),
            )
            .child(self.labeled_row("Take an appshot with", None, trigger));
        if settings.custom {
            capture = capture
                .child(
                    div()
                        .px_3()
                        .py_2()
                        .track_focus(&self.appshots.shortcut_focus)
                        .child(
                            Button::new("appshots-record")
                                .label(if self.appshots.recording {
                                    "Press new shortcut…".to_owned()
                                } else {
                                    settings
                                        .shortcut
                                        .clone()
                                        .unwrap_or_else(|| "Record a shortcut".into())
                                })
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.appshots.recording = true;
                                    this.appshots.invalidate();
                                    this.appshots.sync(&this.settings);
                                    this.appshots.shortcut_focus.focus(window, cx);
                                    cx.notify();
                                })),
                        ),
                )
                .child(
                    div()
                        .px_3()
                        .pb_2()
                        .text_xs()
                        .text_color(self.color(0xe4e9f2).opacity(0.65))
                        .child(
                            "Use Command or Control with a key. Delete removes it; Escape cancels.",
                        ),
                );
        }
        capture = capture
            .child(self.labeled_row("Include the window’s text", Some("Adds accessible window text beside the picture; password fields are excluded.".into()), Switch::new("appshots-text").accessibility_label("Include the window’s text").color(self.color(0xe4e9f2)).checked(settings.includes_text).on_click(cx.listener(move|this,checked:&bool,window,cx|this.change_appshot_setting("includesWindowText",json!(*checked),window,cx)))))
            .child(self.labeled_row("Play a sound", None, Switch::new("appshots-sound").accessibility_label("Play a sound").color(self.color(0xe4e9f2)).checked(settings.sound).on_click(cx.listener(move|this,checked:&bool,window,cx|this.change_appshot_setting("playsSound",json!(*checked),window,cx)))));
        let mut permissions = div()
            .p_4()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_3()
                    .child(
                        div()
                            .text_sm()
                            .text_color(self.color(0xe4e9f2).opacity(0.7))
                            .child("Appshots status"),
                    )
                    .child(
                        Button::new(("appshots-permission", 0usize))
                            .label("Refresh")
                            .small()
                            .accessibility_label("Refresh permissions")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.appshots.permissions = appshots_platform::permissions(0);
                                this.appshots.invalidate();
                                this.appshots.sync(&this.settings);
                                cx.notify();
                            })),
                    ),
            )
            .child(div().text_sm().child(self.appshots.status.clone()));
        for (action, title, allowed, label) in [
            (
                1u8,
                "Screen Recording",
                self.appshots.permissions.screen,
                "Grant Screen Recording access",
            ),
            (
                2u8,
                "Accessibility",
                self.appshots.permissions.accessibility,
                "Grant Accessibility access",
            ),
        ] {
            permissions = permissions.child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_3()
                    .child(
                        div().flex_1().min_w_0().child(title).child(
                            div()
                                .text_xs()
                                .text_color(self.color(0xe4e9f2).opacity(0.65))
                                .child(if allowed { "Allowed" } else { "Not granted" }),
                        ),
                    )
                    .when(cfg!(target_os = "macos") && !allowed, |row| {
                        row.child(
                            Button::new(("appshots-permission", action as usize))
                                .label("Grant Access")
                                .small()
                                .accessibility_label(label)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.appshots.permissions =
                                        appshots_platform::permissions(action);
                                    this.appshots.invalidate();
                                    this.appshots.sync(&this.settings);
                                    cx.notify();
                                })),
                        )
                    }),
            );
        }
        #[cfg(target_os = "macos")]
        for (anchor, label) in [
            ("Privacy_ScreenCapture", "Open Screen Recording settings"),
            ("Privacy_Accessibility", "Open Accessibility settings"),
        ] {
            permissions = permissions.child(
                div().flex().justify_start().child(
                    Button::new(anchor)
                        .label(label)
                        .small()
                        .ghost()
                        .on_click(cx.listener(move |_, _, _, cx| {
                            cx.open_url(&format!(
                                "x-apple.systempreferences:com.apple.preference.security?{anchor}"
                            ))
                        })),
                ),
            );
        }
        if !self.appshots.permissions.detail.is_empty() {
            permissions = permissions.child(
                div()
                    .text_sm()
                    .child(self.appshots.permissions.detail.clone()),
            );
        }
        let privacy = div().p_4().flex().flex_col().gap_2()
            .child("Appshots wait in the composer until you send them. A recently used writable chat receives the picture; otherwise Coincide opens a new chat.")
            .child(div().text_sm().text_color(self.color(0xe4e9f2).opacity(0.7)).child("Only the frontmost eligible window is captured. Coincide’s windows, protected windows and detected password entry are skipped. Pictures stay in local attachments until you send them."))
            .when(self.appshots.private_cleanup_pending(), |pane| pane.child(Button::new("appshots-retry-private-cleanup").label("Retry private capture cleanup").on_click(cx.listener(|this,_,_,cx|{this.appshots.retry_private_cleanup();cx.notify();}))))
            .when(!self.appshots.outcome.is_empty(), |pane| pane.child(div().text_sm().child(format!("Last appshot: {}", self.appshots.outcome))));
        let pane = div()
            .id("appshots-settings")
            .flex_1()
            .min_w_0()
            .min_h_0()
            .overflow_y_scroll()
            .p_4()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .text_sm()
                    .text_color(self.color(0xe4e9f2).opacity(0.7))
                    .child("Capture the window you’re working in and ask an agent about it."),
            )
            .child(self.settings_group("Capture", capture))
            .child(self.settings_group("Permissions", permissions))
            .child(self.settings_group("Privacy", privacy));
        div()
            .id("appshots-settings-surface")
            .flex_1()
            .min_h_0()
            .min_w_0()
            .flex()
            .flex_col()
            .child(self.settings_subpage_header("Appshots", "appshots-settings-done", cx))
            .child(self.settings_scroll.frame("appshots", pane))
            .into_any_element()
    }
}
fn key_code(key: &str) -> u8 {
    match key.to_ascii_lowercase().as_str() {
        "a" => 0,
        "s" => 1,
        "d" => 2,
        "f" => 3,
        "h" => 4,
        "g" => 5,
        "z" => 6,
        "x" => 7,
        "c" => 8,
        "v" => 9,
        "b" => 11,
        "q" => 12,
        "w" => 13,
        "e" => 14,
        "r" => 15,
        "y" => 16,
        "t" => 17,
        "1" => 18,
        "2" => 19,
        "3" => 20,
        "4" => 21,
        "6" => 22,
        "5" => 23,
        "9" => 25,
        "7" => 26,
        "8" => 28,
        "0" => 29,
        "o" => 31,
        "u" => 32,
        "i" => 34,
        "p" => 35,
        "l" => 37,
        "j" => 38,
        "k" => 40,
        "n" => 45,
        "m" => 46,
        _ => 127,
    }
}
