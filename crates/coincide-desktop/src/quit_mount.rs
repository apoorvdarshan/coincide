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
        self.steering.request_shutdown();
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
            self.steering.shutdown_status(),
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
        let external = self.quit_frame_seen
            && drafts_saved
            && media.ready()
            && statuses.iter().all(workflow_drained)
            && workflow_drained(&github.read)
            && github.actions.is_none_or(|s| s.ready())
            && github.writes.is_none_or(|s| s.ready())
            && microphone.ordinary_exit_ready()
            && notifications_done
            && terminals_done
            && browser_done
            && self.appshots.drained()
            && self.computer_use_shutdown_ready()
            && self.image_validations_running == 0
            && self.image_validation_tasks.is_empty()
            && self.navigation_tasks.is_empty()
            && self.thread_bulk.receipts_drained()
            && self.composer_files.receipts_drained();
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
        } else {
            self.status =
                "Finishing background work. Your data remains open until saving completes.".into();
        }
        status.complete() && external
    }
}
