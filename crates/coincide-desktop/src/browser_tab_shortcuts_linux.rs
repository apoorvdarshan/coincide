use super::*;
use gtk::{
    gdk,
    glib::{SignalHandlerId, prelude::ObjectExt},
    prelude::WidgetExt,
};
use webkit2gtk::WebViewExt;
use wry::WebViewExtUnix;
pub(super) struct Adapter {
    view: webkit2gtk::WebView,
    token: Option<SignalHandlerId>,
}
impl Adapter {
    pub fn install(
        view: &wry::WebView,
        callbacks: &Callbacks,
        navigation: Arc<AtomicU64>,
        emit: impl Fn(Command, u64, Option<String>) -> bool + 'static,
    ) -> Result<Self> {
        let view = view.webview();
        let block = callbacks.lifetimes().block();
        let token = view.connect_key_press_event(move |view, event| {
            let _held = &block;
            let epoch = navigation.load(Ordering::Acquire);
            if !view.is_visible() || !view.is_mapped() || !view.has_focus() {
                return gtk::glib::Propagation::Proceed;
            }
            let flags = event.state();
            let Some(key) = event.keyval().to_unicode() else {
                return gtk::glib::Propagation::Proceed;
            };
            let Some(command) = shortcuts::recognize(
                &key.to_string(),
                flags.contains(gdk::ModifierType::CONTROL_MASK),
                flags.intersects(gdk::ModifierType::SUPER_MASK | gdk::ModifierType::META_MASK),
                flags.contains(gdk::ModifierType::MOD1_MASK),
                flags.contains(gdk::ModifierType::SHIFT_MASK),
            ) else {
                return gtk::glib::Propagation::Proceed;
            };
            let url = view
                .uri()
                .filter(|url| url.len() <= 16384)
                .map(|url| url.to_string());
            if emit(command, epoch, url) {
                gtk::glib::Propagation::Stop
            } else {
                gtk::glib::Propagation::Proceed
            }
        });
        Ok(Self {
            view,
            token: Some(token),
        })
    }
}
impl Drop for Adapter {
    fn drop(&mut self) {
        if let Some(token) = self.token.take() {
            self.view.disconnect(token);
        }
    }
}
