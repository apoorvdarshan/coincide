//! Only the owning native view can submit an actual rendered selection. Saved
//! item text, selected conversation, draft and context are checked again here.
use super::*;
use crate::{
    composer_context::{self, ExpectedContext},
    reply_selection::NativeReplySelection,
};
impl Engine {
    pub fn native_attach_reply_selection(
        &mut self,
        thread_id: &str,
        expected_draft: &str,
        expected_context: ExpectedContext,
        selection: NativeReplySelection,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let uuid = Uuid::parse_str(thread_id)?;
        ensure!(
            self.active_thread().and_then(|id| Uuid::parse_str(id).ok()) == Some(uuid),
            "Reply selection target is no longer selected"
        );
        let id = self
            .store
            .resolve_thread_id(uuid)?
            .context("Conversation not found")?;
        ensure!(
            !self
                .unsaved_threads
                .keys()
                .any(|key| Uuid::parse_str(key).ok() == Some(uuid)),
            "Transcript persistence is recovering"
        );
        ensure!(
            !self.store.is_imported(&id)?,
            "Fork imported history before attaching reply text"
        );
        let source = self.store.native_reply_context_source(&id)?;
        let thread: Value = serde_json::from_str(&source)?;
        ensure!(
            thread["isArchived"] != true,
            "Archived conversations cannot receive reply quotes"
        );
        ensure!(
            expected_draft.len() <= 1024 * 1024
                && text(&thread, "draft") == expected_draft
                && expected_context.matches(&thread),
            "Composer changed; select the reply text again"
        );
        let mut matching = thread["items"]
            .as_array()
            .context("Transcript is malformed")?
            .iter()
            .filter(|item| {
                item["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(selection.item)
            });
        let item = matching
            .next()
            .context("Selected reply is no longer available")?;
        ensure!(matching.next().is_none(), "Reply identity is ambiguous");
        ensure!(
            item["kind"] == "assistant" && item["text"].as_str() == Some(selection.source.as_str()),
            "The actual reply changed; select its text again"
        );
        let mut quoted = item.clone();
        quoted["text"] = json!(selection.quote()?);
        let next = composer_context::append_quote(
            thread.get("draftContext").unwrap_or(&Value::Null),
            &quoted,
        )?;
        self.store
            .commit_native_reply_context(&id, &source, &next)?;
        self.revision += 1;
        Ok(json!({"threadId":id,"draftContext":next}))
    }
}

#[cfg(test)]
#[path = "reply_selection_tests.rs"]
mod tests;
