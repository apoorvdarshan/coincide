//! Native owner-only history actions. No JSON paths, profile grants or navigation.
use super::*;
use crate::browser_history::{self, ImportResult, Library, Plan};
pub struct PreparedHistoryOpen {
    owner: Uuid,
    engine_revision: u64,
    thread: String,
    profile: Uuid,
    url: String,
}
pub struct AdmittedHistoryOpen {
    thread: String,
    profile: Uuid,
    url: String,
}
impl AdmittedHistoryOpen {
    pub fn into_parts(self) -> (String, Uuid, String) {
        (self.thread, self.profile, self.url)
    }
}
impl Engine {
    pub fn saved_browser_history(&self, profile: Uuid) -> Result<Library> {
        self.require_admissions()?;
        self.store.saved_browser_history(profile)
    }
    pub fn import_browser_history(
        &mut self,
        thread: &str,
        profile: Uuid,
        expected: u64,
        plan: &Plan,
    ) -> Result<ImportResult> {
        self.require_admissions()?;
        ensure!(
            self.active_thread() == Some(thread),
            "Selected conversation changed; history was not imported"
        );
        let result = self.store.import_browser_history(profile, expected, plan)?;
        if result.changed {
            self.revision += 1;
        }
        Ok(result)
    }
    /// Off-UI resolution. Import/reload never calls this or opens a page.
    pub fn prepare_browser_history(
        &self,
        thread: &str,
        profile: Uuid,
        id: Uuid,
        revision: u64,
    ) -> Result<PreparedHistoryOpen> {
        self.require_admissions()?;
        ensure!(self.ui_available, "History opens in the desktop browser");
        ensure!(
            self.active_thread() == Some(thread),
            "Selected conversation changed; reload history"
        );
        let library = self.saved_browser_history(profile)?;
        let entry = library.selected(id, revision)?;
        let url = browser_history::record_view(&entry.record)?.url;
        Ok(PreparedHistoryOpen {
            owner: self.bookmark_owner,
            engine_revision: self.revision,
            thread: thread.into(),
            profile,
            url,
        })
    }
    /// Memory-only admission. Parent must still match its exact native profile,
    /// tab/navigation snapshot and visible Settings route before the native call.
    pub fn admit_prepared_history(
        &self,
        prepared: PreparedHistoryOpen,
    ) -> Result<AdmittedHistoryOpen> {
        self.require_admissions()?;
        ensure!(
            self.ui_available && !self.store.is_closed(),
            "History browser is unavailable"
        );
        ensure!(
            prepared.owner == self.bookmark_owner
                && prepared.engine_revision == self.revision
                && self.active_thread() == Some(prepared.thread.as_str()),
            "App or conversation changed; click Open again"
        );
        Ok(AdmittedHistoryOpen {
            thread: prepared.thread,
            profile: prepared.profile,
            url: prepared.url,
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn import_and_resolution_never_navigate_and_stale_or_foreign_proofs_fail_closed() {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        let id = text(&engine.execute("threads.create", &json!({})).unwrap(), "id");
        engine.ui_available = true;
        engine.set_active_thread(Some(id.clone())).unwrap();
        let profile = Uuid::new_v4();
        let plan=browser_history::preview(br#"{"history":[{"url":"https://example.test/","title":"Saved","visitCount":1,"lastVisit":0}]}"#).unwrap();
        let library = engine
            .import_browser_history(&id, profile, 0, &plan)
            .unwrap()
            .library;
        assert!(engine.browser_requests.is_empty());
        let before = engine.store.thread(&id).unwrap();
        let proof = engine
            .prepare_browser_history(&id, profile, library.history[0].id, library.revision)
            .unwrap();
        let foreign_proof = engine
            .prepare_browser_history(&id, profile, library.history[0].id, library.revision)
            .unwrap();
        let mut foreign = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        foreign.ui_available = true;
        foreign.set_active_thread(Some(id.clone())).unwrap();
        foreign.revision = engine.revision;
        assert!(foreign.admit_prepared_history(foreign_proof).is_err());
        engine.revision += 1;
        assert!(engine.admit_prepared_history(proof).is_err());
        assert!(engine.browser_requests.is_empty());
        let proof = engine
            .prepare_browser_history(&id, profile, library.history[0].id, library.revision)
            .unwrap();
        let (thread, destination, url) = engine.admit_prepared_history(proof).unwrap().into_parts();
        assert_eq!(
            (thread, destination, url),
            (id.clone(), profile, "https://example.test/".into())
        );
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert!(engine.browser_requests.is_empty());
        let proof = engine
            .prepare_browser_history(&id, profile, library.history[0].id, library.revision)
            .unwrap();
        engine.set_active_thread(None).unwrap();
        assert!(engine.admit_prepared_history(proof).is_err());
        assert!(
            engine
                .import_browser_history(&id, profile, library.revision, &plan)
                .is_err()
        );
        engine.store.close_for_shutdown().unwrap();
        assert!(engine.saved_browser_history(profile).is_err());
    }
}
