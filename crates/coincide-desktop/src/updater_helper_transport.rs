//! Default-unavailable native helper transport. The desktop owner must finish its
//! shutdown hooks before explicitly configuring this launcher. All native prepare,
//! copy, spawn and trust operations are worker-owned; tests use fake factories and
//! scripted/anonymous pipes, never launch/verify a real app or helper.
use super::updater_lifecycle::{
    FromHelper, HelperLauncher, HelperSession, NativePolicy, Selection, ToHelper,
};
use anyhow::{Context, Result, bail, ensure};
use coincide_core::{
    updater_helper::{
        Binding, Frame, HelperMessage, MAX_FRAME, PROTOCOL, ParentMessage, proposal_digest,
    },
    updater_install::Proposal,
};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError},
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

#[derive(Clone)]
pub struct TransportTimeouts {
    pub initial_command: Duration,
    pub prepare: Duration,
    pub proposal: Duration,
    pub approval: Duration,
    pub ready: Duration,
    pub normal_quit: Duration,
    pub consent: Duration,
    pub cancel: Duration,
    pub send: Duration,
    pub frame: Duration,
}
impl Default for TransportTimeouts {
    fn default() -> Self {
        Self {
            initial_command: Duration::from_secs(5),
            prepare: Duration::from_secs(300),
            proposal: Duration::from_secs(540),
            approval: Duration::from_secs(900),
            ready: Duration::from_secs(5),
            normal_quit: Duration::from_secs(7 * 24 * 3600),
            consent: Duration::from_secs(5),
            cancel: Duration::from_secs(5),
            send: Duration::from_secs(5),
            frame: Duration::from_secs(5),
        }
    }
}
#[derive(Clone)]
pub struct TransportConfig {
    /// Native startup configuration, never HTTP/CLI/JSON parameters. The native
    /// factory independently derives and compares actual signed launcher context.
    pub policy: NativePolicy,
    pub timeouts: TransportTimeouts,
    pub command_capacity: usize,
    pub event_capacity: usize,
}
impl TransportConfig {
    fn validate(&self) -> Result<()> {
        ensure!(
            (1..=16).contains(&self.command_capacity) && (1..=16).contains(&self.event_capacity),
            "Invalid helper queue bounds"
        );
        ensure!(
            self.policy.target.is_absolute()
                && self
                    .policy
                    .target
                    .file_name()
                    .is_some_and(|s| s == "Coincide Rust.app")
                && !self.policy.anchor.trim().is_empty()
                && self.policy.parent.pid > 1,
            "Fixed trusted native preview policy required"
        );
        for (value, cap) in [
            (&self.timeouts.initial_command, 30),
            (&self.timeouts.prepare, 900),
            (&self.timeouts.proposal, 900),
            (&self.timeouts.approval, 900),
            (&self.timeouts.ready, 30),
            (&self.timeouts.normal_quit, 7 * 24 * 3600),
            (&self.timeouts.consent, 30),
            (&self.timeouts.cancel, 30),
            (&self.timeouts.send, 30),
            (&self.timeouts.frame, 30),
        ] {
            ensure!(
                !value.is_zero() && *value <= Duration::from_secs(cap),
                "Invalid helper transport deadline"
            );
        }
        let startup = self
            .timeouts
            .initial_command
            .checked_add(self.timeouts.prepare)
            .and_then(|t| t.checked_add(self.timeouts.proposal))
            .context("Helper startup budget overflow")?;
        ensure!(
            !self.policy.handshake_timeout.is_zero()
                && self.policy.handshake_timeout <= Duration::from_secs(900)
                && startup <= self.policy.handshake_timeout,
            "Helper startup budgets exceed native lifecycle handshake"
        );
        Ok(())
    }
}
/// Adapters are trusted native code, not request-supplied proof. poll must retain
/// partial frames and return promptly; send must enforce its absolute deadline.
pub trait WorkerIo: Send {
    fn send(&mut self, frame: &Frame<ParentMessage>, deadline: Instant) -> Result<()>;
    fn poll(&mut self, deadline: Instant) -> Result<Option<Frame<HelperMessage>>>;
}
pub trait WorkerChild: Send {
    fn verify(&mut self, deadline: Instant) -> Result<()>;
    fn has_exited(&mut self) -> Result<bool>;
}
pub struct WorkerConnection {
    io: Box<dyn WorkerIo>,
    child: Box<dyn WorkerChild>,
}
pub trait WorkerFactory: Send + Sync {
    fn prepare_spawn(
        &self,
        policy: &NativePolicy,
        timeouts: &TransportTimeouts,
        deadline: Instant,
        cancelled: &AtomicBool,
    ) -> Result<WorkerConnection>;
}
/// Concrete native factory; this type alone does not prepare or launch anything.
/// Unsupported hosts return unavailable. Only explicitly configured worker calls it.
pub struct NativeWorkerFactory;
impl WorkerFactory for NativeWorkerFactory {
    fn prepare_spawn(
        &self,
        policy: &NativePolicy,
        timeouts: &TransportTimeouts,
        deadline: Instant,
        cancelled: &AtomicBool,
    ) -> Result<WorkerConnection> {
        #[cfg(target_os = "macos")]
        {
            use coincide_core::updater_helper::{ParentPipeChannel, prepare_native_helper};
            use std::{
                fs::File,
                os::fd::OwnedFd,
                process::{Command, Stdio},
            };
            ensure!(
                !cancelled.load(Ordering::SeqCst) && Instant::now() < deadline,
                "Helper preparation cancelled/expired"
            );
            let prepared = prepare_native_helper(&policy.anchor, deadline)?;
            ensure!(
                prepared.target() == policy.target
                    && prepared.parent() == &policy.parent
                    && prepared.installed_version() == policy.installed_version,
                "Actual native launcher differs from configured policy"
            );
            ensure!(
                !cancelled.load(Ordering::SeqCst) && Instant::now() < deadline,
                "Helper preparation cancelled/expired"
            );
            // No shell, args, ambient configuration, GUI activation, target kill,
            // elevation or launch of a desktop app. Only the fixed verified helper.
            let child = Command::new(prepared.executable())
                .env_clear()
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()?;
            // Own the process before any fallible descriptor/trust operation so
            // even a failed launch handshake receives bounded, non-killing reaping.
            let mut process = NativeChild {
                child: Some(child),
                prepared,
                binding: None,
            };
            let (input, output, pid) = {
                let child = process
                    .child
                    .as_mut()
                    .context("Helper child handle missing")?;
                let input: OwnedFd = child.stdout.take().context("Helper stdout missing")?.into();
                let output: OwnedFd = child.stdin.take().context("Helper stdin missing")?.into();
                (input, output, child.id())
            };
            let io = ParentPipeChannel::from_anonymous_files(
                File::from(input),
                File::from(output),
                timeouts.frame,
            )?;
            process.binding = Some(process.prepared.verify_child(pid, deadline)?);
            ensure!(
                !cancelled.load(Ordering::SeqCst) && Instant::now() < deadline,
                "Helper preparation cancelled/expired"
            );
            Ok(WorkerConnection {
                io: Box::new(NativeIo(io)),
                child: Box::new(process),
            })
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (policy, timeouts, deadline, cancelled);
            bail!("Signed native update helper launcher unavailable on this platform")
        }
    }
}
#[cfg(target_os = "macos")]
struct NativeIo(coincide_core::updater_helper::ParentPipeChannel);
#[cfg(target_os = "macos")]
impl WorkerIo for NativeIo {
    fn send(&mut self, frame: &Frame<ParentMessage>, deadline: Instant) -> Result<()> {
        self.0.send_parent(frame, deadline)
    }
    fn poll(&mut self, deadline: Instant) -> Result<Option<Frame<HelperMessage>>> {
        self.0.poll_helper(deadline)
    }
}
#[cfg(target_os = "macos")]
struct NativeChild {
    child: Option<std::process::Child>,
    prepared: coincide_core::updater_helper::PreparedNativeHelper,
    binding: Option<coincide_core::updater_install::ParentBinding>,
}
#[cfg(target_os = "macos")]
impl WorkerChild for NativeChild {
    fn verify(&mut self, deadline: Instant) -> Result<()> {
        let child = self.child.as_mut().context("Helper child handle closed")?;
        ensure!(
            child.try_wait()?.is_none(),
            "Verified helper exited prematurely"
        );
        ensure!(
            Some(self.prepared.verify_child(child.id(), deadline)?) == self.binding,
            "Verified helper process instance changed"
        );
        Ok(())
    }
    fn has_exited(&mut self) -> Result<bool> {
        Ok(self
            .child
            .as_mut()
            .context("Helper child handle closed")?
            .try_wait()?
            .is_some())
    }
}

#[cfg(target_os = "macos")]
impl Drop for NativeChild {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };
        if child.try_wait().ok().flatten().is_some() {
            return;
        }
        // The helper may outlive the normal quitting parent. Never kill it or
        // block a UI/drop thread. Reap boundedly; retain private evidence if an
        // abnormal helper remains after this window (OS reparents it on app exit).
        let _ = thread::Builder::new()
            .name("rust-update-helper-reap".into())
            .spawn(move || {
                let deadline = Instant::now() + Duration::from_secs(45);
                while Instant::now() < deadline {
                    if child.try_wait().ok().flatten().is_some() {
                        break;
                    }
                    thread::sleep(Duration::from_millis(20));
                }
            });
    }
}

#[derive(Default)]
pub struct TransportLauncher {
    configured: Option<(TransportConfig, Arc<dyn WorkerFactory>)>,
    active: Arc<Mutex<Option<Uuid>>>,
    consent_fence: Arc<AtomicBool>,
}
impl TransportLauncher {
    /// Root must not call this until actual native owner hooks are mounted. There
    /// is intentionally no enable/verified boolean or runtime settings decoder.
    pub fn configured(config: TransportConfig, factory: Arc<dyn WorkerFactory>) -> Result<Self> {
        config.validate()?;
        Ok(Self {
            configured: Some((config, factory)),
            active: Arc::new(Mutex::new(None)),
            consent_fence: Arc::new(AtomicBool::new(false)),
        })
    }
}
struct Shared {
    stop: AtomicBool,
    cancel_requested: AtomicBool,
    consent_boundary: AtomicBool,
    closed: AtomicBool,
    terminal: Mutex<Option<FromHelper>>,
}
impl Shared {
    fn terminal(&self, event: FromHelper) {
        if let Ok(mut slot) = self.terminal.lock()
            && slot.is_none()
        {
            *slot = Some(event);
        }
        self.closed.store(true, Ordering::SeqCst);
    }
}
struct QueuedSession {
    commands: SyncSender<ToHelper>,
    events: Receiver<FromHelper>,
    shared: Arc<Shared>,
    consent_fence: Arc<AtomicBool>,
    terminal_consumed: bool,
}
impl Drop for QueuedSession {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        if !self.shared.consent_boundary.load(Ordering::SeqCst) {
            self.shared.cancel_requested.store(true, Ordering::SeqCst);
        }
    }
}
fn bounded_command(message: &ToHelper) -> Result<()> {
    let release = match message {
        ToHelper::Select(s) => Some(&s.release),
        ToHelper::Approve(p) | ToHelper::Decline(p) | ToHelper::Quiescent(p) => Some(&p.release),
        _ => None,
    };
    let mut size = release.map_or(0, |r| {
        r.version
            .len()
            .saturating_add(r.url.len())
            .saturating_add(r.sha256.len())
    });
    if let ToHelper::Approve(p) | ToHelper::Decline(p) | ToHelper::Quiescent(p) = message {
        size = size
            .saturating_add(p.target.as_os_str().len())
            .saturating_add(p.anchor.len())
            .saturating_add(p.installed_version.len())
            .saturating_add(p.installed_tree.len())
            .saturating_add(p.candidate_tree.len());
    }
    ensure!(
        size <= MAX_FRAME / 2,
        "Helper command exceeds bounded policy"
    );
    Ok(())
}
impl HelperSession for QueuedSession {
    fn send(&mut self, message: ToHelper) -> Result<()> {
        bounded_command(&message)?;
        ensure!(
            !self.shared.closed.load(Ordering::SeqCst),
            "Helper session closed"
        );
        let quiescent = matches!(message, ToHelper::Quiescent(_));
        let cancelling = matches!(message, ToHelper::Cancel { .. } | ToHelper::Decline(_));
        ensure!(
            !self.shared.consent_boundary.load(Ordering::SeqCst),
            "Clean consent may have been sent; session cannot be reused/disarmed"
        );
        if quiescent {
            self.consent_fence.store(true, Ordering::SeqCst);
            self.shared.consent_boundary.store(true, Ordering::SeqCst);
        }
        if cancelling {
            self.shared.cancel_requested.store(true, Ordering::SeqCst);
        }
        self.commands
            .try_send(message)
            .map_err(|_| anyhow::anyhow!("Helper command queue full or closed"))
    }
    fn poll(&mut self) -> Result<Option<FromHelper>> {
        if self.terminal_consumed {
            return Ok(None);
        }
        match self.shared.terminal.try_lock() {
            Ok(mut slot) => {
                if let Some(terminal) = slot.take() {
                    self.terminal_consumed = true;
                    return Ok(Some(terminal));
                }
            }
            Err(std::sync::TryLockError::WouldBlock) => return Ok(None),
            Err(std::sync::TryLockError::Poisoned(_)) => bail!("Helper terminal lock failed"),
        }
        for _ in 0..16 {
            match self.events.try_recv() {
                Ok(event) => {
                    if self.shared.cancel_requested.load(Ordering::SeqCst)
                        && matches!(event, FromHelper::Proposal(_) | FromHelper::Ready { .. })
                    {
                        continue;
                    }
                    return Ok(Some(event));
                }
                Err(TryRecvError::Empty) => return Ok(None),
                Err(TryRecvError::Disconnected) => {
                    // Worker writes its terminal slot before disconnecting; retry
                    // on the next native tick rather than inventing disarm/quit.
                    return Ok(None);
                }
            }
        }
        Ok(None)
    }
}
impl HelperLauncher for TransportLauncher {
    fn start_verified(&mut self) -> Result<Box<dyn HelperSession>> {
        let (config, factory) = self
            .configured
            .clone()
            .context("Native owner hooks/helper transport unavailable")?;
        ensure!(
            !self.consent_fence.load(Ordering::SeqCst),
            "Prior clean consent requires native recovery; launcher fenced"
        );
        let generation = Uuid::new_v4();
        {
            let mut active = self
                .active
                .try_lock()
                .map_err(|_| anyhow::anyhow!("Helper launcher busy/unavailable"))?;
            ensure!(
                active.is_none(),
                "A helper session/uncertain consent is still active"
            );
            *active = Some(generation);
        }
        let (sender, commands) = mpsc::sync_channel(config.command_capacity);
        let (events, receiver) = mpsc::sync_channel(config.event_capacity);
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            cancel_requested: AtomicBool::new(false),
            consent_boundary: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            terminal: Mutex::new(None),
        });
        let worker_shared = shared.clone();
        let active = self.active.clone();
        if thread::Builder::new()
            .name("rust-update-helper-transport".into())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_worker(config, factory, commands, events, worker_shared.clone())
                }));
                let terminal = match outcome {
                    Ok(Ok(event)) => event,
                    Ok(Err(error)) => {
                        FromHelper::Failed(error.to_string().chars().take(1024).collect())
                    }
                    Err(_) => FromHelper::Failed("Update helper worker failed".into()),
                };
                // An old generation cannot clear a successor. A consent boundary
                // permanently fences this launcher, even if an ACK was lost.
                if !worker_shared.consent_boundary.load(Ordering::SeqCst)
                    && let Ok(mut slot) = active.lock()
                    && *slot == Some(generation)
                {
                    *slot = None;
                }
                worker_shared.terminal(terminal);
            })
            .is_err()
        {
            if let Ok(mut slot) = self.active.try_lock()
                && *slot == Some(generation)
            {
                *slot = None;
            }
            bail!("Cannot start bounded helper worker");
        }
        Ok(Box::new(QueuedSession {
            commands: sender,
            events: receiver,
            shared,
            consent_fence: self.consent_fence.clone(),
            terminal_consumed: false,
        }))
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Proposal,
    Decision,
    Ready,
    Armed,
    NormalQuit,
    Consent,
    Cancelling,
}
struct ProtocolWorker {
    config: TransportConfig,
    connection: WorkerConnection,
    shared: Arc<Shared>,
    events: SyncSender<FromHelper>,
    session: Uuid,
    nonce: Uuid,
    incoming: u64,
    outgoing: u64,
    phase: Phase,
    deadline: Instant,
    selection: Selection,
    proposal: Option<Proposal>,
    binding: Option<Binding>,
    cancel_transaction: Option<Uuid>,
    approved: bool,
    ready_ack_sent: bool,
}
impl ProtocolWorker {
    fn send(&mut self, body: ParentMessage) -> Result<()> {
        let frame = Frame {
            version: PROTOCOL,
            session: self.session,
            sequence: self.outgoing,
            body,
        };
        self.connection.io.send(
            &frame,
            self.deadline
                .min(Instant::now() + self.config.timeouts.send),
        )?;
        self.outgoing = self
            .outgoing
            .checked_add(1)
            .context("Helper sequence overflow")?;
        Ok(())
    }
    fn phase(&mut self, phase: Phase, timeout: Duration) {
        self.phase = phase;
        self.deadline = Instant::now() + timeout;
    }
    fn progress(&self, event: FromHelper) -> Result<()> {
        if !self.shared.cancel_requested.load(Ordering::SeqCst) {
            self.events
                .try_send(event)
                .map_err(|_| anyhow::anyhow!("Helper event queue full/closed"))?;
        }
        Ok(())
    }
    fn matches_proposal(&self, proposal: &Proposal) -> bool {
        proposal.target == self.config.policy.target
            && proposal.anchor == self.config.policy.anchor
            && proposal.installed_version == self.config.policy.installed_version
            && proposal.release == self.selection.release
            && !proposal.transaction.is_nil()
            && [&proposal.installed_tree, &proposal.candidate_tree]
                .iter()
                .all(|hash| {
                    hash.len() == 64
                        && hash
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                })
    }
    fn command(&mut self, command: ToHelper) -> Result<()> {
        bounded_command(&command)?;
        match command {
            ToHelper::Select(_) => bail!("Repeated helper selection refused"),
            ToHelper::Approve(proposal) => {
                ensure!(
                    self.phase == Phase::Decision && self.proposal.as_ref() == Some(&proposal),
                    "Native approval proposal/order differs"
                );
                if !self.shared.cancel_requested.load(Ordering::SeqCst) {
                    self.send(ParentMessage::Approve {
                        binding: self.binding.clone().context("Missing verified binding")?,
                    })?;
                    self.approved = true;
                    self.phase(Phase::Ready, self.config.timeouts.ready);
                }
            }
            ToHelper::Decline(proposal) => {
                ensure!(
                    self.phase == Phase::Decision && self.proposal.as_ref() == Some(&proposal),
                    "Native decline proposal/order differs"
                );
                self.send(ParentMessage::Decline {
                    binding: self.binding.clone().context("Missing verified binding")?,
                })?;
                self.cancel_transaction = Some(proposal.transaction);
                self.phase(Phase::Cancelling, self.config.timeouts.cancel);
            }
            ToHelper::Cancel { transaction } => {
                if self.phase == Phase::Cancelling {
                    ensure!(
                        transaction == self.cancel_transaction,
                        "Successor cancellation differs"
                    );
                    return Ok(());
                }
                ensure!(
                    self.phase != Phase::Consent
                        && (transaction == self.proposal.as_ref().map(|p| p.transaction)
                            || (transaction.is_none()
                                && matches!(self.phase, Phase::Proposal | Phase::Decision))),
                    "Cancellation binding/order differs"
                );
                self.send(ParentMessage::Cancel { transaction })?;
                self.cancel_transaction = transaction;
                self.phase(Phase::Cancelling, self.config.timeouts.cancel);
            }
            ToHelper::Quiescent(proposal) => {
                ensure!(
                    self.phase == Phase::NormalQuit
                        && !self.shared.cancel_requested.load(Ordering::SeqCst)
                        && self.proposal.as_ref() == Some(&proposal),
                    "Native quiescence proposal/order differs"
                );
                self.connection.child.verify(self.deadline)?;
                self.send(ParentMessage::CleanQuit {
                    binding: self.binding.clone().context("Missing approved binding")?,
                })?;
                self.phase(Phase::Consent, self.config.timeouts.consent);
            }
        }
        Ok(())
    }
    fn event(&mut self, frame: Frame<HelperMessage>) -> Result<Option<FromHelper>> {
        ensure!(
            frame.version == PROTOCOL
                && frame.session == self.session
                && frame.sequence == self.incoming,
            "Helper version/session/sequence differs"
        );
        self.incoming = self
            .incoming
            .checked_add(1)
            .context("Helper incoming sequence overflow")?;
        ensure!(self.incoming <= 16, "Too many helper protocol frames");
        match frame.body {
            HelperMessage::Proposal {
                binding,
                proposal,
                client_nonce,
            } => {
                ensure!(
                    (self.phase == Phase::Proposal || self.phase == Phase::Cancelling)
                        && self.proposal.is_none()
                        && client_nonce == self.nonce
                        && !binding.challenge.is_nil()
                        && binding.transaction == proposal.transaction
                        && binding.proposal_sha256 == proposal_digest(&proposal)?
                        && self.matches_proposal(&proposal),
                    "Helper proposal/nonce/digest differs"
                );
                self.connection.child.verify(self.deadline)?;
                self.binding = Some(binding);
                self.proposal = Some((*proposal).clone());
                if self.phase != Phase::Cancelling {
                    self.phase(Phase::Decision, self.config.timeouts.approval);
                }
                self.progress(FromHelper::Proposal(*proposal))?;
            }
            HelperMessage::Ready { binding, parent } => {
                ensure!(
                    (self.phase == Phase::Ready || self.phase == Phase::Cancelling)
                        && self.approved
                        && self.binding.as_ref() == Some(&binding)
                        && parent == self.config.policy.parent,
                    "Helper READY binding/parent differs"
                );
                self.connection.child.verify(self.deadline)?;
                if self.phase != Phase::Cancelling
                    && !self.shared.cancel_requested.load(Ordering::SeqCst)
                {
                    self.send(ParentMessage::ReadyAck { binding })?;
                    self.ready_ack_sent = true;
                    self.phase(Phase::Armed, self.config.timeouts.ready);
                }
            }
            HelperMessage::Armed { binding } => {
                ensure!(
                    (self.phase == Phase::Armed || self.phase == Phase::Cancelling)
                        && self.ready_ack_sent
                        && self.binding.as_ref() == Some(&binding),
                    "Helper Armed binding/order differs"
                );
                self.connection.child.verify(self.deadline)?;
                if self.phase != Phase::Cancelling {
                    self.phase(Phase::NormalQuit, self.config.timeouts.normal_quit);
                }
                self.progress(FromHelper::Ready {
                    proposal: self.proposal.clone().context("Missing approved proposal")?,
                    parent: self.config.policy.parent.clone(),
                })?;
            }
            HelperMessage::Disarmed { transaction } => {
                ensure!(
                    self.phase == Phase::Cancelling
                        && transaction == self.cancel_transaction
                        && !self.shared.consent_boundary.load(Ordering::SeqCst),
                    "Helper disarm binding/consent differs"
                );
                return Ok(Some(FromHelper::Disarmed { transaction }));
            }
            HelperMessage::ConsentAck { binding } => {
                ensure!(
                    self.phase == Phase::Consent && self.binding.as_ref() == Some(&binding),
                    "Helper consent ACK binding/order differs"
                );
                self.connection.child.verify(self.deadline)?;
                return Ok(Some(FromHelper::ConsentPersisted(
                    self.proposal.clone().context("Missing clean proposal")?,
                )));
            }
            HelperMessage::Finished { .. } => {
                bail!("Helper finished before native parent normal quit")
            }
        }
        Ok(None)
    }
}
fn run_worker(
    config: TransportConfig,
    factory: Arc<dyn WorkerFactory>,
    commands: Receiver<ToHelper>,
    events: SyncSender<FromHelper>,
    shared: Arc<Shared>,
) -> Result<FromHelper> {
    let first = commands
        .recv_timeout(config.timeouts.initial_command)
        .context("Helper selection deadline expired")?;
    if matches!(first, ToHelper::Cancel { transaction: None }) {
        ensure!(
            !shared.consent_boundary.load(Ordering::SeqCst),
            "Consent uncertain before helper preparation completed"
        );
        return Ok(FromHelper::Disarmed { transaction: None });
    }
    let ToHelper::Select(selection) = first else {
        bail!("Helper requires an initial native stage selection")
    };
    bounded_command(&ToHelper::Select(selection.clone()))?;
    ensure!(!selection.job.is_nil(), "Private stage UUID required");
    if shared.stop.load(Ordering::SeqCst) || shared.cancel_requested.load(Ordering::SeqCst) {
        ensure!(
            !shared.consent_boundary.load(Ordering::SeqCst),
            "Consent uncertain before helper preparation completed"
        );
        return Ok(FromHelper::Disarmed { transaction: None });
    }
    let connection = match factory.prepare_spawn(
        &config.policy,
        &config.timeouts,
        Instant::now() + config.timeouts.prepare,
        &shared.cancel_requested,
    ) {
        Ok(connection) => connection,
        Err(error) => {
            if shared.cancel_requested.load(Ordering::SeqCst) {
                ensure!(
                    !shared.consent_boundary.load(Ordering::SeqCst),
                    "Consent uncertain before helper preparation completed"
                );
                return Ok(FromHelper::Disarmed { transaction: None });
            }
            return Err(error);
        }
    };
    if shared.stop.load(Ordering::SeqCst) || shared.cancel_requested.load(Ordering::SeqCst) {
        ensure!(
            !shared.consent_boundary.load(Ordering::SeqCst),
            "Consent uncertain before helper preparation completed"
        );
        return Ok(FromHelper::Disarmed { transaction: None });
    }
    let mut worker = ProtocolWorker {
        config: config.clone(),
        connection,
        shared: shared.clone(),
        events,
        session: Uuid::new_v4(),
        nonce: Uuid::new_v4(),
        incoming: 0,
        outgoing: 0,
        phase: Phase::Proposal,
        deadline: Instant::now() + config.timeouts.proposal,
        selection: selection.clone(),
        proposal: None,
        binding: None,
        cancel_transaction: None,
        approved: false,
        ready_ack_sent: false,
    };
    worker.send(ParentMessage::Select {
        job: selection.job,
        release: selection.release,
        client_nonce: worker.nonce,
    })?;
    loop {
        ensure!(
            Instant::now() < worker.deadline,
            "Helper transport phase deadline expired"
        );
        for _ in 0..16 {
            match commands.try_recv() {
                Ok(command) => worker.command(command)?,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    shared.stop.store(true, Ordering::SeqCst);
                    break;
                }
            }
        }
        if shared.stop.load(Ordering::SeqCst) {
            ensure!(
                !shared.consent_boundary.load(Ordering::SeqCst),
                "Consent uncertain after native session closed"
            );
            if worker.phase != Phase::Cancelling {
                shared.cancel_requested.store(true, Ordering::SeqCst);
                worker.command(ToHelper::Cancel {
                    transaction: worker.proposal.as_ref().map(|p| p.transaction),
                })?;
            }
        }
        if let Some(frame) = worker.connection.io.poll(worker.deadline)? {
            if let Some(terminal) = worker.event(frame)? {
                return Ok(terminal);
            }
        } else {
            ensure!(
                !worker.connection.child.has_exited()?,
                "Verified helper exited without acknowledgement"
            );
            thread::sleep(Duration::from_millis(5));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::{
        updater::{Architecture, Platform, Release},
        updater_helper::{decode_frame, encode_frame},
        updater_install::ParentBinding,
    };
    use std::{collections::VecDeque, fs, path::PathBuf, sync::Condvar};

    struct Files {
        root: PathBuf,
        trust: PathBuf,
    }
    impl Files {
        fn new() -> Arc<Self> {
            let root =
                std::env::temp_dir().join(format!("coincide-transport-fixture-{}", Uuid::new_v4()));
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            }
            #[cfg(not(unix))]
            fs::create_dir(&root).unwrap();
            let root = root.canonicalize().unwrap();
            let trust = root.join("fake-running-trust.fixture");
            fs::write(&trust, b"FAKE-SIGNED-CHILD-TEST-ONLY").unwrap();
            Arc::new(Self { root, trust })
        }
    }
    impl Drop for Files {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.trust);
            let _ = fs::remove_dir(&self.root);
        }
    }
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Mode {
        Success,
        WrongNonce,
        WrongDigest,
        WrongSession,
        WrongSequence,
        WrongParent,
        WrongDisarm,
        WrongConsent,
        LostConsent,
        Exited,
        NoProposal,
    }
    struct Script {
        mode: Mode,
        sent: Vec<Frame<ParentMessage>>,
        replies: VecDeque<Frame<HelperMessage>>,
        incoming: u64,
        session: Uuid,
        proposal: Proposal,
        binding: Binding,
        allow_proposal: bool,
        allow_ready: bool,
        allow_armed: bool,
        fail_read: bool,
    }
    struct ScriptIo(Arc<Mutex<Script>>);
    impl WorkerIo for ScriptIo {
        fn send(&mut self, frame: &Frame<ParentMessage>, deadline: Instant) -> Result<()> {
            ensure!(Instant::now() < deadline, "fake write deadline");
            let frame: Frame<ParentMessage> = decode_frame(&encode_frame(frame)?)?;
            let mut script = self.0.lock().unwrap();
            ensure!(
                frame.sequence == script.sent.len() as u64 && frame.version == PROTOCOL,
                "fake parent sequence"
            );
            script.sent.push(frame.clone());
            let reply = match frame.body {
                ParentMessage::Select { client_nonce, .. } => {
                    script.session = frame.session;
                    if matches!(script.mode, Mode::Exited | Mode::NoProposal) {
                        return Ok(());
                    }
                    let mut binding = script.binding.clone();
                    if script.mode == Mode::WrongDigest {
                        binding.proposal_sha256 = "f".repeat(64);
                    }
                    Some(HelperMessage::Proposal {
                        binding,
                        proposal: Box::new(script.proposal.clone()),
                        client_nonce: if script.mode == Mode::WrongNonce {
                            Uuid::new_v4()
                        } else {
                            client_nonce
                        },
                    })
                }
                ParentMessage::Approve { binding } => {
                    ensure!(binding == script.binding, "fake approval binding");
                    let parent = ParentBinding {
                        pid: if script.mode == Mode::WrongParent {
                            43
                        } else {
                            42
                        },
                        start_seconds: 100,
                        start_micros: 2,
                    };
                    Some(HelperMessage::Ready { binding, parent })
                }
                ParentMessage::ReadyAck { binding } => {
                    ensure!(binding == script.binding, "fake ready ACK");
                    Some(HelperMessage::Armed { binding })
                }
                ParentMessage::Decline { binding } => Some(HelperMessage::Disarmed {
                    transaction: Some(binding.transaction),
                }),
                ParentMessage::Cancel { transaction } => Some(HelperMessage::Disarmed {
                    transaction: if script.mode == Mode::WrongDisarm {
                        Some(Uuid::new_v4())
                    } else {
                        transaction
                    },
                }),
                ParentMessage::CleanQuit { mut binding } => {
                    if script.mode == Mode::LostConsent {
                        script.fail_read = true;
                        return Ok(());
                    }
                    if script.mode == Mode::WrongConsent {
                        binding.challenge = Uuid::new_v4();
                    }
                    Some(HelperMessage::ConsentAck { binding })
                }
            };
            if let Some(body) = reply {
                let response = Frame {
                    version: PROTOCOL,
                    session: if script.mode == Mode::WrongSession {
                        Uuid::new_v4()
                    } else {
                        script.session
                    },
                    sequence: if script.mode == Mode::WrongSequence {
                        script.incoming + 1
                    } else {
                        script.incoming
                    },
                    body,
                };
                script.incoming += 1;
                script.replies.push_back(response);
            }
            Ok(())
        }
        fn poll(&mut self, deadline: Instant) -> Result<Option<Frame<HelperMessage>>> {
            ensure!(Instant::now() < deadline, "fake read deadline");
            let mut script = self.0.lock().unwrap();
            ensure!(!script.fail_read, "fake lost consent ACK pipe");
            let blocked = script
                .replies
                .front()
                .is_some_and(|frame| match frame.body {
                    HelperMessage::Proposal { .. } => !script.allow_proposal,
                    HelperMessage::Ready { .. } => !script.allow_ready,
                    HelperMessage::Armed { .. } => !script.allow_armed,
                    _ => false,
                });
            if blocked {
                return Ok(None);
            }
            script
                .replies
                .pop_front()
                .map(|frame| decode_frame(&encode_frame(&frame)?))
                .transpose()
        }
    }
    struct FakeChild {
        files: Arc<Files>,
        script: Arc<Mutex<Script>>,
    }
    impl WorkerChild for FakeChild {
        fn verify(&mut self, deadline: Instant) -> Result<()> {
            ensure!(
                Instant::now() < deadline,
                "fake child verification deadline"
            );
            ensure!(
                fs::read(&self.files.trust)? == b"FAKE-SIGNED-CHILD-TEST-ONLY",
                "fake dynamic child trust refused"
            );
            Ok(())
        }
        fn has_exited(&mut self) -> Result<bool> {
            Ok(self.script.lock().unwrap().mode == Mode::Exited)
        }
    }
    struct FakeFactory {
        script: Arc<Mutex<Script>>,
        files: Arc<Files>,
        gate: (Mutex<bool>, Condvar),
        started: AtomicBool,
        worker_thread: Mutex<Option<thread::ThreadId>>,
    }
    impl WorkerFactory for FakeFactory {
        fn prepare_spawn(
            &self,
            _: &NativePolicy,
            _: &TransportTimeouts,
            deadline: Instant,
            cancelled: &AtomicBool,
        ) -> Result<WorkerConnection> {
            *self.worker_thread.lock().unwrap() = Some(thread::current().id());
            self.started.store(true, Ordering::SeqCst);
            let mut gate = self.gate.0.lock().unwrap();
            while !*gate {
                ensure!(
                    Instant::now() < deadline && !cancelled.load(Ordering::SeqCst),
                    "fake preparation cancelled/expired"
                );
                gate = self
                    .gate
                    .1
                    .wait_timeout(gate, Duration::from_millis(2))
                    .unwrap()
                    .0;
            }
            let mut child = FakeChild {
                files: self.files.clone(),
                script: self.script.clone(),
            };
            child.verify(deadline)?;
            Ok(WorkerConnection {
                io: Box::new(ScriptIo(self.script.clone())),
                child: Box::new(child),
            })
        }
    }
    struct Harness {
        config: TransportConfig,
        factory: Arc<FakeFactory>,
        selection: Selection,
    }
    impl Harness {
        fn new(mode: Mode) -> Self {
            let files = Files::new();
            let release = Release {
                version: "0.2.0".into(),
                platform: Platform::Macos,
                architecture: Architecture::Arm64,
                url: "https://fixture.invalid/rust-preview/0.2.0/Coincide-Rust-macos-arm64.zip"
                    .into(),
                size: 42,
                sha256: "a".repeat(64),
            };
            let proposal = Proposal {
                transaction: Uuid::new_v4(),
                target: files.root.join("Coincide Rust.app"),
                installed_version: "0.1.0".into(),
                release: release.clone(),
                anchor: "FIXTURE001".into(),
                installed_tree: "b".repeat(64),
                candidate_tree: "c".repeat(64),
            };
            let binding = Binding {
                challenge: Uuid::new_v4(),
                transaction: proposal.transaction,
                proposal_sha256: proposal_digest(&proposal).unwrap(),
            };
            let script = Arc::new(Mutex::new(Script {
                mode,
                sent: vec![],
                replies: VecDeque::new(),
                incoming: 0,
                session: Uuid::nil(),
                proposal,
                binding,
                allow_proposal: true,
                allow_ready: true,
                allow_armed: true,
                fail_read: false,
            }));
            let factory = Arc::new(FakeFactory {
                script,
                files,
                gate: (Mutex::new(true), Condvar::new()),
                started: AtomicBool::new(false),
                worker_thread: Mutex::new(None),
            });
            let policy = NativePolicy {
                target: factory.script.lock().unwrap().proposal.target.clone(),
                anchor: "FIXTURE001".into(),
                installed_version: "0.1.0".into(),
                parent: ParentBinding {
                    pid: 42,
                    start_seconds: 100,
                    start_micros: 2,
                },
                handshake_timeout: Duration::from_secs(10),
                shutdown_timeout: Duration::from_secs(2),
            };
            let timeouts = TransportTimeouts {
                initial_command: Duration::from_secs(2),
                prepare: Duration::from_secs(2),
                proposal: Duration::from_secs(2),
                approval: Duration::from_secs(2),
                ready: Duration::from_secs(2),
                normal_quit: Duration::from_secs(2),
                consent: Duration::from_secs(2),
                cancel: Duration::from_secs(2),
                send: Duration::from_secs(2),
                frame: Duration::from_secs(2),
            };
            Self {
                config: TransportConfig {
                    policy,
                    timeouts,
                    command_capacity: 4,
                    event_capacity: 2,
                },
                factory,
                selection: Selection {
                    job: Uuid::new_v4(),
                    release,
                },
            }
        }
        fn launcher(&self) -> TransportLauncher {
            TransportLauncher::configured(self.config.clone(), self.factory.clone()).unwrap()
        }
        fn start(&self, launcher: &mut TransportLauncher) -> Box<dyn HelperSession> {
            let mut session = launcher.start_verified().unwrap();
            session
                .send(ToHelper::Select(self.selection.clone()))
                .unwrap();
            session
        }
        fn release(&self) {
            *self.factory.gate.0.lock().unwrap() = true;
            self.factory.gate.1.notify_all();
        }
    }
    fn until(mut predicate: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while !predicate() {
            assert!(
                Instant::now() < deadline,
                "fake transport condition timed out"
            );
            thread::sleep(Duration::from_millis(2));
        }
    }
    fn event(session: &mut dyn HelperSession) -> FromHelper {
        let mut result = None;
        until(|| {
            result = session.poll().unwrap();
            result.is_some()
        });
        result.unwrap()
    }
    fn proposal(session: &mut dyn HelperSession) -> Proposal {
        let FromHelper::Proposal(p) = event(session) else {
            panic!("missing proposal")
        };
        p
    }
    fn ready(session: &mut dyn HelperSession) -> Proposal {
        let p = proposal(session);
        session.send(ToHelper::Approve(p.clone())).unwrap();
        let FromHelper::Ready {
            proposal: received, ..
        } = event(session)
        else {
            panic!("missing ready")
        };
        assert_eq!(received, p);
        p
    }
    #[test]
    fn default_is_unavailable_without_native_hooks_or_factory_calls() {
        assert!(TransportLauncher::default().start_verified().is_err());
        let mut h = Harness::new(Mode::Success);
        h.config.command_capacity = 0;
        assert!(TransportLauncher::configured(h.config, h.factory).is_err());
    }
    #[test]
    fn ui_calls_do_not_wait_for_worker_preparation_and_cancel_prevents_select() {
        let h = Harness::new(Mode::Success);
        *h.factory.gate.0.lock().unwrap() = false;
        let mut launcher = h.launcher();
        let start = Instant::now();
        let mut session = h.start(&mut launcher);
        assert!(start.elapsed() < Duration::from_secs(1));
        until(|| h.factory.started.load(Ordering::SeqCst));
        let poll_start = Instant::now();
        assert!(session.poll().unwrap().is_none());
        assert!(poll_start.elapsed() < Duration::from_secs(1));
        assert_ne!(
            h.factory.worker_thread.lock().unwrap().unwrap(),
            thread::current().id()
        );
        session
            .send(ToHelper::Cancel { transaction: None })
            .unwrap();
        assert!(matches!(
            event(session.as_mut()),
            FromHelper::Disarmed { transaction: None }
        ));
        assert!(h.factory.script.lock().unwrap().sent.is_empty());
        h.release();
    }
    #[test]
    fn full_protocol_ready_requires_ack_and_armed_and_consent_requires_exact_ack() {
        let h = Harness::new(Mode::Success);
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        let p = ready(session.as_mut());
        let sent = h.factory.script.lock().unwrap().sent.clone();
        assert!(matches!(sent[1].body, ParentMessage::Approve { .. }));
        assert!(matches!(sent[2].body, ParentMessage::ReadyAck { .. }));
        session.send(ToHelper::Quiescent(p.clone())).unwrap();
        assert_eq!(event(session.as_mut()), FromHelper::ConsentPersisted(p));
        assert!(
            session
                .send(ToHelper::Cancel { transaction: None })
                .is_err()
        );
        assert!(launcher.start_verified().is_err());
        assert!(
            !h.factory
                .script
                .lock()
                .unwrap()
                .sent
                .iter()
                .any(|f| matches!(f.body, ParentMessage::Cancel { .. }))
        );
    }
    #[test]
    fn ready_is_not_published_until_armed_arrives() {
        let h = Harness::new(Mode::Success);
        h.factory.script.lock().unwrap().allow_armed = false;
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        let p = proposal(session.as_mut());
        session.send(ToHelper::Approve(p)).unwrap();
        until(|| {
            h.factory
                .script
                .lock()
                .unwrap()
                .sent
                .iter()
                .any(|f| matches!(f.body, ParentMessage::ReadyAck { .. }))
        });
        assert!(session.poll().unwrap().is_none());
        h.factory.script.lock().unwrap().allow_armed = true;
        assert!(matches!(event(session.as_mut()), FromHelper::Ready { .. }));
        let id = h.factory.script.lock().unwrap().proposal.transaction;
        session
            .send(ToHelper::Cancel {
                transaction: Some(id),
            })
            .unwrap();
        assert!(matches!(
            event(session.as_mut()),
            FromHelper::Disarmed { .. }
        ));
    }
    #[test]
    fn proposal_nonce_digest_session_and_sequence_mismatches_never_publish_progress() {
        for mode in [
            Mode::WrongNonce,
            Mode::WrongDigest,
            Mode::WrongSession,
            Mode::WrongSequence,
        ] {
            let h = Harness::new(mode);
            let mut launcher = h.launcher();
            let mut session = h.start(&mut launcher);
            assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
            assert!(session.poll().unwrap().is_none());
            assert!(
                !h.factory
                    .script
                    .lock()
                    .unwrap()
                    .sent
                    .iter()
                    .any(|f| matches!(
                        f.body,
                        ParentMessage::Approve { .. } | ParentMessage::CleanQuit { .. }
                    ))
            );
        }
    }
    #[test]
    fn wrong_parent_instance_and_changed_child_trust_fail_before_desktop_ready() {
        let h = Harness::new(Mode::WrongParent);
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        let p = proposal(session.as_mut());
        session.send(ToHelper::Approve(p)).unwrap();
        assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
        let h = Harness::new(Mode::Success);
        h.factory.script.lock().unwrap().allow_ready = false;
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        let p = proposal(session.as_mut());
        session.send(ToHelper::Approve(p)).unwrap();
        until(|| {
            h.factory
                .script
                .lock()
                .unwrap()
                .sent
                .iter()
                .any(|f| matches!(f.body, ParentMessage::Approve { .. }))
        });
        fs::write(&h.factory.files.trust, b"FAKE-UNSIGNED-RUNNING").unwrap();
        h.factory.script.lock().unwrap().allow_ready = true;
        assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
    }
    #[test]
    fn cancel_before_observing_proposal_suppresses_inflight_and_matches_none_ack() {
        let h = Harness::new(Mode::Success);
        h.factory.script.lock().unwrap().allow_proposal = false;
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        until(|| !h.factory.script.lock().unwrap().sent.is_empty());
        session
            .send(ToHelper::Cancel { transaction: None })
            .unwrap();
        h.factory.script.lock().unwrap().allow_proposal = true;
        assert!(matches!(
            event(session.as_mut()),
            FromHelper::Disarmed { transaction: None }
        ));
        assert!(session.poll().unwrap().is_none());
    }
    #[test]
    fn cancelling_still_validates_inflight_proposal_instead_of_accepting_bad_digest() {
        let h = Harness::new(Mode::WrongDigest);
        h.factory.script.lock().unwrap().allow_proposal = false;
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        until(|| !h.factory.script.lock().unwrap().sent.is_empty());
        session
            .send(ToHelper::Cancel { transaction: None })
            .unwrap();
        h.factory.script.lock().unwrap().allow_proposal = true;
        assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
    }
    #[test]
    fn cancel_during_ready_or_armed_suppresses_inflight_progress_and_never_quits() {
        for at_armed in [false, true] {
            let h = Harness::new(Mode::Success);
            {
                let mut script = h.factory.script.lock().unwrap();
                if at_armed {
                    script.allow_armed = false;
                } else {
                    script.allow_ready = false;
                }
            }
            let mut launcher = h.launcher();
            let mut session = h.start(&mut launcher);
            let p = proposal(session.as_mut());
            session.send(ToHelper::Approve(p.clone())).unwrap();
            until(|| {
                h.factory.script.lock().unwrap().sent.iter().any(|f| {
                    if at_armed {
                        matches!(f.body, ParentMessage::ReadyAck { .. })
                    } else {
                        matches!(f.body, ParentMessage::Approve { .. })
                    }
                })
            });
            session
                .send(ToHelper::Cancel {
                    transaction: Some(p.transaction),
                })
                .unwrap();
            {
                let mut script = h.factory.script.lock().unwrap();
                script.allow_ready = true;
                script.allow_armed = true;
            }
            assert!(
                matches!(event(session.as_mut()),FromHelper::Disarmed {transaction:Some(id)} if id==p.transaction)
            );
            assert!(
                !h.factory
                    .script
                    .lock()
                    .unwrap()
                    .sent
                    .iter()
                    .any(|f| matches!(f.body, ParentMessage::CleanQuit { .. }))
            );
        }
    }
    #[test]
    fn wrong_disarm_is_not_cancellation_success() {
        let h = Harness::new(Mode::WrongDisarm);
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        let p = ready(session.as_mut());
        session
            .send(ToHelper::Cancel {
                transaction: Some(p.transaction),
            })
            .unwrap();
        assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
    }
    #[test]
    fn lost_or_wrong_consent_ack_fences_launcher_and_never_sends_cancel_or_permit() {
        for mode in [Mode::LostConsent, Mode::WrongConsent] {
            let h = Harness::new(mode);
            let mut launcher = h.launcher();
            let mut session = h.start(&mut launcher);
            let p = ready(session.as_mut());
            session.send(ToHelper::Quiescent(p)).unwrap();
            assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
            assert!(
                session
                    .send(ToHelper::Cancel { transaction: None })
                    .is_err()
            );
            assert!(launcher.start_verified().is_err());
            assert!(
                !h.factory
                    .script
                    .lock()
                    .unwrap()
                    .sent
                    .iter()
                    .any(|f| matches!(f.body, ParentMessage::Cancel { .. }))
            );
            assert!(session.poll().unwrap().is_none());
        }
    }
    #[test]
    fn bounded_queue_and_phase_deadline_fail_without_ui_waits_or_real_children() {
        let mut h = Harness::new(Mode::Success);
        h.config.command_capacity = 1;
        *h.factory.gate.0.lock().unwrap() = false;
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        until(|| h.factory.started.load(Ordering::SeqCst));
        session.send(ToHelper::Select(h.selection.clone())).unwrap();
        assert!(session.send(ToHelper::Select(h.selection.clone())).is_err());
        drop(session);
        h.release();
        let mut h = Harness::new(Mode::NoProposal);
        h.config.timeouts.proposal = Duration::from_millis(25);
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
    }
    #[test]
    fn stale_native_approval_and_premature_quiescence_do_not_send_authorization() {
        let h = Harness::new(Mode::Success);
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        let mut p = proposal(session.as_mut());
        p.candidate_tree = "d".repeat(64);
        session.send(ToHelper::Approve(p)).unwrap();
        assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
        let h = Harness::new(Mode::Success);
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        let p = proposal(session.as_mut());
        session.send(ToHelper::Quiescent(p)).unwrap();
        assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
        assert!(launcher.start_verified().is_err());
        assert!(
            !h.factory
                .script
                .lock()
                .unwrap()
                .sent
                .iter()
                .any(|f| matches!(f.body, ParentMessage::CleanQuit { .. }))
        );
    }
    #[test]
    fn completed_old_generation_cannot_clear_or_cancel_successor() {
        let h = Harness::new(Mode::Success);
        let mut launcher = h.launcher();
        let mut old = h.start(&mut launcher);
        let p = ready(old.as_mut());
        old.send(ToHelper::Cancel {
            transaction: Some(p.transaction),
        })
        .unwrap();
        assert!(matches!(event(old.as_mut()), FromHelper::Disarmed { .. }));
        {
            let mut script = h.factory.script.lock().unwrap();
            script.sent.clear();
            script.replies.clear();
            script.incoming = 0;
        }
        let mut next = h.start(&mut launcher);
        drop(old);
        let _ = proposal(next.as_mut());
        assert!(launcher.start_verified().is_err());
        next.send(ToHelper::Cancel { transaction: None }).unwrap();
        assert!(matches!(
            event(next.as_mut()),
            FromHelper::Disarmed { transaction: None }
        ));
    }
    #[test]
    fn exited_child_cannot_be_treated_as_disarm_or_ready() {
        let h = Harness::new(Mode::Exited);
        let mut launcher = h.launcher();
        let mut session = h.start(&mut launcher);
        assert!(matches!(event(session.as_mut()), FromHelper::Failed(_)));
    }
}
