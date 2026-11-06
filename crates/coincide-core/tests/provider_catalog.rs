use coincide_core::provider_catalog::*;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

fn path(directories: &[&Path]) -> OsString {
    std::env::join_paths(directories).unwrap()
}

fn executable(directory: &Path, name: &str) -> PathBuf {
    let file = directory.join(name);
    // Intentionally not a valid executable: discovery must only inspect metadata.
    std::fs::write(&file, b"not a program; never execute this fixture\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    file
}

fn entry(report: &DiscoveryReport, id: ProviderId) -> &DiscoveredProvider {
    report
        .providers
        .iter()
        .find(|row| row.provider == id)
        .unwrap()
}

#[test]
fn catalog_matches_six_legacy_provider_identities_and_transports() {
    let expected = [
        (
            ProviderId::Claude,
            "claude",
            "Claude Code",
            TransportKind::ClaudeStreamJsonStdio,
        ),
        (
            ProviderId::Codex,
            "codex",
            "Codex",
            TransportKind::CodexAppServerStdio,
        ),
        (
            ProviderId::Cursor,
            "cursor",
            "Cursor",
            TransportKind::AcpStdio,
        ),
        (
            ProviderId::Grok,
            "grok",
            "Grok Build",
            TransportKind::AcpStdio,
        ),
        (
            ProviderId::Opencode,
            "opencode",
            "OpenCode",
            TransportKind::OpenCodeHttpSse,
        ),
        (
            ProviderId::Antigravity,
            "antigravity",
            "Antigravity",
            TransportKind::AcpStdio,
        ),
    ];
    assert_eq!(provider_catalog().len(), expected.len());
    for (descriptor, (id, wire_id, display, transport)) in provider_catalog().iter().zip(expected) {
        assert_eq!(descriptor.id, id);
        assert_eq!(descriptor.display_name, display);
        assert_eq!(descriptor.transport, transport);
        assert_eq!(provider(id), descriptor);
        assert_eq!(serde_json::to_value(id).unwrap(), wire_id);
    }
    assert_eq!(
        provider(ProviderId::Antigravity).executable_candidates,
        &["agy_acp_server.par", "agy_acp_server"]
    );
    assert_eq!(
        provider(ProviderId::Cursor).executable_candidates,
        &["cursor-agent"]
    );
    let encoded = serde_json::to_value(provider_catalog()).unwrap();
    assert!(encoded[0].get("models").is_none());
}

#[test]
fn discovers_all_six_without_executing_fixture_contents() {
    let temp = tempfile::tempdir().unwrap();
    for descriptor in provider_catalog() {
        executable(temp.path(), descriptor.executable_candidates[0]);
    }
    let report = discover_on_path(Some(&path(&[temp.path()])), DiscoveryLimits::default());
    assert_eq!(report.providers.len(), 6);
    for descriptor in provider_catalog() {
        let found = entry(&report, descriptor.id);
        assert_eq!(found.state, InstallationState::Found);
        assert_eq!(
            found.executable.as_deref(),
            Some(
                temp.path()
                    .join(descriptor.executable_candidates[0])
                    .as_path()
            )
        );
    }
    assert_eq!(report.metadata_errors, 0);
}

#[test]
fn missing_tools_are_not_found_in_a_complete_search() {
    let temp = tempfile::tempdir().unwrap();
    let report = discover_on_path(
        Some(&path(&[temp.path(), &temp.path().join("missing")])),
        DiscoveryLimits::default(),
    );
    assert!(
        report
            .providers
            .iter()
            .all(|row| row.state == InstallationState::NotFound && row.executable.is_none())
    );
    assert_eq!(report.metadata_errors, 0);
}

#[test]
fn candidate_preference_then_path_precedence_matches_swift() {
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    let claude = executable(first.path(), "claude");
    executable(second.path(), "claude");
    executable(first.path(), "agy_acp_server");
    let antigravity = executable(second.path(), "agy_acp_server.par");
    let report = discover_on_path(
        Some(&path(&[first.path(), second.path()])),
        DiscoveryLimits::default(),
    );
    assert_eq!(entry(&report, ProviderId::Claude).executable, Some(claude));
    assert_eq!(
        entry(&report, ProviderId::Antigravity).executable,
        Some(antigravity)
    );
}

#[test]
fn directories_and_non_executable_files_are_not_installations() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::create_dir(temp.path().join("claude")).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let file = executable(temp.path(), "codex");
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    let report = discover_on_path(Some(&path(&[temp.path()])), DiscoveryLimits::default());
    assert_eq!(
        entry(&report, ProviderId::Claude).state,
        InstallationState::NotFound
    );
    assert_eq!(
        entry(&report, ProviderId::Codex).state,
        InstallationState::NotFound
    );
}

#[test]
fn limits_and_missing_path_do_not_claim_absence() {
    let temp = tempfile::tempdir().unwrap();
    executable(temp.path(), "claude");
    let supplied = path(&[temp.path()]);
    for limits in [
        DiscoveryLimits {
            max_path_bytes: 0,
            max_path_entries: MAX_PATH_ENTRIES,
        },
        DiscoveryLimits {
            max_path_bytes: MAX_PATH_BYTES,
            max_path_entries: 0,
        },
    ] {
        let report = discover_on_path(Some(&supplied), limits);
        assert_eq!(report.inspected_candidates, 0);
        assert!(report.path_too_large || report.entries_truncated);
        assert!(
            report
                .providers
                .iter()
                .all(|row| row.state == InstallationState::Indeterminate)
        );
    }
    let report = discover_on_path(None, DiscoveryLimits::default());
    assert!(report.path_missing);
    assert_eq!(report.inspected_candidates, 0);
    assert!(
        report
            .providers
            .iter()
            .all(|row| row.state == InstallationState::Indeterminate)
    );
}

#[test]
fn entries_beyond_limit_are_not_inspected_and_found_results_survive_truncation() {
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    executable(first.path(), "claude");
    executable(second.path(), "codex");
    let report = discover_on_path(
        Some(&path(&[first.path(), second.path()])),
        DiscoveryLimits {
            max_path_entries: 1,
            ..DiscoveryLimits::default()
        },
    );
    assert!(report.entries_truncated);
    assert_eq!(
        entry(&report, ProviderId::Claude).state,
        InstallationState::Found
    );
    assert_eq!(
        entry(&report, ProviderId::Codex).state,
        InstallationState::Indeterminate
    );
}

#[test]
fn relative_and_empty_entries_are_skipped_without_environment_mutation() {
    let supplied = path(&[Path::new(""), Path::new("."), Path::new("relative")]);
    let report = discover_on_path(Some(&supplied), DiscoveryLimits::default());
    assert_eq!(report.skipped_relative_entries, 3);
    assert_eq!(report.inspected_candidates, 0);
    assert!(
        report
            .providers
            .iter()
            .all(|row| row.state == InstallationState::Indeterminate)
    );
}

#[test]
fn hard_entry_cap_applies_even_to_duplicate_directories() {
    let temp = tempfile::tempdir().unwrap();
    let directories = vec![temp.path(); MAX_PATH_ENTRIES + 1];
    let report = discover_on_path(
        Some(&path(&directories)),
        DiscoveryLimits {
            max_path_bytes: usize::MAX,
            max_path_entries: usize::MAX,
        },
    );
    assert!(report.entries_truncated);
    // Deduplication avoids repeatedly checking the same files.
    assert_eq!(
        report.inspected_candidates,
        if cfg!(windows) { 35 } else { 7 }
    );
}

#[cfg(unix)]
#[test]
fn follows_valid_symlinks_and_ignores_broken_ones() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    let target = executable(temp.path(), "target");
    symlink(target, temp.path().join("claude")).unwrap();
    symlink(temp.path().join("missing"), temp.path().join("codex")).unwrap();
    let report = discover_on_path(Some(&path(&[temp.path()])), DiscoveryLimits::default());
    assert_eq!(
        entry(&report, ProviderId::Claude).state,
        InstallationState::Found
    );
    assert_eq!(
        entry(&report, ProviderId::Codex).state,
        InstallationState::NotFound
    );
}

#[cfg(windows)]
#[test]
fn finds_fixed_windows_suffixes_without_pathext_or_shell_evaluation() {
    let temp = tempfile::tempdir().unwrap();
    let claude = executable(temp.path(), "claude.cmd");
    let codex = executable(temp.path(), "codex.exe");
    let report = discover_on_path(Some(&path(&[temp.path()])), DiscoveryLimits::default());
    assert_eq!(entry(&report, ProviderId::Claude).executable, Some(claude));
    assert_eq!(entry(&report, ProviderId::Codex).executable, Some(codex));
}

#[test]
fn oversized_input_is_rejected_even_when_caller_requests_unlimited_scan() {
    let supplied = OsString::from("x".repeat(MAX_PATH_BYTES + 1));
    let report = discover_on_path(
        Some(&supplied),
        DiscoveryLimits {
            max_path_bytes: usize::MAX,
            max_path_entries: usize::MAX,
        },
    );
    assert!(report.path_too_large);
    assert_eq!(report.inspected_candidates, 0);
    assert!(
        report
            .providers
            .iter()
            .all(|row| row.state == InstallationState::Indeterminate)
    );
}

#[test]
fn alternate_antigravity_name_is_discovered_without_requiring_runtime_helper() {
    let temp = tempfile::tempdir().unwrap();
    let executable = executable(temp.path(), "agy_acp_server");
    let report = discover_on_path(Some(&path(&[temp.path()])), DiscoveryLimits::default());
    assert_eq!(
        entry(&report, ProviderId::Antigravity).executable,
        Some(executable)
    );
    // Discovery does not assert that this incomplete runtime is usable.
    let json = serde_json::to_value(&report).unwrap();
    assert!(json["providers"][5].get("ready").is_none());
    assert!(json["providers"][5].get("version").is_none());
    assert!(json["providers"][5].get("models").is_none());
}

#[cfg(unix)]
#[test]
fn filesystem_errors_make_negative_results_indeterminate() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    // ELOOP is deterministic even for privileged test users, unlike chmod denial.
    symlink("claude", temp.path().join("claude")).unwrap();
    let report = discover_on_path(Some(&path(&[temp.path()])), DiscoveryLimits::default());
    assert!(report.metadata_errors > 0);
    assert_eq!(
        entry(&report, ProviderId::Claude).state,
        InstallationState::Indeterminate
    );
}
