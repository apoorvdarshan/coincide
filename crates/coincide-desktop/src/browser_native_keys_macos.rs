use super::{Delivered, Phase};
use anyhow::{Context, Result};
use coincide_core::browser_protocol::keys::KeyPress;
use objc2::{MainThreadMarker, rc::Retained};
use objc2_app_kit::{NSEvent, NSEventModifierFlags, NSEventType};
use objc2_foundation::{NSPoint, NSProcessInfo, NSString};
use objc2_web_kit::WKWebView;
use wry::WebViewExtMacOS;
pub(super) struct Adapter {
    view: Retained<WKWebView>,
}
impl Adapter {
    pub(super) fn install(view: &wry::WebView) -> Result<Self> {
        MainThreadMarker::new().context("Native page keys require UI thread")?;
        Ok(Self {
            view: unsafe { Retained::cast_unchecked(view.webview()) },
        })
    }
    pub(super) fn dispatch(
        &self,
        key: &KeyPress,
        phase: Phase,
        finished: impl FnOnce(Result<Delivered>) + 'static,
    ) -> Result<()> {
        let result = (|| -> Result<Delivered> {
            unsafe {
                let mut flags = NSEventModifierFlags::empty();
                if key.meta {
                    flags |= NSEventModifierFlags::Command;
                }
                if key.control {
                    flags |= NSEventModifierFlags::Control;
                }
                if key.shift {
                    flags |= NSEventModifierFlags::Shift;
                }
                let event_type = if phase == Phase::Down {
                    NSEventType::KeyDown
                } else {
                    NSEventType::KeyUp
                };
                let window = self.view.window().map_or(0, |window| window.windowNumber());
                let event = NSEvent::keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode(
                event_type, NSPoint::new(0., 0.), flags, NSProcessInfo::processInfo().systemUptime(), window, None, &NSString::from_str(&key.characters), &NSString::from_str(&key.ignoring_modifiers), false, key.mac_code)
                .context("Native page key event unavailable")?;
                if phase == Phase::Down {
                    if key.meta && self.view.performKeyEquivalent(&event) {
                        return Ok(Delivered::Equivalent);
                    }
                    self.view.keyDown(&event);
                } else {
                    self.view.keyUp(&event);
                }
                Ok(Delivered::Event)
            }
        })();
        finished(result);
        Ok(())
    }
}
