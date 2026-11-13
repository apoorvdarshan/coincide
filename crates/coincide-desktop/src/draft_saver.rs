//! Debounced background draft persistence. Typing updates only in-memory state
//! on the UI thread; one worker saves the latest text after a short quiet
//! period, and retries while the Engine is busy.
use super::*;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
    mpsc::{self, Receiver, SyncSender, TrySendError, sync_channel},
};
use std::time::Duration;

#[derive(Debug)]
struct Request {
    generation: u64,
    thread: String,
    text: String,
}

#[derive(Debug)]
pub(super) enum Outcome {
    Saved,
    Busy,
    Failed(String),
}

#[derive(Debug)]
pub(super) struct Completion {
    pub thread: String,
    pub text: String,
    pub outcome: Outcome,
    generation: u64,
}

pub(super) struct Saver {
    sender: Option<SyncSender<Request>>,
    completions: Receiver<Completion>,
    unsent: Option<Request>,
    active: Option<(u64, String, String)>,
    latest: Arc<AtomicU64>,
    worker: Option<std::thread::JoinHandle<()>>,
    generation: u64,
}

impl Saver {
    pub(super) fn new(engine: SharedEngine) -> Self {
        let (sender, receiver) = sync_channel::<Request>(64);
        let (completed, completions) = mpsc::channel();
        let latest = Arc::new(AtomicU64::new(0));
        let worker_latest = latest.clone();
        let worker = std::thread::Builder::new()
            .name("coincide-draft-saver".into())
            .spawn(move || run(engine, receiver, worker_latest, completed))
            .ok();
        Self {
            sender: Some(sender),
            completions,
            unsent: None,
            active: None,
            latest,
            worker,
            generation: 0,
        }
    }

    /// Records the latest draft text. If the bounded queue is full, retain the
    /// latest request and retry it on the UI's next poll.
    pub(super) fn record(&mut self, thread: &str, text: &str) {
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.latest.store(generation, Ordering::Release);
        self.active = Some((generation, thread.to_owned(), text.to_owned()));
        self.unsent = Some(Request {
            generation,
            thread: thread.to_owned(),
            text: text.to_owned(),
        });
        self.pump();
    }

    fn pump(&mut self) {
        let (Some(sender), Some(request)) = (&self.sender, self.unsent.take()) else {
            return;
        };
        match sender.try_send(request) {
            Ok(()) => {}
            Err(TrySendError::Full(request)) => self.unsent = Some(request),
            Err(TrySendError::Disconnected(_)) => {
                self.sender = None;
                self.active = None;
            }
        }
    }

    pub(super) fn available(&self) -> bool {
        self.sender.is_some()
            && self
                .worker
                .as_ref()
                .is_some_and(|worker| !worker.is_finished())
    }

    pub(super) fn idle(&self) -> bool {
        self.active.is_none()
    }

    /// Only the latest editing intent can acknowledge a pending draft, even
    /// when the user deliberately types the same text a second time.
    pub(super) fn poll(&mut self) -> Vec<Completion> {
        self.pump();
        let mut current = Vec::new();
        while let Ok(completion) = self.completions.try_recv() {
            if self
                .active
                .as_ref()
                .is_some_and(|(generation, thread, text)| {
                    *generation == completion.generation
                        && *thread == completion.thread
                        && *text == completion.text
                })
                && self.latest.load(Ordering::Acquire) == completion.generation
            {
                self.active = None;
                current.push(completion);
            }
        }
        current
    }

    pub(super) fn invalidate_thread(&mut self, thread: &str) {
        if self.active.as_ref().is_some_and(|(_, id, _)| id == thread) {
            self.invalidate();
        }
    }

    /// A submitted draft must not be written again by an older debounce job.
    pub(super) fn invalidate(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.latest.store(self.generation, Ordering::Release);
        self.unsent = None;
        self.active = None;
    }
}

impl Drop for Saver {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn run(
    engine: SharedEngine,
    receiver: Receiver<Request>,
    latest: Arc<AtomicU64>,
    completed: mpsc::Sender<Completion>,
) {
    loop {
        let Ok(mut request) = receiver.recv() else {
            return;
        };
        // Wait for a quiet period, keeping only the newest text.
        loop {
            match receiver.recv_timeout(Duration::from_millis(1200)) {
                Ok(next) => request = next,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => break,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
            }
        }
        if latest.load(Ordering::Acquire) != request.generation {
            continue;
        }
        let mut attempts = 0;
        let outcome = loop {
            match persist_pending_draft_guarded(&engine, &request.thread, &request.text, || {
                latest.load(Ordering::Acquire) == request.generation
            }) {
                Ok(()) => break Outcome::Saved,
                Err(error) if attempts < 20 && engine_busy(&error) => {
                    attempts += 1;
                    std::thread::sleep(Duration::from_millis(100));
                    if latest.load(Ordering::Acquire) != request.generation {
                        break Outcome::Busy;
                    }
                }
                Err(error) if engine_busy(&error) => break Outcome::Busy,
                Err(error) => break Outcome::Failed(error.to_string()),
            }
        };
        let _ = completed.send(Completion {
            generation: request.generation,
            thread: request.thread,
            text: request.text,
            outcome,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::store::Store;

    #[::core::prelude::v1::test]
    fn invalidated_debounce_cannot_restore_a_submitted_draft() {
        let root = tempfile::tempdir().unwrap();
        let engine: SharedEngine = Arc::new(Mutex::new(Engine::new(
            Store::open(&root.path().join("state.sqlite")).unwrap(),
        )));
        let thread = call(&engine, "threads.create", json!({"cwd":root.path()})).unwrap();
        let id = text(&thread, "id");
        let generation = AtomicU64::new(1);
        persist_pending_draft(&engine, &id, "submitted").unwrap();
        // Send consumes the saved text; a previously scheduled save must not
        // put it back, even when it only reaches the lock afterwards.
        persist_pending_draft(&engine, &id, "").unwrap();
        generation.store(2, Ordering::Release);
        persist_pending_draft_guarded(&engine, &id, "submitted", || {
            generation.load(Ordering::Acquire) == 1
        })
        .unwrap();
        assert_eq!(
            call(&engine, "threads.read", json!({"threadId":id})).unwrap()["draft"],
            ""
        );
        persist_pending_draft_guarded(&engine, &id, "new draft", || {
            generation.load(Ordering::Acquire) == 2
        })
        .unwrap();
        assert_eq!(
            call(&engine, "threads.read", json!({"threadId":id})).unwrap()["draft"],
            "new draft"
        );
    }

    #[::core::prelude::v1::test]
    fn worker_acknowledges_a_saved_draft_without_a_ui_thread_write() {
        let root = tempfile::tempdir().unwrap();
        let engine: SharedEngine = Arc::new(Mutex::new(Engine::new(
            Store::open(&root.path().join("state.sqlite")).unwrap(),
        )));
        let thread = call(&engine, "threads.create", json!({"cwd":root.path()})).unwrap();
        let id = text(&thread, "id");
        let mut saver = Saver::new(engine.clone());
        saver.record(&id, "new draft");
        let deadline = std::time::Instant::now() + Duration::from_secs(8);
        let completion = loop {
            if let Some(completion) = saver.poll().pop() {
                break completion;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "draft worker did not finish"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(matches!(completion.outcome, Outcome::Saved));
        assert_eq!(completion.thread, id);
        assert_eq!(completion.text, "new draft");
        assert_eq!(
            call(&engine, "threads.read", json!({"threadId":id})).unwrap()["draft"],
            "new draft"
        );
    }

    #[::core::prelude::v1::test]
    fn a_busy_engine_retries_the_draft_without_blocking_the_editor() {
        let root = tempfile::tempdir().unwrap();
        let engine: SharedEngine = Arc::new(Mutex::new(Engine::new(
            Store::open(&root.path().join("state.sqlite")).unwrap(),
        )));
        let thread = call(&engine, "threads.create", json!({"cwd":root.path()})).unwrap();
        let id = text(&thread, "id");
        let guard = engine.lock().unwrap();
        let mut saver = Saver::new(engine.clone());
        saver.record(&id, "retained while busy");
        std::thread::sleep(Duration::from_millis(1400));
        assert!(saver.poll().is_empty());
        drop(guard);
        let deadline = std::time::Instant::now() + Duration::from_secs(8);
        let completion = loop {
            if let Some(completion) = saver.poll().pop() {
                break completion;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "busy draft was not retried"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(matches!(completion.outcome, Outcome::Saved));
        assert_eq!(
            call(&engine, "threads.read", json!({"threadId":id})).unwrap()["draft"],
            "retained while busy"
        );
    }

    #[::core::prelude::v1::test]
    fn old_acknowledgement_cannot_clear_retyped_identical_text() {
        let (completed, completions) = mpsc::channel();
        let latest = Arc::new(AtomicU64::new(2));
        let mut saver = Saver {
            sender: None,
            completions,
            unsent: None,
            active: Some((2, "thread".into(), "same".into())),
            latest,
            worker: None,
            generation: 2,
        };
        completed
            .send(Completion {
                generation: 1,
                thread: "thread".into(),
                text: "same".into(),
                outcome: Outcome::Saved,
            })
            .unwrap();
        assert!(saver.poll().is_empty());
        assert!(!saver.idle());
        completed
            .send(Completion {
                generation: 2,
                thread: "thread".into(),
                text: "same".into(),
                outcome: Outcome::Saved,
            })
            .unwrap();
        assert_eq!(saver.poll().len(), 1);
        assert!(saver.idle());
    }

    #[::core::prelude::v1::test]
    fn full_queue_retains_the_latest_edit_for_retry() {
        let (sender, receiver) = sync_channel(1);
        sender
            .try_send(Request {
                generation: 0,
                thread: "old".into(),
                text: "old".into(),
            })
            .unwrap();
        let (_, completions) = mpsc::channel();
        let mut saver = Saver {
            sender: Some(sender),
            completions,
            unsent: None,
            active: None,
            latest: Arc::new(AtomicU64::new(0)),
            worker: None,
            generation: 0,
        };
        saver.record("thread", "first");
        saver.record("thread", "latest");
        assert_eq!(saver.unsent.as_ref().unwrap().text, "latest");
        receiver.try_recv().unwrap();
        saver.poll();
        assert_eq!(receiver.try_recv().unwrap().text, "latest");
        assert!(saver.unsent.is_none());
    }
}
