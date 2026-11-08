//! Acceptance-only: run the production preview updater's HTTPS check and
//! download stage against a configured feed, then verify the extracted app with
//! the real Developer ID/Gatekeeper adapter. Not an app entry, release path or
//! installation authorization; the app has no configured update channel.
//!
//! Run explicitly:
//! `updater_stage_e2e FEED ARTIFACT_BASE TEAM_ID CURRENT_VERSION CACHE_ROOT`
use anyhow::{Context, Result, ensure};
use coincide_core::updater::{
    Architecture, Config, Dependencies, Limits, Operation, Platform, Release, RequestPolicy,
    SignatureStatus, State, SystemDiskSpace, Transport, TrustReport, TrustVerifier, Updater,
    UreqTransport, ZipExtractor,
};
use coincide_core::updater_install::{BundleVerifier, MacCodeVerifier};
use std::{
    collections::BTreeSet,
    io::Write,
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};
use url::Url;

/// The updater hands trust verification the extraction root; the signed bundle
/// is the fixed preview app inside it.
struct MacPreviewTrust;
impl TrustVerifier for MacPreviewTrust {
    fn verify(
        &self,
        root: &Path,
        release: &Release,
        anchor: &str,
        _context: &coincide_core::updater::OperationContext,
    ) -> Result<TrustReport> {
        let bundle = root.join("Coincide Rust.app");
        let identity = MacCodeVerifier
            .verify(&bundle, anchor, release.architecture)
            .context("Developer ID/Gatekeeper verification failed")?;
        println!(
            "verified bundle: {} {} {:?} anchor {}",
            identity.bundle_id, identity.version, identity.architecture, identity.anchor
        );
        Ok(TrustReport {
            bundle_id: identity.bundle_id,
            version: identity.version,
            platform: release.platform,
            architecture: identity.architecture,
            signature: SignatureStatus::Verified,
        })
    }
}

/// A thin transport wrapper so the run reports what the real adapter fetched.
struct ReportingTransport;
impl Transport for ReportingTransport {
    fn fetch(
        &self,
        url: &Url,
        policy: &RequestPolicy,
        output: &mut dyn Write,
        context: &coincide_core::updater::OperationContext,
    ) -> Result<coincide_core::updater::Response> {
        println!("fetch {url}");
        UreqTransport.fetch(url, policy, output, context)
    }
}

fn wait(operation: Operation) -> Result<State> {
    let deadline = Instant::now() + Duration::from_secs(600);
    loop {
        if let Some(state) = operation.try_result() {
            return Ok(state);
        }
        ensure!(Instant::now() < deadline, "operation exceeded 10 minutes");
        thread::sleep(Duration::from_millis(200));
    }
}

fn main() -> Result<()> {
    let args = std::env::args().collect::<Vec<_>>();
    ensure!(
        args.len() == 6,
        "usage: updater_stage_e2e FEED ARTIFACT_BASE TEAM_ID CURRENT_VERSION CACHE_ROOT"
    );
    let feed = Url::parse(&args[1])?;
    let artifact_base = Url::parse(&args[2])?;
    ensure!(
        artifact_base.path().ends_with('/'),
        "artifact base must end with /"
    );
    let host = feed.host_str().context("feed host missing")?.to_owned();
    ensure!(
        artifact_base.host_str() == Some(host.as_str()),
        "feed and artifact hosts must match"
    );
    let cache_root = PathBuf::from(&args[5]);
    std::fs::create_dir_all(&cache_root)?;
    let config = Config {
        feed,
        artifact_base,
        trust_anchor: args[3].clone(),
        current_version: args[4].clone(),
        platform: Platform::Macos,
        architecture: Architecture::Arm64,
        cache_root,
        allowed_hosts: BTreeSet::from([host]),
        limits: Limits::default(),
    };
    let dependencies = Dependencies {
        transport: std::sync::Arc::new(ReportingTransport),
        extractor: std::sync::Arc::new(ZipExtractor),
        disk: std::sync::Arc::new(SystemDiskSpace),
        trust: std::sync::Arc::new(MacPreviewTrust),
    };
    let updater = Updater::configured(config, dependencies)?;
    let checked = wait(updater.check()?)?;
    println!("check: {checked:?}");
    match checked {
        State::Available(release) => {
            println!(
                "available: {} {:?} {} bytes sha {}",
                release.version, release.architecture, release.size, release.sha256
            );
            let staged = wait(updater.download_available()?)?;
            println!("stage: {staged:?}");
            match staged {
                State::Staged(stage) => {
                    ensure!(!stage.install_authorized, "unexpected install grant");
                    ensure!(
                        stage.signature == SignatureStatus::Verified,
                        "signature not verified"
                    );
                    ensure!(stage.archive_sha256_verified, "archive hash not verified");
                    println!(
                        "STAGED_OK job={} version={} signature=verified install_authorized=false",
                        stage.job.display(),
                        stage.release.version
                    );
                }
                other => anyhow::bail!("stage did not complete: {other:?}"),
            }
        }
        other => anyhow::bail!("check did not offer an update: {other:?}"),
    }
    Ok(())
}
