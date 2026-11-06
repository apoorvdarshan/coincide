//! Native update session and normal-quit adapter. No process launch/quit, network,
//! signature bypass, or installation occurs here. A separately verified wrapper
//! owns the helper endpoint; native event handlers own approval and shutdown hooks.
use anyhow::{Context, Result, bail, ensure};
use coincide_core::{
    updater::{Platform, Release, Stage},
    updater_install::{ParentBinding, Proposal},
};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
use uuid::Uuid;

/// Trusted native startup values, never control/API request parameters. The
/// launcher must independently verify its signed child before returning a session.
#[derive(Clone)]
pub struct NativePolicy {
    pub target: PathBuf,
    pub anchor: String,
    pub installed_version: String,
    pub parent: ParentBinding,
    pub handshake_timeout: Duration,
    pub shutdown_timeout: Duration,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub job: Uuid,
    pub release: Release,
}
impl Selection {
    pub fn from_stage(stage: &Stage) -> Result<Self> {
        ensure!(
            stage.release.platform == Platform::Macos,
            "Native updates unavailable on this platform"
        );
        ensure!(
            stage.archive_sha256_verified && !stage.install_authorized,
            "Completed integrity-checked stage required"
        );
        let name = stage
            .job
            .file_name()
            .and_then(|n| n.to_str())
            .context("Invalid stage UUID")?;
        let job = Uuid::parse_str(name)?;
        ensure!(job.to_string() == name, "Noncanonical stage UUID");
        Ok(Self {
            job,
            release: stage.release.clone(),
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToHelper {
    Select(Selection),
    Approve(Proposal),
    Decline(Proposal),
    Cancel {
        transaction: Option<Uuid>,
    },
    /// Emitted only by this adapter after every native shutdown hook completed.
    Quiescent(Proposal),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FromHelper {
    /// Helper verified signatures/metadata/hash before proposing these exact bytes.
    Proposal(Proposal),
    /// ArmedInstall already owns target lock and exact-parent exit observer.
    Ready {
        proposal: Proposal,
        parent: ParentBinding,
    },
    Disarmed {
        transaction: Option<Uuid>,
    },
    /// Helper synced its own nonce-bound consent. Parent may now finish normal exit.
    ConsentPersisted(Proposal),
    Failed(String),
}
/// Private child stdin/stdout only. Implementations must cap frames/queues, enforce
/// deadlines, bind the verified child instance, and never accept network/API peers.
/// Methods MUST be nonblocking on the UI thread; send means queue, not pipe flush.
pub trait HelperSession {
    fn send(&mut self, message: ToHelper) -> Result<()>;
    fn poll(&mut self) -> Result<Option<FromHelper>>;
}
pub trait HelperLauncher {
    fn start_verified(&mut self) -> Result<Box<dyn HelperSession>>;
}
pub struct UnavailableHelper;
impl HelperLauncher for UnavailableHelper {
    fn start_verified(&mut self) -> Result<Box<dyn HelperSession>> {
        bail!("Signed independent update wrapper is unavailable")
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShutdownStep {
    FreezeAdmissions,
    StopDispatch,
    DrainProvidersAndHost,
    DrainTerminalsAndBrowser,
    StopComputerUseAndBackground,
    FlushConversationsAndUsage,
    FlushDraftsAndLayout,
    CloseControlAndStores,
    VerifyQuiescent,
}
const STEPS: [ShutdownStep; 9] = [
    ShutdownStep::FreezeAdmissions,
    ShutdownStep::StopDispatch,
    ShutdownStep::DrainProvidersAndHost,
    ShutdownStep::DrainTerminalsAndBrowser,
    ShutdownStep::StopComputerUseAndBackground,
    ShutdownStep::FlushConversationsAndUsage,
    ShutdownStep::FlushDraftsAndLayout,
    ShutdownStep::CloseControlAndStores,
    ShutdownStep::VerifyQuiescent,
];
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Progress {
    Pending,
    Complete,
}
/// The real native app supplies ALL owners. Each method is polled until actual
/// acknowledgements/persistence complete; requesting shutdown is not completion.
/// On failure the app remains quiescent or explicitly restores admissions itself.
pub trait ShutdownHooks {
    fn poll_step(&mut self, step: ShutdownStep) -> Result<Progress>;
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LifecycleState {
    WaitingForProposal,
    AwaitingNativeApproval(Box<Proposal>),
    WaitingForReady,
    ReadyForNormalQuit,
    ShuttingDown(ShutdownStep),
    WaitingForConsent,
    NormalQuitPermitted,
    Exiting,
    Cancelling,
    Cancelled,
    Blocked(String),
    /// Private transport failed after consent may have reached the helper. Never
    /// automatically retry, rearm, claim disarmed, or permit normal quit here.
    ConsentUncertain(String),
}
/// Opaque one-use native lifecycle result, not serializable/API-supplied proof.
pub struct NormalQuitPermit {
    transaction: Uuid,
}
impl NormalQuitPermit {
    pub fn transaction(&self) -> Uuid {
        self.transaction
    }
}
pub struct Lifecycle {
    policy: NativePolicy,
    selection: Selection,
    session: Box<dyn HelperSession>,
    state: LifecycleState,
    proposal: Option<Proposal>,
    deadline: Instant,
    step: usize,
}
impl Lifecycle {
    pub fn begin(
        policy: NativePolicy,
        stage: &Stage,
        launcher: &mut dyn HelperLauncher,
    ) -> Result<Self> {
        ensure!(
            policy.target.is_absolute()
                && policy
                    .target
                    .file_name()
                    .is_some_and(|n| n == "Coincide Rust.app")
                && !policy
                    .target
                    .components()
                    .any(|c| matches!(c, std::path::Component::ParentDir)),
            "Fixed native preview target required"
        );
        ensure!(
            !policy.anchor.trim().is_empty() && policy.parent.pid > 1,
            "Pinned native anchor and parent instance required"
        );
        ensure!(
            !policy.handshake_timeout.is_zero()
                && policy.handshake_timeout <= Duration::from_secs(900)
                && !policy.shutdown_timeout.is_zero()
                && policy.shutdown_timeout <= Duration::from_secs(600),
            "Invalid lifecycle deadlines"
        );
        let selection = Selection::from_stage(stage)?;
        let mut session = launcher.start_verified()?;
        session.send(ToHelper::Select(selection.clone()))?;
        let deadline = Instant::now() + policy.handshake_timeout;
        Ok(Self {
            policy,
            selection,
            session,
            state: LifecycleState::WaitingForProposal,
            proposal: None,
            deadline,
            step: 0,
        })
    }
    pub fn state(&self) -> &LifecycleState {
        &self.state
    }
    fn proposal_matches(&self, p: &Proposal) -> bool {
        p.target == self.policy.target
            && p.installed_version == self.policy.installed_version
            && p.anchor == self.policy.anchor
            && p.release == self.selection.release
            && !p.transaction.is_nil()
            && [p.installed_tree.as_str(), p.candidate_tree.as_str()]
                .iter()
                .all(|s| {
                    s.len() == 64
                        && s.bytes()
                            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
                })
    }
    fn fail(&mut self, reason: String) {
        let uncertain = matches!(
            self.state,
            LifecycleState::WaitingForConsent
                | LifecycleState::NormalQuitPermitted
                | LifecycleState::Exiting
        );
        if !uncertain {
            let _ = self.session.send(ToHelper::Cancel {
                transaction: self.proposal.as_ref().map(|p| p.transaction),
            });
        }
        self.state = if uncertain {
            LifecycleState::ConsentUncertain(reason)
        } else {
            LifecycleState::Blocked(reason)
        };
    }
    /// Native tick only. Drain boundedly so a noisy child cannot monopolize UI.
    pub fn poll(&mut self) {
        if matches!(
            self.state,
            LifecycleState::Cancelled
                | LifecycleState::Blocked(_)
                | LifecycleState::ConsentUncertain(_)
                | LifecycleState::Exiting
        ) {
            return;
        }
        if !matches!(
            self.state,
            LifecycleState::ReadyForNormalQuit | LifecycleState::NormalQuitPermitted
        ) && Instant::now() >= self.deadline
        {
            self.fail("Update helper/lifecycle deadline expired".into());
            return;
        }
        for _ in 0..8 {
            match self.session.poll() {
                Ok(Some(event)) => {
                    if let Err(error) = self.receive(event) {
                        self.fail(error.to_string());
                        return;
                    }
                }
                Ok(None) => break,
                Err(error) => {
                    self.fail(error.to_string());
                    return;
                }
            }
        }
    }
    fn receive(&mut self, event: FromHelper) -> Result<()> {
        match (&self.state, event) {
            (LifecycleState::WaitingForProposal, FromHelper::Proposal(p)) => {
                ensure!(
                    self.proposal_matches(&p),
                    "Helper proposal differs from native selection"
                );
                self.proposal = Some(p.clone());
                self.state = LifecycleState::AwaitingNativeApproval(Box::new(p));
                self.deadline = Instant::now() + self.policy.handshake_timeout;
            }
            (LifecycleState::WaitingForReady, FromHelper::Ready { proposal, parent }) => {
                ensure!(
                    self.proposal.as_ref() == Some(&proposal) && parent == self.policy.parent,
                    "Helper readiness does not bind this approved proposal/parent instance"
                );
                self.state = LifecycleState::ReadyForNormalQuit;
            }
            (LifecycleState::WaitingForConsent, FromHelper::ConsentPersisted(p)) => {
                ensure!(
                    self.proposal.as_ref() == Some(&p),
                    "Consent acknowledgement differs"
                );
                self.state = LifecycleState::NormalQuitPermitted;
            }
            (LifecycleState::Cancelling, FromHelper::Disarmed { transaction }) => {
                ensure!(
                    transaction == self.proposal.as_ref().map(|p| p.transaction),
                    "Disarm acknowledgement differs"
                );
                self.state = LifecycleState::Cancelled;
            }
            (_, FromHelper::Failed(reason)) => bail!(
                "Update helper failed: {}",
                reason.chars().take(1024).collect::<String>()
            ),
            _ => bail!("Unexpected update helper protocol order"),
        }
        Ok(())
    }
    /// Call ONLY from a native approval surface displaying state()'s immutable
    /// proposal. No HTTP/CLI dispatch may expose this action. The helper still
    /// owns the opaque authorization and independently verified signatures.
    pub fn native_approve(&mut self, displayed: &Proposal) -> Result<()> {
        let LifecycleState::AwaitingNativeApproval(proposal) = &self.state else {
            bail!("No native proposal awaiting approval")
        };
        ensure!(
            proposal.as_ref() == displayed,
            "Displayed native proposal changed"
        );
        self.session
            .send(ToHelper::Approve(proposal.as_ref().clone()))?;
        self.state = LifecycleState::WaitingForReady;
        self.deadline = Instant::now() + self.policy.handshake_timeout;
        Ok(())
    }
    pub fn cancel(&mut self) -> Result<()> {
        ensure!(
            !matches!(
                self.state,
                LifecycleState::WaitingForConsent
                    | LifecycleState::NormalQuitPermitted
                    | LifecycleState::Exiting
                    | LifecycleState::ConsentUncertain(_)
            ),
            "Consent boundary crossed; cannot claim cancellation"
        );
        if let LifecycleState::AwaitingNativeApproval(proposal) = &self.state {
            self.session
                .send(ToHelper::Decline(proposal.as_ref().clone()))?;
        } else {
            self.session.send(ToHelper::Cancel {
                transaction: self.proposal.as_ref().map(|p| p.transaction),
            })?;
        }
        self.state = LifecycleState::Cancelling;
        self.deadline = Instant::now() + self.policy.handshake_timeout;
        Ok(())
    }
    /// Call from an actual user-initiated native Quit event. This does not quit.
    pub fn begin_normal_quit(&mut self) -> Result<()> {
        ensure!(
            self.state == LifecycleState::ReadyForNormalQuit,
            "Verified helper is not armed"
        );
        self.step = 0;
        self.state = LifecycleState::ShuttingDown(STEPS[0]);
        self.deadline = Instant::now() + self.policy.shutdown_timeout;
        Ok(())
    }
    /// One nonblocking shutdown step per native tick; Pending must be revisited.
    pub fn advance_shutdown(&mut self, hooks: &mut dyn ShutdownHooks) {
        let LifecycleState::ShuttingDown(step) = self.state else {
            return;
        };
        if Instant::now() >= self.deadline {
            self.fail("Native shutdown timed out; consent withheld".into());
            return;
        }
        match hooks.poll_step(step) {
            Ok(Progress::Pending) => {}
            Ok(Progress::Complete) => {
                self.step += 1;
                if self.step < STEPS.len() {
                    self.state = LifecycleState::ShuttingDown(STEPS[self.step]);
                } else {
                    // Set uncertain-capable state BEFORE queuing: a transport error
                    // can occur after bytes reached the helper but before receipt.
                    self.state = LifecycleState::WaitingForConsent;
                    self.deadline = Instant::now() + self.policy.handshake_timeout;
                    let proposal = self.proposal.as_ref().expect("armed proposal").clone();
                    if let Err(error) = self.session.send(ToHelper::Quiescent(proposal)) {
                        self.fail(error.to_string());
                    }
                }
            }
            Err(error) => self.fail(format!("Native shutdown {step:?} failed: {error}")),
        }
    }
    pub fn take_normal_quit_permission(&mut self) -> Option<NormalQuitPermit> {
        if self.state != LifecycleState::NormalQuitPermitted {
            return None;
        }
        self.state = LifecycleState::Exiting;
        Some(NormalQuitPermit {
            transaction: self.proposal.as_ref()?.transaction,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::updater::{Architecture, SignatureStatus};
    use std::{cell::RefCell, collections::VecDeque, rc::Rc};

    #[derive(Default)]
    struct Wire {
        sent: Vec<ToHelper>,
        incoming: VecDeque<FromHelper>,
        disconnected: bool,
        fail_send: bool,
    }
    struct FakeSession(Rc<RefCell<Wire>>);
    impl HelperSession for FakeSession {
        fn send(&mut self, message: ToHelper) -> Result<()> {
            let mut wire = self.0.borrow_mut();
            wire.sent.push(message);
            ensure!(!wire.fail_send, "injected queue failure");
            Ok(())
        }
        fn poll(&mut self) -> Result<Option<FromHelper>> {
            let mut wire = self.0.borrow_mut();
            ensure!(!wire.disconnected, "injected broken pipe");
            Ok(wire.incoming.pop_front())
        }
    }
    struct FakeLauncher(Rc<RefCell<Wire>>);
    impl HelperLauncher for FakeLauncher {
        fn start_verified(&mut self) -> Result<Box<dyn HelperSession>> {
            Ok(Box::new(FakeSession(self.0.clone())))
        }
    }
    struct Fixture {
        flow: Lifecycle,
        wire: Rc<RefCell<Wire>>,
        proposal: Proposal,
    }
    fn stage() -> Stage {
        Stage {
            job: std::env::temp_dir().join(Uuid::new_v4().to_string()),
            release: Release {
                version: "0.2.0".into(),
                platform: Platform::Macos,
                architecture: Architecture::Arm64,
                url: "https://fixture.invalid/rust-preview/0.2.0/Coincide-Rust-macos-arm64.zip"
                    .into(),
                size: 42,
                sha256: "a".repeat(64),
            },
            archive_sha256_verified: true,
            signature: SignatureStatus::Pending {
                reason: "fixture awaits independent helper".into(),
            },
            install_authorized: false,
        }
    }
    fn fixture() -> Fixture {
        let stage = stage();
        let policy = NativePolicy {
            target: std::env::temp_dir().join("fixture-target/Coincide Rust.app"),
            anchor: "FIXTURE001".into(),
            installed_version: "0.1.0".into(),
            parent: ParentBinding {
                pid: 42,
                start_seconds: 100,
                start_micros: 4,
            },
            handshake_timeout: Duration::from_secs(10),
            shutdown_timeout: Duration::from_secs(10),
        };
        let proposal = Proposal {
            transaction: Uuid::new_v4(),
            target: policy.target.clone(),
            installed_version: "0.1.0".into(),
            release: stage.release.clone(),
            anchor: policy.anchor.clone(),
            installed_tree: "b".repeat(64),
            candidate_tree: "c".repeat(64),
        };
        let wire = Rc::new(RefCell::new(Wire::default()));
        let flow = Lifecycle::begin(policy, &stage, &mut FakeLauncher(wire.clone())).unwrap();
        Fixture {
            flow,
            wire,
            proposal,
        }
    }
    fn event(f: &mut Fixture, event: FromHelper) {
        f.wire.borrow_mut().incoming.push_back(event);
        f.flow.poll();
    }
    fn approve(f: &mut Fixture) {
        let proposal = f.proposal.clone();
        event(f, FromHelper::Proposal(proposal));
        f.flow.native_approve(&f.proposal).unwrap();
    }
    fn ready(f: &mut Fixture) {
        approve(f);
        let proposal = f.proposal.clone();
        let parent = f.flow.policy.parent.clone();
        event(f, FromHelper::Ready { proposal, parent });
        assert_eq!(f.flow.state(), &LifecycleState::ReadyForNormalQuit);
    }
    struct Hooks {
        seen: Vec<ShutdownStep>,
        failure: Option<ShutdownStep>,
        pending: bool,
    }
    impl ShutdownHooks for Hooks {
        fn poll_step(&mut self, step: ShutdownStep) -> Result<Progress> {
            self.seen.push(step);
            ensure!(
                self.failure != Some(step),
                "injected native persistence/drain failure"
            );
            Ok(if self.pending {
                Progress::Pending
            } else {
                Progress::Complete
            })
        }
    }
    fn hooks() -> Hooks {
        Hooks {
            seen: vec![],
            failure: None,
            pending: false,
        }
    }
    fn flush(f: &mut Fixture, hooks: &mut dyn ShutdownHooks) {
        f.flow.begin_normal_quit().unwrap();
        for _ in 0..STEPS.len() {
            f.flow.advance_shutdown(hooks);
        }
    }
    #[test]
    fn proposal_is_selection_and_anchor_bound() {
        for field in 0..5 {
            let mut f = fixture();
            let mut p = f.proposal.clone();
            match field {
                0 => p.target = p.target.with_file_name("Coincide.app"),
                1 => p.release.sha256 = "f".repeat(64),
                2 => p.anchor = "OTHER".into(),
                3 => p.candidate_tree = "garbage".into(),
                _ => p.release.version = "0.3.0".into(),
            }
            event(&mut f, FromHelper::Proposal(p));
            assert!(matches!(f.flow.state(), LifecycleState::Blocked(_)));
            assert!(
                !f.wire
                    .borrow()
                    .sent
                    .iter()
                    .any(|m| matches!(m, ToHelper::Approve(_)))
            );
        }
    }
    #[test]
    fn ready_requires_approval_and_exact_parent_instance() {
        let mut f = fixture();
        let p = f.proposal.clone();
        let parent = f.flow.policy.parent.clone();
        event(
            &mut f,
            FromHelper::Ready {
                proposal: p,
                parent,
            },
        );
        assert!(matches!(f.flow.state(), LifecycleState::Blocked(_)));
        let mut f = fixture();
        approve(&mut f);
        let mut parent = f.flow.policy.parent.clone();
        parent.start_micros += 1;
        let proposal = f.proposal.clone();
        event(&mut f, FromHelper::Ready { proposal, parent });
        assert!(matches!(f.flow.state(), LifecycleState::Blocked(_)));
    }
    #[test]
    fn approval_binds_complete_proposal_and_ready_does_not_quit() {
        let mut f = fixture();
        ready(&mut f);
        assert!(
            f.wire
                .borrow()
                .sent
                .contains(&ToHelper::Approve(f.proposal.clone()))
        );
        assert!(f.flow.take_normal_quit_permission().is_none());
        assert!(
            !f.wire
                .borrow()
                .sent
                .iter()
                .any(|m| matches!(m, ToHelper::Quiescent(_)))
        );
    }
    #[test]
    fn ordered_flush_and_consent_ack_required_for_one_use_quit_permit() {
        let mut f = fixture();
        ready(&mut f);
        let mut hooks = hooks();
        flush(&mut f, &mut hooks);
        assert_eq!(hooks.seen, STEPS);
        assert_eq!(f.flow.state(), &LifecycleState::WaitingForConsent);
        assert!(f.flow.take_normal_quit_permission().is_none());
        let p = f.proposal.clone();
        event(&mut f, FromHelper::ConsentPersisted(p));
        assert_eq!(
            f.flow.take_normal_quit_permission().unwrap().transaction(),
            f.proposal.transaction
        );
        assert!(f.flow.take_normal_quit_permission().is_none());
        assert!(f.flow.cancel().is_err());
    }
    #[test]
    fn failure_at_every_shutdown_owner_withholds_consent() {
        for failure in STEPS {
            let mut f = fixture();
            ready(&mut f);
            let mut hooks = hooks();
            hooks.failure = Some(failure);
            flush(&mut f, &mut hooks);
            assert!(matches!(f.flow.state(), LifecycleState::Blocked(_)));
            assert!(
                !f.wire
                    .borrow()
                    .sent
                    .iter()
                    .any(|m| matches!(m, ToHelper::Quiescent(_)))
            );
            assert!(f.flow.take_normal_quit_permission().is_none());
        }
    }
    #[test]
    fn pending_hook_never_advances_until_acknowledged() {
        let mut f = fixture();
        ready(&mut f);
        f.flow.begin_normal_quit().unwrap();
        let mut hooks = hooks();
        hooks.pending = true;
        for _ in 0..20 {
            f.flow.advance_shutdown(&mut hooks);
        }
        assert_eq!(
            f.flow.state(),
            &LifecycleState::ShuttingDown(ShutdownStep::FreezeAdmissions)
        );
        hooks.pending = false;
        f.flow.advance_shutdown(&mut hooks);
        assert_eq!(
            f.flow.state(),
            &LifecycleState::ShuttingDown(ShutdownStep::StopDispatch)
        );
    }
    #[test]
    fn disconnect_after_sending_quiescence_is_uncertain_never_retried() {
        let mut f = fixture();
        ready(&mut f);
        flush(&mut f, &mut hooks());
        f.wire.borrow_mut().disconnected = true;
        f.flow.poll();
        assert!(matches!(
            f.flow.state(),
            LifecycleState::ConsentUncertain(_)
        ));
        assert!(f.flow.cancel().is_err());
        assert!(f.flow.take_normal_quit_permission().is_none());
        let count = f.wire.borrow().sent.len();
        f.flow.poll();
        assert_eq!(count, f.wire.borrow().sent.len());
    }
    #[test]
    fn ambiguous_send_after_last_flush_is_also_uncertain() {
        let mut f = fixture();
        ready(&mut f);
        f.flow.begin_normal_quit().unwrap();
        let mut hooks = hooks();
        for _ in 0..STEPS.len() - 1 {
            f.flow.advance_shutdown(&mut hooks);
        }
        f.wire.borrow_mut().fail_send = true;
        f.flow.advance_shutdown(&mut hooks);
        assert!(matches!(
            f.flow.state(),
            LifecycleState::ConsentUncertain(_)
        ));
    }
    #[test]
    fn cancellation_requires_exact_ack_and_does_not_allow_quit() {
        let mut f = fixture();
        ready(&mut f);
        f.flow.cancel().unwrap();
        assert_eq!(f.flow.state(), &LifecycleState::Cancelling);
        let id = f.proposal.transaction;
        event(
            &mut f,
            FromHelper::Disarmed {
                transaction: Some(id),
            },
        );
        assert_eq!(f.flow.state(), &LifecycleState::Cancelled);
        assert!(f.flow.take_normal_quit_permission().is_none());
    }
    #[test]
    fn wrong_consent_or_disarm_is_not_success() {
        let mut f = fixture();
        ready(&mut f);
        flush(&mut f, &mut hooks());
        let mut p = f.proposal.clone();
        p.transaction = Uuid::new_v4();
        event(&mut f, FromHelper::ConsentPersisted(p));
        assert!(matches!(
            f.flow.state(),
            LifecycleState::ConsentUncertain(_)
        ));
        let mut f = fixture();
        ready(&mut f);
        f.flow.cancel().unwrap();
        event(
            &mut f,
            FromHelper::Disarmed {
                transaction: Some(Uuid::new_v4()),
            },
        );
        assert!(matches!(f.flow.state(), LifecycleState::Blocked(_)));
    }
    #[test]
    fn deadlines_fail_closed_without_sleep() {
        let mut f = fixture();
        f.flow.deadline = Instant::now();
        f.flow.poll();
        assert!(matches!(f.flow.state(), LifecycleState::Blocked(_)));
        let mut f = fixture();
        ready(&mut f);
        f.flow.begin_normal_quit().unwrap();
        f.flow.deadline = Instant::now();
        f.flow.advance_shutdown(&mut hooks());
        assert!(
            !f.wire
                .borrow()
                .sent
                .iter()
                .any(|m| matches!(m, ToHelper::Quiescent(_)))
        );
    }
    #[test]
    fn unavailable_wrapper_or_nonpreview_platform_is_not_ready() {
        let f = fixture();
        assert!(Lifecycle::begin(f.flow.policy.clone(), &stage(), &mut UnavailableHelper).is_err());
        let mut s = stage();
        s.release.platform = Platform::Windows;
        assert!(Selection::from_stage(&s).is_err());
        s = stage();
        s.archive_sha256_verified = false;
        assert!(Selection::from_stage(&s).is_err());
    }
    #[test]
    fn real_fixture_flush_finishes_before_quiescent_message() {
        use std::{
            fs::{self, File, OpenOptions},
            io::Write,
        };
        struct FlushFile {
            file: Option<File>,
            path: PathBuf,
            synced: bool,
        }
        impl Drop for FlushFile {
            fn drop(&mut self) {
                self.file.take();
                let _ = fs::remove_file(&self.path);
            }
        }
        impl ShutdownHooks for FlushFile {
            fn poll_step(&mut self, step: ShutdownStep) -> Result<Progress> {
                if step == ShutdownStep::FlushConversationsAndUsage {
                    let file = self
                        .file
                        .as_mut()
                        .context("fixture store closed too soon")?;
                    file.write_all(b"fixture transcript and usage\n")?;
                    file.sync_all()?;
                }
                if step == ShutdownStep::FlushDraftsAndLayout {
                    let file = self
                        .file
                        .as_mut()
                        .context("fixture store closed too soon")?;
                    file.write_all(b"fixture draft and layout\n")?;
                    file.sync_all()?;
                    self.synced = true;
                }
                if step == ShutdownStep::CloseControlAndStores {
                    self.file.take();
                }
                if step == ShutdownStep::VerifyQuiescent {
                    ensure!(
                        self.synced && self.file.is_none(),
                        "fixture did not flush and close"
                    );
                    ensure!(
                        fs::read(&self.path)?
                            == b"fixture transcript and usage\nfixture draft and layout\n",
                        "fixture bytes missing"
                    );
                }
                Ok(Progress::Complete)
            }
        }
        let path =
            std::env::temp_dir().join(format!("coincide-update-flush-{}.fixture", Uuid::new_v4()));
        let file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .unwrap();
        let mut hooks = FlushFile {
            file: Some(file),
            path,
            synced: false,
        };
        let mut f = fixture();
        ready(&mut f);
        flush(&mut f, &mut hooks);
        assert_eq!(f.flow.state(), &LifecycleState::WaitingForConsent);
        assert!(hooks.synced && hooks.file.is_none());
        assert!(
            f.wire
                .borrow()
                .sent
                .contains(&ToHelper::Quiescent(f.proposal.clone()))
        );
    }
    #[test]
    fn stale_native_button_cannot_approve_a_different_proposal() {
        let mut f = fixture();
        let proposal = f.proposal.clone();
        event(&mut f, FromHelper::Proposal(proposal));
        let mut displayed = f.proposal.clone();
        displayed.candidate_tree = "d".repeat(64);
        assert!(f.flow.native_approve(&displayed).is_err());
        assert!(
            !f.wire
                .borrow()
                .sent
                .iter()
                .any(|m| matches!(m, ToHelper::Approve(_)))
        );
    }
}
