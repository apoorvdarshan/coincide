//! Trusted aggregation of Engine-owned Rust workers and persistence recovery.
//! Native UI owners, external process cleanup and Store closure remain separate.
use super::*;

pub struct CoreOwnerShutdownStatus {
    pub admissions_frozen: bool,
    pub providers: ProviderWorkersStatus,
    pub catalog: crate::model_catalog::ShutdownStatus,
    pub github_reads: [crate::github_api::ReadShutdownStatus; 2],
    pub background: BackgroundShutdownStatus,
    pub idle_host: IdleShutdownStatus,
    pub terminals: terminal_shutdown::TerminalsShutdownStatus,
    pub active_turns: usize,
    pub unsaved_threads: usize,
    pub pending_schedule_completions: usize,
    pub schedule_error: Option<String>,
}
impl CoreOwnerShutdownStatus {
    /// Engine owner accounting only. This cannot authorize helper consent,
    /// process exit, native WebView teardown, or closing the public control owner.
    pub fn rust_owners_drained(&self) -> bool {
        let p = self.providers;
        let c = self.catalog;
        let b = self.background;
        self.admissions_frozen
            && p.running == 0
            && p.panicked == 0
            && p.unclassified == 0
            && c.closed
            && c.running == 0
            && c.panicked == 0
            && c.unclassified == 0
            && self
                .github_reads
                .iter()
                .all(|s| s.closed && s.running == 0 && s.panicked == 0 && s.unclassified == 0)
            && b.closed
            && b.running == 0
            && b.panicked == 0
            && b.unclassified == 0
            && b.pending_mutation_completions == 0
            && b.pending_attachment_completions == 0
            && self.idle_host.ready()
            && self.terminals.ready()
            && self.active_turns == 0
            && self.unsaved_threads == 0
            && self.pending_schedule_completions == 0
            && self.schedule_error.is_none()
    }
}
impl Engine {
    /// Native owner calls this off the UI thread only after native/UI owners
    /// and control transport have drained too. Core guards cannot certify those
    /// external owners; this method adds no API route or automatic retry.
    pub fn close_store_after_core_shutdown(&mut self) -> Result<()> {
        ensure!(
            self.admissions_frozen(),
            "Store close requires frozen admissions"
        );
        if self.store.is_closed() {
            return Ok(());
        }
        ensure!(
            self.poll_core_owner_shutdown()?.rust_owners_drained(),
            "Core owners are not drained"
        );
        self.store.close_for_shutdown()
    }
    /// Native owner-only irreversible closure. Every cancellation remains a
    /// request; callers retain and poll this Engine until actual acknowledgments.
    pub fn request_core_owner_shutdown(&mut self) -> Result<()> {
        self.freeze_admissions();
        self.enabled_queues.clear();
        let threads = self.runs.keys().cloned().collect::<Vec<_>>();
        for thread in threads {
            self.request_provider_stop(&thread)?;
        }
        self.computer_use_shutdown();
        self.request_model_catalog_shutdown()?;
        self.request_background_shutdown()?;
        self.request_github_reads_shutdown()?;
        self.request_idle_host_shutdown()?;
        self.request_terminals_shutdown()?;
        Ok(())
    }
    pub fn poll_core_owner_shutdown(&mut self) -> Result<CoreOwnerShutdownStatus> {
        ensure!(
            self.admissions_frozen(),
            "Core drain requires frozen admissions"
        );
        ensure!(!self.store.is_closed(), "Store is closed");
        // Recovery, admitted completions and cancellation must continue after
        // admission closure. Engine.poll never restarts frozen dispatch.
        self.poll();
        Ok(CoreOwnerShutdownStatus {
            admissions_frozen: self.admissions_frozen(),
            providers: self.provider_workers_status(),
            catalog: self.model_catalog_shutdown_status()?,
            github_reads: self.github_reads_shutdown_status()?,
            background: self.background_shutdown_status()?,
            idle_host: self.idle_host_shutdown_status()?,
            terminals: self.poll_terminals_shutdown(),
            active_turns: self.runs.len(),
            unsaved_threads: self.unsaved_threads.len(),
            pending_schedule_completions: self.schedule_completions.len(),
            schedule_error: self.schedule_error.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn trusted_owner_closes_every_engine_gate_and_preserves_exact_unsent_draft() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let mut thread = store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        thread["draft"] = json!("unsent\n中文 🦀");
        store.save(&thread).unwrap();
        let mut engine = Engine::fixture(store);
        assert!(engine.poll_core_owner_shutdown().is_err());
        assert!(engine.close_store_after_core_shutdown().is_err());
        engine.request_core_owner_shutdown().unwrap();
        engine.request_core_owner_shutdown().unwrap();
        assert!(
            engine
                .poll_core_owner_shutdown()
                .unwrap()
                .rust_owners_drained()
        );
        assert_eq!(
            engine.store.thread(thread["id"].as_str().unwrap()).unwrap(),
            thread
        );
        assert!(
            !engine.shutdown,
            "owner drainage itself never permits app quit"
        );
        let reply = engine.dispatch(json!({"method":"thread.create","params":{}}));
        assert_eq!(reply["error"]["message"], "Engine admissions are frozen");
        engine.close_store_after_core_shutdown().unwrap();
        assert!(engine.store.is_closed());
        engine.close_store_after_core_shutdown().unwrap();
        assert!(engine.poll_core_owner_shutdown().is_err());
    }
}
