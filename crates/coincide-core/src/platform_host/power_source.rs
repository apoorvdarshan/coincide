//! Read the current power source without changing any system settings.
//!
//! An unknown source must not be treated as external power: a user who asks
//! to allow sleep on battery should not unexpectedly drain the battery.

#[cfg(target_os = "macos")]
pub(super) fn on_battery() -> Option<bool> {
    use std::ffi::{CStr, c_char, c_void};
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> *const c_void;
        fn IOPSGetProvidingPowerSourceType(info: *const c_void) -> *const c_void;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(value: *const c_void);
        fn CFStringGetCString(
            value: *const c_void,
            buffer: *mut c_char,
            size: isize,
            encoding: u32,
        ) -> u8;
    }
    // IOPSCopyPowerSourcesInfo returns an owned snapshot. The type is borrowed
    // from that snapshot and read before releasing it.
    unsafe {
        let info = IOPSCopyPowerSourcesInfo();
        if info.is_null() {
            return None;
        }
        let kind = IOPSGetProvidingPowerSourceType(info);
        let mut buffer = [0 as c_char; 64];
        let result = if kind.is_null()
            || CFStringGetCString(
                kind,
                buffer.as_mut_ptr(),
                buffer.len() as isize,
                0x0800_0100,
            ) == 0
        {
            None
        } else {
            match CStr::from_ptr(buffer.as_ptr()).to_bytes() {
                b"Battery Power" | b"UPS Power" => Some(true),
                b"AC Power" => Some(false),
                _ => None,
            }
        };
        CFRelease(info);
        result
    }
}

#[cfg(target_os = "windows")]
pub(super) fn on_battery() -> Option<bool> {
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    let mut status = SYSTEM_POWER_STATUS::default();
    // The API writes only to this initialized structure.
    if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
        return None;
    }
    match status.ACLineStatus {
        0 if status.BatteryFlag & 128 == 0 => Some(true),
        0 | 1 => Some(false),
        _ => None,
    }
}

#[cfg(target_os = "linux")]
pub(super) fn on_battery() -> Option<bool> {
    linux_source(std::path::Path::new("/sys/class/power_supply"))
}

#[cfg(any(target_os = "linux", test))]
fn linux_source(root: &std::path::Path) -> Option<bool> {
    let mut saw_battery = false;
    let mut battery_discharging = false;
    let mut external_source = false;
    let mut source_known = false;
    for entry in std::fs::read_dir(root).ok()?.flatten() {
        let path = entry.path();
        let Ok(kind) = std::fs::read_to_string(path.join("type")) else {
            continue;
        };
        if kind.trim() == "Battery" {
            saw_battery = true;
            if std::fs::read_to_string(path.join("status"))
                .is_ok_and(|status| status.trim() == "Discharging")
            {
                battery_discharging = true;
            }
        } else if let Ok(online) = std::fs::read_to_string(path.join("online")) {
            match online.trim() {
                "1" => {
                    source_known = true;
                    external_source = true;
                }
                "0" => source_known = true,
                _ => {}
            }
        }
    }
    if external_source {
        Some(false)
    } else if battery_discharging || (saw_battery && source_known) {
        Some(true)
    } else if source_known && !saw_battery {
        Some(false)
    } else {
        None
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
pub(super) fn on_battery() -> Option<bool> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[test]
    fn linux_supplies_distinguish_external_battery_and_unknown() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(linux_source(root.path()), None);
        let battery = root.path().join("BAT0");
        let ac = root.path().join("AC");
        fs::create_dir_all(&battery).unwrap();
        fs::create_dir_all(&ac).unwrap();
        fs::write(battery.join("type"), "Battery\n").unwrap();
        fs::write(battery.join("status"), "Discharging\n").unwrap();
        fs::write(ac.join("type"), "Mains\n").unwrap();
        fs::write(ac.join("online"), "0\n").unwrap();
        assert_eq!(linux_source(root.path()), Some(true));
        fs::write(ac.join("online"), "1\n").unwrap();
        assert_eq!(linux_source(root.path()), Some(false));
        fs::write(ac.join("online"), "unknown\n").unwrap();
        fs::write(battery.join("status"), "Unknown\n").unwrap();
        assert_eq!(linux_source(root.path()), None);
    }
}
