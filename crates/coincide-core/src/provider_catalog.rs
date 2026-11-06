//! Static provider identity and filesystem-only discovery, derived from Swift's
//! `Models.swift`, `ProviderRegistry.swift`, and `Providers/{Claude,Codex,Cursor,
//! OpenCode,ACP}`. Transport and probe descriptions document the legacy client;
//! they are NOT a promise that the Rust runtime implements those capabilities.
//!
//! Discovery never starts a process, evaluates a shell, reads credentials, reads
//! provider configuration/model caches, or uses the network. A found file does
//! not establish its identity, version, authentication, models, or launchability.

use serde::Serialize;
use std::ffi::OsStr;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderId {
    Claude,
    Codex,
    Cursor,
    Grok,
    Opencode,
    Antigravity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransportKind {
    ClaudeStreamJsonStdio,
    CodexAppServerStdio,
    AcpStdio,
    OpenCodeHttpSse,
}

/// Descriptive legacy behavior only: no executable launch recipe or model list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ProviderDescriptor {
    pub id: ProviderId,
    pub display_name: &'static str,
    /// In preference order, excluding Swift's managed-install/custom paths.
    pub executable_candidates: &'static [&'static str],
    pub transport: TransportKind,
    pub legacy_launch: &'static str,
    pub legacy_version_discovery: &'static str,
    pub legacy_model_discovery: &'static str,
}

pub const PROVIDERS: [ProviderDescriptor; 6] = [
    ProviderDescriptor {
        id: ProviderId::Claude,
        display_name: "Claude Code",
        executable_candidates: &["claude"],
        transport: TransportKind::ClaudeStreamJsonStdio,
        legacy_launch: "stream-json input/output with Claude control protocol",
        legacy_version_discovery: "--version; fallback models are version-gated",
        legacy_model_discovery: "initialize models; version-aware Swift fallback catalog",
    },
    ProviderDescriptor {
        id: ProviderId::Codex,
        display_name: "Codex",
        executable_candidates: &["codex"],
        transport: TransportKind::CodexAppServerStdio,
        legacy_launch: "app-server",
        legacy_version_discovery: "initialize userAgent; --version fallback; Swift rejects <0.149 and warns <0.156",
        legacy_model_discovery: "paginated model/list; Swift fallback catalog",
    },
    ProviderDescriptor {
        id: ProviderId::Cursor,
        display_name: "Cursor",
        executable_candidates: &["cursor-agent"],
        transport: TransportKind::AcpStdio,
        legacy_launch: "acp with session-specific model and access flags",
        legacy_version_discovery: "--version; status/about --format json for account and selection",
        legacy_model_discovery: "cursor/list_available_models; models command; Swift fallback catalog",
    },
    ProviderDescriptor {
        id: ProviderId::Grok,
        display_name: "Grok Build",
        executable_candidates: &["grok"],
        transport: TransportKind::AcpStdio,
        legacy_launch: "agent stdio with access-mode-specific permission flags",
        legacy_version_discovery: "--version",
        legacy_model_discovery: "models command; cached models and Swift defaults; session updates",
    },
    ProviderDescriptor {
        id: ProviderId::Opencode,
        display_name: "OpenCode",
        executable_candidates: &["opencode"],
        transport: TransportKind::OpenCodeHttpSse,
        legacy_launch: "serve --hostname=127.0.0.1 --port=0 with authenticated local HTTP and SSE",
        legacy_version_discovery: "--version; Swift requires major version 2 or later",
        legacy_model_discovery: "HTTP /api/model plus providers/integrations; Swift fallback catalog",
    },
    ProviderDescriptor {
        id: ProviderId::Antigravity,
        display_name: "Antigravity",
        executable_candidates: &["agy_acp_server.par", "agy_acp_server"],
        transport: TransportKind::AcpStdio,
        legacy_launch: "ACP server without arguments; requires adjacent localharness_external helper",
        legacy_version_discovery: "managed release metadata and ACP agentInfo; no --version probe",
        legacy_model_discovery: "ACP initialize/session setup and profile cache; Swift default entry",
    },
];

pub fn provider_catalog() -> &'static [ProviderDescriptor] {
    &PROVIDERS
}

pub fn provider(id: ProviderId) -> &'static ProviderDescriptor {
    PROVIDERS.iter().find(|entry| entry.id == id).unwrap()
}

/// Hard bounds apply even when callers supply larger limits.
pub const MAX_PATH_BYTES: usize = 64 * 1024;
pub const MAX_PATH_ENTRIES: usize = 256;

#[derive(Debug, Clone, Copy)]
pub struct DiscoveryLimits {
    pub max_path_bytes: usize,
    pub max_path_entries: usize,
}

impl Default for DiscoveryLimits {
    fn default() -> Self {
        Self {
            max_path_bytes: MAX_PATH_BYTES,
            max_path_entries: MAX_PATH_ENTRIES,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallationState {
    /// An executable-looking file, not a verified working provider.
    Found,
    /// No match in the fully inspected, absolute PATH entries.
    NotFound,
    /// No match, but limits, skipped entries, or I/O errors made the scan incomplete.
    Indeterminate,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiscoveredProvider {
    pub provider: ProviderId,
    pub state: InstallationState,
    pub executable: Option<PathBuf>,
    // Version, authentication and models intentionally absent: never probed.
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiscoveryReport {
    pub providers: Vec<DiscoveredProvider>,
    pub path_missing: bool,
    pub path_too_large: bool,
    pub entries_truncated: bool,
    pub skipped_relative_entries: usize,
    pub metadata_errors: usize,
    pub inspected_candidates: usize,
}

/// Reads only the current process's PATH (never a login shell).
pub fn discover_installed_tools() -> DiscoveryReport {
    discover_on_path(
        std::env::var_os("PATH").as_deref(),
        DiscoveryLimits::default(),
    )
}

/// Uses a supplied PATH so callers/tests need not mutate process environment.
/// Candidate-name preference precedes PATH order, matching Swift's resolver.
/// Empty/relative entries are skipped to avoid implicit current-directory lookup.
/// Symlinks to regular files are allowed; broken links and directories are not.
/// On Unix, at least one execute bit must be set (ACLs/noexec are not checked).
/// On Windows, exact names and fixed .exe/.com/.cmd/.bat suffixes are inspected;
/// PATHEXT is not consulted and scripts are never evaluated. Found scripts are
/// installation hints, not a guarantee they can be spawned without a shell.
///
/// Bounds limit input, allocations and filesystem calls, not wall-clock time:
/// OS metadata calls on a stalled/network-mounted PATH can still block. No
/// directories are enumerated or searched recursively. Results are snapshots;
/// callers must revalidate before any future launch.
pub fn discover_on_path(path: Option<&OsStr>, limits: DiscoveryLimits) -> DiscoveryReport {
    let mut report = DiscoveryReport {
        providers: Vec::with_capacity(PROVIDERS.len()),
        path_missing: path.is_none(),
        path_too_large: false,
        entries_truncated: false,
        skipped_relative_entries: 0,
        metadata_errors: 0,
        inspected_candidates: 0,
    };
    let mut directories = Vec::new();
    if let Some(path) = path {
        if path.len() > limits.max_path_bytes.min(MAX_PATH_BYTES) {
            report.path_too_large = true;
        } else {
            let bound = limits.max_path_entries.min(MAX_PATH_ENTRIES);
            for (index, directory) in std::env::split_paths(path).enumerate() {
                if index == bound {
                    report.entries_truncated = true;
                    break;
                }
                if !directory.is_absolute() {
                    report.skipped_relative_entries += 1;
                } else if !directories.contains(&directory) {
                    directories.push(directory);
                }
            }
        }
    }
    for descriptor in &PROVIDERS {
        let mut found = None;
        'candidate: for name in descriptor.executable_candidates {
            for directory in &directories {
                for suffix in executable_suffixes() {
                    let candidate = directory.join(format!("{name}{suffix}"));
                    report.inspected_candidates += 1;
                    match std::fs::metadata(&candidate) {
                        Ok(metadata) if executable_file(&metadata) => {
                            found = Some(candidate);
                            break 'candidate;
                        }
                        Ok(_) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                        Err(_) => report.metadata_errors += 1,
                    }
                }
            }
        }
        report.providers.push(DiscoveredProvider {
            provider: descriptor.id,
            state: if found.is_some() {
                InstallationState::Found
            } else {
                InstallationState::NotFound
            },
            executable: found,
        });
    }
    if report.path_missing
        || report.path_too_large
        || report.entries_truncated
        || report.skipped_relative_entries != 0
        || report.metadata_errors != 0
    {
        for entry in &mut report.providers {
            if entry.state == InstallationState::NotFound {
                entry.state = InstallationState::Indeterminate;
            }
        }
    }
    report
}

fn executable_suffixes() -> &'static [&'static str] {
    if cfg!(windows) {
        &["", ".exe", ".com", ".cmd", ".bat"]
    } else {
        &[""]
    }
}

fn executable_file(metadata: &std::fs::Metadata) -> bool {
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}
