//! Sidebar search as Swift's sidebar does it: titles, branches and projects
//! scored by `palette_search` (word starts, words run together; no typos), and
//! threads whose messages hold the text once typing pauses for 250 ms. CLI
//! threads.list keeps its original literal query.
use super::*;
use coincide_core::palette_search::{self, Query};
use std::collections::HashMap;

const MESSAGE_PAUSE: Duration = Duration::from_millis(250);

/// A project or bot name matches every word of the query at a word start.
pub(super) fn terms_match(value: &str, query: &str) -> bool {
    palette_search::score_terms(&Query::new(query), value, &[], false).is_some()
}

/// The message search behind the sidebar's results: it runs once typing
/// pauses, and earlier matches stay until it replaces them.
#[derive(Default)]
pub(super) struct MessageSearch {
    query: String,
    due: Option<Instant>,
    matches: HashMap<String, String>,
}
impl MessageSearch {
    /// The search field changed. Under two characters there is nothing to look for.
    pub(super) fn changed(&mut self, query: &str, now: Instant) {
        self.query = query.to_owned();
        if query.trim().chars().count() < 2 {
            self.due = None;
            self.matches.clear();
        } else {
            self.due = Some(now + MESSAGE_PAUSE);
        }
    }
    /// The query to search messages for, once its pause has passed.
    pub(super) fn take_due(&mut self, now: Instant) -> Option<String> {
        if self.due.is_some_and(|due| due <= now) {
            self.due = None;
            Some(self.query.clone())
        } else {
            None
        }
    }
    /// Try again on the next pass, as when the engine was busy.
    pub(super) fn retry(&mut self, now: Instant) {
        self.due = Some(now);
    }
    /// Results for `query`, unless the field has changed since.
    pub(super) fn finish(&mut self, query: &str, matches: HashMap<String, String>) -> bool {
        if query != self.query {
            return false;
        }
        self.matches = matches;
        true
    }
    pub(super) fn matches(&self) -> &HashMap<String, String> {
        &self.matches
    }
    /// The matching line, for the row's tooltip while searching.
    pub(super) fn line(&self, id: &str) -> Option<&str> {
        self.matches.get(id).map(String::as_str)
    }
}

pub(super) fn read(
    engine: &SharedEngine,
    query: &str,
    include_archived: bool,
    projects: &[Value],
    messages: &HashMap<String, String>,
    branch_prefix: &str,
) -> Result<(Vec<ThreadSummary>, Vec<ThreadSummary>)> {
    let owner = try_state(engine)?;
    let all = owner.store.summaries("", true)?;
    let visible = filter(
        &all,
        &Query::new(query),
        include_archived,
        projects,
        messages,
        branch_prefix,
        coincide_core::store::swift_timestamp(),
    );
    Ok((visible, all))
}

/// Every thread of a project whose name matches, plus threads whose title,
/// branch and project together match or whose messages hold the text.
fn filter(
    all: &[ThreadSummary],
    query: &Query,
    include_archived: bool,
    projects: &[Value],
    messages: &HashMap<String, String>,
    branch_prefix: &str,
    now: f64,
) -> Vec<ThreadSummary> {
    let names: HashMap<String, String> = projects
        .iter()
        .map(|project| (text(project, "id").to_lowercase(), text(project, "name")))
        .collect();
    all.iter()
        .filter(|thread| {
            if thread.archived && !include_archived {
                return false;
            }
            if query.is_empty() {
                return true;
            }
            let project = names
                .get(&thread.project_id.to_lowercase())
                .map(String::as_str)
                .unwrap_or("");
            if palette_search::score_terms(query, project, &[], false).is_some()
                || messages.contains_key(&thread.id)
            {
                return true;
            }
            let navigation = thread.navigation.as_ref();
            palette_search::score_thread(
                query,
                &thread.title,
                navigation.and_then(|meta| meta.branch.as_deref()),
                Some(project),
                navigation.and_then(|meta| meta.updated_at).unwrap_or(0.),
                false,
                branch_prefix,
                now,
            )
            .is_some()
        })
        .cloned()
        .collect()
}

impl Coincide {
    /// The worktree branch prefix, left out of what a branch says.
    pub(super) fn sidebar_branch_prefix(&self) -> String {
        self.settings["worktreeBranchPrefix"]
            .as_str()
            .unwrap_or("coincide/")
            .to_owned()
    }
    /// Runs the message search once typing has paused, then lists its threads.
    pub(super) fn poll_sidebar_message_search(&mut self, cx: &mut Context<Self>) {
        let now = Instant::now();
        let Some(query) = self.sidebar_message_search.take_due(now) else {
            return;
        };
        let result = try_state(&self.engine)
            .and_then(|owner| owner.store.message_matches(&query, self.show_archived));
        match result {
            Ok(matches) => {
                if self.sidebar_message_search.finish(&query, matches) {
                    self.refresh(cx);
                }
            }
            Err(error) if engine_busy(&error) => self.sidebar_message_search.retry(now),
            Err(error) => self.status = format!("Messages could not be searched: {error}"),
        }
    }
    /// Edit › Find › Search Threads (Option-Command-F; Control-Alt-F elsewhere):
    /// shows the thread list and puts the cursor in its search field.
    pub(super) fn sidebar_search_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let key = &event.keystroke;
        let command = if cfg!(target_os = "macos") {
            key.modifiers.platform && !key.modifiers.control
        } else {
            key.modifiers.control && !key.modifiers.platform
        };
        if event.is_held
            || !window.is_window_active()
            || !command
            || !key.modifiers.alt
            || key.modifiers.shift
            || !key.key.eq_ignore_ascii_case("f")
            || self.command_palette.read(cx).is_open()
        {
            return false;
        }
        self.focus_sidebar_search(window, cx);
        cx.stop_propagation();
        true
    }
    pub(super) fn focus_sidebar_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.thread_list_open {
            self.toggle_sidebar(window, cx);
        }
        self.search.read(cx).focus_handle(cx).focus(window, cx);
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(
        id: &str,
        title: &str,
        project: &str,
        branch: Option<&str>,
        archived: bool,
    ) -> ThreadSummary {
        serde_json::from_value(json!({"id":id,"title":title,"project_id":project,"pinned":false,"archived":archived,"snoozed_until":null,"navigation":{"branch":branch}})).unwrap()
    }
    fn ids(rows: Vec<ThreadSummary>) -> Vec<String> {
        rows.into_iter().map(|row| row.id).collect()
    }

    #[::core::prelude::v1::test]
    fn search_scores_titles_branches_projects_and_message_matches() {
        let projects = vec![
            json!({"id":"P","name":"Coincide"}),
            json!({"id":"Q","name":"Website"}),
        ];
        let all = vec![
            row("title", "Fix sidebar lag", "q", None, false),
            row(
                "branch",
                "Notes",
                "q",
                Some("coincide/sidebar-search"),
                false,
            ),
            row("project", "Anything", "p", None, false),
            row("message", "Unrelated", "q", None, false),
            row("archived", "Fix sidebar lag", "q", None, true),
            row("inside", "Considerable work", "q", None, false),
        ];
        let messages = HashMap::from([("message".to_owned(), "the needle".to_owned())]);
        let find = |query: &str, archived| {
            ids(filter(
                &all,
                &Query::new(query),
                archived,
                &projects,
                &messages,
                "coincide/",
                0.,
            ))
        };
        assert_eq!(find("sid", false), ["title", "branch", "message"]);
        // A project's name lists all of its threads.
        assert_eq!(find("coincide", false), ["project", "message"]);
        // The worktree prefix is not part of what a branch says.
        assert_eq!(find("coincide sidebar", false), ["message"]);
        assert_eq!(find("fixsid", true), ["title", "message", "archived"]);
        // Four letters may match inside a title's word, never a branch's.
        assert_eq!(
            find("side", false),
            ["title", "branch", "message", "inside"]
        );
        assert_eq!(find("", false).len(), 5);
        assert!(terms_match("Project 12", "12 project"));
        assert!(!terms_match("Project 12", "12 missing"));
        assert!(!terms_match("Considerable", "side"));
    }

    #[::core::prelude::v1::test]
    fn message_search_waits_for_a_pause_and_keeps_only_current_results() {
        let start = Instant::now();
        let mut search = MessageSearch::default();
        search.changed("ne", start);
        assert!(search.take_due(start).is_none());
        assert_eq!(
            search.take_due(start + MESSAGE_PAUSE).as_deref(),
            Some("ne")
        );
        assert!(search.take_due(start + MESSAGE_PAUSE).is_none());
        search.changed("needle", start);
        // Results for text the field no longer holds are dropped.
        assert!(!search.finish("ne", HashMap::from([("a".into(), "x".into())])));
        assert!(search.finish("needle", HashMap::from([("b".into(), "line".into())])));
        assert_eq!(search.line("b"), Some("line"));
        search.changed(" n ", start);
        assert!(search.matches().is_empty());
        assert!(search.take_due(start + MESSAGE_PAUSE).is_none());
    }
}
