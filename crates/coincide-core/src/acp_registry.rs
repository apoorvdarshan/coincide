//! ACP Registry discovery. Registry metadata never launches a process or grants
//! execution authority; a native user action must approve an installed binary.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, ffi::OsStr, io::Read, path::PathBuf, time::Duration};

pub const REGISTRY_URL: &str =
    "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";
const MAX_REGISTRY: u64 = 4 * 1024 * 1024;
const EXISTING: &[&str] = &[
    "codex-acp",
    "claude-acp",
    "cursor",
    "grok-build",
    "opencode",
    "opencode-v2",
    "antigravity-acp",
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Agent {
    pub id: String,
    pub name: String,
    pub website: Option<String>,
    /// Only the official registry's icon for this exact ID is accepted.
    #[serde(default)]
    pub icon: Option<String>,
    pub executable: Option<PathBuf>,
    pub arguments: Vec<String>,
    pub environment: BTreeMap<String, String>,
}

pub fn provider_id(id: &str) -> Option<String> {
    valid_id(id).then(|| format!("acp-{id}"))
}
/// A protocol-defined auth failure is safe to expose without provider data.
pub const SIGN_IN_REQUIRED: &str =
    "Sign in to this agent from Settings → Providers, then refresh its models.";

pub fn registry_id(provider: &str) -> Option<&str> {
    let id = provider.strip_prefix("acp-")?;
    valid_id(id).then_some(id)
}
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 96
        && !id.starts_with('-')
        && !id.ends_with('-')
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}
fn text(value: &Value, limit: usize) -> Option<&str> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= limit && !s.chars().any(char::is_control))
}
fn environment(value: &Value) -> Option<BTreeMap<String, String>> {
    if value.is_null() {
        return Some(BTreeMap::new());
    }
    let map = value.as_object()?;
    if map.len() > 32 {
        return None;
    }
    let mut result = BTreeMap::new();
    for (key, value) in map {
        let upper = key.to_ascii_uppercase();
        if key.len() > 128
            || key.is_empty()
            || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            || ["PATH", "HOME", "SHELL", "BASH_ENV", "ENV"].contains(&upper.as_str())
            || ["COINCIDE_", "DYLD_", "LD_"]
                .iter()
                .any(|prefix| upper.starts_with(prefix))
            || [
                "TOKEN",
                "SECRET",
                "PASSWORD",
                "API_KEY",
                "CREDENTIAL",
                "AUTH",
                "PROXY",
            ]
            .iter()
            .any(|s| upper.contains(s))
        {
            return None;
        }
        result.insert(key.clone(), text(value, 512)?.to_owned());
    }
    Some(result)
}
fn arguments(value: &Value) -> Option<Vec<String>> {
    if value.is_null() {
        return Some(Vec::new());
    }
    let rows = value.as_array()?;
    if rows.len() > 32 {
        return None;
    }
    rows.iter()
        .map(|arg| text(arg, 512).map(str::to_owned))
        .collect()
}
fn executable_name(id: &str, distribution: &Value) -> Option<String> {
    let known = match id {
        "github-copilot-cli" => Some("copilot"),
        "gemini" => Some("gemini"),
        "qwen-code" => Some("qwen"),
        "kimi-code" => Some("kimi"),
        "muse-code" => Some("muse"),
        "factory-droid" => Some("droid"),
        "minimax-code" => Some("mcode"),
        "kiro" => Some("kiro-cli"),
        "mistral-vibe" => Some("vibe-acp"),
        "amp-acp" => Some("amp-acp"),
        _ => None,
    };
    if let Some(known) = known {
        return Some(known.into());
    }
    if let Some(cmd) = text(&distribution["cmd"], 512) {
        let basename = cmd.rsplit(['/', '\\']).next()?;
        return safe_program(basename).then(|| basename.to_owned());
    }
    if let Some(package) = text(&distribution["package"], 256) {
        let package = package.rsplit('/').next()?;
        let package = package.split('@').next()?;
        return safe_program(package).then(|| package.to_owned());
    }
    None
}
fn safe_program(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && !name.starts_with('-')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}
fn locate(path: Option<&OsStr>, name: &str) -> Option<PathBuf> {
    if !safe_program(name) {
        return None;
    }
    std::env::split_paths(path?)
        .take(256)
        .filter(|dir| dir.is_absolute())
        .flat_map(|dir| {
            let names = if cfg!(windows) && !name.ends_with(".exe") {
                vec![format!("{name}.exe"), format!("{name}.com")]
            } else {
                vec![name.to_owned()]
            };
            names.into_iter().map(move |name| dir.join(name))
        })
        .find(|file| {
            let Ok(meta) = std::fs::metadata(file) else {
                return false;
            };
            if !meta.is_file() {
                return false;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if meta.permissions().mode() & 0o111 == 0 {
                    return false;
                }
            }
            true
        })
}
fn platform() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("darwin-aarch64"),
        ("macos", "x86_64") => Some("darwin-x86_64"),
        ("linux", "aarch64") => Some("linux-aarch64"),
        ("linux", "x86_64") => Some("linux-x86_64"),
        ("windows", "aarch64") => Some("windows-aarch64"),
        ("windows", "x86_64") => Some("windows-x86_64"),
        _ => None,
    }
}
pub(crate) fn search_path() -> Option<std::ffi::OsString> {
    let mut paths: Vec<_> = std::env::var_os("PATH")
        .as_deref()
        .map(std::env::split_paths)
        .into_iter()
        .flatten()
        .collect();
    paths.retain(|path| path.is_absolute());
    #[cfg(unix)]
    {
        // macOS GUI launches often omit Homebrew and user-local executables.
        for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = PathBuf::from(path);
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
        if let Some(home) = std::env::var_os("HOME") {
            for relative in [".local/bin", ".cargo/bin", ".bun/bin"] {
                let path = PathBuf::from(&home).join(relative);
                if path.is_absolute() && !paths.contains(&path) {
                    paths.push(path);
                }
            }
        }
    }
    std::env::join_paths(paths).ok()
}
/// Resolve a single command name or absolute path; never invoke a shell.
pub fn resolve_executable(command: &str) -> Option<PathBuf> {
    let path = PathBuf::from(command);
    if path.is_absolute() {
        Some(path)
    } else {
        locate(search_path().as_deref(), command)
    }
}
fn entry(row: &Value, target: Option<&str>, path: Option<&OsStr>) -> Option<Agent> {
    let id = text(&row["id"], 96)?;
    if !valid_id(id) || EXISTING.contains(&id) {
        return None;
    }
    let name = text(&row["name"], 256)?.to_owned();
    let d = &row["distribution"];
    let distribution = target
        .and_then(|target| d["binary"].get(target))
        .filter(|d| d.is_object())
        .or_else(|| d.get("npx").filter(|d| d.is_object()))
        .or_else(|| d.get("uvx").filter(|d| d.is_object()))?;
    let executable = executable_name(id, distribution).and_then(|name| locate(path, &name));
    let website = text(&row["website"], 2048)
        .filter(|url| url.starts_with("https://"))
        .map(str::to_owned);
    let icon = text(&row["icon"], 256)
        .filter(|url| {
            *url == format!("https://cdn.agentclientprotocol.com/registry/v1/latest/{id}.svg")
        })
        .map(str::to_owned);
    Some(Agent {
        id: id.into(),
        name,
        website,
        icon,
        executable,
        arguments: arguments(&distribution["args"])?,
        environment: environment(&distribution["env"])?,
    })
}

/// Parse untrusted registry data, derive only installed local executable hints,
/// and preserve provider arguments literally without invoking a shell.
pub fn parse(bytes: &[u8], target: Option<&str>, path: Option<&OsStr>) -> Result<Vec<Agent>> {
    ensure!(
        bytes.len() as u64 <= MAX_REGISTRY,
        "ACP registry is too large"
    );
    let doc: Value = serde_json::from_slice(bytes).context("Invalid ACP registry")?;
    let rows = doc["agents"]
        .as_array()
        .context("ACP registry has no agents")?;
    ensure!(rows.len() <= 2000, "ACP registry has too many agents");
    let mut agents = Vec::new();
    for row in rows {
        if let Some(agent) = entry(row, target, path)
            && !agents.iter().any(|prior: &Agent| prior.id == agent.id)
        {
            agents.push(agent);
        }
    }
    // These installed agents expose ACP, but are not currently in the index.
    for (id, name, command, args) in [
        ("fx", "fx", "fx", vec!["acp"]),
        (
            "deepseek-harness",
            "DeepSeek Harness",
            "dsh",
            vec!["--profile", "acp"],
        ),
    ] {
        if !agents.iter().any(|agent| agent.id == id) {
            agents.push(Agent {
                id: id.into(),
                name: name.into(),
                website: None,
                icon: None,
                executable: locate(path, command),
                arguments: args.into_iter().map(str::to_owned).collect(),
                environment: BTreeMap::new(),
            });
        }
    }
    agents.sort_by_key(|agent| agent.name.to_lowercase());
    Ok(agents)
}

/// Fetch a new registry mark off the UI thread from the registry's own source.
/// Registry metadata cannot select a host or path, and SVGs with external
/// resources or active content are never handed to the renderer.
pub fn fetch_icon(id: &str) -> Result<Vec<u8>> {
    ensure!(valid_id(id), "Invalid agent identifier");
    let url = format!(
        "https://raw.githubusercontent.com/agentclientprotocol/registry/main/{id}/icon.svg"
    );
    let config = ureq::Agent::config_builder()
        .proxy(None)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(5)))
        .build();
    let mut response = config.new_agent().get(&url).call()?;
    let mut bytes = Vec::new();
    response
        .body_mut()
        .as_reader()
        .take(128 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(safe_icon(&bytes), "Unsupported registry logo");
    Ok(bytes)
}

fn safe_icon(bytes: &[u8]) -> bool {
    if bytes.is_empty() || bytes.len() > 128 * 1024 {
        return false;
    }
    let Ok(svg) = std::str::from_utf8(bytes) else {
        return false;
    };
    let Ok(document) = roxmltree::Document::parse(svg) else {
        return false;
    };
    let root = document.root_element();
    if root.tag_name().name() != "svg" {
        return false;
    }
    let mut count = 0;
    for node in root.descendants().filter(|node| node.is_element()) {
        count += 1;
        if count > 8192 || node.ancestors().take(66).count() > 65 {
            return false;
        }
        if ["script", "foreignobject", "image", "use", "style"]
            .contains(&node.tag_name().name().to_ascii_lowercase().as_str())
        {
            return false;
        }
        for attribute in node.attributes() {
            let name = attribute.name().to_ascii_lowercase();
            let value = attribute.value().to_ascii_lowercase();
            if name.starts_with("on")
                || ["href", "src", "style"].contains(&name.as_str())
                || value.contains("javascript:")
                || value.contains("@import")
                || !value
                    .match_indices("url(")
                    .all(|(index, _)| value[index + 4..].trim_start().starts_with('#'))
            {
                return false;
            }
        }
    }
    true
}
pub fn fetch() -> Result<Vec<Agent>> {
    let config = ureq::Agent::config_builder()
        .proxy(None)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(12)))
        .build();
    let mut response = config
        .new_agent()
        .get(REGISTRY_URL)
        .call()
        .context("ACP registry is unavailable")?;
    let mut bytes = Vec::new();
    response
        .body_mut()
        .as_reader()
        .take(MAX_REGISTRY + 1)
        .read_to_end(&mut bytes)?;
    parse(&bytes, platform(), search_path().as_deref())
}

/// The bundled snapshot allows discovery and browsing before the network
/// responds and on a new installation that has never fetched the registry.
pub fn local_agents() -> Vec<Agent> {
    parse(
        include_bytes!("../third_party/acp-registry/registry.json"),
        platform(),
        search_path().as_deref(),
    )
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn icon_metadata_and_svg_validation_do_not_allow_external_resources() {
        assert!(safe_icon(
            br#"<svg xmlns="http://www.w3.org/2000/svg"><path fill="currentColor"/></svg>"#
        ));
        for bad in [
            "<svg><image href='https://example.org/pixel'/></svg>",
            "<svg><script>test</script></svg>",
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///tmp/x'>]><svg></svg>",
            "<svg><path fill='url(https://example.org/x)'/></svg>",
            "<svg xmlns:x='urn:evil'><x:script>test</x:script></svg>",
            "<svg><path style='fill:url(https://example.org/x)'/></svg>",
        ] {
            assert!(!safe_icon(bad.as_bytes()));
        }
        let mut input = json!({"agents":[{"id":"fixture","name":"Fixture",
            "icon":"https://evil.example/fixture.svg",
            "distribution":{"npx":{"package":"fixture"}}}]});
        let agents = parse(input.to_string().as_bytes(), None, None).unwrap();
        assert!(
            agents
                .iter()
                .find(|agent| agent.id == "fixture")
                .unwrap()
                .icon
                .is_none()
        );
        input["agents"][0]["icon"] =
            json!("https://cdn.agentclientprotocol.com/registry/v1/latest/fixture.svg");
        let agents = parse(input.to_string().as_bytes(), None, None).unwrap();
        assert!(
            agents
                .iter()
                .find(|agent| agent.id == "fixture")
                .unwrap()
                .icon
                .is_some()
        );
        assert!(fetch_icon("../fixture").is_err());
    }
    #[test]
    fn parses_updated_registry_and_only_finds_installed_commands() {
        let root = tempfile::tempdir().unwrap();
        let binary = root.path().join(if cfg!(windows) {
            "copilot.exe"
        } else {
            "copilot"
        });
        std::fs::write(&binary, b"fixture").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let data = br#"{"agents":[{"id":"github-copilot-cli","name":"GitHub Copilot","distribution":{"npx":{"package":"@github/copilot@1.2.3","args":["--acp"]}}},{"id":"future-agent","name":"Future Agent","distribution":{"npx":{"package":"future-agent@1.0.0"}}}]}"#;
        let agents = parse(data, Some("darwin-aarch64"), Some(root.path().as_os_str())).unwrap();
        let copilot = agents
            .iter()
            .find(|a| a.id == "github-copilot-cli")
            .unwrap();
        assert_eq!(copilot.executable.as_deref(), Some(binary.as_path()));
        assert_eq!(copilot.arguments, ["--acp"]);
        assert!(
            agents
                .iter()
                .find(|a| a.id == "future-agent")
                .unwrap()
                .executable
                .is_none()
        );
        assert_eq!(
            registry_id(&provider_id("future-agent").unwrap()),
            Some("future-agent")
        );
    }
    #[test]
    fn bundled_registry_detects_installed_agents_without_network() {
        let root = tempfile::tempdir().unwrap();
        let binary = root.path().join(if cfg!(windows) {
            "copilot.exe"
        } else {
            "copilot"
        });
        std::fs::write(&binary, b"fixture").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let agents = parse(
            include_bytes!("../third_party/acp-registry/registry.json"),
            platform(),
            Some(root.path().as_os_str()),
        )
        .unwrap();
        let copilot = agents
            .iter()
            .find(|agent| agent.id == "github-copilot-cli")
            .unwrap();
        assert_eq!(copilot.executable.as_deref(), Some(binary.as_path()));
        assert!(
            agents
                .iter()
                .any(|agent| agent.id == "gemini" && agent.executable.is_none())
        );
        assert!(agents.len() > 30);
    }
    #[test]
    fn rejects_unsafe_metadata_and_never_interprets_shell() {
        let data = br#"{"agents":[{"id":"../bad","name":"Bad","distribution":{"npx":{"package":"bad"}}},{"id":"bad-env","name":"Bad env","distribution":{"npx":{"package":"bad","env":{"PATH":"/tmp"}}}},{"id":"valid","name":"Valid","distribution":{"npx":{"package":"x","args":["$(touch secret)"]}}}]}"#;
        let agents = parse(data, None, None).unwrap();
        assert!(!agents.iter().any(|a| a.id == "bad-env" || a.id == "../bad"));
        assert_eq!(
            agents.iter().find(|a| a.id == "valid").unwrap().arguments,
            ["$(touch secret)"]
        );
        assert!(registry_id("acp-../evil").is_none());
    }
}
