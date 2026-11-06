//! Retained native Git workflow; semantic replies never release actual workers.
use super::*;
use crate::{
    instructions::git::{Applied, Review},
    worker_owner::{ShutdownStatus, WorkerOwner},
};
use coincide_core::agent::native_instruction_git::{Runner, StoreSource};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc,
};
enum Effect {
    Reviewed(Review),
    Applied(Applied),
}
struct Reply {
    epoch: u64,
    result: std::result::Result<Effect, String>,
}
pub(super) struct State {
    workers: WorkerOwner,
    cancel: Arc<AtomicBool>,
    epoch: Arc<AtomicU64>,
    sender: mpsc::SyncSender<Reply>,
    receiver: mpsc::Receiver<Reply>,
    pending: bool,
    picker: bool,
    failed: bool,
    queued: Option<Reply>,
    review: Option<Review>,
    remote: Option<usize>,
    status: String,
}
impl State {
    pub(super) fn new() -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        Self {
            workers: WorkerOwner::default(),
            cancel: Arc::new(AtomicBool::new(false)),
            epoch: Arc::new(AtomicU64::new(0)),
            sender,
            receiver,
            pending: false,
            picker: false,
            failed: false,
            queued: None,
            review: None,
            remote: None,
            status: String::new(),
        }
    }
    pub(super) fn busy(&self) -> bool {
        self.pending || self.picker || self.failed || self.workers.closed()
    }
    pub(super) fn reviewing(&self) -> bool {
        self.review.is_some()
    }
    pub(super) fn invalidate(&mut self) {
        self.cancel.store(true, Ordering::Release);
        self.epoch.fetch_add(1, Ordering::AcqRel);
        self.review = None;
    }
    fn start(&mut self) -> u64 {
        self.cancel = Arc::new(AtomicBool::new(false));
        self.pending = true;
        self.review = None;
        self.epoch.fetch_add(1, Ordering::AcqRel) + 1
    }
    fn close(&mut self) -> ShutdownStatus {
        self.invalidate();
        self.workers.close();
        self.workers.status()
    }
}
fn admitted(
    admission: &crate::worker_owner::Admission,
    epoch: &AtomicU64,
    expected: u64,
    cancel: &AtomicBool,
) -> Result<()> {
    anyhow::ensure!(
        admission.allowed()
            && epoch.load(Ordering::Acquire) == expected
            && !cancel.load(Ordering::Acquire),
        "Native Git context changed or sync was cancelled"
    );
    Ok(())
}
impl InstructionsPanel {
    fn choose_git_repository(&mut self, cx: &mut Context<Self>) {
        if !self.setup_clean(cx) || self.setup.git.busy() {
            return;
        }
        if self.setup.copy.native_scope().is_none() {
            self.setup.git.status = "Choose an instruction file copy first.".into();
            cx.notify();
            return;
        }
        if !self.setup.git.workers.begin_picker() {
            self.setup.git.status = "Git owner is still finishing cleanup.".into();
            cx.notify();
            return;
        }
        self.setup.git.picker = true;
        self.setup.git.invalidate();
        let expected = self.setup.git.epoch.load(Ordering::Acquire);
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Choose instruction copy repository".into()),
        });
        self.setup.picker = Some(cx.spawn(async move |this, cx| {
            let result: Result<_> = async { picker.await? }.await;
            let _ = this.update(cx, |this, cx| {
                this.setup.git.picker = false;
                let open = this.setup.git.workers.finish_picker();
                if !open
                    || this.setup.git.epoch.load(Ordering::Acquire) != expected
                    || this.dirty(cx)
                {
                    this.setup.git.status =
                        "Repository choice expired; no Git operation was started.".into();
                    cx.notify();
                    return;
                }
                match result {
                    Ok(Some(paths)) if paths.len() == 1 => {
                        this.inspect_git_repository(paths[0].clone(), cx)
                    }
                    Ok(None) => {
                        this.setup.git.status = "Repository choice cancelled".into();
                        cx.notify();
                    }
                    Ok(_) => {
                        this.setup.git.status = "Choose one repository directory".into();
                        cx.notify();
                    }
                    Err(_) => {
                        this.setup.git.status = "Repository picker failed".into();
                        cx.notify();
                    }
                }
            });
        }));
        cx.notify();
    }
    fn inspect_git_repository(&mut self, path: PathBuf, cx: &mut Context<Self>) {
        let source = (|| -> Result<_> {
            let copy = self
                .setup
                .copy
                .native_scope()
                .context("Choose a native file copy")?;
            let owner = crate::try_state(&self.setup.engine)?;
            copy.validate_native(&owner.store)?;
            let source = StoreSource::capture(&owner.store)?;
            let baseline = Metadata::from_document(owner.store.document("instructions.json")?)?;
            Ok((copy, source, baseline))
        })();
        let (copy, source, baseline) = match source {
            Ok(value) => value,
            Err(error) => {
                self.setup.git.status = error.to_string();
                cx.notify();
                return;
            }
        };
        let expected = self.setup.git.start();
        let cancel = self.setup.git.cancel.clone();
        let epoch = self.setup.git.epoch.clone();
        let sender = self.setup.git.sender.clone();
        let engine = self.setup.engine.clone();
        let scope = copy.clone();
        let anchor = source.clone();
        if !self.setup.git.workers.spawn(move |admission| {
            let validate = || -> Result<()> {
                admitted(&admission, &epoch, expected, &cancel)?;
                let owner = crate::try_state(&engine)?;
                anchor.validate(&owner.store)?;
                scope.validate_native(&owner.store)?;
                anyhow::ensure!(
                    Metadata::from_document(owner.store.document("instructions.json")?)?.document
                        == baseline.document,
                    "Instruction configuration changed; review Git again"
                );
                Ok(())
            };
            let result = (|| {
                validate()?;
                Review::capture(path, copy, source, Runner::system()?, &cancel, validate)
                    .map(Effect::Reviewed)
            })()
            .map_err(|e: anyhow::Error| e.to_string());
            let _ = sender.send(Reply {
                epoch: expected,
                result,
            });
        }) {
            self.setup.git.pending = false;
            self.setup.git.status =
                "Git review could not start; owned cleanup is still pending.".into();
        } else {
            self.setup.git.status = "Reading the selected repository for native review…".into();
        }
        cx.notify();
    }
    fn apply_git_copy(&mut self, push: bool, cx: &mut Context<Self>) {
        if self.dirty(cx) || self.setup.git.busy() {
            self.setup.git.status =
                "Save or discard master edits and wait for Git cleanup first.".into();
            cx.notify();
            return;
        }
        let Some(review) = self.setup.git.review.take() else {
            return;
        };
        let (source, scope) = review.owner_tokens();
        let baseline = (|| -> Result<_> {
            let owner = crate::try_state(&self.setup.engine)?;
            review.validate_source(&owner.store)?;
            Metadata::from_document(owner.store.document("instructions.json")?)
        })();
        let baseline = match baseline {
            Ok(value) => value,
            Err(e) => {
                self.setup.git.status = e.to_string();
                cx.notify();
                return;
            }
        };
        let remote = self.setup.git.remote;
        let expected = self.setup.git.start();
        let cancel = self.setup.git.cancel.clone();
        let epoch = self.setup.git.epoch.clone();
        let sender = self.setup.git.sender.clone();
        let engine = self.setup.engine.clone();
        if !self.setup.git.workers.spawn(move |admission| {
            let owner = || -> Result<()> {
                admitted(&admission, &epoch, expected, &cancel)?;
                let owner = crate::try_state(&engine)?;
                source.validate(&owner.store)?;
                scope.validate_native(&owner.store)?;
                anyhow::ensure!(
                    Metadata::from_document(owner.store.document("instructions.json")?)?.document
                        == baseline.document,
                    "Instruction configuration changed; Git was stopped"
                );
                Ok(())
            };
            let result = review
                .apply(remote, push, &cancel, owner)
                .map(Effect::Applied)
                .map_err(|e| e.to_string());
            let _ = sender.send(Reply {
                epoch: expected,
                result,
            });
        }) {
            self.setup.git.pending = false;
            self.setup.git.status =
                "Git sync could not start; owned cleanup is still pending.".into();
        } else {
            self.setup.git.status = "Synchronizing the reviewed Git copy…".into();
        }
        cx.notify();
    }
    pub(crate) fn poll_instruction_git(&mut self, cx: &mut Context<Self>) {
        if self.setup.git.queued.is_none() {
            self.setup.git.queued = self.setup.git.receiver.try_recv().ok();
        }
        let status = self.setup.git.workers.status();
        if status.panicked != 0 || status.unclassified != 0 {
            self.setup.git.failed = true;
            self.setup.git.status = "Git worker cleanup failed; another sync cannot start.".into();
            cx.notify();
            return;
        }
        if status.unjoined != 0 {
            return;
        }
        let Some(reply) = self.setup.git.queued.take() else {
            return;
        };
        self.setup.git.pending = false;
        if reply.epoch != self.setup.git.epoch.load(Ordering::Acquire) || status.closed {
            self.setup.git.status =
                "Git workflow returned after cancellation. Review the repository before retrying."
                    .into();
            cx.notify();
            return;
        }
        match reply.result {
            Ok(Effect::Reviewed(review)) => {
                self.setup.git.remote = (!review.remotes.is_empty()).then_some(0);
                self.setup.git.status =
                    "Review the exact copy, branch and remote before applying Git changes.".into();
                self.setup.git.review = Some(review);
            }
            Ok(Effect::Applied(applied)) => {
                self.setup.git.status = format!(
                    "Git copy finished. Commit: {} · Pulled: {} · Pushed: {}.",
                    applied.committed, applied.pulled, applied.pushed
                );
                self.prepare_copy_sync(cx);
            }
            Err(error) => {
                self.setup.git.status = format!(
                    "Git sync stopped: {error}. Local changes may have completed; inspect the repository before retrying."
                )
            }
        };
        cx.notify();
    }
    pub(crate) fn request_instruction_git_shutdown(&mut self) {
        self.setup.git.close();
    }
    pub(crate) fn instruction_git_shutdown_status(&mut self) -> ShutdownStatus {
        self.setup.git.workers.status()
    }
    pub(super) fn git_copy_controls(&self, cx: &mut Context<Self>) -> AnyElement {
        let state = &self.setup.git;
        let disabled = state.busy()
            || self.setup.review.is_some()
            || self.setup.has_copy_review()
            || self.setup.picker_pending;
        let mut pane=div().flex().flex_col().gap_2().child(div().text_lg().child("Git Copy Sync")).child("Choose the repository containing your selected file copy. Git can commit that file, pull this repository, and push only instruction-copy history. Other local edits are never stashed or discarded.")
            .child(Button::new("instructions-git-repository").label("Review Repository…").disabled(disabled||self.setup.copy.native_scope().is_none()).on_click(cx.listener(|this,_,_,cx|this.choose_git_repository(cx))));
        if state.pending {
            pane = pane.child(
                Button::new("instructions-git-cancel")
                    .label("Cancel Git Sync")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.setup.git.invalidate();
                        this.setup.git.status =
                            "Cancelling and waiting for owned Git cleanup…".into();
                        cx.notify();
                    })),
            );
        }
        if let Some(review) = &state.review {
            pane = pane
                .child(format!(
                    "Repository: {}",
                    review.repository_path().display()
                ))
                .child(format!(
                    "Copy: {} · Branch: {}",
                    review.relative_copy, review.branch
                ))
                .child(
                    div()
                        .id("instructions-git-copy-preview")
                        .max_h(px(140.))
                        .overflow_y_scroll()
                        .font_family("monospace")
                        .child(review.copy_text().to_owned()),
                );
            let mut remotes = div().flex().flex_wrap().gap_1();
            for (index, _) in review.remotes.iter().enumerate() {
                remotes = remotes.child(
                    Button::new(SharedString::from(format!(
                        "instructions-git-remote-{index}"
                    )))
                    .label(review.remote_label(index).to_owned())
                    .when(state.remote == Some(index), |b| b.primary())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.setup.git.remote = Some(index);
                        cx.notify();
                    })),
                );
            }
            if state.remote.is_some_and(|index| !review.can_push(index)) {
                pane=pane.child("Different fetch/push destinations require a manual Git push. Commit and pull remain available.");
            }
            if let Some(upstream) = &review.upstream {
                pane = pane.child(format!("Pull from: {upstream}"));
            }
            pane = pane.child(remotes).child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(
                        Button::new("instructions-git-review-cancel")
                            .label("Cancel Review")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.setup.git.review = None;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("instructions-git-commit")
                            .label("Commit and Pull")
                            .disabled(state.busy())
                            .on_click(cx.listener(|this, _, _, cx| this.apply_git_copy(false, cx))),
                    )
                    .child(
                        Button::new("instructions-git-push")
                            .label("Commit, Pull and Push")
                            .disabled(
                                state.busy()
                                    || !state.remote.is_some_and(|index| review.can_push(index)),
                            )
                            .on_click(cx.listener(|this, _, _, cx| this.apply_git_copy(true, cx))),
                    ),
            );
        }
        pane.child(state.status.clone()).into_any_element()
    }
}
