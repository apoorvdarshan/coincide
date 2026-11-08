//! Trusted native startup configuration for the preview update channel. The
//! channel exists only when the launcher supplies all three feed/base/anchor
//! variables; nothing here is reachable from an API, settings or page request.
//! Install-on-Quit additionally requires an explicit enable value, so a normal
//! preview run can check and download without arming replacement.
use crate::updater_lifecycle::{HelperLauncher, NativePolicy, UnavailableHelper};
use crate::updater_settings::UpdaterSettings;

pub(crate) struct Mount {
    pub settings: UpdaterSettings,
    pub policy: Option<NativePolicy>,
    pub launcher: Box<dyn HelperLauncher>,
}

impl Mount {
    pub fn disabled() -> Self {
        Self {
            settings: UpdaterSettings::new(Default::default()),
            policy: None,
            launcher: Box::new(UnavailableHelper),
        }
    }

    #[cfg(all(target_os = "macos", feature = "preview-updater-helper"))]
    pub fn prepare() -> Self {
        match configured() {
            Ok(mount) => mount,
            Err(error) => {
                eprintln!("Preview update channel unavailable: {error}");
                Self::disabled()
            }
        }
    }

    #[cfg(not(all(target_os = "macos", feature = "preview-updater-helper")))]
    pub fn prepare() -> Self {
        Self::disabled()
    }
}

#[cfg(all(target_os = "macos", feature = "preview-updater-helper"))]
fn configured() -> anyhow::Result<Mount> {
    use crate::updater_helper_transport::{
        NativeWorkerFactory, TransportConfig, TransportLauncher, TransportTimeouts,
    };
    use anyhow::{Context, Result, bail, ensure};
    use coincide_core::updater::{
        Architecture, Config, Dependencies, Limits, Platform, SignatureStatus, SystemDiskSpace,
        TrustReport, TrustVerifier, Updater, UreqTransport, ZipExtractor,
    };
    use coincide_core::updater_install::{BundleVerifier, MacCodeVerifier};
    use std::{
        collections::BTreeSet, os::unix::fs::PermissionsExt, path::Path, sync::Arc, time::Duration,
    };
    use url::Url;

    let feed = std::env::var("COINCIDE_RUST_UPDATE_FEED")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let artifact_base = std::env::var("COINCIDE_RUST_UPDATE_ARTIFACT_BASE")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let anchor = std::env::var("COINCIDE_RUST_UPDATE_ANCHOR")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let (Some(feed), Some(artifact_base), Some(anchor)) = (feed, artifact_base, anchor) else {
        return Ok(Mount::disabled());
    };
    let feed = Url::parse(&feed).context("Invalid preview update feed URL")?;
    let artifact_base =
        Url::parse(&artifact_base).context("Invalid preview update artifact base URL")?;
    ensure!(
        artifact_base.path().ends_with('/'),
        "Preview update artifact base must end with /"
    );
    let host = feed
        .host_str()
        .context("Preview update feed has no host")?
        .to_owned();
    ensure!(
        artifact_base.host_str() == Some(host.as_str()),
        "Preview update feed and artifact hosts must match"
    );
    coincide_core::updater_helper::helper_requirement(&anchor)?;

    let target = app_bundle()?;
    let installed_version = app_version(&target)?;
    let current = std::env::current_exe()?.canonicalize()?;
    ensure!(
        current == target.join("Contents/MacOS/coincide-rust"),
        "Running executable is not the configured preview app"
    );
    let cache_root = coincide_core::control::data_directory()?.join("Updates");
    std::fs::create_dir_all(&cache_root)?;
    std::fs::set_permissions(&cache_root, std::fs::Permissions::from_mode(0o700))?;
    // The independent helper requires these private roots to exist before its
    // installer configuration can canonicalize them.
    for name in ["transactions", "helpers"] {
        let path = cache_root.join(name);
        std::fs::create_dir_all(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))?;
    }
    let architecture = match std::env::consts::ARCH {
        "aarch64" => Architecture::Arm64,
        "x86_64" => Architecture::X86_64,
        other => bail!("Unsupported preview update architecture: {other}"),
    };
    let config = Config {
        feed,
        artifact_base,
        trust_anchor: anchor.clone(),
        current_version: installed_version.clone(),
        platform: Platform::Macos,
        architecture,
        cache_root,
        allowed_hosts: BTreeSet::from([host]),
        limits: Limits::default(),
    };
    /// The channel hands trust verification the extraction root; the fixed
    /// preview app is the bundle inside it.
    struct CandidateTrust;
    impl TrustVerifier for CandidateTrust {
        fn verify(
            &self,
            root: &Path,
            release: &coincide_core::updater::Release,
            anchor: &str,
            _context: &coincide_core::updater::OperationContext,
        ) -> Result<TrustReport> {
            let identity = MacCodeVerifier.verify(
                &root.join("Coincide Rust.app"),
                anchor,
                release.architecture,
            )?;
            Ok(TrustReport {
                bundle_id: identity.bundle_id,
                version: identity.version,
                platform: release.platform,
                architecture: identity.architecture,
                signature: SignatureStatus::Verified,
            })
        }
    }
    let dependencies = Dependencies {
        transport: Arc::new(UreqTransport),
        extractor: Arc::new(ZipExtractor),
        disk: Arc::new(SystemDiskSpace),
        trust: Arc::new(CandidateTrust),
    };
    let updater = Updater::configured(config, dependencies)?;
    let settings = UpdaterSettings::new(updater);

    let install_enabled =
        std::env::var("COINCIDE_RUST_UPDATE_ENABLE_INSTALL").as_deref() == Ok("1");
    if !install_enabled {
        return Ok(Mount {
            settings,
            policy: None,
            launcher: Box::new(UnavailableHelper),
        });
    }
    let policy = NativePolicy {
        target,
        anchor,
        installed_version,
        parent: coincide_core::updater_helper::current_parent_binding()?,
        handshake_timeout: Duration::from_secs(900),
        shutdown_timeout: Duration::from_secs(120),
    };
    let launcher = TransportLauncher::configured(
        TransportConfig {
            policy: policy.clone(),
            timeouts: TransportTimeouts::default(),
            command_capacity: 8,
            event_capacity: 8,
        },
        Arc::new(NativeWorkerFactory),
    )?;
    Ok(Mount {
        settings,
        policy: Some(policy),
        launcher: Box::new(launcher),
    })
}

#[cfg(all(target_os = "macos", feature = "preview-updater-helper"))]
fn app_bundle() -> anyhow::Result<std::path::PathBuf> {
    use anyhow::{Context, ensure};
    let executable = std::env::current_exe()?.canonicalize()?;
    let macos = executable
        .parent()
        .context("Preview executable has no Contents/MacOS parent")?;
    let contents = macos
        .parent()
        .context("Preview executable has no Contents")?;
    let app = contents
        .parent()
        .context("Preview executable has no app bundle")?;
    ensure!(
        app.file_name()
            .is_some_and(|name| name == "Coincide Rust.app"),
        "Preview update target must be Coincide Rust.app"
    );
    Ok(app.to_owned())
}

#[cfg(all(target_os = "macos", feature = "preview-updater-helper"))]
fn app_version(app: &std::path::Path) -> anyhow::Result<String> {
    use anyhow::{Context, ensure};
    use std::process::Command;
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", "CFBundleShortVersionString", "raw", "-o", "-"])
        .arg(app.join("Contents/Info.plist"))
        .output()?;
    ensure!(
        output.status.success(),
        "Preview app version metadata is unreadable"
    );
    let version = String::from_utf8(output.stdout)
        .context("Preview app version is not UTF-8")?
        .trim()
        .to_owned();
    ensure!(!version.is_empty(), "Preview app version is empty");
    Ok(version)
}
