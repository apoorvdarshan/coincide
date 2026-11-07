//! Native voice preference edits do not confer capture or executable authority.
use super::*;
use coincide_core::voice::{Edit, Engine, Mode, Settings};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
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
        self.voice.recording_shortcut = false;
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
    fn voice_picker(
        &self,
        id: &'static str,
        label: String,
        choices: Vec<(String, bool, Edit)>,
        cx: &Context<Self>,
    ) -> AnyElement {
        let parent = cx.entity().downgrade();
        let expected = self.settings.get("voice").cloned();
        Button::new(id).label(label).dropdown_caret(true).dropdown_menu(move|mut menu,_,_|{
            for (label,checked,edit) in &choices {
                let parent=parent.clone();let expected=expected.clone();let edit=edit.clone();
                menu=menu.item(PopupMenuItem::new(label.clone()).checked(*checked).on_click(move|_,window,cx|{
                    let _=parent.update(cx,|this,cx|{
                        if !this.settings_open||!this.transcription_open||this.settings.get("voice")!=expected.as_ref(){this.status="Voice settings changed; reopen the picker before choosing.".into();cx.notify();return}
                        this.change_voice_setting(edit.clone(),window,cx);
                    });
                }));
            }menu
        }).into_any_element()
    }
    pub(super) fn voice_preferences(&self, cx: &mut Context<Self>) -> AnyElement {
        let voice = Settings::decode(&self.settings);
        let enabled = voice.enabled;
        let send = voice.sends_when_stopped;
        let shortcut = voice.shortcut_enabled;
        let engines = [
            (Engine::Apple, "Apple Speech"),
            (Engine::Whisper, "Local Whisper"),
            (Engine::OpenAi, "OpenAI"),
            (Engine::Groq, "Groq"),
        ];
        let current_engine = engines
            .iter()
            .find(|(engine, _)| *engine == voice.engine)
            .unwrap()
            .1;
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
            .child("Engine")
            .child(
                self.voice_picker(
                    "voice-engine-picker",
                    current_engine.into(),
                    engines
                        .iter()
                        .map(|(engine, label)| {
                            (
                                label.to_string(),
                                *engine == voice.engine,
                                Edit::Engine(*engine),
                            )
                        })
                        .collect(),
                    cx,
                ),
            );
        pane=pane.child(match voice.engine {Engine::Whisper=>"Local Whisper uses the executable and model selected below. Selecting an engine does not open the microphone.",Engine::Apple=>if voice_speech::compiled(){"On-device Apple Speech prepares its language assets and authorization only after explicit Dictate. Audio remains on this device. Interim text appears as a preview; final text is inserted after Stop."}else{"Apple Speech is unavailable on this platform/build. Select Local Whisper for equivalent offline dictation."},Engine::OpenAi|Engine::Groq=>"Recordings are sent to this service under your account and its data policies. Explicitly save or load a Voice key below; provider accounts do not supply Voice credentials."});
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
        if !models.is_empty() {
            let current = if voice.engine == Engine::OpenAi {
                &voice.openai_model
            } else {
                &voice.groq_model
            };
            let label = models
                .iter()
                .find(|(id, _)| *id == current)
                .map(|(_, label)| *label)
                .unwrap_or(current.as_str());
            pane = pane.child("Model").child(
                self.voice_picker(
                    "voice-model-picker",
                    label.into(),
                    models
                        .iter()
                        .map(|(id, label)| {
                            (
                                label.to_string(),
                                *id == current,
                                Edit::Model(voice.engine, id.to_string()),
                            )
                        })
                        .collect(),
                    cx,
                ),
            );
        }
        let microphones = self.microphone_panel.read(cx);
        let refreshing = microphones.device_refreshing();
        let device_status = microphones.device_status().to_owned();
        let devices = microphones.devices().map(|devices| devices.to_vec());
        let label = match voice.input_device_uid.as_deref() {
            None => "System Default".to_owned(),
            Some(uid) => devices
                .as_ref()
                .and_then(|devices| devices.iter().find(|device| device.uid == uid))
                .map(|device| device.name.clone())
                .unwrap_or_else(|| {
                    if devices.is_some() {
                        "Disconnected microphone".into()
                    } else {
                        "Saved microphone (not refreshed)".into()
                    }
                }),
        };
        let mut device_choices = vec![(
            "System Default".into(),
            voice.input_device_uid.is_none(),
            Edit::InputDevice(None),
        )];
        if let Some(devices) = &devices {
            for device in devices {
                device_choices.push((
                    format!(
                        "{}{}",
                        device.name,
                        if device.is_default { " (default)" } else { "" }
                    ),
                    voice.input_device_uid.as_ref() == Some(&device.uid),
                    Edit::InputDevice(Some(device.uid.clone())),
                ));
            }
        }
        pane = pane
            .child("Microphone")
            .child(self.voice_picker("voice-input-picker", label, device_choices, cx))
            .child(
                Button::new("voice-input-refresh")
                    .label(if refreshing {
                        "Refreshing inputs…"
                    } else {
                        "Refresh Input Devices"
                    })
                    .disabled(refreshing || !microphone::compiled_backend_available())
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.microphone_panel
                            .update(cx, |panel, cx| panel.refresh_devices(cx))
                    })),
            )
            .child(device_status);
        if voice.input_device_uid.is_some() && devices.is_none() {
            pane=pane.child("Saved microphone has not been checked. Refresh inputs to view its current availability; unavailable input never falls back.");
        } else if voice.input_device_uid.as_ref().is_some_and(|uid| {
            devices
                .as_ref()
                .is_some_and(|devices| !devices.iter().any(|device| &device.uid == uid))
        }) {
            pane=pane.child("The saved microphone was not found in the last refresh. It is retained; an unavailable input never falls back to another microphone.");
        }
        let languages = [
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
        ];
        let language_label = languages
            .iter()
            .find(|(code, _)| *code == voice.language)
            .map(|(_, label)| *label)
            .unwrap_or(voice.language.as_str());
        pane = pane.child("Language").child(
            self.voice_picker(
                "voice-language-picker",
                language_label.into(),
                languages
                    .iter()
                    .map(|(code, label)| {
                        (
                            label.to_string(),
                            *code == voice.language,
                            Edit::Language(code.to_string()),
                        )
                    })
                    .collect(),
                cx,
            ),
        );
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
            );
        let modes = [
            (Mode::Both, "Hold or tap"),
            (Mode::Hold, "Hold"),
            (Mode::Tap, "Tap"),
        ];
        pane = pane.child("Shortcut behavior").child(
            self.voice_picker(
                "voice-mode-picker",
                modes
                    .iter()
                    .find(|(mode, _)| *mode == voice.mode)
                    .unwrap()
                    .1
                    .into(),
                modes
                    .iter()
                    .map(|(mode, label)| {
                        (label.to_string(), *mode == voice.mode, Edit::Mode(*mode))
                    })
                    .collect(),
                cx,
            ),
        );
        let modifiers = [
            ("fn", "Fn"),
            ("control", "Control"),
            ("option", "Option / Alt"),
            ("shift", "Shift"),
            ("command", "Command / Super"),
        ];
        pane=pane.child(self.voice_picker("voice-modifier-picker",voice.shortcut.clone(),modifiers.iter().map(|(key,label)|(label.to_string(),*key==voice.shortcut,Edit::Shortcut(key.to_string()))).collect(),cx))
            .child(Button::new("voice-shortcut-record").label(if self.voice.recording_shortcut{"Press shortcut…"}else{"Record shortcut"}).on_click(cx.listener(|this,_,_,cx|{this.voice.recording_shortcut=true;cx.notify();})))
            .child("Shortcuts work only in the active composer window. The OS may reserve Fn or system shortcuts; AltGr character input is preserved.");
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
                            || (voice.engine == Engine::Apple && !voice_speech::compiled())
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
                        .on_click(cx.listener(|this, _, _, cx| this.cancel_composer_dictation(cx))),
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
            .when_some(
                self.microphone_panel
                    .read(cx)
                    .partial_preview()
                    .filter(|_| {
                        !self
                            .voice
                            .preview
                            .as_ref()
                            .is_some_and(|preview| preview.inline)
                    }),
                |pane, text| {
                    pane.child(
                        div()
                            .id("dictation-partial-preview")
                            .max_h(px(64.0))
                            .overflow_hidden()
                            .child("Dictation preview · final text is inserted after Stop")
                            .child(text.to_owned()),
                    )
                },
            )
            .when(!active && self.microphone_panel.read(cx).failed(), |pane| {
                pane.child(self.microphone_panel.read(cx).status_text())
            })
            .into_any_element()
    }
}
