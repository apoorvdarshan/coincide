use super::{Kind, Sink};
use anyhow::Result;
use gtk::{
    glib::{SignalHandlerId, prelude::ObjectExt},
    prelude::WidgetExt,
};
use webkit2gtk::{FileChooserRequestExt, ScriptDialogType, WebView, WebViewExt};
use wry::WebViewExtUnix;

pub(super) struct Adapter {
    view: WebView,
    handler: Option<SignalHandlerId>,
    chooser: Option<SignalHandlerId>,
}
impl Adapter {
    pub(super) fn install(view: &wry::WebView, sink: Sink) -> Result<Self> {
        let view = view.webview();
        // As in Swift, an agent never gets a picker: only a page the user can see
        // falls through to WebKitGTK's standard chooser. Hidden or parked tabs
        // decline at once instead of opening a dialog over the user's work.
        let chooser = view.connect_run_file_chooser(|view, request| {
            if view.is_visible() && view.is_mapped() {
                return false;
            }
            request.cancel();
            true
        });
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
            chooser: Some(chooser),
        })
    }
}
impl Drop for Adapter {
    fn drop(&mut self) {
        for handler in [self.handler.take(), self.chooser.take()]
            .into_iter()
            .flatten()
        {
            self.view.disconnect(handler);
        }
    }
}
