//! Native window-only adapters. None of these operations runs at construction.
use anyhow::{Result, bail};
#[derive(Default, Clone, Debug)]
pub struct Permissions {
    pub screen: bool,
    pub accessibility: bool,
    pub detail: String,
}
pub struct Capture {
    pub png: Vec<u8>,
    pub app: String,
    pub title: Option<String>,
    pub text: Option<String>,
    /// The captured window group in window-server points (x, y, width,
    /// height), for the HUD's display; None where the platform has no HUD.
    pub frame: Option<[f64; 4]>,
}
/// What the platform said when it took no picture, as Swift's outcomes.
// Only the macOS backend reports these; elsewhere every failure is plain.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    ScreenRecording,
    NoWindow,
    Protected,
    Password,
}
/// A failed capture with what the HUD needs. Backends without a HUD return
/// plain errors, which read as Swift's `failed(reason)`.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
#[derive(Debug)]
pub struct CaptureFailure {
    pub refusal: Option<Refusal>,
    pub app: String,
    pub frame: Option<[f64; 4]>,
    pub message: String,
}
impl std::fmt::Display for CaptureFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for CaptureFailure {}
/// A native `[x, y, width, height]` frame, when it is four finite numbers.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn frame(value: &serde_json::Value) -> Option<[f64; 4]> {
    let parts = value.as_array()?;
    let mut frame = [0.; 4];
    for (slot, part) in frame.iter_mut().zip(parts) {
        *slot = part.as_f64().filter(|n| n.is_finite())?;
    }
    (parts.len() == 4 && frame[2] >= 0. && frame[3] >= 0.).then_some(frame)
}
#[cfg(target_os = "linux")]
#[path = "appshots_linux.rs"]
pub(crate) mod backend;
#[cfg(target_os = "windows")]
#[path = "appshots_windows.rs"]
mod backend;
#[cfg(target_os = "macos")]
mod backend {
    use super::*;
    use std::ffi::{CStr, CString, c_char, c_void};
    unsafe extern "C" {
        fn coincide_appshots_configure(shortcut: *const c_char) -> *mut c_char;
        fn coincide_appshots_stop();
        fn coincide_appshots_triggered() -> bool;
        fn coincide_appshots_permissions(action: i32) -> *mut c_char;
        fn coincide_appshots_capture(
            read: bool,
            allowed: extern "C" fn(*const c_void) -> bool,
            guard: *const c_void,
            bytes: *mut *mut u8,
            length: *mut usize,
        ) -> *mut c_char;
        fn coincide_appshots_free(pointer: *mut c_void);
        fn coincide_appshots_sound();
        fn coincide_appshots_bring_forward(view: *mut c_void);
        fn coincide_appshots_hud(
            message: *const c_char,
            symbol: *const c_char,
            alert: bool,
            frame: *const f64,
        );
    }
    unsafe fn parsed(pointer: *mut c_char) -> Result<serde_json::Value> {
        if pointer.is_null() {
            bail!("Native Appshots allocation failed");
        }
        let result = serde_json::from_slice(unsafe { CStr::from_ptr(pointer) }.to_bytes());
        unsafe {
            coincide_appshots_free(pointer.cast());
        }
        Ok(result?)
    }
    unsafe fn json(pointer: *mut c_char) -> Result<serde_json::Value> {
        let value = unsafe { parsed(pointer) }?;
        if let Some(error) = value["error"].as_str() {
            bail!("{error}");
        }
        Ok(value)
    }
    pub(super) fn configure(shortcut: Option<&str>) -> Result<()> {
        let shortcut = shortcut.map(CString::new).transpose()?;
        unsafe {
            json(coincide_appshots_configure(
                shortcut.as_ref().map_or(std::ptr::null(), |s| s.as_ptr()),
            ))?;
        }
        Ok(())
    }
    pub(super) fn stop() {
        unsafe {
            coincide_appshots_stop();
        }
    }
    pub(super) fn triggered() -> bool {
        unsafe { coincide_appshots_triggered() }
    }
    pub(super) fn permissions(action: u8) -> Permissions {
        match unsafe { json(coincide_appshots_permissions(action.into())) } {
            Ok(value) => Permissions {
                screen: value["screen"] == true,
                accessibility: value["accessibility"] == true,
                detail: String::new(),
            },
            Err(error) => Permissions {
                detail: error.to_string(),
                ..Default::default()
            },
        }
    }
    pub(super) fn capture(read_text: bool, allowed: &dyn Fn() -> bool) -> Result<Capture> {
        extern "C" fn check(pointer: *const c_void) -> bool {
            let callback = unsafe { &*(pointer as *const &dyn Fn() -> bool) };
            callback()
        }
        let mut bytes = std::ptr::null_mut();
        let mut length = 0;
        let result = unsafe {
            parsed(coincide_appshots_capture(
                read_text,
                check,
                (&allowed as *const &dyn Fn() -> bool).cast(),
                &mut bytes,
                &mut length,
            ))
        };
        let png = if !bytes.is_null() && length <= 20 * 1024 * 1024 {
            unsafe { std::slice::from_raw_parts(bytes, length) }.to_vec()
        } else {
            Vec::new()
        };
        if !bytes.is_null() {
            unsafe {
                coincide_appshots_free(bytes.cast());
            }
        }
        let value = result?;
        if let Some(error) = value["error"].as_str() {
            return Err(CaptureFailure {
                refusal: match value["refusal"].as_str() {
                    Some("screenRecording") => Some(Refusal::ScreenRecording),
                    Some("noWindow") => Some(Refusal::NoWindow),
                    Some("protected") => Some(Refusal::Protected),
                    Some("password") => Some(Refusal::Password),
                    _ => None,
                },
                app: value["app"].as_str().unwrap_or("the app").into(),
                frame: frame(&value["frame"]),
                message: error.into(),
            }
            .into());
        }
        if png.is_empty() {
            bail!("Native capture returned no image");
        }
        Ok(Capture {
            png,
            app: value["app"].as_str().unwrap_or("the app").into(),
            title: value["title"].as_str().map(str::to_owned),
            text: value["text"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            frame: frame(&value["frame"]),
        })
    }
    pub(super) fn sound() {
        unsafe {
            coincide_appshots_sound();
        }
    }
    pub(super) fn bring_forward(view: *mut c_void) {
        unsafe { coincide_appshots_bring_forward(view) }
    }
    pub(super) fn hud(message: &str, symbol: &str, alert: bool, frame: Option<[f64; 4]>) {
        let (Ok(message), Ok(symbol)) = (CString::new(message), CString::new(symbol)) else {
            return;
        };
        unsafe {
            coincide_appshots_hud(
                message.as_ptr(),
                symbol.as_ptr(),
                alert,
                frame.as_ref().map_or(std::ptr::null(), |f| f.as_ptr()),
            )
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn native_permissions_cross_the_bridge_as_booleans() {
            unsafe extern "C" {
                fn AXIsProcessTrusted() -> u8;
                fn CGPreflightScreenCaptureAccess() -> bool;
            }
            // Action zero only reads the current state; it never prompts.
            let value = unsafe { json(coincide_appshots_permissions(0)) }.unwrap();
            assert_eq!(
                value["accessibility"].as_bool(),
                Some(unsafe { AXIsProcessTrusted() != 0 })
            );
            assert_eq!(
                value["screen"].as_bool(),
                Some(unsafe { CGPreflightScreenCaptureAccess() })
            );
        }
    }
}
pub fn configure(shortcut: Option<&str>) -> Result<()> {
    backend::configure(shortcut)
}
pub fn stop() {
    backend::stop()
}
pub fn triggered() -> bool {
    backend::triggered()
}
pub fn permissions(action: u8) -> Permissions {
    backend::permissions(action)
}
pub fn capture(read_text: bool, allowed: &dyn Fn() -> bool) -> Result<Capture> {
    backend::capture(read_text, allowed)
}
pub fn sound() {
    backend::sound()
}
/// Swift's AppForegrounder, for the window whose AppKit `NSView` this is
/// (null for none): unhide, deminiaturize, order front and activate.
#[cfg(target_os = "macos")]
pub fn bring_forward(view: *mut std::ffi::c_void) {
    backend::bring_forward(view);
}
/// Swift's AppshotHUD on macOS, around `frame` when known. Swift has no HUD
/// on other platforms; there the outcome shows in Settings and the status.
pub fn hud(message: &str, symbol: &str, alert: bool, frame: Option<[f64; 4]>) {
    #[cfg(target_os = "macos")]
    backend::hud(message, symbol, alert, frame);
    #[cfg(not(target_os = "macos"))]
    let _ = (message, symbol, alert, frame);
}

#[cfg(target_os = "linux")]
pub(crate) fn notification_activity() -> crate::notification_activity::Observation {
    backend::notification_activity()
}
