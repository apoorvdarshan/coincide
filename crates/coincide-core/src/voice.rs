//! Swift VoiceSettings and DictationTrigger semantics. Preferences are display
//! intent, never microphone permission, executable trust or credential authority.
use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Engine {
    Apple,
    OpenAi,
    Groq,
    Whisper,
}
impl Engine {
    pub fn id(self) -> &'static str {
        match self {
            Self::Apple => "apple",
            Self::OpenAi => "openAI",
            Self::Groq => "groq",
            Self::Whisper => "whisper",
        }
    }
    pub fn decode(value: &Value) -> Self {
        match value.as_str() {
            Some("openAI") => Self::OpenAi,
            Some("groq") => Self::Groq,
            Some("whisper") => Self::Whisper,
            _ => Self::Apple,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Both,
    Hold,
    Tap,
}
impl Mode {
    pub fn id(self) -> &'static str {
        match self {
            Self::Both => "both",
            Self::Hold => "hold",
            Self::Tap => "tap",
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    pub enabled: bool,
    pub engine: Engine,
    pub language: String,
    pub shortcut_enabled: bool,
    pub shortcut: String,
    pub mode: Mode,
    pub sends_when_stopped: bool,
    pub openai_model: String,
    pub groq_model: String,
}
impl Settings {
    pub fn decode(settings: &Value) -> Self {
        let v = &settings["voice"];
        Self {
            enabled: v["isEnabled"].as_bool().unwrap_or(true),
            engine: Engine::decode(&v["engine"]),
            language: v["language"]
                .as_str()
                .filter(|s| !s.trim().is_empty())
                .unwrap_or("auto")
                .to_owned(),
            shortcut_enabled: v["shortcutEnabled"].as_bool().unwrap_or(false),
            shortcut: v["shortcut"]
                .as_str()
                .filter(|s| usable_shortcut(s))
                .unwrap_or("fn")
                .trim()
                .to_lowercase(),
            mode: match v["shortcutMode"].as_str() {
                Some("hold") => Mode::Hold,
                Some("tap") => Mode::Tap,
                _ => Mode::Both,
            },
            sends_when_stopped: v["sendsWhenStopped"].as_bool().unwrap_or(false),
            openai_model: v["openAIModel"].as_str().unwrap_or("gpt-transcribe").into(),
            groq_model: v["groqModel"]
                .as_str()
                .unwrap_or("whisper-large-v3-turbo")
                .into(),
        }
    }
}
/// Swift accepts a lone modifier or an unambiguous key chord; Escape always
/// belongs to cancellation and ordinary typing keys must never be intercepted.
pub fn usable_shortcut(value: &str) -> bool {
    let value = value.trim().to_lowercase();
    if matches!(
        value.as_str(),
        "fn" | "control" | "option" | "shift" | "command"
    ) {
        return true;
    }
    let mut parts = value.split('+').collect::<Vec<_>>();
    let Some(key) = parts.pop() else { return false };
    if key.is_empty() || matches!(key, "esc" | "escape") {
        return false;
    }
    if parts.iter().any(|p| {
        !matches!(
            *p,
            "cmd" | "mod" | "super" | "ctrl" | "control" | "alt" | "option" | "shift"
        )
    }) {
        return false;
    }
    parts.iter().any(|p| {
        matches!(
            *p,
            "cmd" | "mod" | "super" | "ctrl" | "control" | "alt" | "option"
        )
    }) || key
        .strip_prefix('f')
        .is_some_and(|n| n.parse::<u8>().is_ok_and(|n| (1..=35).contains(&n)))
}
/// Only these native controls can modify the voice object. Unrecognized model,
/// device and future fields survive byte-equivalent Value round trips.
#[derive(Clone, Debug)]
pub enum Edit {
    Enabled(bool),
    Engine(Engine),
    Language(String),
    ShortcutEnabled(bool),
    Shortcut(String),
    Mode(Mode),
    SendsWhenStopped(bool),
    Model(Engine, String),
}
impl Edit {
    pub fn apply(self, document: &mut Value) -> anyhow::Result<()> {
        use anyhow::{Context, ensure};
        let settings = document
            .as_object_mut()
            .context("Settings are not an object")?;
        let voice = settings
            .entry("voice")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .context("Voice settings are not an object")?;
        let (key, value) = match self {
            Self::Model(engine, model) => {
                ensure!(
                    !model.is_empty()
                        && model.len() <= 128
                        && model
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)),
                    "Invalid transcription model"
                );
                (
                    match engine {
                        Engine::OpenAi => "openAIModel",
                        Engine::Groq => "groqModel",
                        _ => anyhow::bail!("This engine has no hosted transcription model"),
                    },
                    json!(model),
                )
            }
            Self::Enabled(v) => ("isEnabled", json!(v)),
            Self::Engine(v) => ("engine", json!(v.id())),
            Self::Language(v) => {
                ensure!(
                    !v.trim().is_empty() && v.len() <= 64 && !v.chars().any(char::is_control),
                    "Invalid dictation language"
                );
                ("language", json!(v))
            }
            Self::ShortcutEnabled(v) => ("shortcutEnabled", json!(v)),
            Self::Shortcut(v) => {
                ensure!(
                    usable_shortcut(&v) && v.len() <= 128 && !v.chars().any(char::is_control),
                    "Invalid dictation shortcut"
                );
                ("shortcut", json!(v))
            }
            Self::Mode(v) => ("shortcutMode", json!(v.id())),
            Self::SendsWhenStopped(v) => ("sendsWhenStopped", json!(v)),
        };
        voice.insert(key.into(), value);
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    None,
    Start,
    Stop,
    Cancel,
    ScheduleHoldCheck,
}
#[derive(Clone, Copy)]
struct Press {
    start: f64,
    interrupted: bool,
    was_recording: bool,
    started: bool,
    handled: bool,
}
pub struct Trigger {
    pub mode: Mode,
    lone: bool,
    recording: bool,
    press: Option<Press>,
    last: f64,
}
impl Trigger {
    pub fn new(mode: Mode, lone: bool) -> Self {
        Self {
            mode,
            lone,
            recording: false,
            press: None,
            last: f64::NEG_INFINITY,
        }
    }
    pub fn is_recording(&self) -> bool {
        self.recording
    }
    pub fn is_pressed(&self) -> bool {
        self.press.is_some()
    }
    fn start(&mut self, time: f64) -> Action {
        self.recording = true;
        self.last = time;
        Action::Start
    }
    fn stop(&mut self, time: f64) -> Action {
        self.recording = false;
        self.last = time;
        Action::Stop
    }
    pub fn down(&mut self, time: f64) -> Action {
        if self.press.is_some() {
            return Action::None;
        }
        let mut p = Press {
            start: time,
            interrupted: false,
            was_recording: self.recording,
            started: false,
            handled: false,
        };
        let action = if time - self.last < 0.12 {
            p.interrupted = true;
            Action::None
        } else if self.recording {
            if self.lone {
                Action::None
            } else {
                p.handled = true;
                self.stop(time)
            }
        } else if self.lone {
            if self.mode == Mode::Tap {
                Action::None
            } else {
                Action::ScheduleHoldCheck
            }
        } else {
            p.started = true;
            p.handled = self.mode == Mode::Tap;
            self.start(time)
        };
        self.press = Some(p);
        action
    }
    pub fn hold_check(&mut self, time: f64) -> Action {
        let Some(mut p) = self.press else {
            return Action::None;
        };
        if !self.lone
            || self.mode == Mode::Tap
            || p.interrupted
            || p.was_recording
            || p.started
            || self.recording
            || time - p.start < 0.299
        {
            return Action::None;
        }
        p.started = true;
        self.press = Some(p);
        self.start(time)
    }
    pub fn up(&mut self, time: f64) -> Action {
        let Some(p) = self.press.take() else {
            return Action::None;
        };
        if p.interrupted || p.handled {
            return Action::None;
        }
        let held = time - p.start;
        if p.started {
            if !self.recording {
                return Action::None;
            }
            return match self.mode {
                Mode::Hold => self.stop(time),
                Mode::Both if self.lone || held >= 0.3 => self.stop(time),
                _ => Action::None,
            };
        }
        if !self.lone {
            return Action::None;
        }
        if p.was_recording {
            return if self.recording {
                self.stop(time)
            } else {
                Action::None
            };
        }
        if (self.mode == Mode::Both && held < 0.3) || (self.mode == Mode::Tap && held <= 1.0) {
            self.start(time)
        } else {
            Action::None
        }
    }
    pub fn other_input(&mut self, time: f64) -> Action {
        let Some(p) = self.press.as_mut() else {
            return Action::None;
        };
        if !self.lone || p.interrupted {
            return Action::None;
        }
        p.interrupted = true;
        if p.started && self.recording {
            self.recording = false;
            self.last = time;
            Action::Cancel
        } else {
            Action::None
        }
    }
    pub fn escape(&mut self) -> Action {
        if !self.recording {
            return Action::None;
        }
        self.recording_ended();
        Action::Cancel
    }
    pub fn recording_started(&mut self) {
        self.recording = true
    }
    pub fn recording_ended(&mut self) {
        self.recording = false;
        if let Some(p) = self.press.as_mut() {
            p.handled = true
        }
    }
    pub fn reset(&mut self) {
        self.press = None
    }
}
#[cfg(test)]
mod tests {
    use super::{Action, Edit, Engine, Mode, Settings, Trigger};
    use serde_json::json;
    #[test]
    fn swift_defaults_and_unknowns_survive_native_control_edits() {
        let mut v = json!({"future":{"opaque":[1,2]},"voice":{"whisperModel":"future-model","inputDeviceUID":"private-device","unknown":{"keep":true}}});
        let s = Settings::decode(&v);
        assert!(s.enabled);
        assert_eq!(s.engine, Engine::Apple);
        assert_eq!(s.language, "auto");
        assert!(!s.shortcut_enabled);
        assert!(!s.sends_when_stopped);
        assert_eq!(s.mode, Mode::Both);
        Edit::Engine(Engine::Whisper).apply(&mut v).unwrap();
        Edit::Enabled(false).apply(&mut v).unwrap();
        assert_eq!(v["future"], json!({"opaque":[1,2]}));
        assert_eq!(v["voice"]["whisperModel"], "future-model");
        assert_eq!(v["voice"]["inputDeviceUID"], "private-device");
        assert_eq!(v["voice"]["unknown"], json!({"keep":true}));
        assert!(!Settings::decode(&v).enabled);
    }
    #[test]
    fn lone_modifier_hold_interruption_cancel_and_tap_boundaries() {
        let mut t = Trigger::new(Mode::Both, true);
        assert_eq!(t.down(0.0), Action::ScheduleHoldCheck);
        assert_eq!(t.hold_check(0.298), Action::None);
        assert_eq!(t.hold_check(0.3), Action::Start);
        assert_eq!(t.down(0.4), Action::None);
        assert_eq!(t.other_input(0.4), Action::Cancel);
        assert_eq!(t.up(0.5), Action::None);
        assert!(!t.is_recording());
        assert_eq!(t.down(1.0), Action::ScheduleHoldCheck);
        assert_eq!(t.up(1.1), Action::Start);
        assert_eq!(t.down(1.3), Action::None);
        assert_eq!(t.up(1.4), Action::Stop);
        let mut tap = Trigger::new(Mode::Tap, true);
        assert_eq!(tap.down(0.0), Action::None);
        assert_eq!(tap.up(1.001), Action::None);
        assert_eq!(tap.down(2.0), Action::None);
        assert_eq!(tap.up(3.0), Action::Start);
    }
    #[test]
    fn key_tap_repeat_debounce_hold_and_external_cancellation() {
        let mut t = Trigger::new(Mode::Both, false);
        assert_eq!(t.down(0.0), Action::Start);
        assert_eq!(t.down(0.05), Action::None);
        assert_eq!(t.up(0.1), Action::None);
        assert_eq!(t.down(0.11), Action::None);
        assert_eq!(t.up(0.2), Action::None);
        assert!(t.is_recording());
        assert_eq!(t.down(0.3), Action::Stop);
        assert_eq!(t.up(0.4), Action::None);
        assert_eq!(t.down(1.0), Action::Start);
        assert_eq!(t.up(1.3), Action::Stop);
        t.recording_started();
        assert_eq!(t.escape(), Action::Cancel);
        t.reset();
        assert!(!t.is_pressed());
        assert!(!t.is_recording());
        let mut hold = Trigger::new(Mode::Hold, false);
        assert_eq!(hold.down(2.0), Action::Start);
        assert_eq!(hold.up(2.01), Action::Stop);
    }
}

#[cfg(test)]
mod persistence_tests {
    use super::{Edit, Engine};
    use crate::store::Store;
    use serde_json::json;
    #[test]
    fn native_voice_edit_preserves_original_unknowns_and_rejects_external_writer() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.sqlite");
        let mut store = Store::open(&path).unwrap();
        let original = json!({"voice":{"whisperModel":"future","inputDeviceUID":"retained","future":{"opaque":1}},"providerSettings":{"unknown":[7,8]},"futureRoot":true});
        store.save_document("settings.json", &original).unwrap();
        let expected = store.document("settings.json").unwrap();
        let saved = store
            .save_native_voice_settings_if_unchanged(
                expected.as_ref(),
                Edit::Engine(Engine::Whisper),
            )
            .unwrap();
        assert_eq!(saved["voice"]["future"], original["voice"]["future"]);
        assert_eq!(saved["voice"]["inputDeviceUID"], "retained");
        assert_eq!(saved["providerSettings"], original["providerSettings"]);
        let mut second = Store::open(&path).unwrap();
        let mut changed = saved.clone();
        changed["futureRoot"] = json!("external writer");
        second.save_document("settings.json", &changed).unwrap();
        assert!(
            store
                .save_native_voice_settings_if_unchanged(Some(&saved), Edit::Enabled(false))
                .is_err()
        );
        assert_eq!(store.document("settings.json").unwrap(), Some(changed));
        let malformed = json!({"voice":["retain malformed future data"]});
        store.save_document("settings.json", &malformed).unwrap();
        assert!(
            store
                .save_native_voice_settings_if_unchanged(Some(&malformed), Edit::Enabled(false))
                .is_err()
        );
        assert_eq!(store.document("settings.json").unwrap(), Some(malformed));
    }
}
