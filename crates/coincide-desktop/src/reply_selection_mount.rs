//! Native Add Selection to Composer. It never obtains text from the clipboard,
//! another renderer, a background window, or an agent supplied JSON argument.
use super::*;
impl Coincide {
    pub(super) fn selection_to_composer_available(&self, window: &Window, cx: &App) -> bool {
        if self.media.close_requested
            || self.media.shutdown_requested
            || !window.is_window_active()
            || !self.find_context_available()
        {
            return false;
        }
        if let Some(workspace) = self
            .terminal_visible_thread
            .as_ref()
            .and_then(|id| self.terminal_workspaces.get(id))
        {
            if workspace.read(cx).is_focused(window) {
                return workspace
                    .read(cx)
                    .focused_context_selection_available(window);
            }
        }
        if self
            .selected
            .as_ref()
            .is_some_and(|thread| self.browser_panels.contains(&text(thread, "id")))
        {
            return false;
        }
        let Some(projection) = transcript::focused_reply_projection(window, cx) else {
            return false;
        };
        self.selected
            .as_ref()
            .filter(|thread| thread["id"] == projection.thread)
            .is_some_and(|thread| {
                thread["items"].as_array().is_some_and(|items| {
                    let mut matching = items.iter().filter(|item| item["id"] == projection.item);
                    matching.next().is_some_and(|item| {
                        item["kind"] == "assistant"
                            && item["text"].as_str() == Some(projection.source())
                    }) && matching.next().is_none()
                })
            })
    }

    pub(super) fn add_selection_to_composer(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.close_requested
            || self.media.shutdown_requested
            || !window.is_window_active()
            || !self.find_context_available()
        {
            return;
        }
        if let Some(workspace) = self
            .terminal_visible_thread
            .as_ref()
            .and_then(|id| self.terminal_workspaces.get(id))
            .cloned()
        {
            if workspace.read(cx).is_focused(window) {
                workspace.update(cx, |workspace, cx| {
                    workspace.request_focused_context_selection(window, cx)
                });
                return;
            }
        }
        // A native web view can retain OS input outside GPUI's text focus. Do
        // not borrow an old registered reply selection while that pane is open.
        if self
            .selected
            .as_ref()
            .is_some_and(|thread| self.browser_panels.contains(&text(thread, "id")))
        {
            return;
        }
        let Some(projection) = transcript::focused_reply_projection(window, cx) else {
            return;
        };
        let admitted = self
            .selected
            .as_ref()
            .filter(|thread| thread["id"] == projection.thread)
            .is_some_and(|thread| {
                let Some(items) = thread["items"].as_array() else {
                    return false;
                };
                let mut matching = items.iter().filter(|item| item["id"] == projection.item);
                matching.next().is_some_and(|item| {
                    item["kind"] == "assistant"
                        && item["text"].as_str() == Some(projection.source())
                }) && matching.next().is_none()
            });
        if !admitted {
            self.status = "The selected reply changed; select its text again.".into();
            cx.notify();
            return;
        }
        if !self.flush_pending_drafts() {
            self.status = "Save the current draft before attaching a reply selection.".into();
            cx.notify();
            return;
        }
        let result = (|| -> Result<Value> {
            anyhow::ensure!(
                projection.current(window, cx),
                "Reply selection changed; select its text again"
            );
            let thread = self
                .selected
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Conversation changed"))?;
            let id = text(thread, "id");
            let draft = self.composer.read(cx).value().to_string();
            anyhow::ensure!(
                text(thread, "draft") == draft && !self.pending_drafts.contains_key(&id),
                "Draft changed; retry after saving"
            );
            let context = coincide_core::composer_context::ExpectedContext::from_thread(thread);
            let selection = projection.into_native()?;
            try_state(&self.engine)?.native_attach_reply_selection(&id, &draft, context, selection)
        })();
        match result {
            Ok(saved) => {
                if let Some(thread) = self
                    .selected
                    .as_mut()
                    .filter(|thread| thread["id"] == saved["threadId"])
                {
                    thread["draftContext"] = saved["draftContext"].clone();
                }
                self.composer_files.invalidate();
                self.composer.read(cx).focus_handle(cx).focus(window, cx);
                self.status = "Selected reply attached. Your message has not been sent.".into();
            }
            Err(error) => self.status = error.to_string(),
        }
        cx.notify();
    }
    pub(super) fn reply_selection_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let key = &event.keystroke;
        let primary = if cfg!(target_os = "macos") {
            key.modifiers.platform
        } else {
            key.modifiers.control
        };
        if event.is_held
            || !primary
            || key.modifiers.alt
            || key.modifiers.shift
            || (cfg!(target_os = "macos") && key.modifiers.control)
            || (!cfg!(target_os = "macos") && key.modifiers.platform)
            || key.key != "l"
            || !window.is_window_active()
        {
            return false;
        }
        if !self.selection_to_composer_available(window, cx) {
            return false;
        }
        self.add_selection_to_composer(window, cx);
        cx.stop_propagation();
        true
    }
}
