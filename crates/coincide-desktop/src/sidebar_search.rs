//! Sidebar search as Swift's sidebar does it: titles, branches and projects
//! scored by `palette_search` (word starts, words run together; no typos), and
//! threads whose messages hold the text once typing pauses for 250 ms. CLI
//! threads.list keeps its original literal query.
use super::*;
use crate::worker_owner::{ShutdownStatus, WorkerOwner};
use coincide_core::palette_search::{self, Field, Query};
use std::collections::HashMap;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
    mpsc::{self, Receiver, TryRecvError},
};

const MESSAGE_PAUSE: Duration = Duration::from_millis(250);

/// A project or bot name matches every word of the query at a word start.
pub(super) fn terms_match(value: &str, query: &str) -> bool {
    palette_search::score_terms(&Query::new(query), &Field::new(value), &[], false).is_some()
}

/// The message search behind the sidebar's results: it runs once typing
/// pauses. Only the latest query can publish results.
#[derive(Default)]
pub(super) struct MessageSearch {
    query: String,
    due: Option<Instant>,
    matches: HashMap<String, String>,
    generation: Arc<AtomicU64>,
    archived: Option<bool>,
    owner: WorkerOwner,
    reply: Option<Receiver<SearchReply>>,
}

struct SearchReply {
    generation: u64,
    query: String,
    include_archived: bool,
    outcome: SearchOutcome,
}

enum SearchOutcome {
    Found(HashMap<String, String>),
    Cancelled,
    Busy,
    Failed,
}

impl MessageSearch {
    /// The search field changed. Under two characters there is nothing to look for.
    pub(super) fn changed(&mut self, query: &str, now: Instant) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.query = query.to_owned();
        self.matches.clear();
        if query.trim().chars().count() < 2 {
            self.due = None;
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

    fn archive_changed(&mut self, include_archived: bool, now: Instant) -> bool {
        let changed = self
            .archived
            .replace(include_archived)
            .is_some_and(|old| old != include_archived);
        if changed {
            self.generation.fetch_add(1, Ordering::AcqRel);
            self.matches.clear();
            if self.query.trim().chars().count() >= 2 {
                self.due = Some(now);
            }
        }
        changed
    }

    fn start_due(&mut self, engine: &SharedEngine, include_archived: bool, now: Instant) {
        if self.reply.is_some() || !self.owner.can_start() {
            return;
        }
        let Some(query) = self.take_due(now) else {
            return;
        };
        let generation = self.generation.load(Ordering::Acquire);
        let current = self.generation.clone();
        let engine = engine.clone();
        let (sender, receiver) = mpsc::sync_channel(1);
        let retry_query = query.clone();
        if self.owner.spawn(move |admission| {
            let cancelled =
                || !admission.allowed() || current.load(Ordering::Acquire) != generation;
            let outcome = if cancelled() {
                SearchOutcome::Cancelled
            } else {
                let source = match engine.try_lock() {
                    Ok(engine) if !engine.shutdown && !engine.admissions_frozen() => engine
                        .store
                        .message_search_source()
                        .map_err(|_| SearchOutcome::Failed),
                    Ok(_) => Err(SearchOutcome::Cancelled),
                    Err(std::sync::TryLockError::WouldBlock) => Err(SearchOutcome::Busy),
                    Err(std::sync::TryLockError::Poisoned(_)) => Err(SearchOutcome::Failed),
                };
                match source {
                    Ok(source) => match source.search(&query, include_archived, cancelled) {
                        Ok(Some(found)) => SearchOutcome::Found(found),
                        Ok(None) => SearchOutcome::Cancelled,
                        Err(_) => SearchOutcome::Failed,
                    },
                    Err(outcome) => outcome,
                }
            };
            let _ = sender.try_send(SearchReply {
                generation,
                query,
                include_archived,
                outcome,
            });
        }) {
            self.reply = Some(receiver);
        } else if self.query == retry_query {
            self.retry(now);
        }
    }

    fn poll(&mut self, include_archived: bool, now: Instant) -> Option<bool> {
        self.owner.poll();
        let receiver = self.reply.as_ref()?;
        let reply = match receiver.try_recv() {
            Ok(reply) => reply,
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => {
                self.reply = None;
                return Some(false);
            }
        };
        self.reply = None;
        if reply.generation != self.generation.load(Ordering::Acquire)
            || reply.query != self.query
            || reply.include_archived != include_archived
        {
            return None;
        }
        match reply.outcome {
            SearchOutcome::Found(matches) => Some(self.finish(&reply.query, matches)),
            SearchOutcome::Busy => {
                self.retry(now);
                None
            }
            SearchOutcome::Cancelled => None,
            SearchOutcome::Failed => Some(false),
        }
    }

    pub(super) fn shutdown(&mut self) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.due = None;
        self.reply = None;
        self.owner.close();
    }

    /// Cancel an in-flight read without permanently disabling search if a
    /// window-close attempt is held up by another workflow.
    pub(super) fn prepare_window_close(&mut self) -> bool {
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.reply = None;
        self.due = (self.query.trim().chars().count() >= 2).then(|| Instant::now() + MESSAGE_PAUSE);
        let status = self.owner.status();
        status.unjoined == 0 && status.panicked == 0 && status.unclassified == 0
    }

    pub(super) fn shutdown_status(&mut self) -> ShutdownStatus {
        self.owner.status()
    }

    pub(super) fn closed_and_drained(&mut self) -> bool {
        let status = self.shutdown_status();
        status.closed && status.unjoined == 0 && status.panicked == 0 && status.unclassified == 0
    }
}

pub(super) fn read(
    engine: &SharedEngine,
    reader: Option<&coincide_core::store::ThreadNavigationReader>,
    query: &str,
    include_archived: bool,
    projects: &[Value],
    messages: &HashMap<String, String>,
    branch_prefix: &str,
) -> Result<(Vec<ThreadSummary>, Vec<ThreadSummary>)> {
    let all = match try_state(engine) {
        Ok(owner) => owner.store.summaries("", true)?,
        Err(error) if engine_busy(&error) => {
            reader.map_or(Err(error), |reader| reader.summaries())?
        }
        Err(error) => return Err(error),
    };
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
            if palette_search::score_terms(query, &Field::new(project), &[], false).is_some()
                || messages.contains_key(&thread.id)
            {
                return true;
            }
            let navigation = thread.navigation.as_ref();
            // The worktree prefix is not part of what a branch says.
            let branch = navigation
                .and_then(|meta| meta.branch.as_deref())
                .map(|branch| branch.strip_prefix(branch_prefix).unwrap_or(branch))
                .unwrap_or("");
            palette_search::score_thread(
                query,
                &Field::new(&thread.title),
                &Field::new(branch),
                &Field::new(project),
                navigation.and_then(|meta| meta.updated_at).unwrap_or(0.),
                now,
                false,
            )
            .is_some()
        })
        .cloned()
        .collect()
}

impl Coincide {
    pub(super) fn refresh_cached_sidebar_search(&mut self, cx: &mut Context<Self>) {
        let query = self.search.read(cx).value();
        self.threads = filter(
            &self.sidebar_all_threads,
            &Query::new(&query),
            self.show_archived,
            &self.projects,
            self.sidebar_message_search.matches(),
            &self.sidebar_branch_prefix(),
            coincide_core::store::swift_timestamp(),
        );
        cx.notify();
    }
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
        let archive_changed = self
            .sidebar_message_search
            .archive_changed(self.show_archived, now);
        match self.sidebar_message_search.poll(self.show_archived, now) {
            Some(true) => self.refresh_cached_sidebar_search(cx),
            Some(false) => {
                self.status = "Messages could not be searched.".into();
                cx.notify();
            }
            None if archive_changed => self.refresh_cached_sidebar_search(cx),
            None => {}
        }
        self.sidebar_message_search
            .start_due(&self.engine, self.show_archived, now);
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

    #[test]
    fn saved_sidebar_rows_are_available_while_the_engine_is_busy() {
        let directory = tempfile::tempdir().unwrap();
        let store = coincide_core::store::Store::open(&directory.path().join("sidebar.sqlite")).unwrap();
        let reader = store.thread_navigation_reader().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let mut busy = engine.lock().unwrap();
        let created = busy.dispatch_desktop(json!({"method":"threads.create","params":{}}));
        let id = created["result"]["id"].as_str().unwrap();

        let (visible, all) = read(&engine, Some(&reader), "", false, &[], &HashMap::new(), "")
            .expect("a busy engine should not block committed sidebar rows");
        assert_eq!(visible.len(), 1);
        assert_eq!(visible[0].id, id);
        assert_eq!(all.len(), 1);
    }

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

    #[::core::prelude::v1::test]
    fn background_message_search_retries_a_busy_engine_and_discards_superseded_queries() {
        let root = tempfile::tempdir().unwrap();
        let mut store =
            coincide_core::store::Store::open(&root.path().join("search.sqlite")).unwrap();
        let old_id = "11111111-1111-4111-8111-111111111111";
        let new_id = "22222222-2222-4222-8222-222222222222";
        for (id, text) in [(old_id, "previous phrase"), (new_id, "current phrase")] {
            store.save(&json!({"id":id,"title":"Synthetic","projectID":"","items":[{"kind":"user","text":text}],"updatedAt":1.0})).unwrap();
        }
        let engine = Arc::new(std::sync::Mutex::new(coincide_core::api::Engine::new(
            store,
        )));
        let mut search = MessageSearch::default();
        let start = Instant::now();
        search.archive_changed(false, start);
        search.changed("previous", start);
        let held = engine.lock().unwrap();
        search.start_due(&engine, false, start + MESSAGE_PAUSE);
        // Starting a search while the engine is locked must not wait for it.
        search.changed("current", start);
        drop(held);
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let now = Instant::now() + MESSAGE_PAUSE;
            if search.poll(false, now) == Some(true) {
                break;
            }
            search.start_due(&engine, false, now);
            assert!(Instant::now() < deadline, "latest search did not finish");
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(search.line(new_id), Some("current phrase"));
        assert!(search.line(old_id).is_none());
        // An interrupted window close must not permanently disable searching.
        search.prepare_window_close();
        search.changed("previous", Instant::now());
        loop {
            let now = Instant::now() + MESSAGE_PAUSE;
            if search.poll(false, now) == Some(true) {
                break;
            }
            search.start_due(&engine, false, now);
            assert!(
                Instant::now() < deadline,
                "search did not resume after close was held"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(search.line(old_id), Some("previous phrase"));
        search.shutdown();
        while !search.closed_and_drained() {
            assert!(Instant::now() < deadline, "search worker did not drain");
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}
