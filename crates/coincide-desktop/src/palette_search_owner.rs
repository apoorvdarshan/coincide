//! One admitted palette search at a time; replies never replace worker custody.
use crate::{
    command_palette::{PaletteList, SearchRequest},
    worker_owner::{ShutdownStatus, WorkerOwner},
};
use coincide_core::project_search::SearchControl;
use std::sync::mpsc::{self, Receiver};

#[derive(Default)]
pub(super) struct State {
    owner: WorkerOwner,
    active: Option<SearchControl>,
    pending: Option<SearchRequest>,
    reply: Option<Receiver<(u64, Vec<PaletteList>)>>,
    cleanup_uncertain: bool,
}
impl State {
    pub fn cancel(&mut self) {
        self.pending = None;
        self.reply = None;
        if let Some(control) = &self.active {
            control.cancel();
        }
    }
    pub fn submit(&mut self, request: SearchRequest) {
        self.cancel();
        if !self.owner.closed() {
            self.pending = Some(request);
        }
    }
    pub fn poll(
        &mut self,
        search: fn(&SearchRequest, &SearchControl) -> Vec<PaletteList>,
    ) -> Option<(u64, Vec<PaletteList>)> {
        self.owner.poll();
        if self.owner.status().unjoined != 0 {
            return None;
        }
        if let Some(control) = self.active.take() {
            self.cleanup_uncertain |= !control.cleanup_confirmed();
        }
        let result = self.reply.take().and_then(|rx| rx.try_recv().ok());
        if !self.cleanup_uncertain
            && self.owner.can_start()
            && let Some(request) = self.pending.take()
        {
            let control = SearchControl::default();
            let work_control = control.clone();
            let (tx, rx) = mpsc::sync_channel(1);
            if self.owner.spawn(move |admission| {
                if !admission.allowed() {
                    work_control.cancel();
                }
                let lists = search(&request, &work_control);
                // Cancellation drops the receiver; publication never blocks cleanup.
                if !work_control.cancelled() {
                    let _ = tx.try_send((request.generation, lists));
                }
            }) {
                self.active = Some(control);
                self.reply = Some(rx);
            }
        }
        result
    }
    pub fn shutdown(&mut self) {
        self.cancel();
        self.owner.close();
    }
    pub fn status(&mut self) -> ShutdownStatus {
        self.owner.poll();
        if self.owner.status().unjoined == 0
            && let Some(control) = self.active.take()
        {
            self.cleanup_uncertain |= !control.cleanup_confirmed();
        }
        let mut status = self.owner.status();
        status.unclassified += usize::from(self.cleanup_uncertain);
        status
    }
}
impl Drop for State {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::command_palette::SearchKind;
    use std::{
        cell::RefCell,
        sync::{
            Mutex,
            atomic::{AtomicUsize, Ordering},
        },
        time::{Duration, Instant},
    };
    struct Gate(mpsc::Sender<()>, mpsc::Receiver<()>);
    impl Drop for Gate {
        fn drop(&mut self) {
            self.0.send(()).unwrap();
            self.1.recv().unwrap();
        }
    }
    thread_local! { static TLS_GATE: RefCell<Option<Gate>> = const { RefCell::new(None) }; }
    static NEXT_GATE: Mutex<Option<Gate>> = Mutex::new(None);
    static CALLS: AtomicUsize = AtomicUsize::new(0);
    fn synthetic(request: &SearchRequest, _: &SearchControl) -> Vec<PaletteList> {
        CALLS.fetch_add(1, Ordering::SeqCst);
        if request.generation == 1 {
            TLS_GATE.with(|gate| *gate.borrow_mut() = NEXT_GATE.lock().unwrap().take());
        }
        vec![]
    }
    fn request(generation: u64) -> SearchRequest {
        SearchRequest {
            generation,
            kind: SearchKind::Folders,
            query: String::new(),
        }
    }
    #[test]
    fn cancelled_reply_keeps_real_worker_slot_through_tls_and_only_latest_request_runs() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        *NEXT_GATE.lock().unwrap() = Some(Gate(entered_tx, release_rx));
        let mut state = State::default();
        state.submit(request(1));
        assert!(state.poll(synthetic).is_none());
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        state.submit(request(2));
        state.submit(request(3));
        assert!(!state.active.as_ref().unwrap().allowed());
        assert!(
            state.poll(synthetic).is_none(),
            "semantic reply cannot release TLS custody"
        );
        assert_eq!(CALLS.load(Ordering::SeqCst), 1);
        assert_eq!(state.status().unjoined, 1);
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let generation = loop {
            if let Some((generation, _)) = state.poll(synthetic) {
                break generation;
            }
            assert!(
                Instant::now() < deadline,
                "owned private callback did not join"
            );
            std::thread::yield_now();
        };
        assert_eq!(generation, 3);
        assert_eq!(
            CALLS.load(Ordering::SeqCst),
            2,
            "intermediate request must never start"
        );
        state.shutdown();
        state.submit(request(4));
        assert!(state.poll(synthetic).is_none());
        let status = state.status();
        assert!(status.closed);
        assert_eq!(status.unjoined, 0);
        assert_eq!(status.panicked, 0);
    }
}
