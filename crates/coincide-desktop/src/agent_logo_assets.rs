// Bundled official ACP Registry marks; refreshed for new entries at runtime.
use gpui_kit::{Image, ImageFormat};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

// Only artwork published by the named provider may override a registry mark.
// Source URLs and the two IBM Bob theme substitutions are documented beside
// the files. Unknown or monochrome marks keep neutral, theme-readable ink.
fn official_svg(id: &str, dark: bool) -> Option<&'static [u8]> {
    Some(match id {
        "amp-acp" => include_bytes!("../assets/agent-registry/brand/amp.svg"),
        "bob" if dark => include_bytes!("../assets/agent-registry/brand/bob-dark.svg"),
        "bob" => include_bytes!("../assets/agent-registry/brand/bob-light.svg"),
        "codebuddy-code" => include_bytes!("../assets/agent-registry/brand/codebuddy.svg"),
        "qwen-code" => include_bytes!("../assets/agent-registry/brand/qwen.svg"),
        "kiro" => include_bytes!("../assets/agent-registry/brand/kiro.svg"),
        "kilo" => include_bytes!("../assets/agent-registry/brand/kilo.svg"),
        _ => return None,
    })
}

fn colored_svg(id: &str, bytes: &[u8], dark: bool) -> Vec<u8> {
    if let Some(official) = official_svg(id, dark) {
        return official.to_vec();
    }
    let color = if dark { "#f4f4f4" } else { "#171717" };
    let svg = String::from_utf8_lossy(bytes).replace("currentColor", color);
    // This bundled DeepSeek mark uses a white fill instead of currentColor.
    let svg = if id == "deepseek-harness" {
        svg.replace("#fff", color)
    } else {
        svg
    };
    svg.into_bytes()
}

pub(super) fn colored_image(id: &str, source: Arc<[u8]>, dark: bool) -> Arc<Image> {
    type Cached = HashMap<(String, bool), (Arc<[u8]>, Arc<Image>)>;
    static IMAGES: OnceLock<Mutex<Cached>> = OnceLock::new();
    let mut images = IMAGES
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let key = (id.to_owned(), dark);
    if let Some((previous, image)) = images.get(&key)
        && previous.as_ref() == source.as_ref()
    {
        return image.clone();
    }
    let (format, bytes) = artwork(id, &source, dark);
    let image = Arc::new(Image::from_bytes(format, bytes));
    images.insert(key, (source, image.clone()));
    image
}

/// Both GPUI and the native menu use the same provider artwork.
pub(super) fn artwork(id: &str, source: &[u8], dark: bool) -> (ImageFormat, Vec<u8>) {
    match id {
        "claude-acp" => (
            ImageFormat::Png,
            include_bytes!("../assets/providers/logo-claude.png").to_vec(),
        ),
        "antigravity-acp" => (
            ImageFormat::Png,
            include_bytes!("../assets/providers/logo-antigravity.png").to_vec(),
        ),
        "gemini" => (
            ImageFormat::Png,
            include_bytes!("../assets/agent-registry/brand/gemini.png").to_vec(),
        ),
        "kimi-code" => (
            ImageFormat::Png,
            include_bytes!("../assets/agent-registry/brand/kimi-code.png").to_vec(),
        ),
        _ => (ImageFormat::Svg, colored_svg(id, source, dark)),
    }
}

fn cache() -> &'static Mutex<HashMap<String, Arc<[u8]>>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Arc<[u8]>>>> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}

pub(super) fn logo(id: &str) -> Option<Arc<[u8]>> {
    let mut cache = cache().lock().ok()?;
    if let Some(mark) = cache.get(id) {
        return Some(mark.clone());
    }
    let mark: Arc<[u8]> = Arc::from(bundled(id)?);
    cache.insert(id.to_owned(), mark.clone());
    Some(mark)
}

pub(super) fn remember(id: String, bytes: Vec<u8>) {
    if let Ok(mut cache) = cache().lock() {
        cache.insert(id, Arc::from(bytes));
    }
}
pub(super) fn bundled(id: &str) -> Option<&'static [u8]> {
    Some(match id {
        "agoragentic-acp" => include_bytes!("../assets/agent-registry/agoragentic-acp.svg"),
        "amp-acp" => include_bytes!("../assets/agent-registry/amp-acp.svg"),
        "antigravity-acp" => include_bytes!("../assets/agent-registry/antigravity-acp.svg"),
        "auggie" => include_bytes!("../assets/agent-registry/auggie.svg"),
        "autohand" => include_bytes!("../assets/agent-registry/autohand.svg"),
        "bob" => include_bytes!("../assets/agent-registry/bob.svg"),
        "claude-acp" => include_bytes!("../assets/agent-registry/claude-acp.svg"),
        "cline" => include_bytes!("../assets/agent-registry/cline.svg"),
        "codebuddy-code" => include_bytes!("../assets/agent-registry/codebuddy-code.svg"),
        "codex-acp" => include_bytes!("../assets/agent-registry/codex-acp.svg"),
        "cortex-code" => include_bytes!("../assets/agent-registry/cortex-code.svg"),
        "corust-agent" => include_bytes!("../assets/agent-registry/corust-agent.svg"),
        "crow-cli" => include_bytes!("../assets/agent-registry/crow-cli.svg"),
        "cursor" => include_bytes!("../assets/agent-registry/cursor.svg"),
        "deepagents" => include_bytes!("../assets/agent-registry/deepagents.svg"),
        "deepseek-harness" => include_bytes!("../assets/agent-registry/deepseek-harness.svg"),
        "devin" => include_bytes!("../assets/agent-registry/devin.svg"),
        "dimcode" => include_bytes!("../assets/agent-registry/dimcode.svg"),
        "dirac" => include_bytes!("../assets/agent-registry/dirac.svg"),
        "factory-droid" => include_bytes!("../assets/agent-registry/factory-droid.svg"),
        "fast-agent" => include_bytes!("../assets/agent-registry/fast-agent.svg"),
        "fx" => include_bytes!("../assets/agent-registry/fx.svg"),
        "gemini" => include_bytes!("../assets/agent-registry/gemini.svg"),
        "github-copilot-cli" => include_bytes!("../assets/agent-registry/github-copilot-cli.svg"),
        "glm-acp-agent" => include_bytes!("../assets/agent-registry/glm-acp-agent.svg"),
        "goose" => include_bytes!("../assets/agent-registry/goose.svg"),
        "grok-build" => include_bytes!("../assets/agent-registry/grok-build.svg"),
        "harn" => include_bytes!("../assets/agent-registry/harn.svg"),
        "junie" => include_bytes!("../assets/agent-registry/junie.svg"),
        "kilo" => include_bytes!("../assets/agent-registry/kilo.svg"),
        "kimchi" => include_bytes!("../assets/agent-registry/kimchi.svg"),
        "kimi" => include_bytes!("../assets/agent-registry/kimi.svg"),
        "kimi-code" => include_bytes!("../assets/agent-registry/kimi-code.svg"),
        "kiro" => include_bytes!("../assets/agent-registry/kiro.svg"),
        "minimax-code" => include_bytes!("../assets/agent-registry/minimax-code.svg"),
        "minion-code" => include_bytes!("../assets/agent-registry/minion-code.svg"),
        "mistral-vibe" => include_bytes!("../assets/agent-registry/mistral-vibe.svg"),
        "muse-code" => include_bytes!("../assets/agent-registry/muse-code.svg"),
        "nova" => include_bytes!("../assets/agent-registry/nova.svg"),
        "opencode" => include_bytes!("../assets/agent-registry/opencode.svg"),
        "opencode-v2" => include_bytes!("../assets/agent-registry/opencode-v2.svg"),
        "pi-acp" => include_bytes!("../assets/agent-registry/pi-acp.svg"),
        "poolside" => include_bytes!("../assets/agent-registry/poolside.svg"),
        "qoder" => include_bytes!("../assets/agent-registry/qoder.svg"),
        "qwen-code" => include_bytes!("../assets/agent-registry/qwen-code.svg"),
        "sigit" => include_bytes!("../assets/agent-registry/sigit.svg"),
        "stakpak" => include_bytes!("../assets/agent-registry/stakpak.svg"),
        "vtcode" => include_bytes!("../assets/agent-registry/vtcode.svg"),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn official_artwork_and_neutral_fallback_render_in_both_themes() {
        let renderer = gpui_kit::SvgRenderer::new(Arc::new(()));
        for id in [
            "amp-acp",
            "bob",
            "codebuddy-code",
            "qwen-code",
            "kiro",
            "kilo",
        ] {
            for dark in [false, true] {
                let bytes = colored_svg(id, bundled(id).unwrap(), dark);
                let image = renderer.render_single_frame(&bytes, 1.).unwrap();
                assert!(
                    image.as_bytes(0).unwrap().chunks_exact(4).any(|pixel| {
                        pixel[3] > 100 && (pixel[0] != pixel[1] || pixel[1] != pixel[2])
                    }),
                    "{id} must retain its official artwork in the {} theme",
                    if dark { "dark" } else { "light" }
                );
            }
        }
        for id in [
            "auggie",
            "autohand",
            "cline",
            "deepseek-harness",
            "new-agent",
        ] {
            let source = bundled(id).unwrap_or(br#"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path fill="currentColor" d="M0 0h16v16H0z"/></svg>"#);
            for (dark, ink) in [(true, "#f4f4f4"), (false, "#171717")] {
                let bytes = colored_svg(id, source, dark);
                assert!(std::str::from_utf8(&bytes).unwrap().contains(ink));
                renderer.render_single_frame(&bytes, 1.).unwrap();
            }
        }
        assert!(
            std::str::from_utf8(official_svg("qwen-code", false).unwrap())
                .unwrap()
                .contains("#082DFF")
        );
        assert!(
            std::str::from_utf8(official_svg("bob", true).unwrap())
                .unwrap()
                .contains("#bc93fd")
        );
        assert!(
            std::str::from_utf8(official_svg("bob", false).unwrap())
                .unwrap()
                .contains("#a16efb")
        );
        let original = br##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path fill="#25ad85" d="M0 0h8v16H0z"/><path fill="currentColor" d="M8 0h8v16H8z"/></svg>"##;
        let colored = colored_svg("new-agent", original, true);
        let text = std::str::from_utf8(&colored).unwrap();
        assert!(text.contains("#25ad85"));
        assert!(text.contains("#f4f4f4"));
        assert!(!text.contains("currentColor"));
        renderer.render_single_frame(&colored, 1.).unwrap();

        let source: Arc<[u8]> = Arc::from(&original[..]);
        let first = colored_image("test-new-agent", source.clone(), true);
        assert!(Arc::ptr_eq(
            &first,
            &colored_image("test-new-agent", source.clone(), true)
        ));
        assert!(!Arc::ptr_eq(
            &first,
            &colored_image("test-new-agent", source, false)
        ));
    }

    #[test]
    fn bundled_official_logos_are_distinct_and_rasterize() {
        let renderer = gpui_kit::SvgRenderer::new(Arc::new(()));
        let ids = [
            "agoragentic-acp",
            "amp-acp",
            "antigravity-acp",
            "auggie",
            "autohand",
            "bob",
            "claude-acp",
            "cline",
            "codebuddy-code",
            "codex-acp",
            "cortex-code",
            "corust-agent",
            "crow-cli",
            "cursor",
            "deepagents",
            "deepseek-harness",
            "devin",
            "dimcode",
            "dirac",
            "factory-droid",
            "fast-agent",
            "fx",
            "gemini",
            "github-copilot-cli",
            "glm-acp-agent",
            "goose",
            "grok-build",
            "harn",
            "junie",
            "kilo",
            "kimchi",
            "kimi",
            "kimi-code",
            "kiro",
            "minimax-code",
            "minion-code",
            "mistral-vibe",
            "muse-code",
            "nova",
            "opencode",
            "opencode-v2",
            "pi-acp",
            "poolside",
            "qoder",
            "qwen-code",
            "sigit",
            "stakpak",
            "vtcode",
        ];
        for id in ids {
            let data = bundled(id).unwrap();
            let image = renderer
                .render_single_frame(data, 1.)
                .unwrap_or_else(|error| panic!("{id}: {error}"));
            assert!(
                image
                    .as_bytes(0)
                    .unwrap()
                    .chunks_exact(4)
                    .any(|pixel| pixel[3] > 0),
                "{id}"
            );
        }
        assert_ne!(bundled("qwen-code"), bundled("github-copilot-cli"));
        assert!(bundled("unknown-agent").is_none());
    }
}
