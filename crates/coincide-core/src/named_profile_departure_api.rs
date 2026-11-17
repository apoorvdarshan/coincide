use super::*;
impl Engine {
    pub(crate) fn park_named_departure_by_id(&mut self, id: &str) -> Result<()> {
        let selection = self.store.thread_departure_selection(id)?;
        if selection["selection"]["provider"] != "codex"
            || crate::composer_selection::default_account(&selection["selection"]["accountID"])
        {
            return Ok(());
        }
        if let Some(binding) = self.named_resume.departure_binding(&selection)? {
            let fence = self.model_catalog.named_catalog_fence(&binding);
            let thread = self.store.thread(id)?;
            ensure!(
                thread["id"] == selection["id"] && thread["selection"] == selection["selection"],
                "Named account selection changed"
            );
            self.named_resume.park_departure(&thread, fence)?;
        }
        Ok(())
    }
    pub(crate) fn park_named_departure(&mut self, thread: &Value) -> Result<()> {
        if thread["selection"]["provider"] != "codex"
            || crate::composer_selection::default_account(&thread["selection"]["accountID"])
        {
            return Ok(());
        }
        if let Some(binding) = self.named_resume.departure_binding(thread)? {
            let fence = self.model_catalog.named_catalog_fence(&binding);
            self.named_resume.park_departure(thread, fence)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        agent::{WorkerCompletion, WorkerThreadStatus},
        codex_login_profiles::LaunchContext,
        composer_policy::Policy,
    };

    #[test]
    fn switching_ordinary_and_unproved_named_threads_uses_a_small_selection_projection() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let ordinary = Uuid::new_v4().to_string();
        let named = Uuid::new_v4().to_string();
        let account = Uuid::new_v4().to_string();
        for (id, account_id) in [(&ordinary, "default"), (&named, account.as_str())] {
            store.save(&json!({"id":id,"selection":{"provider":"codex","accountID":account_id},"items":[{"kind":"user","text":"x".repeat(1_000_000)}],"projectID":""})).unwrap();
            let projection = store.thread_departure_selection(id).unwrap();
            assert_eq!(projection["selection"]["accountID"], account_id);
            assert!(projection.get("items").is_none());
            assert!(projection.to_string().len() < 1000);
        }
        let mut engine = Engine::fixture(store);
        engine.set_active_thread(Some(ordinary.clone())).unwrap();
        engine.set_active_thread(Some(named.clone())).unwrap();
        assert_eq!(engine.active_thread(), Some(named.as_str()));
        engine.set_active_thread(Some(ordinary.clone())).unwrap();
        assert_eq!(engine.active_thread(), Some(ordinary.as_str()));
    }

    #[cfg(any(unix, windows))]
    #[test]
    fn switching_a_named_thread_still_parks_its_exact_joined_receipt() {
        let dir = tempfile::tempdir().unwrap();
        let private = dir.path().join("private");
        crate::native_file::private_directory(&private).unwrap();
        let root = private.canonicalize().unwrap();
        let mut store = Store::open(&root.join("state.sqlite")).unwrap();
        let id = Uuid::new_v4().to_string();
        let account = Uuid::new_v4().to_string();
        crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
        let profile =
            LaunchContext::capture(&root, &account, &std::env::current_exe().unwrap()).unwrap();
        let thread = json!({"id":id,"selection":{"provider":"codex","modelID":"default","accountID":account},"items":[{"kind":"user","text":"synthetic prefix"}],"sessions":{"codex":{"accountID":account,"sessionID":"synthetic-native"}}});
        store.save(&thread).unwrap();
        let mut engine = Engine::fixture(store);
        let policy =
            Policy::parse_named(&thread, crate::composer_policy::Origin::Ordinary, None).unwrap();
        let ack = engine
            .named_resume
            .prepare(&thread, profile, &root, policy)
            .unwrap()
            .acknowledge(&json!({"thread":{"id":"synthetic-native"},"model":"synthetic-model"}))
            .unwrap();
        let worker = WorkerCompletion::observe(std::thread::spawn(|| {}));
        let deadline = Instant::now() + Duration::from_secs(5);
        while worker.status() == WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        engine.named_resume.persisted(ack, &thread, worker);
        engine.named_resume.poll();
        let binding = engine
            .named_resume
            .departure_binding(&thread)
            .unwrap()
            .unwrap();
        engine
            .model_catalog
            .fixture_resume_job(binding.clone(), "before-switch");
        let fence = engine.model_catalog.named_catalog_fence(&binding).unwrap();
        engine.set_active_thread(Some(id)).unwrap();
        assert!(
            engine
                .named_resume
                .catalog_refresh_required(&binding, &fence)
                .unwrap()
        );
    }
}
