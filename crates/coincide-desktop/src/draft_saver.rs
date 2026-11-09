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
            match receiver.recv_timeout(Duration::from_millis(500)) {
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
            match persist_pending_draft(&engine, &request.thread, &request.text) {
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
