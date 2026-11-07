//! Explicit native microphone lifecycle. Construction has no OS effects.
//! Native implementations are opt-in; no Apple Speech, inference or sending.
use coincide_core::dictation::transcription::encode_wav;
use std::{collections::VecDeque, ops::Range};
use uuid::Uuid;
const SAMPLE_RATE: usize = 16_000;
const MAX_SECONDS: usize = 600;
#[cfg(any(
    test,
    all(
        feature = "native-microphone",
        any(target_os = "windows", target_os = "linux")
    )
))]
#[path = "microphone_samples.rs"]
mod samples;

/// Build capability only; never queries devices or asks for OS permission.
pub const fn compiled_backend_available() -> bool {
    cfg!(all(
        feature = "native-microphone",
        any(
            target_os = "macos",
            target_os = "windows",
            target_os = "linux"
        )
    ))
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    NotDetermined,
    Authorized,
    /// Explicitly armed; actual WASAPI/ALSA access is checked on Record.
    Ready,
    Denied,
    Restricted,
    Unavailable,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptureError {
    Unavailable,
    PermissionRequired,
    Busy,
    InvalidLimit,
    InvalidBinding,
    NoInput,
    Overflow,
    Conversion,
    DeviceChanged,
    NothingRecorded,
}
#[derive(Clone, PartialEq, Eq)]
pub struct CaptureBinding {
    pub thread_id: String,
    pub composer_revision: u64,
    pub settings_revision: u64,
    pub selection: Range<usize>,
}
/// Contains personal audio: no Debug/Serialize/persistence. Parent must recheck
/// accepts_audio with live binding before explicit transcription on its worker.
pub struct CapturedAudio {
    pub session: Uuid,
    pub generation: u64,
    pub binding: CaptureBinding,
    pub wav: Vec<u8>,
    pub limit_reached: bool,
}
/// Native-only personal audio. No Debug/Serialize or document constructor.
pub struct CaptureChunk {
    pub session: Uuid,
    pub generation: u64,
    pub binding: CaptureBinding,
    pub offset: usize,
    pub samples: Vec<f32>,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaptureProgress {
    pub session: Uuid,
    pub captured_samples: usize,
    /// Actual converted mono peak for the latest native buffer, in 0..=1.
    pub level: f32,
}
#[derive(Clone, Copy)]
struct BackendProgress {
    samples: usize,
    level: f32,
}
pub enum CaptureEvent {
    PermissionChanged(Permission),
    Started(Uuid),
    Audio(CapturedAudio),
    Failed(CaptureError),
    Cancelled,
}
enum BackendEvent {
    Ready(Vec<f32>, bool),
    Failed(CaptureError),
}
#[derive(Clone, PartialEq, Eq)]
pub struct InputDevice {
    pub uid: String,
    pub name: String,
    pub is_default: bool,
}
fn valid_device_uid(uid: &str) -> bool {
    !uid.is_empty() && uid.len() <= 4096 && !uid.chars().any(char::is_control)
}
fn validate_devices(devices: &[InputDevice]) -> Result<(), CaptureError> {
    if devices.len() > 128 {
        return Err(CaptureError::Overflow);
    }
    let mut ids = std::collections::HashSet::new();
    for device in devices {
        if !valid_device_uid(&device.uid)
            || device.name.is_empty()
            || device.name.len() > 512
            || device.name.chars().any(char::is_control)
            || !ids.insert(&device.uid)
        {
            return Err(CaptureError::InvalidBinding);
        }
    }
    Ok(())
}
trait CaptureBackend {
    fn read_samples(&mut self, _: usize, _: usize) -> Result<Vec<f32>, CaptureError> {
        Ok(Vec::new())
    }
    fn input_devices(&mut self) -> Result<Vec<InputDevice>, CaptureError> {
        Err(CaptureError::Unavailable)
    }
    fn start_on_device(
        &mut self,
        maximum_samples: usize,
        uid: Option<&str>,
    ) -> Result<(), CaptureError> {
        if uid.is_some() {
            Err(CaptureError::NoInput)
        } else {
            self.start(maximum_samples)
        }
    }
    fn available(&self) -> bool;
    fn permission(&self) -> Permission;
    fn request_permission(&mut self) -> Result<(), CaptureError>;
    fn poll_permission(&mut self) -> Option<Permission>;
    fn discard_permission(&mut self);
    fn start(&mut self, maximum_samples: usize) -> Result<(), CaptureError>;
    fn stop(&mut self);
    fn cancel(&mut self);
    fn poll(&mut self) -> Option<BackendEvent>;
    fn progress(&self) -> Option<BackendProgress> {
        None
    }
}
struct Session {
    id: Uuid,
    generation: u64,
    binding: CaptureBinding,
    maximum_samples: usize,
    stopping: bool,
}
/// Call on one native owner thread. Native start/Drop may synchronously initialize
/// or quiesce AVAudioEngine; do not call from an audio callback. Native conversion
/// itself runs on an owned serial queue. Methods are not exposed to agent APIs.
pub struct Microphone {
    backend: Box<dyn CaptureBackend>,
    permission: Permission,
    binding: Option<CaptureBinding>,
    generation: u64,
    permission_generation: Option<u64>,
    session: Option<Session>,
    completed: Option<Uuid>,
    events: VecDeque<CaptureEvent>,
}
impl Microphone {
    pub fn new() -> Self {
        #[cfg(all(
            feature = "native-microphone",
            any(target_os = "macos", target_os = "windows", target_os = "linux")
        ))]
        let backend = platform::Native::default();
        #[cfg(not(all(
            feature = "native-microphone",
            any(target_os = "macos", target_os = "windows", target_os = "linux")
        )))]
        let backend = platform::Native;
        Self::with_backend(Box::new(backend))
    }
    fn with_backend(backend: Box<dyn CaptureBackend>) -> Self {
        Self {
            backend,
            permission: Permission::Unavailable,
            binding: None,
            generation: 0,
            permission_generation: None,
            session: None,
            completed: None,
            events: VecDeque::new(),
        }
    }
    /// Compiled backend availability, NOT proof of TCC authorization/device input.
    pub fn backend_available(&self) -> bool {
        self.backend.available()
    }
    /// Explicit status query. It never creates an engine or requests permission.
    pub fn refresh_permission(&mut self) -> Permission {
        self.permission = self.backend.permission();
        self.permission
    }
    /// Native Enable Microphone action only. Grant does NOT call start.
    pub fn request_permission(&mut self) -> Result<(), CaptureError> {
        if self.session.is_some() || self.permission_generation.is_some() {
            return Err(CaptureError::Busy);
        }
        self.backend.request_permission()?;
        self.permission_generation = Some(self.generation);
        Ok(())
    }
    pub fn set_binding(&mut self, binding: Option<CaptureBinding>) {
        if self.binding != binding {
            self.cancel();
            self.binding = binding;
        }
    }
    /// Native Record action only; requires separate prior authorization. No
    /// automatic permission request or recognition is performed here.
    pub fn start(&mut self, maximum_seconds: usize) -> Result<Uuid, CaptureError> {
        self.start_on_device(maximum_seconds, None)
    }
    /// Enumeration is an explicit native worker action, never permission or
    /// capture. A chosen ID is metadata until a later explicit Record action.
    pub fn input_devices(&mut self) -> Result<Vec<InputDevice>, CaptureError> {
        if self.session.is_some() {
            return Err(CaptureError::Busy);
        }
        let devices = self.backend.input_devices()?;
        validate_devices(&devices)?;
        Ok(devices)
    }
    pub fn start_on_device(
        &mut self,
        maximum_seconds: usize,
        uid: Option<&str>,
    ) -> Result<Uuid, CaptureError> {
        if uid.is_some_and(|uid| !valid_device_uid(uid)) {
            return Err(CaptureError::InvalidBinding);
        }
        if self.session.is_some() || self.permission_generation.is_some() {
            return Err(CaptureError::Busy);
        }
        if maximum_seconds == 0 || maximum_seconds > MAX_SECONDS {
            return Err(CaptureError::InvalidLimit);
        }
        let binding = self.binding.clone().ok_or(CaptureError::InvalidBinding)?;
        if binding.thread_id.is_empty() || binding.selection.start > binding.selection.end {
            return Err(CaptureError::InvalidBinding);
        }
        if !self.backend.available() {
            return Err(CaptureError::Unavailable);
        }
        match self.refresh_permission() {
            Permission::Authorized | Permission::Ready => {}
            Permission::Unavailable => return Err(CaptureError::Unavailable),
            _ => return Err(CaptureError::PermissionRequired),
        }
        self.generation = self.generation.wrapping_add(1);
        self.completed = None;
        self.events.clear();
        let maximum_samples = maximum_seconds * SAMPLE_RATE;
        self.backend.start_on_device(maximum_samples, uid)?;
        let id = Uuid::new_v4();
        self.session = Some(Session {
            id,
            generation: self.generation,
            binding,
            maximum_samples,
            stopping: false,
        });
        self.events.push_back(CaptureEvent::Started(id));
        Ok(id)
    }
    /// Read only the live owner's published prefix. This does not open a
    /// device or grant a new consumer any capture authority.
    pub fn read_chunk(
        &mut self,
        id: Uuid,
        offset: usize,
        limit: usize,
    ) -> Result<Option<CaptureChunk>, CaptureError> {
        if limit == 0 || limit > 4096 {
            return Err(CaptureError::InvalidLimit);
        }
        let session = self
            .session
            .as_ref()
            .filter(|session| {
                session.id == id
                    && session.generation == self.generation
                    && self.binding.as_ref() == Some(&session.binding)
            })
            .ok_or(CaptureError::InvalidBinding)?;
        if offset > session.maximum_samples {
            return Err(CaptureError::Overflow);
        }
        let samples = self.backend.read_samples(offset, limit)?;
        if samples.len() > limit
            || offset.saturating_add(samples.len()) > session.maximum_samples
            || samples.iter().any(|sample| !sample.is_finite())
        {
            return Err(CaptureError::Overflow);
        }
        if samples.is_empty() {
            return Ok(None);
        }
        Ok(Some(CaptureChunk {
            session: id,
            generation: session.generation,
            binding: session.binding.clone(),
            offset,
            samples,
        }))
    }
    pub fn stop(&mut self, session: Uuid) -> Result<(), CaptureError> {
        let active = self
            .session
            .as_mut()
            .filter(|active| active.id == session)
            .ok_or(CaptureError::InvalidBinding)?;
        if !active.stopping {
            active.stopping = true;
            self.backend.stop();
        }
        Ok(())
    }
    pub fn cancel(&mut self) {
        let was_active = self.session.take().is_some();
        self.generation = self.generation.wrapping_add(1);
        self.completed = None;
        self.permission_generation = None;
        self.backend.discard_permission();
        self.backend.cancel();
        self.events.clear();
        if was_active {
            self.events.push_back(CaptureEvent::Cancelled);
        }
    }
    /// Parent polls native events; Audio never starts inference itself.
    pub fn poll(&mut self) -> Option<CaptureEvent> {
        if let Some(permission) = self.backend.poll_permission()
            && self.permission_generation.take() == Some(self.generation)
        {
            self.permission = permission;
            self.events
                .push_back(CaptureEvent::PermissionChanged(permission));
        }
        if let Some(event) = self.backend.poll()
            && let Some(session) = self.session.take()
            && session.generation == self.generation
            && self.binding.as_ref() == Some(&session.binding)
        {
            match event {
                BackendEvent::Ready(samples, limited) => {
                    let result = if samples.is_empty() {
                        Err(CaptureError::NothingRecorded)
                    } else if samples.len() > session.maximum_samples {
                        Err(CaptureError::Overflow)
                    } else {
                        encode_wav(&samples, SAMPLE_RATE as u32)
                            .map_err(|_| CaptureError::Conversion)
                    };
                    match result {
                        Ok(wav) => {
                            self.completed = Some(session.id);
                            self.events.push_back(CaptureEvent::Audio(CapturedAudio {
                                session: session.id,
                                generation: session.generation,
                                binding: session.binding,
                                wav,
                                limit_reached: limited,
                            }));
                        }
                        Err(error) => self.events.push_back(CaptureEvent::Failed(error)),
                    }
                }
                BackendEvent::Failed(error) => self.events.push_back(CaptureEvent::Failed(error)),
            }
        }
        self.events.pop_front()
    }
    pub fn accepts_audio(&self, audio: &CapturedAudio, live: &CaptureBinding) -> bool {
        audio.generation == self.generation
            && self.completed == Some(audio.session)
            && audio.binding == *live
            && self.binding.as_ref() == Some(live)
    }
    pub fn progress(&self) -> Option<CaptureProgress> {
        let session = self.session.as_ref()?;
        if session.stopping
            || session.generation != self.generation
            || self.binding.as_ref() != Some(&session.binding)
        {
            return None;
        }
        let progress = self.backend.progress()?;
        if progress.samples > session.maximum_samples
            || !progress.level.is_finite()
            || !(0.0..=1.0).contains(&progress.level)
        {
            return None;
        }
        Some(CaptureProgress {
            session: session.id,
            captured_samples: progress.samples,
            level: progress.level,
        })
    }
}
impl Default for Microphone {
    fn default() -> Self {
        Self::new()
    }
}
impl Drop for Microphone {
    fn drop(&mut self) {
        self.backend.discard_permission();
        self.backend.cancel();
    }
}

#[cfg(all(
    feature = "native-microphone",
    any(target_os = "windows", target_os = "linux")
))]
#[path = "microphone_cpal.rs"]
mod platform;

#[cfg(not(all(
    feature = "native-microphone",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
mod platform {
    use super::*;
    #[derive(Default)]
    pub(super) struct Native;
    impl CaptureBackend for Native {
        fn available(&self) -> bool {
            false
        }
        fn permission(&self) -> Permission {
            Permission::Unavailable
        }
        fn request_permission(&mut self) -> Result<(), CaptureError> {
            Err(CaptureError::Unavailable)
        }
        fn poll_permission(&mut self) -> Option<Permission> {
            None
        }
        fn discard_permission(&mut self) {}
        fn start(&mut self, _: usize) -> Result<(), CaptureError> {
            Err(CaptureError::Unavailable)
        }
        fn stop(&mut self) {}
        fn cancel(&mut self) {}
        fn poll(&mut self) -> Option<BackendEvent> {
            None
        }
    }
}
#[cfg(all(target_os = "macos", feature = "native-microphone"))]
mod platform {
    use super::*;
    use std::{
        ffi::{CStr, CString, c_char, c_void},
        ptr::NonNull,
    };
    #[repr(C)]
    struct CInputDevice {
        uid: *mut c_char,
        name: *mut c_char,
        is_default: i32,
    }
    struct DeviceList {
        ptr: *mut CInputDevice,
        count: usize,
    }
    impl Drop for DeviceList {
        fn drop(&mut self) {
            unsafe { cc_mic_input_devices_free(self.ptr, self.count) }
        }
    }
    unsafe extern "C" {
        fn cc_mic_permission_status() -> i32;
        fn cc_mic_request_permission() -> *mut c_void;
        fn cc_mic_permission_poll(request: *mut c_void) -> i32;
        fn cc_mic_permission_destroy(request: *mut c_void);
        fn cc_mic_start_device(
            maximum_samples: usize,
            uid: *const c_char,
            error: *mut i32,
        ) -> *mut c_void;
        fn cc_mic_input_devices(out: *mut *mut CInputDevice, count: *mut usize) -> i32;
        fn cc_mic_input_devices_free(devices: *mut CInputDevice, count: usize);
        fn cc_mic_stop(handle: *mut c_void);
        fn cc_mic_cancel(handle: *mut c_void);
        fn cc_mic_poll(handle: *mut c_void) -> i32;
        fn cc_mic_sample_count(handle: *mut c_void) -> usize;
        fn cc_mic_copy_samples(handle: *mut c_void, destination: *mut f32, capacity: usize) -> i32;
        fn cc_mic_destroy(handle: *mut c_void);
        fn cc_mic_read_samples(
            handle: *mut c_void,
            offset: usize,
            out: *mut f32,
            capacity: usize,
            written: *mut usize,
        ) -> i32;
        fn cc_mic_progress(handle: *mut c_void, samples: *mut usize, level: *mut f32) -> i32;
        #[cfg(test)]
        pub(super) fn cc_mic_fixture_read_published() -> i32;
        #[cfg(test)]
        pub(super) fn cc_mic_fixture_convert(
            input: *const f32,
            frames: usize,
            channels: u32,
            rate: f64,
            output: *mut f32,
            capacity: usize,
            written: *mut usize,
        ) -> i32;
    }
    #[derive(Default)]
    pub(super) struct Native {
        request: Option<NonNull<c_void>>,
        capture: Option<NonNull<c_void>>,
    }
    fn permission(value: i32) -> Permission {
        match value {
            0 => Permission::NotDetermined,
            1 => Permission::Authorized,
            2 => Permission::Denied,
            3 => Permission::Restricted,
            _ => Permission::Unavailable,
        }
    }
    fn error(value: i32) -> CaptureError {
        match value {
            -2 => CaptureError::PermissionRequired,
            -3 => CaptureError::NoInput,
            -4 => CaptureError::Overflow,
            -5 => CaptureError::Conversion,
            -6 => CaptureError::DeviceChanged,
            -7 => CaptureError::InvalidLimit,
            -8 => CaptureError::Busy,
            _ => CaptureError::Unavailable,
        }
    }
    impl CaptureBackend for Native {
        fn read_samples(&mut self, offset: usize, limit: usize) -> Result<Vec<f32>, CaptureError> {
            if limit == 0 || limit > 4096 {
                return Err(CaptureError::InvalidLimit);
            }
            let Some(handle) = self.capture else {
                return Err(CaptureError::InvalidBinding);
            };
            let mut samples = vec![0.0; limit];
            let mut written = 0;
            let code = unsafe {
                cc_mic_read_samples(
                    handle.as_ptr(),
                    offset,
                    samples.as_mut_ptr(),
                    limit,
                    &mut written,
                )
            };
            if code != 0 {
                return Err(error(code));
            }
            if written > limit {
                return Err(CaptureError::Overflow);
            }
            samples.truncate(written);
            Ok(samples)
        }

        fn input_devices(&mut self) -> Result<Vec<InputDevice>, CaptureError> {
            if self.capture.is_some() {
                return Err(CaptureError::Busy);
            }
            let mut ptr = std::ptr::null_mut();
            let mut count = 0;
            let code = unsafe { cc_mic_input_devices(&mut ptr, &mut count) };
            if code != 0 {
                return Err(error(code));
            }
            // Pinned bridge allocates at most128 entries and terminates every
            // UID/name (4096/512 bytes). Guard frees them on every decode path.
            if count > 128 {
                // This violates the pinned bridge's contract. Do not iterate
                // an untrusted count while reporting the failed receipt.
                unsafe { cc_mic_input_devices_free(ptr, 0) };
                return Err(CaptureError::Overflow);
            }
            let list = DeviceList { ptr, count };
            if ptr.is_null() {
                return Err(CaptureError::Unavailable);
            }
            let native = unsafe { std::slice::from_raw_parts(list.ptr, list.count) };
            let mut devices = Vec::with_capacity(count);
            for device in native {
                if device.uid.is_null() || device.name.is_null() {
                    return Err(CaptureError::InvalidBinding);
                }
                let uid = unsafe { CStr::from_ptr(device.uid) }
                    .to_str()
                    .map_err(|_| CaptureError::InvalidBinding)?
                    .to_owned();
                let name = unsafe { CStr::from_ptr(device.name) }
                    .to_str()
                    .map_err(|_| CaptureError::InvalidBinding)?
                    .to_owned();
                devices.push(InputDevice {
                    uid,
                    name,
                    is_default: device.is_default != 0,
                });
            }
            validate_devices(&devices)?;
            Ok(devices)
        }
        fn available(&self) -> bool {
            true
        }
        fn progress(&self) -> Option<BackendProgress> {
            let handle = self.capture?;
            let mut samples = 0;
            let mut level = 0.0;
            (unsafe { cc_mic_progress(handle.as_ptr(), &mut samples, &mut level) } != 0)
                .then_some(BackendProgress { samples, level })
        }
        fn permission(&self) -> Permission {
            unsafe { permission(cc_mic_permission_status()) }
        }
        fn request_permission(&mut self) -> Result<(), CaptureError> {
            if self.request.is_some() {
                return Err(CaptureError::Busy);
            }
            self.request = NonNull::new(unsafe { cc_mic_request_permission() });
            self.request.map(|_| ()).ok_or(CaptureError::Unavailable)
        }
        fn poll_permission(&mut self) -> Option<Permission> {
            let request = self.request?;
            let result = unsafe { cc_mic_permission_poll(request.as_ptr()) };
            if result == 0 {
                return None;
            }
            self.discard_permission();
            Some(permission(result))
        }
        fn discard_permission(&mut self) {
            if let Some(request) = self.request.take() {
                unsafe {
                    cc_mic_permission_destroy(request.as_ptr());
                }
            }
        }
        fn start(&mut self, maximum_samples: usize) -> Result<(), CaptureError> {
            self.start_on_device(maximum_samples, None)
        }
        fn start_on_device(
            &mut self,
            maximum_samples: usize,
            uid: Option<&str>,
        ) -> Result<(), CaptureError> {
            let uid = uid
                .map(CString::new)
                .transpose()
                .map_err(|_| CaptureError::InvalidBinding)?;
            if self.capture.is_some() {
                return Err(CaptureError::Busy);
            }
            let mut code = -1;
            self.capture = NonNull::new(unsafe {
                cc_mic_start_device(
                    maximum_samples,
                    uid.as_ref().map_or(std::ptr::null(), |uid| uid.as_ptr()),
                    &mut code,
                )
            });
            self.capture.map(|_| ()).ok_or_else(|| error(code))
        }
        fn stop(&mut self) {
            if let Some(capture) = self.capture {
                unsafe {
                    cc_mic_stop(capture.as_ptr());
                }
            }
        }
        fn cancel(&mut self) {
            if let Some(capture) = self.capture.take() {
                unsafe {
                    cc_mic_cancel(capture.as_ptr());
                    cc_mic_destroy(capture.as_ptr());
                }
            }
        }
        fn poll(&mut self) -> Option<BackendEvent> {
            let capture = self.capture?;
            let state = unsafe { cc_mic_poll(capture.as_ptr()) };
            if state == 1 {
                return None;
            }
            let result = if state == 2 || state == 3 {
                let count = unsafe { cc_mic_sample_count(capture.as_ptr()) };
                if count > SAMPLE_RATE * MAX_SECONDS {
                    BackendEvent::Failed(CaptureError::Overflow)
                } else {
                    let mut samples = vec![0.0; count];
                    let code = unsafe {
                        cc_mic_copy_samples(capture.as_ptr(), samples.as_mut_ptr(), samples.len())
                    };
                    if code != 0 {
                        BackendEvent::Failed(error(code))
                    } else {
                        BackendEvent::Ready(samples, state == 3)
                    }
                }
            } else {
                BackendEvent::Failed(error(state))
            };
            self.cancel();
            Some(result)
        }
    }
    impl Drop for Native {
        fn drop(&mut self) {
            self.discard_permission();
            self.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, rc::Rc};
    struct FakeState {
        permission: Permission,
        pending: bool,
        starts: usize,
        requests: usize,
        stops: usize,
        cancelled: usize,
        recording: bool,
        progress: Option<BackendProgress>,
        event: Option<BackendEvent>,
        published: Vec<f32>,
    }
    struct Fake(Rc<RefCell<FakeState>>);
    impl CaptureBackend for Fake {
        fn read_samples(&mut self, offset: usize, limit: usize) -> Result<Vec<f32>, CaptureError> {
            let state = self.0.borrow();
            if offset > state.published.len() {
                return Err(CaptureError::InvalidBinding);
            }
            Ok(state.published[offset..]
                .iter()
                .take(limit)
                .copied()
                .collect())
        }
        fn progress(&self) -> Option<BackendProgress> {
            self.0.borrow().progress
        }
        fn available(&self) -> bool {
            true
        }
        fn permission(&self) -> Permission {
            self.0.borrow().permission
        }
        fn request_permission(&mut self) -> Result<(), CaptureError> {
            let mut state = self.0.borrow_mut();
            state.requests += 1;
            state.pending = true;
            Ok(())
        }
        fn poll_permission(&mut self) -> Option<Permission> {
            let mut state = self.0.borrow_mut();
            if state.pending && state.permission != Permission::NotDetermined {
                state.pending = false;
                Some(state.permission)
            } else {
                None
            }
        }
        fn discard_permission(&mut self) {
            self.0.borrow_mut().pending = false;
        }
        fn start(&mut self, _: usize) -> Result<(), CaptureError> {
            let mut state = self.0.borrow_mut();
            state.starts += 1;
            state.recording = true;
            Ok(())
        }
        fn stop(&mut self) {
            self.0.borrow_mut().stops += 1;
        }
        fn cancel(&mut self) {
            let mut state = self.0.borrow_mut();
            if state.recording {
                state.cancelled += 1;
                state.recording = false;
            }
            state.event = None;
        }
        fn poll(&mut self) -> Option<BackendEvent> {
            let mut state = self.0.borrow_mut();
            let result = state.event.take();
            if result.is_some() {
                state.recording = false;
            }
            result
        }
    }
    fn binding(revision: u64) -> CaptureBinding {
        CaptureBinding {
            thread_id: "synthetic-thread".into(),
            composer_revision: revision,
            settings_revision: 1,
            selection: 0..0,
        }
    }
    fn setup(permission: Permission) -> (Microphone, Rc<RefCell<FakeState>>) {
        let state = Rc::new(RefCell::new(FakeState {
            permission,
            pending: false,
            starts: 0,
            requests: 0,
            stops: 0,
            cancelled: 0,
            recording: false,
            progress: None,
            event: None,
            published: Vec::new(),
        }));
        let mut controller = Microphone::with_backend(Box::new(Fake(state.clone())));
        controller.set_binding(Some(binding(1)));
        (controller, state)
    }
    #[::core::prelude::v1::test]
    fn published_pcm_chunks_are_bounded_and_bound_to_actual_session_and_target() {
        let (mut microphone, state) = setup(Permission::Authorized);
        let session = microphone.start(1).unwrap();
        state.borrow_mut().published = vec![0.0, 0.5, -0.5];
        let chunk = microphone.read_chunk(session, 0, 2).unwrap().unwrap();
        assert_eq!(chunk.samples, vec![0.0, 0.5]);
        assert_eq!(chunk.offset, 0);
        assert!(chunk.binding == binding(1));
        assert_eq!(chunk.session, session);
        assert_eq!(
            microphone
                .read_chunk(session, 2, 2)
                .unwrap()
                .unwrap()
                .samples,
            vec![-0.5]
        );
        assert!(microphone.read_chunk(session, 3, 2).unwrap().is_none());
        assert!(matches!(
            microphone.read_chunk(Uuid::new_v4(), 0, 2),
            Err(CaptureError::InvalidBinding)
        ));
        assert!(matches!(
            microphone.read_chunk(session, 0, 4097),
            Err(CaptureError::InvalidLimit)
        ));
        assert_eq!(state.borrow().starts, 1);
        assert_eq!(state.borrow().requests, 0);
        microphone.set_binding(Some(binding(2)));
        assert!(matches!(
            microphone.read_chunk(session, 0, 2),
            Err(CaptureError::InvalidBinding)
        ));
    }
    #[::core::prelude::v1::test]
    fn unimplemented_selected_device_adapter_never_calls_default_start() {
        let (mut controller, state) = setup(Permission::Authorized);
        assert_eq!(
            controller.start_on_device(1, Some("missing-input")),
            Err(CaptureError::NoInput)
        );
        assert_eq!(state.borrow().starts, 0);
        assert_eq!(state.borrow().requests, 0);
        assert_eq!(
            controller.start_on_device(1, Some("")),
            Err(CaptureError::InvalidBinding)
        );
        assert_eq!(state.borrow().starts, 0);
        controller.start_on_device(1, None).unwrap();
        assert_eq!(state.borrow().starts, 1);
    }
    #[::core::prelude::v1::test]
    fn device_metadata_is_bounded_unambiguous_and_not_capture_authority() {
        let valid = InputDevice {
            uid: "synthetic-mic".into(),
            name: "Synthetic microphone".into(),
            is_default: true,
        };
        assert!(validate_devices(std::slice::from_ref(&valid)).is_ok());
        assert_eq!(
            validate_devices(&[valid.clone(), valid.clone()]),
            Err(CaptureError::InvalidBinding)
        );
        assert_eq!(
            validate_devices(&vec![valid.clone(); 129]),
            Err(CaptureError::Overflow)
        );
        let mut invalid = valid;
        invalid.uid = "x".repeat(4097);
        assert_eq!(
            validate_devices(&[invalid]),
            Err(CaptureError::InvalidBinding)
        );
    }
    #[::core::prelude::v1::test]
    fn permission_is_explicit_and_grant_never_starts_recording() {
        let (mut controller, state) = setup(Permission::NotDetermined);
        assert_eq!(state.borrow().requests, 0);
        assert_eq!(state.borrow().starts, 0);
        assert_eq!(controller.start(1), Err(CaptureError::PermissionRequired));
        assert_eq!(state.borrow().requests, 0);
        controller.request_permission().unwrap();
        assert_eq!(state.borrow().requests, 1);
        assert!(controller.poll().is_none());
        state.borrow_mut().permission = Permission::Authorized;
        assert!(matches!(
            controller.poll(),
            Some(CaptureEvent::PermissionChanged(Permission::Authorized))
        ));
        assert_eq!(state.borrow().starts, 0);
        controller.start(1).unwrap();
        assert_eq!(state.borrow().starts, 1);
        assert_eq!(controller.start(1), Err(CaptureError::Busy));
    }
    #[::core::prelude::v1::test]
    fn stop_encodes_bounded_samples_into_existing_wav_codec() {
        let (mut controller, state) = setup(Permission::Authorized);
        let session = controller.start(1).unwrap();
        assert!(matches!(controller.poll(), Some(CaptureEvent::Started(_))));
        controller.stop(session).unwrap();
        controller.stop(session).unwrap();
        assert_eq!(state.borrow().stops, 1);
        state.borrow_mut().event = Some(BackendEvent::Ready(vec![0.0, 0.5, -0.5], true));
        let Some(CaptureEvent::Audio(audio)) = controller.poll() else {
            panic!("expected audio");
        };
        assert!(controller.accepts_audio(&audio, &binding(1)));
        assert!(audio.limit_reached);
        assert_eq!(audio.wav, encode_wav(&[0.0, 0.5, -0.5], 16_000).unwrap());
        controller.set_binding(Some(binding(2)));
        assert!(!controller.accepts_audio(&audio, &binding(2)));
    }
    #[::core::prelude::v1::test]
    fn native_progress_requires_the_actual_live_session_and_valid_backend_samples() {
        let (mut controller, state) = setup(Permission::Authorized);
        state.borrow_mut().progress = Some(BackendProgress {
            samples: 100,
            level: 0.25,
        });
        assert!(controller.progress().is_none());
        let session = controller.start(1).unwrap();
        assert_eq!(
            controller.progress(),
            Some(CaptureProgress {
                session,
                captured_samples: 100,
                level: 0.25
            })
        );
        state.borrow_mut().progress = Some(BackendProgress {
            samples: 16_001,
            level: 0.25,
        });
        assert!(controller.progress().is_none());
        state.borrow_mut().progress = Some(BackendProgress {
            samples: 100,
            level: f32::NAN,
        });
        assert!(controller.progress().is_none());
        state.borrow_mut().progress = Some(BackendProgress {
            samples: 100,
            level: 0.25,
        });
        controller.stop(session).unwrap();
        assert!(controller.progress().is_none());
        controller.set_binding(Some(binding(2)));
        assert!(
            controller.progress().is_none(),
            "late backend progress cannot revive a revoked session"
        );
    }
    #[::core::prelude::v1::test]
    fn cancel_drop_and_changed_binding_discard_late_results() {
        let (mut controller, state) = setup(Permission::Authorized);
        controller.start(1).unwrap();
        controller.set_binding(Some(binding(2)));
        assert_eq!(state.borrow().cancelled, 1);
        // A deliberately broken fake supplies a late result after cancellation.
        state.borrow_mut().event = Some(BackendEvent::Ready(vec![1.0], false));
        assert!(matches!(controller.poll(), Some(CaptureEvent::Cancelled)));
        assert!(controller.poll().is_none());
        controller.start(1).unwrap();
        drop(controller);
        assert_eq!(state.borrow().cancelled, 2);
    }
    #[::core::prelude::v1::test]
    fn denial_limits_and_nonfinite_samples_fail_closed() {
        let (mut controller, state) = setup(Permission::Denied);
        assert_eq!(controller.start(0), Err(CaptureError::InvalidLimit));
        assert_eq!(controller.start(601), Err(CaptureError::InvalidLimit));
        assert_eq!(controller.start(1), Err(CaptureError::PermissionRequired));
        assert_eq!(state.borrow().starts, 0);
        state.borrow_mut().permission = Permission::Authorized;
        for (samples, expected) in [
            (vec![0.0; 16_001], CaptureError::Overflow),
            (vec![f32::NAN], CaptureError::Conversion),
            (vec![], CaptureError::NothingRecorded),
        ] {
            controller.start(1).unwrap();
            let _ = controller.poll();
            state.borrow_mut().event = Some(BackendEvent::Ready(samples, false));
            assert!(
                matches!(controller.poll(), Some(CaptureEvent::Failed(error)) if error == expected)
            );
        }
    }
    #[::core::prelude::v1::test]
    fn late_permission_result_after_target_change_cannot_start_or_emit() {
        let (mut controller, state) = setup(Permission::NotDetermined);
        controller.request_permission().unwrap();
        controller.set_binding(Some(binding(2)));
        state.borrow_mut().permission = Permission::Authorized;
        state.borrow_mut().pending = true; // deliberately late fake callback
        assert!(controller.poll().is_none());
        assert_eq!(state.borrow().starts, 0);
    }
    #[cfg(not(all(
        feature = "native-microphone",
        any(target_os = "macos", target_os = "windows", target_os = "linux")
    )))]
    #[::core::prelude::v1::test]
    fn default_platform_cannot_request_permission_or_record() {
        let mut controller = Microphone::new();
        assert!(!controller.backend_available());
        assert_eq!(
            controller.request_permission(),
            Err(CaptureError::Unavailable)
        );
        controller.set_binding(Some(binding(1)));
        assert_eq!(controller.start(1), Err(CaptureError::Unavailable));
    }
    #[cfg(all(target_os = "macos", feature = "native-microphone"))]
    #[::core::prelude::v1::test]
    fn native_published_reader_fixture_uses_only_private_samples_and_queue() {
        assert_eq!(unsafe { platform::cc_mic_fixture_read_published() }, 0);
    }
    #[cfg(all(target_os = "macos", feature = "native-microphone"))]
    #[::core::prelude::v1::test]
    fn native_converter_fixture_resamples_and_flushes_without_capture_engine() {
        for rate in [44_100, 48_000] {
            let frames = rate / 10;
            let mut stereo = Vec::with_capacity(frames * 2);
            for _ in 0..frames {
                stereo.extend([0.25_f32, 0.75_f32]);
            }
            let mut output = vec![0.0; 4096];
            let mut written = 0;
            let status = unsafe {
                platform::cc_mic_fixture_convert(
                    stereo.as_ptr(),
                    frames,
                    2,
                    rate as f64,
                    output.as_mut_ptr(),
                    output.len(),
                    &mut written,
                )
            };
            assert_eq!(status, 0);
            assert!((1500..=1700).contains(&written));
            assert!(output[..written].iter().all(|sample| sample.is_finite()));
            // Interior steady-state samples validate stereo downmix, not just duration.
            let mean = output[200..written - 200].iter().sum::<f32>() / (written - 400) as f32;
            assert!((mean - 0.5).abs() < 0.05, "unexpected downmix amplitude");
            assert!(encode_wav(&output[..written], 16_000).is_ok());
        }
    }
}
