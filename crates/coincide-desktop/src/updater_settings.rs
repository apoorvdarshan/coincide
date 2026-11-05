//! Explicit native updater controls. Register from the desktop; construction and
//! rendering never check a feed. The existing native tick drives `tick`, and the
//! actual Quit handler drives lifecycle hooks/consumes its one-use quit permit.
use super::updater_lifecycle::{
    HelperLauncher, Lifecycle, LifecycleState, NativePolicy, NormalQuitPermit, ShutdownHooks,
};
use anyhow::{Result, bail, ensure};
use coincide_core::updater::{Operation, SignatureStatus, State, Updater};
use gpui_kit::{
    component::{Disableable, button::*},
    *,
};

#[derive(Default)]
pub struct UpdaterSettings {
    updater: Updater,
    operation: Option<Operation>,
    lifecycle: Option<Lifecycle>,
    error: Option<String>,
}
impl UpdaterSettings {
    pub fn new(updater: Updater) -> Self {
        Self {
            updater,
            operation: None,
            lifecycle: None,
            error: None,
        }
    }
    pub fn state(&self) -> State {
        self.updater.state()
    }
    pub fn lifecycle(&self) -> Option<&LifecycleState> {
        self.lifecycle.as_ref().map(Lifecycle::state)
    }
    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    fn no_install_session(&self) -> Result<()> {
        ensure!(
            self.lifecycle
                .as_ref()
                .is_none_or(|l| matches!(l.state(), LifecycleState::Cancelled)),
            "Cancel and confirm disarm before changing the selected update"
        );
        Ok(())
    }
    pub fn check(&mut self) -> Result<()> {
        self.no_install_session()?;
        ensure!(self.operation.is_none(), "An update operation is running");
        self.operation = Some(self.updater.check()?);
        self.error = None;
        Ok(())
    }
    pub fn download(&mut self) -> Result<()> {
        self.no_install_session()?;
        ensure!(self.operation.is_none(), "An update operation is running");
        self.operation = Some(self.updater.download_available()?);
        self.error = None;
        Ok(())
    }
    pub fn prepare_install(
        &mut self,
        policy: NativePolicy,
        launcher: &mut dyn HelperLauncher,
    ) -> Result<()> {
        self.no_install_session()?;
        ensure!(self.operation.is_none(), "An update operation is running");
        let State::Staged(stage) = self.updater.state() else {
            bail!("Download and stage an update first")
        };
        self.lifecycle = Some(Lifecycle::begin(policy, &stage, launcher)?);
        self.error = None;
        Ok(())
    }
    pub fn native_approve(
        &mut self,
        displayed: &coincide_core::updater_install::Proposal,
    ) -> Result<()> {
        self.lifecycle
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("No native proposal"))?
            .native_approve(displayed)
    }
    pub fn cancel(&mut self) -> Result<()> {
        if let Some(operation) = &self.operation {
            ensure!(
                operation.cancel(),
                "Operation completed; refresh status before cancelling"
            );
            self.operation = None;
            return Ok(());
        }
        self.lifecycle
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("No update operation/session"))?
            .cancel()
    }
    pub fn tick(&mut self) {
        if let Some(state) = self.operation.as_ref().and_then(Operation::try_result) {
            self.operation = None;
            if let State::Failed(reason) = state {
                self.error = Some(reason);
            }
        }
        if let Some(lifecycle) = &mut self.lifecycle {
            lifecycle.poll();
        }
    }
    /// Native user Quit only; not an API or settings-window-close callback.
    pub fn begin_normal_quit(&mut self) -> Result<()> {
        self.lifecycle
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("No armed update"))?
            .begin_normal_quit()
    }
    pub fn advance_shutdown(&mut self, hooks: &mut dyn ShutdownHooks) {
        if let Some(lifecycle) = &mut self.lifecycle {
            lifecycle.advance_shutdown(hooks);
        }
    }
    pub fn take_normal_quit_permission(&mut self) -> Option<NormalQuitPermit> {
        self.lifecycle.as_mut()?.take_normal_quit_permission()
    }
    pub fn status_text(&self) -> String {
        if let Some(lifecycle) = &self.lifecycle {
            return match lifecycle.state() {
                LifecycleState::WaitingForProposal => "Verifying update with independent helper…".into(),
                LifecycleState::AwaitingNativeApproval(_) => "Review the verified update below.".into(),
                LifecycleState::WaitingForReady => "Waiting for helper to observe this app instance…".into(),
                LifecycleState::ReadyForNormalQuit => "Update armed for your next normal Quit. The app will not quit or reopen automatically.".into(),
                LifecycleState::ShuttingDown(step) => format!("Saving and stopping work: {step:?}…"),
                LifecycleState::WaitingForConsent => "Waiting for helper to persist clean-quit consent…".into(),
                LifecycleState::NormalQuitPermitted | LifecycleState::Exiting => "Saved work confirmed; normal quit may complete.".into(),
                LifecycleState::Cancelling => "Waiting for helper to confirm cancellation…".into(),
                LifecycleState::Cancelled => "Update helper cancelled. Staged download retained.".into(),
                LifecycleState::Blocked(reason) => format!("Update blocked: {reason}"),
                LifecycleState::ConsentUncertain(reason) => format!("Quit consent could not be confirmed: {reason}. Do not retry this update automatically."),
            };
        }
        match self.updater.state() {
            State::Disabled => "Updates are off. A Rust preview feed and trust anchor must be configured.".into(),
            State::Idle => "Check for a Rust preview update when you choose.".into(),
            State::Checking => "Checking for a Rust preview update…".into(),
            State::Current => "This Rust preview is current for the configured channel.".into(),
            State::Unpublished => "No Rust preview update is published on the configured channel.".into(),
            State::Available(release) => format!("Rust preview {} is available ({} bytes).", release.version, release.size),
            State::Downloading { received, total } => format!("Downloading Rust preview: {received} / {total} bytes…"),
            State::Verifying => "Checking downloaded archive and staged bundle…".into(),
            State::Staged(stage) => match stage.signature {
                SignatureStatus::Pending { reason } => format!("Archive SHA-256 verified. Signature verification pending: {reason}. Installation is not authorized."),
                SignatureStatus::Verified => "Staged signature and archive verified. Native approval and independent helper readiness are still required.".into(),
            },
            State::Cancelled => "Update operation cancelled.".into(),
            State::TimedOut => "Update operation timed out.".into(),
            State::Failed(reason) => format!("Update failed: {reason}"),
        }
    }
    fn record(&mut self, result: Result<()>) {
        if let Err(error) = result {
            self.error = Some(error.to_string());
        }
    }
}

/// Native GPUI surface: no timer, startup networking or Quit action. Parent embeds
/// this entity in Settings and calls tick from its existing native event loop.
/// Native lifecycle hooks belong to the real root app, not this view/window.
pub struct UpdaterSettingsView {
    pub model: UpdaterSettings,
    policy: Option<NativePolicy>,
    launcher: Box<dyn HelperLauncher>,
}
impl UpdaterSettingsView {
    pub fn new(
        model: UpdaterSettings,
        policy: Option<NativePolicy>,
        launcher: Box<dyn HelperLauncher>,
    ) -> Self {
        Self {
            model,
            policy,
            launcher,
        }
    }
    pub fn tick(&mut self, cx: &mut Context<Self>) {
        self.model.tick();
        cx.notify();
    }
}
impl Render for UpdaterSettingsView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let state = self.model.state();
        let session_clear = self.model.no_install_session().is_ok();
        let busy = self.model.operation.is_some();
        let can_check = !matches!(state, State::Disabled) && session_clear && !busy;
        let can_download = matches!(state, State::Available(_)) && session_clear && !busy;
        let can_install =
            matches!(state, State::Staged(_)) && session_clear && !busy && self.policy.is_some();
        let can_cancel = busy
            || self.model.lifecycle().is_some_and(|s| {
                !matches!(
                    s,
                    LifecycleState::Cancelled
                        | LifecycleState::Cancelling
                        | LifecycleState::WaitingForConsent
                        | LifecycleState::NormalQuitPermitted
                        | LifecycleState::Exiting
                        | LifecycleState::ConsentUncertain(_)
                )
            });
        let mut content = div()
            .flex()
            .flex_col()
            .gap_3()
            .child("Rust preview updates")
            .child(self.model.status_text())
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("rust-update-check")
                            .label("Check for Update")
                            .disabled(!can_check)
                            .on_click(cx.listener(|this, _, _, cx| {
                                let result = this.model.check();
                                this.model.record(result);
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("rust-update-download")
                            .label("Download Update")
                            .disabled(!can_download)
                            .on_click(cx.listener(|this, _, _, cx| {
                                let result = this.model.download();
                                this.model.record(result);
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("rust-update-prepare")
                            .label("Review Install on Quit")
                            .disabled(!can_install)
                            .on_click(cx.listener(|this, _, _, cx| {
                                if let Some(policy) = this.policy.clone() {
                                    let result =
                                        this.model.prepare_install(policy, this.launcher.as_mut());
                                    this.model.record(result);
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("rust-update-cancel")
                            .label("Cancel Update")
                            .disabled(!can_cancel)
                            .on_click(cx.listener(|this, _, _, cx| {
                                let result = this.model.cancel();
                                this.model.record(result);
                                cx.notify();
                            })),
                    ),
            );
        if let Some(LifecycleState::AwaitingNativeApproval(proposal)) = self.model.lifecycle() {
            let displayed = proposal.as_ref().clone();
            // The immutable proposal is the one the approval callback binds. Hash
            // and anchor are shown here because they determine this decision.
            content = content
                .child(format!(
                    "Install Rust preview {} → {}",
                    proposal.installed_version, proposal.release.version
                ))
                .child(format!("Target: {}", proposal.target.display()))
                .child(format!("Signing anchor: {}", proposal.anchor))
                .child(format!("Archive SHA-256: {}", proposal.release.sha256))
                .child(
                    Button::new("rust-update-native-approve")
                        .label("Approve for Next Normal Quit")
                        .on_click(cx.listener(move |this, _, _, cx| {
                            let result = this.model.native_approve(&displayed);
                            this.model.record(result);
                            cx.notify();
                        })),
                );
        }
        if let Some(error) = self.model.error() {
            content = content.child(error.to_owned());
        }
        content
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_is_off_and_never_starts_operations() {
        let mut model = UpdaterSettings::default();
        for _ in 0..20 {
            model.tick();
        }
        assert!(matches!(model.state(), State::Disabled));
        assert!(model.operation.is_none());
        assert!(model.check().is_err());
        assert!(model.download().is_err());
        assert!(model.begin_normal_quit().is_err());
        assert!(model.take_normal_quit_permission().is_none());
        assert!(model.status_text().contains("Updates are off"));
    }
    #[test]
    fn no_stage_cannot_show_approval_or_prepare_helper() {
        let mut model = UpdaterSettings::default();
        assert!(model.cancel().is_err());
        model.advance_shutdown(&mut NeverFlush);
        assert!(model.lifecycle().is_none());
    }
    struct NeverFlush;
    impl ShutdownHooks for NeverFlush {
        fn poll_step(
            &mut self,
            _: super::super::updater_lifecycle::ShutdownStep,
        ) -> Result<super::super::updater_lifecycle::Progress> {
            panic!("No lifecycle must call native hooks")
        }
    }
}
