use super::{Kind, Sink};
use anyhow::Result;
use gtk::glib::{SignalHandlerId, prelude::ObjectExt};
use webkit2gtk::{ScriptDialogType, WebView, WebViewExt};
use wry::WebViewExtUnix;

pub(super) struct Adapter {
    view: WebView,
    handler: Option<SignalHandlerId>,
}
impl Adapter {
    pub(super) fn install(view: &wry::WebView, sink: Sink) -> Result<Self> {
        let view = view.webview();
        let handler = view.connect_script_dialog(move |_, dialog| {
            let kind = match dialog.dialog_type() {
                ScriptDialogType::Alert => Kind::Alert,
                ScriptDialogType::Confirm => Kind::Confirm,
                ScriptDialogType::Prompt => Kind::Prompt,
                ScriptDialogType::BeforeUnloadConfirm => Kind::BeforeUnload,
                _ => {
                    dialog.close();
                    return true;
                }
            };
            let message = dialog.message().map(|s| s.to_string()).unwrap_or_default();
            let text = (kind == Kind::Prompt).then(|| {
                dialog
                    .prompt_get_default_text()
                    .map(|s| s.to_string())
                    .unwrap_or_default()
            });
            // The cloned native ref explicitly suspends the page until close.
            let pending = dialog.clone();
            sink.open(kind, message, text, move |accept, text| {
                match kind {
                    Kind::Confirm | Kind::BeforeUnload => pending.confirm_set_confirmed(accept),
                    Kind::Prompt if accept => {
                        pending.prompt_set_text(text.as_deref().unwrap_or_default())
                    }
                    _ => {}
                }
                pending.close();
                Ok(())
            });
            true
        });
        Ok(Self {
            view,
            handler: Some(handler),
        })
    }
}
impl Drop for Adapter {
    fn drop(&mut self) {
        if let Some(handler) = self.handler.take() {
            self.view.disconnect(handler);
        }
    }
}
