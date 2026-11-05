//! Filesystem arguments for external Git. Rust retains canonical Windows
//! verbatim paths internally; Git for Windows expects drive/UNC syntax instead.
use anyhow::Result;
use std::{ffi::OsString, path::Path};

pub(crate) fn external_git_path(path: &Path) -> Result<OsString> {
    #[cfg(windows)]
    {
        use anyhow::Context;
        let absolute = if path.is_absolute() {
            std::borrow::Cow::Borrowed(path)
        } else {
            std::borrow::Cow::Owned(path.canonicalize().context("Resolving relative Git path")?)
        };
        Ok(windows_git_path(absolute.to_str().context("Git path is not valid UTF-8")?)?.into())
    }
    #[cfg(not(windows))]
    {
        Ok(path.as_os_str().to_owned())
    }
}

#[cfg(any(windows, test))]
fn windows_git_path(path: &str) -> Result<String> {
    use anyhow::ensure;
    ensure!(
        path.encode_utf16().count() < 32767 && !path.chars().any(char::is_control),
        "Git path exceeds Windows limits or contains control characters"
    );
    let path = path.replace('\\', "/");
    let path = if path
        .get(..8)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("//?/UNC/"))
    {
        format!("//{}", &path[8..])
    } else if let Some(drive) = path.strip_prefix("//?/") {
        ensure!(
            is_drive_absolute(drive),
            "Git does not support this Windows verbatim namespace"
        );
        drive.to_owned()
    } else {
        path
    };
    let (tail, minimum_components) = if is_drive_absolute(&path) {
        (&path[3..], 0)
    } else if let Some(unc) = path.strip_prefix("//") {
        (unc, 2)
    } else {
        anyhow::bail!("Git requires an absolute Windows drive or UNC path");
    };
    let tail = tail.strip_suffix('/').unwrap_or(tail);
    let components: Vec<_> = if tail.is_empty() {
        vec![]
    } else {
        tail.split('/').collect()
    };
    ensure!(
        components.len() >= minimum_components,
        "UNC Git path requires server and share names"
    );
    for part in components {
        // Removing the verbatim prefix must never change which file is meant:
        // ordinary Win32 paths normalize trailing dots/spaces and device names.
        ensure!(
            !part.is_empty()
                && part != "."
                && part != ".."
                && !part.ends_with(['.', ' '])
                && !part.contains(['<', '>', ':', '"', '|', '?', '*'])
                && part.encode_utf16().count() <= 255,
            "Git cannot preserve this Windows path component without verbatim semantics"
        );
        let base = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        ensure!(
            !matches!(
                base.as_str(),
                "CON"
                    | "PRN"
                    | "AUX"
                    | "NUL"
                    | "CONIN$"
                    | "CONOUT$"
                    | "COM1"
                    | "COM2"
                    | "COM3"
                    | "COM4"
                    | "COM5"
                    | "COM6"
                    | "COM7"
                    | "COM8"
                    | "COM9"
                    | "LPT1"
                    | "LPT2"
                    | "LPT3"
                    | "LPT4"
                    | "LPT5"
                    | "LPT6"
                    | "LPT7"
                    | "LPT8"
                    | "LPT9"
                    | "COM¹"
                    | "COM²"
                    | "COM³"
                    | "LPT¹"
                    | "LPT²"
                    | "LPT³"
            ),
            "Git cannot preserve a Windows device-name path component"
        );
    }
    Ok(path)
}

#[cfg(any(windows, test))]
fn is_drive_absolute(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1..3] == *b":/"
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn git_windows_paths_preserve_drive_unc_spaces_and_unicode() {
        for (input, expected) in [
            (
                r"\\?\C:\Users\Fixture App\worktrees\one",
                "C:/Users/Fixture App/worktrees/one",
            ),
            (r"C:\Users\日本語\one", "C:/Users/日本語/one"),
            (r"\\?\UNC\server\share name\one", "//server/share name/one"),
            (r"\\server\share\one", "//server/share/one"),
            (r"\\?\C:\", "C:/"),
            (r"\\?\UNC\server\share\", "//server/share/"),
        ] {
            assert_eq!(windows_git_path(input).unwrap(), expected);
        }
        let long = format!(
            r"\\?\C:\{}",
            (0..35)
                .map(|i| format!("segment{i}"))
                .collect::<Vec<_>>()
                .join("\\")
        );
        assert!(long.len() > 260);
        assert_eq!(
            windows_git_path(&long).unwrap(),
            long[4..].replace('\\', "/")
        );
    }
    #[test]
    fn git_windows_paths_reject_semantically_different_device_or_verbatim_names() {
        for path in [
            r"\\?\Volume{00000000-0000-0000-0000-000000000000}\repo",
            r"\\.\pipe\name",
            r"\\?\GLOBALROOT\Device\HarddiskVolume1\repo",
            r"C:relative",
            r"\rooted",
            "relative",
            r"\\server",
            r"C:\a\..\b",
            r"\\?\C:\name.\repo",
            r"\\?\C:\name \repo",
            r"\\?\C:\NUL.txt",
            r"C:\repo\file:stream",
            r"C:\repo\COM1",
            r"\\?\C:\COM¹",
            "C:/a//b",
        ] {
            assert!(windows_git_path(path).is_err(), "{path}");
        }
    }
    #[cfg(unix)]
    #[test]
    fn unix_git_path_bytes_are_not_interpreted_as_windows_syntax() {
        use std::os::unix::ffi::OsStringExt;
        let path = std::path::PathBuf::from(OsString::from_vec(b"/tmp/opaque-\xff-name".to_vec()));
        assert_eq!(external_git_path(&path).unwrap(), path.as_os_str());
    }
}
