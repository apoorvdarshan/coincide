//! Parent normal-quit integration. Strict updater/native-release acceptance is
//! separate; this path never mints updater consent or enables its launcher.
use super::*;
use coincide_core::agent::WorkerThreadStatus;

fn workflow_drained(status: &worker_owner::ShutdownStatus) -> bool {
    status.closed
        && status.unjoined == 0
        && status.panicked == 0
        && status.unclassified == 0
        && status.pending_pickers == 0
}
impl Coincide {
    pub(super) fn poll_cookie_close(&mut self, cx: &mut Context<Self>) -> bool {
        // Synchronous context invalidation precedes any native progress. The
        // closed panel retains worker/picker and cleanup-only retry custody.
        self.browser_settings_panel
            .update(cx, |panel, _| panel.request_shutdown());
        let (progress, drained) = self.browser.as_mut().map_or((None, true), |browser| {
            let progress = browser.poll_cookie_import();
            (progress, browser.cookie_import_drained())
        });
        if let Some(status) = progress {
            self.browser_settings_panel
                .update(cx, |panel, cx| panel.set_cookie_import_status(status, cx));
        }
        let status = self
            .browser_settings_panel
            .update(cx, |panel, _| panel.shutdown_status());
        drained && workflow_drained(&status)
    }
    /// Gates the already-drained normal quit on the update lifecycle, when an
    /// installation was approved. Returns true only when no update is armed or
    /// the helper confirmed its consent after every real drain owner completed.
    pub(super) fn updater_quit_ready(&mut self, cx: &mut Context<Self>) -> bool {
        use crate::updater_lifecycle::{LifecycleState, Progress, ShutdownHooks, ShutdownStep};
        struct AlreadyDrained;
        impl ShutdownHooks for AlreadyDrained {
            fn poll_step(&mut self, _: ShutdownStep) -> anyhow::Result<Progress> {
                // This runs only after poll_global_quit reported the real drain
                // complete; each acknowledgement is therefore actual, not assumed.
                Ok(Progress::Complete)
            }
        }
        // The settings window can close during quitting, so the root tick must
        // also poll the helper session rather than depending on that window's task.
        self.updater_settings.update(cx, |view, cx| view.tick(cx));
        let action = match self.updater_settings.read(cx).model.lifecycle().cloned() {
            None
            | Some(LifecycleState::Cancelled)
            | Some(LifecycleState::Blocked(_))
            | Some(LifecycleState::WaitingForProposal)
            | Some(LifecycleState::WaitingForReady)
            | Some(LifecycleState::AwaitingNativeApproval(_))
            | Some(LifecycleState::Cancelling) => return true,
            Some(LifecycleState::ReadyForNormalQuit) => 1,
            Some(LifecycleState::ShuttingDown(step)) => {
                self.status = format!("Finishing {step:?} before the update installs…");
                2
            }
            Some(LifecycleState::WaitingForConsent) => {
                self.status = "Waiting for the update helper to confirm it is safe to quit…".into();
                return false;
            }
            Some(LifecycleState::NormalQuitPermitted) => 3,
            Some(LifecycleState::Exiting) => return false,
            Some(LifecycleState::ConsentUncertain(reason)) => {
                // Never claim a clean quit when consent may already have reached
                // the helper. The user can still force quit from the OS.
                self.status = format!(
                    "Quit is paused because the update consent is uncertain ({reason}). Force quit to stop without installing, or reopen Coincide."
                );
                return false;
            }
        };
        match action {
            1 => {
                self.status = "Saving and stopping work before the update installs…".into();
                let result = self
                    .updater_settings
                    .update(cx, |view, _| view.model.begin_normal_quit());
                if let Err(error) = result {
                    self.status = format!("The verified update isn't armed: {error}");
                }
                false
            }
            2 => {
                let mut hooks = AlreadyDrained;
                self.updater_settings
                    .update(cx, |view, _| view.model.advance_shutdown(&mut hooks));
                false
            }
            _ => {
                self.status = "Your work is saved. The update installs as Coincide quits…".into();
                let permit = self.updater_settings.update(cx, |view, _| {
                    view.model.take_normal_quit_permission().is_some()
                });
                permit
            }
        }
    }
    pub(super) fn finish_normal_quit(&mut self, cx: &mut Context<Self>) {
        if self.quit_issued {
            return;
        }
        if let Some(guard) = &self.native_quit {
            if self.native_quit_observed {
                if let Err(error) = guard.permit_once() {
                    self.status = error.to_string();
                    return;
                }
                self.quit_issued = true;
            }
            // API quit must also be observed by the native veto before a permit
            // exists. The next tick sees that native request and consumes it.
        } else {
            self.quit_issued = true;
        }
        cx.quit();
    }
    pub(super) fn poll_global_quit(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        // Only committed source may enter the normal draft-flush custody.
        self.close_dictation_preview(cx);
        self.palette_search.shutdown();
        // Admission closure is one in-memory flag, even if the off-UI drain
        // worker cannot start. Busy Engine is retried without blocking GPUI.
        if let Ok(mut engine) = self.engine.try_lock() {
            engine.freeze_admissions();
        }
        if self.quit_runtime.is_none() && self.quit_runtime_error.is_none() {
            // Freeze native input before accepting an external-owner drain proof.
            // Render a read-only surface and capture any already committed text.
            window.blur(cx);
            match shutdown_runtime::Runtime::start(self.engine.clone(), self.control_owner.clone())
            {
                Ok(runtime) => self.quit_runtime = Some(runtime),
                Err(error) => self.quit_runtime_error = Some(error.to_string()),
            }
        }
        if let Some(thread) = self.selected.as_mut() {
            let current = self.composer.read(cx).value().to_string();
            if thread["draft"].as_str() != Some(current.as_str()) {
                let id = text(thread, "id");
                thread["draft"] = json!(&current);
                if self
                    .pending_drafts
                    .get(&id)
                    .is_none_or(|draft| draft.text != current)
                {
                    self.pending_drafts.insert(
                        id,
                        PendingDraft {
                            text: current,
                            retry: true,
                            failed: false,
                        },
                    );
                }
            }
        }
        let drafts_saved = self.flush_pending_drafts() && self.flush_native_selection();
        self.voice.close();
        self.selection_ui.close_capability_reads();
        self.thread_bulk.close();
        self.instructions_panel
            .update(cx, |panel, _| panel.request_instruction_git_shutdown());
        self.provider_configuration_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.composer_files.close();
        self.composer_suggestions.close();
        self.usage_history.request_shutdown();
        self.codex_limits.request_shutdown();
        self.credential_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.transcription_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.microphone_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.voice_credentials
            .update(cx, |panel, _| panel.request_shutdown());
        self.session_import_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.bot_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.workspace_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.git_controls.request_shutdown();
        self.diff_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.browser_settings_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.github_panel
            .update(cx, |panel, cx| panel.request_shutdown(cx));
        self.github_threads_panel
            .update(cx, |panel, _| panel.request_shutdown());
        self.notification_panel.read(cx).request_shutdown();
        self.appshots.close();
        self.shutdown_computer_use(cx);
        for workspace in self.terminal_workspaces.values() {
            workspace.update(cx, |workspace, cx| workspace.request_shutdown(cx));
        }
        if let Some(browser) = &mut self.browser {
            browser.request_shutdown(cx);
        }
        // The root owns messages already exported from their closed workflows.
        for _ in self.credential_jobs.try_iter() {}
        for _ in self.transcription_events.try_iter() {}
        for _ in self.microphone_events.try_iter() {}
        for _ in self.browser_profile_requests.try_iter() {}
        self.browser_replies.clear();
        self.request_media_owner_shutdown(cx);
        let media = self.poll_media_owner_shutdown(cx);
        let statuses = [
            self.palette_search.status(),
            self.voice_credentials
                .update(cx, |panel, _| panel.shutdown_status()),
            self.provider_configuration_panel
                .update(cx, |panel, _| panel.shutdown_status()),
            self.selection_ui.capability_read_shutdown_status(),
            self.thread_bulk.shutdown_status(),
            self.instructions_panel
                .update(cx, |panel, _| panel.instruction_git_shutdown_status()),
            self.composer_files.shutdown_status(),
            self.composer_suggestions.shutdown_status(),
            self.usage_history.shutdown_status(),
            self.credential_panel
                .update(cx, |panel, _| panel.shutdown_status()),
            self.transcription_panel
                .update(cx, |panel, _| panel.shutdown_status()),
            self.session_import_panel
                .update(cx, |panel, _| panel.shutdown_status()),
            self.bot_panel
                .update(cx, |panel, _| panel.shutdown_status()),
            self.workspace_panel
                .update(cx, |panel, _| panel.shutdown_status()),
            self.git_controls.shutdown_status(),
            self.diff_panel
                .update(cx, |panel, _| panel.shutdown_status()),
            self.browser_settings_panel
                .update(cx, |panel, _| panel.shutdown_status()),
            self.github_threads_panel
                .update(cx, |panel, _| panel.shutdown_status()),
        ];
        let github = self
            .github_panel
            .update(cx, |panel, cx| panel.shutdown_status(cx));
        let microphone = self
            .microphone_panel
            .update(cx, |panel, _| panel.shutdown_status());
        let notifications = self.notification_panel.read(cx).bridge_handle();
        if let Some(handle) = &notifications {
            handle.try_reconcile_claims(&self.engine);
        }
        let notifications_done = self.notification_panel.read(cx).ordinary_exit_ready();
        let terminals_done = self.terminal_workspaces.values().all(|workspace| {
            workspace.update(cx, |workspace, _| workspace.shutdown_status())
                == WorkerThreadStatus::Returned
        });
        // Ordinary process exit releases idle native browser objects. Updater
        // authorization additionally requires its separate native-release proof.
        let browser_done = self
            .browser
            .as_mut()
            .is_none_or(|b| b.poll_shutdown().owners_drained() && b.cookie_import_drained());
        let media_ready = media.ready();
        let workflows_ready = statuses.iter().all(workflow_drained);
        let github_ready = workflow_drained(&github.read)
            && github.actions.is_none_or(|s| s.ready())
            && github.writes.is_none_or(|s| s.ready());
        let microphone_ready = microphone.ordinary_exit_ready();
        let appshots_ready = self.appshots.drained();
        let computer_use_ready = self.computer_use_shutdown_ready();
        let images_ready = self.image_validations_running == 0
            && self.image_validation_tasks.is_empty()
            && self.navigation_tasks.is_empty();
        let thread_bulk_ready = self.thread_bulk.receipts_drained();
        let composer_files_ready = self.composer_files.receipts_drained();
        // Offscreen/minimized windows may not draw another frame. Completion
        // depends on saved data and joined owners, never a visual acknowledgement.
        // Admissions and native input are already closed above.
        let external = drafts_saved
            && media_ready
            && workflows_ready
            && github_ready
            && microphone_ready
            && notifications_done
            && terminals_done
            && browser_done
            && appshots_ready
            && computer_use_ready
            && images_ready
            && thread_bulk_ready
            && composer_files_ready;
        let mut waiting = Vec::new();
        if !drafts_saved {
            waiting.push("drafts");
        }
        if !media_ready {
            waiting.push("media");
        }
        if !workflows_ready {
            waiting.push("panel workflows");
        }
        if !github_ready {
            waiting.push("github");
        }
        if !microphone_ready {
            waiting.push("microphone");
        }
        if !notifications_done {
            waiting.push("notifications");
        }
        if !terminals_done {
            waiting.push("terminals");
        }
        if !browser_done {
            waiting.push("browser");
        }
        if !appshots_ready {
            waiting.push("appshots");
        }
        if !computer_use_ready {
            waiting.push("computer use");
        }
        if !images_ready {
            waiting.push("images");
        }
        if !thread_bulk_ready {
            waiting.push("sidebar operations");
        }
        if !composer_files_ready {
            waiting.push("file discovery");
        }
        let Some(runtime) = &self.quit_runtime else {
            if let Some(error) = &self.quit_runtime_error {
                self.status = format!("Quitting is paused: {error}");
            }
            return false;
        };
        runtime.set_external_drained(external);
        let status = runtime.status();
        if let Some(error) = &status.error {
            self.status = format!("Quitting is paused: {error}");
        } else if !drafts_saved {
            self.status =
                "Drafts are waiting to save. Use Retry save if a previous save failed.".into();
        } else if !external {
            self.status = format!(
                "Finishing background work. Waiting for: {}.",
                waiting.join(", ")
            );
        } else {
            self.status =
                "Finishing background work. Your data remains open until saving completes.".into();
        }
        status.complete() && external
    }
}
