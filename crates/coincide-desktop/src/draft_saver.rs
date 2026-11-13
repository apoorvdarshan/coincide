//! Debounced background draft persistence. Typing updates only in-memory state
//! on the UI thread; one worker saves the latest text after a short quiet
//! period, and retries while the Engine is busy.
use super::*;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
    mpsc::{Receiver, SyncSender, sync_channel},
};
use std::time::Duration;

struct Request {
    generation: u64,
    thread: String,
    text: String,
}

pub(super) struct Saver {
    sender: Option<SyncSender<Request>>,
    latest: Arc<AtomicU64>,
    worker: Option<std::thread::JoinHandle<()>>,
    generation: u64,
}

impl Saver {
    pub(super) fn new(engine: SharedEngine) -> Self {
        let (sender, receiver) = sync_channel::<Request>(64);
        let latest = Arc::new(AtomicU64::new(0));
        let worker_latest = latest.clone();
        let worker = std::thread::Builder::new()
            .name("coincide-draft-saver".into())
            .spawn(move || run(engine, receiver, worker_latest))
            .ok();
        Self {
            sender: Some(sender),
            latest,
            worker,
            generation: 0,
        }
    }

    /// Records the latest draft text. A full queue drops intermediate values;
    /// the next keystroke carries the latest text, and the worker drains to it.
    pub(super) fn record(&mut self, thread: &str, text: &str) {
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.latest.store(generation, Ordering::Release);
        if let Some(sender) = &self.sender {
            let _ = sender.try_send(Request {
                generation,
                thread: thread.to_owned(),
                text: text.to_owned(),
            });
        }
    }

    /// A submitted draft must not be written again by an older debounce job.
    pub(super) fn invalidate(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.latest.store(self.generation, Ordering::Release);
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

fn run(engine: SharedEngine, receiver: Receiver<Request>, latest: Arc<AtomicU64>) {
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
        loop {
            match persist_pending_draft_guarded(&engine, &request.thread, &request.text, || {
                latest.load(Ordering::Acquire) == request.generation
            }) {
                Ok(()) => break,
                Err(error) if attempts < 20 && engine_busy(&error) => {
                    attempts += 1;
                    std::thread::sleep(Duration::from_millis(100));
                    if latest.load(Ordering::Acquire) != request.generation {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
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
}
