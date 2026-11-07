//! Native voice preference edits do not confer capture or executable authority.
use super::*;
use coincide_core::voice::{Edit, Engine, Mode, Settings};
impl Coincide {
    pub(super) fn change_voice_setting(
        &mut self,
        edit: Edit,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        let result = (|| -> Result<Value> {
            let mut owner = try_state(&self.engine)?;
            let current = owner.store.document("settings.json")?;
            anyhow::ensure!(
                current.as_ref().and_then(|v| v.get("voice")) == self.settings.get("voice"),
                "Voice settings changed; reload before editing"
            );
            owner
                .store
                .save_native_voice_settings_if_unchanged(current.as_ref(), edit)
        })();
        match result {
            Ok(settings) => {
                self.microphone_panel
                    .update(cx, |panel, cx| panel.cancel(cx));
                let mut public = self.settings.clone();
                public["voice"] = settings["voice"].clone();
                self.accept_settings(public, window, cx);
                self.sync_voice_interceptor(cx);
            }
            Err(error) => self.status = error.to_string(),
        }
        cx.notify();
    }
    pub(super) fn voice_preferences(&self, cx: &mut Context<Self>) -> AnyElement {
        let voice = Settings::decode(&self.settings);
        let enabled = voice.enabled;
        let send = voice.sends_when_stopped;
        let shortcut = voice.shortcut_enabled;
        let mut pane = div()
            .id("voice-preferences")
            .p_4()
            .flex()
            .flex_col()
            .gap_2()
            .child("Voice")
            .child(
                Button::new("voice-enabled")
                    .label(if enabled {
                        "Dictation: On"
                    } else {
                        "Dictation: Off"
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_voice_setting(Edit::Enabled(!enabled), window, cx)
                    })),
            )
            .child("Engine");
        for (engine, label) in [
            (Engine::Apple, "Apple Speech"),
            (Engine::Whisper, "Local Whisper"),
            (Engine::OpenAi, "OpenAI"),
            (Engine::Groq, "Groq"),
        ] {
            pane = pane.child(
                Button::new(engine.id())
                    .label(format!(
                        "{}{}",
                        if voice.engine == engine { "✓ " } else { "" },
                        label
                    ))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_voice_setting(Edit::Engine(engine), window, cx)
                    })),
            );
        }
        pane=pane.child(match voice.engine {Engine::Whisper=>"Local Whisper uses the executable and model selected below. Selecting an engine does not open the microphone.",Engine::Apple=>"Apple Speech is not connected in this desktop build. Select Local Whisper for offline dictation.",Engine::OpenAi|Engine::Groq=>"Recordings are sent to this service under your account and its data policies. Explicitly save or load a Voice key below; provider accounts do not supply Voice credentials."});
        let models: &[(&str, &str)] = match voice.engine {
            Engine::OpenAi => &[
                ("gpt-transcribe", "GPT Transcribe"),
                ("gpt-4o-transcribe", "GPT-4o Transcribe"),
                ("gpt-4o-mini-transcribe", "GPT-4o mini Transcribe"),
                ("whisper-1", "Whisper"),
            ],
            Engine::Groq => &[
                ("whisper-large-v3-turbo", "Whisper Large v3 Turbo"),
                ("whisper-large-v3", "Whisper Large v3"),
            ],
            _ => &[],
        };
        for &(id, label) in models {
            let engine = voice.engine;
            let selected = if engine == Engine::OpenAi {
                &voice.openai_model
            } else {
                &voice.groq_model
            } == id;
            pane = pane.child(
                Button::new(id)
                    .label(format!("{}{}", if selected { "✓ " } else { "" }, label))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_voice_setting(Edit::Model(engine, id.into()), window, cx)
                    })),
            );
        }
        pane = pane.child(format!("Language: {}", voice.language));
        for (code, label) in [
            ("auto", "Automatic"),
            ("en-US", "English (US)"),
            ("en-GB", "English (UK)"),
            ("en-AU", "English (Australia)"),
            ("en-IN", "English (India)"),
            ("es-ES", "Spanish (Spain)"),
            ("es-MX", "Spanish (Mexico)"),
            ("fr-FR", "French (France)"),
            ("fr-CA", "French (Canada)"),
            ("de-DE", "German"),
            ("it-IT", "Italian"),
            ("pt-BR", "Portuguese (Brazil)"),
            ("pt-PT", "Portuguese (Portugal)"),
            ("nl-NL", "Dutch"),
            ("sv-SE", "Swedish"),
            ("da-DK", "Danish"),
            ("nb-NO", "Norwegian"),
            ("fi-FI", "Finnish"),
            ("pl-PL", "Polish"),
            ("cs-CZ", "Czech"),
            ("ru-RU", "Russian"),
            ("uk-UA", "Ukrainian"),
            ("tr-TR", "Turkish"),
            ("el-GR", "Greek"),
            ("ar-SA", "Arabic"),
            ("he-IL", "Hebrew"),
            ("hi-IN", "Hindi"),
            ("th-TH", "Thai"),
            ("vi-VN", "Vietnamese"),
            ("id-ID", "Indonesian"),
            ("ms-MY", "Malay"),
            ("ja-JP", "Japanese"),
            ("ko-KR", "Korean"),
            ("zh-CN", "Chinese (Simplified)"),
            ("zh-TW", "Chinese (Taiwan)"),
            ("zh-HK", "Chinese (Hong Kong)"),
        ] {
            pane = pane.child(Button::new(code).label(label).on_click(cx.listener(
                move |this, _, window, cx| {
                    this.change_voice_setting(Edit::Language(code.into()), window, cx)
                },
            )));
        }
        pane = pane
            .child(
                Button::new("voice-send-on-stop")
                    .label(if send {
                        "Send when stopped: On"
                    } else {
                        "Send when stopped: Off"
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_voice_setting(Edit::SendsWhenStopped(!send), window, cx)
                    })),
            )
            .child(
                Button::new("voice-shortcut-enabled")
                    .label(if shortcut {
                        "Shortcut: On"
                    } else {
                        "Shortcut: Off"
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_voice_setting(Edit::ShortcutEnabled(!shortcut), window, cx)
                    })),
            )
            .child(format!(
                "Shortcut: {} (foreground window only)",
                voice.shortcut
            ));
        for (mode, label) in [
            (Mode::Both, "Hold or tap"),
            (Mode::Hold, "Hold"),
            (Mode::Tap, "Tap"),
        ] {
            pane = pane.child(
                Button::new(mode.id())
                    .label(format!(
                        "{}{}",
                        if mode == voice.mode { "✓ " } else { "" },
                        label
                    ))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_voice_setting(Edit::Mode(mode), window, cx)
                    })),
            );
        }
        pane = pane
            .child(
                Button::new("voice-shortcut-record")
                    .label(if self.voice.recording_shortcut {
                        "Press shortcut…"
                    } else {
                        "Record shortcut"
                    })
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.voice.recording_shortcut = true;
                        cx.notify();
                    })),
            )
            .child(
                Button::new("voice-shortcut-fn")
                    .label("Use Fn modifier")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.change_voice_setting(Edit::Shortcut("fn".into()), window, cx)
                    })),
            );
        for (shortcut, label) in [
            ("control", "Use Control modifier"),
            ("option", "Use Option / Alt modifier"),
            ("shift", "Use Shift modifier"),
            ("command", "Use Command / Super modifier"),
        ] {
            pane = pane.child(Button::new(shortcut).label(label).on_click(cx.listener(
                move |this, _, window, cx| {
                    this.change_voice_setting(Edit::Shortcut(shortcut.into()), window, cx)
                },
            )));
        }
        pane=pane.child("Shortcuts work only in the active composer window. The OS may reserve Fn or system shortcuts; AltGr character input is preserved.");
        pane.into_any_element()
    }
    pub(super) fn block_voice_close(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.voice_credentials.read(cx).blocks_close(cx) {
            return false;
        }
        if let Some(guard) = &self.native_quit {
            guard.cancel_request();
        }
        self.native_quit_observed = false;
        self.open_settings_panel(window, cx);
        self.navigate_settings_section(settings::SettingsSection::Voice, window, cx);
        self.settings_status =
            "Save or discard the typed Voice key, and wait for its owned operation before closing."
                .into();
        cx.notify();
        true
    }
    pub(super) fn composer_voice_control(&self, cx: &mut Context<Self>) -> AnyElement {
        let voice = Settings::decode(&self.settings);
        let active = self.microphone_panel.read(cx).dictation_active();
        div()
            .flex()
            .gap_2()
            .child(
                Button::new("composer-dictation")
                    .label(if active {
                        "Stop dictation"
                    } else {
                        "Microphone"
                    })
                    .disabled(
                        !voice.enabled
                            || voice.engine == Engine::Apple
                            || !microphone::compiled_backend_available(),
                    )
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.microphone_window_active =
                            window.is_window_active() && window.visibility().is_visible();
                        this.sync_transcription_binding(cx);
                        if this.microphone_panel.read(cx).dictation_active() {
                            this.microphone_panel
                                .update(cx, |panel, cx| panel.stop_dictation(cx));
                        } else {
                            this.begin_composer_dictation(window, cx);
                        }
                    })),
            )
            .when(active, |pane| {
                pane.child(
                    Button::new("composer-dictation-cancel")
                        .label("Cancel dictation")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.voice.ticket = None;
                            this.microphone_panel
                                .update(cx, |panel, cx| panel.cancel(cx))
                        })),
                )
                .child(self.microphone_panel.read(cx).status_text())
                .when_some(
                    self.microphone_panel.read(cx).level(),
                    |pane, level| {
                        pane.child(
                            div()
                                .id("dictation-native-level")
                                .w(px(64.))
                                .h(px(8.))
                                .bg(rgb(0x303946))
                                .child(div().w(px(level * 64.)).h_full().bg(rgb(0x5caf7d))),
                        )
                    },
                )
            })
            .into_any_element()
    }
}
