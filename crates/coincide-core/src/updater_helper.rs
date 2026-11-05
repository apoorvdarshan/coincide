//! Independent Rust-preview helper. The feature/bin is explicitly registered by
//! the parent and defaults OFF. No CLI path/approval/verified arguments, network,
//! elevation, signing, target termination or relaunch. Native code is invoked only
//! by the explicit helper entry; tests inject trust/parent/filesystem adapters.
#[cfg(any(target_os = "macos", all(test, unix)))]
use crate::updater;
#[cfg(target_os = "macos")]
use crate::updater_install;
use crate::{
    updater::{Architecture, Config, Dependencies, Platform, Release, Updater},
    updater_install::{
        InstallConfig, InstallDependencies, InstallOutcome, Installer, NativeApproval,
        NativeDecision, ParentBinding, ParentWatch, ProcessGuard, Proposal, ShutdownBarrier,
    },
};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
#[cfg(unix)]
use std::io::{Read, Write};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use uuid::Uuid;

pub const HELPER_ID: &str = "com.apoorvdarshan.coincide.rust.updater";
pub const HELPER_NAME: &str = "CoincideRustUpdater";
/// Exact Developer ID predicate; pure construction is fixture-testable on every
/// host. No ad hoc/unsigned or request-configured identity alternative exists.
pub fn helper_requirement(anchor: &str) -> Result<String> {
    code_requirement(anchor, HELPER_ID)
}
fn code_requirement(anchor: &str, identifier: &str) -> Result<String> {
    ensure!(
        anchor.len() == 10
            && anchor
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()),
        "Pinned Developer ID team required; unsigned/ad hoc helper is refused"
    );
    Ok(format!(
        "anchor apple generic and identifier \"{identifier}\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"{anchor}\""
    ))
}
pub const PROTOCOL: u8 = 1;
pub const MAX_FRAME: usize = 64 * 1024;
const APP: &str = "Coincide Rust.app";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Frame<T> {
    pub version: u8,
    pub session: Uuid,
    pub sequence: u64,
    pub body: T,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub challenge: Uuid,
    pub transaction: Uuid,
    pub proposal_sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ParentMessage {
    Select {
        job: Uuid,
        release: Release,
        client_nonce: Uuid,
    },
    Approve {
        binding: Binding,
    },
    Decline {
        binding: Binding,
    },
    ReadyAck {
        binding: Binding,
    },
    CleanQuit {
        binding: Binding,
    },
    Cancel {
        transaction: Option<Uuid>,
    },
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum HelperMessage {
    Proposal {
        binding: Binding,
        proposal: Box<Proposal>,
        client_nonce: Uuid,
    },
    Ready {
        binding: Binding,
        parent: ParentBinding,
    },
    Armed {
        binding: Binding,
    },
    ConsentAck {
        binding: Binding,
    },
    Disarmed {
        transaction: Option<Uuid>,
    },
    Finished {
        transaction: Uuid,
        status: String,
    },
}
/// Transport is exclusively the signed parent's inherited private pipes. Deadline
/// applies to header AND body/read/write. No detached blocking IO worker is used.
pub trait PrivateChannel: Send {
    fn receive(&mut self, deadline: Instant) -> Result<Frame<ParentMessage>>;
    fn send(&mut self, frame: &Frame<HelperMessage>, deadline: Instant) -> Result<()>;
}
/// Framing helpers are shared by both ends; reject length before allocation and
/// refuse trailing data/unknown fields. Actual pipe adapter adds hard IO deadlines.
pub fn encode_frame<T: Serialize>(frame: &Frame<T>) -> Result<Vec<u8>> {
    let body = serde_json::to_vec(frame)?;
    ensure!(
        !body.is_empty() && body.len() <= MAX_FRAME,
        "Helper frame exceeds limit"
    );
    let mut bytes = Vec::with_capacity(body.len() + 4);
    bytes.extend_from_slice(&(body.len() as u32).to_be_bytes());
    bytes.extend_from_slice(&body);
    Ok(bytes)
}
pub fn decode_frame<T: DeserializeOwned + Serialize>(bytes: &[u8]) -> Result<Frame<T>> {
    ensure!(bytes.len() >= 4, "Truncated helper frame header");
    let size = u32::from_be_bytes(bytes[..4].try_into()?) as usize;
    ensure!(
        size > 0 && size <= MAX_FRAME && bytes.len() == size + 4,
        "Invalid helper frame length"
    );
    decode_payload(&bytes[4..])
}
fn decode_payload<T: DeserializeOwned + Serialize>(bytes: &[u8]) -> Result<Frame<T>> {
    let frame: Frame<T> = serde_json::from_slice(bytes)?;
    // Release is shared with feed parsing and permits future metadata fields.
    // The private pipe protocol is closed: reject dropped/unknown nested fields
    // and noncanonical UUID representations instead of silently accepting flags.
    ensure!(
        serde_json::to_value(&frame)? == serde_json::from_slice::<serde_json::Value>(bytes)?,
        "Noncanonical or unknown helper protocol fields"
    );
    Ok(frame)
}
pub fn proposal_digest(proposal: &Proposal) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(proposal)?)
    ))
}
#[derive(Clone)]
pub struct ProtocolLimits {
    pub bootstrap: Duration,
    pub approval: Duration,
    pub ready_ack: Duration,
    pub clean_quit: Duration,
    pub send: Duration,
}
impl Default for ProtocolLimits {
    fn default() -> Self {
        Self {
            bootstrap: Duration::from_secs(5),
            approval: Duration::from_secs(900),
            ready_ack: Duration::from_secs(5),
            clean_quit: Duration::from_secs(7 * 24 * 3600),
            send: Duration::from_secs(5),
        }
    }
}
impl ProtocolLimits {
    fn validate(&self) -> Result<()> {
        for (value, maximum) in [
            (self.bootstrap, 30),
            (self.approval, 900),
            (self.ready_ack, 30),
            (self.clean_quit, 7 * 24 * 3600),
            (self.send, 30),
        ] {
            ensure!(
                !value.is_zero() && value <= Duration::from_secs(maximum),
                "Invalid helper deadline"
            );
        }
        Ok(())
    }
}
#[derive(Clone)]
pub struct HelperConfig {
    /// Trusted native startup configuration. Wire selection cannot change these.
    pub updater: Config,
    pub install: InstallConfig,
    pub protocol: ProtocolLimits,
}
#[derive(Clone, Debug)]
pub struct AuthenticatedParent {
    pub parent: ParentBinding,
    pub target: PathBuf,
    pub installed_version: String,
    pub architecture: Architecture,
}
/// Running process identity is distinct from signature checks on a bundle's
/// current filesystem bytes. This selector cannot contain a request path/ID.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RunningSubject {
    Helper,
    Parent(ParentBinding),
    /// Only a launcher-owned Child.id()/start binding, never a wire PID.
    ChildHelper(ParentBinding),
}
impl RunningSubject {
    pub fn identifier(&self) -> &'static str {
        match self {
            Self::Helper | Self::ChildHelper(_) => HELPER_ID,
            Self::Parent(_) => crate::updater::PREVIEW_ID,
        }
    }
}
pub trait RunningCodeTrust: Send + Sync {
    fn verify(&self, subject: &RunningSubject, anchor: &str) -> Result<()>;
}
fn verify_running_pair(
    parent: &ParentBinding,
    anchor: &str,
    trust: &dyn RunningCodeTrust,
) -> Result<()> {
    ensure!(parent.pid > 1, "Actual running parent required");
    trust.verify(&RunningSubject::Helper, anchor)?;
    trust.verify(&RunningSubject::Parent(parent.clone()), anchor)
}
/// Must verify self's fixed helper signature/identity and the actual parent's
/// preview bundle/team/executable AND dynamically running code before returning.
/// Keep PID/start/path snapshots around those checks. Not a user boolean proof.
pub trait RuntimeIdentity: Send + Sync {
    fn authenticate(
        &self,
        config: &HelperConfig,
        running: &dyn RunningCodeTrust,
    ) -> Result<AuthenticatedParent>;
}
#[derive(Clone)]
pub struct HelperDependencies {
    pub identity: Arc<dyn RuntimeIdentity>,
    pub running: Arc<dyn RunningCodeTrust>,
    pub staging: Dependencies,
    pub installation: InstallDependencies,
}
#[derive(Debug, PartialEq, Eq)]
pub enum HelperOutcome {
    Declined,
    Cancelled,
    Finished(InstallOutcome),
}
struct Session {
    channel: Box<dyn PrivateChannel>,
    id: Uuid,
    client_nonce: Uuid,
    challenge: Uuid,
    incoming: u64,
    outgoing: u64,
    frames: usize,
    limits: ProtocolLimits,
    cancelled: bool,
}
impl Session {
    fn receive(&mut self, timeout: Duration) -> Result<ParentMessage> {
        ensure!(self.frames < 16, "Helper protocol frame count exceeded");
        let frame = self.channel.receive(Instant::now() + timeout)?;
        ensure!(
            frame.version == PROTOCOL
                && frame.session == self.id
                && frame.sequence == self.incoming,
            "Helper protocol version/session/sequence mismatch"
        );
        self.incoming = self
            .incoming
            .checked_add(1)
            .context("Helper sequence overflow")?;
        self.frames += 1;
        Ok(frame.body)
    }
    fn send(&mut self, body: HelperMessage) -> Result<()> {
        let frame = Frame {
            version: PROTOCOL,
            session: self.id,
            sequence: self.outgoing,
            body,
        };
        self.channel
            .send(&frame, Instant::now() + self.limits.send)?;
        self.outgoing = self
            .outgoing
            .checked_add(1)
            .context("Helper sequence overflow")?;
        Ok(())
    }
    fn binding(&self, proposal: &Proposal) -> Result<Binding> {
        Ok(Binding {
            challenge: self.challenge,
            transaction: proposal.transaction,
            proposal_sha256: proposal_digest(proposal)?,
        })
    }
    fn acknowledge_disarm(&mut self, transaction: Option<Uuid>) -> Result<()> {
        self.send(HelperMessage::Disarmed { transaction })
    }
}
type SharedSession = Arc<Mutex<Session>>;
fn locked(session: &SharedSession) -> Result<std::sync::MutexGuard<'_, Session>> {
    session
        .lock()
        .map_err(|_| anyhow::anyhow!("Helper session lock failed"))
}
struct ApprovalProxy(SharedSession);
impl NativeApproval for ApprovalProxy {
    fn present(&self, proposal: &Proposal) -> Result<NativeDecision> {
        let mut session = locked(&self.0)?;
        let binding = session.binding(proposal)?;
        let client_nonce = session.client_nonce;
        session.send(HelperMessage::Proposal {
            binding: binding.clone(),
            proposal: Box::new(proposal.clone()),
            client_nonce,
        })?;
        let timeout = session.limits.approval;
        match session.receive(timeout)? {
            ParentMessage::Approve { binding: received } => {
                ensure!(received == binding, "Native approval binding differs");
                Ok(NativeDecision::Approve)
            }
            ParentMessage::Decline { binding: received } => {
                ensure!(received == binding, "Native decline binding differs");
                session.acknowledge_disarm(Some(proposal.transaction))?;
                Ok(NativeDecision::Decline)
            }
            ParentMessage::Cancel { transaction } => {
                ensure!(
                    transaction.is_none() || transaction == Some(proposal.transaction),
                    "Cancellation transaction differs"
                );
                session.cancelled = true;
                session.acknowledge_disarm(transaction)?;
                Ok(NativeDecision::Decline)
            }
            _ => bail!("Native proposal decision required"),
        }
    }
}
struct CleanQuitProxy {
    session: SharedSession,
    running: Arc<dyn RunningCodeTrust>,
    parent: ParentBinding,
    anchor: String,
}
impl ShutdownBarrier for CleanQuitProxy {
    fn quiesce_and_flush(&self, proposal: &Proposal) -> Result<()> {
        let mut session = locked(&self.session)?;
        let binding = session.binding(proposal)?;
        let timeout = session.limits.clean_quit;
        match session.receive(timeout)? {
            ParentMessage::CleanQuit { binding: received } => {
                ensure!(received == binding, "Post-flush clean-quit binding differs");
                // The normal-quit wait can last days; do not authorize consent
                // using only an earlier valid process/disk identity snapshot.
                verify_running_pair(&self.parent, &self.anchor, self.running.as_ref())?;
                Ok(())
            }
            ParentMessage::Cancel { transaction } => {
                ensure!(
                    transaction == Some(proposal.transaction),
                    "Cancellation transaction differs"
                );
                // Engine cancellation/consent removal occurs before acknowledgement.
                session.cancelled = true;
                bail!("Native parent cancelled before clean-quit consent")
            }
            _ => bail!("Post-flush private clean-quit message required"),
        }
    }
}
struct BoundProcessGuard {
    expected: ParentBinding,
    native: Arc<dyn ProcessGuard>,
    running: Arc<dyn RunningCodeTrust>,
    anchor: String,
}
impl ProcessGuard for BoundProcessGuard {
    fn observe_parent(&self, target: &std::path::Path) -> Result<Box<dyn ParentWatch>> {
        let watch = self.native.observe_parent(target)?;
        ensure!(
            watch.binding() == self.expected,
            "Authenticated parent instance changed before readiness"
        );
        // Approval can remain open for minutes. Recheck running identities after
        // the first observer and confirm the native path/start binding again before
        // reporting READY; never keep only the earlier static authentication.
        verify_running_pair(&self.expected, &self.anchor, self.running.as_ref())?;
        let after = self.native.observe_parent(target)?;
        ensure!(
            after.binding() == self.expected,
            "Parent changed during dynamic readiness verification"
        );
        drop(watch);
        Ok(after)
    }
    fn ensure_stopped(&self, target: &std::path::Path) -> Result<()> {
        self.native.ensure_stopped(target)
    }
}

/// Complete independent flow. No opaque approval is deserialized. Real trust is
/// re-established in this process, then Installer mints/owns its capability. The
/// clean-quit command is private native lifecycle traffic, never a request flag.
pub fn serve(
    config: HelperConfig,
    dependencies: HelperDependencies,
    mut channel: Box<dyn PrivateChannel>,
) -> Result<HelperOutcome> {
    config.protocol.validate()?;
    let authenticated = dependencies
        .identity
        .authenticate(&config, dependencies.running.as_ref())?;
    ensure!(
        authenticated.parent.pid > 1
            && authenticated.target == config.install.target_parent.join(APP)
            && authenticated.installed_version == config.updater.current_version
            && authenticated.architecture == config.updater.architecture
            && config.updater.platform == Platform::Macos
            && config.updater.trust_anchor == config.install.trust_anchor,
        "Authenticated preview parent/configuration differs"
    );
    let first = channel.receive(Instant::now() + config.protocol.bootstrap)?;
    ensure!(
        first.version == PROTOCOL && first.sequence == 0 && !first.session.is_nil(),
        "Invalid helper bootstrap envelope"
    );
    let ParentMessage::Select {
        job,
        release,
        client_nonce,
    } = first.body
    else {
        bail!("Private UUID selection required")
    };
    ensure!(!client_nonce.is_nil(), "Bootstrap nonce required");
    let updater = Updater::reopen_for_helper(config.updater, dependencies.staging, job, release)?;
    let session = Arc::new(Mutex::new(Session {
        channel,
        id: first.session,
        client_nonce,
        challenge: Uuid::new_v4(),
        incoming: 1,
        outgoing: 0,
        frames: 1,
        limits: config.protocol,
        cancelled: false,
    }));
    let mut installation = dependencies.installation;
    installation.approval = Arc::new(ApprovalProxy(session.clone()));
    let running = dependencies.running;
    installation.processes = Arc::new(BoundProcessGuard {
        expected: authenticated.parent.clone(),
        native: installation.processes,
        running: running.clone(),
        anchor: config.install.trust_anchor.clone(),
    });
    let installer = Installer::configured(config.install, installation)?;
    let Some(authorization) = installer.request_native_authorization(&updater)? else {
        return Ok(if locked(&session)?.cancelled {
            HelperOutcome::Cancelled
        } else {
            HelperOutcome::Declined
        });
    };
    let proposal = authorization.proposal().clone();
    let armed = installer.arm(authorization)?;
    let binding = locked(&session)?.binding(&proposal)?;
    let ready_result = (|| -> Result<()> {
        let mut session = locked(&session)?;
        session.send(HelperMessage::Ready {
            binding: binding.clone(),
            parent: armed.parent_binding(),
        })?;
        let timeout = session.limits.ready_ack;
        match session.receive(timeout)? {
            ParentMessage::ReadyAck { binding: received } => {
                ensure!(received == binding, "READY acknowledgement binding differs")
            }
            ParentMessage::Cancel { transaction } => {
                ensure!(
                    transaction == Some(proposal.transaction),
                    "Cancellation transaction differs"
                );
                session.cancelled = true;
                bail!("Native parent cancelled readiness")
            }
            _ => bail!("READY acknowledgement required before clean quit"),
        }
        session.send(HelperMessage::Armed {
            binding: binding.clone(),
        })
    })();
    if let Err(error) = ready_result {
        let cancelled = locked(&session)?.cancelled;
        installer.cancel(armed)?;
        if cancelled {
            locked(&session)?.send(HelperMessage::Disarmed {
                transaction: Some(proposal.transaction),
            })?;
            return Ok(HelperOutcome::Cancelled);
        }
        return Err(error);
    }
    if let Err(error) = armed.authorize_clean_quit(&CleanQuitProxy {
        session: session.clone(),
        running,
        parent: authenticated.parent,
        anchor: proposal.anchor.clone(),
    }) {
        let cancelled = locked(&session)?.cancelled;
        installer.cancel(armed)?;
        if cancelled {
            locked(&session)?.send(HelperMessage::Disarmed {
                transaction: Some(proposal.transaction),
            })?;
            return Ok(HelperOutcome::Cancelled);
        }
        return Err(error);
    }
    // A failed ACK never falls through into replacement. This may leave a parent
    // uncertain, but does not falsely replace after losing its private channel.
    if let Err(error) = locked(&session)?.send(HelperMessage::ConsentAck { binding }) {
        installer.cancel(armed)?;
        return Err(error);
    }
    let outcome = installer.run_helper(armed)?;
    let status = match &outcome {
        InstallOutcome::Installed { .. } => "installed",
        InstallOutcome::RolledBack { .. } => "rolled_back",
        InstallOutcome::NotInstalled { .. } => "not_installed",
        InstallOutcome::RecoveryRequired { .. } => "recovery_required",
    };
    // Parent normally exited; final pipe reporting is diagnostic, not install proof.
    let _ = locked(&session)?.send(HelperMessage::Finished {
        transaction: proposal.transaction,
        status: status.into(),
    });
    Ok(HelperOutcome::Finished(outcome))
}

/// Validate the descriptor itself, never a /proc path or caller-supplied label.
#[cfg(unix)]
fn validate_anonymous_pipe(fd: i32) -> Result<()> {
    let mut info = std::mem::MaybeUninit::<libc::stat>::uninit();
    ensure!(
        unsafe { libc::fstat(fd, info.as_mut_ptr()) } == 0,
        "Pipe stat failed"
    );
    let info = unsafe { info.assume_init() };
    ensure!(
        info.st_mode & libc::S_IFMT == libc::S_IFIFO && info.st_uid == unsafe { libc::geteuid() },
        "Owned FIFO descriptor required"
    );
    #[cfg(target_os = "linux")]
    {
        // Linux anonymous pipes retain the initial inode link count (1), and
        // both kinds report S_IFIFO. The kernel distinguishes them by pipefs:
        // linux v6.12 fs/pipe.c get_pipe_inode/fifo_open/pipefs_init_fs_context;
        // include/uapi/linux/magic.h defines PIPEFS_MAGIC. An unlinked named
        // FIFO still belongs to its original filesystem, not internal pipefs.
        let mut filesystem = std::mem::MaybeUninit::<libc::statfs>::uninit();
        ensure!(
            unsafe { libc::fstatfs(fd, filesystem.as_mut_ptr()) } == 0,
            "Pipe filesystem stat failed"
        );
        let filesystem = unsafe { filesystem.assume_init() };
        ensure!(
            filesystem.f_type == 0x5049_5045,
            "Anonymous pipefs descriptor required"
        );
    }
    #[cfg(not(target_os = "linux"))]
    {
        ensure!(info.st_nlink == 0, "Anonymous pipe descriptor required");
        #[cfg(target_os = "macos")]
        // XNU bsd/kern/sys_pipe.c pipe_stat leaves device/link count zero.
        // A named FIFO unlinked after opening also has zero links, but retains
        // its filesystem device. Do not treat unlink as proof of anonymity.
        ensure!(
            info.st_dev == 0,
            "Anonymous Darwin pipe descriptor required"
        );
    }
    Ok(())
}

#[cfg(unix)]
pub struct PipeChannel {
    input: std::fs::File,
    output: std::fs::File,
}
#[cfg(unix)]
impl PipeChannel {
    /// Only explicit independent-helper entry calls this. Duplicates close-on-exec
    /// anonymous pipe FDs; does not open paths/sockets or accept external peers.
    pub fn from_stdio() -> Result<Self> {
        use std::os::fd::FromRawFd;
        fn duplicate(fd: i32) -> Result<std::fs::File> {
            validate_anonymous_pipe(fd).context("Private anonymous helper pipes required")?;
            let copied = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
            ensure!(copied >= 0, "Cannot duplicate helper pipe");
            let file = unsafe { std::fs::File::from_raw_fd(copied) };
            nonblocking(&file)?;
            Ok(file)
        }
        Ok(Self {
            input: duplicate(0)?,
            output: duplicate(1)?,
        })
    }
    fn read_exact(&mut self, mut bytes: &mut [u8], deadline: Instant) -> Result<()> {
        while !bytes.is_empty() {
            wait_pipe(&self.input, libc::POLLIN, deadline)?;
            match self.input.read(bytes) {
                Ok(0) => bail!("Helper private input closed"),
                Ok(size) => {
                    bytes = &mut bytes[size..];
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                    ) => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }
}
#[cfg(unix)]
fn nonblocking(file: &std::fs::File) -> Result<()> {
    use std::os::fd::AsRawFd;
    let fd = file.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    ensure!(
        flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == 0,
        "Cannot bound helper pipe IO"
    );
    Ok(())
}
#[cfg(unix)]
fn wait_pipe(file: &std::fs::File, events: i16, deadline: Instant) -> Result<()> {
    use std::os::fd::AsRawFd;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        ensure!(!remaining.is_zero(), "Helper private pipe deadline expired");
        let mut descriptor = libc::pollfd {
            fd: file.as_raw_fd(),
            events,
            revents: 0,
        };
        let count = unsafe {
            libc::poll(
                &mut descriptor,
                1,
                remaining.as_millis().clamp(1, 1000) as i32,
            )
        };
        if count < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error.into());
        }
        if count == 0 {
            continue;
        }
        ensure!(
            descriptor.revents & libc::POLLNVAL == 0,
            "Helper private pipe invalid"
        );
        if descriptor.revents & (events | libc::POLLHUP | libc::POLLERR) != 0 {
            return Ok(());
        }
    }
}
#[cfg(unix)]
impl PrivateChannel for PipeChannel {
    fn receive(&mut self, deadline: Instant) -> Result<Frame<ParentMessage>> {
        let mut header = [0u8; 4];
        self.read_exact(&mut header, deadline)?;
        let size = u32::from_be_bytes(header) as usize;
        ensure!(
            size > 0 && size <= MAX_FRAME,
            "Helper private frame length rejected"
        );
        let mut bytes = vec![0u8; size];
        self.read_exact(&mut bytes, deadline)?;
        decode_payload(&bytes)
    }
    fn send(&mut self, frame: &Frame<HelperMessage>, deadline: Instant) -> Result<()> {
        let bytes = encode_frame(frame)?;
        write_pipe_bytes(&mut self.output, &bytes, deadline)
    }
}

#[cfg(unix)]
pub struct ParentPipeChannel {
    pipes: PipeChannel,
    incoming: Vec<u8>,
    started: Option<Instant>,
    frame_timeout: Duration,
}
#[cfg(unix)]
impl ParentPipeChannel {
    pub fn from_anonymous_files(
        input: std::fs::File,
        output: std::fs::File,
        frame_timeout: Duration,
    ) -> Result<Self> {
        use std::os::fd::AsRawFd;
        ensure!(
            !frame_timeout.is_zero() && frame_timeout <= Duration::from_secs(30),
            "Invalid parent pipe frame timeout"
        );
        for file in [&input, &output] {
            let fd = file.as_raw_fd();
            validate_anonymous_pipe(fd).context("Private anonymous parent pipes required")?;
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            ensure!(
                flags >= 0
                    && unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } == 0,
                "Cannot protect inherited parent pipe"
            );
            nonblocking(file)?;
        }
        Ok(Self {
            pipes: PipeChannel { input, output },
            incoming: Vec::new(),
            started: None,
            frame_timeout,
        })
    }
    pub fn send_parent(&mut self, frame: &Frame<ParentMessage>, deadline: Instant) -> Result<()> {
        let bytes = encode_frame(frame)?;
        write_pipe_bytes(&mut self.pipes.output, &bytes, deadline)
    }
    /// Nonblocking incremental reader: partial frames survive polling so UI
    /// cancellation never waits for a missing peer byte. Absolute deadlines remain
    /// hard, including a per-frame deadline beginning at the first header byte.
    pub fn poll_helper(&mut self, deadline: Instant) -> Result<Option<Frame<HelperMessage>>> {
        loop {
            let now = Instant::now();
            ensure!(
                now < deadline
                    && self
                        .started
                        .is_none_or(|start| now < start + self.frame_timeout),
                "Parent helper response/frame deadline expired"
            );
            let needed = if self.incoming.len() < 4 {
                4
            } else {
                let size = u32::from_be_bytes(self.incoming[..4].try_into()?) as usize;
                ensure!(
                    size > 0 && size <= MAX_FRAME,
                    "Parent helper frame length rejected"
                );
                size + 4
            };
            if self.incoming.len() == needed && needed > 4 {
                let frame = decode_frame(&self.incoming)?;
                self.incoming.clear();
                self.started = None;
                return Ok(Some(frame));
            }
            let mut bytes = [0u8; 8192];
            let count = (needed - self.incoming.len()).min(bytes.len());
            match self.pipes.input.read(&mut bytes[..count]) {
                Ok(0) => bail!("Private helper output closed"),
                Ok(size) => {
                    self.started.get_or_insert(now);
                    self.incoming.extend_from_slice(&bytes[..size]);
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(None),
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error.into()),
            }
        }
    }
}
#[cfg(unix)]
fn write_pipe_bytes(output: &mut std::fs::File, bytes: &[u8], deadline: Instant) -> Result<()> {
    let mut remaining = bytes;
    while !remaining.is_empty() {
        wait_pipe(output, libc::POLLOUT, deadline)?;
        match output.write(remaining) {
            Ok(0) => bail!("Private helper pipe output closed"),
            Ok(size) => remaining = &remaining[size..],
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

/// Opaque launcher-owned copy. Its only constructor derives OS account/cache and
/// current signed preview identity. No request-supplied paths or serialized proof.
/// The private job is retained when dropped: helper may outlive its quitting parent.
pub struct PreparedNativeHelper {
    executable: PathBuf,
    target: PathBuf,
    parent: ParentBinding,
    version: String,
    #[cfg(target_os = "macos")]
    anchor: String,
    #[cfg(target_os = "macos")]
    digest: String,
}
impl PreparedNativeHelper {
    pub fn executable(&self) -> &std::path::Path {
        &self.executable
    }
    pub fn target(&self) -> &std::path::Path {
        &self.target
    }
    pub fn parent(&self) -> &ParentBinding {
        &self.parent
    }
    pub fn installed_version(&self) -> &str {
        &self.version
    }
    /// Recheck copied bytes/signature AND actual child executable/start/dynamic
    /// identity. Caller supplies only its owned std::process::Child.id().
    pub fn verify_child(&self, pid: u32, deadline: Instant) -> Result<ParentBinding> {
        #[cfg(target_os = "macos")]
        {
            native::verify_launcher_child(self, pid, deadline)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (pid, deadline);
            bail!("Native signed helper child verification unavailable")
        }
    }
}
/// Worker-thread only. Native operations/UUID copy are never invoked at module
/// load or by default. Fixed existing private OS-account directories required.
pub fn prepare_native_helper(anchor: &str, deadline: Instant) -> Result<PreparedNativeHelper> {
    #[cfg(target_os = "macos")]
    {
        native::prepare_launcher(anchor, deadline)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (anchor, deadline);
        bail!("Native signed helper launcher unavailable")
    }
}

/// Actual native identity adapter. Non-Mac is unavailable; ad hoc/unsigned code
/// cannot satisfy the explicit Developer ID certificate+team+identifier predicate.
pub struct MacRuntimeIdentity;
impl RuntimeIdentity for MacRuntimeIdentity {
    fn authenticate(
        &self,
        config: &HelperConfig,
        running: &dyn RunningCodeTrust,
    ) -> Result<AuthenticatedParent> {
        #[cfg(target_os = "macos")]
        {
            native::authenticate(config, running)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (config, running);
            bail!("Independent signed preview helper is unavailable on this platform")
        }
    }
}
/// Security.framework running-code verification. Non-Mac is unavailable; this
/// never substitutes a static path check when the dynamic API denies access.
pub struct MacRunningCodeTrust;
impl RunningCodeTrust for MacRunningCodeTrust {
    fn verify(&self, subject: &RunningSubject, anchor: &str) -> Result<()> {
        #[cfg(target_os = "macos")]
        {
            native::verify_running_code(subject, anchor)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (subject, anchor);
            bail!("Dynamic running-code verification is unavailable on this platform")
        }
    }
}
/// Explicit bin entry only. Build configuration absent => disabled before pipe,
/// signature or process inspection. There are no runtime environment/CLI overrides.
pub fn native_main() -> Result<()> {
    ensure!(
        std::env::args_os().count() == 1,
        "Update helper accepts no command-line arguments"
    );
    #[cfg(target_os = "macos")]
    {
        let anchor = option_env!("COINCIDE_RUST_UPDATER_TEAM")
            .context("Preview updater team is not configured; helper disabled")?;
        let feed = option_env!("COINCIDE_RUST_UPDATER_FEED")
            .context("Preview updater feed is not configured; helper disabled")?;
        let base = option_env!("COINCIDE_RUST_UPDATER_ARTIFACT_BASE")
            .context("Preview updater artifact policy is not configured; helper disabled")?;
        let config = native::configuration(anchor, feed, base)?;
        let disk = Arc::new(updater::SystemDiskSpace);
        let dependencies = HelperDependencies {
            identity: Arc::new(MacRuntimeIdentity),
            running: Arc::new(MacRunningCodeTrust),
            staging: Dependencies {
                transport: Arc::new(OfflineTransport),
                extractor: Arc::new(updater::ZipExtractor),
                disk: disk.clone(),
                trust: Arc::new(NoStoredTrust),
            },
            installation: InstallDependencies {
                verifier: Arc::new(updater_install::MacCodeVerifier),
                approval: Arc::new(updater_install::UnavailableNativeApproval),
                processes: Arc::new(updater_install::MacProcessGuard),
                exchange: Arc::new(updater_install::NativeExchange),
                disk,
            },
        };
        let _ = serve(config, dependencies, Box::new(PipeChannel::from_stdio()?))?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        bail!("Independent signed preview helper is unavailable on this platform")
    }
}
#[cfg(target_os = "macos")]
struct OfflineTransport;
#[cfg(target_os = "macos")]
impl updater::Transport for OfflineTransport {
    fn fetch(
        &self,
        _: &url::Url,
        _: &updater::RequestPolicy,
        _: &mut dyn Write,
        _: &updater::OperationContext,
    ) -> Result<updater::Response> {
        bail!("Independent install helper never performs network requests")
    }
}
#[cfg(any(target_os = "macos", all(test, unix)))]
struct NoStoredTrust;
#[cfg(any(target_os = "macos", all(test, unix)))]
impl updater::TrustVerifier for NoStoredTrust {
    fn verify(
        &self,
        _: &std::path::Path,
        _: &Release,
        _: &str,
        _: &updater::OperationContext,
    ) -> Result<updater::TrustReport> {
        bail!("Stored stage flags cannot authorize helper trust")
    }
}

#[cfg(target_os = "macos")]
mod native {
    use super::*;
    use crate::updater::{DiskSpace, Limits};
    use crate::updater_install::BundleVerifier;
    use std::{
        collections::BTreeSet,
        ffi::{CStr, OsString},
        fs::{self, File},
        os::unix::{
            ffi::OsStringExt,
            fs::{MetadataExt, PermissionsExt},
        },
        path::Path,
        process::{Command, Stdio},
        thread,
    };
    type CfRef = *const std::ffi::c_void;
    type CfRetain = Option<unsafe extern "C" fn(CfRef, CfRef) -> CfRef>;
    type CfRelease = Option<unsafe extern "C" fn(CfRef, CfRef)>;
    type CfDescription = Option<unsafe extern "C" fn(CfRef) -> CfRef>;
    type CfEqual = Option<unsafe extern "C" fn(CfRef, CfRef) -> u8>;
    #[repr(C)]
    struct CfDictionaryKeyCallbacks {
        version: isize,
        retain: CfRetain,
        release: CfRelease,
        description: CfDescription,
        equal: CfEqual,
        hash: Option<unsafe extern "C" fn(CfRef) -> usize>,
    }
    #[repr(C)]
    struct CfDictionaryValueCallbacks {
        version: isize,
        retain: CfRetain,
        release: CfRelease,
        description: CfDescription,
        equal: CfEqual,
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        #[link_name = "CFRelease"]
        fn cf_release(value: CfRef);
        #[link_name = "CFStringCreateWithCString"]
        fn cf_string_create(allocator: CfRef, value: *const libc::c_char, encoding: u32) -> CfRef;
        #[link_name = "CFNumberCreate"]
        fn cf_number_create(allocator: CfRef, kind: isize, value: CfRef) -> CfRef;
        #[link_name = "CFDictionaryCreate"]
        fn cf_dictionary_create(
            allocator: CfRef,
            keys: *const CfRef,
            values: *const CfRef,
            count: isize,
            key_callbacks: *const CfDictionaryKeyCallbacks,
            value_callbacks: *const CfDictionaryValueCallbacks,
        ) -> CfRef;
        #[link_name = "kCFTypeDictionaryKeyCallBacks"]
        static CF_TYPE_KEYS: CfDictionaryKeyCallbacks;
        #[link_name = "kCFTypeDictionaryValueCallBacks"]
        static CF_TYPE_VALUES: CfDictionaryValueCallbacks;
    }
    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        #[link_name = "kSecGuestAttributePid"]
        static SEC_GUEST_PID: CfRef;
        #[link_name = "SecCodeCopySelf"]
        fn sec_code_copy_self(flags: u32, code: *mut CfRef) -> i32;
        #[link_name = "SecCodeCopyGuestWithAttributes"]
        fn sec_code_copy_guest(host: CfRef, attributes: CfRef, flags: u32, code: *mut CfRef)
        -> i32;
        #[link_name = "SecRequirementCreateWithString"]
        fn sec_requirement_create(text: CfRef, flags: u32, requirement: *mut CfRef) -> i32;
        #[link_name = "SecCodeCheckValidity"]
        fn sec_code_check_validity(code: CfRef, flags: u32, requirement: CfRef) -> i32;
    }
    struct OwnedCf(CfRef);
    impl OwnedCf {
        fn new(value: CfRef) -> Result<Self> {
            ensure!(
                !value.is_null(),
                "Security/CoreFoundation object unavailable"
            );
            Ok(Self(value))
        }
        fn copied(status: i32, value: CfRef) -> Result<Self> {
            if status != 0 {
                if !value.is_null() {
                    unsafe { cf_release(value) };
                }
                bail!(
                    "Running-code lookup/requirement unavailable or unauthorized (OSStatus {status})"
                );
            }
            Self::new(value)
        }
    }
    impl Drop for OwnedCf {
        fn drop(&mut self) {
            unsafe { cf_release(self.0) };
        }
    }
    /// These are DYNAMIC SecCode objects, never SecStaticCode translations.
    /// Apple SecCode.h states this call is secure against modification of the
    /// filesystem source. Default flags do not skip dynamic executable validation.
    pub(super) fn verify_running_code(subject: &RunningSubject, anchor: &str) -> Result<()> {
        let requirement = std::ffi::CString::new(code_requirement(anchor, subject.identifier())?)?;
        // CFStringEncodingUTF8 and kCFNumberSInt32Type from SDK CF headers.
        let text = OwnedCf::new(unsafe {
            cf_string_create(std::ptr::null(), requirement.as_ptr(), 0x08000100)
        })?;
        let mut raw_requirement = std::ptr::null();
        let status = unsafe { sec_requirement_create(text.0, 0, &mut raw_requirement) };
        let requirement = OwnedCf::copied(status, raw_requirement)?;
        let mut raw_code = std::ptr::null();
        let (before, before_path) = match subject {
            RunningSubject::Helper => {
                let pid = unsafe { libc::getpid() };
                (process_binding(pid)?, process_path(pid)?)
            }
            RunningSubject::Parent(expected) | RunningSubject::ChildHelper(expected) => {
                let pid = i32::try_from(expected.pid).context("Running parent PID overflow")?;
                ensure!(
                    pid > 1 && process_binding(pid)? == *expected,
                    "Running parent start identity differs"
                );
                (expected.clone(), process_path(pid)?)
            }
        };
        match subject {
            RunningSubject::Helper => {
                let status = unsafe { sec_code_copy_self(0, &mut raw_code) };
                let code = OwnedCf::copied(status, raw_code)?;
                let status = unsafe { sec_code_check_validity(code.0, 0, requirement.0) };
                ensure!(
                    status == 0,
                    "Dynamically running helper is not trusted (OSStatus {status})"
                );
            }
            RunningSubject::Parent(expected) | RunningSubject::ChildHelper(expected) => {
                let pid = i32::try_from(expected.pid).context("Running parent PID overflow")?;
                let number = OwnedCf::new(unsafe {
                    cf_number_create(std::ptr::null(), 3, (&pid as *const i32).cast())
                })?;
                let keys = [unsafe { SEC_GUEST_PID }];
                let values = [number.0];
                let attributes = OwnedCf::new(unsafe {
                    cf_dictionary_create(
                        std::ptr::null(),
                        keys.as_ptr(),
                        values.as_ptr(),
                        1,
                        std::ptr::addr_of!(CF_TYPE_KEYS),
                        std::ptr::addr_of!(CF_TYPE_VALUES),
                    )
                })?;
                // NULL host asks the kernel for the actual running PID. This does
                // NOT obtain static code from a caller-selected filesystem path.
                let status = unsafe {
                    sec_code_copy_guest(std::ptr::null(), attributes.0, 0, &mut raw_code)
                };
                let code = OwnedCf::copied(status, raw_code)?;
                let status = unsafe { sec_code_check_validity(code.0, 0, requirement.0) };
                ensure!(
                    status == 0,
                    "Dynamically running guest identity is not trusted (OSStatus {status})"
                );
            }
        }
        let pid = i32::try_from(before.pid).context("Running PID overflow")?;
        ensure!(
            process_binding(pid)? == before && process_path(pid)? == before_path,
            "Running process changed during dynamic code verification"
        );
        Ok(())
    }
    #[link(name = "proc")]
    unsafe extern "C" {
        fn proc_pidpath(
            pid: libc::c_int,
            buffer: *mut libc::c_void,
            buffersize: u32,
        ) -> libc::c_int;
        fn proc_pidinfo(
            pid: libc::c_int,
            flavor: libc::c_int,
            arg: u64,
            buffer: *mut libc::c_void,
            buffersize: libc::c_int,
        ) -> libc::c_int;
    }
    fn anchor_valid(anchor: &str) -> Result<()> {
        helper_requirement(anchor).map(|_| ())
    }

    fn process_path(pid: i32) -> Result<PathBuf> {
        let mut bytes = [0u8; 4096];
        let count = unsafe { proc_pidpath(pid, bytes.as_mut_ptr().cast(), bytes.len() as u32) };
        ensure!(
            count > 0 && (count as usize) < bytes.len(),
            "Native executable path unavailable"
        );
        let end = bytes
            .iter()
            .position(|b| *b == 0)
            .context("Unterminated native executable path")?;
        Ok(PathBuf::from(OsString::from_vec(bytes[..end].to_vec())))
    }
    fn process_binding(pid: i32) -> Result<ParentBinding> {
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
        let size = std::mem::size_of::<libc::proc_bsdinfo>();
        ensure!(
            unsafe {
                proc_pidinfo(
                    pid,
                    libc::PROC_PIDTBSDINFO,
                    0,
                    info.as_mut_ptr().cast(),
                    size as i32,
                )
            } == size as i32,
            "Parent process start identity unavailable"
        );
        let info = unsafe { info.assume_init() };
        ensure!(info.pbi_pid == pid as u32, "Native parent PID differs");
        Ok(ParentBinding {
            pid: pid as u32,
            start_seconds: info.pbi_start_tvsec,
            start_micros: info.pbi_start_tvusec,
        })
    }
    fn no_links(path: &Path) -> Result<()> {
        ensure!(
            path.is_absolute()
                && !path
                    .components()
                    .any(|p| matches!(p, std::path::Component::ParentDir)),
            "Absolute native path required"
        );
        for p in path.ancestors() {
            ensure!(
                !fs::symlink_metadata(p)?.file_type().is_symlink(),
                "Native path traverses symlink"
            );
        }
        ensure!(path.canonicalize()? == path, "Native path is not canonical");
        Ok(())
    }
    fn cache_root() -> Result<PathBuf> {
        let mut info = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut storage = vec![0u8; 64 * 1024];
        let mut result = std::ptr::null_mut();
        ensure!(
            unsafe {
                libc::getpwuid_r(
                    libc::geteuid(),
                    info.as_mut_ptr(),
                    storage.as_mut_ptr().cast(),
                    storage.len(),
                    &mut result,
                )
            } == 0
                && !result.is_null(),
            "Native home directory unavailable"
        );
        let info = unsafe { info.assume_init() };
        ensure!(!info.pw_dir.is_null(), "Native home directory missing");
        let home = unsafe { CStr::from_ptr(info.pw_dir) }.to_bytes().to_vec();
        let root = PathBuf::from(OsString::from_vec(home))
            .join("Library/Application Support/Coincide Rust/Updates");
        no_links(&root)?;
        updater::SystemDiskSpace.verify_private(&root)?;
        Ok(root)
    }
    fn parent_target() -> Result<(ParentBinding, PathBuf)> {
        let pid = unsafe { libc::getppid() };
        ensure!(pid > 1, "Native preview parent required");
        let binding = process_binding(pid)?;
        let executable = process_path(pid)?;
        no_links(&executable)?;
        let target = executable
            .parent()
            .and_then(Path::parent)
            .and_then(Path::parent)
            .context("Native parent bundle unavailable")?
            .to_path_buf();
        ensure!(
            target.file_name().is_some_and(|name| name == APP)
                && executable == target.join("Contents/MacOS/coincide-rust"),
            "Not the fixed Rust preview parent"
        );
        Ok((binding, target))
    }
    fn architecture() -> Result<Architecture> {
        if cfg!(target_arch = "aarch64") {
            Ok(Architecture::Arm64)
        } else if cfg!(target_arch = "x86_64") {
            Ok(Architecture::X86_64)
        } else {
            bail!("Native helper architecture unavailable")
        }
    }
    /// Fixed verifier executable and arguments only; no shell/signing operation.
    /// Child inherits no environment or helper pipes. Deadline/output are bounded.
    fn verify_tool(args: &[OsString]) -> Result<()> {
        let mut child = Command::new("/usr/bin/codesign")
            .args(args)
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(status) = child.try_wait()? {
                ensure!(
                    status.success(),
                    "Unsigned/ad hoc/mismatched helper signature refused"
                );
                return Ok(());
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                bail!("Helper signature verifier timed out");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
    fn helper_signature(path: &Path, anchor: &str) -> Result<()> {
        let requirement = helper_requirement(anchor)?;
        verify_tool(&[
            "--verify".into(),
            "--strict".into(),
            "--all-architectures".into(),
            "-R".into(),
            // Leading '=' selects inline requirement text rather than a file.
            format!("={requirement}").into(),
            path.as_os_str().to_owned(),
        ])
    }
    fn hash(path: &Path) -> Result<String> {
        let metadata = fs::symlink_metadata(path)?;
        ensure!(
            metadata.is_file() && metadata.len() > 0 && metadata.len() <= 256 * 1024 * 1024,
            "Helper file bounds rejected"
        );
        let mut file = File::open(path)?.take(metadata.len() + 1);
        let mut hash = Sha256::new();
        let mut bytes = [0u8; 65536];
        let mut count = 0;
        loop {
            let size = file.read(&mut bytes)?;
            if size == 0 {
                break;
            }
            count += size as u64;
            hash.update(&bytes[..size]);
        }
        ensure!(count == metadata.len(), "Helper changed during inspection");
        Ok(format!("{:x}", hash.finalize()))
    }
    pub(super) fn authenticate(
        config: &HelperConfig,
        running: &dyn RunningCodeTrust,
    ) -> Result<AuthenticatedParent> {
        ensure!(
            unsafe { libc::getuid() } != 0
                && unsafe { libc::getuid() } == unsafe { libc::geteuid() }
                && unsafe { libc::getgid() } == unsafe { libc::getegid() },
            "Elevated/set-id update helper is refused; no administrator bypass"
        );
        anchor_valid(&config.install.trust_anchor)?;
        let cache = cache_root()?;
        ensure!(
            config.updater.cache_root == cache
                && config.install.transaction_root == cache.join("transactions"),
            "Helper cache/transaction configuration differs from native location"
        );
        let (parent, target) = parent_target()?;
        let self_before = process_binding(unsafe { libc::getpid() })?;
        ensure!(
            target == config.install.target_parent.join(APP),
            "Native target configuration differs"
        );
        let self_path = std::env::current_exe()?;
        no_links(&self_path)?;
        let job = self_path.parent().context("Private helper job missing")?;
        let job_name = job
            .file_name()
            .and_then(|s| s.to_str())
            .context("Private helper UUID missing")?;
        let id = Uuid::parse_str(job_name)?;
        ensure!(
            !id.is_nil()
                && id.to_string() == job_name
                && job.parent() == Some(cache.join("helpers").as_path())
                && self_path == job.join(HELPER_NAME),
            "Helper must run from its fixed private UUID copy"
        );
        updater::SystemDiskSpace.verify_private(&cache.join("helpers"))?;
        updater::SystemDiskSpace.verify_private(job)?;
        let metadata = fs::symlink_metadata(&self_path)?;
        ensure!(
            metadata.is_file()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o777 == 0o700
                && metadata.nlink() == 1,
            "Private owned helper executable required"
        );
        let installed_helper = target.join("Contents/MacOS").join(HELPER_NAME);
        no_links(&installed_helper)?;
        helper_signature(&installed_helper, &config.install.trust_anchor)?;
        helper_signature(&self_path, &config.install.trust_anchor)?;
        ensure!(
            hash(&installed_helper)? == hash(&self_path)?,
            "Private helper copy differs from installed signed helper"
        );
        let architecture = architecture()?;
        let identity = updater_install::MacCodeVerifier.verify(
            &target,
            &config.install.trust_anchor,
            architecture,
        )?;
        ensure!(
            identity.bundle_id == updater::PREVIEW_ID
                && identity.version == config.updater.current_version,
            "Signed native preview metadata differs"
        );
        // SecCode validates the kernel's running code object, not a translation
        // to the currently signed bytes at target's pathname.
        verify_running_pair(&parent, &config.install.trust_anchor, running)?;
        let (after, after_target) = parent_target()?;
        ensure!(
            process_binding(unsafe { libc::getpid() })? == self_before
                && std::env::current_exe()? == self_path
                && after == parent
                && after_target == target,
            "Native parent changed during signature checks"
        );
        Ok(AuthenticatedParent {
            parent,
            target,
            installed_version: identity.version,
            architecture,
        })
    }
    pub(super) fn prepare_launcher(
        anchor: &str,
        deadline: Instant,
    ) -> Result<PreparedNativeHelper> {
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        ensure!(
            Instant::now() < deadline,
            "Native helper preparation deadline expired"
        );
        ensure!(
            unsafe { libc::getuid() } != 0
                && unsafe { libc::getuid() } == unsafe { libc::geteuid() }
                && unsafe { libc::getgid() } == unsafe { libc::getegid() },
            "Elevated preview launcher refused"
        );
        anchor_valid(anchor)?;
        let parent = process_binding(unsafe { libc::getpid() })?;
        let executable = std::env::current_exe()?;
        no_links(&executable)?;
        let target = executable
            .parent()
            .and_then(Path::parent)
            .and_then(Path::parent)
            .context("Current preview bundle unavailable")?
            .to_path_buf();
        ensure!(
            target.file_name().is_some_and(|name| name == APP)
                && executable == target.join("Contents/MacOS/coincide-rust"),
            "Only the current fixed preview may launch its helper"
        );
        let architecture = architecture()?;
        let identity = updater_install::MacCodeVerifier.verify(&target, anchor, architecture)?;
        MacRunningCodeTrust.verify(&RunningSubject::Parent(parent.clone()), anchor)?;
        ensure!(
            process_binding(unsafe { libc::getpid() })? == parent
                && process_path(parent.pid as i32)? == executable,
            "Preview changed during launcher authentication"
        );
        let helpers = cache_root()?.join("helpers");
        updater::SystemDiskSpace.verify_private(&helpers)?;
        let source = target.join("Contents/MacOS").join(HELPER_NAME);
        no_links(&source)?;
        helper_signature(&source, anchor)?;
        let digest = hash(&source)?;
        let size = fs::metadata(&source)?.len();
        ensure!(
            size > 0 && size <= 256 * 1024 * 1024,
            "Installed helper copy size rejected"
        );
        ensure!(
            updater::SystemDiskSpace.available_bytes(&helpers)?
                >= size.saturating_add(64 * 1024 * 1024),
            "Insufficient helper-copy disk space"
        );
        ensure!(
            Instant::now() < deadline,
            "Native helper preparation deadline expired"
        );
        let job = helpers.join(Uuid::new_v4().to_string());
        fs::DirBuilder::new().mode(0o700).create(&job)?;
        let copy = job.join(HELPER_NAME);
        let mut input = File::open(&source)?.take(size + 1);
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o700)
            .open(&copy)?;
        let mut bytes = [0u8; 65536];
        let mut count = 0u64;
        loop {
            ensure!(
                Instant::now() < deadline,
                "Native helper copy deadline expired"
            );
            let got = input.read(&mut bytes)?;
            if got == 0 {
                break;
            }
            count += got as u64;
            ensure!(count <= size, "Installed helper grew during copy");
            output.write_all(&bytes[..got])?;
        }
        ensure!(count == size, "Installed helper size changed");
        output.sync_all()?;
        drop(output);
        File::open(&job)?.sync_all()?;
        helper_signature(&copy, anchor)?;
        ensure!(
            hash(&copy)? == digest && hash(&source)? == digest,
            "Verified helper copy/source changed"
        );
        let after = updater_install::MacCodeVerifier.verify(&target, anchor, architecture)?;
        ensure!(
            after == identity
                && process_binding(unsafe { libc::getpid() })? == parent
                && process_path(parent.pid as i32)? == executable,
            "Preview source changed during helper copy"
        );
        MacRunningCodeTrust.verify(&RunningSubject::Parent(parent.clone()), anchor)?;
        ensure!(
            Instant::now() < deadline,
            "Native helper preparation deadline expired"
        );
        Ok(PreparedNativeHelper {
            executable: copy,
            target,
            parent,
            version: identity.version,
            anchor: anchor.into(),
            digest,
        })
    }
    pub(super) fn verify_launcher_child(
        prepared: &PreparedNativeHelper,
        pid: u32,
        deadline: Instant,
    ) -> Result<ParentBinding> {
        ensure!(
            Instant::now() < deadline,
            "Helper child verification deadline expired"
        );
        let pid = i32::try_from(pid).context("Helper child PID overflow")?;
        ensure!(pid > 1, "Owned helper child required");
        let before = process_binding(pid)?;
        ensure!(
            process_path(pid)? == prepared.executable,
            "Spawned child is not the fixed private helper copy"
        );
        no_links(&prepared.executable)?;
        let info = fs::symlink_metadata(&prepared.executable)?;
        ensure!(
            info.is_file()
                && info.uid() == unsafe { libc::geteuid() }
                && info.nlink() == 1
                && info.permissions().mode() & 0o777 == 0o700,
            "Private helper copy ownership/mode changed"
        );
        helper_signature(&prepared.executable, &prepared.anchor)?;
        ensure!(
            hash(&prepared.executable)? == prepared.digest,
            "Private helper bytes changed after verification"
        );
        MacRunningCodeTrust.verify(
            &RunningSubject::ChildHelper(before.clone()),
            &prepared.anchor,
        )?;
        MacRunningCodeTrust.verify(
            &RunningSubject::Parent(prepared.parent.clone()),
            &prepared.anchor,
        )?;
        ensure!(
            process_binding(pid)? == before
                && process_path(pid)? == prepared.executable
                && process_binding(unsafe { libc::getpid() })? == prepared.parent
                && process_path(prepared.parent.pid as i32)?
                    == prepared.target.join("Contents/MacOS/coincide-rust"),
            "Launcher or helper process instance/path changed"
        );
        ensure!(
            Instant::now() < deadline,
            "Helper child verification deadline expired"
        );
        Ok(before)
    }
    pub(super) fn configuration(
        anchor: &str,
        feed: &str,
        artifact_base: &str,
    ) -> Result<HelperConfig> {
        anchor_valid(anchor)?;
        let (_, target) = parent_target()?;
        let architecture = architecture()?;
        let identity = updater_install::MacCodeVerifier.verify(&target, anchor, architecture)?;
        let feed = url::Url::parse(feed)?;
        let artifact_base = url::Url::parse(artifact_base)?;
        let allowed_hosts: BTreeSet<_> = [
            feed.host_str().context("Feed host missing")?.to_owned(),
            artifact_base
                .host_str()
                .context("Artifact host missing")?
                .to_owned(),
        ]
        .into_iter()
        .collect();
        let cache = cache_root()?;
        Ok(HelperConfig {
            updater: Config {
                feed,
                artifact_base,
                trust_anchor: anchor.into(),
                current_version: identity.version,
                platform: Platform::Macos,
                architecture,
                cache_root: cache.clone(),
                allowed_hosts,
                limits: Limits::default(),
            },
            install: InstallConfig {
                target_parent: target
                    .parent()
                    .context("Target parent missing")?
                    .to_path_buf(),
                trust_anchor: anchor.into(),
                reserve_disk_bytes: 64 * 1024 * 1024,
                transaction_root: cache.join("transactions"),
                approval_lifetime: Duration::from_secs(900),
                exit_timeout: Duration::from_secs(30),
            },
            protocol: ProtocolLimits::default(),
        })
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::updater::{DiskSpace, Limits, State};
    use crate::updater_install::{
        BundleIdentity, BundleVerifier, NativeExchange, UnavailableNativeApproval,
    };
    use serde_json::json;
    use std::{
        collections::BTreeSet,
        fs::{self, File},
        io::Cursor,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
        path::Path,
        process::{Child, Command, Stdio},
        sync::atomic::{AtomicUsize, Ordering},
    };
    use tempfile::TempDir;
    use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};
    const ANCHOR: &str = "FIXTURE001";
    fn directory(path: &Path) {
        fs::DirBuilder::new().mode(0o700).create(path).unwrap();
    }
    fn metadata(version: &str) -> serde_json::Value {
        json!({"id":updater::PREVIEW_ID,"version":version,"fixtureTrust":"FAKE-SIGNED-TEST-ONLY"})
    }
    fn bundle(path: &Path, version: &str) {
        directory(path);
        directory(&path.join("Contents"));
        directory(&path.join("Contents/MacOS"));
        fs::write(
            path.join("Contents/Info.plist"),
            serde_json::to_vec(&metadata(version)).unwrap(),
        )
        .unwrap();
        for executable in ["coincide-rust", "coincide-rs", "coincide-store"] {
            let file = path.join("Contents/MacOS").join(executable);
            fs::write(
                &file,
                format!("synthetic {executable} {version}; NEVER EXECUTE"),
            )
            .unwrap();
            fs::set_permissions(file, fs::Permissions::from_mode(0o700)).unwrap();
        }
    }
    fn zip(version: &str) -> Vec<u8> {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o700);
        for executable in ["coincide-rust", "coincide-rs", "coincide-store"] {
            writer
                .start_file(format!("{APP}/Contents/MacOS/{executable}"), options)
                .unwrap();
            writer
                .write_all(format!("synthetic {executable} {version}; NEVER EXECUTE").as_bytes())
                .unwrap();
        }
        writer
            .start_file(
                format!("{APP}/Contents/Info.plist"),
                options.unix_permissions(0o600),
            )
            .unwrap();
        writer
            .write_all(&serde_json::to_vec(&metadata(version)).unwrap())
            .unwrap();
        writer.finish().unwrap().into_inner()
    }
    struct FakeRunningCodeTrust {
        parent_marker: PathBuf,
        helper_marker: PathBuf,
    }
    impl RunningCodeTrust for FakeRunningCodeTrust {
        fn verify(&self, subject: &RunningSubject, anchor: &str) -> Result<()> {
            let marker = match subject {
                RunningSubject::Helper | RunningSubject::ChildHelper(_) => &self.helper_marker,
                RunningSubject::Parent(_) => &self.parent_marker,
            };
            // Deliberately independent of the signed-on-disk fixture bundle.
            // These files model the kernel's running code record in tests only.
            let info: serde_json::Value = serde_json::from_slice(&fs::read(marker)?)?;
            ensure!(
                info["status"] != "unavailable",
                "fixture dynamic running code unavailable"
            );
            ensure!(
                info["status"] == "running_valid"
                    && info["team"] == anchor
                    && info["id"] == subject.identifier(),
                "fixture dynamic running code requirement failed"
            );
            Ok(())
        }
    }
    struct FakeIdentity {
        marker: PathBuf,
        parent: ParentBinding,
    }
    impl RuntimeIdentity for FakeIdentity {
        fn authenticate(
            &self,
            config: &HelperConfig,
            running: &dyn RunningCodeTrust,
        ) -> Result<AuthenticatedParent> {
            // Test-only trust marker is an injected verifier fixture, NEVER native
            // signature evidence. Production MacRuntimeIdentity uses codesign.
            ensure!(
                fs::read(&self.marker)? == b"FAKE-SIGNED-HELPER-TEST-ONLY",
                "fixture unsigned/ad hoc self refused"
            );
            let target = config.install.target_parent.join(APP);
            let info: serde_json::Value =
                serde_json::from_slice(&fs::read(target.join("Contents/Info.plist"))?)?;
            ensure!(
                info["id"] == updater::PREVIEW_ID
                    && info["fixtureTrust"] == "FAKE-SIGNED-TEST-ONLY",
                "fixture unsigned/wrong parent refused"
            );
            verify_running_pair(&self.parent, &config.install.trust_anchor, running)?;
            Ok(AuthenticatedParent {
                parent: self.parent.clone(),
                target,
                installed_version: info["version"].as_str().context("fixture version")?.into(),
                architecture: Architecture::Arm64,
            })
        }
    }
    struct FakeVerifier {
        target: PathBuf,
        reject_after_swap: bool,
    }
    impl BundleVerifier for FakeVerifier {
        fn verify(
            &self,
            path: &Path,
            anchor: &str,
            architecture: Architecture,
        ) -> Result<BundleIdentity> {
            let info: serde_json::Value =
                serde_json::from_slice(&fs::read(path.join("Contents/Info.plist"))?)?;
            ensure!(
                info["id"] == updater::PREVIEW_ID
                    && info["fixtureTrust"] == "FAKE-SIGNED-TEST-ONLY",
                "fixture unsigned/mismatched bundle refused"
            );
            let version = info["version"]
                .as_str()
                .context("fixture version")?
                .to_owned();
            ensure!(
                !(self.reject_after_swap && path == self.target && version == "0.2.0"),
                "injected post-exchange trust failure"
            );
            Ok(BundleIdentity {
                bundle_id: updater::PREVIEW_ID.into(),
                version,
                architecture,
                anchor: anchor.into(),
            })
        }
    }
    struct FakeDisk;
    impl DiskSpace for FakeDisk {
        fn available_bytes(&self, _: &Path) -> Result<u64> {
            Ok(u64::MAX)
        }
    }
    struct NeverHttp(AtomicUsize);
    impl updater::Transport for NeverHttp {
        fn fetch(
            &self,
            _: &url::Url,
            _: &updater::RequestPolicy,
            _: &mut dyn Write,
            _: &updater::OperationContext,
        ) -> Result<updater::Response> {
            self.0.fetch_add(1, Ordering::SeqCst);
            bail!("fixture forbids ALL network")
        }
    }
    struct FakeProcess {
        parent: ParentBinding,
        child: Arc<Mutex<Option<Child>>>,
        stopped: bool,
    }
    struct FakeWatch {
        parent: ParentBinding,
        child: Arc<Mutex<Option<Child>>>,
    }
    impl ParentWatch for FakeWatch {
        fn binding(&self) -> ParentBinding {
            self.parent.clone()
        }
        fn wait_clean_exit(&mut self, _: Duration) -> Result<()> {
            if let Some(mut child) = self.child.lock().unwrap().take() {
                ensure!(child.wait()?.success(), "fixture parent did not exit zero");
            }
            Ok(())
        }
    }
    impl ProcessGuard for FakeProcess {
        fn observe_parent(&self, _: &Path) -> Result<Box<dyn ParentWatch>> {
            Ok(Box::new(FakeWatch {
                parent: self.parent.clone(),
                child: self.child.clone(),
            }))
        }
        fn ensure_stopped(&self, _: &Path) -> Result<()> {
            ensure!(self.stopped, "fixture target still running");
            Ok(())
        }
    }
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Mode {
        Success,
        Decline,
        CancelBeforeProposalObserved,
        RevokeRunningAfterApproval,
        RevokeRunningAfterReady,
        WrongApproval,
        ReplaySequence,
        WrongSession,
        SkipReadyAck,
        CancelReady,
        CancelClean,
        WrongClean,
        MissingClean,
        AckFailure,
    }
    struct FakeWire {
        first: Option<Frame<ParentMessage>>,
        next: u64,
        session: Uuid,
        mode: Mode,
        running_parent: PathBuf,
        sent: Arc<Mutex<Vec<Frame<HelperMessage>>>>,
    }
    impl PrivateChannel for FakeWire {
        fn receive(&mut self, deadline: Instant) -> Result<Frame<ParentMessage>> {
            ensure!(Instant::now() < deadline, "fixture deadline");
            if let Some(frame) = self.first.take() {
                return decode_frame(&encode_frame(&frame)?);
            }
            let last = self
                .sent
                .lock()
                .unwrap()
                .last()
                .context("fixture no helper message")?
                .body
                .clone();
            let body = match last {
                HelperMessage::Proposal { mut binding, .. } => {
                    if self.mode == Mode::RevokeRunningAfterApproval {
                        fs::write(
                            &self.running_parent,
                            serde_json::to_vec(&json!({
                            "id":updater::PREVIEW_ID,"team":ANCHOR,"status":"unsigned_running"}))?,
                        )?;
                    }
                    if self.mode == Mode::WrongApproval {
                        binding.proposal_sha256 = "f".repeat(64);
                    }
                    if self.mode == Mode::Decline {
                        ParentMessage::Decline { binding }
                    } else if self.mode == Mode::CancelBeforeProposalObserved {
                        ParentMessage::Cancel { transaction: None }
                    } else {
                        ParentMessage::Approve { binding }
                    }
                }
                HelperMessage::Ready { binding, .. } => {
                    if self.mode == Mode::CancelReady {
                        ParentMessage::Cancel {
                            transaction: Some(binding.transaction),
                        }
                    } else if self.mode == Mode::SkipReadyAck {
                        ParentMessage::CleanQuit { binding }
                    } else {
                        ParentMessage::ReadyAck { binding }
                    }
                }
                HelperMessage::Armed { mut binding } => {
                    if self.mode == Mode::RevokeRunningAfterReady {
                        fs::write(
                            &self.running_parent,
                            serde_json::to_vec(&json!({
                            "id":updater::PREVIEW_ID,"team":ANCHOR,"status":"unsigned_running"}))?,
                        )?;
                    }
                    if self.mode == Mode::MissingClean {
                        bail!("fixture private input closed before flush");
                    }
                    if self.mode == Mode::WrongClean {
                        binding.challenge = Uuid::new_v4();
                    }
                    if self.mode == Mode::CancelClean {
                        ParentMessage::Cancel {
                            transaction: Some(binding.transaction),
                        }
                    } else {
                        ParentMessage::CleanQuit { binding }
                    }
                }
                _ => bail!("fixture no parent reply for helper state"),
            };
            let frame = Frame {
                version: PROTOCOL,
                session: if self.mode == Mode::WrongSession {
                    Uuid::new_v4()
                } else {
                    self.session
                },
                sequence: if self.mode == Mode::ReplaySequence {
                    0
                } else {
                    self.next
                },
                body,
            };
            self.next += 1;
            decode_frame(&encode_frame(&frame)?)
        }
        fn send(&mut self, frame: &Frame<HelperMessage>, deadline: Instant) -> Result<()> {
            ensure!(Instant::now() < deadline, "fixture deadline");
            let copied = decode_frame(&encode_frame(frame)?)?;
            self.sent.lock().unwrap().push(copied);
            ensure!(
                !(self.mode == Mode::AckFailure
                    && matches!(frame.body, HelperMessage::ConsentAck { .. })),
                "fixture lost consent ACK"
            );
            Ok(())
        }
    }
    struct Fixture {
        _root: TempDir,
        config: HelperConfig,
        dependencies: HelperDependencies,
        marker: PathBuf,
        running_parent: PathBuf,
        running_helper: PathBuf,
        job: Uuid,
        release: Release,
        target: PathBuf,
        sent: Arc<Mutex<Vec<Frame<HelperMessage>>>>,
        network: Arc<NeverHttp>,
        child: Arc<Mutex<Option<Child>>>,
    }
    impl Fixture {
        fn new() -> Self {
            let root = tempfile::Builder::new()
                .prefix("coincide-helper-fixture-")
                .permissions(fs::Permissions::from_mode(0o700))
                .tempdir()
                .unwrap();
            let root_path = root.path().canonicalize().unwrap();
            let cache = root_path.join("cache");
            directory(&cache);
            let transaction_root = root_path.join("transactions");
            directory(&transaction_root);
            let target_parent = root_path.join("apps");
            directory(&target_parent);
            let target = target_parent.join(APP);
            bundle(&target, "0.1.0");
            let marker = root_path.join("helper.trust.fixture");
            fs::write(&marker, b"FAKE-SIGNED-HELPER-TEST-ONLY").unwrap();
            let running_parent = root_path.join("running-parent.fixture");
            let running_helper = root_path.join("running-helper.fixture");
            for (path, id) in [
                (&running_parent, updater::PREVIEW_ID),
                (&running_helper, HELPER_ID),
            ] {
                fs::write(
                    path,
                    serde_json::to_vec(&json!({"id":id,"team":ANCHOR,"status":"running_valid"}))
                        .unwrap(),
                )
                .unwrap();
            }
            let archive = zip("0.2.0");
            let job = Uuid::new_v4();
            let job_dir = cache.join(job.to_string());
            directory(&job_dir);
            fs::write(job_dir.join("release.zip"), &archive).unwrap();
            // Deliberately false mutable flags cannot block genuine fresh checks,
            // and true flags cannot rescue tampered archive/signature bytes.
            fs::write(
                job_dir.join("stage.json"),
                b"{\"signature\":\"Verified\",\"install_authorized\":true}",
            )
            .unwrap();
            let release = Release {
                version: "0.2.0".into(),
                platform: Platform::Macos,
                architecture: Architecture::Arm64,
                url: "https://fixture.invalid/rust-preview/0.2.0/Coincide-Rust-macos-arm64.zip"
                    .into(),
                size: archive.len() as u64,
                sha256: format!("{:x}", Sha256::digest(&archive)),
            };
            let parent = ParentBinding {
                pid: 42,
                start_seconds: 100,
                start_micros: 2,
            };
            let child = Arc::new(Mutex::new(None));
            let network = Arc::new(NeverHttp(AtomicUsize::new(0)));
            let disk = Arc::new(FakeDisk);
            let dependencies = HelperDependencies {
                identity: Arc::new(FakeIdentity {
                    marker: marker.clone(),
                    parent: parent.clone(),
                }),
                running: Arc::new(FakeRunningCodeTrust {
                    parent_marker: running_parent.clone(),
                    helper_marker: running_helper.clone(),
                }),
                staging: Dependencies {
                    transport: network.clone(),
                    extractor: Arc::new(updater::ZipExtractor),
                    disk: disk.clone(),
                    trust: Arc::new(NoStoredTrust),
                },
                installation: InstallDependencies {
                    verifier: Arc::new(FakeVerifier {
                        target: target.clone(),
                        reject_after_swap: false,
                    }),
                    approval: Arc::new(UnavailableNativeApproval),
                    processes: Arc::new(FakeProcess {
                        parent,
                        child: child.clone(),
                        stopped: true,
                    }),
                    exchange: Arc::new(NativeExchange),
                    disk,
                },
            };
            let config = HelperConfig {
                updater: Config {
                    feed: "https://fixture.invalid/rust-preview/feed.json"
                        .parse()
                        .unwrap(),
                    artifact_base: "https://fixture.invalid/rust-preview/".parse().unwrap(),
                    trust_anchor: ANCHOR.into(),
                    current_version: "0.1.0".into(),
                    platform: Platform::Macos,
                    architecture: Architecture::Arm64,
                    cache_root: cache,
                    allowed_hosts: BTreeSet::from(["fixture.invalid".into()]),
                    limits: Limits::default(),
                },
                install: InstallConfig {
                    target_parent,
                    trust_anchor: ANCHOR.into(),
                    reserve_disk_bytes: 0,
                    transaction_root,
                    approval_lifetime: Duration::from_secs(10),
                    exit_timeout: Duration::from_secs(2),
                },
                protocol: ProtocolLimits {
                    bootstrap: Duration::from_secs(2),
                    approval: Duration::from_secs(2),
                    ready_ack: Duration::from_secs(2),
                    clean_quit: Duration::from_secs(2),
                    send: Duration::from_secs(2),
                },
            };
            Self {
                _root: root,
                config,
                dependencies,
                marker,
                running_parent,
                running_helper,
                job,
                release,
                target,
                sent: Arc::new(Mutex::new(Vec::new())),
                network,
                child,
            }
        }
        fn channel(&self, mode: Mode) -> Box<dyn PrivateChannel> {
            let session = Uuid::new_v4();
            Box::new(FakeWire {
                first: Some(Frame {
                    version: PROTOCOL,
                    session,
                    sequence: 0,
                    body: ParentMessage::Select {
                        job: self.job,
                        release: self.release.clone(),
                        client_nonce: Uuid::new_v4(),
                    },
                }),
                next: 1,
                session,
                mode,
                running_parent: self.running_parent.clone(),
                sent: self.sent.clone(),
            })
        }
        fn run(&self, mode: Mode) -> Result<HelperOutcome> {
            serve(
                self.config.clone(),
                self.dependencies.clone(),
                self.channel(mode),
            )
        }
        fn version(&self) -> String {
            let info: serde_json::Value =
                serde_json::from_slice(&fs::read(self.target.join("Contents/Info.plist")).unwrap())
                    .unwrap();
            info["version"].as_str().unwrap().into()
        }
        fn trust_snapshot(&self) -> Vec<(Vec<u8>, u32)> {
            // Exact bytes AND modes of all original fixture bundle/trust/archive
            // inputs, excluding the helper's separately owned transaction journal.
            let mut paths = vec![
                self.marker.clone(),
                self.target.join("Contents/Info.plist"),
                self.config
                    .updater
                    .cache_root
                    .join(self.job.to_string())
                    .join("release.zip"),
            ];
            paths.extend(
                ["coincide-rust", "coincide-rs", "coincide-store"]
                    .into_iter()
                    .map(|name| self.target.join("Contents/MacOS").join(name)),
            );
            paths
                .into_iter()
                .map(|path| {
                    (
                        fs::read(&path).unwrap(),
                        fs::metadata(path).unwrap().permissions().mode(),
                    )
                })
                .collect()
        }
        fn assert_not_installed(&self, outcome: HelperOutcome, expected_reason: &str) {
            let HelperOutcome::Finished(InstallOutcome::NotInstalled {
                transaction,
                reason,
            }) = outcome
            else {
                panic!("Expected strict NotInstalled rejection, got {outcome:?}");
            };
            assert_eq!(reason, expected_reason);
            let sent = self.sent.lock().unwrap();
            let HelperMessage::Proposal { binding, .. } = &sent[0].body else {
                panic!("Missing verified proposal");
            };
            assert_eq!(transaction, binding.transaction);
            assert!(!transaction.is_nil());
            assert!(matches!(&sent.last().unwrap().body,
                HelperMessage::Finished { transaction: reported, status }
                    if *reported == transaction && status == "not_installed"));
        }
        fn no_install(&self) {
            assert_eq!(self.version(), "0.1.0");
            assert_eq!(self.network.0.load(Ordering::SeqCst), 0);
            assert!(
                !fs::read_dir(&self.config.install.target_parent)
                    .unwrap()
                    .any(|p| p
                        .unwrap()
                        .file_name()
                        .to_string_lossy()
                        .starts_with(".Coincide-Rust-backup-"))
            );
        }
    }
    #[test]
    fn complete_private_helper_flow_copies_exchanges_and_retains_backup_only_in_temp() {
        let f = Fixture::new();
        let outcome = f.run(Mode::Success).unwrap();
        let HelperOutcome::Finished(InstallOutcome::Installed { backup, .. }) = outcome else {
            panic!("not installed fixture")
        };
        assert!(backup.starts_with(f._root.path().canonicalize().unwrap()));
        assert_eq!(f.version(), "0.2.0");
        let backup_info: serde_json::Value =
            serde_json::from_slice(&fs::read(backup.join("Contents/Info.plist")).unwrap()).unwrap();
        assert_eq!(backup_info["version"], "0.1.0");
        assert_eq!(f.network.0.load(Ordering::SeqCst), 0);
        let sent = f.sent.lock().unwrap();
        assert!(matches!(sent[0].body, HelperMessage::Proposal { .. }));
        assert!(matches!(sent[1].body, HelperMessage::Ready { .. }));
        assert!(matches!(sent[2].body, HelperMessage::Armed { .. }));
        assert!(matches!(sent[3].body, HelperMessage::ConsentAck { .. }));
        for (index, frame) in sent.iter().enumerate() {
            assert_eq!(frame.sequence, index as u64);
        }
        assert!(
            f.config
                .updater
                .cache_root
                .join(f.job.to_string())
                .join("release.zip")
                .is_file()
        );
    }
    #[test]
    fn unsigned_self_and_parent_refuse_before_archive_or_native_approval() {
        for self_bad in [true, false] {
            let f = Fixture::new();
            if self_bad {
                fs::write(&f.marker, b"AD-HOC-UNSIGNED").unwrap();
            } else {
                fs::write(f.target.join("Contents/Info.plist"), serde_json::to_vec(&json!({"id":updater::PREVIEW_ID,"version":"0.1.0","fixtureTrust":"unsigned"})).unwrap()).unwrap();
            }
            assert!(f.run(Mode::Success).is_err());
            assert!(f.sent.lock().unwrap().is_empty());
            f.no_install();
        }
    }
    #[test]
    fn signed_disk_never_substitutes_for_running_parent_or_helper_identity() {
        for case in 0..5 {
            let f = Fixture::new();
            let helper = case == 3;
            let path = if helper {
                &f.running_helper
            } else {
                &f.running_parent
            };
            let mut info = json!({"id":if helper { HELPER_ID } else { updater::PREVIEW_ID },
                "team":ANCHOR,"status":"running_valid"});
            match case {
                0 | 3 => info["status"] = json!("unsigned_running"),
                1 => info["id"] = json!("com.apoorvdarshan.coincide"),
                2 => info["team"] = json!("OTHER00000"),
                _ => info["status"] = json!("unavailable"),
            }
            fs::write(path, serde_json::to_vec(&info).unwrap()).unwrap();
            let before = f.trust_snapshot();
            let error = f.run(Mode::Success).unwrap_err().to_string();
            assert_eq!(
                error,
                if case == 4 {
                    "fixture dynamic running code unavailable"
                } else {
                    "fixture dynamic running code requirement failed"
                }
            );
            assert!(f.sent.lock().unwrap().is_empty());
            assert_eq!(f.trust_snapshot(), before);
            f.no_install();
        }
    }
    #[test]
    fn running_trust_changed_during_native_approval_is_rechecked_before_ready() {
        let f = Fixture::new();
        let before = f.trust_snapshot();
        assert_eq!(
            f.run(Mode::RevokeRunningAfterApproval)
                .unwrap_err()
                .to_string(),
            "fixture dynamic running code requirement failed"
        );
        {
            let sent = f.sent.lock().unwrap();
            assert_eq!(sent.len(), 1);
            assert!(matches!(sent[0].body, HelperMessage::Proposal { .. }));
        }
        assert_eq!(f.trust_snapshot(), before);
        f.no_install();
    }
    #[test]
    fn running_trust_changed_after_ready_cannot_mint_clean_quit_consent() {
        let f = Fixture::new();
        let before = f.trust_snapshot();
        assert_eq!(
            f.run(Mode::RevokeRunningAfterReady)
                .unwrap_err()
                .to_string(),
            "fixture dynamic running code requirement failed"
        );
        let sent = f.sent.lock().unwrap();
        assert!(
            sent.iter()
                .any(|frame| matches!(frame.body, HelperMessage::Armed { .. }))
        );
        assert!(
            !sent
                .iter()
                .any(|frame| matches!(frame.body, HelperMessage::ConsentAck { .. }))
        );
        drop(sent);
        assert_eq!(f.trust_snapshot(), before);
        f.no_install();
    }
    #[test]
    fn unsigned_candidate_refuses_before_proposal_despite_claimed_verified_receipt() {
        struct UnsignedCandidate(FakeVerifier);
        impl BundleVerifier for UnsignedCandidate {
            fn verify(
                &self,
                path: &Path,
                anchor: &str,
                arch: Architecture,
            ) -> Result<BundleIdentity> {
                let identity = self.0.verify(path, anchor, arch)?;
                ensure!(
                    identity.version != "0.2.0",
                    "fixture candidate has no valid signature"
                );
                Ok(identity)
            }
        }
        let mut f = Fixture::new();
        f.dependencies.installation.verifier = Arc::new(UnsignedCandidate(FakeVerifier {
            target: f.target.clone(),
            reject_after_swap: false,
        }));
        assert!(f.run(Mode::Success).is_err());
        assert!(f.sent.lock().unwrap().is_empty());
        f.no_install();
    }
    #[test]
    fn swift_parent_identity_is_always_rejected() {
        let f = Fixture::new();
        fs::write(f.target.join("Contents/Info.plist"), serde_json::to_vec(&json!({"id":"com.apoorvdarshan.coincide","version":"0.1.0","fixtureTrust":"FAKE-SIGNED-TEST-ONLY"})).unwrap()).unwrap();
        assert!(f.run(Mode::Success).is_err());
        assert!(f.sent.lock().unwrap().is_empty());
        f.no_install();
    }
    #[test]
    fn offline_reopen_ignores_flags_and_extracts_new_private_archive_snapshot() {
        let f = Fixture::new();
        let updater = Updater::reopen_for_helper(
            f.config.updater.clone(),
            f.dependencies.staging.clone(),
            f.job,
            f.release.clone(),
        )
        .unwrap();
        let State::Staged(stage) = updater.state() else {
            panic!("not offline stage")
        };
        assert!(!stage.archive_sha256_verified && !stage.install_authorized);
        assert!(matches!(
            stage.signature,
            updater::SignatureStatus::Pending { .. }
        ));
        let candidate = updater.fresh_install_candidate().unwrap();
        assert!(candidate.bundle.is_dir());
        assert!(!candidate.bundle.starts_with(&stage.job));
        let copy = candidate
            .bundle
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .to_path_buf();
        assert!(copy.starts_with(&f.config.updater.cache_root));
        drop(candidate);
        assert!(!copy.exists());
        assert!(stage.job.join("release.zip").is_file());
        f.no_install();
    }
    #[test]
    fn mutable_verified_receipt_cannot_rescue_archive_tampering() {
        let f = Fixture::new();
        let path = f
            .config
            .updater
            .cache_root
            .join(f.job.to_string())
            .join("release.zip");
        let mut archive = fs::read(&path).unwrap();
        archive[40] ^= 1;
        fs::write(path, archive).unwrap();
        assert!(f.run(Mode::Success).is_err());
        assert!(f.sent.lock().unwrap().is_empty());
        f.no_install();
    }
    #[test]
    fn wrong_release_policy_platform_arch_or_uuid_refuses_offline_bootstrap() {
        for field in 0..5 {
            let mut f = Fixture::new();
            match field {
                0 => f.release.url = "https://fixture.invalid/Coincide.zip".into(),
                1 => f.release.platform = Platform::Windows,
                2 => f.release.architecture = Architecture::X86_64,
                3 => f.job = Uuid::nil(),
                _ => f.release.version = "0.1.0".into(),
            }
            assert!(f.run(Mode::Success).is_err());
            assert!(f.sent.lock().unwrap().is_empty());
            f.no_install();
        }
    }
    #[test]
    fn offline_archive_traversal_and_expansion_limits_remain_enforced() {
        for malicious in [true, false] {
            let mut f = Fixture::new();
            if malicious {
                let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
                writer
                    .start_file(
                        "../outside.fixture",
                        SimpleFileOptions::default()
                            .compression_method(CompressionMethod::Deflated),
                    )
                    .unwrap();
                writer
                    .write_all(b"must never escape private snapshot")
                    .unwrap();
                let archive = writer.finish().unwrap().into_inner();
                fs::write(
                    f.config
                        .updater
                        .cache_root
                        .join(f.job.to_string())
                        .join("release.zip"),
                    &archive,
                )
                .unwrap();
                f.release.size = archive.len() as u64;
                f.release.sha256 = format!("{:x}", Sha256::digest(&archive));
            } else {
                f.config.updater.limits.entries = 1;
            }
            assert!(f.run(Mode::Success).is_err());
            assert!(f.sent.lock().unwrap().is_empty());
            assert!(!f.config.updater.cache_root.join("outside.fixture").exists());
            f.no_install();
        }
    }
    #[test]
    fn private_job_symlink_and_public_mode_are_not_reopened() {
        let f = Fixture::new();
        let job = f.config.updater.cache_root.join(f.job.to_string());
        fs::set_permissions(&job, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(f.run(Mode::Success).is_err());
        f.no_install();
        let f = Fixture::new();
        let job = f.config.updater.cache_root.join(f.job.to_string());
        let moved = f.config.updater.cache_root.join("moved-fixture");
        fs::rename(&job, &moved).unwrap();
        std::os::unix::fs::symlink(&moved, &job).unwrap();
        assert!(f.run(Mode::Success).is_err());
        f.no_install();
    }
    #[test]
    fn decline_cancel_and_every_binding_or_protocol_failure_never_replace() {
        for mode in [
            Mode::Decline,
            Mode::WrongApproval,
            Mode::ReplaySequence,
            Mode::WrongSession,
            Mode::SkipReadyAck,
            Mode::CancelReady,
            Mode::CancelClean,
            Mode::WrongClean,
            Mode::MissingClean,
            Mode::AckFailure,
        ] {
            let f = Fixture::new();
            let result = f.run(mode);
            if mode == Mode::Decline {
                assert_eq!(result.unwrap(), HelperOutcome::Declined);
            } else if matches!(mode, Mode::CancelReady | Mode::CancelClean) {
                assert_eq!(result.unwrap(), HelperOutcome::Cancelled);
            } else {
                assert!(result.is_err(), "{mode:?}");
            }
            f.no_install();
        }
    }
    #[test]
    fn cancellation_before_parent_observes_proposal_echoes_unbound_transaction() {
        let f = Fixture::new();
        assert_eq!(
            f.run(Mode::CancelBeforeProposalObserved).unwrap(),
            HelperOutcome::Cancelled
        );
        assert!(matches!(
            f.sent.lock().unwrap().last().unwrap().body,
            HelperMessage::Disarmed { transaction: None }
        ));
        f.no_install();
    }
    #[test]
    fn changed_parent_start_instance_cannot_report_ready() {
        let mut f = Fixture::new();
        f.dependencies.installation.processes = Arc::new(FakeProcess {
            parent: ParentBinding {
                pid: 42,
                start_seconds: 101,
                start_micros: 2,
            },
            child: f.child.clone(),
            stopped: true,
        });
        assert!(f.run(Mode::Success).is_err());
        assert!(
            !f.sent
                .lock()
                .unwrap()
                .iter()
                .any(|frame| matches!(frame.body, HelperMessage::Ready { .. }))
        );
        f.no_install();
    }
    #[test]
    fn target_running_after_clean_parent_exit_cannot_replace() {
        let mut f = Fixture::new();
        f.dependencies.installation.processes = Arc::new(FakeProcess {
            parent: ParentBinding {
                pid: 42,
                start_seconds: 100,
                start_micros: 2,
            },
            child: f.child.clone(),
            stopped: false,
        });
        let before = f.trust_snapshot();
        f.assert_not_installed(
            f.run(Mode::Success).unwrap(),
            "fixture target still running",
        );
        assert_eq!(f.trust_snapshot(), before);
        f.no_install();
    }
    #[test]
    fn post_exchange_trust_failure_rolls_back_temp_bundle() {
        let mut f = Fixture::new();
        f.dependencies.installation.verifier = Arc::new(FakeVerifier {
            target: f.target.clone(),
            reject_after_swap: true,
        });
        assert!(matches!(
            f.run(Mode::Success).unwrap(),
            HelperOutcome::Finished(InstallOutcome::RolledBack { .. })
        ));
        assert_eq!(f.version(), "0.1.0");
    }
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn actual_native_identity_refuses_non_mac_without_inspection() {
        let f = Fixture::new();
        assert_eq!(
            MacRuntimeIdentity
                .authenticate(&f.config, f.dependencies.running.as_ref())
                .unwrap_err()
                .to_string(),
            "Independent signed preview helper is unavailable on this platform"
        );
        f.no_install();
    }
    #[test]
    fn child_exit_fixture_zero() { /* deliberately no native effects; child harness exits zero */
    }
    #[test]
    fn child_exit_fixture_failure() {
        if std::env::var_os("COINCIDE_HELPER_FIXTURE_CHILD").is_some() {
            std::process::exit(23);
        }
    }
    #[test]
    fn helper_requires_actual_fixture_child_success_not_just_missing_pid() {
        for success in [true, false] {
            let mut f = Fixture::new();
            let test = if success {
                "updater_helper::tests::child_exit_fixture_zero"
            } else {
                "updater_helper::tests::child_exit_fixture_failure"
            };
            let child = Command::new(std::env::current_exe().unwrap())
                .args(["--exact", test, "--nocapture"])
                .env("COINCIDE_HELPER_FIXTURE_CHILD", "1")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let parent = ParentBinding {
                pid: child.id(),
                start_seconds: 100,
                start_micros: 2,
            };
            f.dependencies.identity = Arc::new(FakeIdentity {
                marker: f.marker.clone(),
                parent: parent.clone(),
            });
            f.dependencies.installation.processes = Arc::new(FakeProcess {
                parent,
                child: f.child.clone(),
                stopped: true,
            });
            *f.child.lock().unwrap() = Some(child);
            let before = f.trust_snapshot();
            let result = f.run(Mode::Success);
            if success {
                assert!(matches!(
                    result.unwrap(),
                    HelperOutcome::Finished(InstallOutcome::Installed { .. })
                ));
            } else {
                f.assert_not_installed(result.unwrap(), "fixture parent did not exit zero");
                assert_eq!(f.trust_snapshot(), before);
                f.no_install();
            }
        }
    }
    fn pipes() -> (File, File) {
        use std::os::fd::FromRawFd;
        let mut fds = [-1; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let read = unsafe { File::from_raw_fd(fds[0]) };
        let write = unsafe { File::from_raw_fd(fds[1]) };
        nonblocking(&read).unwrap();
        nonblocking(&write).unwrap();
        (read, write)
    }
    #[test]
    fn anonymous_pipe_validation_preserves_parent_cloexec_and_nonblocking() {
        use std::os::fd::AsRawFd;
        let (input, _writer) = pipes();
        let (_reader, output) = pipes();
        validate_anonymous_pipe(input.as_raw_fd()).unwrap();
        validate_anonymous_pipe(output.as_raw_fd()).unwrap();
        for file in [&input, &output] {
            let fd = file.as_raw_fd();
            let descriptor_flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            let status_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            assert!(descriptor_flags >= 0 && status_flags >= 0);
            assert_eq!(
                unsafe { libc::fcntl(fd, libc::F_SETFD, descriptor_flags & !libc::FD_CLOEXEC) },
                0
            );
            assert_eq!(
                unsafe { libc::fcntl(fd, libc::F_SETFL, status_flags & !libc::O_NONBLOCK) },
                0
            );
        }
        let parent =
            ParentPipeChannel::from_anonymous_files(input, output, Duration::from_secs(1)).unwrap();
        for file in [&parent.pipes.input, &parent.pipes.output] {
            let fd = file.as_raw_fd();
            let descriptor_flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            let status_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            assert!(descriptor_flags >= 0 && status_flags >= 0);
            assert_ne!(descriptor_flags & libc::FD_CLOEXEC, 0);
            assert_ne!(status_flags & libc::O_NONBLOCK, 0);
        }
    }

    #[test]
    fn anonymous_pipe_validation_rejects_named_fifo_even_after_unlink() {
        use std::{
            ffi::CString,
            os::{
                fd::AsRawFd,
                unix::{
                    ffi::OsStrExt,
                    fs::{MetadataExt, OpenOptionsExt},
                },
            },
        };
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("named-fifo.fixture");
        let name = CString::new(path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        let fifo = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&path)
            .unwrap();
        assert_eq!(fifo.metadata().unwrap().nlink(), 1);
        for unlinked in [false, true] {
            if unlinked {
                fs::remove_file(&path).unwrap();
                assert_eq!(fifo.metadata().unwrap().nlink(), 0);
            }
            assert!(validate_anonymous_pipe(fifo.as_raw_fd()).is_err());
            let (_reader, output) = pipes();
            assert!(
                ParentPipeChannel::from_anonymous_files(
                    fifo.try_clone().unwrap(),
                    output,
                    Duration::from_secs(1)
                )
                .is_err()
            );
            let (input, _writer) = pipes();
            assert!(
                ParentPipeChannel::from_anonymous_files(
                    input,
                    fifo.try_clone().unwrap(),
                    Duration::from_secs(1)
                )
                .is_err()
            );
        }
    }

    #[test]
    fn parent_pipe_adapter_roundtrips_existing_helper_protocol() {
        let (parent_input, helper_output) = pipes();
        let (helper_input, parent_output) = pipes();
        let mut parent = ParentPipeChannel::from_anonymous_files(
            parent_input,
            parent_output,
            Duration::from_secs(1),
        )
        .unwrap();
        let mut helper = PipeChannel {
            input: helper_input,
            output: helper_output,
        };
        let frame = Frame {
            version: PROTOCOL,
            session: Uuid::new_v4(),
            sequence: 0,
            body: ParentMessage::Cancel { transaction: None },
        };
        parent
            .send_parent(&frame, Instant::now() + Duration::from_secs(1))
            .unwrap();
        assert_eq!(
            helper
                .receive(Instant::now() + Duration::from_secs(1))
                .unwrap(),
            frame
        );
        let ack = Frame {
            version: PROTOCOL,
            session: frame.session,
            sequence: 0,
            body: HelperMessage::Disarmed { transaction: None },
        };
        helper
            .send(&ack, Instant::now() + Duration::from_secs(1))
            .unwrap();
        assert_eq!(
            parent
                .poll_helper(Instant::now() + Duration::from_secs(1))
                .unwrap(),
            Some(ack)
        );
    }
    #[test]
    fn parent_pipe_reader_retains_partial_header_and_bounds_incomplete_frames() {
        let (input, mut helper_output) = pipes();
        let (_helper_input, output) = pipes();
        let mut parent =
            ParentPipeChannel::from_anonymous_files(input, output, Duration::from_secs(1)).unwrap();
        let frame = Frame {
            version: PROTOCOL,
            session: Uuid::new_v4(),
            sequence: 0,
            body: HelperMessage::Disarmed { transaction: None },
        };
        let bytes = encode_frame(&frame).unwrap();
        helper_output.write_all(&bytes[..2]).unwrap();
        assert!(
            parent
                .poll_helper(Instant::now() + Duration::from_secs(1))
                .unwrap()
                .is_none()
        );
        helper_output.write_all(&bytes[2..]).unwrap();
        assert_eq!(
            parent
                .poll_helper(Instant::now() + Duration::from_secs(1))
                .unwrap(),
            Some(frame)
        );
        helper_output.write_all(&[0, 0]).unwrap();
        assert!(
            parent
                .poll_helper(Instant::now() + Duration::from_secs(1))
                .unwrap()
                .is_none()
        );
        parent.started = Some(Instant::now() - Duration::from_secs(2));
        assert!(
            parent
                .poll_helper(Instant::now() + Duration::from_secs(1))
                .is_err()
        );
    }
    #[test]
    fn parent_pipe_constructor_and_length_reject_regular_files_and_oversized_frames() {
        use std::os::fd::AsRawFd;
        let directory = tempfile::Builder::new()
            .permissions(fs::Permissions::from_mode(0o700))
            .tempdir()
            .unwrap();
        let file = File::create(directory.path().join("not-a-pipe.fixture")).unwrap();
        assert!(validate_anonymous_pipe(file.as_raw_fd()).is_err());
        let (_read, output) = pipes();
        assert!(
            ParentPipeChannel::from_anonymous_files(file, output, Duration::from_secs(1)).is_err()
        );
        let (input, mut helper_output) = pipes();
        let (_read, output) = pipes();
        let mut parent =
            ParentPipeChannel::from_anonymous_files(input, output, Duration::from_secs(1)).unwrap();
        helper_output
            .write_all(&((MAX_FRAME + 1) as u32).to_be_bytes())
            .unwrap();
        assert!(
            parent
                .poll_helper(Instant::now() + Duration::from_secs(1))
                .is_err()
        );
    }
    #[test]
    fn real_fixture_pipe_roundtrip_and_partial_header_deadline_are_bounded() {
        let (input, mut parent_write) = pipes();
        let (_parent_read, output) = pipes();
        let mut channel = PipeChannel { input, output };
        let frame = Frame {
            version: PROTOCOL,
            session: Uuid::new_v4(),
            sequence: 0,
            body: ParentMessage::Cancel { transaction: None },
        };
        parent_write
            .write_all(&encode_frame(&frame).unwrap())
            .unwrap();
        assert_eq!(
            channel
                .receive(Instant::now() + Duration::from_secs(1))
                .unwrap(),
            frame
        );
        parent_write.write_all(&[0, 0]).unwrap();
        let started = Instant::now();
        assert!(
            channel
                .receive(started + Duration::from_millis(20))
                .is_err()
        );
        assert!(started.elapsed() < Duration::from_secs(1));
    }
    #[test]
    fn oversized_pipe_frame_and_blocked_output_refuse_before_unbounded_io() {
        let (input, mut parent_write) = pipes();
        let (_parent_read, output) = pipes();
        let mut channel = PipeChannel { input, output };
        parent_write
            .write_all(&((MAX_FRAME + 1) as u32).to_be_bytes())
            .unwrap();
        assert!(
            channel
                .receive(Instant::now() + Duration::from_secs(1))
                .is_err()
        );
        let large = Frame {
            version: PROTOCOL,
            session: Uuid::new_v4(),
            sequence: 0,
            body: HelperMessage::Finished {
                transaction: Uuid::new_v4(),
                status: "x".repeat(32 * 1024),
            },
        };
        // Fill the real anonymous fixture pipe while deliberately withholding reads.
        let started = Instant::now();
        let deadline = started + Duration::from_millis(20);
        loop {
            if channel.send(&large, deadline).is_err() {
                break;
            }
        }
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}

#[cfg(test)]
mod codec_tests {
    use super::*;
    #[test]
    fn bounded_codec_rejects_unknown_fields_trailing_or_oversized_bytes() {
        let frame = Frame {
            version: PROTOCOL,
            session: Uuid::new_v4(),
            sequence: 0,
            body: ParentMessage::Cancel { transaction: None },
        };
        let bytes = encode_frame(&frame).unwrap();
        assert_eq!(decode_frame::<ParentMessage>(&bytes).unwrap(), frame);
        let mut trailing = bytes.clone();
        trailing.push(0);
        assert!(decode_frame::<ParentMessage>(&trailing).is_err());
        assert!(decode_frame::<ParentMessage>(&[0xff, 0xff, 0xff, 0xff]).is_err());
        let mut unknown = serde_json::to_value(&frame).unwrap();
        unknown["body"]["verified"] = serde_json::json!(true);
        let encoded = serde_json::to_vec(&unknown).unwrap();
        let mut bytes = (encoded.len() as u32).to_be_bytes().to_vec();
        bytes.extend(encoded);
        assert!(decode_frame::<ParentMessage>(&bytes).is_err());
    }
    #[test]
    fn nested_release_verification_flags_are_not_private_protocol_fields() {
        let frame = Frame {
            version: PROTOCOL,
            session: Uuid::new_v4(),
            sequence: 0,
            body: ParentMessage::Select {
                job: Uuid::new_v4(),
                client_nonce: Uuid::new_v4(),
                release: Release {
                    version: "0.2.0".into(),
                    platform: Platform::Macos,
                    architecture: Architecture::Arm64,
                    url: "https://fixture.invalid/never-requested.zip".into(),
                    size: 42,
                    sha256: "a".repeat(64),
                },
            },
        };
        let mut value = serde_json::to_value(&frame).unwrap();
        value["body"]["release"]["verified"] = serde_json::json!(true);
        let body = serde_json::to_vec(&value).unwrap();
        let mut bytes = (body.len() as u32).to_be_bytes().to_vec();
        bytes.extend(body);
        assert!(decode_frame::<ParentMessage>(&bytes).is_err());
    }
    #[test]
    fn dynamic_roles_pin_distinct_preview_and_helper_requirements() {
        let parent = RunningSubject::Parent(ParentBinding {
            pid: 42,
            start_seconds: 100,
            start_micros: 2,
        });
        assert_eq!(parent.identifier(), crate::updater::PREVIEW_ID);
        assert_eq!(RunningSubject::Helper.identifier(), HELPER_ID);
        assert_eq!(
            RunningSubject::ChildHelper(ParentBinding {
                pid: 43,
                start_seconds: 101,
                start_micros: 1
            })
            .identifier(),
            HELPER_ID
        );
        let requirement = code_requirement("FIXTURE001", parent.identifier()).unwrap();
        assert!(requirement.contains("identifier \"com.apoorvdarshan.coincide.rust\""));
        assert!(!requirement.contains(HELPER_ID));
        assert!(requirement.contains("certificate leaf[subject.OU] = \"FIXTURE001\""));
    }
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn dynamic_native_backend_never_falls_back_to_disk_on_non_mac() {
        assert_eq!(
            MacRunningCodeTrust
                .verify(&RunningSubject::Helper, "FIXTURE001")
                .unwrap_err()
                .to_string(),
            "Dynamic running-code verification is unavailable on this platform"
        );
    }
    #[test]
    fn trust_requirement_never_accepts_adhoc_unsigned_or_injected_anchor() {
        for invalid in ["", "-", "adhoc", "FIXTURE00\"", "fixture001"] {
            assert!(helper_requirement(invalid).is_err());
        }
        let requirement = helper_requirement("FIXTURE001").unwrap();
        assert!(requirement.contains("anchor apple generic"));
        assert!(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"));
        assert!(requirement.contains(HELPER_ID));
        assert!(!requirement.contains("com.apoorvdarshan.coincide\""));
    }
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn native_identity_is_truthfully_unavailable_on_non_mac() {
        // No native process/signature operation is called on this path.
        assert!(matches!(
            native_main().unwrap_err().to_string().as_str(),
            "Independent signed preview helper is unavailable on this platform"
                | "Update helper accepts no command-line arguments"
        ));
    }
}
