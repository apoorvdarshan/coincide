//! Track a requested conversation separately from the last loaded view.
//! A delayed read must never replace a newer navigation request.
use anyhow::Result;
use coincide_core::{
    api::SharedEngine,
    store::{ThreadNavigationReader, ThreadSummary},
};
use serde_json::Value;
use std::{
    collections::VecDeque,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

/// Read and decode on the worker. A streaming or busy engine does not delay
/// opening a different saved thread.
pub(super) fn read(
    engine: &SharedEngine,
    reader: Option<&ThreadNavigationReader>,
    id: &str,
    current: &AtomicU64,
    generation: u64,
) -> Result<Option<Value>> {
    if current.load(Ordering::Acquire) != generation {
        return Ok(None);
    }
    if let Some(reader) = reader {
        if let Ok(engine) = engine.try_lock() {
            anyhow::ensure!(
                !engine.shutdown && !engine.admissions_frozen(),
                "App is closing"
            );
            if let Some(thread) = engine.unsaved_thread_for_navigation(id) {
                return Ok((current.load(Ordering::Acquire) == generation).then_some(thread));
            }
        }
        let thread = reader.read(id)?;
        return Ok((current.load(Ordering::Acquire) == generation).then_some(thread));
    }
    let snapshot = {
        let engine = engine
            .lock()
            .map_err(|_| anyhow::anyhow!("App engine is unavailable"))?;
        if current.load(Ordering::Acquire) != generation {
            return Ok(None);
        }
        anyhow::ensure!(
            !engine.shutdown && !engine.admissions_frozen(),
            "App is closing"
        );
        engine.capture_thread_read(id)?.1
    };
    if current.load(Ordering::Acquire) != generation {
        return Ok(None);
    }
    snapshot.decode().map(Some)
}

/// Never commit a delayed new-chat request after the user navigates away.
pub(super) fn create(
    engine: &SharedEngine,
    request: &Value,
    current_generation: &AtomicU64,
    generation: u64,
) -> Result<Option<Value>> {
    let mut engine = engine
        .lock()
        .map_err(|_| anyhow::anyhow!("App engine is unavailable"))?;
    if current_generation.load(Ordering::Acquire) != generation {
        return Ok(None);
    }
    anyhow::ensure!(
        !engine.shutdown && !engine.admissions_frozen(),
        "App is closing"
    );
    let intent = engine.prepare_native_new_thread(request)?;
    if current_generation.load(Ordering::Acquire) != generation {
        return Ok(None);
    }
    engine.apply_native_new_thread(intent).map(Some)
}

#[derive(Default)]
pub(super) struct State {
    generation: Arc<AtomicU64>,
    target: Option<String>,
    ready: Option<Value>,
    focus_composer: bool,
    reader: Option<ThreadNavigationReader>,
    recent: VecDeque<Value>,
}

impl State {
    pub fn reader(&mut self, engine: &SharedEngine) -> Option<ThreadNavigationReader> {
        if self.reader.is_none() {
            self.reader = engine.try_lock().ok()?.store.thread_navigation_reader();
        }
        self.reader.clone()
    }

    pub fn remember(&mut self, thread: Value) {
        // Keep a few recently used views without copying their transcripts.
        // Very large conversations continue through the background read.
        if thread["isArchived"] == true
            || thread["items"]
                .as_array()
                .is_none_or(|items| items.len() > 4_000)
        {
            return;
        }
        self.recent
            .retain(|previous| previous["id"] != thread["id"]);
        self.recent.push_front(thread);
        self.recent.truncate(4);
    }

    pub fn take_recent(&mut self, id: &str, summaries: &[ThreadSummary]) -> Option<Value> {
        let index = self.recent.iter().position(|thread| thread["id"] == id)?;
        let thread = self.recent.remove(index)?;
        let summary = summaries.iter().find(|summary| summary.id == id)?;
        let navigation = summary.navigation.as_ref()?;
        (!summary.archived
            && summary.title == thread["title"]
            && navigation.updated_at == thread["updatedAt"].as_f64()
            && navigation.item_count == thread["items"].as_array().map(Vec::len))
        .then_some(thread)
    }

    pub fn begin(&mut self, id: &str) -> u64 {
        let generation = self
            .generation
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1);
        self.target = Some(id.to_owned());
        self.ready = None;
        self.focus_composer = false;
        generation
    }

    pub fn target(&self) -> Option<&str> {
        self.target.as_deref()
    }

    pub fn matches(&self, generation: u64, id: &str) -> bool {
        self.generation.load(Ordering::Acquire) == generation && self.target() == Some(id)
    }

    pub fn cancellation(&self) -> Arc<AtomicU64> {
        self.generation.clone()
    }

    pub fn finish(&mut self, generation: u64, id: &str, thread: Value) -> bool {
        if !self.matches(generation, id) || thread["id"].as_str() != Some(id) {
            return false;
        }
        self.ready = Some(thread);
        true
    }

    pub fn waiting(&self, id: &str) -> bool {
        self.target() == Some(id) && self.ready.is_none()
    }

    pub fn take(&mut self, id: &str) -> Option<Value> {
        (self.target() == Some(id))
            .then(|| self.ready.take())
            .flatten()
    }

    pub fn focus_composer_when_ready(&mut self, id: &str) {
        if self.target() == Some(id) {
            self.focus_composer = true;
        }
    }

    pub fn should_focus_composer(&self, id: &str) -> bool {
        self.target() == Some(id) && self.focus_composer
    }

    pub fn cancel(&mut self) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.target = None;
        self.ready = None;
        self.focus_composer = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::{api::Engine, store::Store};
    use serde_json::json;
    use std::sync::{Arc, Mutex};

    #[test]
    fn only_the_latest_matching_thread_can_finish() {
        let mut state = State::default();
        let first = state.begin("a");
        let second = state.begin("b");
        assert!(!state.finish(first, "a", json!({"id":"a"})));
        assert!(!state.finish(second, "b", json!({"id":"a"})));
        assert!(state.waiting("b"));
        assert!(state.finish(second, "b", json!({"id":"b","draft":"kept"})));
        assert_eq!(state.take("b").unwrap()["draft"], "kept");
        state.cancel();
        assert!(!state.finish(second, "b", json!({"id":"b"})));
    }

    #[test]
    fn cancelled_creation_waiting_for_engine_does_not_create_a_chat() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&dir.path().join("synthetic.sqlite")).unwrap(),
        )));
        let locked = engine.lock().unwrap();
        let generation = Arc::new(AtomicU64::new(1));
        let worker_engine = engine.clone();
        let worker_generation = generation.clone();
        let cwd = dir.path().to_path_buf();
        let worker = std::thread::spawn(move || {
            create(
                &worker_engine,
                &json!({"projectId":"00000000-0000-0000-0000-000000000000","cwd":cwd}),
                &worker_generation,
                1,
            )
        });
        generation.store(2, Ordering::Release);
        drop(locked);
        assert!(worker.join().unwrap().unwrap().is_none());
        assert!(
            engine
                .lock()
                .unwrap()
                .store
                .summaries("", false)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn created_chat_can_be_read_and_idle_reuse_is_preserved() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&dir.path().join("synthetic.sqlite")).unwrap(),
        )));
        let generation = AtomicU64::new(3);
        let request = json!({"projectId":"00000000-0000-0000-0000-000000000000","cwd":dir.path()});
        let created = create(&engine, &request, &generation, 3).unwrap().unwrap();
        let id = created["id"].as_str().unwrap();
        assert_eq!(
            read(&engine, None, id, &generation, 3).unwrap().unwrap(),
            created
        );
        assert_eq!(
            create(&engine, &request, &generation, 3).unwrap().unwrap()["id"],
            id
        );
    }

    #[test]
    fn saved_navigation_reads_while_the_engine_is_locked() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("synthetic.sqlite")).unwrap();
        let thread = store.new_thread("").unwrap();
        store.save(&thread).unwrap();
        let reader = store.thread_navigation_reader().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let _busy = engine.lock().unwrap();
        assert_eq!(
            read(
                &engine,
                Some(&reader),
                thread["id"].as_str().unwrap(),
                &AtomicU64::new(1),
                1
            )
            .unwrap(),
            Some(thread)
        );
    }

    #[test]
    fn recent_navigation_reuses_a_matching_view_and_discards_deleted_or_changed_views() {
        let thread = json!({"id":"a","title":"A","updatedAt":1.0,"items":[]});
        let summary = ThreadSummary {
            id: "a".into(),
            title: "A".into(),
            project_id: String::new(),
            archived: false,
            pinned: false,
            snoozed_until: None,
            navigation: Some(coincide_core::store::ThreadNavigation {
                updated_at: Some(1.0),
                item_count: Some(0),
                ..Default::default()
            }),
        };
        let mut state = State::default();
        state.remember(thread.clone());
        assert_eq!(
            state.take_recent("a", std::slice::from_ref(&summary)),
            Some(thread.clone())
        );
        state.remember(thread.clone());
        let mut changed = summary;
        changed.navigation.as_mut().unwrap().item_count = Some(1);
        assert!(state.take_recent("a", &[changed]).is_none());
        state.remember(thread);
        assert!(state.take_recent("a", &[]).is_none());
    }

    #[test]
    fn superseded_read_waiting_for_engine_never_returns_the_old_thread() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&dir.path().join("synthetic.sqlite")).unwrap(),
        )));
        let generation = Arc::new(AtomicU64::new(1));
        let request = json!({"projectId":"00000000-0000-0000-0000-000000000000","cwd":dir.path()});
        let created = create(&engine, &request, &generation, 1).unwrap().unwrap();
        let id = created["id"].as_str().unwrap().to_owned();
        let locked = engine.lock().unwrap();
        let worker_engine = engine.clone();
        let worker_generation = generation.clone();
        let worker =
            std::thread::spawn(move || read(&worker_engine, None, &id, &worker_generation, 1));
        generation.store(2, Ordering::Release);
        drop(locked);
        assert!(worker.join().unwrap().unwrap().is_none());
        assert_eq!(
            engine
                .lock()
                .unwrap()
                .store
                .summaries("", false)
                .unwrap()
                .len(),
            1
        );
    }
}
