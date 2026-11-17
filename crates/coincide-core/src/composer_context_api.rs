//! Trusted optimistic context editor; parent registers one narrow dispatch arm.
use super::*;
use crate::composer_context::{self, Edit, ExpectedContext};
impl Engine {
    /// The desktop calls this only for a path the user picked, pasted, or
    /// dropped. It targets that original conversation even if selection moves.
    pub fn attach_picked_path(
        &mut self,
        id: &str,
        path: &composer_context::PickedPath,
    ) -> Result<Value> {
        self.require_admissions()?;
        let uuid = Uuid::parse_str(id)?;
        ensure!(
            std::path::Path::new(&path.path).is_absolute(),
            "Attachment path is not absolute"
        );
        ensure!(
            !self
                .unsaved_threads
                .keys()
                .any(|id| Uuid::parse_str(id).ok() == Some(uuid)),
            "Transcript persistence is recovering"
        );
        let card = self.store.attach_picked_path(id, path)?;
        self.revision += 1;
        Ok(card)
    }

    /// A cancelled in-flight selection may only remove the exact card that
    /// its own job inserted, never a pre-existing or subsequently edited one.
    pub fn remove_cancelled_picked_path(&mut self, id: &str, card: &Value) -> Result<()> {
        self.require_admissions()?;
        let uuid = Uuid::parse_str(id)?;
        ensure!(
            !self
                .unsaved_threads
                .keys()
                .any(|id| Uuid::parse_str(id).ok() == Some(uuid)),
            "Transcript persistence is recovering"
        );
        if self.store.remove_cancelled_picked_path(id, card)? {
            self.revision += 1;
        }
        Ok(())
    }

    /// Remove the exact reference the desktop user dismissed. This compact
    /// update works for quotes and files without rewriting the conversation.
    pub fn remove_draft_context_card(&mut self, id: &str, card: &Value) -> Result<()> {
        self.require_admissions()?;
        let uuid = Uuid::parse_str(id)?;
        ensure!(
            !self.store.is_imported(id)?,
            "Fork an imported thread before editing context"
        );
        ensure!(
            !self
                .unsaved_threads
                .keys()
                .any(|id| Uuid::parse_str(id).ok() == Some(uuid)),
            "Transcript persistence is recovering"
        );
        if self.store.remove_exact_context_card(id, card)? {
            self.revision += 1;
        }
        Ok(())
    }

    pub fn edit_composer_context(&mut self, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        let object = p.as_object().context("Context edit must be an object")?;
        ensure!(
            object
                .keys()
                .all(|key| matches!(key.as_str(), "threadId" | "expectedContext" | "edit")),
            "Unknown context edit field"
        );
        let id = required(p, "threadId")?;
        let uuid = Uuid::parse_str(id)?;
        ensure!(
            self.active_thread().and_then(|id| Uuid::parse_str(id).ok()) == Some(uuid),
            "Context target is no longer selected"
        );
        ensure!(
            !self
                .unsaved_threads
                .keys()
                .any(|id| Uuid::parse_str(id).ok() == Some(uuid)),
            "Transcript persistence is recovering"
        );
        ensure!(
            !self.store.is_imported(id)?,
            "Fork an imported thread before editing context"
        );
        let mut thread = self.store.thread(id)?;
        let expected: ExpectedContext = serde_json::from_value(
            p.get("expectedContext")
                .context("Missing expected context")?
                .clone(),
        )?;
        ensure!(
            expected.matches(&thread),
            "Attached context changed; reload before editing"
        );
        let edit: Edit =
            serde_json::from_value(p.get("edit").context("Missing context edit")?.clone())?;
        let raw = thread.get("draftContext").unwrap_or(&Value::Null);
        let next = match edit {
            Edit::Quote { item_id } => {
                let item_id = Uuid::parse_str(&item_id)?;
                let mut matches = thread["items"]
                    .as_array()
                    .context("Invalid transcript")?
                    .iter()
                    .filter(|item| {
                        item["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(item_id)
                    });
                let item = matches
                    .next()
                    .context("Quoted message is no longer available")?;
                ensure!(
                    matches.next().is_none(),
                    "Quoted message identity is ambiguous"
                );
                composer_context::append_quote(raw, item)?
            }
            Edit::Remove { id } => composer_context::remove(raw, &id)?,
            Edit::Clear => json!([]),
        };
        thread["draftContext"] = next;
        self.store.save(&thread)?;
        self.revision += 1;
        Ok(thread)
    }
}

#[cfg(test)]
mod picked_path_tests {
    use super::*;
    #[test]
    fn removing_a_quote_is_exact_and_preserves_newer_draft_context() {
        let directory = tempfile::tempdir().unwrap();
        let store = crate::store::Store::open(&directory.path().join("state.sqlite")).unwrap();
        let mut engine = Engine::fixture(store);
        let mut thread = engine.store.new_thread("").unwrap();
        let id = thread["id"].as_str().unwrap().to_owned();
        let quote = json!({"id":Uuid::new_v4(),"kind":"quote","text":"selected text"});
        let other = json!({"id":Uuid::new_v4(),"kind":"quote","text":"keep this"});
        thread["draft"] = json!("new draft");
        thread["draftContext"] = json!([quote.clone(), other.clone()]);
        engine.store.save(&thread).unwrap();
        let mut changed = quote.clone();
        changed["text"] = json!("newer text");
        thread["draftContext"] = json!([changed.clone(), other.clone()]);
        engine.store.save(&thread).unwrap();
        assert!(engine.remove_draft_context_card(&id, &quote).is_err());
        assert_eq!(
            engine.store.thread(&id).unwrap()["draftContext"],
            json!([changed.clone(), other.clone()])
        );
        engine.remove_draft_context_card(&id, &changed).unwrap();
        let saved = engine.store.thread(&id).unwrap();
        assert_eq!(saved["draft"], "new draft");
        assert_eq!(saved["draftContext"], json!([other]));
        engine.remove_draft_context_card(&id, &changed).unwrap();
    }
    #[test]
    fn cancel_removes_only_the_exact_selected_path_card() {
        let directory = tempfile::tempdir().unwrap();
        let document = directory.path().join("notes.txt");
        std::fs::write(&document, "fixture").unwrap();
        let path = composer_context::PickedPath::inspect(&document).unwrap();
        let store = crate::store::Store::open(&directory.path().join("state.sqlite")).unwrap();
        let mut engine = Engine::fixture(store);
        let mut thread = engine.store.new_thread("").unwrap();
        thread["draft"] = json!("keep this draft");
        thread["items"] = json!([{ "id":"fixture", "kind":"user", "text":"keep history" }]);
        engine.store.save(&thread).unwrap();
        let id = thread["id"].as_str().unwrap();
        let card = engine.attach_picked_path(id, &path).unwrap();
        let second = engine.attach_picked_path(id, &path).unwrap();
        assert_ne!(second["id"], card["id"]);
        let saved = engine.store.thread(id).unwrap();
        assert_eq!(saved["draft"], "keep this draft");
        assert_eq!(saved["items"], thread["items"]);
        assert_eq!(saved["draftContext"], json!([card.clone(), second.clone()]));
        let mut changed = card.clone();
        changed["future"] = json!("preserved");
        let mut newer = saved;
        newer["draftContext"] = json!([changed.clone(), second.clone()]);
        engine.store.save(&newer).unwrap();
        engine.remove_cancelled_picked_path(id, &card).unwrap();
        assert_eq!(
            engine.store.thread(id).unwrap()["draftContext"],
            json!([changed.clone(), second.clone()])
        );
        engine.remove_cancelled_picked_path(id, &changed).unwrap();
        assert_eq!(
            engine.store.thread(id).unwrap()["draftContext"],
            json!([second])
        );
    }

    #[test]
    fn path_updates_preserve_navigation_draft_revision_and_roll_back_on_failure() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("state.sqlite");
        let store = crate::store::Store::open(&database).unwrap();
        let mut engine = Engine::fixture(store);
        let thread = engine.store.new_thread("").unwrap();
        let id = thread["id"].as_str().unwrap();
        let revision = engine.store.thread_with_draft_revision(id).unwrap().1;
        let folder = composer_context::PickedPath::inspect(directory.path()).unwrap();
        let card = engine.attach_picked_path(id, &folder).unwrap();
        assert_eq!(
            engine.store.thread_with_draft_revision(id).unwrap().1,
            revision
        );
        let navigation = engine
            .store
            .summaries("", false)
            .unwrap()
            .into_iter()
            .find(|row| row.id == id)
            .unwrap()
            .navigation
            .unwrap();
        assert_eq!(navigation.has_draft, Some(true));
        engine.remove_cancelled_picked_path(id, &card).unwrap();
        let navigation = engine
            .store
            .summaries("", false)
            .unwrap()
            .into_iter()
            .find(|row| row.id == id)
            .unwrap()
            .navigation
            .unwrap();
        assert_eq!(navigation.has_draft, Some(false));
        let before = engine.store.thread(id).unwrap();
        let db = rusqlite::Connection::open(&database).unwrap();
        db.execute_batch("CREATE TRIGGER fail_picked_path BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;").unwrap();
        assert!(engine.attach_picked_path(id, &folder).is_err());
        assert_eq!(engine.store.thread(id).unwrap(), before);
    }
}
