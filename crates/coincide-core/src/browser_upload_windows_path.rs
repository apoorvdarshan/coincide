//! Pure closed local-drive path policy, shared by Windows SDK reader and tests.
use anyhow::{Result, ensure};
pub(super) struct LocalPath {
    pub(super) drive: u8,
    pub(super) components: Vec<String>,
}
impl LocalPath {
    pub(super) fn parse(path: &str) -> Result<Self> {
        ensure!(
            path.len() <= 4096 && !path.chars().any(char::is_control),
            "Windows upload path is invalid"
        );
        let path = path.replace('/', "\\");
        let path = path.strip_prefix("\\\\?\\").unwrap_or(&path);
        let bytes = path.as_bytes();
        ensure!(
            bytes.len() > 3
                && bytes[0].is_ascii_alphabetic()
                && bytes[1] == b':'
                && bytes[2] == b'\\',
            "Windows uploads require an absolute local drive path; UNC and device paths are unavailable"
        );
        let components = path[3..].split('\\').map(str::to_owned).collect::<Vec<_>>();
        ensure!(
            components.len() <= 128,
            "Windows upload path exceeds 128 components"
        );
        for part in &components {
            ensure!(
                !part.is_empty()
                    && part != "."
                    && part != ".."
                    && !part.ends_with([' ', '.'])
                    && !part
                        .chars()
                        .any(|c| matches!(c, ':' | '<' | '>' | '"' | '|' | '?' | '*')),
                "Windows upload paths cannot contain streams, traversal or ambiguous components"
            );
            let stem = part
                .split('.')
                .next()
                .unwrap_or_default()
                .to_ascii_uppercase();
            ensure!(
                !matches!(
                    stem.as_str(),
                    "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
                ) && !(stem.len() == 4
                    && (stem.starts_with("COM") || stem.starts_with("LPT"))
                    && matches!(stem.as_bytes()[3], b'1'..=b'9')),
                "Windows device names are unavailable for uploads"
            );
            ensure!(
                part.encode_utf16().count() <= 255,
                "Windows upload component exceeds 255 UTF-16 units"
            );
        }
        Ok(Self {
            drive: bytes[0].to_ascii_uppercase(),
            components,
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordinary_and_verbatim_local_paths_name_the_same_component_walk() {
        for path in [
            r"c:\Users\fixture\界.txt",
            r"\\?\C:\Users\fixture\界.txt",
            "C:/Users/fixture/界.txt",
        ] {
            let parsed = LocalPath::parse(path).unwrap();
            assert_eq!(parsed.drive, b'C');
            assert_eq!(parsed.components, ["Users", "fixture", "界.txt"]);
        }
    }
    #[test]
    fn network_devices_streams_and_normalization_aliases_cannot_enter_reader() {
        for path in [
            r"\\server\share\file",
            r"\\?\UNC\server\share\file",
            r"\\.\pipe\owned",
            r"\??\C:\owned",
            r"C:relative",
            r"C:\",
            r"C:\owned\..\file",
            r"C:\owned\.\file",
            r"C:\owned\file:stream",
            r"C:\owned\file.",
            r"C:\owned\file ",
            r"C:\owned\\file",
            r"C:\owned\CON.txt",
            r"C:\owned\LPT9",
            r"C:\owned\a?b",
        ] {
            assert!(
                LocalPath::parse(path).is_err(),
                "closed path policy admitted {path}"
            );
        }
    }
}
