//! Trusted Engine admission controls, independent of shutdown readiness.
use super::*;

impl Engine {
    /// Irreversibly close all Engine JSON entry points and new provider/queue/
    /// schedule dispatch. Existing work and persistence must still be polled.
    /// This does not stop workers or establish resource cleanup/quiescence.
    pub fn freeze_admissions(&mut self) {
        self.cancel_provider_restore();
        self.admissions_frozen = true;
    }

    pub fn admissions_frozen(&self) -> bool {
        self.admissions_frozen
    }

    pub(super) fn require_admissions(&self) -> Result<()> {
        ensure!(!self.admissions_frozen, "Engine admissions are frozen");
        Ok(())
    }

    /// Trusted owner-only draft flush after JSON admissions have closed. A
    /// failed write leaves the caller's draft ownership intact; retry explicitly.
    /// No arbitrary thread patch or provider work can pass through this seam.
    pub fn persist_frozen_draft(&mut self, thread_id: &str, text: &str) -> Result<()> {
        ensure!(
            self.admissions_frozen,
            "Draft flush requires frozen admissions"
        );
        ensure!(text.len() <= 1_048_576, "Draft exceeds 1 MiB");
        ensure!(
            !self.unsaved_threads.contains_key(thread_id),
            "Transcript persistence is recovering; retry draft flush after recovery"
        );
        self.store.patch_thread(thread_id, &json!({"draft":text}))?;
        self.revision += 1;
        Ok(())
    }

    /// Trusted cancellation remains available after JSON admissions close.
    /// Sending Stop requests cancellation; it does not acknowledge worker exit
    /// or successful provider/process cleanup. Existing poll still owns results.
    pub fn request_provider_stop(&mut self, thread_id: &str) -> Result<()> {
        let user_initiated = !self.admissions_frozen();
        let run = self
            .runs
            .get_mut(thread_id)
            .context("Thread is not running")?;
        run.cancelled = true;
        if user_initiated {
            run.session.stop_for_user();
        } else {
            run.session.stop();
        }
        self.notification_events.cancel_requests(thread_id);
        self.enabled_queues.remove(thread_id);
        Ok(())
    }
}
