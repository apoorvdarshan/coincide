//! Local bookmark operations. Paths and credentials never enter this API.
use super::*;
use crate::browser_bookmarks::{self, ImportResult, Library, Plan};
impl Engine {
    /// Trusted parent calls this off UI under its one nonblocking Engine guard.
    pub fn saved_browser_bookmarks(&self) -> Result<Library> {
        self.require_admissions()?;
        Library::from_document(self.store.local_document(browser_bookmarks::DOCUMENT)?)
    }
    pub fn import_browser_bookmarks(
        &mut self,
        expected_revision: u64,
        plan: &Plan,
    ) -> Result<ImportResult> {
        self.require_admissions()?;
        let library = self.saved_browser_bookmarks()?;
        let result = library.merge(expected_revision, plan)?;
        if result.added > 0 {
            self.store.save_document(
                browser_bookmarks::DOCUMENT,
                &serde_json::to_value(&result.library)?,
            )?;
            self.revision += 1;
        }
        Ok(result)
    }
    /// Explicit user action only: resolve current saved identity, then enqueue
    /// ordinary desktop bridge work. This thread never performs native IO.
    pub fn open_browser_bookmark(
        &mut self,
        thread_id: &str,
        id: Uuid,
        revision: u64,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(self.ui_available, "Bookmarks open in the desktop browser");
        let thread = self.store.thread(thread_id)?;
        let thread = text(&thread, "id");
        ensure!(
            self.active_thread() == Some(thread.as_str()),
            "Selected thread changed; reopen bookmarks"
        );
        let library = self.saved_browser_bookmarks()?;
        let bookmark = library.selected(id, revision)?;
        let url = browser_bookmarks::validate_url(&bookmark.url)?;
        ensure!(
            self.browser_pending.len() <= 126,
            "Browser queue is busy; nothing opened"
        );
        let navigate = self.execute(
            "browser.request",
            &json!({"threadId":thread,"action":"new-tab","url":url}),
        )?;
        let show = self.execute(
            "browser.request",
            &json!({"threadId":thread,"action":"show"}),
        )?;
        Ok(
            json!({"navigateOperationId":navigate["operationId"],"showOperationId":show["operationId"],"threadId":thread}),
        )
    }
    pub(super) fn browser_bookmarks_command(
        &mut self,
        method: &str,
        params: &Value,
    ) -> Result<Value> {
        let fields = params
            .as_object()
            .context("Bookmark parameters must be an object")?;
        match method {
            "browser.bookmarks.list" => {
                ensure!(fields.is_empty(), "Bookmark list accepts no options");
                Ok(serde_json::to_value(self.saved_browser_bookmarks()?)?)
            }
            "browser.bookmarks.import" => {
                ensure!(
                    fields
                        .keys()
                        .all(|key| matches!(key.as_str(), "expectedRevision" | "plan")),
                    "Unsupported bookmark import fields"
                );
                let expected = params["expectedRevision"]
                    .as_u64()
                    .context("Expected bookmark revision required")?;
                let plan: Plan = serde_json::from_value(params["plan"].clone())
                    .context("Invalid bookmark import plan")?;
                Ok(serde_json::to_value(
                    self.import_browser_bookmarks(expected, &plan)?,
                )?)
            }
            "browser.bookmarks.open" => {
                ensure!(
                    fields.keys().all(|key| matches!(
                        key.as_str(),
                        "threadId" | "bookmarkId" | "expectedRevision"
                    )),
                    "Unsupported bookmark open fields"
                );
                self.open_browser_bookmark(
                    required(params, "threadId")?,
                    Uuid::parse_str(required(params, "bookmarkId")?)?,
                    params["expectedRevision"]
                        .as_u64()
                        .context("Expected bookmark revision required")?,
                )
            }
            _ => bail!("Unknown bookmark command"),
        }
    }
}
