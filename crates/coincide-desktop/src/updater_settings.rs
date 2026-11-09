//! Settings › About › App Updates, as Swift's AppUpdateSettingsView: the daily
//! check preference, status and the Check, Download, Install on Quit and Cancel
//! Installation actions. Construction and rendering never check a feed; checks
//! run only when asked or when the daily check is due, and only with a configured
//! update channel. The actual Quit handler drives lifecycle hooks/consumes its
//! one-use quit permit.
use super::updater_lifecycle::{
    HelperLauncher, Lifecycle, LifecycleState, NativePolicy, NormalQuitPermit, ShutdownHooks,
};
use anyhow::{Result, bail, ensure};
use coincide_core::{
    api::SharedEngine,
    store::swift_timestamp,
    updater::{Operation, SignatureStatus, State, Updater},
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    Context, FontWeight, InteractiveElement, IntoElement, ParentElement, Render, Styled, Task,
    Window,
    component::{ActiveTheme, Disableable, button::Button, switch::Switch},
    div,
};
use serde_json::json;
use std::time::{Duration, Instant};

/// Swift checks once a day, looking every hour whether a day has passed.
const DAILY: f64 = 24. * 3600.;
const AUTOMATIC_LOOK: Duration = Duration::from_secs(3600);

/// Whether the daily check is due: on, and a day since the last check.
fn automatic_check_due(enabled: bool, last: Option<f64>, now: f64) -> bool {
    enabled && last.is_none_or(|last| !(now - last < DAILY))
}

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
    /// Whether nothing stands in the way of an automatic check: no update is
    /// being checked, downloaded, ready or armed (Swift's `automaticCheck` guard).
    fn can_check_automatically(&self) -> bool {
        matches!(
            self.updater.state(),
            State::Idle
                | State::Current
                | State::Unpublished
                | State::Available(_)
                | State::Cancelled
                | State::TimedOut
                | State::Failed(_)
        ) && self.operation.is_none()
            && self.lifecycle.is_none()
    }
    /// Swift's `automaticCheck`: checks when the daily check is due and nothing
    /// stands in its way.
    pub fn automatic_check(&mut self, enabled: bool, last: Option<f64>, now: f64) -> bool {
        automatic_check_due(enabled, last, now)
            && self.can_check_automatically()
            && self.check().is_ok()
    }
    fn busy(&self) -> bool {
        self.operation.is_some()
            || matches!(
                self.lifecycle(),
                Some(LifecycleState::WaitingForProposal | LifecycleState::WaitingForReady)
            )
    }
    /// The installation is armed for the next normal Quit, or on its way there.
    fn armed(&self) -> bool {
        self.lifecycle().is_some_and(|state| {
            !matches!(
                state,
                LifecycleState::Cancelled | LifecycleState::Blocked(_)
            )
        })
    }
    fn staged_job(&self) -> Option<std::path::PathBuf> {
        match self.updater.state() {
            State::Staged(stage) => Some(stage.job),
            _ => None,
        }
    }
    pub fn status_text(&self) -> String {
        if let Some(lifecycle) = &self.lifecycle {
            return match lifecycle.state() {
                LifecycleState::WaitingForProposal | LifecycleState::WaitingForReady => {
                    "Preparing installation…".into()
                }
                LifecycleState::AwaitingNativeApproval(_) => {
                    "Review the verified update below.".into()
                }
                LifecycleState::ReadyForNormalQuit => "The update will install after you quit. Wait for confirmation, then reopen Coincide yourself.".into(),
                LifecycleState::ShuttingDown(_) | LifecycleState::WaitingForConsent => {
                    "Saving and stopping work before the update installs…".into()
                }
                LifecycleState::NormalQuitPermitted | LifecycleState::Exiting => {
                    "Your work is saved. The update installs as Coincide quits.".into()
                }
                LifecycleState::Cancelling => "Cancelling the installation…".into(),
                LifecycleState::Cancelled => {
                    "Installation cancelled. The downloaded update is kept.".into()
                }
                LifecycleState::Blocked(reason) => {
                    format!("The update can't be installed: {reason}")
                }
                LifecycleState::ConsentUncertain(reason) => format!(
                    "Coincide couldn't confirm it was safe to install ({reason}). The update won't be retried automatically."
                ),
            };
        }
        match self.updater.state() {
            State::Disabled => {
                "This build has no update channel, so it can't check for updates.".into()
            }
            State::Idle => "Check for a newer version of Coincide.".into(),
            State::Checking => "Checking for updates…".into(),
            State::Current => "Coincide is up to date.".into(),
            State::Unpublished => "No published release is available yet.".into(),
            State::Available(release) => format!("Version {} is available.", release.version),
            State::Downloading { .. } | State::Verifying => {
                "Downloading and verifying the update…".into()
            }
            State::Staged(stage) => match stage.signature {
                SignatureStatus::Verified => "The update is verified and ready to install.".into(),
                SignatureStatus::Pending { reason } => format!(
                    "The update is downloaded, but its signature isn't verified yet ({reason}), so it can't be installed."
                ),
            },
            State::Cancelled => "Update cancelled.".into(),
            State::TimedOut => "The update request timed out. Try again later.".into(),
            State::Failed(reason) => reason,
        }
    }
    fn record(&mut self, result: Result<()>) {
        if let Err(error) = result {
            self.error = Some(error.to_string());
        }
    }
}

/// The App Updates section. Its own poll completes operations and, hourly,
/// runs the daily check; there is no startup check and no Quit action here.
/// Native lifecycle hooks belong to the real root app, not this view/window.
pub struct UpdaterSettingsView {
    pub model: UpdaterSettings,
    policy: Option<NativePolicy>,
    launcher: Box<dyn HelperLauncher>,
    engine: SharedEngine,
    /// `checksForAppUpdates` (Swift's default is on) and `lastAppUpdateCheck`
    /// (seconds since 2001, as Swift saves dates), once read from settings.
    preferences: Option<(bool, Option<f64>)>,
    checking: bool,
    looked: Option<Instant>,
    _poll: Task<()>,
}
impl UpdaterSettingsView {
    pub fn new(
        model: UpdaterSettings,
        policy: Option<NativePolicy>,
        launcher: Box<dyn HelperLauncher>,
        engine: SharedEngine,
        cx: &mut Context<Self>,
    ) -> Self {
        let poll = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(250))
                    .await;
                if this.update(cx, |this, cx| this.tick(cx)).is_err() {
                    break;
                }
            }
        });
        Self {
            model,
            policy,
            launcher,
            engine,
            preferences: None,
            checking: false,
            looked: None,
            _poll: poll,
        }
    }
    /// Reads the preferences until it succeeds; a busy Engine is retried next poll.
    fn preferences(&mut self) -> Option<(bool, Option<f64>)> {
        if self.preferences.is_none()
            && let Ok(settings) = crate::call(&self.engine, "settings.read", json!({}))
        {
            self.preferences = Some((
                settings["checksForAppUpdates"].as_bool().unwrap_or(true),
                settings["lastAppUpdateCheck"].as_f64(),
            ));
        }
        self.preferences
    }
    fn save_preference(&mut self, key: &str, value: serde_json::Value) -> Result<()> {
        let mut patch = json!({});
        patch[key] = value;
        // Never waits for a background worker holding the Engine.
        crate::call(&self.engine, "settings.patch", json!({"patch":patch}))?;
        Ok(())
    }
    fn set_daily(&mut self, enabled: bool, cx: &mut Context<Self>) {
        match self.save_preference("checksForAppUpdates", json!(enabled)) {
            Ok(()) => {
                let last = self.preferences.and_then(|(_, last)| last);
                self.preferences = Some((enabled, last));
                if self.automatic_check() {
                    self.looked = Some(Instant::now());
                }
            }
            Err(error) => self.model.error = Some(format!("The preference wasn't saved: {error}")),
        }
        cx.notify();
    }
    /// Swift records the check's time before it starts, so a failing check is
    /// not retried until the next day. False while the Engine is busy, so the
    /// next poll tries again.
    fn automatic_check(&mut self) -> bool {
        if matches!(self.model.state(), State::Disabled) {
            return true;
        }
        let Some((enabled, last)) = self.preferences() else {
            return false;
        };
        let now = swift_timestamp();
        if !automatic_check_due(enabled, last, now) || !self.model.can_check_automatically() {
            return true;
        }
        if self
            .save_preference("lastAppUpdateCheck", json!(now))
            .is_err()
        {
            return false;
        }
        self.preferences = Some((enabled, Some(now)));
        self.checking = self.model.automatic_check(enabled, last, now);
        true
    }
    fn check(&mut self) {
        let result = self.model.check();
        self.checking = result.is_ok();
        self.model.record(result);
    }
    /// The app menu's "Check for Updates…": same check the settings button runs.
    pub(super) fn check_now(&mut self, cx: &mut Context<Self>) {
        self.check();
        cx.notify();
    }
    pub fn tick(&mut self, cx: &mut Context<Self>) {
        let before = (self.model.state(), self.model.lifecycle().cloned());
        self.model.tick();
        if self.checking && self.model.operation.is_none() {
            self.checking = false;
            if matches!(
                self.model.state(),
                State::Current | State::Unpublished | State::Available(_)
            ) {
                let now = swift_timestamp();
                if self
                    .save_preference("lastAppUpdateCheck", json!(now))
                    .is_ok()
                    && let Some((enabled, _)) = self.preferences
                {
                    self.preferences = Some((enabled, Some(now)));
                }
            }
        }
        if self
            .looked
            .is_none_or(|looked| looked.elapsed() >= AUTOMATIC_LOOK)
            && self.automatic_check()
        {
            self.looked = Some(Instant::now());
        }
        if before != (self.model.state(), self.model.lifecycle().cloned()) {
            cx.notify();
        }
    }
}
impl Render for UpdaterSettingsView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let daily = self.preferences().is_none_or(|(enabled, _)| enabled);
        let state = self.model.state();
        let busy = self.model.busy();
        let armed = self.model.armed();
        let can_install = self.policy.is_some();
        let downloading = matches!(state, State::Downloading { .. } | State::Verifying);
        let ready =
            matches!(&state, State::Staged(stage) if stage.signature == SignatureStatus::Verified);
        let muted = cx.theme().muted_foreground;
        let mut actions = div().flex().flex_wrap().gap_2().child(
            Button::new("app-update-check")
                .label("Check for Updates…")
                .disabled(matches!(state, State::Disabled) || busy || armed)
                .on_click(cx.listener(|this, _, _, cx| {
                    this.check();
                    cx.notify();
                })),
        );
        if matches!(state, State::Available(_)) && can_install && !busy {
            actions = actions.child(
                Button::new("app-update-download")
                    .label("Download Update")
                    .on_click(cx.listener(|this, _, _, cx| {
                        let result = this.model.download();
                        this.model.record(result);
                        cx.notify();
                    })),
            );
        }
        if downloading {
            actions = actions.child(
                Button::new("app-update-cancel-download")
                    .label("Cancel Download")
                    .on_click(cx.listener(|this, _, _, cx| {
                        let result = this.model.cancel();
                        this.model.record(result);
                        cx.notify();
                    })),
            );
        }
        if ready && can_install && !armed {
            actions = actions.child(
                Button::new("app-update-install")
                    .label("Install on Quit")
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(policy) = this.policy.clone() {
                            let result = this.model.prepare_install(policy, this.launcher.as_mut());
                            this.model.record(result);
                        }
                        cx.notify();
                    })),
            );
        }
        let cancellable = self.model.lifecycle().is_some_and(|state| {
            !matches!(
                state,
                LifecycleState::Cancelled
                    | LifecycleState::Cancelling
                    | LifecycleState::WaitingForConsent
                    | LifecycleState::NormalQuitPermitted
                    | LifecycleState::Exiting
                    | LifecycleState::ConsentUncertain(_)
            )
        });
        if cancellable {
            actions = actions.child(
                Button::new("app-update-cancel")
                    .label("Cancel Installation")
                    .on_click(cx.listener(|this, _, _, cx| {
                        let result = this.model.cancel();
                        this.model.record(result);
                        cx.notify();
                    })),
            );
        }
        let mut content = div()
            .id("app-update-settings")
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(
                div()
                    .text_lg()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("App Updates"),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child("Check for updates daily")
                    .child(
                        Switch::new("app-update-daily")
                            .accessibility_label("Check for updates daily")
                            .checked(daily)
                            .on_click(cx.listener(|this, checked: &bool, _, cx| {
                                this.set_daily(*checked, cx)
                            })),
                    ),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(muted)
                    .child(self.model.status_text()),
            )
            .when(
                (matches!(state, State::Available(_)) || ready) && !can_install,
                |view| {
                    view.child(div().text_sm().text_color(muted).child(
                        if cfg!(target_os = "macos") {
                            "Updates can only be installed by a verified Developer ID build."
                        } else {
                            "Installing updates isn't available on this platform yet."
                        },
                    ))
                },
            )
            .child(actions);
        if let Some(LifecycleState::AwaitingNativeApproval(proposal)) = self.model.lifecycle() {
            let displayed = proposal.as_ref().clone();
            // The immutable proposal is the one the approval callback binds. Hash
            // and anchor are shown here because they determine this decision.
            content = content
                .child(format!(
                    "Install version {} over {}",
                    proposal.release.version, proposal.installed_version
                ))
                .child(format!("Target: {}", proposal.target.display()))
                .child(format!("Signing anchor: {}", proposal.anchor))
                .child(format!("Archive SHA-256: {}", proposal.release.sha256))
                .child(
                    Button::new("app-update-approve")
                        .label("Approve for Next Normal Quit")
                        .on_click(cx.listener(move |this, _, _, cx| {
                            let result = this.model.native_approve(&displayed);
                            this.model.record(result);
                            cx.notify();
                        })),
                );
        }
        if let Some(job) = self.model.staged_job().filter(|_| ready || armed) {
            content = content
                .child(div().text_sm().text_color(muted).child(
                    "Coincide never quits or reopens automatically. The previous app is kept as a backup.",
                ))
                .child(
                    Button::new("app-update-reveal")
                        .label("Show Update Folder")
                        .on_click(move |_, _, cx| cx.reveal_path(&job)),
                );
        }
        if let Some(error) = self.model.error() {
            content = content.child(div().text_sm().child(error.to_owned()));
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
        assert!(model.status_text().contains("no update channel"));
    }
    #[test]
    fn daily_check_is_due_once_a_day_only_while_on() {
        assert!(automatic_check_due(true, None, 0.));
        assert!(!automatic_check_due(false, None, 0.));
        assert!(!automatic_check_due(true, Some(1000.), 1000. + DAILY - 1.));
        assert!(automatic_check_due(true, Some(1000.), 1000. + DAILY));
        // As in Swift, a day must pass after the saved time; an unreadable time
        // never blocks the check.
        assert!(!automatic_check_due(true, Some(1000.), 999.));
        assert!(automatic_check_due(true, Some(f64::NAN), 0.));
        let mut model = UpdaterSettings::default();
        assert!(!model.automatic_check(true, None, 0.));
        assert!(model.operation.is_none() && model.error().is_none());
        assert!(matches!(model.state(), State::Disabled));
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
