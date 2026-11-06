//! Local bookmark operations. Paths and credentials never enter this API.
use super::*;
use crate::browser_bookmarks::{self, ImportResult, Library, Plan};
/// Native-parent-only proof of an off-UI saved bookmark resolution. It cannot
/// be deserialized from JSON or cloned/replayed after admission.
pub struct PreparedBookmarkOpen {
    owner: Uuid,
    engine_revision: u64,
    thread: String,
    url: String,
}
pub struct QueuedBookmarkOpen {
    pub thread: String,
    pub navigate_operation: String,
    pub show_operation: String,
}
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
    /// Resolve saved data off UI. This does not queue anything or change state.
    pub fn prepare_browser_bookmark(
        &self,
        thread_id: &str,
        id: Uuid,
        revision: u64,
    ) -> Result<PreparedBookmarkOpen> {
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
        Ok(PreparedBookmarkOpen {
            owner: self.bookmark_owner,
            engine_revision: self.revision,
            thread,
            url,
        })
    }
    /// Parent calls only after fresh native visibility/selection checks. This
    /// consumes an opaque proof with memory checks only (including Store's
    /// closed flag), never Store I/O, files or the native backend.
    pub fn admit_prepared_bookmark(
        &mut self,
        prepared: PreparedBookmarkOpen,
    ) -> Result<QueuedBookmarkOpen> {
        self.require_admissions()?;
        ensure!(self.ui_available, "Bookmarks open in the desktop browser");
        ensure!(
            !self.store.is_closed(),
            "Store is closed; bookmark was not opened"
        );
        ensure!(
            prepared.owner == self.bookmark_owner && prepared.engine_revision == self.revision,
            "The app changed while preparing this bookmark; click Open again"
        );
        ensure!(
            self.active_thread() == Some(prepared.thread.as_str()),
            "Selected thread changed; bookmark was not opened"
        );
        ensure!(
            self.browser_pending.len() <= 126,
            "Browser queue is busy; nothing opened"
        );
        let next_revision = self
            .revision
            .checked_add(2)
            .context("Browser revision exhausted")?;
        let navigate = Uuid::new_v4().to_string();
        let show = Uuid::new_v4().to_string();
        let thread = prepared.thread;
        for (id, action) in [
            (
                navigate.clone(),
                crate::browser_protocol::BrowserAction::NewTab {
                    url: Some(prepared.url),
                },
            ),
            (show.clone(), crate::browser_protocol::BrowserAction::Show),
        ] {
            self.browser_pending
                .insert(id.clone(), (thread.clone(), Instant::now()));
            self.browser_requests
                .push_back(crate::browser_protocol::BrowserRequest {
                    id,
                    thread_id: thread.clone(),
                    tab: None,
                    frame: None,
                    action,
                });
        }
        self.revision = next_revision;
        Ok(QueuedBookmarkOpen {
            thread,
            navigate_operation: navigate,
            show_operation: show,
        })
    }
    /// Explicit owner API action: no Settings visibility authority is inferred.
    /// Provider-scoped channels cannot invoke this owner-only route.
    pub fn open_browser_bookmark(
        &mut self,
        thread_id: &str,
        id: Uuid,
        revision: u64,
    ) -> Result<Value> {
        let prepared = self.prepare_browser_bookmark(thread_id, id, revision)?;
        let queued = self.admit_prepared_bookmark(prepared)?;
        Ok(
            json!({"navigateOperationId":queued.navigate_operation,"showOperationId":queued.show_operation,"threadId":queued.thread}),
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
