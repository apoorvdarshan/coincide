use super::*;
use gtk::{
    gdk,
    glib::{SignalHandlerId, prelude::ObjectExt},
    prelude::*,
};
use webkit2gtk::WebViewExt;
use wry::WebViewExtUnix;
pub(super) struct Adapter {
    view: webkit2gtk::WebView,
    token: Option<SignalHandlerId>,
}
impl Adapter {
    pub fn focused(&self, _: &wry::WebView) -> bool {
        owns_input_focus(&self.view)
    }
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
            if !view.is_visible() || !view.is_mapped() {
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
            // Ordinary page typing never opens an X11 connection or pays for
            // a focus round trip. Only the four host chords need this check.
            if !owns_input_focus(view) {
                return gtk::glib::Propagation::Proceed;
            }
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

#[link(name = "gdk-3")]
unsafe extern "C" {
    fn gdk_x11_window_get_xid(window: *mut gdk::ffi::GdkWindow) -> libc::c_ulong;
}
fn owns_input_focus(view: &webkit2gtk::WebView) -> bool {
    use gtk::glib::translate::ToGlibPtr;
    use x11rb::protocol::xproto::ConnectionExt;
    if !view.is_visible() || !view.is_mapped() {
        return false;
    }
    let Some(window) = view.window() else {
        return false;
    };
    let xid = unsafe { gdk_x11_window_get_xid(window.to_glib_none().0) };
    let Ok(owned) = u32::try_from(xid) else {
        return false;
    };
    if owned <= 1 {
        return false;
    }
    let Ok((connection, _)) = x11rb::connect(None) else {
        return false;
    };
    let Ok(cookie) = connection.get_input_focus() else {
        return false;
    };
    let Ok(reply) = cookie.reply() else {
        return false;
    };
    let mut current = reply.focus;
    // Query only ancestry; never focus/mutate another client or use global hooks.
    for _ in 0..32 {
        if current == owned {
            return true;
        }
        if current <= 1 {
            return false;
        }
        let Ok(cookie) = connection.query_tree(current) else {
            return false;
        };
        let Ok(tree) = cookie.reply() else {
            return false;
        };
        if tree.parent == current {
            return false;
        }
        current = tree.parent;
    }
    false
}
/// An explicit native-user tab action focuses only its selected owned child.
/// GtkWidget::grab_focus alone changes logical focus inside Wry's foreign GtkWindow.
pub(super) fn focus(view: &wry::WebView) -> Result<()> {
    view.focus()?;
    let widget = view.webview();
    let window = widget
        .window()
        .ok_or_else(|| anyhow::anyhow!("Native browser focus window unavailable"))?;
    window.focus(gdk::ffi::GDK_CURRENT_TIME as u32);
    // A bare Xvfb has no window manager to apply that request. Set X input
    // focus on our own view directly so the native key reaches it.
    use gtk::glib::translate::ToGlibPtr;
    let xid = unsafe { gdk_x11_window_get_xid(window.to_glib_none().0) };
    if let Ok(owned) = u32::try_from(xid)
        && owned > 1
        && let Ok((connection, _)) = x11rb::connect(None)
    {
        use x11rb::protocol::xproto::{ConnectionExt, InputFocus};
        let _ = connection.set_input_focus(InputFocus::Parent, owned, x11rb::CURRENT_TIME);
        let _ = connection.flush();
    }
    widget.display().sync();
    Ok(())
}
