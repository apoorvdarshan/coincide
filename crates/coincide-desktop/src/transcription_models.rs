//! Explicit model actions; construction/render never inspect disk or network.
use super::*;
use coincide_core::{
    api::SharedEngine,
    dictation::model_assets::{self, ModelId, Repository, VerifiedModel},
    native_ui_edits::{NativeUiEditLease, NativeUiEditors},
};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[derive(Clone, Copy)]
enum Action {
    Download,
    Verify,
    Use,
    Remove,
    Retry,
}
struct Reply {
    generation: u64,
    id: ModelId,
    action: Action,
    repository: Option<Arc<Repository>>,
    result: Result<Option<Arc<VerifiedModel>>, model_assets::Error>,
    expected_voice: Option<serde_json::Value>,
    _custody: NativeUiEditLease,
}
pub(crate) struct UseRequest {
    _custody: NativeUiEditLease,
    pub model: Arc<VerifiedModel>,
    pub expected_voice: Option<serde_json::Value>,
}
pub(super) struct Models {
    engine: SharedEngine,
    downloader: Arc<dyn model_assets::Downloader>,
    removed: Option<ModelId>,
    lease: NativeUiEditLease,
    repository: Option<Arc<Repository>>,
    models: Vec<Arc<VerifiedModel>>,
    workers: WorkerOwner,
    sender: mpsc::SyncSender<Reply>,
    receiver: mpsc::Receiver<Reply>,
    cancellation: Arc<AtomicBool>,
    progress: Arc<AtomicU64>,
    generation: u64,
    pending: Option<ModelId>,
    seen_progress: u64,
    status: String,
    use_request: Option<UseRequest>,
}
impl Models {
    pub fn new(engine: SharedEngine, native: NativeUiEditors) -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        Self{engine,downloader:Arc::new(model_assets::HttpsDownloader),removed:None,lease:native.editor(),repository:None,models:Vec::new(),workers:WorkerOwner::default(),sender,receiver,cancellation:Arc::new(AtomicBool::new(false)),progress:Arc::new(AtomicU64::new(0)),generation:0,pending:None,seen_progress:0,status:"Models have not been checked. Downloads use compatible whisper.cpp GGML weights, separately from Swift CoreML assets. A configured whisper-cli executable is still required.".into(),use_request:None}
    }
    fn action(&mut self, id: ModelId, action: Action) {
        if self.pending.is_some() || !self.workers.can_start() {
            return;
        }
        let model = self.models.iter().find(|m| m.id() == id).cloned();
        if matches!(action, Action::Remove) && model.is_none() {
            self.status = "Verify the downloaded model before removing it.".into();
            return;
        }
        self.start(id, action, model);
    }
    fn start(&mut self, id: ModelId, action: Action, model: Option<Arc<VerifiedModel>>) {
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.pending = Some(id);
        self.cancellation = Arc::new(AtomicBool::new(false));
        self.progress.store(0, Ordering::Release);
        self.status=if matches!(action,Action::Remove){"Waiting for actual model readers and pending transcripts before removal. Cancel preserves the model."}else{"Working on the selected model. Cancel requests shutdown; completion waits for the owned worker."}.into();
        let cancellation = self.cancellation.clone();
        let progress = self.progress.clone();
        let engine = self.engine.clone();
        let repository = self.repository.clone();
        let sender = self.sender.clone();
        let downloader = self.downloader.clone();
        let custody = self.lease.pending_native_action();
        if !self.workers.spawn(move |admission| {
            let cancelled = || cancellation.load(Ordering::Acquire) || !admission.allowed();
            let mut expected_voice = None;
            let repository = repository.or_else(|| {
                let root = crate::try_state(&engine)
                    .ok()?
                    .store
                    .data_directory()
                    .ok()?;
                Repository::open(&root).ok().map(Arc::new)
            });
            let result = (|| {
                if cancelled() {
                    return Err(model_assets::Error::Cancelled);
                }
                let repository = repository.as_ref().ok_or(model_assets::Error::Storage)?;
                match action {
                    Action::Download => repository
                        .download(id, downloader.as_ref(), &cancelled, &mut |received| {
                            progress.store(received, Ordering::Release);
                        })
                        .map(Some),
                    Action::Verify => repository.verify(id, &cancelled).map(Some),
                    Action::Use => {
                        expected_voice = crate::try_state(&engine)
                            .map_err(|_| model_assets::Error::Busy)?
                            .store
                            .document("settings.json")
                            .map_err(|_| model_assets::Error::Storage)?
                            .as_ref()
                            .and_then(|v| v.get("voice"))
                            .cloned();
                        repository.verify(id, &cancelled).map(Some)
                    }
                    Action::Remove => repository
                        .remove(
                            model.as_deref().ok_or(model_assets::Error::Changed)?,
                            &cancelled,
                        )
                        .map(|_| None),
                    Action::Retry => repository.retry_owned_cleanup(&cancelled).map(|_| None),
                }
            })();
            let _ = sender.send(Reply {
                generation,
                id,
                action,
                repository,
                result,
                expected_voice,
                _custody: custody,
            });
        }) {
            self.pending = None;
            self.status = "The model worker could not start.".into();
        }
    }
    pub fn poll(&mut self) -> bool {
        self.workers.poll();
        let current_progress = self.progress.load(Ordering::Acquire);
        let mut changed = current_progress != self.seen_progress;
        self.seen_progress = current_progress;
        while let Ok(reply) = self.receiver.try_recv() {
            if self.workers.closed() || reply.generation != self.generation {
                continue;
            }
            changed = true;
            self.pending = None;
            self.repository = reply.repository;
            match reply.result {
                Ok(model) => {
                    if matches!(reply.action, Action::Remove) {
                        self.removed = Some(reply.id);
                        self.models.retain(|m| m.id() != reply.id);
                    }
                    if let Some(model) = model {
                        self.models.retain(|m| m.id() != reply.id);
                        self.models.push(model.clone());
                        if matches!(reply.action, Action::Use) {
                            self.use_request = Some(UseRequest {
                                _custody: reply._custody,
                                model,
                                expected_voice: reply.expected_voice,
                            });
                        }
                    }
                    self.status=if matches!(reply.action,Action::Remove){"Verified downloaded model removed. Other files were preserved."}else{"Model action completed. Downloading or verifying never records or runs inference. Use selects the verified model for this session."}.into();
                }
                Err(error) => self.status = message(error).into(),
            }
        }
        changed
    }
    pub fn close(&mut self) {
        self.cancellation.store(true, Ordering::Release);
        self.workers.close();
        self.use_request = None;
        while self.receiver.try_recv().is_ok() {}
    }
    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        if self.workers.closed() {
            self.close();
        }
        let status = self.workers.status();
        if self.workers.closed() {
            while self.receiver.try_recv().is_ok() {}
        }
        status
    }
    pub fn take_removed(&mut self) -> Option<ModelId> {
        self.removed.take()
    }
    pub fn take_use(&mut self) -> Option<UseRequest> {
        self.use_request.take()
    }
    pub fn render(&self, cx: &Context<TranscriptionSettings>) -> gpui_kit::AnyElement {
        let busy = self.pending.is_some() || self.workers.closed();
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
            .child("Local Whisper models (GGML)")
            .child(self.status.clone());
        for spec in model_assets::CATALOG {
            let id = spec.id;
            let verified = self
                .models
                .iter()
                .any(|m| m.id() == id && m.available_for_new_use());
            let mut row = div().flex().gap_2().child(format!(
                "{} · {:.1} MB · {}",
                spec.name,
                spec.bytes as f64 / 1_000_000.0,
                if verified {
                    "verified this session"
                } else {
                    "not verified"
                }
            ));
            for (action, label) in [
                (Action::Download, "Download"),
                (Action::Verify, "Verify"),
                (Action::Use, "Use"),
                (Action::Remove, "Remove"),
            ] {
                row = row.child(
                    Button::new(format!("voice-model-{}-{label}", id.id()))
                        .label(label)
                        .disabled(busy || (matches!(action, Action::Remove) && !verified))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(models) = &mut this.models {
                                models.action(id, action);
                            }
                            cx.notify();
                        })),
                );
            }
            pane = pane.child(row);
        }
        if let Some(id) = self.pending {
            pane = pane.child(format!(
                "{}: {} / {} bytes",
                id.spec().name,
                self.progress.load(Ordering::Acquire),
                id.spec().bytes
            ));
        }
        pane.child(
            Button::new("voice-model-cancel")
                .label("Cancel model action")
                .disabled(!busy || self.workers.closed())
                .on_click(cx.listener(|this, _, _, cx| {
                    if let Some(models) = &mut this.models {
                        models.cancellation.store(true, Ordering::Release);
                    }
                    cx.notify();
                })),
        )
        .child(
            Button::new("voice-model-cleanup")
                .label("Retry owned cleanup")
                .disabled(busy)
                .on_click(cx.listener(|this, _, _, cx| {
                    if let Some(models) = &mut this.models {
                        models.action(ModelId::Base, Action::Retry);
                    }
                    cx.notify();
                })),
        )
        .into_any_element()
    }
}
fn message(error: model_assets::Error) -> &'static str {
    use model_assets::Error::*;
    match error {
        Cancelled => {
            "Model action cancelled. Only owned staging cleanup was attempted; existing models were preserved."
        }
        ExistingPreserved => {
            "A model file already exists. It was preserved. Use Verify to check it against the pinned catalog."
        }
        NotDownloaded => "This model has not been downloaded. Choose Download explicitly.",
        ChecksumMismatch | SizeMismatch => {
            "The model does not match the pinned catalog. Existing files were preserved; new invalid staging was discarded."
        }
        Changed => {
            "The model or its directory changed. No changed file was adopted or intentionally deleted."
        }
        RecoveryPending => {
            "Cleanup or process exit is uncertain. Retained files are unavailable for new inference/removal. Retry owned cleanup; process uncertainty requires a fresh application session."
        }
        InsufficientSpace => "Insufficient space for the model plus temporary storage reserve.",
        Busy => "The model or application is busy. Retry after its current owner returns.",
        Network | Rejected => {
            "The official model download failed or was rejected. No model was published without verification."
        }
        Storage | Unavailable => {
            "The private model directory or platform operation is unavailable."
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Action, Models};
    use coincide_core::{
        api::Engine,
        dictation::model_assets::{Downloader, Error, ModelId, Result, Spec},
        native_ui_edits::NativeUiEditors,
        store::Store,
    };
    use std::{
        io::Write,
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
        },
        time::{Duration, Instant},
    };
    struct FakeDownload(Arc<AtomicUsize>);
    impl Downloader for FakeDownload {
        fn fetch(
            &self,
            _: &Spec,
            output: &mut dyn Write,
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<()> {
            self.0.fetch_add(1, Ordering::AcqRel);
            output
                .write_all(b"synthetic partial weights")
                .map_err(|_| Error::Storage)?;
            while !cancelled() {
                std::thread::yield_now();
            }
            Err(Error::Cancelled)
        }
    }
    #[test]
    fn explicit_download_cancel_has_actual_worker_return_and_preserves_other_files() {
        let root = tempfile::tempdir().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&root.path().join("state.sqlite")).unwrap(),
        )));
        let native = NativeUiEditors::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let mut models = Models::new(engine, native);
        models.downloader = Arc::new(FakeDownload(calls.clone()));
        assert!(
            !root.path().join("voice-models-ggml-v1").exists(),
            "construction must remain inert"
        );
        models.poll();
        assert_eq!(calls.load(Ordering::Acquire), 0);
        models.action(ModelId::Tiny, Action::Download);
        struct Cancel(Arc<std::sync::atomic::AtomicBool>);
        impl Drop for Cancel {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }
        let _cancel = Cancel(models.cancellation.clone());
        let deadline = Instant::now() + Duration::from_secs(5);
        while calls.load(Ordering::Acquire) == 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        let other = root.path().join("voice-models-ggml-v1/user-owned");
        std::fs::write(&other, b"preserve").unwrap();
        models.close();
        loop {
            let status = models.shutdown_status();
            if status.unjoined == 0 {
                assert_eq!(status.returned, 1);
                assert_eq!(status.panicked, 0);
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(calls.load(Ordering::Acquire), 1);
        assert_eq!(std::fs::read(other).unwrap(), b"preserve");
        assert_eq!(
            std::fs::read_dir(root.path().join("voice-models-ggml-v1"))
                .unwrap()
                .count(),
            1
        );
        assert!(
            models.take_use().is_none(),
            "cancel cannot mint selected-model authority"
        );
    }
}
