//! Explicit selected terminal display data, never client text or execution authority.
use super::*;
use crate::{
    composer_context::{self, ExpectedContext},
    terminal::TerminalPoint,
};
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    thread_id: String,
    expected_draft: String,
    expected_context: ExpectedContext,
    terminal_id: String,
    revision: u64,
    start: Point,
    end: Point,
}
#[derive(Clone, Copy, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Point {
    row: usize,
    col: usize,
}
impl From<Point> for TerminalPoint {
    fn from(point: Point) -> Self {
        Self {
            row: point.row,
            col: point.col,
        }
    }
}
impl Engine {
    pub fn attach_terminal_selection(&mut self, params: &Value) -> Result<Value> {
        self.require_admissions()?;
        let request: Request = serde_json::from_value(params.clone())?;
        ensure!(
            request.expected_draft.len() <= 1024 * 1024,
            "Draft exceeds terminal reference bounds"
        );
        let uuid = Uuid::parse_str(&request.thread_id)?;
        let id = self
            .store
            .resolve_thread_id(uuid)?
            .context("Conversation not found")?;
        ensure!(
            self.active_thread().and_then(|id| Uuid::parse_str(id).ok()) == Some(uuid),
            "Terminal context target is no longer selected"
        );
        ensure!(
            !self
                .unsaved_threads
                .keys()
                .any(|id| Uuid::parse_str(id).ok() == Some(uuid)),
            "Transcript persistence is recovering"
        );
        ensure!(
            !self.store.is_imported(&id)?,
            "Fork an imported thread before attaching terminal output"
        );
        let source = self.store.terminal_context_source(&id)?;
        ensure!(
            source.len() <= 8 * 1024 * 1024,
            "Conversation exceeds terminal reference bounds"
        );
        let thread: Value = serde_json::from_str(&source)?;
        ensure!(
            text(&thread, "draft") == request.expected_draft
                && request.expected_context.matches(&thread),
            "Draft or attached context changed; select terminal text again"
        );
        let (owner, terminal) = self
            .terminals
            .get_mut(&request.terminal_id)
            .context("Terminal is no longer available")?;
        ensure!(
            Uuid::parse_str(owner).ok() == Some(uuid),
            "Terminal belongs to another conversation"
        );
        // The real screen owns hidden/wide/combining filtering and exact viewport revision.
        let selected =
            terminal.copy_selection(request.revision, request.start.into(), request.end.into())?;
        let next = composer_context::append_terminal_selection(
            thread.get("draftContext").unwrap_or(&Value::Null),
            &selected,
        )?;
        self.store.commit_terminal_context(&id, &source, &next)?;
        self.revision += 1;
        Ok(json!({"threadId":id,"draftContext":next,"bytes":selected.len()}))
    }
}
