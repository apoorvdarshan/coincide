//! Trusted optimistic context editor; parent registers one narrow dispatch arm.
use super::*;
use crate::composer_context::{self, Edit, ExpectedContext};
impl Engine {
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
