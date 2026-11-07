//! Read-only host activity sampled on the configured notification worker.
//! Construction and fake backends never touch the desktop, devices or buses.
use crate::notifications::{Backend, Payload, Permission};
use anyhow::Result;
use coincide_core::platform_host::notifications::{Delivery, DesktopActivity};
use uuid::Uuid;
#[derive(Default, Debug, Clone, Copy)]
pub(crate) struct Observation {
    pub idle_seconds: Option<u64>,
    pub locked: Option<bool>,
    pub display_asleep: Option<bool>,
}
impl Observation {
    fn apply(self, mut desktop: DesktopActivity) -> DesktopActivity {
        desktop.idle_seconds = self.idle_seconds.unwrap_or(u64::MAX);
        // An unavailable lock observation cannot assert an unlocked desktop.
        desktop.locked = self.locked.unwrap_or(true);
        desktop.display_asleep = self.display_asleep.unwrap_or(false);
        desktop
    }
}
pub(crate) struct Native<B>(pub B);
impl<B: Backend> Backend for Native<B> {
    fn permission(&mut self) -> Result<Permission> {
        self.0.permission()
    }
    fn request_permission(&mut self) -> Result<Permission> {
        self.0.request_permission()
    }
    fn post(&mut self, payload: &Payload) -> Delivery {
        self.0.post(payload)
    }
    fn clear_thread(&mut self, thread: Uuid) -> Result<()> {
        self.0.clear_thread(thread)
    }
    fn observe_desktop(&mut self, desktop: DesktopActivity) -> DesktopActivity {
        sample().apply(desktop)
    }
}
#[cfg(target_os = "macos")]
fn sample() -> Observation {
    #[repr(C)]
    #[derive(Default)]
    struct NativeObservation {
        idle: f64,
        known: u32,
        locked: u32,
        asleep: u32,
    }
    unsafe extern "C" {
        fn coincide_notification_activity() -> NativeObservation;
    }
    // SAFETY: fixed scalar C ABI; the bridge returns no retained objects.
    let value = unsafe { coincide_notification_activity() };
    Observation {
        idle_seconds: (value.known & 1 != 0 && value.idle.is_finite() && value.idle >= 0.0)
            .then_some(value.idle as u64),
        locked: (value.known & 2 != 0).then_some(value.locked != 0),
        display_asleep: (value.known & 4 != 0).then_some(value.asleep != 0),
    }
}
#[cfg(windows)]
fn sample() -> Observation {
    use ::windows::Win32::{
        Foundation::HANDLE,
        System::{StationsAndDesktops::*, SystemInformation::GetTickCount},
        UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO},
    };
    let mut input = LASTINPUTINFO {
        cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
        ..Default::default()
    };
    let idle_seconds = unsafe { GetLastInputInfo(&mut input) }
        .as_bool()
        .then(|| u64::from(unsafe { GetTickCount() }.wrapping_sub(input.dwTime)) / 1000);
    struct Desktop(HDESK);
    impl Drop for Desktop {
        fn drop(&mut self) {
            let _ = unsafe { CloseDesktop(self.0) };
        }
    }
    // READOBJECTS does not change the input desktop or request UI access.
    let locked = (|| -> Option<bool> {
        let input = Desktop(
            unsafe { OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS) }
                .ok()?,
        );
        let mut name = [0u16; 128];
        let mut needed = 0;
        unsafe {
            GetUserObjectInformationW(
                HANDLE(input.0.0),
                UOI_NAME,
                Some(name.as_mut_ptr().cast()),
                std::mem::size_of_val(&name) as u32,
                Some(&mut needed),
            )
        }
        .ok()?;
        if needed < 2 || needed as usize > std::mem::size_of_val(&name) || needed % 2 != 0 {
            return None;
        }
        let end = name.iter().position(|c| *c == 0)?;
        Some(String::from_utf16(&name[..end]).ok()?.to_lowercase() != "default")
    })();
    Observation {
        idle_seconds,
        locked,
        display_asleep: None,
    }
}
#[cfg(target_os = "linux")]
fn sample() -> Observation {
    let mut observation = crate::appshots_platform::notification_activity();
    // Bind the logind session to this actual process, never an imported session
    // identifier. Bounded failures leave the lock state unknown.
    observation.locked = (|| -> Option<bool> {
        use std::time::Duration;
        use zbus::blocking::{Proxy, connection::Builder};
        let bus = Builder::system()
            .ok()?
            .method_timeout(Duration::from_millis(150))
            .build()
            .ok()?;
        let manager = Proxy::new(
            &bus,
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
        )
        .ok()?;
        let path: zbus::zvariant::OwnedObjectPath = manager
            .call("GetSessionByPID", &(std::process::id(),))
            .ok()?;
        let session = Proxy::new(
            &bus,
            "org.freedesktop.login1",
            path,
            "org.freedesktop.login1.Session",
        )
        .ok()?;
        session.get_property::<bool>("LockedHint").ok()
    })();
    observation
}
#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn sample() -> Observation {
    Observation::default()
}
#[cfg(test)]
mod tests {
    use super::*;
    fn desktop() -> DesktopActivity {
        DesktopActivity {
            app_active: true,
            visible_thread: Some(Uuid::new_v4()),
            idle_seconds: 0,
            locked: false,
            display_asleep: false,
        }
    }
    #[test]
    fn unknown_activity_never_asserts_recent_unlocked_input_and_preserves_ui_identity() {
        let original = desktop();
        let observed = Observation::default().apply(original);
        assert_eq!(observed.idle_seconds, u64::MAX);
        assert!(observed.locked);
        assert_eq!(observed.visible_thread, original.visible_thread);
        assert!(observed.app_active);
        let observed = Observation {
            idle_seconds: Some(7),
            locked: Some(false),
            display_asleep: Some(true),
        }
        .apply(original);
        assert_eq!(observed.idle_seconds, 7);
        assert!(!observed.locked);
        assert!(observed.display_asleep);
    }
    #[cfg(target_os = "linux")]
    #[test]
    #[ignore = "fresh Linux CI private Xvfb and bus only; never the user session"]
    fn actual_private_x11_activity() {
        assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
        assert_eq!(
            std::env::var("COINCIDE_PRIVATE_ACTIVITY_FIXTURE").as_deref(),
            Ok("1")
        );
        assert!(std::env::var_os("DISPLAY").is_some());
        let bus = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap();
        assert_eq!(std::env::var("DBUS_SYSTEM_BUS_ADDRESS").unwrap(), bus);
        assert!(!bus.is_empty());
        let observed = sample();
        assert!(
            observed.idle_seconds.is_some_and(|idle| idle < 60),
            "Fresh owned Xvfb must expose actual XScreenSaver idle time"
        );
        assert!(
            observed.locked.is_none(),
            "The private bus has no logind session; unknown must stay unknown"
        );
        let routed = observed.apply(desktop());
        assert!(
            routed.locked,
            "Unknown private-bus lock cannot assert an unlocked session"
        );
    }
    #[test]
    fn windows_input_age_handles_tick_rollover_without_negative_or_future_age() {
        let last = u32::MAX - 499;
        let now = 500u32;
        assert_eq!(u64::from(now.wrapping_sub(last)) / 1000, 1);
    }
}
