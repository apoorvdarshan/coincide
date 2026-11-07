//! Explicit Mac native-quit custody. Installation never activates or quits the
//! app. The callback only coalesces an atomic request and returns Cancel until
//! the trusted root owner arms a single permit after its normal flush guards.
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InstallError {
    UnsupportedPlatform,
    NotMainThread,
    GpuiClassUnavailable,
    UnexpectedApplication,
    DelegateUnavailable,
    ForeignDelegate,
    ExistingTerminationHandler,
    MethodRegistrationFailed,
    InstallationIdentityChanged,
}
impl std::fmt::Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Native quit guard installation failed: {self:?}")
    }
}
impl std::error::Error for InstallError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PermitError {
    NotInstalled,
    NoObservedRequest,
}
impl std::fmt::Display for PermitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Native quit permit rejected: {self:?}")
    }
}
impl std::error::Error for PermitError {}

// Local SDK NSApplication.h: NS_ENUM(NSUInteger, NSApplicationTerminateReply).
// Supported macOS targets are LP64: NSUInteger/return ABI is usize, not BOOL.
const TERMINATE_CANCEL: usize = 0;
const TERMINATE_NOW: usize = 1;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Identity {
    application: usize,
    delegate: usize,
    class: usize,
}
struct QuitState {
    requested: AtomicBool,
    observed: AtomicBool,
    permit: AtomicBool,
}
impl QuitState {
    const fn new() -> Self {
        Self {
            requested: AtomicBool::new(false),
            observed: AtomicBool::new(false),
            permit: AtomicBool::new(false),
        }
    }
    fn callback(&self, expected: Identity, actual: Identity) -> usize {
        if actual != expected {
            return TERMINATE_CANCEL;
        }
        if self.permit.swap(false, Ordering::AcqRel) {
            self.requested.store(false, Ordering::Release);
            TERMINATE_NOW
        } else {
            self.requested.store(true, Ordering::Release);
            TERMINATE_CANCEL
        }
    }
    fn take_requested(&self) -> bool {
        let requested = self.requested.swap(false, Ordering::AcqRel);
        if requested {
            self.observed.store(true, Ordering::Release);
        }
        requested
    }
    fn cancel(&self) {
        self.requested.store(false, Ordering::Release);
        self.observed.store(false, Ordering::Release);
        self.permit.store(false, Ordering::Release);
    }
    fn permit_once(&self) -> Result<(), PermitError> {
        if !self.observed.swap(false, Ordering::AcqRel) {
            return Err(PermitError::NoObservedRequest);
        }
        self.permit.store(true, Ordering::Release);
        Ok(())
    }
}
fn check_delegate(
    expected: usize,
    actual: usize,
    existing_method: bool,
) -> Result<(), InstallError> {
    if expected == 0 || expected != actual {
        return Err(InstallError::ForeignDelegate);
    }
    if existing_method {
        return Err(InstallError::ExistingTerminationHandler);
    }
    Ok(())
}

/// Opaque main-thread capability. No JSON, public boolean, constructor, or quit
/// invocation can mint a permit; root must first observe the native request.
pub struct NativeQuit {
    #[cfg(target_os = "macos")]
    identity: Identity,
    #[cfg(target_os = "macos")]
    _main: objc2::MainThreadMarker,
}
impl NativeQuit {
    pub fn take_requested(&self) -> bool {
        #[cfg(target_os = "macos")]
        {
            if macos::INSTALLED.get() == Some(&self.identity) {
                return macos::STATE.take_requested();
            }
        }
        false
    }
    /// User cancelled the unsaved-editor decision before any shutdown begins.
    pub(super) fn cancel_request(&self) {
        #[cfg(target_os = "macos")]
        if macos::INSTALLED.get() == Some(&self.identity) {
            macos::STATE.cancel();
        }
    }
    /// Trusted root calls this only after draft/media/runtime closure guards.
    /// This does not issue quit or prove crash/force-quit data preservation.
    pub(super) fn permit_once(&self) -> Result<(), PermitError> {
        #[cfg(target_os = "macos")]
        {
            if macos::INSTALLED.get() == Some(&self.identity) {
                return macos::STATE.permit_once();
            }
        }
        Err(PermitError::NotInstalled)
    }
}
#[cfg(not(target_os = "macos"))]
pub fn install() -> Result<NativeQuit, InstallError> {
    Err(InstallError::UnsupportedPlatform)
}
#[cfg(target_os = "macos")]
pub fn install() -> Result<NativeQuit, InstallError> {
    macos::install()
}

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use objc2::{
        MainThreadMarker, class, msg_send,
        runtime::{AnyClass, AnyObject, Imp, Sel},
        sel,
    };
    use std::sync::OnceLock;
    pub(super) static INSTALLED: OnceLock<Identity> = OnceLock::new();
    pub(super) static STATE: QuitState = QuitState::new();

    // Exact NSApplicationDelegate selector ABI: NSUInteger (id, SEL, id).
    // Never touches App/Entity/Mutex state, allocates, sends Objective-C messages,
    // invokes root closures, or unwinds. Unknown identity always refuses quit.
    unsafe extern "C-unwind" fn should_terminate(
        this: *mut AnyObject,
        _: Sel,
        sender: *mut AnyObject,
    ) -> usize {
        let Some(expected) = INSTALLED.get().copied() else {
            return TERMINATE_CANCEL;
        };
        let actual = Identity {
            application: sender as usize,
            delegate: this as usize,
            class: expected.class,
        };
        STATE.callback(expected, actual)
    }
    fn implementation() -> Imp {
        // IMP is objc2's erased C-unwind function pointer. class_addMethod's
        // explicit type encoding supplies the checked selector ABI to AppKit.
        unsafe {
            std::mem::transmute::<
                unsafe extern "C-unwind" fn(*mut AnyObject, Sel, *mut AnyObject) -> usize,
                Imp,
            >(should_terminate)
        }
    }
    pub(super) fn install() -> Result<NativeQuit, InstallError> {
        let main = MainThreadMarker::new().ok_or(InstallError::NotMainThread)?;
        let expected =
            AnyClass::get(c"GPUIApplicationDelegate").ok_or(InstallError::GpuiClassUnavailable)?;
        let application_class =
            AnyClass::get(c"GPUIApplication").ok_or(InstallError::GpuiClassUnavailable)?;
        unsafe {
            // GPUI must already have initialized its actual application/delegate.
            // Missing classes fail before sharedApplication could create one.
            let application: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
            let app = application
                .as_ref()
                .ok_or(InstallError::UnexpectedApplication)?;
            // KVO wraps the application in an NSKVONotifying_ subclass when
            // something observes it, so accept any subclass of GPUIApplication.
            let mut class = Some(app.class());
            let mut is_gpui = false;
            while let Some(candidate) = class {
                if std::ptr::eq(candidate, application_class) {
                    is_gpui = true;
                    break;
                }
                class = candidate.superclass();
            }
            if !is_gpui {
                return Err(InstallError::UnexpectedApplication);
            }
            let delegate: *mut AnyObject = msg_send![application, delegate];
            let object = delegate.as_ref().ok_or(InstallError::DelegateUnavailable)?;
            let actual_class = object.class();
            if !std::ptr::eq(actual_class, expected) {
                return Err(InstallError::ForeignDelegate);
            }
            let identity = Identity {
                application: application as usize,
                delegate: delegate as usize,
                class: expected as *const AnyClass as usize,
            };
            let selector = sel!(applicationShouldTerminate:);
            let existing = expected.instance_method(selector);
            if let Some(installed) = INSTALLED.get() {
                if installed != &identity
                    || existing.is_none_or(|method| {
                        method.implementation() as usize != implementation() as usize
                    })
                {
                    return Err(InstallError::InstallationIdentityChanged);
                }
                return Ok(NativeQuit {
                    identity,
                    _main: main,
                });
            }
            check_delegate(
                identity.class,
                actual_class as *const AnyClass as usize,
                existing.is_some(),
            )?;
            // class_addMethod refuses an existing method; there is no replacement
            // or swizzle, even if another installer races the presence check.
            let added = objc2::ffi::class_addMethod(
                expected as *const AnyClass as *mut AnyClass,
                selector,
                implementation(),
                c"Q@:@".as_ptr(),
            );
            if !added.as_bool() {
                return Err(InstallError::MethodRegistrationFailed);
            }
            INSTALLED
                .set(identity)
                .map_err(|_| InstallError::InstallationIdentityChanged)?;
            Ok(NativeQuit {
                identity,
                _main: main,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn identity() -> Identity {
        Identity {
            application: 1,
            delegate: 2,
            class: 3,
        }
    }
    #[test]
    fn native_requests_coalesce_and_cannot_quit_before_guard_permit() {
        let state = QuitState::new();
        let id = identity();
        assert_eq!(state.permit_once(), Err(PermitError::NoObservedRequest));
        for _ in 0..3 {
            assert_eq!(state.callback(id, id), TERMINATE_CANCEL);
        }
        assert!(state.take_requested());
        assert!(!state.take_requested());
        assert_eq!(state.callback(id, id), TERMINATE_CANCEL);
        assert!(state.take_requested());
        state.permit_once().unwrap();
        assert_eq!(state.callback(id, id), TERMINATE_NOW);
        assert!(!state.take_requested());
        assert_eq!(state.callback(id, id), TERMINATE_CANCEL);
    }
    #[test]
    fn permit_is_one_use_and_cannot_be_rearmed_without_observed_request() {
        let state = QuitState::new();
        let id = identity();
        assert_eq!(state.callback(id, id), TERMINATE_CANCEL);
        assert!(state.take_requested());
        state.permit_once().unwrap();
        assert_eq!(state.permit_once(), Err(PermitError::NoObservedRequest));
        assert_eq!(state.callback(id, id), TERMINATE_NOW);
        assert_eq!(state.callback(id, id), TERMINATE_CANCEL);
        assert_eq!(state.permit_once(), Err(PermitError::NoObservedRequest));
        assert!(state.take_requested());
        state.permit_once().unwrap();
        assert_eq!(state.callback(id, id), TERMINATE_NOW);
    }
    #[test]
    fn cancelled_unsaved_editor_request_cannot_leave_a_quit_permit() {
        let state = QuitState::new();
        let id = identity();
        state.callback(id, id);
        assert!(state.take_requested());
        state.permit_once().unwrap();
        state.cancel();
        assert_eq!(state.permit_once(), Err(PermitError::NoObservedRequest));
        assert_eq!(state.callback(id, id), TERMINATE_CANCEL);
        assert!(state.take_requested());
        state.permit_once().unwrap();
        assert_eq!(state.callback(id, id), TERMINATE_NOW);
    }
    #[test]
    fn foreign_delegate_or_application_never_requests_or_consumes_permit() {
        let state = QuitState::new();
        let id = identity();
        let foreign = Identity { delegate: 99, ..id };
        assert_eq!(state.callback(id, foreign), TERMINATE_CANCEL);
        assert!(!state.take_requested());
        state.callback(id, id);
        assert!(state.take_requested());
        state.permit_once().unwrap();
        assert_eq!(state.callback(id, foreign), TERMINATE_CANCEL);
        assert_eq!(
            state.callback(
                id,
                Identity {
                    application: 99,
                    ..id
                }
            ),
            TERMINATE_CANCEL
        );
        assert_eq!(state.callback(id, id), TERMINATE_NOW);
    }
    #[test]
    fn exact_class_and_absent_selector_are_required_without_override() {
        assert_eq!(check_delegate(3, 3, false), Ok(()));
        assert_eq!(
            check_delegate(3, 4, false),
            Err(InstallError::ForeignDelegate)
        );
        assert_eq!(
            check_delegate(0, 0, false),
            Err(InstallError::ForeignDelegate)
        );
        assert_eq!(
            check_delegate(3, 3, true),
            Err(InstallError::ExistingTerminationHandler)
        );
        assert_eq!(TERMINATE_CANCEL, 0);
        assert_eq!(TERMINATE_NOW, 1);
    }
}
