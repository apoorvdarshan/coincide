//! Native Add Selection to Composer. It never obtains text from the clipboard,
//! another renderer, a background window, or an agent supplied JSON argument.
use super::*;
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenuItem};
impl Coincide {
    /// Keep the captured native selection bound to the clicked message while
    /// the popup temporarily owns focus.
    pub(super) fn message_reply_context_menu(
        &self,
        card: Stateful<Div>,
        source: &str,
        item: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let owner = cx.entity().downgrade();
        let source = source.to_owned();
        let item = item.to_owned();
        card.context_menu(move |mut menu, window, cx| {
            let selection = transcript::focused_reply_projection(window, cx).filter(|projection| {
                projection.thread == source
                    && projection.item == item
                    && projection.current(window, cx)
            });
            if let Some(projection) = selection {
                let selected = projection.clone();
                let target = owner.clone();
                menu = menu.item(
                    PopupMenuItem::new("Reply to selection")
                        .icon(gpui_kit::assets::IconName::Reply)
                        .on_click(move |_, window, cx| {
                            let _ = target.update(cx, |this, cx| {
                                this.reply_to_menu_selection(selected.clone(), window, cx)
                            });
                        }),
                );
                menu = menu.item(
                    PopupMenuItem::new("Copy selection")
                        .icon(gpui_kit::assets::IconName::Copy)
                        .on_click(move |_, window, cx| {
                            if projection.current_in_menu(window, cx) {
                                cx.write_to_clipboard(ClipboardItem::new_string(
                                    projection.selected_text().to_owned(),
                                ));
                            }
                        }),
                );
                menu = menu.separator();
            }
            let target = owner.clone();
            let source = source.clone();
            let item = item.clone();
            menu.item(
                PopupMenuItem::new("Reply to message").on_click(move |_, window, cx| {
                    let _ = target.update(cx, |this, cx| {
                        this.reply_to_message(&source, &item, window, cx)
                    });
                }),
            )
        })
        .into_any_element()
    }

    fn reply_to_menu_selection(
        &mut self,
        projection: transcript::ReplyProjection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.close_requested || self.media.shutdown_requested || !self.chat_visible() {
            return;
        }
        let captured = (|| -> Result<_> {
            anyhow::ensure!(
                projection.current_in_menu(window, cx),
                "The selection changed"
            );
            let thread = self
                .selected
                .as_ref()
                .filter(|thread| thread["id"] == projection.thread)
                .ok_or_else(|| anyhow::anyhow!("Conversation changed"))?;
            let mut matches = thread["items"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|item| item["id"] == projection.item);
            let item = matches
                .next()
                .ok_or_else(|| anyhow::anyhow!("Message unavailable"))?;
            let kind = item["kind"].as_str().unwrap_or("");
            anyhow::ensure!(
                matches.next().is_none()
                    && coincide_core::composer_context::quotable_kind(kind)
                    && item["text"].as_str() == Some(projection.source()),
                "Message changed"
            );
            Ok((
                text(thread, "id"),
                coincide_core::composer_context::ExpectedContext::from_thread(thread),
                projection.into_native(kind)?,
            ))
        })();
        match captured {
            Ok((id, context, selection)) => {
                self.submit_reply_reference(id, context, selection, window, cx)
            }
            Err(error) => {
                self.status = format!("Could not attach reply: {error}");
                self.show_local_error(&self.status.clone());
                cx.notify();
            }
        }
    }
    fn browser_owns_reply_focus(&self, window: &Window, cx: &App) -> bool {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return false;
        };
        if !self.browser_panels.contains(&id) {
            return false;
        }
        self.browser_focus.contains_focused(window, cx)
            || self.browser.as_ref().is_some_and(|browser| {
                browser
                    .shortcut_source(&id, cx)
                    .is_some_and(|source| browser.native_shortcut_focused(&source, cx))
            })
    }
    pub(super) fn reply_to_message(
        &mut self,
        source: &str,
        item: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.selection_to_composer_available(window, cx)
            && transcript::focused_reply_projection(window, cx)
                .is_some_and(|selection| selection.thread == source && selection.item == item)
        {
            self.add_selection_to_composer(window, cx);
            return;
        }
        let capture = (|| -> Result<_> {
            let thread = self
                .selected
                .as_ref()
                .filter(|thread| thread["id"] == source)
                .ok_or_else(|| anyhow::anyhow!("Conversation changed"))?;
            let rows = thread["items"]
                .as_array()
                .ok_or_else(|| anyhow::anyhow!("Message unavailable"))?;
            let mut matches = rows.iter().filter(|row| row["id"] == item);
            let row = matches
                .next()
                .ok_or_else(|| anyhow::anyhow!("Message unavailable"))?;
            anyhow::ensure!(matches.next().is_none(), "Message identity is ambiguous");
            let body = row["text"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("Message has no text"))?;
            anyhow::ensure!(
                body.len() <= 16_000,
                "Select the part of this message you want to reply to"
            );
            let kind = row["kind"].as_str().unwrap_or("");
            let selection = coincide_core::reply_selection::NativeReplySelection::from_native_message_projection(
                item, body.into(), 0..body.len(), body.into(), 0..body.len(), kind,
            )?;
            Ok((
                source.to_owned(),
                coincide_core::composer_context::ExpectedContext::from_thread(thread),
                selection,
            ))
        })();
        match capture {
            Ok((id, context, selection)) => {
                self.submit_reply_reference(id, context, selection, window, cx)
            }
            Err(error) => {
                self.status = error.to_string();
                self.show_local_error(&format!("Could not attach reply: {error}"));
                cx.notify();
            }
        }
    }

    fn submit_reply_reference(
        &mut self,
        id: String,
        context: coincide_core::composer_context::ExpectedContext,
        selection: coincide_core::reply_selection::NativeReplySelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(job) = self.attachment_imports.reserve_reference(&id) else {
            self.show_local_error(
                "Too many attachment changes are in progress. Try again shortly.",
            );
            cx.notify();
            return;
        };
        self.composer.read(cx).focus_handle(cx).focus(window, cx);
        let engine = self.engine.clone();
        cx.spawn(async move |this, cx| {
            let owner = id.clone();
            let result = cx
                .background_executor()
                .spawn(async move {
                    let mut engine = engine
                        .lock()
                        .map_err(|_| anyhow::anyhow!("App engine is unavailable"))?;
                    engine.native_attach_reply_selection_preserve_draft(&id, context, selection)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(saved) => {
                        this.composer_files.invalidate();
                        let card = saved["draftContext"]
                            .as_array()
                            .and_then(|rows| rows.last())
                            .cloned();
                        let error = card
                            .is_none()
                            .then(|| anyhow::anyhow!("Saved reply reference was unavailable"));
                        this.finish_reply_reference(job, &owner, card, error, cx);
                    }
                    Err(error) => {
                        this.finish_reply_reference(job, &owner, None, Some(error), cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
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
        if self.browser_owns_reply_focus(window, cx) {
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
                        item["kind"]
                            .as_str()
                            .is_some_and(coincide_core::composer_context::quotable_kind)
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
        if self.voice.preview.is_some() {
            self.cancel_composer_dictation(cx);
        }

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
        if self.browser_owns_reply_focus(window, cx) {
            return;
        }
        let Some(projection) = transcript::focused_reply_projection(window, cx) else {
            return;
        };
        let kind = self
            .selected
            .as_ref()
            .filter(|thread| thread["id"] == projection.thread)
            .and_then(|thread| {
                let Some(items) = thread["items"].as_array() else {
                    return None;
                };
                let mut matching = items.iter().filter(|item| item["id"] == projection.item);
                let item = matching.next()?;
                let kind = item["kind"].as_str()?;
                (matching.next().is_none()
                    && coincide_core::composer_context::quotable_kind(kind)
                    && item["text"].as_str() == Some(projection.source()))
                .then(|| kind.to_owned())
            });
        let Some(kind) = kind else {
            self.status = "The selected reply changed; select its text again.".into();
            cx.notify();
            return;
        };
        let capture = (|| -> Result<_> {
            anyhow::ensure!(
                projection.current(window, cx),
                "Reply selection changed; select its text again"
            );
            let thread = self
                .selected
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Conversation changed"))?;
            let id = text(thread, "id");
            let context = coincide_core::composer_context::ExpectedContext::from_thread(thread);
            let selection = projection.into_native(&kind)?;
            Ok((id, context, selection))
        })();
        let (id, context, selection) = match capture {
            Ok(value) => value,
            Err(error) => {
                self.status = error.to_string();
                cx.notify();
                return;
            }
        };
        self.submit_reply_reference(id, context, selection, window, cx);
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
