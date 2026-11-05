//! Engine-owned generic workers. Filesystem/git operations already admitted have
//! no safe cancellation protocol; closing admissions does not interrupt writes.
use super::*;

const MAX_WORKERS: usize = 32;
#[cfg(test)]
#[path = "background_worker_tests.rs"]
mod tests;

/// Sampled Rust-thread ownership, not child cleanup or whole-app readiness.
/// Pending mutation/attachment completion ownership can outlive a worker panic.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BackgroundShutdownStatus {
    pub closed: bool,
    pub running: usize,
    pub returned: u64,
    pub panicked: u64,
    pub unclassified: u64,
    pub pending_mutation_completions: usize,
    pub pending_attachment_completions: usize,
}
#[derive(Default)]
pub(super) struct State {
    workers: Vec<agent::WorkerCompletion>,
    totals: BackgroundShutdownStatus,
}
impl State {
    pub(super) fn check_admission(&mut self) -> Result<()> {
        self.poll();
        ensure!(
            !self.totals.closed,
            "Background worker admissions are closed"
        );
        ensure!(
            self.workers.len() < MAX_WORKERS,
            "Too many background workers; wait for existing workers to exit"
        );
        Ok(())
    }
    pub(super) fn track(&mut self, worker: std::thread::JoinHandle<()>) {
        self.workers.push(agent::WorkerCompletion::observe(worker));
    }
    pub(super) fn poll(&mut self) {
        let totals = &mut self.totals;
        self.workers.retain(|worker| {
            let counter = match worker.status() {
                agent::WorkerThreadStatus::Running => return true,
                agent::WorkerThreadStatus::Returned => &mut totals.returned,
                agent::WorkerThreadStatus::Panicked => &mut totals.panicked,
                agent::WorkerThreadStatus::Unclassified => return true,
            };
            *counter = counter.saturating_add(1);
            false
        });
    }
    fn status(&mut self) -> BackgroundShutdownStatus {
        self.poll();
        BackgroundShutdownStatus {
            running: self.workers.len(),
            unclassified: self.totals.unclassified
                + self
                    .workers
                    .iter()
                    .filter(|w| w.status() == agent::WorkerThreadStatus::Unclassified)
                    .count() as u64,
            ..self.totals
        }
    }
}
impl Engine {
    pub(super) fn require_background_admission(&mut self) -> Result<()> {
        self.require_admissions()?;
        self.background_workers.check_admission()
    }
    /// Trusted owner-only closure. Existing filesystem/git work is not safely
    /// cancellable; keep polling its completion mailbox and join acknowledgments.
    pub fn request_background_shutdown(&mut self) -> Result<()> {
        ensure!(
            self.admissions_frozen(),
            "Background shutdown requires frozen admissions"
        );
        self.background_workers.totals.closed = true;
        Ok(())
    }
    /// Nonblocking completion-mailbox and actual thread-join observation only.
    pub fn background_shutdown_status(&mut self) -> Result<BackgroundShutdownStatus> {
        ensure!(
            self.admissions_frozen(),
            "Background shutdown status requires frozen admissions"
        );
        self.poll_workspace_completions();
        let status = self.background_workers.status();
        // A completion can publish between the first receive pass and join
        // acknowledgement. Drain again before reporting ownership counts.
        self.poll_workspace_completions();
        Ok(BackgroundShutdownStatus {
            pending_mutation_completions: self.workspace_mutations.len(),
            pending_attachment_completions: self.attachment_operations.len(),
            ..status
        })
    }
}
