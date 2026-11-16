// Bundled official ACP Registry marks; refreshed for new entries at runtime.
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

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
