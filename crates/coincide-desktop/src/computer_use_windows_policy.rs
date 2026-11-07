//! Pure bounds shared by the Windows adapter and synthetic cross-platform tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Identity {
    pub hwnd: usize,
    pub pid: u32,
    pub created: u64,
}
impl Identity {
    pub fn matches(self, current: Self) -> bool {
        self.hwnd != 0 && self.pid != 0 && self.created != 0 && self == current
    }
}
pub(super) fn restricted_executable(path: &str) -> bool {
    let file = path
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or(path)
        .to_ascii_lowercase();
    matches!(
        file.as_str(),
        "chrome.exe"
            | "msedge.exe"
            | "firefox.exe"
            | "brave.exe"
            | "opera.exe"
            | "arc.exe"
            | "safari.exe"
            | "logonui.exe"
            | "consent.exe"
            | "credentialuibroker.exe"
    )
}
pub(super) fn role(kind: i32) -> &'static str {
    match kind {
        50000 => "button",
        50002 => "checkbox",
        50003 => "combobox",
        50004 => "edit",
        50005 => "hyperlink",
        50006 => "image",
        50007 => "list_item",
        50008 => "list",
        50009 => "menu",
        50010 => "menu_bar",
        50011 => "menu_item",
        50012 => "progress",
        50013 => "radio_button",
        50014 => "scroll_bar",
        50015 => "slider",
        50016 => "spinner",
        50018 => "tab",
        50019 => "tab_item",
        50020 => "text",
        50021 => "toolbar",
        50023 => "tree",
        50024 => "tree_item",
        50026 => "group",
        50028 => "data_grid",
        50029 => "data_item",
        50030 => "document",
        50031 => "split_button",
        50032 => "window",
        50033 => "pane",
        50036 => "table",
        _ => "custom",
    }
}
pub(super) fn bounded_text(text: &str, maximum: usize) -> String {
    text.chars().take(maximum).collect()
}
pub(super) fn point(rect: [i32; 4], dpi: u32, x: f64, y: f64) -> Option<(i32, i32)> {
    let width = i64::from(rect[2]) - i64::from(rect[0]);
    let height = i64::from(rect[3]) - i64::from(rect[1]);
    if dpi == 0
        || width <= 0
        || height <= 0
        || width > 16384
        || height > 16384
        || !x.is_finite()
        || !y.is_finite()
        || x < 0.0
        || y < 0.0
    {
        return None;
    }
    let dx = (x * f64::from(dpi) / 96.0).floor();
    let dy = (y * f64::from(dpi) / 96.0).floor();
    if dx >= width as f64 || dy >= height as f64 {
        return None;
    }
    let px = i64::from(rect[0]) + dx as i64;
    let py = i64::from(rect[1]) + dy as i64;
    Some((i32::try_from(px).ok()?, i32::try_from(py).ok()?))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn process_birth_and_full_width_window_identity_are_required() {
        let original = Identity {
            hwnd: usize::MAX,
            pid: 7,
            created: 9,
        };
        assert!(original.matches(original));
        assert!(!original.matches(Identity {
            created: 10,
            ..original
        }));
        assert!(!original.matches(Identity {
            hwnd: 3,
            ..original
        }));
        assert!(
            !Identity {
                created: 0,
                ..original
            }
            .matches(Identity {
                created: 0,
                ..original
            })
        );
    }
    #[test]
    fn dpi_points_are_bounded_in_the_observed_window_and_unicode_is_not_split() {
        assert_eq!(
            point([-100, 20, 300, 220], 192, 199.9, 99.9),
            Some((299, 219))
        );
        for (x, y) in [
            (200.0, 0.0),
            (0.0, 100.0),
            (-0.1, 0.0),
            (f64::NAN, 0.0),
            (0.0, f64::INFINITY),
        ] {
            assert_eq!(point([-100, 20, 300, 220], 192, x, y), None);
        }
        assert_eq!(point([0, 0, 20, 20], 0, 0.0, 0.0), None);
        assert_eq!(bounded_text("中🙂a", 2), "中🙂");
        assert_eq!(role(50004), "edit");
        assert_eq!(role(-1), "custom");
        assert!(restricted_executable("C:\\Apps\\CHROME.EXE"));
        assert!(restricted_executable("C:\\Windows\\Consent.exe"));
        assert!(!restricted_executable("C:\\Tests\\fixture.exe"));
    }
}
