//! One bounded snapshot job; actual SDK callbacks and encoding worker returns
//! remain owned through cancellation, tab close and browser shutdown.
use super::{
    screenshot_native,
    shutdown::{CallbackAck, Callbacks},
};
use crate::worker_owner::WorkerOwner;
use anyhow::{Result, ensure};
use coincide_core::{
    browser_protocol::{BrowserReply, BrowserRequest},
    browser_screenshot::{
        self,
        artifact::{Artifact, Directory},
    },
};
use serde_json::json;
use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, TryRecvError},
    },
};

pub(super) struct Binding {
    pub thread: String,
    pub tab: String,
    pub url: String,
    pub epoch: u64,
    navigation: Arc<AtomicU64>,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
}
impl Binding {
    fn current(&self) -> bool {
        !self.cancelled.load(Ordering::Acquire)
            && !self.protected.load(Ordering::Acquire)
            && self.navigation.load(Ordering::Acquire) == self.epoch
    }
}
struct Pending {
    request: BrowserRequest,
    binding: Binding,
    raw: Option<Receiver<Result<screenshot_native::Pixels, &'static str>>>,
    encoded: Option<Receiver<Result<Artifact, String>>>,
    artifact: Option<Artifact>,
    truncated: bool,
    failure: Option<String>,
    // Pending worker accounting is released ONLY after WorkerOwner reports the
    // real thread/observer join, never on result-channel delivery or timeout.
    worker_ack: Option<CallbackAck>,
    native_returned: Arc<AtomicBool>,
}
pub(super) struct Owner {
    directory: PathBuf,
    job: Option<Pending>,
    worker: WorkerOwner,
}
impl Owner {
    pub fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            job: None,
            worker: WorkerOwner::default(),
        }
    }
    pub fn pending(&self, thread: &str, tab: &str) -> bool {
        self.job
            .as_ref()
            .is_some_and(|j| j.binding.thread == thread && j.binding.tab == tab)
    }
    #[allow(clippy::too_many_arguments)] // Each is a distinct retained native source binding.
    pub fn begin(
        &mut self,
        request: BrowserRequest,
        tab: String,
        url: String,
        view: &wry::WebView,
        navigation: Arc<AtomicU64>,
        protected: Arc<AtomicBool>,
        callbacks: Callbacks,
        console_suppressed: Arc<AtomicBool>,
        full_page: bool,
    ) -> Result<()> {
        ensure!(
            self.job.is_none() && self.worker.can_start() && !callbacks.closed(),
            "A browser screenshot is already pending or closing"
        );
        let cancelled = Arc::new(AtomicBool::new(false));
        let binding = Binding {
            thread: request.thread_id.clone(),
            tab,
            url,
            epoch: navigation.load(Ordering::Acquire),
            navigation: navigation.clone(),
            protected: protected.clone(),
            cancelled: cancelled.clone(),
        };
        ensure!(binding.current(), "Snapshot document is private or stale");
        let (sender, raw) = mpsc::sync_channel(1);
        let native_returned = Arc::new(AtomicBool::new(false));
        self.job = Some(Pending {
            request,
            binding,
            raw: Some(raw),
            encoded: None,
            artifact: None,
            truncated: false,
            failure: None,
            worker_ack: None,
            native_returned: native_returned.clone(),
        });
        console_suppressed.store(true, Ordering::Release);
        screenshot_native::capture(
            view,
            navigation,
            protected,
            cancelled,
            callbacks,
            full_page,
            Box::new(move |result| {
                console_suppressed.store(false, Ordering::Release);
                native_returned.store(true, Ordering::Release);
                let _ = sender.try_send(result);
            }),
        );
        Ok(())
    }
    pub fn close(&mut self) {
        self.worker.close();
        if let Some(job) = &self.job {
            job.binding.cancelled.store(true, Ordering::Release);
        }
    }
    /// `source_matches` is supplied by the real retained browser/controller and
    /// checks thread/tab/native URL/selection after callback and after encoding.
    pub fn poll(
        &mut self,
        callbacks: &Callbacks,
        source_matches: impl Fn(&Binding) -> bool,
    ) -> Option<BrowserReply> {
        self.worker.poll();
        let job = self.job.as_mut()?;
        if callbacks.closed() || !source_matches(&job.binding) {
            job.binding.cancelled.store(true, Ordering::Release);
        }
        if let Some(raw) = &job.raw {
            match raw.try_recv() {
                Ok(result) => {
                    job.raw = None;
                    match result {
                        Ok(pixels) if job.binding.current() => {
                            job.truncated = pixels.truncated;
                            let directory = self.directory.clone();
                            let cancelled = job.binding.cancelled.clone();
                            let navigation = job.binding.navigation.clone();
                            let epoch = job.binding.epoch;
                            let protected = job.binding.protected.clone();
                            let (sender, receiver) = mpsc::sync_channel(1);
                            job.worker_ack = Some(callbacks.begin());
                            let started = self.worker.spawn(move |admission| {
                                let allowed = || {
                                    admission.allowed()
                                        && !cancelled.load(Ordering::Acquire)
                                        && !protected.load(Ordering::Acquire)
                                        && navigation.load(Ordering::Acquire) == epoch
                                };
                                let result = (|| -> Result<Artifact> {
                                    ensure!(allowed(), "Snapshot cancelled");
                                    let png = match pixels.data {
                                        screenshot_native::Data::Png(bytes) => {
                                            browser_screenshot::redact_png(
                                                &bytes,
                                                &pixels.geometry,
                                            )?
                                        }
                                        screenshot_native::Data::Raw {
                                            width,
                                            height,
                                            stride,
                                            bytes,
                                            channels,
                                        } => browser_screenshot::redact_raw(
                                            width,
                                            height,
                                            stride,
                                            &bytes,
                                            channels,
                                            &pixels.geometry,
                                        )?,
                                    };
                                    ensure!(allowed(), "Snapshot cancelled");
                                    let root = Directory::open(&directory)?;
                                    ensure!(allowed(), "Snapshot cancelled");
                                    root.write(&png)
                                })()
                                .map_err(|error| error.to_string());
                                if let Err(
                                    mpsc::TrySendError::Disconnected(Ok(artifact))
                                    | mpsc::TrySendError::Full(Ok(artifact)),
                                ) = sender.try_send(result)
                                {
                                    let _ = artifact.discard();
                                }
                            });
                            if started {
                                job.encoded = Some(receiver);
                            } else {
                                job.failure = Some("Snapshot encoder worker did not start".into());
                            }
                        }
                        Ok(_) => {
                            job.failure = Some("Snapshot source changed or was cancelled".into())
                        }
                        Err(error) => job.failure = Some(error.into()),
                    }
                }
                Err(TryRecvError::Disconnected) => {
                    job.raw = None;
                    job.failure = Some("Native snapshot callback returned no result".into());
                }
                Err(TryRecvError::Empty) => {}
            }
        }
        if let Some(receiver) = &job.encoded {
            match receiver.try_recv() {
                Ok(result) => {
                    job.encoded = None;
                    match result {
                        Ok(artifact) => job.artifact = Some(artifact),
                        Err(error) => job.failure = Some(error),
                    }
                }
                Err(TryRecvError::Disconnected) => {
                    job.encoded = None;
                    job.failure = Some("Snapshot worker returned no result".into());
                }
                Err(TryRecvError::Empty) => {}
            }
        }
        let status = self.worker.status();
        if status.unjoined != 0
            || !job.native_returned.load(Ordering::Acquire)
            || job.raw.is_some()
            || job.encoded.is_some()
        {
            return None;
        }
        if let Some(ack) = job.worker_ack.take() {
            ack.ack();
        }
        let mut job = self.job.take().expect("owned snapshot job");
        let result = if job.binding.current()
            && source_matches(&job.binding)
            && !callbacks.closed()
            && job.artifact.as_ref().is_some_and(Artifact::matches)
        {
            let artifact = job.artifact.take().unwrap();
            json!({"path":artifact.path(),"mimeType":"image/png","tab":job.binding.tab,"width":artifact.width(),"height":artifact.height(),"truncated":job.truncated,"fullPage":matches!(job.request.action,coincide_core::browser_protocol::BrowserAction::Screenshot{full_page:true})})
        } else {
            let cleanup = job.artifact.take().map(Artifact::discard).transpose();
            json!({"error":job.failure.unwrap_or_else(||"Snapshot source changed or was cancelled".into()),"cleanupRetained":cleanup.is_err()})
        };
        Some(BrowserReply {
            id: job.request.id,
            thread_id: job.request.thread_id,
            result,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::browser_protocol::BrowserAction;
    use std::time::{Duration, Instant};
    fn pending(
        owner: &mut Owner,
        delivered: bool,
    ) -> mpsc::SyncSender<Result<screenshot_native::Pixels, &'static str>> {
        let (sender, receiver) = mpsc::sync_channel(1);
        owner.job = Some(Pending {
            request: BrowserRequest {
                id: "private-test".into(),
                thread_id: uuid::Uuid::new_v4().to_string(),
                tab: None,
                frame: None,
                action: BrowserAction::Screenshot { full_page: false },
            },
            binding: Binding {
                thread: "owned-thread".into(),
                tab: "owned-tab".into(),
                url: "https://owned.test/".into(),
                epoch: 7,
                navigation: Arc::new(AtomicU64::new(7)),
                protected: Arc::new(AtomicBool::new(false)),
                cancelled: Arc::new(AtomicBool::new(false)),
            },
            raw: Some(receiver),
            encoded: None,
            artifact: None,
            truncated: false,
            failure: None,
            worker_ack: None,
            native_returned: Arc::new(AtomicBool::new(delivered)),
        });
        sender
    }
    fn pixels() -> screenshot_native::Pixels {
        let png = coincide_core::appshots::encode_rgba(2, 2, vec![255; 16]).unwrap();
        screenshot_native::Pixels {
            data: screenshot_native::Data::Png(png),
            geometry: browser_screenshot::Geometry::checked(2., 2., vec![]).unwrap(),
            truncated: false,
        }
    }
    #[test]
    fn published_reply_reports_truncation_and_contains_only_redacted_raw_pixels() {
        let temp = tempfile::tempdir().unwrap();
        let mut owner = Owner::new(temp.path().join("snapshots"));
        let callbacks = Callbacks::default();
        let mask = browser_screenshot::Rect {
            x: 0.,
            y: 0.,
            width: 1.,
            height: 1.,
        };
        pending(&mut owner, true)
            .send(Ok(screenshot_native::Pixels {
                data: screenshot_native::Data::Raw {
                    width: 6,
                    height: 2,
                    stride: 24,
                    bytes: vec![255; 48],
                    channels: browser_screenshot::Channels::cairo_argb32(),
                },
                geometry: browser_screenshot::Geometry::checked(6., 2., vec![mask]).unwrap(),
                truncated: true,
            }))
            .unwrap_or_else(|_| panic!("private callback receiver"));
        let deadline = Instant::now() + Duration::from_secs(5);
        let reply = loop {
            if let Some(reply) = owner.poll(&callbacks, |_| true) {
                break reply;
            }
            assert!(Instant::now() < deadline, "owned encoder must return");
            std::thread::yield_now();
        };
        assert_eq!(reply.result["truncated"], true);
        assert_eq!(reply.result["fullPage"], false);
        assert_eq!(
            (
                reply.result["width"].as_u64(),
                reply.result["height"].as_u64()
            ),
            (Some(6), Some(2))
        );
        let image = image::open(reply.result["path"].as_str().unwrap())
            .unwrap()
            .into_rgba8();
        assert_eq!(image.get_pixel(0, 0).0, [32, 32, 32, 255]);
        assert_eq!(image.get_pixel(5, 1).0, [255; 4]);
        assert_eq!(callbacks.pending(), 0);
    }
    #[test]
    fn screenshot_cancel_waits_for_actual_worker_return_and_discards_stale_artifact() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("snapshots");
        let mut owner = Owner::new(path.clone());
        let callbacks = Callbacks::default();
        pending(&mut owner, true)
            .send(Ok(pixels()))
            .unwrap_or_else(|_| panic!("private callback receiver"));
        let _ = owner.poll(&callbacks, |_| true);
        owner.close();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(reply) = owner.poll(&callbacks, |_| false) {
                assert!(reply.result.get("path").is_none());
                assert_eq!(reply.result["cleanupRetained"], false);
                break;
            }
            assert!(
                Instant::now() < deadline,
                "owned screenshot encoder must actually return"
            );
            std::thread::yield_now();
        }
        assert_eq!(owner.worker.status().unjoined, 0);
        assert_eq!(callbacks.pending(), 0);
        assert!(!path.exists() || std::fs::read_dir(path).unwrap().next().is_none());
    }
    #[test]
    fn unknown_native_callback_release_cannot_ack_or_reopen_admission() {
        let temp = tempfile::tempdir().unwrap();
        let mut owner = Owner::new(temp.path().join("snapshots"));
        let callbacks = Callbacks::default();
        drop(pending(&mut owner, false));
        assert!(owner.poll(&callbacks, |_| true).is_none());
        assert!(owner.pending("owned-thread", "owned-tab"));
        owner.close();
        assert!(owner.poll(&callbacks, |_| false).is_none());
        assert!(
            owner.job.is_some(),
            "an absent native callback is not an actual SDK return"
        );
    }
    #[test]
    fn screenshot_publication_is_bound_to_original_navigation_and_private_state() {
        let temp = tempfile::tempdir().unwrap();
        let mut owner = Owner::new(temp.path().join("snapshots"));
        let callbacks = Callbacks::default();
        pending(&mut owner, true)
            .send(Ok(pixels()))
            .unwrap_or_else(|_| panic!("private callback receiver"));
        owner
            .job
            .as_ref()
            .unwrap()
            .binding
            .navigation
            .store(8, Ordering::Release);
        let reply = owner
            .poll(&callbacks, |_| true)
            .expect("stale pixels never start a worker");
        assert!(reply.result.get("path").is_none());
        assert_eq!(owner.worker.status().returned, 0);
        pending(&mut owner, true)
            .send(Ok(pixels()))
            .unwrap_or_else(|_| panic!("private callback receiver"));
        owner
            .job
            .as_ref()
            .unwrap()
            .binding
            .protected
            .store(true, Ordering::Release);
        assert!(
            owner
                .poll(&callbacks, |_| true)
                .unwrap()
                .result
                .get("path")
                .is_none()
        );
    }
}
