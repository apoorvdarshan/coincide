//! Closed toast payloads shared by the actual Windows adapter and inert tests.
use super::{Payload, thread_from_event_id};
use anyhow::{Result, ensure};
use uuid::Uuid;

#[cfg(all(windows, feature = "native-notifications"))]
pub(super) const GROUP: &str = "coincide-rust";
#[cfg(all(windows, feature = "native-notifications"))]
pub(super) const MAX_HISTORY: u32 = 4096;

fn xml_text(text: &str) -> String {
    text.chars()
        // XML 1.0 excludes controls even when escaped. Do not let preview text
        // change the surrounding document or add actions, URLs or images.
        .filter(|c| matches!(*c, '\t' | '\n' | '\r') || *c >= ' ')
        .filter(|c| !matches!(*c as u32, 0xfffe | 0xffff))
        .flat_map(|c| match c {
            '&' => "&amp;".chars().collect::<Vec<_>>(),
            '<' => "&lt;".chars().collect(),
            '>' => "&gt;".chars().collect(),
            '"' => "&quot;".chars().collect(),
            '\'' => "&apos;".chars().collect(),
            _ => vec![c],
        })
        .collect()
}

pub(super) fn toast_xml(payload: &Payload) -> Result<String> {
    ensure!(
        thread_from_event_id(&payload.id) == Some(payload.thread),
        "Invalid notification identity"
    );
    ensure!(
        payload.title.chars().count() <= 120
            && payload
                .body
                .as_ref()
                .is_none_or(|body| body.chars().count() <= 240),
        "Notification preview exceeds limit"
    );
    let body = payload
        .body
        .as_deref()
        .map(|body| format!("<text>{}</text>", xml_text(body)))
        .unwrap_or_default();
    Ok(format!(
        "<toast launch=\"{}\"><visual><binding template=\"ToastGeneric\"><text>{}</text>{body}</binding></visual><audio silent=\"true\"/></toast>",
        payload.id,
        xml_text(&payload.title)
    ))
}

/// A history receipt may only clear this exact event namespace and thread.
/// Never use a truncated group/tag hash as authority to remove another toast.
pub(super) fn owned_history_id(id: &str, thread: Uuid) -> bool {
    thread_from_event_id(id) == Some(thread)
}

/// `canonicalize` yields verbatim `\\?\` paths, which the shell namespace
/// behind `IShellLink::SetPath` does not parse. Return the equivalent ordinary
/// Win32 disk or UNC path, refusing components whose meaning would change once
/// the verbatim prefix no longer disables Win32 normalization. Callers still
/// verify the saved target by canonical path and file identity.
pub(super) fn shell_link_target(path: &str) -> Result<String> {
    let plain = if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = path.strip_prefix(r"\\?\") {
        rest.to_owned()
    } else {
        path.to_owned()
    };
    let bytes = plain.as_bytes();
    let (root, rest) = if bytes.len() > 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && bytes[2] == b'\\'
    {
        (&plain[..3], &plain[3..])
    } else if let Some(unc) = plain.strip_prefix(r"\\") {
        let mut parts = unc.splitn(3, '\\');
        let (Some(server), Some(share), Some(_)) = (parts.next(), parts.next(), parts.next())
        else {
            anyhow::bail!("Unsupported notification target path");
        };
        ensure!(
            !server.is_empty() && !share.is_empty() && !matches!(server, "?" | "."),
            "Unsupported notification target path"
        );
        let root = server.len() + share.len() + 4;
        (&plain[..root], &plain[root..])
    } else {
        anyhow::bail!("Unsupported notification target path");
    };
    ensure!(
        !root.contains('/')
            && rest.split('\\').all(|part| {
                !part.is_empty()
                    && part != "."
                    && part != ".."
                    && !part.contains('/')
                    && !part.ends_with(['.', ' '])
            }),
        "Unsupported notification target path"
    );
    Ok(plain)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn payload() -> Payload {
        let thread = Uuid::new_v4();
        Payload {
            id: format!("coincide-rust.{thread}.{}.completed", Uuid::new_v4()),
            thread,
            title: "Résumé <Agent> & \"approval\"".into(),
            body: Some("a\0b\u{1f}\n<image src='https://untrusted.invalid'> Ω".into()),
        }
    }
    #[test]
    fn preview_cannot_inject_toast_elements_and_invalid_xml_controls_are_removed() {
        let xml = toast_xml(&payload()).unwrap();
        assert!(xml.contains("Résumé &lt;Agent&gt; &amp; &quot;approval&quot;"));
        assert!(xml.contains("ab\n&lt;image src=&apos;https://untrusted.invalid&apos;&gt; Ω"));
        assert!(!xml.contains("<image"));
        assert!(!xml.contains('\0'));
        assert!(!xml.contains('\u{1f}'));
    }
    #[test]
    fn invalid_or_foreign_event_ids_have_no_payload_or_clear_authority() {
        let mut p = payload();
        let foreign = Uuid::new_v4();
        assert!(owned_history_id(&p.id, p.thread));
        assert!(!owned_history_id(&p.id, foreign));
        p.thread = foreign;
        assert!(toast_xml(&p).is_err());
        for id in [
            "",
            "coincide-rust",
            "coincide-rust.<toast>",
            "https://untrusted.invalid",
        ] {
            assert!(!owned_history_id(id, foreign));
        }
    }
    #[test]
    fn shell_link_targets_drop_only_the_verbatim_prefix() {
        for (path, expected) in [
            (
                r"\\?\D:\a\coincide\target\app.exe",
                r"D:\a\coincide\target\app.exe",
            ),
            (
                r"C:\Program Files\Coincide\app.exe",
                r"C:\Program Files\Coincide\app.exe",
            ),
            (
                r"\\?\UNC\server\share\Coincide\app.exe",
                r"\\server\share\Coincide\app.exe",
            ),
            (r"\\server\share\app.exe", r"\\server\share\app.exe"),
        ] {
            assert_eq!(shell_link_target(path).unwrap(), expected);
        }
        for path in [
            "",
            r"\\?\Volume{00000000-0000-0000-0000-000000000000}\app.exe",
            r"\\?\GLOBALROOT\Device\HarddiskVolume1\app.exe",
            r"\\.\C:\app.exe",
            r"\\?\C:\name.\app.exe",
            r"\\?\C:\name \app.exe",
            r"\\?\C:\a\..\app.exe",
            r"\\?\C:\a\.\app.exe",
            r"\\?\C:\a\\app.exe",
            r"\\?\C:\a/b\app.exe",
            r"\\?\UNC\server\app.exe",
            r"C:",
            r"C:\",
            "relative\\app.exe",
        ] {
            assert!(shell_link_target(path).is_err(), "{path}");
        }
    }
    #[test]
    fn omitted_preview_and_oversized_preview_are_distinct() {
        let mut p = payload();
        p.body = None;
        assert_eq!(toast_xml(&p).unwrap().matches("<text>").count(), 1);
        p.body = Some("x".repeat(241));
        assert!(toast_xml(&p).is_err());
    }
}
