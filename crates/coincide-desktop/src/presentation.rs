use super::*;

// Shared with the macOS Theme and TranscriptMetrics. Keep the composer and
// virtualized transcript rows aligned without constraining the scroll viewport.
pub(super) const CONTENT_WIDTH: f32 = 820.;
pub(super) const CONTENT_GUTTER: f32 = 24.;
pub(super) const RAIL_GUTTER: f32 = 34.;

pub(super) fn provider_name(provider: &str) -> &str {
    match provider {
        "codex" => "Codex",
        "claude" => "Claude",
        "cursor" => "Cursor",
        "grok" => "Grok",
        "opencode" => "OpenCode",
        "antigravity" => "Antigravity",
        "" => "Assistant",
        other => other,
    }
}

impl Coincide {
    pub(super) fn provider_ink(&self, provider: &str) -> Rgba {
        let (light, dark) = match provider {
            "claude" => (0xC2603D, 0xE08A6B),
            "codex" => (0x0E8A6A, 0x3CC79A),
            "cursor" => (0x5A5FD6, 0x9A9EFF),
            "grok" => (0x6B7077, 0xA9AEB4),
            "opencode" => (0xB7700C, 0xE9B04E),
            "antigravity" => (0x2F6BDB, 0x6FA3FF),
            _ => return self.color(0xe4e9f2),
        };
        rgb(if self.appearance_dark { dark } else { light })
    }
}
