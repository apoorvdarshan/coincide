//! Source-bound, one-use native key phases. Native callbacks retain their own
//! actual custody even when a dialog/API reply or timeout finishes logically.
use super::native_keys::{Delivered, Phase};
use super::*;
use coincide_core::browser_protocol::keys::KeyPress;
#[derive(Clone, Debug, PartialEq, Eq)]
struct Binding {
    thread: String,
    tab: String,
    epoch: u64,
    url: String,
    active: Option<String>,
    visible: Option<String>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
    Focus,
    ReadyDown,
    Down,
    ReadyUp,
    Up,
    Done,
}
pub(super) enum Event {
    Focus {
        id: String,
        nonce: Uuid,
        result: Value,
    },
    Key {
        id: String,
        nonce: Uuid,
        phase: Phase,
        result: std::result::Result<Delivered, String>,
    },
}
pub(super) struct Pending {
    request: BrowserRequest,
    binding: Binding,
    key: KeyPress,
    stage: Stage,
    nonce: Uuid,
    deadline: Instant,
    replied: bool,
    down_acknowledged: bool,
}
impl Pending {
    fn source_matches(&self, current: Option<&Binding>, closed: bool, protected: bool) -> bool {
        !closed && !protected && current == Some(&self.binding)
    }
    fn phase(
        &mut self,
        current: Option<&Binding>,
        closed: bool,
        protected: bool,
        dialog: bool,
    ) -> Option<Phase> {
        if !self.source_matches(current, closed, protected) || dialog {
            return None;
        }
        let phase = match self.stage {
            Stage::ReadyDown => Phase::Down,
            Stage::ReadyUp => Phase::Up,
            _ => return None,
        };
        self.stage = if phase == Phase::Down {
            Stage::Down
        } else {
            Stage::Up
        };
        self.nonce = Uuid::new_v4();
        Some(phase)
    }
    fn focus_returned(&mut self, nonce: Uuid) -> bool {
        if self.stage != Stage::Focus || self.nonce != nonce {
            return false;
        }
        self.stage = Stage::ReadyDown;
        self.nonce = Uuid::new_v4();
        true
    }
    fn key_returned(&mut self, nonce: Uuid, phase: Phase, delivered: Delivered) -> bool {
        if nonce != self.nonce
            || !matches!(
                (self.stage, phase),
                (Stage::Down, Phase::Down) | (Stage::Up, Phase::Up)
            )
        {
            return false;
        }
        self.nonce = Uuid::new_v4();
        if phase == Phase::Down {
            self.down_acknowledged = true;
        }
        let finished = delivered == Delivered::Equivalent || phase == Phase::Up;
        self.stage = if finished {
            Stage::Done
        } else {
            Stage::ReadyUp
        };
        finished
    }
}
impl BrowserController {
    fn press_binding(&self, thread: &str, tab: &str, cx: &App) -> Option<Binding> {
        let view = self.tabs.get(thread)?.iter().find(|item| item.id == tab)?;
        Some(Binding {
            thread: thread.into(),
            tab: tab.into(),
            epoch: view.navigation.load(Ordering::Acquire),
            url: credential_native_address(view.view.read(cx).raw())?,
            active: self.active.get(thread).cloned(),
            visible: self.visible.clone(),
        })
    }
    pub(super) fn begin_press(
        &mut self,
        request: BrowserRequest,
        tab: String,
        cx: &App,
    ) -> Result<()> {
        ensure!(
            self.presses.len() < 16 && !self.presses.values().any(|p| p.binding.tab == tab),
            "A native key is already pending in this tab or capacity is reached"
        );
        let BrowserAction::Press { key, .. } = &request.action else {
            anyhow::bail!("Invalid native key request")
        };
        let key = KeyPress::admitted(key)?;
        let binding = self
            .press_binding(&request.thread_id, &tab, cx)
            .context("Native key source unavailable")?;
        let source =
            script_for_request(&request)?.context("Native key focus validation missing")?;
        let target = self
            .tabs
            .get(&binding.thread)
            .and_then(|tabs| tabs.iter().find(|item| item.id == tab))
            .context("Native key tab closed")?;
        ensure!(target.keys.available(), "Native page keys unavailable");
        let id = request.id.clone();
        let nonce = Uuid::new_v4();
        let sender = self.sender.clone();
        let callback_id = id.clone();
        target.view.read(cx).raw().evaluate_script_tracked(
            &source,
            &self.shutdown.callbacks,
            move |payload| {
                let result = parse_script_result(&payload);
                let _ = sender.try_send(NativeEvent::Press(Event::Focus {
                    id: callback_id.clone(),
                    nonce,
                    result,
                }));
            },
        )?;
        self.presses.insert(
            id,
            Pending {
                request,
                binding,
                key,
                stage: Stage::Focus,
                nonce,
                deadline: Instant::now() + Duration::from_secs(20),
                replied: false,
                down_acknowledged: false,
            },
        );
        Ok(())
    }
    pub(super) fn press_event(&mut self, event: Event) {
        match event {
            Event::Focus { id, nonce, result } => {
                let Some(pending) = self.presses.get_mut(&id) else {
                    return;
                };
                if pending.nonce != nonce || pending.stage != Stage::Focus {
                    return;
                }
                if result["focused"] != true {
                    self.finish_press(&id, json!({"error":"Native key focus validation failed"}));
                    return;
                }
                pending.focus_returned(nonce);
            }
            Event::Key {
                id,
                nonce,
                phase,
                result,
            } => {
                let Some(pending) = self.presses.get_mut(&id) else {
                    return;
                };
                if pending.nonce != nonce
                    || !matches!(
                        (pending.stage, phase),
                        (Stage::Down, Phase::Down) | (Stage::Up, Phase::Up)
                    )
                {
                    return;
                }
                match result {
                    Ok(delivered) => { if pending.key_returned(nonce,phase,delivered) { self.finish_press(&id,json!({"pressed":true,"nativeKeys":true})); } }
                    Err(_) => self.finish_press(&id,json!({"error":"Native key completion failed; do not replay automatically"})),
                }
            }
        }
    }
    fn finish_press(&mut self, id: &str, result: Value) {
        if let Some(pending) = self.presses.remove(id)
            && !pending.replied
        {
            self.replies.push_back(BrowserReply {
                id: pending.request.id,
                thread_id: pending.request.thread_id,
                result,
            });
        }
    }
    pub(super) fn poll_presses(&mut self, cx: &App) -> bool {
        let ids = self.presses.keys().cloned().collect::<Vec<_>>();
        let mut changed = false;
        for id in ids {
            let pending = &self.presses[&id];
            let current = self.press_binding(&pending.binding.thread, &pending.binding.tab, cx);
            let tab = self
                .tabs
                .get(&pending.binding.thread)
                .and_then(|tabs| tabs.iter().find(|tab| tab.id == pending.binding.tab));
            let protected =
                tab.is_none_or(|tab| tab.credential_console_suppressed.load(Ordering::Acquire));
            let dialog = tab.and_then(|tab| tab.dialogs.snapshot());
            if !pending.source_matches(
                current.as_ref(),
                self.shutdown.callbacks.closed(),
                protected,
            ) {
                let result = if pending.down_acknowledged {
                    json!({"pressed":true,"nativeKeys":true,"keyUpCancelledForChangedSource":true})
                } else {
                    json!({"error":"Native key source changed; completion is not confirmed and must not be replayed automatically"})
                };
                self.finish_press(&id, result);
                changed = true;
                continue;
            }
            if let Some(dialog) = dialog {
                let pending = self.presses.get_mut(&id).expect("pending key");
                if !pending.replied {
                    self.replies.push_back(BrowserReply {
                        id: id.clone(),
                        thread_id: pending.request.thread_id.clone(),
                        result: public_dialog_reply(&dialog, &pending.binding.tab, protected),
                    });
                    pending.replied = true;
                    changed = true;
                }
                if matches!(pending.stage, Stage::Focus | Stage::ReadyDown) {
                    self.presses.remove(&id);
                } else {
                    pending.deadline = Instant::now() + Duration::from_secs(20);
                }
                continue;
            }
            if Instant::now() >= pending.deadline {
                self.finish_press(&id,json!({"error":"Native key completion is unknown; do not replay automatically"}));
                changed = true;
                continue;
            }
            let pending = self.presses.get_mut(&id).expect("pending key");
            if let Some(phase) = pending.phase(current.as_ref(), false, false, false) {
                let nonce = pending.nonce;
                let sender = self.sender.clone();
                let callback_id = id.clone();
                let tab = self
                    .tabs
                    .get(&pending.binding.thread)
                    .and_then(|tabs| tabs.iter().find(|tab| tab.id == pending.binding.tab))
                    .expect("validated key tab");
                let result = tab.keys.dispatch(
                    &pending.key,
                    phase,
                    &self.shutdown.callbacks,
                    move |result| {
                        let _ = sender.try_send(NativeEvent::Press(Event::Key {
                            id: callback_id,
                            nonce,
                            phase,
                            result: result.map_err(|_| "Native key failed".into()),
                        }));
                    },
                );
                if result.is_err() {
                    self.finish_press(&id,json!({"error":"Native key dispatch failed; native completion may remain pending"}));
                }
                changed = true;
            }
        }
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pending() -> Pending {
        let thread = Uuid::new_v4().to_string();
        let tab = "synthetic-native-tab".to_owned();
        Pending {
            request: BrowserRequest {
                id: Uuid::new_v4().to_string(),
                thread_id: thread.clone(),
                tab: Some(tab.clone()),
                frame: None,
                action: BrowserAction::Press {
                    key: "Enter".into(),
                    selector: Some("#synthetic".into()),
                },
            },
            binding: Binding {
                thread,
                tab: tab.clone(),
                epoch: 7,
                url: "http://127.0.0.1:1234/owned".into(),
                active: Some(tab),
                visible: None,
            },
            key: KeyPress::admitted("Enter").unwrap(),
            stage: Stage::Focus,
            nonce: Uuid::new_v4(),
            deadline: Instant::now() + Duration::from_secs(20),
            replied: false,
            down_acknowledged: false,
        }
    }
    #[::core::prelude::v1::test]
    fn delayed_native_callbacks_admit_exactly_one_down_up_and_ignore_duplicate_stage_returns() {
        let mut press = pending();
        let source = press.binding.clone();
        let focus = press.nonce;
        assert!(press.focus_returned(focus));
        assert!(!press.focus_returned(focus));
        assert_eq!(
            press.phase(Some(&source), false, false, false),
            Some(Phase::Down)
        );
        let down = press.nonce;
        assert_eq!(press.phase(Some(&source), false, false, false), None);
        assert!(!press.key_returned(down, Phase::Down, Delivered::Event));
        let fresh = press.nonce;
        assert!(!press.key_returned(down, Phase::Down, Delivered::Event));
        assert_eq!(press.nonce, fresh);
        assert_eq!(
            press.phase(Some(&source), false, false, false),
            Some(Phase::Up)
        );
        let up = press.nonce;
        assert!(press.key_returned(up, Phase::Up, Delivered::Event));
        assert_eq!(press.phase(Some(&source), false, false, false), None);
        assert!(!press.key_returned(up, Phase::Up, Delivered::Event));
    }
    #[::core::prelude::v1::test]
    fn changed_tab_thread_navigation_url_selection_and_privacy_never_dispatch_a_key() {
        let mut press = pending();
        press.stage = Stage::ReadyDown;
        let source = press.binding.clone();
        let mut sources = Vec::new();
        let mut changed = source.clone();
        changed.tab = "other".into();
        sources.push(changed);
        let mut changed = source.clone();
        changed.thread = Uuid::new_v4().to_string();
        sources.push(changed);
        let mut changed = source.clone();
        changed.epoch += 1;
        sources.push(changed);
        let mut changed = source.clone();
        changed.url.push_str("-changed");
        sources.push(changed);
        let mut changed = source.clone();
        changed.active = None;
        sources.push(changed);
        let mut changed = source.clone();
        changed.visible = Some("other-thread".into());
        sources.push(changed);
        for changed in sources {
            assert_eq!(press.phase(Some(&changed), false, false, false), None);
        }
        assert_eq!(press.phase(None, false, false, false), None);
        assert_eq!(press.phase(Some(&source), true, false, false), None);
        assert_eq!(press.phase(Some(&source), false, true, false), None);
        assert_eq!(press.stage, Stage::ReadyDown);
    }
    #[::core::prelude::v1::test]
    fn dialog_defers_only_release_and_changed_document_never_receives_late_key_up() {
        let mut press = pending();
        let source = press.binding.clone();
        press.stage = Stage::ReadyDown;
        press.phase(Some(&source), false, false, false).unwrap();
        let down = press.nonce;
        press.key_returned(down, Phase::Down, Delivered::Event);
        assert_eq!(press.phase(Some(&source), false, false, true), None);
        assert_eq!(press.stage, Stage::ReadyUp);
        let mut changed = source.clone();
        changed.epoch += 1;
        assert_eq!(press.phase(Some(&changed), false, false, false), None);
        assert_eq!(
            press.phase(Some(&source), false, false, false),
            Some(Phase::Up)
        );
        assert_eq!(press.phase(Some(&source), false, false, false), None);
    }
    #[::core::prelude::v1::test]
    fn native_equivalent_finishes_without_replaying_down_or_sending_an_extra_up() {
        let mut press = pending();
        let source = press.binding.clone();
        press.stage = Stage::ReadyDown;
        press.phase(Some(&source), false, false, false).unwrap();
        let down = press.nonce;
        assert!(press.key_returned(down, Phase::Down, Delivered::Equivalent));
        assert_eq!(press.phase(Some(&source), false, false, false), None);
    }
}
