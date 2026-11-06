//! Preview-only install-helper engine. No startup hook, binary, forced quit,
//! elevation, launch, signing, data migration, or deserializable authorization.
//!
//! Parent registers this module and supplies the native approval/shutdown bridge.
//! `MacCodeVerifier`, `MacProcessGuard` and `NativeExchange` contain real native
//! adapter code; fixtures inject their own verifier/UI/process controls. These
//! adapters are never called by construction. A future independent helper wrapper
//! must carry the opaque authorization over a trusted native channel; it must not
//! reconstruct it from an HTTP/CLI boolean or an arbitrary job/target path.
use crate::updater::{
    Architecture, DiskSpace, InstallCandidate, PREVIEW_ID, Platform, Release, Updater,
};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use uuid::Uuid;

#[cfg(target_os = "macos")]
use std::{
    ffi::OsString,
    process::{Command, Stdio},
    thread,
};

#[cfg(target_os = "macos")]
#[link(name = "proc")]
unsafe extern "C" {
    fn proc_pidpath(pid: libc::c_int, buffer: *mut libc::c_void, buffersize: u32) -> libc::c_int;
    fn proc_pidinfo(
        pid: libc::c_int,
        flavor: libc::c_int,
        arg: u64,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
    fn proc_listpids(
        kind: u32,
        typeinfo: u32,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
}

const APP: &str = "Coincide Rust.app";
#[cfg(any(target_os = "macos", test))]
const MAIN: &str = "coincide-rust";

#[derive(Clone)]
pub struct InstallConfig {
    /// Trusted native startup configuration, never a request parameter. Target
    /// is ALWAYS this parent/Coincide Rust.app, never the production Swift app.
    pub target_parent: PathBuf,
    /// Pinned by native startup configuration, never recovered from a mutable job.
    pub trust_anchor: String,
    pub reserve_disk_bytes: u64,
    /// Pre-existing owner-private transaction directory outside every app bundle.
    pub transaction_root: PathBuf,
    pub approval_lifetime: Duration,
    pub exit_timeout: Duration,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct BundleIdentity {
    pub bundle_id: String,
    pub version: String,
    pub architecture: Architecture,
    pub anchor: String,
}
/// Trusted native adapter boundary, NOT a user-supplied "verified" boolean.
/// Must validate code signatures/resources and independently read metadata.
pub trait BundleVerifier: Send + Sync {
    fn verify(
        &self,
        bundle: &Path,
        anchor: &str,
        architecture: Architecture,
    ) -> Result<BundleIdentity>;
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Proposal {
    pub transaction: Uuid,
    pub target: PathBuf,
    pub installed_version: String,
    pub release: Release,
    pub anchor: String,
    pub installed_tree: String,
    pub candidate_tree: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NativeDecision {
    Approve,
    Decline,
}
pub trait NativeApproval: Send + Sync {
    /// Present this immutable proposal in a native UI. Never expose this as a
    /// request-supplied decision. Signature verification happens independently.
    fn present(&self, proposal: &Proposal) -> Result<NativeDecision>;
}
pub struct UnavailableNativeApproval;
impl NativeApproval for UnavailableNativeApproval {
    fn present(&self, _: &Proposal) -> Result<NativeDecision> {
        bail!("Native update approval UI is unavailable")
    }
}
pub trait ShutdownBarrier {
    /// Native app lifecycle must stop admission/providers/terminals/schedules,
    /// flush persistent/UI state and fail if it cannot establish a clean quit.
    fn quiesce_and_flush(&self, proposal: &Proposal) -> Result<()>;
}
pub struct UnavailableShutdownBarrier;
impl ShutdownBarrier for UnavailableShutdownBarrier {
    fn quiesce_and_flush(&self, _: &Proposal) -> Result<()> {
        bail!("Native shutdown/flush bridge is unavailable")
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ParentBinding {
    pub pid: u32,
    pub start_seconds: u64,
    pub start_micros: u64,
}
pub trait ParentWatch: Send {
    fn binding(&self) -> ParentBinding;
    /// Exact registered process must exit normally with status zero. Not just ESRCH.
    fn wait_clean_exit(&mut self, timeout: Duration) -> Result<()>;
}
pub trait ProcessGuard: Send + Sync {
    /// Helper-side call: bind the helper's actual parent executable and start time,
    /// then register observation BEFORE the wrapper reports READY to its parent.
    fn observe_parent(&self, target: &Path) -> Result<Box<dyn ParentWatch>>;
    fn ensure_stopped(&self, target: &Path) -> Result<()>;
}
pub trait Exchange: Send + Sync {
    /// Atomic same-volume exchange; never implement as remove+rename or copy over target.
    fn swap(&self, target: &Path, replacement: &Path) -> Result<()>;
}
#[derive(Clone)]
pub struct InstallDependencies {
    pub verifier: Arc<dyn BundleVerifier>,
    pub approval: Arc<dyn NativeApproval>,
    pub processes: Arc<dyn ProcessGuard>,
    pub exchange: Arc<dyn Exchange>,
    pub disk: Arc<dyn DiskSpace>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum Phase {
    Armed,
    CandidateCopied,
    Exchanging,
    Exchanged,
    Committed,
    RollbackPending,
    RolledBack,
    Cancelled,
    RecoveryRequired,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Journal {
    format: u8,
    proposal: Proposal,
    proposal_sha256: String,
    nonce: Uuid,
    parent: ParentBinding,
    phase: Phase,
}
#[derive(Serialize, Deserialize)]
struct Consent {
    transaction: Uuid,
    proposal_sha256: String,
    nonce: Uuid,
}
/// No Clone/Deserialize/public fields: this capability is minted only after fresh
/// verification and a native adapter's approval of the exact proposal.
pub struct AuthorizedInstall {
    candidate: InstallCandidate,
    proposal: Proposal,
    expires: Instant,
    owner: Uuid,
}
impl AuthorizedInstall {
    pub fn proposal(&self) -> &Proposal {
        &self.proposal
    }
}
pub struct ArmedInstall {
    candidate: InstallCandidate,
    journal: Journal,
    directory: PathBuf,
    watch: Box<dyn ParentWatch>,
    owner: Uuid,
    active: Arc<Mutex<Option<Uuid>>>,
    _target_lock: TargetLock,
}
impl Drop for ArmedInstall {
    fn drop(&mut self) {
        if let Ok(mut active) = self.active.lock()
            && *active == Some(self.transaction())
        {
            *active = None;
        }
    }
}
impl ArmedInstall {
    pub fn transaction(&self) -> Uuid {
        self.journal.proposal.transaction
    }
    pub fn parent_binding(&self) -> ParentBinding {
        self.journal.parent.clone()
    }
    /// Call only from the actual native app termination lifecycle. This method
    /// invokes the bridge; it never accepts a user boolean claiming persistence.
    pub fn authorize_clean_quit(&self, barrier: &dyn ShutdownBarrier) -> Result<()> {
        barrier.quiesce_and_flush(&self.journal.proposal)?;
        let consent = Consent {
            transaction: self.transaction(),
            proposal_sha256: self.journal.proposal_sha256.clone(),
            nonce: self.journal.nonce,
        };
        write_new_json(&self.directory.join("clean-quit.json"), &consent)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InstallOutcome {
    Installed {
        transaction: Uuid,
        backup: PathBuf,
        receipt_warning: Option<String>,
    },
    RolledBack {
        transaction: Uuid,
        retained_candidate: PathBuf,
        reason: String,
    },
    NotInstalled {
        transaction: Uuid,
        reason: String,
    },
    RecoveryRequired {
        transaction: Uuid,
        backup: PathBuf,
        reason: String,
    },
}
// Fixed operation categories, never populated from native errors or paths.
#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "kebab-case")]
enum DiagnosticStage {
    ParentExitProof,
    ConsentBinding,
    StoppedTargetProof,
    InstalledIdentity,
    CandidateIdentity,
    DestinationPreparation,
    DestinationDisk,
    CandidateCopy,
    CopiedIdentity,
    CopyJournal,
    StoppedTargetRecheck,
    InstalledIdentityRecheck,
    CopiedIdentityRecheck,
    ExchangeJournal,
    Exchange,
    ExchangeDurability,
    ExchangedJournal,
    PostExchangeIdentity,
    RollbackStoppedTargetProof,
    RollbackBackupIdentity,
    RollbackJournal,
    RollbackExchange,
    RollbackDurability,
    RollbackIdentity,
    RollbackReceipt,
    FinalVerification,
    FinalReceipt,
}
// Diagnostic only: never deserialized or consulted by install/recovery paths.
#[derive(Serialize)]
struct OutcomeDiagnostic {
    format: u8,
    transaction: Uuid,
    outcome: &'static str,
    stage: DiagnosticStage,
    reason: &'static str,
}
impl InstallOutcome {
    fn diagnostic(&self, stage: DiagnosticStage) -> OutcomeDiagnostic {
        let (transaction, outcome, reason) = match self {
            Self::Installed { transaction, .. } => (
                *transaction,
                "Installed",
                "Verified replacement installed; previous bundle retained",
            ),
            Self::RolledBack { transaction, .. } => (
                *transaction,
                "RolledBack",
                "Replacement rejected; previous target restored",
            ),
            Self::NotInstalled { transaction, .. } => (
                *transaction,
                "NotInstalled",
                "Replacement was not installed; inspect retained transaction state",
            ),
            Self::RecoveryRequired { transaction, .. } => (
                *transaction,
                "RecoveryRequired",
                "Exchange state requires inspection; retained bundles must not be retried automatically",
            ),
        };
        OutcomeDiagnostic {
            format: 1,
            transaction,
            outcome,
            stage,
            reason,
        }
    }
    fn warn_diagnostic_unavailable(&mut self) {
        const WARNING: &str =
            "Outcome diagnostic could not be persisted; actual outcome is unchanged";
        match self {
            Self::Installed {
                receipt_warning, ..
            } => match receipt_warning {
                Some(previous) => {
                    previous.push_str("; ");
                    previous.push_str(WARNING);
                }
                None => *receipt_warning = Some(WARNING.into()),
            },
            Self::RolledBack { reason, .. }
            | Self::NotInstalled { reason, .. }
            | Self::RecoveryRequired { reason, .. } => {
                reason.push_str("; ");
                reason.push_str(WARNING);
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecoveryAccounting {
    NotExchanged {
        phase: Phase,
        retained_candidate: Option<PathBuf>,
    },
    InstalledWithBackup {
        phase: Phase,
        backup: PathBuf,
    },
    RestoredOldTarget {
        phase: Phase,
        retained_candidate: PathBuf,
    },
    Ambiguous {
        phase: Phase,
        target: PathBuf,
        backup: PathBuf,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Checkpoint {
    AfterArm,
    AfterCopy,
    BeforeSwap,
    AfterSwap,
    AfterVerify,
    BeforeCommit,
    BeforeRollback,
    AfterRollback,
}
#[derive(Clone)]
pub struct Installer {
    config: InstallConfig,
    dependencies: InstallDependencies,
    owner: Uuid,
    // Keep one runtime transaction in flight. Recovery never replays a job.
    active: Arc<Mutex<Option<Uuid>>>,
    #[cfg(test)]
    fault: Option<Arc<dyn Fn(Checkpoint) -> Result<()> + Send + Sync>>,
}
impl Installer {
    pub fn configured(
        mut config: InstallConfig,
        dependencies: InstallDependencies,
    ) -> Result<Self> {
        ensure!(
            !config.approval_lifetime.is_zero()
                && config.approval_lifetime <= Duration::from_secs(15 * 60),
            "Invalid native approval lifetime"
        );
        ensure!(
            !config.exit_timeout.is_zero()
                && config.exit_timeout <= Duration::from_secs(7 * 24 * 60 * 60),
            "Invalid parent-exit timeout"
        );
        ensure!(
            !config.trust_anchor.trim().is_empty(),
            "Pinned native trust anchor required"
        );
        ensure!(
            !config
                .target_parent
                .ancestors()
                .any(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("app"))),
            "Target parent cannot be inside any app bundle"
        );
        no_symlinks(&config.target_parent)?;
        no_symlinks(&config.transaction_root)?;
        ensure!(
            config.target_parent.is_dir(),
            "Existing target parent required"
        );
        private_directory(&config.transaction_root)?;
        config.target_parent = config.target_parent.canonicalize()?;
        config.transaction_root = config.transaction_root.canonicalize()?;
        let target = config.target_parent.join(APP);
        ensure!(
            !config.transaction_root.starts_with(&target),
            "Transactions cannot be stored inside the target app"
        );
        Ok(Self {
            config,
            dependencies,
            owner: Uuid::new_v4(),
            active: Arc::new(Mutex::new(None)),
            #[cfg(test)]
            fault: None,
        })
    }
    pub fn target(&self) -> PathBuf {
        self.config.target_parent.join(APP)
    }
    fn backup(&self, id: Uuid) -> PathBuf {
        self.config
            .target_parent
            .join(format!(".Coincide-Rust-backup-{id}.app"))
    }
    fn transaction_dir(&self, id: Uuid) -> PathBuf {
        self.config.transaction_root.join(id.to_string())
    }
    fn checkpoint(&self, point: Checkpoint) -> Result<()> {
        #[cfg(test)]
        if let Some(fault) = &self.fault {
            fault(point)?;
        }
        let _ = point;
        Ok(())
    }
    /// Native caller chooses only the service, never an artifact/target/hash path.
    /// The opaque result is one-use and bound to this Installer instance.
    pub fn request_native_authorization(
        &self,
        updater: &Updater,
    ) -> Result<Option<AuthorizedInstall>> {
        ensure!(
            self.active
                .lock()
                .map_err(|_| anyhow::anyhow!("Install lock failed"))?
                .is_none(),
            "An install transaction is armed"
        );
        let candidate = updater.fresh_install_candidate()?;
        ensure!(
            candidate.anchor == self.config.trust_anchor,
            "Staged and native trust anchors differ"
        );
        ensure!(
            candidate.release.platform == Platform::Macos,
            "Only Rust preview app bundles are supported"
        );
        let target = self.target();
        no_symlinks(&target)?;
        let installed = self.dependencies.verifier.verify(
            &target,
            &candidate.anchor,
            candidate.release.architecture,
        )?;
        validate_identity(
            &installed,
            &candidate.current_version,
            &candidate.anchor,
            candidate.release.architecture,
        )?;
        let replacement = self.dependencies.verifier.verify(
            &candidate.bundle,
            &candidate.anchor,
            candidate.release.architecture,
        )?;
        validate_identity(
            &replacement,
            &candidate.release.version,
            &candidate.anchor,
            candidate.release.architecture,
        )?;
        ensure!(
            numeric_version(&replacement.version)? > numeric_version(&installed.version)?,
            "Only a newer preview version may be installed"
        );
        let proposal = Proposal {
            transaction: Uuid::new_v4(),
            target,
            installed_version: installed.version,
            release: candidate.release.clone(),
            anchor: candidate.anchor.clone(),
            installed_tree: fingerprint(&self.target())?,
            candidate_tree: fingerprint(&candidate.bundle)?,
        };
        if self.dependencies.approval.present(&proposal)? == NativeDecision::Decline {
            return Ok(None);
        }
        // Files may have changed while the native prompt was visible.
        ensure!(
            fingerprint(&self.target())? == proposal.installed_tree
                && fingerprint(&candidate.bundle)? == proposal.candidate_tree,
            "Bundle changed during native approval"
        );
        Ok(Some(AuthorizedInstall {
            candidate,
            proposal,
            expires: Instant::now() + self.config.approval_lifetime,
            owner: self.owner,
        }))
    }
    /// Independent-helper entry boundary. Observation is registered here; only
    /// after success may a wrapper report readiness to its actual parent.
    pub fn arm(&self, authorization: AuthorizedInstall) -> Result<ArmedInstall> {
        ensure!(
            authorization.owner == self.owner && Instant::now() < authorization.expires,
            "Native authorization expired or belongs to another installer"
        );
        ensure!(
            authorization.proposal.target == self.target(),
            "Native target binding differs"
        );
        let id = authorization.proposal.transaction;
        let mut active = self
            .active
            .lock()
            .map_err(|_| anyhow::anyhow!("Install lock failed"))?;
        ensure!(active.is_none(), "Install transaction already armed");
        let target_lock = target_lock(&self.config.target_parent, true)?;
        self.verify_tree(&self.target(), &authorization.proposal, false)?;
        self.verify_tree(
            &authorization.candidate.bundle,
            &authorization.proposal,
            true,
        )?;
        let watch = self.dependencies.processes.observe_parent(&self.target())?;
        let parent = watch.binding();
        ensure!(parent.pid > 1, "Invalid observed parent");
        let directory = self.transaction_dir(id);
        create_private_directory(&directory)?;
        let journal = Journal {
            format: 1,
            proposal_sha256: proposal_hash(&authorization.proposal)?,
            proposal: authorization.proposal,
            nonce: Uuid::new_v4(),
            parent,
            phase: Phase::Armed,
        };
        persist(&directory, &journal)?;
        self.checkpoint(Checkpoint::AfterArm)?;
        *active = Some(id);
        Ok(ArmedInstall {
            candidate: authorization.candidate,
            journal,
            directory,
            watch,
            owner: self.owner,
            active: self.active.clone(),
            _target_lock: target_lock,
        })
    }
    pub fn cancel(&self, mut armed: ArmedInstall) -> Result<()> {
        self.check_armed(&armed)?;
        armed.journal.phase = Phase::Cancelled;
        persist(&armed.directory, &armed.journal)?;
        let consent = armed.directory.join("clean-quit.json");
        if fs::symlink_metadata(&consent).is_ok() {
            fs::remove_file(consent)?;
            sync_directory(&armed.directory)?;
        }
        *self
            .active
            .lock()
            .map_err(|_| anyhow::anyhow!("Install lock failed"))? = None;
        Ok(())
    }
    fn check_armed(&self, armed: &ArmedInstall) -> Result<()> {
        ensure!(
            armed.owner == self.owner
                && armed.journal.proposal.target == self.target()
                && *self
                    .active
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Install lock failed"))?
                    == Some(armed.transaction()),
            "Install capability is not active for this target"
        );
        Ok(())
    }
    fn verify_tree(&self, path: &Path, proposal: &Proposal, new: bool) -> Result<()> {
        no_symlinks(path)?;
        let identity = self.dependencies.verifier.verify(
            path,
            &proposal.anchor,
            proposal.release.architecture,
        )?;
        validate_identity(
            &identity,
            if new {
                &proposal.release.version
            } else {
                &proposal.installed_version
            },
            &proposal.anchor,
            proposal.release.architecture,
        )?;
        ensure!(
            fingerprint(path)?
                == if new {
                    proposal.candidate_tree.as_str()
                } else {
                    proposal.installed_tree.as_str()
                },
            "Verified bundle fingerprint changed"
        );
        Ok(())
    }
    /// Never terminates/relaunches a target. A typed native approval, registered
    /// clean parent exit, matching post-flush consent, signature checks and stopped
    /// target checks all precede any write beside the target.
    pub fn run_helper(&self, mut armed: ArmedInstall) -> Result<InstallOutcome> {
        self.check_armed(&armed)?;
        let id = armed.transaction();
        let mut diagnostic_stage = DiagnosticStage::ParentExitProof;
        let result = (|| -> Result<InstallOutcome> {
            armed.watch.wait_clean_exit(self.config.exit_timeout)?;
            diagnostic_stage = DiagnosticStage::ConsentBinding;
            let consent: Consent = read_json(&armed.directory.join("clean-quit.json"))?;
            ensure!(
                consent.transaction == id
                    && consent.proposal_sha256 == armed.journal.proposal_sha256
                    && consent.nonce == armed.journal.nonce,
                "Clean quit consent does not bind this native authorization"
            );
            diagnostic_stage = DiagnosticStage::StoppedTargetProof;
            self.dependencies.processes.ensure_stopped(&self.target())?;
            diagnostic_stage = DiagnosticStage::InstalledIdentity;
            self.verify_tree(&self.target(), &armed.journal.proposal, false)?;
            diagnostic_stage = DiagnosticStage::CandidateIdentity;
            self.verify_tree(&armed.candidate.bundle, &armed.journal.proposal, true)?;
            diagnostic_stage = DiagnosticStage::DestinationPreparation;
            let backup = self.backup(id);
            ensure!(
                fs::symlink_metadata(&backup)
                    .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
                "Replacement/backup path already exists"
            );
            diagnostic_stage = DiagnosticStage::DestinationDisk;
            let required = files(&armed.candidate.bundle)?.values().try_fold(
                self.config.reserve_disk_bytes,
                |total, path| -> Result<u64> {
                    total
                        .checked_add(fs::metadata(path)?.len())
                        .context("Replacement disk budget overflow")
                },
            )?;
            ensure!(
                self.dependencies
                    .disk
                    .available_bytes(&self.config.target_parent)?
                    >= required,
                "Insufficient destination-volume disk space"
            );
            diagnostic_stage = DiagnosticStage::CandidateCopy;
            copy_bundle(&armed.candidate.bundle, &backup)?;
            diagnostic_stage = DiagnosticStage::CopiedIdentity;
            self.verify_tree(&backup, &armed.journal.proposal, true)?;
            diagnostic_stage = DiagnosticStage::CopyJournal;
            armed.journal.phase = Phase::CandidateCopied;
            persist(&armed.directory, &armed.journal)?;
            self.checkpoint(Checkpoint::AfterCopy)?;
            diagnostic_stage = DiagnosticStage::StoppedTargetRecheck;
            self.dependencies.processes.ensure_stopped(&self.target())?;
            diagnostic_stage = DiagnosticStage::InstalledIdentityRecheck;
            self.verify_tree(&self.target(), &armed.journal.proposal, false)?;
            diagnostic_stage = DiagnosticStage::CopiedIdentityRecheck;
            self.verify_tree(&backup, &armed.journal.proposal, true)?;
            diagnostic_stage = DiagnosticStage::ExchangeJournal;
            armed.journal.phase = Phase::Exchanging;
            persist(&armed.directory, &armed.journal)?;
            self.checkpoint(Checkpoint::BeforeSwap)?;
            diagnostic_stage = DiagnosticStage::Exchange;
            if self
                .dependencies
                .exchange
                .swap(&self.target(), &backup)
                .is_err()
            {
                armed.journal.phase = Phase::RecoveryRequired;
                let _ = persist(&armed.directory, &armed.journal);
                return Ok(InstallOutcome::RecoveryRequired {
                    transaction: id,
                    backup,
                    reason: "Atomic exchange failed; inspect both retained bundles".into(),
                });
            }
            diagnostic_stage = DiagnosticStage::ExchangeDurability;
            sync_directory(&self.config.target_parent)?;
            self.checkpoint(Checkpoint::AfterSwap)?;
            diagnostic_stage = DiagnosticStage::ExchangedJournal;
            armed.journal.phase = Phase::Exchanged;
            persist(&armed.directory, &armed.journal)?;
            diagnostic_stage = DiagnosticStage::PostExchangeIdentity;
            if self
                .verify_tree(&self.target(), &armed.journal.proposal, true)
                .is_err()
            {
                // Do not exchange a changed/unknown backup back into the install.
                diagnostic_stage = DiagnosticStage::RollbackStoppedTargetProof;
                self.dependencies.processes.ensure_stopped(&self.target())?;
                diagnostic_stage = DiagnosticStage::RollbackBackupIdentity;
                self.verify_tree(&backup, &armed.journal.proposal, false)?;
                diagnostic_stage = DiagnosticStage::RollbackJournal;
                armed.journal.phase = Phase::RollbackPending;
                persist(&armed.directory, &armed.journal)?;
                self.checkpoint(Checkpoint::BeforeRollback)?;
                diagnostic_stage = DiagnosticStage::RollbackExchange;
                if self
                    .dependencies
                    .exchange
                    .swap(&self.target(), &backup)
                    .is_err()
                {
                    armed.journal.phase = Phase::RecoveryRequired;
                    let _ = persist(&armed.directory, &armed.journal);
                    return Ok(InstallOutcome::RecoveryRequired {
                        transaction: id,
                        backup,
                        reason:
                            "Post-exchange verification and rollback failed; both bundles retained"
                                .into(),
                    });
                }
                diagnostic_stage = DiagnosticStage::RollbackDurability;
                sync_directory(&self.config.target_parent)?;
                self.checkpoint(Checkpoint::AfterRollback)?;
                diagnostic_stage = DiagnosticStage::RollbackIdentity;
                self.verify_tree(&self.target(), &armed.journal.proposal, false)?;
                diagnostic_stage = DiagnosticStage::RollbackReceipt;
                armed.journal.phase = Phase::RolledBack;
                persist(&armed.directory, &armed.journal)?;
                return Ok(InstallOutcome::RolledBack {
                    transaction: id,
                    retained_candidate: backup,
                    reason: "New target verification failed; previous target restored".into(),
                });
            }
            diagnostic_stage = DiagnosticStage::FinalVerification;
            self.checkpoint(Checkpoint::AfterVerify)?;
            // A receipt is diagnostic: never misreport a completed verified exchange
            // as a failed installation solely because this write failed.
            diagnostic_stage = DiagnosticStage::FinalReceipt;
            armed.journal.phase = Phase::Committed;
            let receipt = self
                .checkpoint(Checkpoint::BeforeCommit)
                .and_then(|()| persist(&armed.directory, &armed.journal));
            Ok(InstallOutcome::Installed {
                transaction: id,
                backup,
                receipt_warning: receipt
                    .err()
                    .map(|_| "Installed; final receipt could not be persisted".into()),
            })
        })();
        *self
            .active
            .lock()
            .map_err(|_| anyhow::anyhow!("Install lock failed"))? = None;
        let mut outcome = match result {
            Ok(outcome) => outcome,
            Err(error) => {
                let backup = self.backup(id);
                let exchanged = matches!(
                    armed.journal.phase,
                    Phase::Exchanging
                        | Phase::Exchanged
                        | Phase::RollbackPending
                        | Phase::RecoveryRequired
                        | Phase::Committed
                );
                if exchanged {
                    InstallOutcome::RecoveryRequired {
                        transaction: id,
                        backup,
                        reason: format!("Transaction interrupted: {error}"),
                    }
                } else {
                    InstallOutcome::NotInstalled {
                        transaction: id,
                        reason: error.to_string(),
                    }
                }
            }
        };
        // This record cannot authorize exchange, rollback, consent or recovery.
        // A write failure must preserve the actual filesystem outcome and never
        // cause callers to retry a completed exchange as an installation failure.
        if persist_outcome(&armed.directory, &outcome.diagnostic(diagnostic_stage)).is_err() {
            outcome.warn_diagnostic_unavailable();
        }
        Ok(outcome)
    }
    /// Read-only crash accounting. UUID is the sole selector; target and backup
    /// paths are derived from native configuration. No journal path is executed.
    /// This NEVER resumes an install or authorizes a rollback on restart.
    pub fn account_recovery(&self, id: Uuid) -> Result<RecoveryAccounting> {
        let directory = self.transaction_dir(id);
        private_directory(&directory)?;
        let journal: Journal = read_json(&directory.join("journal.json"))?;
        let _target_lock = target_lock(&self.config.target_parent, false)?;
        ensure!(
            journal.format == 1
                && journal.proposal.transaction == id
                && journal.proposal.target == self.target()
                && journal.proposal_sha256 == proposal_hash(&journal.proposal)?
                && journal.proposal.anchor == self.config.trust_anchor,
            "Recovery journal identity differs"
        );
        let backup = self.backup(id);
        let old = self
            .verify_tree(&self.target(), &journal.proposal, false)
            .is_ok();
        let new = self
            .verify_tree(&self.target(), &journal.proposal, true)
            .is_ok();
        let backup_old = self.verify_tree(&backup, &journal.proposal, false).is_ok();
        let backup_new = self.verify_tree(&backup, &journal.proposal, true).is_ok();
        if new && backup_old {
            return Ok(RecoveryAccounting::InstalledWithBackup {
                phase: journal.phase,
                backup,
            });
        }
        if old && backup_new {
            return if matches!(journal.phase, Phase::RolledBack | Phase::RollbackPending) {
                Ok(RecoveryAccounting::RestoredOldTarget {
                    phase: journal.phase,
                    retained_candidate: backup,
                })
            } else {
                Ok(RecoveryAccounting::NotExchanged {
                    phase: journal.phase,
                    retained_candidate: Some(backup),
                })
            };
        }
        if old
            && fs::symlink_metadata(&backup)
                .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
        {
            return Ok(RecoveryAccounting::NotExchanged {
                phase: journal.phase,
                retained_candidate: None,
            });
        }
        Ok(RecoveryAccounting::Ambiguous {
            phase: journal.phase,
            target: self.target(),
            backup,
        })
    }
}

// Persistent lock inode is never unlinked: deleting it could let another helper
// lock a replacement inode and race an already-held lock on the original.
struct TargetLock {
    _file: File,
}
impl Drop for TargetLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            // A concurrent fork can inherit this open-file description until
            // CLOEXEC. Close alone would leave our lease held by that copy.
            // Explicit unlock releases only this description's transaction lock.
            // SAFETY: the owned file descriptor remains live through this Drop.
            while unsafe { libc::flock(self._file.as_raw_fd(), libc::LOCK_UN) } != 0 {
                if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                    break;
                }
            }
        }
    }
}
fn target_lock(parent: &Path, create: bool) -> Result<TargetLock> {
    no_symlinks(parent)?;
    let path = parent.join(".Coincide-Rust-update.lock");
    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(true)
        .create(create)
        .truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        let file = options.open(path)?;
        let metadata = file.metadata()?;
        ensure!(
            metadata.is_file()
                && metadata.nlink() == 1
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0,
            "Target lock must be an owned private regular file"
        );
        // SAFETY: flock receives a valid live file descriptor, no borrowed pointers.
        use std::os::fd::AsRawFd;
        ensure!(
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "Another helper owns the native target transaction lock"
        );
        Ok(TargetLock { _file: file })
    }
    #[cfg(not(unix))]
    {
        let _ = (options, path);
        bail!("Native target locking unavailable")
    }
}

fn numeric_version(value: &str) -> Result<[u64; 3]> {
    let parts = value.split('.').collect::<Vec<_>>();
    ensure!(parts.len() == 3, "Numeric version required");
    let mut result = [0; 3];
    for (i, part) in parts.iter().enumerate() {
        ensure!(
            !part.is_empty()
                && part.bytes().all(|b| b.is_ascii_digit())
                && (part.len() == 1 || !part.starts_with('0')),
            "Ambiguous version"
        );
        result[i] = part.parse()?;
    }
    Ok(result)
}
fn validate_identity(
    identity: &BundleIdentity,
    version: &str,
    anchor: &str,
    arch: Architecture,
) -> Result<()> {
    ensure!(
        identity.bundle_id == PREVIEW_ID
            && identity.version == version
            && identity.anchor == anchor
            && identity.architecture == arch,
        "Preview bundle identity/version/signing anchor differs"
    );
    numeric_version(version)?;
    Ok(())
}
fn no_symlinks(path: &Path) -> Result<()> {
    ensure!(path.is_absolute(), "Absolute native configuration required");
    for parent in path.ancestors() {
        ensure!(
            !fs::symlink_metadata(parent)?.file_type().is_symlink(),
            "Native target path traverses a symlink"
        );
    }
    Ok(())
}
fn private_directory(path: &Path) -> Result<()> {
    no_symlinks(path)?;
    ensure!(
        path.is_dir()
            && !path
                .ancestors()
                .any(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("app"))),
        "Private transaction directory outside app bundles required"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let metadata = fs::metadata(path)?;
        ensure!(
            metadata.permissions().mode() & 0o077 == 0
                && metadata.uid() == unsafe { libc::geteuid() },
            "Transaction directory must be owned and private"
        );
    }
    #[cfg(not(unix))]
    bail!("Native private transaction ACL verification unavailable");
    #[cfg(unix)]
    Ok(())
}
fn create_private_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new().mode(0o700).create(path)?;
    }
    #[cfg(not(unix))]
    bail!("Native private directory creation unavailable");
    #[cfg(unix)]
    Ok(())
}
fn new_file(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    Ok(options.open(path)?)
}
fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    #[cfg(not(unix))]
    {
        let _ = path;
        bail!("Directory durability adapter unavailable");
    }
    #[cfg(unix)]
    Ok(())
}
fn write_new_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut file = new_file(path)?;
    serde_json::to_writer(&mut file, value)?;
    file.sync_all()?;
    sync_directory(path.parent().context("Missing transaction parent")?)
}
fn persist_outcome(directory: &Path, diagnostic: &OutcomeDiagnostic) -> Result<()> {
    // Fixed UUID-derived transaction path, independently checked even after a
    // successful swap. No caller-provided filename or native error text is used.
    ensure!(
        directory.file_name().and_then(|name| name.to_str())
            == Some(diagnostic.transaction.to_string().as_str()),
        "Diagnostic transaction directory differs"
    );
    private_directory(directory)?;
    let bytes = serde_json::to_vec(diagnostic)?;
    ensure!(bytes.len() <= 4096, "Outcome diagnostic exceeds its bound");
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::{
            fd::{AsRawFd, FromRawFd},
            unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        };
        // Pin the checked parent, so all child operations use one actual owned
        // directory rather than resolving its pathname again during publication.
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(directory)?;
        let metadata = directory.metadata()?;
        ensure!(
            metadata.is_dir()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0,
            "Owned private diagnostic directory required"
        );
        let temporary = std::ffi::CString::new(format!(".outcome-{}", Uuid::new_v4()))?;
        // SAFETY: live directory descriptor, NUL-terminated owned basename and
        // flags require a fresh no-follow 0600 regular file in that directory.
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        ensure!(fd >= 0, "Cannot create outcome diagnostic");
        // SAFETY: successful openat transferred a new descriptor to this File.
        let mut file = unsafe { File::from_raw_fd(fd) };
        let result = (|| -> Result<()> {
            let metadata = file.metadata()?;
            ensure!(
                metadata.is_file()
                    && metadata.nlink() == 1
                    && metadata.uid() == unsafe { libc::geteuid() }
                    && metadata.permissions().mode() & 0o777 == 0o600,
                "Private diagnostic file required"
            );
            file.write_all(&bytes)?;
            file.sync_all()?;
            // linkat is atomic and refuses an existing outcome.json, including a
            // symlink. It cannot replace an earlier diagnostic or touch its target.
            ensure!(
                unsafe {
                    libc::linkat(
                        directory.as_raw_fd(),
                        temporary.as_ptr(),
                        directory.as_raw_fd(),
                        c"outcome.json".as_ptr(),
                        0,
                    )
                } == 0,
                "Cannot publish outcome diagnostic"
            );
            ensure!(
                unsafe { libc::unlinkat(directory.as_raw_fd(), temporary.as_ptr(), 0) } == 0,
                "Cannot finish outcome publication"
            );
            directory.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            // Only our fresh random temporary name is eligible for cleanup;
            // failure never removes/replaces the fixed published diagnostic.
            unsafe {
                libc::unlinkat(directory.as_raw_fd(), temporary.as_ptr(), 0);
            }
            let _ = directory.sync_all();
        }
        result
    }
    #[cfg(not(unix))]
    bail!("Private outcome diagnostic adapter unavailable")
}
fn persist(directory: &Path, journal: &Journal) -> Result<()> {
    let temporary = directory.join(format!(".journal-{}", Uuid::new_v4()));
    write_new_json(&temporary, journal)?;
    fs::rename(temporary, directory.join("journal.json"))?;
    sync_directory(directory)
}
fn read_json<T: for<'a> Deserialize<'a>>(path: &Path) -> Result<T> {
    no_symlinks(path)?;
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_file() && metadata.len() <= 1024 * 1024,
        "Invalid bounded transaction record"
    );
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}
fn proposal_hash(proposal: &Proposal) -> Result<String> {
    Ok(crate::digest_hex::lower_hex(Sha256::digest(
        serde_json::to_vec(proposal)?,
    )))
}
fn files(root: &Path) -> Result<BTreeMap<String, PathBuf>> {
    fn walk(root: &Path, at: &Path, result: &mut BTreeMap<String, PathBuf>) -> Result<()> {
        for entry in fs::read_dir(at)? {
            let entry = entry?;
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path)?;
            ensure!(
                !metadata.file_type().is_symlink(),
                "Bundle symlinks are unsupported by this preview installer"
            );
            if metadata.is_dir() {
                walk(root, &path, result)?;
            } else {
                ensure!(metadata.is_file(), "Bundle contains a special file");
                let name = path
                    .strip_prefix(root)?
                    .to_str()
                    .context("Non UTF8 bundle path")?
                    .to_owned();
                ensure!(!name.contains(['\\', ':']), "Unsupported bundle filename");
                ensure!(result.len() < 50_000, "Too many bundle files");
                result.insert(name, path);
            }
        }
        Ok(())
    }
    no_symlinks(root)?;
    ensure!(root.is_dir(), "Bundle directory missing");
    let mut result = BTreeMap::new();
    walk(root, root, &mut result)?;
    ensure!(!result.is_empty(), "Empty bundle");
    Ok(result)
}
fn fingerprint(root: &Path) -> Result<String> {
    let mut hash = Sha256::new();
    let mut total = 0u64;
    for (name, path) in files(root)? {
        let metadata = fs::metadata(&path)?;
        ensure!(metadata.len() <= 256 * 1024 * 1024, "Bundle file too large");
        total = total
            .checked_add(metadata.len())
            .context("Bundle size overflow")?;
        ensure!(total <= 1024 * 1024 * 1024, "Bundle too large");
        hash.update((name.len() as u64).to_le_bytes());
        hash.update(name.as_bytes());
        hash.update(metadata.len().to_le_bytes());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            hash.update((metadata.permissions().mode() & 0o777).to_le_bytes());
        }
        let mut file = File::open(path)?;
        let mut buffer = [0u8; 65536];
        let mut remaining = metadata.len();
        while remaining > 0 {
            let limit = remaining.min(buffer.len() as u64) as usize;
            let n = file.read(&mut buffer[..limit])?;
            ensure!(n > 0, "Bundle file shrank");
            hash.update(&buffer[..n]);
            remaining -= n as u64;
        }
        ensure!(file.read(&mut buffer[..1])? == 0, "Bundle file grew");
    }
    Ok(crate::digest_hex::lower_hex(hash.finalize()))
}
fn copy_bundle(source: &Path, destination: &Path) -> Result<()> {
    let entries = files(source)?;
    create_private_directory(destination)?;
    for (name, path) in entries {
        let target = destination.join(name);
        let parent = target.parent().context("Missing copied file parent")?;
        let relative = parent.strip_prefix(destination)?;
        let mut at = destination.to_path_buf();
        for part in relative.components() {
            at.push(part);
            if !at.exists() {
                create_private_directory(&at)?;
            }
            ensure!(
                fs::symlink_metadata(&at)?.is_dir(),
                "Copied file parent changed"
            );
        }
        let mut input = File::open(&path)?;
        let mut output = new_file(&target)?;
        let expected = fs::metadata(&path)?.len();
        ensure!(expected <= 256 * 1024 * 1024, "Replacement file too large");
        let count = std::io::copy(&mut (&mut input).take(expected), &mut output)?;
        ensure!(
            count == expected && input.read(&mut [0u8; 1])? == 0,
            "Replacement source changed"
        );
        output.sync_all()?;
        fs::set_permissions(&target, fs::metadata(&path)?.permissions())?;
        output.sync_all()?;
        sync_directory(parent)?;
    }
    sync_directory(destination)?;
    sync_directory(destination.parent().context("Missing copy parent")?)
}

/// Real atomic exchange. Unsupported systems refuse; there is no delete/rename fallback.
pub struct NativeExchange;
impl Exchange for NativeExchange {
    fn swap(&self, target: &Path, replacement: &Path) -> Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
            ensure!(
                fs::metadata(target)?.dev() == fs::metadata(replacement)?.dev(),
                "Atomic exchange requires one filesystem"
            );
            let target = std::ffi::CString::new(target.as_os_str().as_bytes())?;
            let replacement = std::ffi::CString::new(replacement.as_os_str().as_bytes())?;
            #[cfg(target_os = "macos")]
            let result = unsafe {
                libc::renameatx_np(
                    libc::AT_FDCWD,
                    target.as_ptr(),
                    libc::AT_FDCWD,
                    replacement.as_ptr(),
                    libc::RENAME_SWAP,
                )
            };
            #[cfg(target_os = "linux")]
            let result = unsafe {
                libc::renameat2(
                    libc::AT_FDCWD,
                    target.as_ptr(),
                    libc::AT_FDCWD,
                    replacement.as_ptr(),
                    libc::RENAME_EXCHANGE,
                )
            };
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            let result = -1;
            ensure!(
                result == 0,
                "Atomic exchange failed: {}",
                std::io::Error::last_os_error()
            );
            Ok(())
        }
        #[cfg(not(unix))]
        {
            let _ = (target, replacement);
            bail!("Native atomic bundle exchange is unavailable")
        }
    }
}

/// Bounded fixed-tool execution used only by native verification. No shell, no
/// signing flags, no install/open/kill-target command. Timeout kills only this tool.
#[cfg(target_os = "macos")]
fn native_tool(program: &str, args: &[OsString]) -> Result<Vec<u8>> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let output = child.stdout.take().context("Verifier stdout unavailable")?;
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        output
            .take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
    });
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("Native verifier timed out");
        }
        thread::sleep(Duration::from_millis(10));
    };
    let bytes = reader
        .join()
        .map_err(|_| anyhow::anyhow!("Verifier output worker failed"))??;
    ensure!(
        status.success() && bytes.len() <= 1024 * 1024,
        "Native signature/metadata verification failed"
    );
    Ok(bytes)
}
/// Actual Developer ID/code/resource/Gatekeeper adapter. It performs verification
/// only when explicitly invoked. Non-Mac hosts return unavailable, never Verified.
pub struct MacCodeVerifier;
impl BundleVerifier for MacCodeVerifier {
    fn verify(
        &self,
        bundle: &Path,
        anchor: &str,
        architecture: Architecture,
    ) -> Result<BundleIdentity> {
        #[cfg(target_os = "macos")]
        {
            ensure!(
                anchor.len() == 10
                    && anchor
                        .bytes()
                        .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()),
                "Configured Developer ID team anchor required"
            );
            no_symlinks(bundle)?;
            let info = bundle.join("Contents/Info.plist");
            ensure!(
                fs::symlink_metadata(&info)?.is_file() && fs::metadata(&info)?.len() <= 1024 * 1024,
                "Invalid app plist"
            );
            let bytes = native_tool(
                "/usr/bin/plutil",
                &[
                    "-convert".into(),
                    "json".into(),
                    "-o".into(),
                    "-".into(),
                    info.into_os_string(),
                ],
            )?;
            let metadata: serde_json::Value = serde_json::from_slice(&bytes)?;
            ensure!(
                metadata["CFBundleIdentifier"].as_str() == Some(PREVIEW_ID)
                    && metadata["CFBundleExecutable"].as_str() == Some(MAIN)
                    && metadata["CFBundleName"].as_str() == Some("Coincide Rust"),
                "Not the Rust preview app identity"
            );
            let version = metadata["CFBundleShortVersionString"]
                .as_str()
                .context("Missing app version")?
                .to_owned();
            numeric_version(&version)?;
            if let Some(minimum) = metadata.get("LSMinimumSystemVersion") {
                let minimum = minimum.as_str().context("Invalid minimum macOS metadata")?;
                fn os_version(value: &str) -> Result<Vec<u64>> {
                    let parts = value.trim().split('.').collect::<Vec<_>>();
                    ensure!((1..=3).contains(&parts.len()), "Invalid OS version");
                    let mut result = Vec::new();
                    for p in parts {
                        ensure!(
                            !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()),
                            "Invalid OS version"
                        );
                        result.push(p.parse()?);
                    }
                    while result.len() < 3 {
                        result.push(0);
                    }
                    Ok(result)
                }
                let os = native_tool("/usr/bin/sw_vers", &["-productVersion".into()])?;
                ensure!(
                    os_version(std::str::from_utf8(&os)?)? >= os_version(minimum)?,
                    "Declared minimum runtime exceeds this Mac"
                );
            }
            let requirement = format!(
                "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"{anchor}\" and identifier \"{PREVIEW_ID}\""
            );
            native_tool(
                "/usr/bin/codesign",
                &[
                    "--verify".into(),
                    "--strict".into(),
                    "--deep".into(),
                    "--all-architectures".into(),
                    "-R".into(),
                    // codesign treats an unprefixed requirement as a filename.
                    format!("={requirement}").into(),
                    bundle.as_os_str().to_owned(),
                ],
            )?;
            let arch = match architecture {
                Architecture::Arm64 => "arm64",
                Architecture::X86_64 => "x86_64",
            };
            for executable in [MAIN, "coincide-rs", "coincide-store"] {
                let path = bundle.join("Contents/MacOS").join(executable);
                let metadata = fs::symlink_metadata(&path)?;
                ensure!(
                    metadata.is_file() && metadata.len() > 0,
                    "Required preview executable missing"
                );
                let team_requirement = format!(
                    "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"{anchor}\""
                );
                native_tool(
                    "/usr/bin/codesign",
                    &[
                        "--verify".into(),
                        "--strict".into(),
                        "--all-architectures".into(),
                        "-R".into(),
                        format!("={team_requirement}").into(),
                        path.as_os_str().to_owned(),
                    ],
                )?;
                native_tool(
                    "/usr/bin/lipo",
                    &["-verify_arch".into(), arch.into(), path.into_os_string()],
                )?;
            }
            native_tool(
                "/usr/sbin/spctl",
                &[
                    "--assess".into(),
                    "--type".into(),
                    "execute".into(),
                    bundle.as_os_str().to_owned(),
                ],
            )?;
            Ok(BundleIdentity {
                bundle_id: PREVIEW_ID.into(),
                version,
                architecture,
                anchor: anchor.into(),
            })
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (bundle, anchor, architecture);
            bail!("Native Developer ID verification is unavailable on this platform")
        }
    }
}

/// Independent Mac helper's exact-parent observer. Registration does not kill or
/// quit anything. Other platforms refuse until a native observer is supplied.
pub struct MacProcessGuard;
#[cfg(target_os = "macos")]
struct MacParentWatch {
    queue: i32,
    binding: ParentBinding,
}
#[cfg(target_os = "macos")]
impl Drop for MacParentWatch {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.queue);
        }
    }
}
#[cfg(target_os = "macos")]
fn process_path(pid: i32) -> Result<PathBuf> {
    let mut buffer = vec![0u8; 4096];
    // SAFETY: the supplied allocation has the declared writable capacity.
    let count = unsafe { proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    ensure!(
        count > 0,
        "Cannot establish native process executable identity"
    );
    let end = buffer
        .iter()
        .position(|b| *b == 0)
        .unwrap_or(count as usize);
    use std::os::unix::ffi::OsStringExt;
    Ok(PathBuf::from(OsString::from_vec(buffer[..end].to_vec())))
}
#[cfg(target_os = "macos")]
fn process_binding(pid: i32) -> Result<ParentBinding> {
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
    let size = std::mem::size_of::<libc::proc_bsdinfo>();
    // SAFETY: proc_pidinfo receives a writable struct-sized allocation.
    let count = unsafe {
        proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            size as i32,
        )
    };
    ensure!(
        count == size as i32,
        "Cannot establish parent start identity"
    );
    let info = unsafe { info.assume_init() };
    ensure!(info.pbi_pid == pid as u32, "Parent PID differs");
    Ok(ParentBinding {
        pid: pid as u32,
        start_seconds: info.pbi_start_tvsec,
        start_micros: info.pbi_start_tvusec,
    })
}
#[cfg(target_os = "macos")]
impl MacParentWatch {
    fn observe(pid: i32) -> Result<Self> {
        let binding = process_binding(pid)?;
        let queue = unsafe { libc::kqueue() };
        ensure!(queue >= 0, "Cannot register parent observer");
        let watch = Self { queue, binding };
        let event = libc::kevent {
            ident: pid as usize,
            filter: libc::EVFILT_PROC,
            flags: libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
            fflags: libc::NOTE_EXIT | libc::NOTE_EXITSTATUS,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        // SAFETY: event has the kevent ABI, with no returned event buffer requested.
        ensure!(
            unsafe { libc::kevent(queue, &event, 1, std::ptr::null_mut(), 0, std::ptr::null(),) }
                == 0,
            "Cannot observe exact parent exit"
        );
        ensure!(
            process_binding(pid)? == watch.binding,
            "Parent changed while registering observer"
        );
        Ok(watch)
    }
}
#[cfg(target_os = "macos")]
impl ParentWatch for MacParentWatch {
    fn binding(&self) -> ParentBinding {
        self.binding.clone()
    }
    fn wait_clean_exit(&mut self, timeout: Duration) -> Result<()> {
        let timeout = libc::timespec {
            tv_sec: timeout.as_secs() as _,
            tv_nsec: timeout.subsec_nanos() as _,
        };
        let mut event = std::mem::MaybeUninit::<libc::kevent>::uninit();
        let count = unsafe {
            libc::kevent(
                self.queue,
                std::ptr::null(),
                0,
                event.as_mut_ptr(),
                1,
                &timeout,
            )
        };
        ensure!(count == 1, "Parent exit timed out or observer failed");
        let event = unsafe { event.assume_init() };
        ensure!(
            event.ident == self.binding.pid as usize
                && event.flags & libc::EV_ERROR == 0
                && event.fflags & libc::NOTE_EXIT != 0
                && event.data == 0,
            "Parent did not exit normally with status zero"
        );
        Ok(())
    }
}
impl ProcessGuard for MacProcessGuard {
    fn observe_parent(&self, target: &Path) -> Result<Box<dyn ParentWatch>> {
        #[cfg(target_os = "macos")]
        {
            let pid = unsafe { libc::getppid() };
            ensure!(pid > 1, "Independent helper parent is unavailable");
            let expected = target.join("Contents/MacOS").join(MAIN);
            ensure!(
                process_path(pid)?.canonicalize()? == expected.canonicalize()?,
                "Helper parent is not the configured Rust preview executable"
            );
            let watch = MacParentWatch::observe(pid)?;
            ensure!(
                process_path(pid)?.canonicalize()? == expected.canonicalize()?,
                "Parent executable changed"
            );
            Ok(Box::new(watch))
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = target;
            bail!("Native clean-parent observer unavailable")
        }
    }
    fn ensure_stopped(&self, target: &Path) -> Result<()> {
        #[cfg(target_os = "macos")]
        {
            // PROC_ALL_PIDS = 1 in libproc. Fixed native enumeration, no shell/ps parsing.
            let required = unsafe { proc_listpids(1, 0, std::ptr::null_mut(), 0) };
            ensure!(
                required > 0 && required < 16 * 1024 * 1024,
                "Cannot enumerate native processes"
            );
            let capacity = required as usize / std::mem::size_of::<i32>() + 256;
            let mut pids = vec![0i32; capacity];
            let count = unsafe {
                proc_listpids(
                    1,
                    0,
                    pids.as_mut_ptr().cast(),
                    (capacity * std::mem::size_of::<i32>()) as i32,
                )
            };
            ensure!(
                count > 0 && (count as usize) < capacity * std::mem::size_of::<i32>(),
                "Native process list changed; retry"
            );
            let executable = target.join("Contents/MacOS").join(MAIN);
            for pid in pids
                .into_iter()
                .take(count as usize / std::mem::size_of::<i32>())
                .filter(|pid| *pid > 1)
            {
                if let Ok(path) = process_path(pid) {
                    ensure!(
                        path != executable && !path.starts_with(target),
                        "A configured Rust preview bundle executable is still running"
                    );
                    if path.file_name().is_some_and(|name| name == MAIN) {
                        // Conservatively refuse another preview-named GUI instance too.
                        bail!("Another Rust preview executable is running");
                    }
                } else {
                    // A disappeared PID is harmless. Do not silently classify a live,
                    // uninspectable process as proof that the target is stopped.
                    let exists = unsafe { libc::kill(pid, 0) };
                    ensure!(
                        exists == -1
                            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH),
                        "Cannot prove all observed native processes are outside the target"
                    );
                }
            }
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = target;
            bail!("Native stopped-target verification unavailable")
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::updater::{
        Config, Dependencies, DiskSpace, Limits, OperationContext, RequestPolicy, Response,
        SignatureStatus, State, Transport, TrustReport, TrustVerifier,
    };
    use serde_json::{Value, json};
    use std::io::Write;
    use std::{
        collections::BTreeSet,
        io::Cursor,
        process::{Child, Command, Stdio},
        sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        thread,
    };
    use tempfile::TempDir;
    use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

    const ANCHOR: &str = "FIXTURE001";
    fn temp() -> TempDir {
        use std::os::unix::fs::PermissionsExt;
        tempfile::Builder::new()
            .permissions(fs::Permissions::from_mode(0o700))
            .tempdir()
            .unwrap()
    }
    fn metadata(version: &str) -> Value {
        json!({"CFBundleIdentifier":PREVIEW_ID,"CFBundleName":"Coincide Rust","CFBundleExecutable":MAIN,"CFBundleShortVersionString":version,"fixture_anchor":ANCHOR})
    }
    fn bundle(path: &Path, version: &str) {
        create_private_directory(path).unwrap();
        create_private_directory(&path.join("Contents")).unwrap();
        create_private_directory(&path.join("Contents/MacOS")).unwrap();
        write_new_json(&path.join("Contents/Info.plist"), &metadata(version)).unwrap();
        for name in [MAIN, "coincide-rs", "coincide-store"] {
            let mut file = new_file(&path.join("Contents/MacOS").join(name)).unwrap();
            file.write_all(format!("synthetic-{name}-{version}; never execute").as_bytes())
                .unwrap();
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(
                path.join("Contents/MacOS").join(name),
                fs::Permissions::from_mode(0o700),
            )
            .unwrap();
        }
    }
    fn archive() -> Vec<u8> {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o700);
        for name in [MAIN, "coincide-rs", "coincide-store"] {
            writer
                .start_file(format!("{APP}/Contents/MacOS/{name}"), options)
                .unwrap();
            writer
                .write_all(format!("synthetic-{name}-0.2.0; never execute").as_bytes())
                .unwrap();
        }
        writer
            .start_file(
                format!("{APP}/Contents/Info.plist"),
                options.unix_permissions(0o600),
            )
            .unwrap();
        writer
            .write_all(&serde_json::to_vec(&metadata("0.2.0")).unwrap())
            .unwrap();
        writer.finish().unwrap().into_inner()
    }
    struct FixtureHttp {
        archive: Vec<u8>,
        calls: AtomicUsize,
    }
    impl Transport for FixtureHttp {
        fn fetch(
            &self,
            url: &url::Url,
            _: &RequestPolicy,
            output: &mut dyn Write,
            context: &OperationContext,
        ) -> Result<Response> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            context.checkpoint()?;
            let bytes = if url.path().ends_with("feed.json") {
                serde_json::to_vec(
                    &json!({"channel":"rust-preview","bundle_id":PREVIEW_ID,"version":"0.2.0",
                "artifacts":[{"version":"0.2.0","platform":"macos","architecture":"arm64","url":"https://fixture.example/preview/0.2.0/Coincide-Rust-macos-arm64.zip","size":self.archive.len(),"sha256":crate::digest_hex::lower_hex(Sha256::digest(&self.archive))}]}),
                )?
            } else {
                self.archive.clone()
            };
            output.write_all(&bytes)?;
            Ok(Response {
                status: 200,
                content_length: Some(bytes.len() as u64),
                chain: vec![url.clone()],
            })
        }
    }
    struct FixtureDisk(AtomicU64);
    impl DiskSpace for FixtureDisk {
        fn available_bytes(&self, _: &Path) -> Result<u64> {
            Ok(self.0.load(Ordering::SeqCst))
        }
    }
    struct FixtureVerifier {
        target: PathBuf,
        reject_new_target: AtomicBool,
        always_reject: AtomicBool,
    }
    impl BundleVerifier for FixtureVerifier {
        fn verify(&self, path: &Path, anchor: &str, arch: Architecture) -> Result<BundleIdentity> {
            ensure!(
                !self.always_reject.load(Ordering::SeqCst),
                "Synthetic trust unavailable/rejected"
            );
            let info: Value = read_json(&path.join("Contents/Info.plist"))?;
            ensure!(
                info["fixture_anchor"].as_str() == Some(anchor),
                "Synthetic signer mismatch"
            );
            let version = info["CFBundleShortVersionString"]
                .as_str()
                .context("Missing fixture version")?;
            if version == "0.2.0"
                && path == self.target
                && self.reject_new_target.swap(false, Ordering::SeqCst)
            {
                bail!("Synthetic post-exchange verifier failure");
            }
            Ok(BundleIdentity {
                bundle_id: info["CFBundleIdentifier"]
                    .as_str()
                    .context("Missing fixture ID")?
                    .into(),
                version: version.into(),
                architecture: arch,
                anchor: anchor.into(),
            })
        }
    }
    struct StageTrust;
    impl TrustVerifier for StageTrust {
        fn verify(
            &self,
            path: &Path,
            release: &Release,
            anchor: &str,
            context: &OperationContext,
        ) -> Result<TrustReport> {
            context.checkpoint()?;
            let metadata: Value = read_json(&path.join(APP).join("Contents/Info.plist"))?;
            ensure!(
                metadata["fixture_anchor"].as_str() == Some(anchor),
                "Fixture anchor differs"
            );
            Ok(TrustReport {
                bundle_id: PREVIEW_ID.into(),
                version: release.version.clone(),
                platform: Platform::Macos,
                architecture: Architecture::Arm64,
                signature: SignatureStatus::Pending {
                    reason: "Only installer fixture verifier can approve these synthetic bytes"
                        .into(),
                },
            })
        }
    }
    struct FixtureUi {
        approve: AtomicBool,
        calls: AtomicUsize,
    }
    impl NativeApproval for FixtureUi {
        fn present(&self, _: &Proposal) -> Result<NativeDecision> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(if self.approve.load(Ordering::SeqCst) {
                NativeDecision::Approve
            } else {
                NativeDecision::Decline
            })
        }
    }
    struct FixtureBarrier {
        fail: bool,
        calls: AtomicUsize,
    }
    impl ShutdownBarrier for FixtureBarrier {
        fn quiesce_and_flush(&self, _: &Proposal) -> Result<()> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            ensure!(!self.fail, "Synthetic unsaved state");
            Ok(())
        }
    }
    struct FixtureWatch {
        clean: bool,
    }
    impl ParentWatch for FixtureWatch {
        fn binding(&self) -> ParentBinding {
            ParentBinding {
                pid: 42,
                start_seconds: 123,
                start_micros: 456,
            }
        }
        fn wait_clean_exit(&mut self, _: Duration) -> Result<()> {
            ensure!(self.clean, "Synthetic signalled/nonzero process exit");
            Ok(())
        }
    }
    struct FixtureProcesses {
        clean: AtomicBool,
        stopped: AtomicBool,
        registered: AtomicUsize,
        child: Mutex<Option<Child>>,
    }
    struct ChildWatch {
        child: Child,
    }
    impl ParentWatch for ChildWatch {
        fn binding(&self) -> ParentBinding {
            ParentBinding {
                pid: self.child.id(),
                start_seconds: 1,
                start_micros: 1,
            }
        }
        fn wait_clean_exit(&mut self, timeout: Duration) -> Result<()> {
            let deadline = Instant::now() + timeout;
            loop {
                if let Some(status) = self.child.try_wait()? {
                    ensure!(
                        status.success(),
                        "Owned fixture process did not exit cleanly"
                    );
                    return Ok(());
                }
                if Instant::now() >= deadline {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    bail!("Owned fixture process timeout");
                }
                thread::sleep(Duration::from_millis(1));
            }
        }
    }
    impl Drop for ChildWatch {
        fn drop(&mut self) {
            if self.child.try_wait().ok().flatten().is_none() {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
    }
    impl ProcessGuard for FixtureProcesses {
        fn observe_parent(&self, _: &Path) -> Result<Box<dyn ParentWatch>> {
            self.registered.fetch_add(1, Ordering::SeqCst);
            if let Some(child) = self.child.lock().unwrap().take() {
                Ok(Box::new(ChildWatch { child }))
            } else {
                Ok(Box::new(FixtureWatch {
                    clean: self.clean.load(Ordering::SeqCst),
                }))
            }
        }
        fn ensure_stopped(&self, _: &Path) -> Result<()> {
            ensure!(
                self.stopped.load(Ordering::SeqCst),
                "Synthetic target still running"
            );
            Ok(())
        }
    }
    struct FailureExchange {
        calls: AtomicUsize,
        fail_on: usize,
    }
    impl Exchange for FailureExchange {
        fn swap(&self, target: &Path, other: &Path) -> Result<()> {
            let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
            ensure!(call != self.fail_on, "Synthetic atomic exchange failure");
            NativeExchange.swap(target, other)
        }
    }
    struct Fixture {
        root: TempDir,
        updater: Updater,
        installer: Installer,
        http: Arc<FixtureHttp>,
        verifier: Arc<FixtureVerifier>,
        ui: Arc<FixtureUi>,
        processes: Arc<FixtureProcesses>,
        disk: Arc<FixtureDisk>,
    }
    impl Fixture {
        fn new() -> Self {
            let root = temp();
            let physical = root.path().canonicalize().unwrap();
            let cache = physical.join("cache");
            let transactions = physical.join("transactions");
            let target_parent = physical.join("apps");
            for path in [&cache, &transactions, &target_parent] {
                create_private_directory(path).unwrap();
            }
            bundle(&target_parent.join(APP), "0.1.0");
            let http = Arc::new(FixtureHttp {
                archive: archive(),
                calls: AtomicUsize::new(0),
            });
            let disk = Arc::new(FixtureDisk(AtomicU64::new(4 * 1024 * 1024)));
            let updater = Updater::configured(
                Config {
                    feed: url::Url::parse("https://fixture.example/preview/feed.json").unwrap(),
                    artifact_base: url::Url::parse("https://fixture.example/preview/").unwrap(),
                    trust_anchor: ANCHOR.into(),
                    current_version: "0.1.0".into(),
                    platform: Platform::Macos,
                    architecture: Architecture::Arm64,
                    cache_root: cache,
                    allowed_hosts: BTreeSet::from(["fixture.example".into()]),
                    limits: Limits {
                        metadata_bytes: 16384,
                        archive_bytes: 65536,
                        expanded_bytes: 65536,
                        entry_bytes: 16384,
                        entries: 20,
                        reserve_disk_bytes: 1024,
                        check_timeout: Duration::from_secs(3),
                        stage_timeout: Duration::from_secs(3),
                    },
                },
                Dependencies {
                    transport: http.clone(),
                    extractor: Arc::new(crate::updater::ZipExtractor),
                    disk: disk.clone(),
                    trust: Arc::new(StageTrust),
                },
            )
            .unwrap();
            fn wait(op: crate::updater::Operation) -> State {
                let deadline = Instant::now() + Duration::from_secs(3);
                loop {
                    if let Some(state) = op.try_result() {
                        return state;
                    }
                    assert!(Instant::now() < deadline);
                    thread::sleep(Duration::from_millis(1));
                }
            }
            assert!(matches!(
                wait(updater.check().unwrap()),
                State::Available(_)
            ));
            assert!(matches!(
                wait(updater.download_available().unwrap()),
                State::Staged(_)
            ));
            let verifier = Arc::new(FixtureVerifier {
                target: target_parent.join(APP),
                reject_new_target: AtomicBool::new(false),
                always_reject: AtomicBool::new(false),
            });
            let ui = Arc::new(FixtureUi {
                approve: AtomicBool::new(true),
                calls: AtomicUsize::new(0),
            });
            let processes = Arc::new(FixtureProcesses {
                clean: AtomicBool::new(true),
                stopped: AtomicBool::new(true),
                registered: AtomicUsize::new(0),
                child: Mutex::new(None),
            });
            let installer = Installer::configured(
                InstallConfig {
                    target_parent,
                    trust_anchor: ANCHOR.into(),
                    reserve_disk_bytes: 1024,
                    transaction_root: transactions,
                    approval_lifetime: Duration::from_secs(60),
                    exit_timeout: Duration::from_secs(3),
                },
                InstallDependencies {
                    verifier: verifier.clone(),
                    approval: ui.clone(),
                    processes: processes.clone(),
                    exchange: Arc::new(NativeExchange),
                    disk: disk.clone(),
                },
            )
            .unwrap();
            Self {
                root,
                updater,
                installer,
                http,
                verifier,
                ui,
                processes,
                disk,
            }
        }
        fn authorization(&self) -> AuthorizedInstall {
            self.installer
                .request_native_authorization(&self.updater)
                .unwrap()
                .expect("native fixture approved")
        }
        fn armed(&self) -> ArmedInstall {
            self.installer.arm(self.authorization()).unwrap()
        }
        fn consent(&self, armed: &ArmedInstall) {
            armed
                .authorize_clean_quit(&FixtureBarrier {
                    fail: false,
                    calls: AtomicUsize::new(0),
                })
                .unwrap();
        }
        fn version(&self) -> String {
            let value: Value =
                read_json(&self.installer.target().join("Contents/Info.plist")).unwrap();
            value["CFBundleShortVersionString"].as_str().unwrap().into()
        }
        fn fault(&mut self, point: Checkpoint) {
            self.installer.fault = Some(Arc::new(move |at| {
                ensure!(at != point, "Synthetic crash checkpoint");
                Ok(())
            }));
        }
    }
    #[test]
    fn native_authorization_binds_fresh_verified_bytes_not_staged_signature_flag() {
        let f = Fixture::new();
        assert!(matches!(
            f.updater.state(),
            State::Staged(crate::updater::Stage {
                signature: SignatureStatus::Pending { .. },
                ..
            })
        ));
        let approval = f.authorization();
        assert_eq!(
            approval.proposal().release.sha256,
            crate::digest_hex::lower_hex(Sha256::digest(&f.http.archive))
        );
        assert_eq!(approval.proposal().anchor, ANCHOR);
        assert_eq!(approval.proposal().target, f.installer.target());
        assert_eq!(f.http.calls.load(Ordering::SeqCst), 2);
        let armed = f.installer.arm(approval).unwrap();
        assert_eq!(f.processes.registered.load(Ordering::SeqCst), 1);
        f.installer.cancel(armed).unwrap();
        assert_eq!(f.version(), "0.1.0");
    }
    #[test]
    fn decline_or_real_verifier_unavailable_cannot_create_install_capability() {
        let f = Fixture::new();
        f.ui.approve.store(false, Ordering::SeqCst);
        assert!(
            f.installer
                .request_native_authorization(&f.updater)
                .unwrap()
                .is_none()
        );
        f.ui.approve.store(true, Ordering::SeqCst);
        f.verifier.always_reject.store(true, Ordering::SeqCst);
        assert!(
            f.installer
                .request_native_authorization(&f.updater)
                .is_err()
        );
        assert_eq!(f.ui.calls.load(Ordering::SeqCst), 1);
        assert_eq!(f.version(), "0.1.0");
    }
    #[test]
    fn rejects_swift_identity_even_at_preview_named_path() {
        let f = Fixture::new();
        let path = f.installer.target().join("Contents/Info.plist");
        let mut value: Value = read_json(&path).unwrap();
        value["CFBundleIdentifier"] = json!("com.apoorvdarshan.coincide");
        fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(
            f.installer
                .request_native_authorization(&f.updater)
                .is_err()
        );
        assert_eq!(f.ui.calls.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn stage_archive_corruption_is_rejected_before_native_prompt() {
        let f = Fixture::new();
        let State::Staged(stage) = f.updater.state() else {
            panic!("missing stage")
        };
        fs::write(stage.job.join("release.zip"), b"corrupt").unwrap();
        assert!(
            f.installer
                .request_native_authorization(&f.updater)
                .is_err()
        );
        assert_eq!(f.ui.calls.load(Ordering::SeqCst), 0);
        assert_eq!(f.version(), "0.1.0");
    }
    #[test]
    fn stale_native_authorization_refuses_changed_target_and_wrong_installer() {
        let f = Fixture::new();
        let approval = f.authorization();
        let other =
            Installer::configured(f.installer.config.clone(), f.installer.dependencies.clone())
                .unwrap();
        assert!(other.arm(approval).is_err());
        let approval = f.authorization();
        fs::write(
            f.installer.target().join("Contents/MacOS/coincide-rust"),
            b"changed",
        )
        .unwrap();
        assert!(f.installer.arm(approval).is_err());
    }
    #[test]
    fn successful_exchange_keeps_exact_previous_bundle_and_durable_receipt() {
        let f = Fixture::new();
        let old = fingerprint(&f.installer.target()).unwrap();
        let armed = f.armed();
        let id = armed.transaction();
        f.consent(&armed);
        let InstallOutcome::Installed {
            backup,
            receipt_warning,
            ..
        } = f.installer.run_helper(armed).unwrap()
        else {
            panic!("not installed")
        };
        assert!(receipt_warning.is_none());
        assert_eq!(f.version(), "0.2.0");
        assert_eq!(fingerprint(&backup).unwrap(), old);
        assert!(matches!(
            f.installer.account_recovery(id).unwrap(),
            RecoveryAccounting::InstalledWithBackup {
                phase: Phase::Committed,
                ..
            }
        ));
    }
    #[test]
    fn missing_or_failed_flush_consent_keeps_installed_target() {
        let f = Fixture::new();
        let armed = f.armed();
        let barrier = FixtureBarrier {
            fail: true,
            calls: AtomicUsize::new(0),
        };
        assert!(armed.authorize_clean_quit(&barrier).is_err());
        assert!(matches!(
            f.installer.run_helper(armed).unwrap(),
            InstallOutcome::NotInstalled { .. }
        ));
        assert_eq!(f.version(), "0.1.0");
    }
    #[test]
    fn abnormal_parent_and_running_target_cannot_exchange() {
        for running in [false, true] {
            let f = Fixture::new();
            if running {
                f.processes.stopped.store(false, Ordering::SeqCst);
            } else {
                f.processes.clean.store(false, Ordering::SeqCst);
            }
            let armed = f.armed();
            f.consent(&armed);
            assert!(matches!(
                f.installer.run_helper(armed).unwrap(),
                InstallOutcome::NotInstalled { .. }
            ));
            assert_eq!(f.version(), "0.1.0");
        }
    }
    #[test]
    fn altered_consent_or_target_binding_cannot_install() {
        let f = Fixture::new();
        let armed = f.armed();
        f.consent(&armed);
        let path = armed.directory.join("clean-quit.json");
        let mut consent: Consent = read_json(&path).unwrap();
        consent.nonce = Uuid::new_v4();
        fs::write(path, serde_json::to_vec(&consent).unwrap()).unwrap();
        assert!(matches!(
            f.installer.run_helper(armed).unwrap(),
            InstallOutcome::NotInstalled { .. }
        ));
        assert_eq!(f.version(), "0.1.0");
    }
    #[test]
    fn target_lock_drop_releases_even_with_inherited_open_description() {
        let temporary = temp();
        let parent = temporary.path().canonicalize().unwrap();
        let lock = target_lock(&parent, true).unwrap();
        // dup shares the open-file description, as a concurrent fork does
        // before exec closes inherited CLOEXEC descriptors. No scheduling race.
        let inherited = lock._file.try_clone().unwrap();
        assert!(target_lock(&parent, false).is_err());
        drop(lock);
        let replacement = target_lock(&parent, false)
            .expect("finished transaction unlocks despite inherited descriptor");
        assert!(inherited.metadata().is_ok());
        assert!(target_lock(&parent, false).is_err());
        // The old descriptor must not release the replacement's distinct lock.
        drop(inherited);
        assert!(target_lock(&parent, false).is_err());
        drop(replacement);
        assert!(target_lock(&parent, false).is_ok());
    }

    #[test]
    fn post_exchange_failure_atomically_restores_previous_bundle() {
        let f = Fixture::new();
        let old = fingerprint(&f.installer.target()).unwrap();
        let armed = f.armed();
        let id = armed.transaction();
        f.consent(&armed);
        f.verifier.reject_new_target.store(true, Ordering::SeqCst);
        assert!(matches!(
            f.installer.run_helper(armed).unwrap(),
            InstallOutcome::RolledBack { .. }
        ));
        assert_eq!(fingerprint(&f.installer.target()).unwrap(), old);
        assert!(matches!(
            f.installer.account_recovery(id).unwrap(),
            RecoveryAccounting::RestoredOldTarget {
                phase: Phase::RolledBack,
                ..
            }
        ));
    }
    #[test]
    fn failed_rollback_retains_both_bundles_and_reports_recovery_required() {
        let mut f = Fixture::new();
        f.installer.dependencies.exchange = Arc::new(FailureExchange {
            calls: AtomicUsize::new(0),
            fail_on: 2,
        });
        let armed = f.armed();
        let id = armed.transaction();
        f.consent(&armed);
        f.verifier.reject_new_target.store(true, Ordering::SeqCst);
        let InstallOutcome::RecoveryRequired { backup, .. } =
            f.installer.run_helper(armed).unwrap()
        else {
            panic!("must retain for recovery")
        };
        assert!(backup.is_dir());
        assert!(f.installer.target().is_dir());
        assert!(matches!(
            f.installer.account_recovery(id).unwrap(),
            RecoveryAccounting::InstalledWithBackup {
                phase: Phase::RecoveryRequired,
                ..
            }
        ));
    }
    #[test]
    fn crashes_before_and_after_swap_are_accounted_without_replay() {
        for point in [
            Checkpoint::AfterCopy,
            Checkpoint::BeforeSwap,
            Checkpoint::AfterSwap,
        ] {
            let mut f = Fixture::new();
            f.fault(point);
            let armed = f.armed();
            let id = armed.transaction();
            f.consent(&armed);
            let _ = f.installer.run_helper(armed).unwrap();
            let before = fingerprint(&f.installer.target()).unwrap();
            let result = f.installer.account_recovery(id).unwrap();
            assert_eq!(before, fingerprint(&f.installer.target()).unwrap());
            if point == Checkpoint::AfterSwap {
                assert!(matches!(
                    result,
                    RecoveryAccounting::InstalledWithBackup { .. }
                ));
                assert_eq!(f.version(), "0.2.0");
            } else {
                assert!(matches!(result, RecoveryAccounting::NotExchanged { .. }));
                assert_eq!(f.version(), "0.1.0");
            }
        }
    }
    #[test]
    fn receipt_failure_does_not_misreport_a_verified_success() {
        let mut f = Fixture::new();
        f.fault(Checkpoint::BeforeCommit);
        let armed = f.armed();
        let id = armed.transaction();
        f.consent(&armed);
        let InstallOutcome::Installed {
            receipt_warning, ..
        } = f.installer.run_helper(armed).unwrap()
        else {
            panic!("must report installed")
        };
        assert!(receipt_warning.is_some());
        assert_eq!(f.version(), "0.2.0");
        assert!(matches!(
            f.installer.account_recovery(id).unwrap(),
            RecoveryAccounting::InstalledWithBackup {
                phase: Phase::Exchanged,
                ..
            }
        ));
    }
    #[test]
    fn outcome_diagnostic_records_pre_exchange_rejection_without_changing_target_or_journal() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let mut f = Fixture::new();
        let exchange = Arc::new(FailureExchange {
            calls: AtomicUsize::new(0),
            fail_on: usize::MAX,
        });
        f.installer.dependencies.exchange = exchange.clone();
        let armed = f.armed();
        let id = armed.transaction();
        let directory = armed.directory.clone();
        f.consent(&armed);
        let before = fingerprint(&f.installer.target()).unwrap();
        f.processes.stopped.store(false, Ordering::SeqCst);
        assert!(matches!(
            f.installer.run_helper(armed).unwrap(),
            InstallOutcome::NotInstalled { .. }
        ));
        assert_eq!(exchange.calls.load(Ordering::SeqCst), 0);
        assert_eq!(fingerprint(&f.installer.target()).unwrap(), before);
        let path = directory.join("outcome.json");
        let record: Value = read_json(&path).unwrap();
        assert_eq!(
            record,
            serde_json::json!({"format":1,"transaction":id,"outcome":"NotInstalled","stage":"stopped-target-proof","reason":"Replacement was not installed; inspect retained transaction state"})
        );
        let metadata = fs::symlink_metadata(path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(metadata.nlink(), 1);
        assert!(metadata.len() <= 4096);
        assert_eq!(
            read_json::<Journal>(&directory.join("journal.json"))
                .unwrap()
                .phase,
            Phase::Armed
        );
        assert!(matches!(
            f.installer.account_recovery(id).unwrap(),
            RecoveryAccounting::NotExchanged {
                phase: Phase::Armed,
                ..
            }
        ));
        assert!(!fs::read_dir(directory).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".outcome-")
        }));
    }
    #[test]
    fn outcome_diagnostic_write_failure_preserves_installed_result_without_reexchange_or_following_symlink()
     {
        let mut f = Fixture::new();
        let exchange = Arc::new(FailureExchange {
            calls: AtomicUsize::new(0),
            fail_on: usize::MAX,
        });
        f.installer.dependencies.exchange = exchange.clone();
        let armed = f.armed();
        let id = armed.transaction();
        let directory = armed.directory.clone();
        f.consent(&armed);
        let outside = f.root.path().join("synthetic-untouched-diagnostic-target");
        fs::write(&outside, b"synthetic sentinel").unwrap();
        std::os::unix::fs::symlink(&outside, directory.join("outcome.json")).unwrap();
        let InstallOutcome::Installed {
            receipt_warning, ..
        } = f.installer.run_helper(armed).unwrap()
        else {
            panic!("Diagnostic failure cannot turn a verified exchange into failure")
        };
        assert!(
            receipt_warning
                .unwrap()
                .contains("Outcome diagnostic could not be persisted")
        );
        assert_eq!(f.version(), "0.2.0");
        assert_eq!(exchange.calls.load(Ordering::SeqCst), 1);
        assert_eq!(fs::read(outside).unwrap(), b"synthetic sentinel");
        assert!(
            fs::symlink_metadata(directory.join("outcome.json"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(matches!(
            f.installer.account_recovery(id).unwrap(),
            RecoveryAccounting::InstalledWithBackup {
                phase: Phase::Committed,
                ..
            }
        ));
        assert_eq!(exchange.calls.load(Ordering::SeqCst), 1);
        assert!(!fs::read_dir(directory).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".outcome-")
        }));
    }
    #[test]
    fn outcome_diagnostic_is_write_once_and_never_recovery_authority() {
        let f = Fixture::new();
        let armed = f.armed();
        let id = armed.transaction();
        let directory = armed.directory.clone();
        f.consent(&armed);
        let false_record = InstallOutcome::Installed {
            transaction: id,
            backup: f.installer.backup(id),
            receipt_warning: None,
        }
        .diagnostic(DiagnosticStage::FinalReceipt);
        persist_outcome(&directory, &false_record).unwrap();
        let bytes = fs::read(directory.join("outcome.json")).unwrap();
        assert!(
            persist_outcome(
                &directory,
                &InstallOutcome::NotInstalled {
                    transaction: id,
                    reason: "synthetic".into()
                }
                .diagnostic(DiagnosticStage::StoppedTargetProof)
            )
            .is_err()
        );
        assert_eq!(fs::read(directory.join("outcome.json")).unwrap(), bytes);
        // Release only the consumed capability's target lock; leave the actual
        // Armed journal intact, as a process interruption would.
        drop(armed);
        // Even a syntactically valid diagnostic claiming Installed cannot
        // authorize exchange or change read-only recovery's actual Armed phase.
        assert!(matches!(
            f.installer.account_recovery(id).unwrap(),
            RecoveryAccounting::NotExchanged {
                phase: Phase::Armed,
                ..
            }
        ));
        assert_eq!(f.version(), "0.1.0");
    }
    #[test]
    fn low_destination_disk_and_cancel_preserve_original_target() {
        let f = Fixture::new();
        let armed = f.armed();
        f.consent(&armed);
        f.disk.0.store(0, Ordering::SeqCst);
        assert!(matches!(
            f.installer.run_helper(armed).unwrap(),
            InstallOutcome::NotInstalled { .. }
        ));
        assert_eq!(f.version(), "0.1.0");
        let f = Fixture::new();
        let armed = f.armed();
        let id = armed.transaction();
        f.consent(&armed);
        f.installer.cancel(armed).unwrap();
        assert!(
            !f.installer
                .transaction_dir(id)
                .join("clean-quit.json")
                .exists()
        );
        assert_eq!(f.version(), "0.1.0");
    }
    #[test]
    fn recovery_rejects_modified_journal_target_and_anchor_without_following_paths() {
        let f = Fixture::new();
        let armed = f.armed();
        let id = armed.transaction();
        let directory = f.installer.transaction_dir(id);
        f.installer.cancel(armed).unwrap();
        let mut journal: Journal = read_json(&directory.join("journal.json")).unwrap();
        journal.proposal.target = f.root.path().join("Coincide.app");
        journal.proposal_sha256 = proposal_hash(&journal.proposal).unwrap();
        fs::write(
            directory.join("journal.json"),
            serde_json::to_vec(&journal).unwrap(),
        )
        .unwrap();
        assert!(f.installer.account_recovery(id).is_err());
    }
    #[test]
    fn owned_temp_script_process_requires_status_zero_not_just_process_disappearance() {
        for status in [0, 7] {
            let f = Fixture::new();
            let script = f.root.path().join("owned-parent.sh");
            fs::write(&script, format!("#!/bin/sh\nexit {status}\n")).unwrap();
            let child = Command::new("/bin/sh")
                .arg(&script)
                .current_dir(f.root.path())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            *f.processes.child.lock().unwrap() = Some(child);
            let armed = f.armed();
            f.consent(&armed);
            let result = f.installer.run_helper(armed).unwrap();
            if status == 0 {
                assert!(matches!(result, InstallOutcome::Installed { .. }));
            } else {
                assert!(matches!(result, InstallOutcome::NotInstalled { .. }));
                assert_eq!(f.version(), "0.1.0");
            }
        }
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn real_mac_process_observer_binds_owned_child_start_and_exit_status() {
        for status in [0, 9] {
            let root = temp();
            let script = root.path().join("observed-parent.sh");
            let gate = root.path().join("release-parent");
            fs::write(
                &script,
                format!("#!/bin/sh\nwhile [ ! -f \"$1\" ]; do sleep 0.01; done\nexit {status}\n"),
            )
            .unwrap();
            let mut child = Command::new("/bin/sh")
                .arg(&script)
                .arg(&gate)
                .current_dir(root.path())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let mut watch = MacParentWatch::observe(child.id() as i32).unwrap();
            assert_eq!(watch.binding().pid, child.id());
            fs::write(gate, b"release fixture").unwrap();
            assert_eq!(
                watch.wait_clean_exit(Duration::from_secs(3)).is_ok(),
                status == 0
            );
            let _ = child.wait();
        }
    }
    #[test]
    fn expired_authorization_and_post_arm_target_change_are_rejected() {
        let f = Fixture::new();
        let mut auth = f.authorization();
        auth.expires = Instant::now() - Duration::from_secs(1);
        assert!(f.installer.arm(auth).is_err());
        let armed = f.armed();
        f.consent(&armed);
        let main = f.installer.target().join("Contents/MacOS/coincide-rust");
        fs::write(&main, b"target changed after helper readiness").unwrap();
        let changed = fingerprint(&f.installer.target()).unwrap();
        assert!(matches!(
            f.installer.run_helper(armed).unwrap(),
            InstallOutcome::NotInstalled { .. }
        ));
        assert_eq!(fingerprint(&f.installer.target()).unwrap(), changed);
    }
    #[test]
    fn dropping_an_armed_capability_never_leaves_an_implicit_install_authorization() {
        let f = Fixture::new();
        let armed = f.armed();
        let id = armed.transaction();
        drop(armed);
        assert_eq!(f.version(), "0.1.0");
        assert!(matches!(
            f.installer.account_recovery(id).unwrap(),
            RecoveryAccounting::NotExchanged { .. }
        ));
        assert!(
            f.installer
                .request_native_authorization(&f.updater)
                .unwrap()
                .is_some()
        );
    }
    #[test]
    fn separate_helper_instances_cannot_race_one_target() {
        let f = Fixture::new();
        let other =
            Installer::configured(f.installer.config.clone(), f.installer.dependencies.clone())
                .unwrap();
        let second = other
            .request_native_authorization(&f.updater)
            .unwrap()
            .unwrap();
        let first = f.armed();
        assert!(other.arm(second).is_err());
        f.installer.cancel(first).unwrap();
        let second = other
            .arm(
                other
                    .request_native_authorization(&f.updater)
                    .unwrap()
                    .unwrap(),
            )
            .unwrap();
        other.cancel(second).unwrap();
        assert_eq!(f.version(), "0.1.0");
    }
}
