use super::{Delivered, Phase};
use anyhow::{Context, Result, ensure};
use coincide_core::browser_protocol::keys::{KeyPress, Named};
use gtk::{gdk, glib::translate::*, prelude::*};
use wry::WebViewExtUnix;
pub(super) struct Adapter {
    view: webkit2gtk::WebView,
}
impl Adapter {
    pub(super) fn install(view: &wry::WebView) -> Result<Self> {
        let view = view.webview();
        ensure!(
            view.is_realized() && view.window().is_some(),
            "Native browser key widget unavailable"
        );
        Ok(Self { view })
    }
    pub(super) fn dispatch(
        &self,
        key: &KeyPress,
        phase: Phase,
        finished: impl FnOnce(Result<Delivered>) + 'static,
    ) -> Result<()> {
        let result = (|| -> Result<Delivered> {
            let window = self
                .view
                .window()
                .context("Native browser key window unavailable")?;
            let display = self.view.display();
            let keyval = match key.named {
                Some(Named::Enter) => gdk::keys::constants::Return,
                Some(Named::Tab) => gdk::keys::constants::Tab,
                Some(Named::Space) => gdk::keys::constants::space,
                Some(Named::Backspace) => gdk::keys::constants::BackSpace,
                Some(Named::Escape) => gdk::keys::constants::Escape,
                Some(Named::Delete) => gdk::keys::constants::Delete,
                Some(Named::Home) => gdk::keys::constants::Home,
                Some(Named::End) => gdk::keys::constants::End,
                Some(Named::PageUp) => gdk::keys::constants::Page_Up,
                Some(Named::PageDown) => gdk::keys::constants::Page_Down,
                Some(Named::Left) => gdk::keys::constants::Left,
                Some(Named::Right) => gdk::keys::constants::Right,
                Some(Named::Up) => gdk::keys::constants::Up,
                Some(Named::Down) => gdk::keys::constants::Down,
                None => gdk::keys::Key::from_unicode(
                    key.characters
                        .chars()
                        .next()
                        .context("Native key missing")?,
                ),
            };
            let keymap =
                gdk::Keymap::for_display(&display).context("Native browser keymap unavailable")?;
            let entries = keymap.entries_for_keyval(keyval.into_glib());
            let physical = entries.first().context("Native key absent from keymap")?;
            let device = display
                .default_seat()
                .and_then(|seat| seat.keyboard())
                .context("Native browser keyboard device unavailable")?;
            let mut event = gdk::Event::new(if phase == Phase::Down {
                gdk::EventType::KeyPress
            } else {
                gdk::EventType::KeyRelease
            });
            event.set_device(Some(&device));
            let mut state = gdk::ModifierType::empty();
            if key.shift {
                state |= gdk::ModifierType::SHIFT_MASK;
            }
            if key.control || key.meta {
                state |= gdk::ModifierType::CONTROL_MASK;
            }
            let text = std::ffi::CString::new(key.page_text())?;
            // gdk_event_free owns these exact window/string references. The
            // event is delivered only to this retained widget, never put on a
            // global queue and never synthesized through page JavaScript.
            unsafe {
                let raw: *mut gdk::ffi::GdkEvent = event.to_glib_none().0;
                let raw = &mut (*raw).key;
                raw.window = window.to_glib_full();
                raw.send_event = 0;
                raw.time = gdk::CURRENT_TIME;
                raw.state = state.bits();
                raw.keyval = keyval.into_glib();
                raw.hardware_keycode = u16::try_from(physical.keycode())?;
                raw.group = u8::try_from(physical.group())?;
                raw.length = i32::try_from(key.page_text().len())?;
                raw.string = gtk::glib::ffi::g_strdup(text.as_ptr());
                raw.is_modifier = 0;
            }
            self.view.event(&event);
            Ok(Delivered::Event)
        })();
        finished(result);
        Ok(())
    }
}
