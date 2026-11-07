//! Swift PreviewKeys syntax with a separate, bounded native page-key policy.
use anyhow::{Result, bail, ensure};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Named {
    Enter,
    Tab,
    Space,
    Backspace,
    Escape,
    Delete,
    Home,
    End,
    PageUp,
    PageDown,
    Left,
    Right,
    Down,
    Up,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyPress {
    pub named: Option<Named>,
    pub physical: u8,
    pub mac_code: u16,
    pub characters: String,
    pub ignoring_modifiers: String,
    pub shift: bool,
    pub control: bool,
    pub meta: bool,
    pub alt: bool,
}
impl KeyPress {
    pub fn parse(text: &str) -> Result<Self> {
        ensure!(
            !text.is_empty() && text.len() <= 64 && !text.chars().any(char::is_control),
            "Invalid browser key"
        );
        let parts: Vec<_> = text.split('+').map(str::trim).collect();
        let mut key = *parts.last().unwrap();
        let mut modifiers = &parts[..parts.len() - 1];
        if key.is_empty() && parts.len() >= 2 && parts[parts.len() - 2].is_empty() {
            key = "+";
            modifiers = &parts[..parts.len() - 2];
        }
        ensure!(
            !key.is_empty() && modifiers.len() <= 4,
            "Invalid browser key chord"
        );
        let mut result = Self {
            named: None,
            physical: 0,
            mac_code: 0,
            characters: String::new(),
            ignoring_modifiers: String::new(),
            shift: false,
            control: false,
            meta: false,
            alt: false,
        };
        for modifier in modifiers {
            match modifier.to_ascii_lowercase().as_str() {
                "meta" | "cmd" | "command" => result.meta = true,
                "control" | "ctrl" => result.control = true,
                "alt" | "option" | "opt" => result.alt = true,
                "shift" => result.shift = true,
                _ => bail!("Invalid browser key modifier"),
            }
        }
        let named = match key.to_ascii_lowercase().as_str() {
            "enter" | "return" => Some((Named::Enter, 36, '\r')),
            "tab" => Some((Named::Tab, 48, '\t')),
            "space" => Some((Named::Space, 49, ' ')),
            "backspace" => Some((Named::Backspace, 51, '\u{7f}')),
            "escape" | "esc" => Some((Named::Escape, 53, '\u{1b}')),
            "delete" => Some((Named::Delete, 117, '\u{f728}')),
            "home" => Some((Named::Home, 115, '\u{f729}')),
            "end" => Some((Named::End, 119, '\u{f72b}')),
            "pageup" => Some((Named::PageUp, 116, '\u{f72c}')),
            "pagedown" => Some((Named::PageDown, 121, '\u{f72d}')),
            "arrowleft" => Some((Named::Left, 123, '\u{f702}')),
            "arrowright" => Some((Named::Right, 124, '\u{f703}')),
            "arrowdown" => Some((Named::Down, 125, '\u{f701}')),
            "arrowup" => Some((Named::Up, 126, '\u{f700}')),
            _ => None,
        };
        if let Some((named, code, character)) = named {
            result.named = Some(named);
            result.mac_code = code;
            result.characters = character.to_string();
            result.ignoring_modifiers = result.characters.clone();
            return Ok(result);
        }
        ensure!(
            key.len() == 1 && key.is_ascii() && !key.as_bytes()[0].is_ascii_whitespace(),
            "Browser key must be named or one printable ASCII character"
        );
        let character = key.as_bytes()[0];
        let shifted = b"!@#$%^&*()_+{}|:\"<>?~";
        let bases = b"1234567890-=[]\\;',./`";
        let (base, implicit_shift) =
            if let Some(index) = shifted.iter().position(|value| *value == character) {
                (bases[index], true)
            } else {
                (
                    character.to_ascii_lowercase(),
                    character.is_ascii_uppercase(),
                )
            };
        let table: &[(u8, u16)] = &[
            (b'a', 0),
            (b's', 1),
            (b'd', 2),
            (b'f', 3),
            (b'h', 4),
            (b'g', 5),
            (b'z', 6),
            (b'x', 7),
            (b'c', 8),
            (b'v', 9),
            (b'b', 11),
            (b'q', 12),
            (b'w', 13),
            (b'e', 14),
            (b'r', 15),
            (b'y', 16),
            (b't', 17),
            (b'1', 18),
            (b'2', 19),
            (b'3', 20),
            (b'4', 21),
            (b'6', 22),
            (b'5', 23),
            (b'=', 24),
            (b'9', 25),
            (b'7', 26),
            (b'-', 27),
            (b'8', 28),
            (b'0', 29),
            (b']', 30),
            (b'o', 31),
            (b'u', 32),
            (b'[', 33),
            (b'i', 34),
            (b'p', 35),
            (b'l', 37),
            (b'j', 38),
            (b'\'', 39),
            (b'k', 40),
            (b';', 41),
            (b'\\', 42),
            (b',', 43),
            (b'/', 44),
            (b'n', 45),
            (b'm', 46),
            (b'.', 47),
            (b'`', 50),
        ];
        result.mac_code = table
            .iter()
            .find(|(key, _)| *key == base)
            .map(|(_, code)| *code)
            .ok_or_else(|| anyhow::anyhow!("Unsupported browser key"))?;
        result.physical = base;
        result.shift |= implicit_shift;
        result.ignoring_modifiers = if shifted.contains(&character) {
            (character as char).to_string()
        } else {
            (base as char).to_string()
        };
        result.characters = if shifted.contains(&character) {
            (character as char).to_string()
        } else if result.shift {
            (base.to_ascii_uppercase() as char).to_string()
        } else {
            (base as char).to_string()
        };
        Ok(result)
    }
    pub fn admit_page_key(&self) -> Result<()> {
        ensure!(
            !(self.alt || self.meta && self.control),
            "This browser chord is outside the page-key policy"
        );
        if self.meta || self.control {
            ensure!(
                matches!(self.physical, b'a' | b'z' | b'y')
                    || matches!(
                        self.named,
                        Some(
                            Named::Enter
                                | Named::Backspace
                                | Named::Delete
                                | Named::Home
                                | Named::End
                                | Named::Left
                                | Named::Right
                        )
                    ),
                "Host, global and clipboard shortcuts are not browser page-key actions"
            );
        }
        Ok(())
    }
    pub fn admitted(text: &str) -> Result<Self> {
        let key = Self::parse(text)?;
        key.admit_page_key()?;
        Ok(key)
    }
    pub fn page_text(&self) -> &str {
        if self.meta || self.control {
            return "";
        }
        match self.named {
            Some(Named::Enter) => "\r",
            Some(
                Named::Tab
                | Named::Backspace
                | Named::Escape
                | Named::Delete
                | Named::Home
                | Named::End
                | Named::PageUp
                | Named::PageDown
                | Named::Left
                | Named::Right
                | Named::Up
                | Named::Down,
            ) => "",
            _ => &self.characters,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn swift_aliases_shifted_punctuation_and_literal_plus_preserve_native_character_contract() {
        assert_eq!(
            KeyPress::parse("Cmd+a").unwrap(),
            KeyPress::parse(" command + a ").unwrap()
        );
        assert_eq!(
            KeyPress::parse("Ctrl+Return").unwrap(),
            KeyPress::parse("Control+Enter").unwrap()
        );
        let plus = KeyPress::parse("Meta++").unwrap();
        assert_eq!((plus.mac_code, plus.physical, plus.shift), (24, b'=', true));
        assert_eq!(plus.characters, "+");
        let upper = KeyPress::parse("A").unwrap();
        assert_eq!(upper.characters, "A");
        assert_eq!(upper.ignoring_modifiers, "a");
        assert!(upper.shift);
        for invalid in [
            "",
            "Ctrl+",
            "F12",
            "é",
            "ab",
            "Super+a",
            "Alt+Ctrl+Shift+Meta+Ctrl+a",
            "Enter\n",
        ] {
            assert!(KeyPress::parse(invalid).is_err(), "{invalid:?}");
        }
    }
    #[test]
    fn native_page_policy_denies_host_clipboard_and_global_chords_without_changing_parser() {
        for denied in [
            "Meta+q",
            "Ctrl+w",
            "Ctrl+l",
            "Meta+v",
            "Ctrl+c",
            "Meta+x",
            "Alt+ArrowLeft",
            "Ctrl+Tab",
            "Control+Meta+a",
            "Ctrl+Escape",
        ] {
            assert!(KeyPress::parse(denied).is_ok());
            assert!(KeyPress::admitted(denied).is_err(), "{denied}");
        }
        for allowed in [
            "Enter",
            "Shift+Tab",
            "Escape",
            "ArrowLeft",
            "Ctrl+Enter",
            "Meta+a",
            "Ctrl+z",
            "Shift+Meta+z",
            "+",
        ] {
            KeyPress::admitted(allowed).unwrap();
        }
        assert_eq!(KeyPress::admitted("Ctrl+a").unwrap().page_text(), "");
    }
}
