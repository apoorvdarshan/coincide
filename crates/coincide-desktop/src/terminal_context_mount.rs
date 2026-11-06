//! Accepted terminal-reference receipts project context only; they never submit or rewrite drafts.
use super::*;
use terminal_workspace::{ComposerBaseline, TerminalContextEvent, TerminalWorkspace};
impl Coincide {
    pub(super) fn invalidate_terminal_contexts(&self, cx: &Context<Self>) {
        for workspace in self.terminal_workspaces.values() {
            workspace.read(cx).invalidate_context();
        }
    }
    pub(super) fn terminal_context_event(
        &mut self,
        workspace: &Entity<TerminalWorkspace>,
        event: &TerminalContextEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event {
            TerminalContextEvent::LastClosed => {
                let id = workspace.read(cx).thread_id().to_owned();
                if self.terminal_visible_thread.as_deref() == Some(id.as_str())
                    && self
                        .terminal_workspaces
                        .get(&id)
                        .is_some_and(|current| current.entity_id() == workspace.entity_id())
                {
                    self.terminal_open = false;
                    self.sync_terminal_workspace(window, cx);
                    if window.is_window_active() {
                        self.composer.read(cx).focus_handle(cx).focus(window, cx);
                    }
                    cx.notify();
                }
            }

            TerminalContextEvent::Requested(request) => {
                let id = workspace.read(cx).thread_id().to_owned();
                let current = self.selected.as_ref().filter(|thread| thread["id"] == id);
                if !window.is_window_active()
                    || self.terminal_visible_thread.as_deref() != Some(id.as_str())
                    || self.pending_drafts.contains_key(&id)
                    || !workspace.read(cx).selection_request_current(request)
                    || current.is_none()
                {
                    self.status =
                        "Terminal or composer changed; select the output again after saving."
                            .into();
                    cx.notify();
                    return;
                }
                let thread = current.unwrap();
                let draft = self.composer.read(cx).value().to_string();
                if text(thread, "draft") != draft {
                    self.status = "Save the current draft before attaching terminal output.".into();
                    cx.notify();
                    return;
                }
                let baseline = ComposerBaseline {
                    thread: id,
                    draft,
                    context: coincide_core::composer_context::ExpectedContext::from_thread(thread),
                };
                workspace.update(cx, |workspace, cx| {
                    workspace.queue_context_selection(request.clone(), baseline, cx)
                });
            }
            TerminalContextEvent::Completed {
                request,
                baseline,
                result,
                fresh,
            } => {
                match result {
                    Ok(saved) => {
                        // A commit remains real even if navigation revoked its UI projection.
                        self.status =
                            "Terminal selection attached to its original conversation.".into();
                        let current = self.selected.as_ref().is_some_and(|thread| {
                            thread["id"] == baseline.thread && baseline.context.matches(thread)
                        });
                        if *fresh
                            && current
                            && !self.pending_drafts.contains_key(&baseline.thread)
                            && self.composer.read(cx).value().as_ref() == baseline.draft
                            && self.terminal_visible_thread.as_deref()
                                == Some(baseline.thread.as_str())
                            && window.is_window_active()
                            && workspace.read(cx).selection_request_current(request)
                        {
                            self.selected.as_mut().unwrap()["draftContext"] =
                                saved["draftContext"].clone();
                            self.composer_files.invalidate();
                            self.composer.read(cx).focus_handle(cx).focus(window, cx);
                        }
                    }
                    Err(error) => {
                        self.status = format!("Terminal selection was not attached: {error}")
                    }
                }
                cx.notify();
            }
        }
    }
}
