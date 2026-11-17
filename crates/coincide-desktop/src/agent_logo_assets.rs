// Bundled official ACP Registry marks; refreshed for new entries at runtime.
use gpui_kit::{Image, ImageFormat};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

// Registry icons are often monochrome currentColor templates. Keep their
// silhouettes distinct with stable accents that remain legible in both themes.
fn accent(id: &str, dark: bool) -> u32 {
    const DARK: [u32; 8] = [
        0xf4878f, 0xb8a1f4, 0x74cfcc, 0xefc27a, 0x8abaf5, 0xe9a6d0, 0xa5d49c, 0xb3c8e8,
    ];
    const LIGHT: [u32; 8] = [
        0xb83e4a, 0x6545b0, 0x257f80, 0x986322, 0x3561a7, 0xa4467c, 0x4d823f, 0x506a93,
    ];
    let index = match id {
        "amp-acp" => 0,
        "auggie" | "qwen-code" => 1,
        "autohand" => 2,
        "bob" => 3,
        "cline" | "deepseek-harness" | "gemini" => 4,
        "codebuddy-code" => 5,
        _ => {
            let hash = id.bytes().fold(2_166_136_261_u32, |hash, byte| {
                (hash ^ u32::from(byte)).wrapping_mul(16_777_619)
            });
            hash as usize % DARK.len()
        }
    };
    if dark { DARK[index] } else { LIGHT[index] }
}

fn colored_svg(id: &str, bytes: &[u8], dark: bool) -> Vec<u8> {
    let color = format!("#{:06x}", accent(id, dark));
    let svg = String::from_utf8_lossy(bytes).replace("currentColor", &color);
    // This bundled DeepSeek mark uses a white fill instead of currentColor.
    let svg = if id == "deepseek-harness" {
        svg.replace("#fff", &color)
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
    // GPUI's image renderer keeps the SVG's own fills and gradients. Replace
    // only template ink, leaving any supplied multicolor artwork intact.
    let image = Arc::new(Image::from_bytes(
        ImageFormat::Svg,
        colored_svg(id, &source, dark),
    ));
    images.insert(key, (source, image.clone()));
    image
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
    fn registry_templates_are_colored_in_both_themes_and_keep_embedded_colors() {
        let renderer = gpui_kit::SvgRenderer::new(Arc::new(()));
        let ids = [
            "amp-acp",
            "auggie",
            "autohand",
            "bob",
            "cline",
            "codebuddy-code",
            "deepseek-harness",
        ];
        assert_eq!(
            ids[..6]
                .iter()
                .map(|id| accent(id, true))
                .collect::<std::collections::HashSet<_>>()
                .len(),
            6
        );
        for id in ids {
            for dark in [false, true] {
                let bytes = colored_svg(id, bundled(id).unwrap(), dark);
                let image = renderer.render_single_frame(&bytes, 1.).unwrap();
                assert!(
                    image.as_bytes(0).unwrap().chunks_exact(4).any(|pixel| {
                        pixel[3] > 100 && (pixel[0] != pixel[1] || pixel[1] != pixel[2])
                    }),
                    "{id} must retain visible color in the {} theme",
                    if dark { "dark" } else { "light" }
                );
            }
        }
        let original = br##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path fill="#25ad85" d="M0 0h8v16H0z"/><path fill="currentColor" d="M8 0h8v16H8z"/></svg>"##;
        let colored = colored_svg("new-agent", original, true);
        let text = std::str::from_utf8(&colored).unwrap();
        assert!(text.contains("#25ad85"));
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
