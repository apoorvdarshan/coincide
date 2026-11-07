//! Local saved-document transport. Account rows come from saved provider
//! configuration only: no provider launch, network or session discovery.
use crate::{
    usage_dashboard::{Dashboard, Data},
    usage_history_view::{UsageHistoryEvent, UsageHistoryView},
    worker_owner::{ShutdownStatus, WorkerOwner},
};
use coincide_core::{
    api::SharedEngine,
    local_usage::{CaptureCoverage, Query, Report, project},
};
use gpui_kit::*;
use std::sync::mpsc::{self, Receiver, SyncSender};

type Reply<T> = (u64, Result<T, String>);
struct Reader<T> {
    owner: WorkerOwner,
    generation: u64,
    receiver: Option<Receiver<Reply<T>>>,
}
impl<T> Default for Reader<T> {
    fn default() -> Self {
        Self {
            owner: WorkerOwner::default(),
            generation: 0,
            receiver: None,
        }
    }
}
impl<T: Send + 'static> Reader<T> {
    fn start(
        &mut self,
        read: impl FnOnce() -> Result<T, String> + Send + 'static,
    ) -> Result<(), String> {
        if !self.owner.can_start() {
            return Err("A saved-history read is still finishing, or this view is closing.".into());
        }
        self.generation = self
            .generation
            .checked_add(1)
            .ok_or("Saved-history generation exhausted")?;
        let generation = self.generation;
        let (tx, rx): (SyncSender<Reply<T>>, Receiver<Reply<T>>) = mpsc::sync_channel(1);
        if !self.owner.spawn(move |admission| {
            if !admission.allowed() {
                return;
            }
            let result = read();
            if admission.allowed() {
                let _ = tx.try_send((generation, result));
            }
        }) {
            return Err("Saved-history reader could not start.".into());
        }
        self.receiver = Some(rx);
        Ok(())
    }
    fn poll(&mut self) -> Option<Result<T, String>> {
        self.owner.poll();
        if self.owner.closed() {
            self.receiver = None;
            return None;
        }
        let receiver = self.receiver.as_ref()?;
        match receiver.try_recv() {
            Ok((generation, result)) => {
                self.receiver = None;
                (generation == self.generation).then_some(result)
            }
            Err(mpsc::TryRecvError::Empty) => None,
            Err(mpsc::TryRecvError::Disconnected) => {
                self.receiver = None;
                Some(Err("Saved-history read ended without a result.".into()))
            }
        }
    }
    fn close(&mut self) {
        self.owner.close();
        self.receiver = None;
    }
}
pub struct Mount {
    pub panel: Entity<UsageHistoryView>,
    pub dashboard: Dashboard,
    engine: SharedEngine,
    reader: Reader<Report>,
    dashboard_reader: Reader<Data>,
}
impl Mount {
    pub fn new(engine: SharedEngine, cx: &mut App) -> Self {
        Self {
            panel: cx.new(|_| UsageHistoryView::new()),
            dashboard: Dashboard::default(),
            engine,
            reader: Reader::default(),
            dashboard_reader: Reader::default(),
        }
    }
    /// Reads saved turns and account rows for Settings › Usage in the background.
    pub fn load_dashboard(&mut self) {
        if self.dashboard.loading {
            return;
        }
        self.dashboard.attempted_at = Some(chrono::Utc::now());
        let engine = self.engine.clone();
        match self
            .dashboard_reader
            .start(move || crate::usage_dashboard::read(&engine))
        {
            Ok(()) => self.dashboard.loading = true,
            Err(error) => self.dashboard.error = Some(error),
        }
    }
    pub fn load(&mut self, event: &UsageHistoryEvent, cx: &mut App) {
        let UsageHistoryEvent::Load(query) = event;
        let query: Query = query.clone();
        let engine = self.engine.clone();
        let started = self.reader.start(move || {
            let snapshot = {
                let engine = engine.try_lock().map_err(|_| {
                    "The app is busy. Reload saved history to try again.".to_owned()
                })?;
                if engine.admissions_frozen() {
                    return Err("Saved history is closing.".into());
                }
                engine.store.saved_usage_snapshot().map_err(|_| {
                    "Saved usage history could not be read. Its saved contents have been retained.".to_owned()
                })?
            };
            project(&snapshot.0, snapshot.1, query, CaptureCoverage::CodexRequestSnapshots)
                .map_err(|_| {
                    "Saved usage history or filters are invalid. Saved contents have been retained.".to_owned()
                })
        });
        if let Err(error) = started {
            self.panel
                .update(cx, |panel, cx| panel.set_snapshot(Err(error), cx));
        }
    }

    /// True when the dashboard changed and should be drawn again.
    pub fn poll(&mut self, cx: &mut App) -> bool {
        if let Some(result) = self.reader.poll() {
            self.panel
                .update(cx, |panel, cx| panel.set_snapshot(result, cx));
        }
        let mut changed = false;
        if let Some(result) = self.dashboard_reader.poll() {
            self.dashboard.accept(result);
            changed = true;
        }
        changed | self.dashboard.claude.poll(&self.engine)
    }
    pub fn request_shutdown(&mut self) {
        self.reader.close();
        self.dashboard_reader.close();
        self.dashboard.claude.close();
    }
    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        let history = self.reader.owner.status();
        let dashboard = self.dashboard_reader.owner.status();
        ShutdownStatus {
            closed: history.closed && dashboard.closed,
            unjoined: history.unjoined + dashboard.unjoined,
            returned: history.returned.saturating_add(dashboard.returned),
            panicked: history.panicked.saturating_add(dashboard.panicked),
            unclassified: history.unclassified + dashboard.unclassified,
            pending_pickers: history.pending_pickers + dashboard.pending_pickers,
            spawn_error: history.spawn_error.or(dashboard.spawn_error),
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    #[::core::prelude::v1::test]
    fn close_discards_queued_reply_but_keeps_actual_reader_ownership() {
        let mut reader = Reader::<Report>::default();
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        reader
            .start(move || {
                started_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Err("synthetic saved-history error".into())
            })
            .unwrap();
        started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        reader.close();
        assert!(reader.poll().is_none());
        assert_eq!(reader.owner.status().unjoined, 1);
        assert!(
            reader
                .start(|| panic!("closed read must not start"))
                .is_err()
        );
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while reader.owner.status().unjoined > 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(reader.owner.status().returned, 1);
        assert!(reader.poll().is_none());
    }
    #[::core::prelude::v1::test]
    fn superseded_reply_cannot_update_current_generation() {
        let mut reader = Reader::<Report>::default();
        let (tx, rx) = mpsc::sync_channel(1);
        reader.generation = 2;
        reader.receiver = Some(rx);
        tx.send((1, Err("stale private error".into()))).unwrap();
        assert!(reader.poll().is_none());
        assert!(reader.receiver.is_none());
    }
}
