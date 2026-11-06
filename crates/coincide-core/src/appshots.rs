//! Provider-independent Appshots policy. Construction and parsing never access
//! input devices, permissions, the screen, or an agent.
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    pub enabled: bool,
    pub custom: bool,
    pub shortcut: Option<String>,
    pub includes_text: bool,
    pub sound: bool,
}
impl Settings {
    pub fn read(settings: &Value) -> Self {
        let raw = &settings["appshots"];
        Self {
            enabled: raw["enabled"].as_bool().unwrap_or(false),
            custom: raw["trigger"] == "shortcut",
            shortcut: raw["shortcut"]["shortcut"]
                .as_str()
                .filter(|s| {
                    valid_shortcut(s)
                        && raw["shortcut"]["keyCode"]
                            .as_u64()
                            .is_some_and(|code| code <= 127)
                })
                .map(str::to_owned),
            includes_text: raw["includesWindowText"].as_bool().unwrap_or(false),
            sound: raw["playsSound"].as_bool().unwrap_or(true),
        }
    }
}
pub fn valid_shortcut(text: &str) -> bool {
    if text.len() > 128 {
        return false;
    }
    let mut modifier = false;
    let mut key = false;
    for part in text.split('+') {
        match part {
            "mod" | "ctrl" => modifier = true,
            "shift" | "alt" => {}
            part if !key && part.len() == 1 && part.bytes().all(|b| b.is_ascii_alphanumeric()) => {
                key = true
            }
            _ => return false,
        }
    }
    modifier && key
}
/// Replace exactly one known property while retaining future fields and the
/// stored shortcut's unknown metadata. Callers must CAS the complete old object.
pub fn patch(current: &Value, field: &str, value: Value) -> Result<Value> {
    ensure!(current.is_object(), "Settings are malformed");
    ensure!(
        matches!(
            field,
            "enabled" | "trigger" | "shortcut" | "includesWindowText" | "playsSound"
        ),
        "Unknown Appshots setting"
    );
    match field {
        "trigger" => ensure!(
            value == "bothCommandKeys" || value == "shortcut",
            "Invalid Appshots trigger"
        ),
        "shortcut" => ensure!(
            value.is_null()
                || (value["shortcut"].as_str().is_some_and(valid_shortcut)
                    && value["keyCode"].as_u64().is_some_and(|code| code <= 127)),
            "Use Command or Control with a letter or number"
        ),
        _ => ensure!(value.is_boolean(), "Invalid Appshots toggle"),
    }
    let mut raw = current
        .get("appshots")
        .cloned()
        .unwrap_or_else(|| json!({}));
    ensure!(
        raw.is_object(),
        "Appshots settings are malformed; original retained"
    );
    if field == "shortcut" && value.is_object() {
        let mut shortcut = raw
            .get("shortcut")
            .filter(|value| value.is_object())
            .cloned()
            .unwrap_or_else(|| json!({}));
        for (key, value) in value.as_object().unwrap() {
            shortcut[key] = value.clone();
        }
        raw[field] = shortcut;
    } else {
        raw[field] = value;
    }
    Ok(json!({"appshots":raw}))
}
#[derive(Clone, Debug, Default)]
pub struct Destination {
    recent: Option<(String, Instant)>,
}
impl Destination {
    pub fn interact(&mut self, thread: Option<String>, now: Instant) {
        if self
            .recent
            .as_ref()
            .is_some_and(|(_, previous)| now < *previous)
        {
            return;
        }
        self.recent = thread.map(|id| (id, now));
    }
    pub fn target(&self, now: Instant) -> Option<&str> {
        self.recent
            .as_ref()
            .filter(|(_, at)| {
                now.checked_duration_since(*at)
                    .is_some_and(|age| age <= Duration::from_secs(60))
            })
            .map(|(id, _)| id.as_str())
    }
}
/// Input adapters report only primary modifier transitions and whether another
/// key intervened. A chord fires once and rearms only after both keys release.
#[derive(Default)]
pub struct BothPrimary {
    armed: bool,
    blocked: bool,
}
impl BothPrimary {
    pub fn update(&mut self, left: bool, right: bool, other: bool) -> bool {
        if !left && !right {
            self.armed = true;
            self.blocked = false;
            return false;
        }
        self.blocked |= other;
        if left && right && self.armed && !self.blocked {
            self.armed = false;
            return true;
        }
        false
    }
}
/// Native Windows/X11 adapters provide bounded RGBA pixels; reuse the core PNG
/// codec rather than temporary screen files or a shell screenshot command.
pub fn encode_rgba(width: u32, height: u32, rgba: Vec<u8>) -> Result<Vec<u8>> {
    use image::{ExtendedColorType, ImageEncoder, codecs::png::PngEncoder};
    ensure!(
        width > 0
            && height > 0
            && width <= 8192
            && height <= 8192
            && u64::from(width) * u64::from(height) <= 16_000_000,
        "Capture dimensions exceed limits"
    );
    ensure!(
        rgba.len() == width as usize * height as usize * 4,
        "Invalid capture pixel length"
    );
    let mut bytes = Vec::new();
    PngEncoder::new(&mut bytes).write_image(&rgba, width, height, ExtendedColorType::Rgba8)?;
    ensure!(
        bytes.len() <= 20 * 1024 * 1024,
        "Captured image exceeds 20 MiB"
    );
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_and_future_fields() {
        let settings = Settings::read(&json!({"appshots":{"enabled":"future","playsSound":false}}));
        assert!(!settings.enabled && !settings.includes_text && !settings.sound);
        assert!(Settings::read(&json!({})).sound);
        assert!(
            Settings::read(&json!({"appshots":{"shortcut":{"keyCode":-1,"shortcut":"mod+s"}}}))
                .shortcut
                .is_none()
        );
        assert!(
            Settings::read(&json!({"appshots":{"shortcut":{"keyCode":1,"shortcut":"mod+s"}}}))
                .shortcut
                .is_some()
        );
        let current = json!({"appshots":{"future":{"keep":1},"trigger":"new-trigger"},"other":3});
        assert_eq!(
            patch(&current, "enabled", json!(true)).unwrap(),
            json!({"appshots":{"future":{"keep":1},"trigger":"new-trigger","enabled":true}})
        );
    }
    #[test]
    fn recording_shortcut_preserves_future_metadata_and_refuses_unusable_key_codes() {
        let current = json!({"appshots":{"shortcut":{"keyCode":0,"shortcut":"mod+a","future":{"keep":[1,2]}},"futureSetting":"keep"},"neighbor":7});
        let before = current.clone();
        let changed = patch(
            &current,
            "shortcut",
            json!({"keyCode":7,"shortcut":"mod+x"}),
        )
        .unwrap();
        assert_eq!(
            changed,
            json!({"appshots":{"shortcut":{"keyCode":7,"shortcut":"mod+x","future":{"keep":[1,2]}},"futureSetting":"keep"}})
        );
        assert_eq!(Settings::read(&changed).shortcut.as_deref(), Some("mod+x"));
        for invalid in [
            json!({"shortcut":"mod+x"}),
            json!({"keyCode":128,"shortcut":"mod+x"}),
            json!({"keyCode":-1,"shortcut":"mod+x"}),
        ] {
            assert!(patch(&current, "shortcut", invalid).is_err());
            assert_eq!(current, before);
        }
        let removed = patch(&current, "shortcut", Value::Null).unwrap();
        assert!(removed["appshots"]["shortcut"].is_null());
        assert_eq!(removed["appshots"]["futureSetting"], "keep");
        assert_eq!(current, before);
    }
    #[test]
    fn exact_recent_window_and_no_clock_reversal() {
        let now = Instant::now();
        let mut d = Destination::default();
        d.interact(Some("one".into()), now);
        assert_eq!(d.target(now + Duration::from_secs(60)), Some("one"));
        assert_eq!(d.target(now + Duration::from_secs(61)), None);
        assert_eq!(d.target(now - Duration::from_secs(1)), None);
        d.interact(Some("older".into()), now - Duration::from_secs(1));
        assert_eq!(d.target(now), Some("one"));
    }
    #[test]
    fn chord_is_once_per_release_and_other_keys_block() {
        let mut d = BothPrimary::default();
        d.update(false, false, false);
        assert!(!d.update(true, false, false));
        assert!(d.update(true, true, false));
        assert!(!d.update(true, true, false));
        d.update(false, false, false);
        d.update(true, false, true);
        assert!(!d.update(true, true, false));
        d.update(false, false, false);
        assert!(d.update(true, true, false));
    }
}
