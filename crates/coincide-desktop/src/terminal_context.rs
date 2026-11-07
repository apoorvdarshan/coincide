//! Explicit terminal→composer handoff. Opaque source identity and receipt custody stay owned.
use super::*;
use coincide_core::composer_context::ExpectedContext;
#[derive(Clone)]
pub(crate) struct ComposerBaseline {
    pub thread: String,
    pub draft: String,
    pub context: ExpectedContext,
}
#[derive(Clone)]
pub(crate) struct SelectionRequest {
    pub(super) thread: String,
    pub(super) pane: PaneId,
    pub(super) terminal: String,
    pub(super) ticket: u64,
    pub(super) revision: u64,
    pub(super) start: TerminalPoint,
    pub(super) end: TerminalPoint,
    /// Swift's "Send Last Command's Output to Agent": Core finds the newest
    /// command and its output by the shell's prompt marks, not by this range.
    pub(super) last_output: bool,
    epoch: Arc<AtomicU64>,
    generation: u64,
}
impl SelectionRequest {
    pub(super) fn current(&self) -> bool {
        self.epoch.load(Ordering::Acquire) == self.generation
    }
    pub(super) fn params(&self, baseline: &ComposerBaseline) -> Value {
        let mut params = json!({"threadId":baseline.thread,"expectedDraft":baseline.draft,"expectedContext":baseline.context,"terminalId":self.terminal,"revision":self.revision});
        if self.last_output {
            params["lastOutput"] = json!(true);
        } else {
            params["start"] = json!(self.start);
            params["end"] = json!(self.end);
        }
        params
    }
    /// What the composer was given, for the window's status line.
    pub(crate) fn subject(&self) -> &'static str {
        if self.last_output {
            "The last command’s output"
        } else {
            "Terminal selection"
        }
    }
}
#[derive(Clone)]
pub(crate) enum TerminalContextEvent {
    LastClosed,
    /// The header's Hide Terminal button.
    HideRequested,
    Requested(SelectionRequest),
    Completed {
        request: SelectionRequest,
        baseline: ComposerBaseline,
        result: std::result::Result<Value, String>,
        fresh: bool,
    },
}
impl EventEmitter<TerminalContextEvent> for TerminalWorkspace {}
impl TerminalWorkspace {
    pub(super) fn drain_context_shutdown(&mut self) {
        for update in self.rx.try_iter().take(64) {
            if let Update::ContextAttached(_, _, result) = update {
                self.context_pending = false;
                self.context_shutdown_receipts.push(result);
            }
        }
    }
    pub(crate) fn invalidate_context(&self) {
        self.context_epoch.fetch_add(1, Ordering::AcqRel);
    }
    pub(crate) fn selection_request_current(&self, request: &SelectionRequest) -> bool {
        self.visible
            && !self.stopping.load(Ordering::Acquire)
            && request.thread == self.thread
            && Arc::ptr_eq(&request.epoch, &self.context_epoch)
            && request.current()
            && self.ids().contains(&request.pane)
            && self.panes.get(&request.pane).is_some_and(|pane| {
                !pane.closing
                    && pane.terminal.as_ref() == Some(&request.terminal)
                    && pane.ticket == request.ticket
                    && pane
                        .frame
                        .as_ref()
                        .is_some_and(|frame| frame["revision"].as_u64() == Some(request.revision))
            })
    }
    pub(crate) fn queue_context_selection(
        &mut self,
        request: SelectionRequest,
        baseline: ComposerBaseline,
        cx: &mut Context<Self>,
    ) {
        let last_output = request.last_output;
        if self.context_pending
            || !self.selection_request_current(&request)
            || baseline.thread != self.thread
        {
            self.notice = "Terminal pane or composer changed; select again.".into();
        } else if self
            .tx
            .try_send(Command::AttachSelection(request, baseline))
            .is_ok()
        {
            self.context_pending = true;
            self.notice = if last_output {
                "Attaching the last command’s output…"
            } else {
                "Attaching selected terminal output…"
            }
            .into();
        } else {
            self.notice = "Terminal selection not queued; worker busy.".into();
        }
        cx.notify();
    }
    pub(super) fn request_context_selection(&mut self, key: PaneId, cx: &mut Context<Self>) {
        let result = (|| -> Result<SelectionRequest> {
            ensure!(
                self.visible
                    && !self.context_pending
                    && !self.stopping.load(Ordering::Acquire)
                    && self.ids().contains(&key),
                "Terminal pane is not available"
            );
            let pane = self
                .panes
                .get(&key)
                .ok_or_else(|| anyhow::anyhow!("Terminal pane is unavailable"))?;
            ensure!(!pane.closing, "Terminal is closing");
            let terminal = pane
                .terminal
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Wait for terminal"))?;
            let frame = pane
                .frame
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Wait for terminal output"))?;
            let (start, end) = selection_bounds(&pane.selection, terminal, frame)?;
            // Same visible-grid filtering as Copy; Core rederives it from the actual screen.
            let visible = coincide_core::terminal::selected_text(frame, start, end)?;
            ensure!(
                visible.len() <= 32 * 1024 && visible.chars().any(|ch| !ch.is_whitespace()),
                "Select nonblank terminal output of at most 32 KiB"
            );
            Ok(SelectionRequest {
                thread: self.thread.clone(),
                pane: key,
                terminal: terminal.clone(),
                ticket: pane.ticket,
                revision: frame["revision"]
                    .as_u64()
                    .ok_or_else(|| anyhow::anyhow!("Invalid terminal revision"))?,
                start,
                end,
                last_output: false,
                epoch: self.context_epoch.clone(),
                generation: self.context_epoch.load(Ordering::Acquire),
            })
        })();
        match result {
            Ok(request) => cx.emit(TerminalContextEvent::Requested(request)),
            Err(error) => {
                self.notice = error.to_string();
                cx.notify();
            }
        }
    }
    /// Swift's "Send Last Command's Output to Agent" (⇧⌘L): the same bounded
    /// request and receipt path as a selection, for the frame on screen.
    pub(super) fn request_last_output(&mut self, key: PaneId, cx: &mut Context<Self>) {
        let result = (|| -> Result<SelectionRequest> {
            ensure!(
                self.visible
                    && !self.context_pending
                    && !self.stopping.load(Ordering::Acquire)
                    && self.ids().contains(&key),
                "Terminal pane is not available"
            );
            let pane = self
                .panes
                .get(&key)
                .ok_or_else(|| anyhow::anyhow!("Terminal pane is unavailable"))?;
            ensure!(!pane.closing, "Terminal is closing");
            let terminal = pane
                .terminal
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Wait for terminal"))?;
            let frame = pane
                .frame
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Wait for terminal output"))?;
            ensure!(
                frame["shell"]["command"].is_string(),
                "Run a command in this terminal first"
            );
            let origin = TerminalPoint { row: 0, col: 0 };
            Ok(SelectionRequest {
                thread: self.thread.clone(),
                pane: key,
                terminal: terminal.clone(),
                ticket: pane.ticket,
                revision: frame["revision"]
                    .as_u64()
                    .ok_or_else(|| anyhow::anyhow!("Invalid terminal revision"))?,
                start: origin,
                end: origin,
                last_output: true,
                epoch: self.context_epoch.clone(),
                generation: self.context_epoch.load(Ordering::Acquire),
            })
        })();
        match result {
            Ok(request) => cx.emit(TerminalContextEvent::Requested(request)),
            Err(error) => {
                self.notice = error.to_string();
                cx.notify();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    struct Worker {
        tx: SyncSender<Command>,
        rx: Receiver<Update>,
        join: std::thread::JoinHandle<()>,
        calls: Arc<Mutex<Vec<(String, Value)>>>,
        epoch: Arc<AtomicU64>,
    }
    impl Worker {
        fn new(revoke_after_commit: bool) -> Self {
            let (tx, commands) = mpsc::sync_channel(8);
            let (updates, rx) = mpsc::sync_channel(8);
            let calls = Arc::new(Mutex::new(vec![]));
            let ordinary = calls.clone();
            let attached = calls.clone();
            let epoch = Arc::new(AtomicU64::new(0));
            let join = std::thread::spawn(move || {
                run_worker(
                    "thread-A".into(),
                    commands,
                    updates,
                    &AtomicBool::new(false),
                    move |method, params| {
                        ordinary.lock().unwrap().push((method.into(), params));
                        ensure!(
                            matches!(method, "terminal.list" | "terminal.input"),
                            "Unexpected non-terminal call"
                        );
                        Ok(json!([]))
                    },
                    |_| Ok(None),
                    move |request, baseline| {
                        attached
                            .lock()
                            .unwrap()
                            .push(("attach-controller".into(), request.params(baseline)));
                        if revoke_after_commit {
                            request.epoch.fetch_add(1, Ordering::AcqRel);
                        }
                        Ok(
                            json!({"threadId":baseline.thread,"draftContext":[{"kind":"terminal","text":"selected"}]}),
                        )
                    },
                )
            });
            let worker = Self {
                tx,
                rx,
                join,
                calls,
                epoch,
            };
            assert!(matches!(worker.next(), Update::Listed(Ok(_))));
            worker
                .tx
                .send(Command::Adopt(10, "terminal-A".into()))
                .unwrap();
            worker
        }
        fn request(&self) -> SelectionRequest {
            SelectionRequest {
                thread: "thread-A".into(),
                pane: 10,
                terminal: "terminal-A".into(),
                ticket: 0,
                revision: 7,
                start: TerminalPoint { row: 0, col: 1 },
                end: TerminalPoint { row: 1, col: 3 },
                last_output: false,
                epoch: self.epoch.clone(),
                generation: 0,
            }
        }
        fn baseline(&self) -> ComposerBaseline {
            ComposerBaseline {
                thread: "thread-A".into(),
                draft: "  exact café 中文 draft\n".into(),
                context: ExpectedContext {
                    present: true,
                    value: json!([{"id":"opaque-existing","kind":"quote","text":"kept","unknown":[1,false]}]),
                },
            }
        }
        fn next(&self) -> Update {
            self.rx
                .recv_timeout(Duration::from_secs(3))
                .expect("actual worker reply")
        }
        fn finish(self) {
            drop(self.tx);
            drop(self.rx);
            self.join.join().unwrap();
        }
    }
    #[::core::prelude::v1::test]
    fn real_worker_forwards_only_explicit_exact_scope_and_no_copy_send_or_pty_input() {
        let w = Worker::new(false);
        let request = w.request();
        let baseline = w.baseline();
        let expected = request.params(&baseline);
        w.tx.send(Command::AttachSelection(request, baseline))
            .unwrap();
        let Update::ContextAttached(request, _, Ok(saved)) = w.next() else {
            panic!("owned receipt missing")
        };
        assert!(request.current());
        assert_eq!(saved["threadId"], "thread-A");
        let log = w.calls.lock().unwrap().clone();
        assert_eq!(log.len(), 2);
        assert_eq!(log[0].0, "terminal.list");
        assert_eq!(log[1], ("attach-controller".into(), expected));
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn real_worker_refuses_stale_pane_terminal_ticket_thread_and_revoked_composer_before_controller()
     {
        for case in 0..6 {
            let w = Worker::new(false);
            let mut request = w.request();
            let mut baseline = w.baseline();
            match case {
                0 => request.pane = 999,
                1 => request.terminal = "terminal-B".into(),
                2 => request.ticket = 1,
                3 => request.thread = "thread-B".into(),
                4 => baseline.thread = "thread-B".into(),
                _ => {
                    w.epoch.fetch_add(1, Ordering::AcqRel);
                }
            }
            w.tx.send(Command::AttachSelection(request, baseline))
                .unwrap();
            assert!(
                matches!(w.next(), Update::ContextAttached(_, _, Err(_))),
                "case {case}"
            );
            assert_eq!(
                w.calls.lock().unwrap().len(),
                1,
                "stale request reached attach controller"
            );
            w.finish();
        }
        let w = Worker::new(false);
        w.tx.send(Command::Act(
            10,
            1,
            Action::Input(TerminalInput::Text {
                text: "new explicit terminal input".into(),
            }),
        ))
        .unwrap();
        w.tx.send(Command::AttachSelection(w.request(), w.baseline()))
            .unwrap();
        assert!(matches!(w.next(), Update::ContextAttached(_, _, Err(_))));
        assert_eq!(
            w.calls
                .lock()
                .unwrap()
                .iter()
                .filter(|(method, _)| method == "attach-controller")
                .count(),
            0
        );
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn last_output_request_names_no_range_and_takes_the_same_admission_path() {
        let w = Worker::new(false);
        let mut request = w.request();
        request.last_output = true;
        let baseline = w.baseline();
        let params = request.params(&baseline);
        assert_eq!(params["lastOutput"], true);
        assert!(params.get("start").is_none() && params.get("end").is_none());
        assert_eq!(request.subject(), "The last command’s output");
        w.tx.send(Command::AttachSelection(request, baseline))
            .unwrap();
        assert!(matches!(w.next(), Update::ContextAttached(_, _, Ok(_))));
        let log = w.calls.lock().unwrap().clone();
        assert_eq!(log[1], ("attach-controller".into(), params));
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn actual_worker_keeps_successful_commit_receipt_after_later_generation_revocation() {
        let w = Worker::new(true);
        w.tx.send(Command::AttachSelection(w.request(), w.baseline()))
            .unwrap();
        let Update::ContextAttached(request, baseline, Ok(saved)) = w.next() else {
            panic!("post-admission commit was hidden")
        };
        assert!(!request.current());
        assert_eq!(baseline.thread, "thread-A");
        assert_eq!(saved["draftContext"][0]["text"], "selected");
        assert_eq!(
            w.calls
                .lock()
                .unwrap()
                .iter()
                .filter(|(method, _)| method == "attach-controller")
                .count(),
            1
        );
        w.finish();
    }
}

impl TerminalWorkspace {
    pub(crate) fn focused_context_selection_available(&self, window: &Window) -> bool {
        self.is_focused(window)
            && !self.context_pending
            && !self.stopping.load(Ordering::Acquire)
            && self.ids().iter().any(|id| {
                self.panes.get(id).is_some_and(|pane| {
                    if pane.closing || !pane.focus.is_focused(window) {
                        return false;
                    }
                    let (Some(terminal), Some(frame)) =
                        (pane.terminal.as_ref(), pane.frame.as_ref())
                    else {
                        return false;
                    };
                    selection_bounds(&pane.selection, terminal, frame)
                        .ok()
                        .and_then(|(start, end)| {
                            coincide_core::terminal::selected_text(frame, start, end).ok()
                        })
                        .is_some_and(|text| {
                            text.len() <= 32 * 1024 && text.chars().any(|ch| !ch.is_whitespace())
                        })
                })
            })
    }
    /// The shared Add Selection command uses only the pane that actually owns
    /// focus, then follows the existing bounded request/receipt admission path.
    pub(crate) fn request_focused_context_selection(
        &mut self,
        window: &Window,
        cx: &mut Context<Self>,
    ) {
        if !self.is_focused(window) {
            return;
        }
        let focused = self.ids().into_iter().find(|id| {
            self.panes
                .get(id)
                .is_some_and(|pane| !pane.closing && pane.focus.is_focused(window))
        });
        if let Some(pane) = focused {
            self.request_context_selection(pane, cx);
        }
    }
}
