//! Only the owning native view can submit an actual rendered selection. Saved
//! item text, selected conversation, draft and context are checked again here.
use super::*;
use crate::{composer_context::ExpectedContext, reply_selection::NativeReplySelection};
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
        let result = self.store.commit_selected_reply(
            &id,
            Some(expected_draft),
            &expected_context,
            &selection,
        )?;
        self.revision += 1;
        Ok(result)
    }

    /// A native selection adds context independently of a draft that is still
    /// being typed; the store changes only context and validates the source.
    pub fn native_attach_reply_selection_preserve_draft(
        &mut self,
        thread_id: &str,
        expected_context: ExpectedContext,
        selection: NativeReplySelection,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let uuid = Uuid::parse_str(thread_id)?;
        // The native view captured this target before starting the worker.
        // A later navigation must not retarget or cancel the user's reply.
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
        let result = self
            .store
            .commit_selected_reply(&id, None, &expected_context, &selection)?;
        self.revision += 1;
        Ok(result)
    }
}

#[cfg(test)]
#[path = "reply_selection_tests.rs"]
mod tests;
