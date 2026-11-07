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
    settings: Option<Settings>,
    machine: Trigger,
    clock: Instant,
    was_active: bool,
    pub ticket: Option<SendIntent>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            recording_shortcut: false,
            settings: None,
            machine: Trigger::new(coincide_core::voice::Mode::Both, true),
            clock: Instant::now(),
            was_active: false,
            ticket: None,
        }
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
    pub(super) fn begin_composer_dictation(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.voice_target_available(window, cx) {
            return;
        }
        let focus = self.composer.read(cx).focus_handle(cx).clone();
        focus.focus(window, cx);
        let Some(binding) = self.sync_transcription_binding(cx) else {
            return;
        };
        let voice = Settings::decode(&self.settings);
        if !voice.enabled || voice.engine != Engine::Whisper {
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
            target: binding,
            generation,
            send: voice.sends_when_stopped,
            voice: self.settings.get("voice").cloned().unwrap_or(Value::Null),
        });
        self.voice.machine.recording_started();
    }
    fn voice_target_available(&self, window: &Window, cx: &Context<Self>) -> bool {
        if window.window_handle().window_id() != self.main_window.window_id()
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
                self.voice.ticket = None;
                self.microphone_panel.update(cx, |p, cx| p.cancel(cx));
            }
            Action::ScheduleHoldCheck => window.request_animation_frame(),
            Action::None => {}
        }
    }
    pub(super) fn poll_voice_shortcut(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let settings = Settings::decode(&self.settings);
        if !self.settings_open || !self.transcription_open {
            self.voice.recording_shortcut = false;
        }
        let available = self.voice_target_available(window, cx)
            && settings.enabled
            && settings.engine == Engine::Whisper;
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
        if self.voice.recording_shortcut && self.settings_open && self.transcription_open {
            if event.is_held {
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
        if !self.voice_target_available(window, cx)
            || !settings.enabled
            || !settings.shortcut_enabled
            || settings.engine != Engine::Whisper
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
            || settings.engine != Engine::Whisper
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
