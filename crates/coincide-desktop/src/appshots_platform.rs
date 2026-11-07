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
}
#[cfg(target_os = "linux")]
#[path = "appshots_linux.rs"]
mod backend;
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
    }
    unsafe fn json(pointer: *mut c_char) -> Result<serde_json::Value> {
        if pointer.is_null() {
            bail!("Native Appshots allocation failed");
        }
        let result = serde_json::from_slice(unsafe { CStr::from_ptr(pointer) }.to_bytes());
        unsafe {
            coincide_appshots_free(pointer.cast());
        }
        let value: serde_json::Value = result?;
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
            json(coincide_appshots_capture(
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
        })
    }
    pub(super) fn sound() {
        unsafe {
            coincide_appshots_sound();
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

#[cfg(target_os = "linux")]
pub(crate) fn notification_activity() -> crate::notification_activity::Observation {
    backend::notification_activity()
}
