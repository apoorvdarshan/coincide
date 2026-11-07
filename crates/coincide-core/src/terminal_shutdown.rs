//! Trusted terminal-owner drain. This does not declare whole-app shutdown ready.
use super::*;
use crate::terminal::{PendingTerminalShutdown, TerminalShutdownStatus};

#[derive(Default)]
pub(super) struct State {
    requested: bool,
    owners: Vec<Owner>,
    errors: Vec<DrainError>,
}
struct Owner {
    terminal_id: String,
    thread_id: String,
    pending: PendingTerminalShutdown,
}
#[derive(Debug, Clone)]
pub struct DrainError {
    pub terminal_id: String,
    pub message: String,
}
#[derive(Debug, Clone)]
pub struct PaneStatus {
    pub terminal_id: String,
    pub thread_id: String,
    pub status: TerminalShutdownStatus,
}
#[derive(Debug, Clone)]
pub struct TerminalsShutdownStatus {
    pub requested: bool,
    pub live_count: usize,
    pub pending_count: usize,
    pub completed_count: usize,
    pub panes: Vec<PaneStatus>,
    pub errors: Vec<DrainError>,
}
impl TerminalsShutdownStatus {
    pub fn ready(&self) -> bool {
        self.requested
            && self.live_count == 0
            && self.pending_count == 0
            && self.errors.is_empty()
            && self.panes.iter().all(|pane| pane.status.ready())
    }
}
impl Engine {
    /// Restarting replaces a shell but retains its complete retired owner in
    /// the same collector that whole-app shutdown checks.
    pub(super) fn retain_restarted_terminal(
        &mut self,
        terminal_id: String,
        thread_id: String,
        pending: PendingTerminalShutdown,
    ) {
        self.terminal_shutdown.owners.push(Owner {
            terminal_id,
            thread_id,
            pending,
        });
    }

    /// Irreversible owner transfer, available only after trusted admission freeze.
    /// Retain all pending owners and failure records; repeated calls never retry kills.
    pub fn request_terminals_shutdown(&mut self) -> Result<()> {
        ensure!(
            self.admissions_frozen(),
            "Terminal drain requires frozen admissions"
        );
        if self.terminal_shutdown.requested {
            return Ok(());
        }
        self.terminal_shutdown.requested = true;
        for (terminal_id, (thread_id, mut terminal)) in std::mem::take(&mut self.terminals) {
            match terminal.request_shutdown() {
                Ok(pending) => self.terminal_shutdown.owners.push(Owner {
                    terminal_id,
                    thread_id,
                    pending,
                }),
                Err(_) => {
                    self.terminal_shutdown.errors.push(DrainError {
                        terminal_id: terminal_id.clone(),
                        message: "Terminal shutdown transfer failed; ownership retained".into(),
                    });
                    self.terminals.insert(terminal_id, (thread_id, terminal));
                }
            }
        }
        self.revision += 1;
        Ok(())
    }
    /// Nonblocking observation only. Does not request stop, retry, or release owners.
    pub fn poll_terminals_shutdown(&self) -> TerminalsShutdownStatus {
        let panes: Vec<_> = self
            .terminal_shutdown
            .owners
            .iter()
            .map(|owner| PaneStatus {
                terminal_id: owner.terminal_id.clone(),
                thread_id: owner.thread_id.clone(),
                status: owner.pending.poll(),
            })
            .collect();
        let completed_count = panes.iter().filter(|pane| pane.status.ready()).count();
        TerminalsShutdownStatus {
            requested: self.terminal_shutdown.requested,
            live_count: self.terminals.len(),
            pending_count: panes.len() - completed_count,
            completed_count,
            panes,
            errors: self.terminal_shutdown.errors.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn empty_terminal_drain_requires_freeze_is_inert_and_rejects_later_json_create() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("data.sqlite")).unwrap();
        let project = store.create_project(dir.path(), Some("synthetic")).unwrap();
        let mut thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
        thread["draft"] = json!("exact unsent\n 中文");
        store.save(&thread).unwrap();
        let id = text(&thread, "id");
        let mut engine = Engine::fixture(store);
        assert!(!engine.poll_terminals_shutdown().ready());
        assert!(engine.request_terminals_shutdown().is_err());
        assert!(!engine.poll_terminals_shutdown().requested);
        engine.freeze_admissions();
        engine.request_terminals_shutdown().unwrap();
        assert!(engine.poll_terminals_shutdown().ready());
        let revision = engine.revision;
        engine.request_terminals_shutdown().unwrap();
        assert_eq!(engine.revision, revision);
        let result=engine.dispatch(json!({"method":"terminal.create","params":{"threadId":id,"shell":"/nonexistent-synthetic-shell"}}));
        assert_eq!(result["error"]["message"], "Engine admissions are frozen");
        assert!(engine.poll_terminals_shutdown().ready());
        assert_eq!(engine.store.thread(&id).unwrap(), thread);
    }
}
