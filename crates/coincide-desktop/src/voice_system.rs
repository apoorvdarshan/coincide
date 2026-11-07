//! What the system itself does with dictation's key and privacy settings,
//! read only to suggest a change (Swift SystemFnKeyUsage and DictationController).
//! Coincide never changes these settings.
use coincide_core::voice::Settings;

/// A privacy setting that stopped dictation, with its System Settings pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Denial {
    Microphone,
    SpeechRecognition,
}
impl Denial {
    /// Swift DictationController.openMicrophoneSettings and
    /// openSpeechRecognitionSettings.
    pub fn settings_url(self) -> &'static str {
        match self {
            Self::Microphone => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            }
            Self::SpeechRecognition => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            }
        }
    }
}

/// macOS's own use of the 🌐 key (System Settings › Keyboard › "Press 🌐 key
/// to"), which also acts when Fn is the dictation shortcut.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FnKeyUsage {
    DoNothing,
    ChangeInputSource,
    ShowEmoji,
    StartDictation,
    /// Not set or unreadable; macOS then does something by default.
    Unknown,
}
impl FnKeyUsage {
    /// com.apple.HIToolbox's AppleFnUsageType.
    fn from_value(value: Option<i64>) -> Self {
        match value {
            Some(0) => Self::DoNothing,
            Some(1) => Self::ChangeInputSource,
            Some(2) => Self::ShowEmoji,
            Some(3) => Self::StartDictation,
            _ => Self::Unknown,
        }
    }
    fn display_name(self) -> &'static str {
        match self {
            Self::DoNothing => "Do Nothing",
            Self::ChangeInputSource => "Change Input Source",
            Self::ShowEmoji => "Show Emoji & Symbols",
            Self::StartDictation => "Start Dictation",
            Self::Unknown => "",
        }
    }
    /// The current system setting; Unknown off macOS.
    pub fn current() -> Self {
        Self::from_value(read_fn_usage())
    }
}

pub(crate) const KEYBOARD_SETTINGS: &str =
    "x-apple.systempreferences:com.apple.Keyboard-Settings.extension";

/// Swift's Settings › Voice note when Fn is the dictation shortcut and macOS
/// also acts on 🌐; None when there is nothing to change.
pub(crate) fn fn_conflict(voice: &Settings, usage: FnKeyUsage) -> Option<String> {
    if !cfg!(target_os = "macos") || !voice.shortcut_enabled || voice.shortcut != "fn" {
        return None;
    }
    let advice = "To use 🌐 only for Coincide’s dictation, set “Press 🌐 key to” to Do Nothing in Keyboard settings.";
    match usage {
        FnKeyUsage::DoNothing => None,
        FnKeyUsage::Unknown => Some(format!("macOS may also act when you press 🌐. {advice}")),
        usage => Some(format!(
            "macOS is also set to {} when you press 🌐. {advice}",
            usage.display_name()
        )),
    }
}

#[cfg(target_os = "macos")]
fn read_fn_usage() -> Option<i64> {
    use std::ffi::c_void;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            allocator: *const c_void,
            bytes: *const u8,
            length: isize,
            encoding: u32,
            external: u8,
        ) -> *const c_void;
        fn CFPreferencesCopyAppValue(
            key: *const c_void,
            application: *const c_void,
        ) -> *const c_void;
        fn CFGetTypeID(value: *const c_void) -> usize;
        fn CFNumberGetTypeID() -> usize;
        fn CFNumberGetValue(number: *const c_void, kind: isize, value: *mut c_void) -> u8;
        fn CFRelease(value: *const c_void);
    }
    const UTF8: u32 = 0x0800_0100;
    const SINT64: isize = 4;
    let string = |text: &str| unsafe {
        CFStringCreateWithBytes(
            std::ptr::null(),
            text.as_ptr(),
            text.len() as isize,
            UTF8,
            0,
        )
    };
    let key = string("AppleFnUsageType");
    let domain = string("com.apple.HIToolbox");
    let mut result = None;
    if !key.is_null() && !domain.is_null() {
        unsafe {
            let value = CFPreferencesCopyAppValue(key, domain);
            if !value.is_null() {
                let mut number = 0i64;
                if CFGetTypeID(value) == CFNumberGetTypeID()
                    && CFNumberGetValue(value, SINT64, (&mut number as *mut i64).cast()) != 0
                {
                    result = Some(number);
                }
                CFRelease(value);
            }
        }
    }
    for value in [key, domain] {
        if !value.is_null() {
            unsafe { CFRelease(value) };
        }
    }
    result
}
#[cfg(not(target_os = "macos"))]
fn read_fn_usage() -> Option<i64> {
    None
}

/// Swift DictationMenu.subtitle: how menus and the command palette name the
/// dictation shortcut, such as "Hold or tap 🌐 fn"; None when it is off.
/// For Edit › Dictate and its palette entry, which run
/// `Coincide::toggle_composer_dictation`.
#[allow(dead_code)]
pub(crate) fn dictation_subtitle(voice: &Settings) -> Option<String> {
    if !voice.enabled || !voice.shortcut_enabled {
        return None;
    }
    let keys = shortcut_label(&voice.shortcut);
    Some(match voice.mode {
        coincide_core::voice::Mode::Both => format!("Hold or tap {keys}"),
        coincide_core::voice::Mode::Hold => format!("Hold {keys}"),
        coincide_core::voice::Mode::Tap => format!("Tap {keys}"),
    })
}
/// The shortcut as menus show it: "🌐 fn", "⌥Space" on a Mac; "Ctrl+Space"
/// elsewhere.
pub(crate) fn shortcut_label(shortcut: &str) -> String {
    let mac = cfg!(target_os = "macos");
    let lone = |name: &str| match (name, mac) {
        ("fn", true) => Some("🌐 fn"),
        ("fn", false) => Some("Fn"),
        ("control", true) => Some("⌃"),
        ("option", true) => Some("⌥"),
        ("shift", true) => Some("⇧"),
        ("command", true) => Some("⌘"),
        ("control", false) => Some("Ctrl"),
        ("option", false) => Some("Alt"),
        ("shift", false) => Some("Shift"),
        ("command", false) => Some("Super"),
        _ => None,
    };
    if let Some(name) = lone(shortcut) {
        return name.into();
    }
    let mut tokens = shortcut.split('+').collect::<Vec<_>>();
    let key = tokens.pop().unwrap_or_default();
    let key = match key {
        "space" => "Space".to_owned(),
        key if key.chars().count() == 1 => key.to_uppercase(),
        key => {
            let mut chars = key.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect())
                .unwrap_or_default()
        }
    };
    let modifier = |token: &str| match (token, mac) {
        ("ctrl" | "control", true) => "⌃",
        ("alt" | "option", true) => "⌥",
        ("shift", true) => "⇧",
        ("cmd" | "super" | "mod", true) => "⌘",
        ("ctrl" | "control", false) => "Ctrl+",
        ("alt" | "option", false) => "Alt+",
        ("shift", false) => "Shift+",
        ("cmd" | "super" | "mod", false) => "Super+",
        _ => "",
    };
    if mac {
        // macOS orders modifiers ⌃⌥⇧⌘.
        let mut ordered = String::new();
        for symbol in ["⌃", "⌥", "⇧", "⌘"] {
            if tokens.iter().any(|token| modifier(token) == symbol) {
                ordered.push_str(symbol);
            }
        }
        format!("{ordered}{key}")
    } else {
        let mut text = String::new();
        for prefix in ["Ctrl+", "Alt+", "Shift+", "Super+"] {
            if tokens.iter().any(|token| modifier(token) == prefix) {
                text.push_str(prefix);
            }
        }
        format!("{text}{key}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn voice(value: serde_json::Value) -> Settings {
        Settings::decode(&json!({ "voice": value }))
    }

    #[::core::prelude::v1::test]
    fn fn_usage_values_follow_hitoolbox() {
        assert_eq!(FnKeyUsage::from_value(Some(0)), FnKeyUsage::DoNothing);
        assert_eq!(
            FnKeyUsage::from_value(Some(1)),
            FnKeyUsage::ChangeInputSource
        );
        assert_eq!(FnKeyUsage::from_value(Some(2)), FnKeyUsage::ShowEmoji);
        assert_eq!(FnKeyUsage::from_value(Some(3)), FnKeyUsage::StartDictation);
        assert_eq!(FnKeyUsage::from_value(Some(9)), FnKeyUsage::Unknown);
        assert_eq!(FnKeyUsage::from_value(None), FnKeyUsage::Unknown);
    }

    #[::core::prelude::v1::test]
    fn fn_conflict_warns_only_when_fn_is_the_shortcut_and_macos_acts_on_it() {
        let fn_key = voice(json!({"shortcutEnabled": true, "shortcut": "fn"}));
        let conflict = fn_conflict(&fn_key, FnKeyUsage::ShowEmoji);
        let unknown = fn_conflict(&fn_key, FnKeyUsage::Unknown);
        if cfg!(target_os = "macos") {
            assert_eq!(
                conflict.unwrap(),
                "macOS is also set to Show Emoji & Symbols when you press 🌐. To use 🌐 only for Coincide’s dictation, set “Press 🌐 key to” to Do Nothing in Keyboard settings."
            );
            assert!(
                unknown
                    .unwrap()
                    .starts_with("macOS may also act when you press 🌐.")
            );
        } else {
            assert!(conflict.is_none() && unknown.is_none());
        }
        assert!(fn_conflict(&fn_key, FnKeyUsage::DoNothing).is_none());
        let option = voice(json!({"shortcutEnabled": true, "shortcut": "option"}));
        assert!(fn_conflict(&option, FnKeyUsage::StartDictation).is_none());
        let off = voice(json!({"shortcutEnabled": false, "shortcut": "fn"}));
        assert!(fn_conflict(&off, FnKeyUsage::StartDictation).is_none());
    }

    #[::core::prelude::v1::test]
    fn dictate_subtitle_names_the_mode_and_shortcut_or_nothing_when_off() {
        let mac = cfg!(target_os = "macos");
        let both = voice(json!({"shortcutEnabled": true, "shortcut": "fn"}));
        assert_eq!(
            dictation_subtitle(&both).unwrap(),
            if mac {
                "Hold or tap 🌐 fn"
            } else {
                "Hold or tap Fn"
            }
        );
        let tap =
            voice(json!({"shortcutEnabled": true, "shortcut": "alt+space", "shortcutMode": "tap"}));
        assert_eq!(
            dictation_subtitle(&tap).unwrap(),
            if mac { "Tap ⌥Space" } else { "Tap Alt+Space" }
        );
        let hold = voice(
            json!({"shortcutEnabled": true, "shortcut": "cmd+shift+d", "shortcutMode": "hold"}),
        );
        assert_eq!(
            dictation_subtitle(&hold).unwrap(),
            if mac {
                "Hold ⇧⌘D"
            } else {
                "Hold Shift+Super+D"
            }
        );
        assert_eq!(
            dictation_subtitle(&voice(json!({"shortcutEnabled": false}))),
            None
        );
        assert_eq!(
            dictation_subtitle(&voice(json!({"isEnabled": false, "shortcutEnabled": true}))),
            None
        );
    }

    #[::core::prelude::v1::test]
    fn denials_open_their_privacy_panes() {
        assert!(
            Denial::Microphone
                .settings_url()
                .ends_with("Privacy_Microphone")
        );
        assert!(
            Denial::SpeechRecognition
                .settings_url()
                .ends_with("Privacy_SpeechRecognition")
        );
    }
}
