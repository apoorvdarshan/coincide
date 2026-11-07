//! Foreground-only dictation. No OS monitor or global shortcut registration.
use super::*;
use coincide_core::voice::{Action, Engine, Settings, Trigger};
use std::time::Instant;
pub(super) struct SendIntent {
    target: transcription_settings::ComposerBinding,
    generation: u64,
    send: bool,
    voice: Value,
}
impl SendIntent {
    pub(super) fn producer_matches(
        &self,
        generation: u64,
        binding: &transcription_settings::ComposerBinding,
        voice: &Value,
    ) -> bool {
        self.generation == generation && self.target == *binding && self.voice == *voice
    }
    pub(super) fn accepts(&self, event: &transcription_settings::TextReady, voice: &Value) -> bool {
        self.send
            && !event.text.trim().is_empty()
            && self.generation == event.generation
            && self.target == event.binding
            && self.voice == *voice
    }
}
pub(super) struct State {
    pub recording_shortcut: bool,
    /// What macOS also does on 🌐, as of the last time Voice opened.
    pub fn_usage: Option<&'static str>,
    settings: Option<Settings>,
    machine: Trigger,
    clock: Instant,
    was_active: bool,
    interceptor: Option<Subscription>,
    pub ticket: Option<SendIntent>,
    pub(super) preview: Option<dictation_preview::Preview>,
    pub(super) restored_preview: Option<gpui_base::input::NativeTextRevision>,
    /// macOS's 🌐 key setting, re-read at most every two seconds.
    fn_usage_cache: std::cell::Cell<Option<(Instant, voice_system::FnKeyUsage)>>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            recording_shortcut: false,
            fn_usage: None,
            settings: None,
            machine: Trigger::new(coincide_core::voice::Mode::Both, true),
            clock: Instant::now(),
            was_active: false,
            interceptor: None,
            ticket: None,
            preview: None,
            restored_preview: None,
            fn_usage_cache: Default::default(),
        }
    }
}
impl State {
    pub(super) fn fn_usage(&self) -> voice_system::FnKeyUsage {
        if let Some((read, usage)) = self.fn_usage_cache.get()
            && read.elapsed() < std::time::Duration::from_secs(2)
        {
            return usage;
        }
        let usage = voice_system::FnKeyUsage::current();
        self.fn_usage_cache.set(Some((Instant::now(), usage)));
        usage
    }
    pub(super) fn recording_ended(&mut self) {
        self.machine.recording_ended();
    }
    pub(super) fn close(&mut self) {
        self.interceptor = None;
        self.ticket = None;
        self.machine.recording_ended();
        self.machine.reset();
    }
}
fn lone(shortcut: &str) -> bool {
    matches!(shortcut, "fn" | "control" | "option" | "shift" | "command")
}
fn modifiers(shortcut: &str) -> Option<Modifiers> {
    let mut m = Modifiers::default();
    match shortcut {
        "fn" => m.function = true,
        "control" => m.control = true,
        "option" => m.alt = true,
        "shift" => m.shift = true,
        "command" => m.platform = true,
        _ => return None,
    };
    Some(m)
}
fn matches(shortcut: &str, key: &Keystroke) -> bool {
    let mut tokens = shortcut.split('+').collect::<Vec<_>>();
    let Some(letter) = tokens.pop() else {
        return false;
    };
    let mut m = Modifiers::default();
    for token in tokens {
        match token {
            "cmd" | "super" | "mod" => m.platform = true,
            "ctrl" | "control" => m.control = true,
            "alt" | "option" => m.alt = true,
            "shift" => m.shift = true,
            _ => return false,
        }
    }
    key.key.eq_ignore_ascii_case(letter) && key.modifiers == m
}
impl Coincide {
    pub(super) fn sync_voice_interceptor(&mut self, cx: &mut Context<Self>) {
        let settings = Settings::decode(&self.settings);
        let enabled = settings.enabled
            && settings.shortcut_enabled
            && microphone::compiled_backend_available()
            && !self.media.shutdown_requested
            && !self.media.close_requested;
        if !enabled {
            self.voice.interceptor = None;
            return;
        }
        if self.voice.interceptor.is_some() {
            return;
        }
        let owner = cx.entity().downgrade();
        self.voice.interceptor = Some(cx.intercept_keystrokes(move |event, window, cx| {
            let Some(is_held) = event.is_held else { return };
            let key = KeyDownEvent {
                keystroke: event.keystroke.clone(),
                is_held,
                prefer_character_input: event.input_preference == InputPreference::CharacterInput,
            };
            let _ = owner.update(cx, |owner, cx| {
                if owner.voice_key_down(&key, window, cx) {
                    window.prevent_default();
                }
            });
        }));
    }
    pub(super) fn begin_composer_dictation(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.voice_target_available(window, cx) {
            return;
        }
        if self.voice.preview.is_some() {
            self.cancel_composer_dictation(cx);
        }
        if !self.flush_pending_drafts() {
            self.status = "Save the current draft before dictating; your text was retained.".into();
            cx.notify();
            return;
        }
        if self.composer_files.opened {
            self.close_composer_file_picker(window, cx);
        }
        self.microphone_window_active = true;
        self.microphone_settings_active = false;
        let focus = self.composer.read(cx).focus_handle(cx).clone();
        focus.focus(window, cx);
        let Some(binding) = self.sync_transcription_binding(cx) else {
            return;
        };
        let voice = Settings::decode(&self.settings);
        if !voice.enabled {
            return;
        }
        if !self.microphone_panel.read(cx).configured_for_dictation() {
            self.voice.ticket = None;
            self.voice.machine.recording_ended();
            self.status=if voice_speech::effective_engine(voice.engine)==Engine::Whisper{"Choose the local Whisper executable and model in Settings › Voice before dictating."}else{"Save or explicitly load the separate Voice API key in Settings › Voice before dictating."}.into();
            cx.notify();
            return;
        }
        if self.voice.settings.as_ref() != Some(&voice) {
            self.voice.machine = Trigger::new(voice.mode, lone(&voice.shortcut));
            self.voice.settings = Some(voice.clone());
        }
        let generation = self
            .microphone_panel
            .update(cx, |panel, cx| panel.begin_dictation(cx));
        self.voice.ticket = Some(SendIntent {
            target: binding.clone(),
            generation,
            send: voice.sends_when_stopped,
            voice: self.settings.get("voice").cloned().unwrap_or(Value::Null),
        });
        self.capture_dictation_preview(binding, generation, cx);
        self.voice.machine.recording_started();
    }
    pub(super) fn voice_target_available(&self, window: &Window, cx: &Context<Self>) -> bool {
        if !microphone::compiled_backend_available()
            || window.window_handle().window_id() != self.main_window.window_id()
            || !window.is_window_active()
            || !window.visibility().is_visible()
            || !self.chat_visible()
            || self.command_palette.read(cx).is_open()
            || self.media.shutdown_requested
            || self.media.close_requested
        {
            return false;
        }
        let Some(thread) = &self.selected else {
            return false;
        };
        let Ok(owner) = try_state(&self.engine) else {
            return false;
        };
        !owner.admissions_frozen() && !owner.store.is_imported(&text(thread, "id")).unwrap_or(true)
    }
    fn voice_action(&mut self, action: Action, window: &mut Window, cx: &mut Context<Self>) {
        match action {
            Action::Start => self.begin_composer_dictation(window, cx),
            Action::Stop => self
                .microphone_panel
                .update(cx, |p, cx| p.stop_dictation(cx)),
            Action::Cancel => {
                self.cancel_composer_dictation(cx);
            }
            Action::ScheduleHoldCheck => window.request_animation_frame(),
            Action::None => {}
        }
    }
    pub(super) fn poll_voice_shortcut(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_voice_interceptor(cx);
        let settings = Settings::decode(&self.settings);
        let recorder_active = if self.settings_window.is_some() {
            self.microphone_settings_active
        } else {
            self.microphone_window_active && self.settings_in_main_window()
        };
        if !self.settings_open || !self.transcription_open || !recorder_active {
            self.voice.recording_shortcut = false;
        }
        let available = self.voice_target_available(window, cx) && settings.enabled;
        if self.voice.settings.as_ref() != Some(&settings) || !available {
            if self.voice.ticket.take().is_some() {
                self.microphone_panel.update(cx, |p, cx| p.cancel(cx));
            }
            self.voice.machine = Trigger::new(settings.mode, lone(&settings.shortcut));
            self.voice.settings = Some(settings.clone());
        }
        if available && settings.shortcut_enabled && self.voice.machine.is_pressed() {
            let action = self
                .voice
                .machine
                .hold_check(self.voice.clock.elapsed().as_secs_f64());
            self.voice_action(action, window, cx);
            window.request_animation_frame();
        }
        let panel = self.microphone_panel.read(cx);
        if self
            .voice
            .ticket
            .as_ref()
            .is_some_and(|ticket| panel.intent_generation() != Some(ticket.generation))
        {
            self.voice.ticket = None;
            self.voice.machine.recording_ended();
        }
        let active = panel.dictation_active();
        if self.voice.was_active && !active {
            self.voice.machine.recording_ended();
        }
        self.voice.was_active = active;
        if active {
            window.request_animation_frame();
            cx.notify();
        }
    }
    pub(super) fn voice_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let recorder_window = self.settings_window.map_or_else(
            || {
                self.settings_in_main_window()
                    && window.window_handle().window_id() == self.main_window.window_id()
            },
            |handle| handle.window_id() == window.window_handle().window_id(),
        );
        if self.voice.recording_shortcut
            && self.settings_open
            && self.transcription_open
            && recorder_window
            && window.is_window_active()
        {
            if event.is_held {
                cx.stop_propagation();
                window.prevent_default();
                return true;
            }
            self.voice.recording_shortcut = false;
            if event.keystroke.key == "escape" {
                cx.notify();
                return true;
            }
            let key = &event.keystroke;
            if (key.modifiers.platform || key.modifiers.control) && key.key == "q" {
                return false;
            }
            if !key.modifiers.platform && !key.modifiers.control && !key.modifiers.alt {
                self.status = "Use Command, Control or Option with a key. Escape cancels.".into();
                cx.notify();
                return true;
            }
            let mut value = String::new();
            if key.modifiers.platform {
                value.push_str("mod+")
            }
            if key.modifiers.control {
                value.push_str("ctrl+")
            }
            if key.modifiers.alt {
                value.push_str("alt+")
            }
            if key.modifiers.shift {
                value.push_str("shift+")
            }
            value.push_str(&key.key);
            self.change_voice_setting(coincide_core::voice::Edit::Shortcut(value), window, cx);
            cx.stop_propagation();
            return true;
        }
        let settings = Settings::decode(&self.settings);
        if self.voice_target_available(window, cx)
            && event.keystroke.key == "escape"
            && self.microphone_panel.read(cx).dictation_active()
        {
            self.cancel_composer_dictation(cx);
            cx.stop_propagation();
            return true;
        }
        if event.prefer_character_input
            || !self.voice_target_available(window, cx)
            || !settings.enabled
            || !settings.shortcut_enabled
        {
            return false;
        }
        let action = if event.keystroke.key == "escape" && self.voice.machine.is_recording() {
            self.voice.machine.escape()
        } else if lone(&settings.shortcut) {
            let action = self
                .voice
                .machine
                .other_input(self.voice.clock.elapsed().as_secs_f64());
            self.voice_action(action, window, cx);
            return false;
        } else if matches(&settings.shortcut, &event.keystroke) {
            if event.is_held {
                cx.stop_propagation();
                return true;
            }
            self.voice
                .machine
                .down(self.voice.clock.elapsed().as_secs_f64())
        } else {
            return false;
        };
        self.voice_action(action, window, cx);
        cx.stop_propagation();
        true
    }
    pub(super) fn voice_key_up(
        &mut self,
        event: &KeyUpEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let settings = Settings::decode(&self.settings);
        if !self.voice_target_available(window, cx)
            || !settings.shortcut_enabled
            || lone(&settings.shortcut)
        {
            return;
        }
        if settings
            .shortcut
            .split('+')
            .next_back()
            .is_some_and(|key| event.keystroke.key.eq_ignore_ascii_case(key))
            && self.voice.machine.is_pressed()
        {
            let action = self
                .voice
                .machine
                .up(self.voice.clock.elapsed().as_secs_f64());
            self.voice_action(action, window, cx);
            cx.stop_propagation();
        }
    }
    pub(super) fn voice_modifiers(
        &mut self,
        event: &ModifiersChangedEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let settings = Settings::decode(&self.settings);
        if !self.voice_target_available(window, cx)
            || !settings.enabled
            || !settings.shortcut_enabled
        {
            return;
        }
        let Some(flag) = modifiers(&settings.shortcut) else {
            return;
        };
        let now = self.voice.clock.elapsed().as_secs_f64();
        let action = if event.modifiers == flag && !self.voice.machine.is_pressed() {
            self.voice.machine.down(now)
        } else if self.voice.machine.is_pressed() {
            let held = match settings.shortcut.as_str() {
                "fn" => event.modifiers.function,
                "control" => event.modifiers.control,
                "option" => event.modifiers.alt,
                "shift" => event.modifiers.shift,
                "command" => event.modifiers.platform,
                _ => false,
            };
            if !held {
                self.voice.machine.up(now)
            } else if event.modifiers != flag {
                self.voice.machine.other_input(now)
            } else {
                Action::None
            }
        } else {
            Action::None
        };
        self.voice_action(action, window, cx);
    }
}

#[cfg(test)]
mod tests {
    use super::SendIntent;
    use crate::transcription_settings::{ComposerBinding, TextReady};
    use serde_json::json;
    #[::core::prelude::v1::test]
    fn send_intent_requires_exact_actual_producer_generation_and_voice_target() {
        let voice = json!({"engine":"whisper","sendsWhenStopped":true,"language":"en-US"});
        let binding = ComposerBinding {
            thread_id: "synthetic-thread".into(),
            composer_revision: 4,
            selection: 7..11,
        };
        let intent = SendIntent {
            target: binding.clone(),
            generation: 7,
            send: true,
            voice: voice.clone(),
        };
        let mut event = TextReady {
            _model_lease: None,
            generation: 7,
            binding,
            text: "synthetic transcript".into(),
        };
        assert!(intent.accepts(&event, &voice));
        event.generation = 8;
        assert!(
            !intent.accepts(&event, &voice),
            "later manual capture must never borrow a failed or empty dictation's send opt-in"
        );
        event.generation = 7;
        event.binding.composer_revision += 1;
        assert!(!intent.accepts(&event, &voice));
        event.binding.composer_revision -= 1;
        event.binding.thread_id = "another-thread".into();
        assert!(!intent.accepts(&event, &voice));
        event.binding.thread_id = "synthetic-thread".into();
        assert!(!intent.accepts(
            &event,
            &json!({"engine":"openAI","sendsWhenStopped":true,"language":"en-US"})
        ));
        event.text.clear();
        assert!(!intent.accepts(&event, &voice));
    }
}
