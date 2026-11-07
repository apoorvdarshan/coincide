use super::*;
use coincide_core::appshots::{self, Settings};
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
        let mut pane=div().id("appshots-settings").flex_1().min_w_0().min_h_0().overflow_y_scroll().p_5().flex().flex_col().gap_4()
            .child(div().text_xl().child("Appshots"))
            .child("Capture the window you’re working in and ask an agent about it.")
            .child(Button::new("appshots-enabled").label(if settings.enabled{"Turn off Appshots"}else{"Turn on Appshots"}).on_click(cx.listener(move|this,_,window,cx|this.change_appshot_setting("enabled",json!(!settings.enabled),window,cx))))
            .child("Capture the frontmost window of the app you’re using and attach it to a chat, ready for your question.")
            .child("Take an appshot with")
            .child(div().flex().gap_2()
                .child(Button::new("appshots-both").label(if cfg!(target_os="macos"){"Both ⌘ keys"}else{"Both primary modifier keys"}).selected(!settings.custom).on_click(cx.listener(|this,_,window,cx|this.change_appshot_setting("trigger",json!("bothCommandKeys"),window,cx))))
                .child(Button::new("appshots-custom").label("Custom shortcut").selected(settings.custom).on_click(cx.listener(|this,_,window,cx|this.change_appshot_setting("trigger",json!("shortcut"),window,cx)))));
        if settings.custom {
            pane = pane
                .child(
                    div().track_focus(&self.appshots.shortcut_focus).child(
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
                .child("Use Command or Control with a key. Delete removes it; Escape cancels.");
        }
        pane=pane.child(Button::new("appshots-text").label(if settings.includes_text{"Include the window’s text: On"}else{"Include the window’s text: Off"}).on_click(cx.listener(move|this,_,window,cx|this.change_appshot_setting("includesWindowText",json!(!settings.includes_text),window,cx))))
            .child("Adds text the app exposes through Accessibility as a card beside the picture. Password fields are excluded.")
            .child(Button::new("appshots-sound").label(if settings.sound{"Play a sound: On"}else{"Play a sound: Off"}).on_click(cx.listener(move|this,_,window,cx|this.change_appshot_setting("playsSound",json!(!settings.sound),window,cx))))
            .child(format!("Status: {}",self.appshots.status))
            .child(div().text_lg().child("Permissions"))
            .child(format!("Screen Recording: {} · Accessibility: {}",if self.appshots.permissions.screen{"Allowed"}else{"Not granted"},if self.appshots.permissions.accessibility{"Allowed"}else{"Not granted"}));
        for (action, label) in [
            (0u8, "Refresh permissions"),
            (1, "Grant Screen Recording access"),
            (2, "Grant Accessibility access"),
        ] {
            if action != 0 && !cfg!(target_os = "macos") {
                continue;
            }
            pane = pane.child(
                Button::new(("appshots-permission", action as usize))
                    .label(label)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.appshots.permissions = appshots_platform::permissions(action);
                        this.appshots.invalidate();
                        this.appshots.sync(&this.settings);
                        cx.notify();
                    })),
            );
        }
        #[cfg(target_os = "macos")]
        for (anchor, label) in [
            ("Privacy_ScreenCapture", "Open Screen Recording settings"),
            ("Privacy_Accessibility", "Open Accessibility settings"),
        ] {
            pane = pane.child(Button::new(anchor).label(label).on_click(cx.listener(
                move |_, _, _, cx| {
                    cx.open_url(&format!(
                        "x-apple.systempreferences:com.apple.preference.security?{anchor}"
                    ))
                },
            )));
        }
        self.settings_scroll.frame("appshots",
        pane.child(self.appshots.permissions.detail.clone())
            .child(div().text_lg().child("Privacy"))
            .child("Appshots never send on their own. The picture waits in the composer. A writable chat used in the last minute receives it; otherwise a new projectless chat is created.")
            .child("Only the frontmost eligible window is captured, never the whole screen. Coincide’s windows, protected windows and detected password entry are skipped. Captures stay with local attachments until you send. OS privacy and text availability differ by platform.")
            .when(self.appshots.private_cleanup_pending(),|pane|pane.child(Button::new("appshots-retry-private-cleanup").label("Retry private capture cleanup").on_click(cx.listener(|this,_,_,cx|{this.appshots.retry_private_cleanup();cx.notify();}))))
            .child(format!("Last appshot: {}",self.appshots.outcome))        )
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
