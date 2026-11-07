//! Scoped Windows Power Requests. No power-plan, lid, service or persistent
//! setting changes. Construction is inert; one owned handle holds one request.
use super::super::power::SleepInhibitor;
use anyhow::Result;
#[cfg(any(test, windows))]
use anyhow::ensure;

pub trait Api: Send {
    type Lease: Send;
    fn acquire(&mut self) -> Result<Self::Lease>;
    fn check(&mut self, lease: &Self::Lease) -> Result<()>;
    fn release(&mut self, lease: &mut Self::Lease) -> Result<()>;
}
pub struct WindowsInhibitor<A: Api> {
    api: A,
    lease: Option<A::Lease>,
}
impl<A: Api> WindowsInhibitor<A> {
    pub fn with_api(api: A) -> Self {
        Self { api, lease: None }
    }
}
impl<A: Api> SleepInhibitor for WindowsInhibitor<A> {
    fn acquire(&mut self) -> Result<()> {
        if self.lease.is_some() {
            return self.check();
        }
        self.lease = Some(self.api.acquire()?);
        Ok(())
    }
    fn check(&mut self) -> Result<()> {
        let lease = self
            .lease
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Windows idle-sleep request is not held"))?;
        self.api.check(lease)
    }
    fn release(&mut self) -> Result<()> {
        if let Some(lease) = &mut self.lease {
            self.api.release(lease)?;
        }
        self.lease = None;
        Ok(())
    }
}
impl<A: Api> Drop for WindowsInhibitor<A> {
    fn drop(&mut self) {
        let _ = self.release();
    }
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows_sys::Win32::{
        Foundation::INVALID_HANDLE_VALUE,
        System::{
            Power::{
                PowerClearRequest, PowerCreateRequest, PowerRequestSystemRequired, PowerSetRequest,
            },
            SystemServices::POWER_REQUEST_CONTEXT_VERSION,
            Threading::{POWER_REQUEST_CONTEXT_SIMPLE_STRING, REASON_CONTEXT, REASON_CONTEXT_0},
        },
    };
    #[derive(Default)]
    pub struct SystemApi;
    pub struct NativeLease {
        handle: OwnedHandle,
        active: bool,
        // Keep the reason's storage alive for the complete handle lifetime.
        _reason: Vec<u16>,
    }
    impl Api for SystemApi {
        type Lease = NativeLease;
        fn acquire(&mut self) -> Result<NativeLease> {
            let mut reason: Vec<u16> = "Coincide: agent work is active"
                .encode_utf16()
                .chain(Some(0))
                .collect();
            let context = REASON_CONTEXT {
                Version: POWER_REQUEST_CONTEXT_VERSION,
                Flags: POWER_REQUEST_CONTEXT_SIMPLE_STRING,
                Reason: REASON_CONTEXT_0 {
                    SimpleReasonString: reason.as_mut_ptr(),
                },
            };
            let raw = unsafe { PowerCreateRequest(&context) };
            ensure!(
                !raw.is_null() && raw != INVALID_HANDLE_VALUE,
                "Windows could not create this app's idle-sleep request"
            );
            let handle = unsafe { OwnedHandle::from_raw_handle(raw) };
            ensure!(
                unsafe { PowerSetRequest(handle.as_raw_handle(), PowerRequestSystemRequired) } != 0,
                "Windows did not acknowledge this app's idle-sleep request"
            );
            Ok(NativeLease {
                handle,
                active: true,
                _reason: reason,
            })
        }
        fn check(&mut self, lease: &NativeLease) -> Result<()> {
            // The private live handle retains the acknowledged request. Do not
            // call PowerSetRequest again: its counter requires matching clears.
            // This is not a query of physical sleep/lid behavior.
            ensure!(lease.active, "Windows idle-sleep request was released");
            Ok(())
        }
        fn release(&mut self, lease: &mut NativeLease) -> Result<()> {
            if lease.active {
                ensure!(
                    unsafe {
                        PowerClearRequest(lease.handle.as_raw_handle(), PowerRequestSystemRequired)
                    } != 0,
                    "Windows did not confirm releasing this app's idle-sleep request"
                );
                lease.active = false;
            }
            Ok(())
        }
    }
    impl Drop for NativeLease {
        fn drop(&mut self) {
            if self.active {
                unsafe {
                    PowerClearRequest(self.handle.as_raw_handle(), PowerRequestSystemRequired);
                }
            }
            // Closing this exact owned handle also releases its power requests.
        }
    }
    impl WindowsInhibitor<SystemApi> {
        pub fn native() -> Self {
            Self::with_api(SystemApi)
        }
    }
}
#[cfg(windows)]
pub use native::SystemApi;

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    #[derive(Default)]
    struct State {
        calls: Vec<&'static str>,
        fail_acquire: bool,
        fail_release: bool,
    }
    struct Fake(Arc<Mutex<State>>);
    impl Api for Fake {
        type Lease = u64;
        fn acquire(&mut self) -> Result<u64> {
            let mut state = self.0.lock().unwrap();
            state.calls.push("acquire");
            ensure!(!state.fail_acquire, "synthetic acquire failure");
            Ok(7)
        }
        fn check(&mut self, lease: &u64) -> Result<()> {
            assert_eq!(*lease, 7);
            self.0.lock().unwrap().calls.push("check");
            Ok(())
        }
        fn release(&mut self, lease: &mut u64) -> Result<()> {
            assert_eq!(*lease, 7);
            let mut state = self.0.lock().unwrap();
            state.calls.push("release");
            ensure!(
                !std::mem::take(&mut state.fail_release),
                "synthetic release failure"
            );
            Ok(())
        }
    }
    #[test]
    fn construction_and_repeated_acquisition_do_not_duplicate_os_requests() {
        let state = Arc::new(Mutex::new(State::default()));
        let mut inhibitor = WindowsInhibitor::with_api(Fake(state.clone()));
        assert!(state.lock().unwrap().calls.is_empty());
        inhibitor.acquire().unwrap();
        inhibitor.acquire().unwrap();
        inhibitor.check().unwrap();
        inhibitor.release().unwrap();
        inhibitor.release().unwrap();
        assert_eq!(
            state.lock().unwrap().calls,
            ["acquire", "check", "check", "release"]
        );
        inhibitor.acquire().unwrap();
        drop(inhibitor);
        assert_eq!(
            state.lock().unwrap().calls,
            ["acquire", "check", "check", "release", "acquire", "release"]
        );
    }
    #[test]
    fn failed_acquisition_has_no_lease_and_failed_release_retains_exact_custody() {
        let state = Arc::new(Mutex::new(State {
            fail_acquire: true,
            ..State::default()
        }));
        let mut inhibitor = WindowsInhibitor::with_api(Fake(state.clone()));
        assert!(inhibitor.acquire().is_err());
        assert!(inhibitor.lease.is_none());
        state.lock().unwrap().fail_acquire = false;
        inhibitor.acquire().unwrap();
        state.lock().unwrap().fail_release = true;
        assert!(inhibitor.release().is_err());
        assert_eq!(inhibitor.lease, Some(7));
        inhibitor.release().unwrap();
        assert!(inhibitor.lease.is_none());
    }
    #[cfg(windows)]
    #[test]
    #[ignore = "explicit fresh Windows runner only; no developer power requests"]
    fn owned_kernel_round_trip() {
        assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
        assert_eq!(
            std::env::var("COINCIDE_WINDOWS_POWER_CI").as_deref(),
            Ok("owned-native-request")
        );
        let mut inhibitor = WindowsInhibitor::native();
        assert!(inhibitor.lease.is_none());
        inhibitor.acquire().unwrap();
        inhibitor.check().unwrap();
        inhibitor.acquire().unwrap();
        inhibitor.release().unwrap();
        assert!(inhibitor.lease.is_none());
    }
}
