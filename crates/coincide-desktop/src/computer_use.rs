//! Serialized Computer Use adapter. Construction is inert. Native controls are
//! deliberately distinct from the agent Request protocol; agents reach it only
//! through each thread's private bridge connection (computer_use_bridge).
use coincide_core::agent::WorkerThreadStatus;
use coincide_core::computer_use::*;
use serde_json::Value;
#[cfg(all(target_os = "macos", feature = "native-computer-use"))]
use serde_json::json;
use std::{
    collections::BTreeSet,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;
#[cfg(any(test, target_os = "windows"))]
#[path = "native_capture_owner.rs"]
pub(crate) mod capture_owner;
#[cfg(all(target_os = "linux", feature = "native-computer-use"))]
#[path = "computer_use_linux.rs"]
mod linux;
#[cfg(any(test, all(target_os = "linux", feature = "native-computer-use")))]
#[path = "computer_use_linux_policy.rs"]
mod linux_policy;
#[cfg(all(target_os = "windows", feature = "native-computer-use"))]
#[path = "computer_use_windows.rs"]
mod windows;
#[cfg(any(test, target_os = "windows"))]
#[path = "computer_use_windows_policy.rs"]
mod windows_policy;
pub fn native_compiled() -> bool {
    cfg!(all(
        any(
            target_os = "macos",
            target_os = "windows",
            target_os = "linux"
        ),
        feature = "native-computer-use"
    ))
}
#[derive(Debug, Clone)]
pub struct Status {
    pub enabled: bool,
    pub native_compiled: bool,
    pub permissions: Permissions,
    pub busy: bool,
    pub stopped: bool,
    pub error: Option<Failure>,
    /// The thread whose actions hold the shared desktop.
    pub desktop_owner: Option<Uuid>,
}
impl Default for Status {
    fn default() -> Self {
        Self {
            enabled: false,
            native_compiled: native_compiled(),
            permissions: Permissions::default(),
            busy: false,
            stopped: false,
            error: None,
            desktop_owner: None,
        }
    }
}
pub struct Reply {
    grant: Uuid,
    deadline: Instant,
    pub id: Uuid,
    pub thread: Uuid,
    pub result: Result<Value, Failure>,
}
struct Job {
    id: Uuid,
    thread: Uuid,
    grant: Uuid,
    request: Request,
    deadline: Instant,
}
enum Message {
    Job(Job),
    Refresh,
    Permission(PermissionKind),
}
#[derive(Clone)]
pub struct Handle {
    authority: Authority,
    tx: SyncSender<Message>,
    status: Arc<Mutex<Status>>,
    stop: Arc<AtomicBool>,
    compiled: bool,
    in_flight: Arc<Mutex<BTreeSet<Uuid>>>,
    joined: Arc<AtomicU8>,
    /// A Settings switch change the mount still has to save.
    unsaved: Arc<Mutex<Option<bool>>>,
}
impl Handle {
    /// Native Settings switch: applies now and is saved by the mount, so the
    /// next launch starts the same way (Swift `settings.computerUseEnabled`).
    pub fn native_set_saved(&self, enabled: bool) -> Result<(), Failure> {
        self.native_enable(enabled)?;
        *self.unsaved.lock().unwrap_or_else(|e| e.into_inner()) = Some(enabled);
        Ok(())
    }
    pub(crate) fn take_unsaved(&self) -> Option<bool> {
        self.unsaved
            .try_lock()
            .ok()
            .and_then(|mut unsaved| unsaved.take())
    }
    /// Native UI only; revocation is immediate even when the mailbox is full.
    pub fn native_enable(&self, enabled: bool) -> Result<(), Failure> {
        if enabled && self.stop.load(Ordering::Acquire) {
            return Err(Failure::Revoked);
        }
        if enabled && !self.compiled {
            return Err(Failure::Unsupported);
        }
        self.authority.native_enable(enabled);
        Ok(())
    }
    pub fn native_grant(&self, thread: Uuid) -> Result<(), Failure> {
        if self.stop.load(Ordering::Acquire) {
            return Err(Failure::Revoked);
        }
        if !self.compiled {
            return Err(Failure::Unsupported);
        }
        self.authority.native_grant(thread)
    }
    /// Trusted in-process Engine binding only; never export as a JSON setter.
    pub fn authority_for_engine(&self) -> Authority {
        self.authority.clone()
    }
    pub fn thread_enabled(&self, thread: Uuid) -> bool {
        self.authority.grant(thread).is_ok()
    }
    pub fn native_revoke(&self, thread: Uuid) {
        self.authority.native_revoke(thread);
    }
    pub fn native_refresh(&self) -> Result<(), Failure> {
        self.control(Message::Refresh)
    }
    pub fn native_request_permission(&self, kind: PermissionKind) -> Result<(), Failure> {
        self.control(Message::Permission(kind))
    }
    fn control(&self, message: Message) -> Result<(), Failure> {
        if self.stop.load(Ordering::Acquire) {
            return Err(Failure::Revoked);
        }
        if !self.compiled {
            return Err(Failure::Unsupported);
        }
        if !self.authority.enabled() {
            return Err(Failure::Off);
        }
        self.tx.try_send(message).map_err(|e| match e {
            TrySendError::Full(_) => Failure::Busy,
            TrySendError::Disconnected(_) => Failure::Revoked,
        })
    }
    /// Agent endpoint: authenticated parent supplies thread UUID, never from JSON.
    /// One bounded request; errors are returned without changing native authority.
    pub fn try_request(&self, thread: Uuid, request: Request) -> Result<Uuid, Failure> {
        self.try_request_until(thread, request, Instant::now() + Duration::from_secs(10))
    }
    /// Trusted gateway hook: preserve the original API deadline across Engine
    /// queueing. The caller cannot extend the runtime's ten-second ceiling.
    /// Deadline/grant are transport context, never accepted from agent JSON.
    pub fn try_request_until(
        &self,
        thread: Uuid,
        request: Request,
        deadline: Instant,
    ) -> Result<Uuid, Failure> {
        if deadline <= Instant::now() {
            return Err(Failure::TimedOut);
        }
        // Shutdown revokes Authority as well; inspect stopped state before a
        // disabled grant can incorrectly mask it as Off.
        if self.stop.load(Ordering::Acquire) {
            return Err(Failure::Revoked);
        }
        let grant = self.authority.grant(thread).map_err(|error| {
            if self.stop.load(Ordering::Acquire) {
                Failure::Revoked
            } else {
                error
            }
        })?;
        self.try_request_bound(thread, request, deadline, grant)
    }
    /// Native Engine handoff only. Pin the admission stamp into Job; never
    /// recapture a newer grant after an Engine queue delay or UI regrant.
    pub fn try_request_bound(
        &self,
        thread: Uuid,
        request: Request,
        deadline: Instant,
        expected_grant: Uuid,
    ) -> Result<Uuid, Failure> {
        let now = Instant::now();
        if deadline <= now {
            return Err(Failure::TimedOut);
        }
        let deadline = deadline.min(now + Duration::from_secs(10));
        if self.stop.load(Ordering::Acquire) {
            return Err(Failure::Revoked);
        }
        let grant = expected_grant;
        let id = Uuid::new_v4();
        let job = Job {
            id,
            thread,
            grant,
            request,
            deadline,
        };
        let mut in_flight = self.in_flight.try_lock().map_err(|_| Failure::Busy)?;
        if Instant::now() >= deadline {
            return Err(Failure::TimedOut);
        }
        if self.authority.grant(thread) != Ok(expected_grant) {
            return Err(Failure::Revoked);
        }
        // Equality is checked within reservation; Job keeps the expected stamp.
        // Regrant after this point can only revoke the job, never authorize it anew.
        if !in_flight.insert(thread) {
            return Err(Failure::Busy);
        }
        if let Err(error) = self.tx.try_send(Message::Job(job)) {
            in_flight.remove(&thread);
            return Err(match error {
                TrySendError::Full(_) => Failure::Busy,
                TrySendError::Disconnected(_) => Failure::Revoked,
            });
        }
        Ok(id)
    }
    /// Threads allowed this session, and those with a request running now.
    /// Never blocks: a contended reservation set reads as nothing in use.
    pub fn activity(&self) -> (Vec<Uuid>, Vec<Uuid>) {
        let in_use = self
            .in_flight
            .try_lock()
            .map(|threads| threads.iter().copied().collect())
            .unwrap_or_default();
        (self.authority.granted(), in_use)
    }
    pub fn try_status(&self) -> Option<Status> {
        self.status.try_lock().ok().map(|s| {
            let mut status = s.clone();
            status.enabled = self.authority.enabled();
            status.stopped = matches!(self.joined.load(Ordering::Acquire), 1 | 2);
            status
        })
    }
    pub fn shutdown(&self) {
        self.authority.native_enable(false);
        self.stop.store(true, Ordering::Release);
    }
}
/// Runtime shutdown describes this owned worker only, not whole-app readiness
/// or acceptance by macOS. Returned still requires inspection of backend errors.
#[derive(Debug, Clone)]
pub struct ShutdownStatus {
    pub requested: bool,
    pub worker: WorkerThreadStatus,
    pub backend: Option<Status>,
    pub observer_error: Option<String>,
    pub pending_reservations: Option<usize>,
}
/// Drop signals only. Worker joins happen on an independent observer, never GPUI.
pub struct Runtime {
    handle: Handle,
    rx: Receiver<Reply>,
    worker: Arc<Mutex<Option<thread::JoinHandle<()>>>>,
    join_observer_started: bool,
    join_observer_error: Option<String>,
}
impl Runtime {
    pub fn spawn_native() -> std::io::Result<Self> {
        #[cfg(all(target_os = "macos", feature = "native-computer-use"))]
        {
            Self::spawn(NativeBackend::default(), true)
        }
        #[cfg(all(target_os = "windows", feature = "native-computer-use"))]
        {
            Self::spawn(windows::NativeBackend::default(), true)
        }
        #[cfg(all(target_os = "linux", feature = "native-computer-use"))]
        {
            Self::spawn(linux::NativeBackend::default(), true)
        }
        #[cfg(not(all(
            any(target_os = "macos", target_os = "windows", target_os = "linux"),
            feature = "native-computer-use"
        )))]
        {
            Self::spawn(UnsupportedBackend, false)
        }
    }
    pub fn spawn<B: Backend + Send + 'static>(backend: B, compiled: bool) -> std::io::Result<Self> {
        Self::spawn_with_observer(backend, compiled, |observe| {
            thread::Builder::new()
                .name("coincide-computer-use-join".into())
                .spawn(observe)
        })
    }
    fn spawn_with_observer<B: Backend + Send + 'static>(
        backend: B,
        compiled: bool,
        spawn_observer: impl FnOnce(Box<dyn FnOnce() + Send>) -> std::io::Result<thread::JoinHandle<()>>,
    ) -> std::io::Result<Self> {
        let (tx, requests) = mpsc::sync_channel(8);
        let (results, rx) = mpsc::sync_channel(8);
        let authority = Authority::default();
        let handle = Handle {
            authority: authority.clone(),
            tx,
            status: Arc::new(Mutex::new(Status {
                native_compiled: compiled,
                ..Status::default()
            })),
            stop: Arc::new(AtomicBool::new(false)),
            compiled,
            in_flight: Arc::new(Mutex::new(BTreeSet::new())),
            joined: Arc::new(AtomicU8::new(0)),
            unsaved: Arc::new(Mutex::new(None)),
        };
        let h = handle.clone();
        let worker = thread::Builder::new()
            .name("coincide-computer-use".into())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let mut broker = Broker::new(backend, authority);
                    let mut pending = None;
                    while !h.stop.load(Ordering::Acquire) {
                        broker.reap_revoked();
                        if let Some(reply) = pending.take() {
                            match results.try_send(reply) {
                                Ok(()) => {}
                                Err(TrySendError::Full(reply)) => {
                                    pending = Some(reply);
                                    thread::park_timeout(Duration::from_millis(10));
                                    continue;
                                }
                                Err(TrySendError::Disconnected(_)) => break,
                            }
                        }
                        let mut status = h.status.lock().unwrap_or_else(|e| e.into_inner());
                        status.enabled = h.authority.enabled();
                        status.permissions = broker.cached_permissions();
                        status.desktop_owner = broker.desktop_owner();
                        drop(status);
                        let message = match requests.recv_timeout(Duration::from_millis(25)) {
                            Ok(m) => m,
                            Err(mpsc::RecvTimeoutError::Timeout) => continue,
                            Err(_) => break,
                        };
                        h.status.lock().unwrap_or_else(|e| e.into_inner()).busy = true;
                        match message {
                            Message::Job(job) => {
                                let mut result = broker.execute(
                                    job.thread,
                                    job.grant,
                                    job.request,
                                    job.deadline,
                                );
                                if h.authority.grant(job.thread) != Ok(job.grant) {
                                    result = Err(Failure::Revoked);
                                }
                                pending = Some(Reply {
                                    id: job.id,
                                    thread: job.thread,
                                    result,
                                    grant: job.grant,
                                    deadline: job.deadline,
                                });
                            }
                            Message::Refresh | Message::Permission(_) => {
                                let kind = if let Message::Permission(k) = message {
                                    Some(k)
                                } else {
                                    None
                                };
                                let result = broker.native_permission(kind);
                                h.status.lock().unwrap_or_else(|e| e.into_inner()).error =
                                    result.err();
                            }
                        }
                        h.status.lock().unwrap_or_else(|e| e.into_inner()).busy = false;
                    }
                    broker.invalidate();
                }));
                h.authority.native_enable(false);
                h.stop.store(true, Ordering::Release);
                let mut status = h.status.lock().unwrap_or_else(|e| e.into_inner());
                status.enabled = false;
                status.busy = false;
                if outcome.is_err() {
                    status.error = Some(Failure::Native);
                }
            })?;
        let mut runtime = Self {
            handle,
            rx,
            worker: Arc::new(Mutex::new(Some(worker))),
            join_observer_started: false,
            join_observer_error: None,
        };
        runtime.start_join_observer_with(spawn_observer);
        Ok(runtime)
    }
    fn start_join_observer_with(
        &mut self,
        spawn: impl FnOnce(Box<dyn FnOnce() + Send>) -> std::io::Result<thread::JoinHandle<()>>,
    ) {
        if self.join_observer_started {
            return;
        }
        let slot = self.worker.clone();
        let handle = self.handle.clone();
        let observe = Box::new(move || {
            let worker = slot
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .take();
            let Some(worker) = worker else {
                handle.joined.store(3, Ordering::Release);
                return;
            };
            let panicked = worker.join().is_err();
            let mut status = handle
                .status
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            status.stopped = true;
            status.busy = false;
            if panicked {
                status.error = Some(Failure::Native);
            }
            drop(status);
            handle
                .joined
                .store(if panicked { 2 } else { 1 }, Ordering::Release);
        });
        match spawn(observe) {
            Ok(_) => {
                self.join_observer_started = true;
                self.join_observer_error = None;
            }
            Err(error) => {
                // Closure drop has not taken the shared JoinHandle. Keep it in
                // Runtime for an explicit retry, never claim it has exited.
                self.join_observer_error = Some(error.to_string().chars().take(1024).collect());
            }
        }
    }
    fn discard_shutdown_data(&self) {
        // Bounded reply queue; no private observation survives shutdown polling.
        for _ in 0..8 {
            if self.rx.try_recv().is_err() {
                break;
            }
        }
        if let Ok(mut in_flight) = self.handle.in_flight.try_lock() {
            in_flight.clear();
        }
    }
    /// Signal revocation and request stop. This never joins or waits for backend
    /// work, and revocation itself is not worker-exit acknowledgement.
    pub fn request_shutdown(&mut self) {
        self.handle.shutdown();
        self.discard_shutdown_data();
        self.start_join_observer_with(|observe| {
            thread::Builder::new()
                .name("coincide-computer-use-join".into())
                .spawn(observe)
        });
    }
    /// Poll-only status. Actual join includes backend Drop and TLS destruction;
    /// an observer-start failure retains ownership and reports Running + error.
    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        let requested = self.handle.stop.load(Ordering::Acquire);
        if requested {
            self.discard_shutdown_data();
        }
        let worker = match self.handle.joined.load(Ordering::Acquire) {
            0 => WorkerThreadStatus::Running,
            1 => WorkerThreadStatus::Returned,
            2 => WorkerThreadStatus::Panicked,
            _ => WorkerThreadStatus::Unclassified,
        };
        if requested {
            self.discard_shutdown_data();
        }
        ShutdownStatus {
            requested,
            worker,
            backend: self.handle.try_status(),
            observer_error: self.join_observer_error.clone(),
            pending_reservations: self.handle.in_flight.try_lock().ok().map(|set| set.len()),
        }
    }
    pub fn handle(&self) -> Handle {
        self.handle.clone()
    }
    /// Replies can contain private UI data. Parent routes ONLY to matching thread.
    pub fn try_reply(&self) -> Result<Reply, TryRecvError> {
        if self.handle.stop.load(Ordering::Acquire) {
            self.discard_shutdown_data();
            return Err(TryRecvError::Disconnected);
        }
        let mut reply = self.rx.try_recv()?;
        self.handle
            .in_flight
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&reply.thread);
        if self.handle.authority.grant(reply.thread) != Ok(reply.grant) {
            reply.result = Err(Failure::Revoked);
        } else if Instant::now() >= reply.deadline {
            reply.result = Err(Failure::TimedOut);
        }
        Ok(reply)
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}
pub struct UnsupportedBackend;
impl Backend for UnsupportedBackend {
    fn permissions(&mut self) -> Result<Permissions, Failure> {
        Ok(Permissions {
            accessibility: Permission::Unsupported,
            screen_capture: Permission::Unsupported,
        })
    }
    fn request_permission(&mut self, _: PermissionKind) -> Result<Permissions, Failure> {
        Err(Failure::Unsupported)
    }
    fn call(&mut self, _: NativeCall, _: &Permit) -> Result<NativeResult, Failure> {
        Err(Failure::Unsupported)
    }
    fn invalidate(&mut self) {}
}

#[cfg(all(target_os = "macos", feature = "native-computer-use"))]
mod macos {
    use super::*;
    use std::{ffi::c_void, ptr};
    unsafe extern "C" {
        fn coincide_cu_create() -> *mut c_void;
        fn coincide_cu_destroy(ctx: *mut c_void);
        fn coincide_cu_call(
            ctx: *mut c_void,
            bytes: *const u8,
            length: usize,
            out: *mut usize,
            check: Option<unsafe extern "C" fn(*const c_void) -> bool>,
            guard: *const c_void,
        ) -> *mut u8;
        fn coincide_cu_free(bytes: *mut u8);
    }
    pub struct NativeBackend {
        context: *mut c_void,
    }
    impl Default for NativeBackend {
        fn default() -> Self {
            Self {
                context: ptr::null_mut(),
            }
        }
    }
    // SAFETY: instance is moved to one worker, never shared. All FFI access and
    // destruction are serialized there; no AppKit objects escape to Rust callers.
    unsafe impl Send for NativeBackend {}
    impl NativeBackend {
        fn invoke(&mut self, value: Value) -> Result<Value, Failure> {
            self.invoke_guarded(value, None)
        }
        fn invoke_guarded(
            &mut self,
            value: Value,
            permit: Option<&Permit>,
        ) -> Result<Value, Failure> {
            if let Some(permit) = permit {
                permit.check()?;
            }
            let bytes = serde_json::to_vec(&value).map_err(|_| Failure::InvalidRequest)?;
            if bytes.len() > MAX_REQUEST {
                return Err(Failure::TooLarge);
            }
            if self.context.is_null() {
                // SAFETY: creates owned context lazily on explicit authorized operation.
                self.context = unsafe { coincide_cu_create() };
            }
            if self.context.is_null() {
                return Err(Failure::Native);
            }
            let mut length = 0; // SAFETY: input slice live, output length writable, owned serialized context.
            unsafe extern "C" fn check_guard(raw: *const c_void) -> bool {
                // SAFETY: C invokes this synchronously while the borrowed Permit
                // is alive. Screenshot completion blocks never call this pointer.
                unsafe { (&*(raw.cast::<Permit>())).check().is_ok() }
            }
            let buffer = unsafe {
                coincide_cu_call(
                    self.context,
                    bytes.as_ptr(),
                    bytes.len(),
                    &mut length,
                    permit.map(|_| check_guard as unsafe extern "C" fn(*const c_void) -> bool),
                    permit.map_or(ptr::null(), |p| std::ptr::from_ref(p).cast()),
                )
            };
            if buffer.is_null() {
                return Err(Failure::Native);
            }
            struct Buffer(*mut u8);
            impl Drop for Buffer {
                fn drop(&mut self) {
                    // SAFETY: buffer originated from cu_call, freed once.
                    unsafe { coincide_cu_free(self.0) };
                }
            }
            let buffer = Buffer(buffer);
            if length > MAX_RESULT {
                return Err(Failure::TooLarge);
            }
            // SAFETY: native contract returns exactly length initialized bytes.
            let data = unsafe { std::slice::from_raw_parts(buffer.0, length) };
            let value: Value = serde_json::from_slice(data).map_err(|_| Failure::Native)?;
            if let Some(error) = value["error"].as_str() {
                return Err(match error {
                    "unsupported" => Failure::Unsupported,
                    "permission_denied" => Failure::PermissionDenied,
                    "stale_observation" => Failure::StaleObservation,
                    "timed_out" => Failure::TimedOut,
                    "revoked" => Failure::Revoked,
                    "too_large" => Failure::TooLarge,
                    _ => Failure::Native,
                });
            }
            Ok(value)
        }
        fn auth(&mut self, op: &str) -> Result<Permissions, Failure> {
            let value = self.invoke(json!({"op":op}))?;
            Ok(Permissions {
                accessibility: if value["ax"] == true {
                    Permission::Granted
                } else {
                    Permission::Denied
                },
                screen_capture: if value["screen"] == true {
                    Permission::Granted
                } else {
                    Permission::Denied
                },
            })
        }
    }
    /// One native op per extended tool; the adapter rechecks every target.
    fn extended_request(extended: Extended) -> Value {
        let target = |target: Target| match target {
            Target::Element(native) => json!({"native":native}),
            Target::Point { pid, window, x, y } => {
                json!({"pid":pid,"window":window,"x":x,"y":y})
            }
        };
        match extended {
            Extended::DoubleClick(t) => {
                json!({"op":"pointer","action":"double_click","target":target(t)})
            }
            Extended::RightClick(t) => {
                json!({"op":"pointer","action":"right_click","target":target(t)})
            }
            Extended::Scroll {
                target: t,
                direction,
                amount,
            } => {
                json!({"op":"pointer","action":"scroll","target":target(t),"direction":direction,"amount":amount})
            }
            Extended::MoveCursor { pid, window, x, y } => {
                json!({"op":"pointer","action":"move","target":{"pid":pid,"window":window,"x":x,"y":y}})
            }
            Extended::Drag {
                pid,
                window,
                from,
                to,
            } => {
                json!({"op":"drag","pid":pid,"window":window,"x":from[0],"y":from[1],"to_x":to[0],"to_y":to[1]})
            }
            Extended::TypeText { native, text } => {
                json!({"op":"type_text","native":native,"text":text})
            }
            Extended::Hotkey { native, chord } => {
                json!({"op":"hotkey","native":native,"modifiers":chord.modifiers,"key":chord.key})
            }
            Extended::InvokeMenu { pid, path } => json!({"op":"invoke_menu","pid":pid,"path":path}),
            Extended::LaunchApp { bundle_id } => json!({"op":"launch_app","bundle_id":bundle_id}),
            Extended::SetWindowFrame { pid, window, frame } => {
                json!({"op":"set_window_frame","pid":pid,"window":window,"x":frame[0],"y":frame[1],"width":frame[2],"height":frame[3]})
            }
            Extended::DesktopScreenshot => json!({"op":"desktop_screenshot"}),
            Extended::Zoom {
                pid,
                window,
                region,
            } => {
                json!({"op":"zoom","pid":pid,"window":window,"x":region[0],"y":region[1],"width":region[2],"height":region[3]})
            }
        }
    }
    impl Backend for NativeBackend {
        fn extended_tools(&self) -> &'static [&'static str] {
            &[
                "double_click",
                "right_click",
                "type_text",
                "hotkey",
                "scroll",
                "drag",
                "move_cursor",
                "invoke_menu",
                "launch_app",
                "set_window_frame",
                "zoom",
                "get_desktop_state",
            ]
        }
        fn permissions(&mut self) -> Result<Permissions, Failure> {
            self.auth("permissions")
        }
        fn request_permission(&mut self, kind: PermissionKind) -> Result<Permissions, Failure> {
            self.auth(match kind {
                PermissionKind::Accessibility => "request_ax",
                PermissionKind::ScreenCapture => "request_screen",
            })
        }
        fn invalidate(&mut self) {
            if !self.context.is_null() {
                let _ = self.invoke(json!({"op":"invalidate"}));
            }
        }
        fn call(&mut self, call: NativeCall, permit: &Permit) -> Result<NativeResult, Failure> {
            let request = match call {
                NativeCall::ListApps => json!({"op":"apps"}),
                NativeCall::ListWindows(Some(pid)) => json!({"op":"windows","pid":pid}),
                NativeCall::ListWindows(None) => json!({"op":"windows"}),
                NativeCall::Observe {
                    pid,
                    window,
                    limit,
                    screenshot,
                } => {
                    json!({"op":"observe","pid":pid,"window":window,"limit":limit,"screenshot":screenshot})
                }
                NativeCall::Press { native } => json!({"op":"press","native":native}),
                NativeCall::SetValue { native, text } => {
                    json!({"op":"set_value","native":native,"text":text})
                }
                NativeCall::Key { native, key } => json!({"op":"key","native":native,"key":key}),
                NativeCall::Point { pid, window, x, y } => {
                    json!({"op":"point","pid":pid,"window":window,"x":x,"y":y})
                }
                NativeCall::Extended(extended) => extended_request(extended),
            };
            let observe = request["op"] == "observe";
            permit.check()?;
            let value = self.invoke_guarded(request, Some(permit))?;
            if observe {
                let entries = value["nodes"].as_array().ok_or(Failure::Native)?;
                if entries.len() > MAX_NODES {
                    return Err(Failure::TooLarge);
                }
                let mut nodes = vec![];
                for n in entries {
                    nodes.push(Node {
                        native_id: n["native_id"].as_u64().ok_or(Failure::Native)?,
                        role: n["role"].as_str().unwrap_or("").into(),
                        title: n["title"].as_str().unwrap_or("").into(),
                        value: n["value"].as_str().map(str::to_owned),
                        secure: n["secure"].as_bool().unwrap_or(true),
                        focused: n["focused"].as_bool().unwrap_or(false),
                    });
                }
                let screenshot = if value["screenshot"].is_object() {
                    Some(Image {
                        png_base64: value["screenshot"]["png_base64"]
                            .as_str()
                            .ok_or(Failure::Native)?
                            .into(),
                        width: u32::try_from(
                            value["screenshot"]["width"]
                                .as_u64()
                                .ok_or(Failure::Native)?,
                        )
                        .map_err(|_| Failure::Native)?,
                        height: u32::try_from(
                            value["screenshot"]["height"]
                                .as_u64()
                                .ok_or(Failure::Native)?,
                        )
                        .map_err(|_| Failure::Native)?,
                    })
                } else {
                    None
                };
                return Ok(NativeResult::Snapshot(Snapshot {
                    nodes,
                    screenshot,
                    width: value["width"].as_f64().ok_or(Failure::Native)?,
                    height: value["height"].as_f64().ok_or(Failure::Native)?,
                }));
            }
            if let Some(data) = value.get("data") {
                Ok(NativeResult::Data(data.clone()))
            } else {
                Ok(NativeResult::Done)
            }
        }
    }
    impl Drop for NativeBackend {
        fn drop(&mut self) {
            if !self.context.is_null() {
                // SAFETY: owned context freed once on its worker.
                unsafe { coincide_cu_destroy(self.context) };
                self.context = ptr::null_mut();
            }
        }
    }
    #[cfg(test)]
    mod native_permission_tests {
        use super::*;

        #[test]
        fn native_permission_response_uses_json_booleans() {
            // This only checks permission state; it never prompts or reads a
            // window. Either granted or denied must cross the FFI as a bool.
            unsafe extern "C" {
                fn AXIsProcessTrusted() -> u8;
                fn CGPreflightScreenCaptureAccess() -> bool;
            }
            let mut backend = NativeBackend::default();
            let response = backend.invoke(json!({"op":"permissions"})).unwrap();
            // SAFETY: both system functions only return the current status.
            let accessibility = unsafe { AXIsProcessTrusted() != 0 };
            let screen = unsafe { CGPreflightScreenCaptureAccess() };
            assert_eq!(response["ax"].as_bool(), Some(accessibility), "{response}");
            assert_eq!(response["screen"].as_bool(), Some(screen), "{response}");
        }
    }
}
#[cfg(all(target_os = "macos", feature = "native-computer-use"))]
use macos::NativeBackend;

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    struct Fake {
        calls: Arc<AtomicUsize>,
        permissions: Arc<AtomicUsize>,
    }
    impl Backend for Fake {
        fn permissions(&mut self) -> Result<Permissions, Failure> {
            self.permissions.fetch_add(1, Ordering::SeqCst);
            Ok(Permissions {
                accessibility: Permission::Granted,
                screen_capture: Permission::Granted,
            })
        }
        fn request_permission(&mut self, _: PermissionKind) -> Result<Permissions, Failure> {
            self.permissions()
        }
        fn call(&mut self, _: NativeCall, _: &Permit) -> Result<NativeResult, Failure> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(NativeResult::Data(serde_json::json!({"fixture":true})))
        }
        fn invalidate(&mut self) {}
    }
    fn fake() -> (Runtime, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let permissions = Arc::new(AtomicUsize::new(0));
        (
            Runtime::spawn(
                Fake {
                    calls: calls.clone(),
                    permissions: permissions.clone(),
                },
                true,
            )
            .unwrap(),
            calls,
            permissions,
        )
    }
    fn reply(runtime: &Runtime) -> Reply {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Ok(reply) = runtime.try_reply() {
                return reply;
            }
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
    }
    #[test]
    fn default_off_and_enable_alone_never_query_or_prompt() {
        let (runtime, calls, permissions) = fake();
        let h = runtime.handle();
        let t = Uuid::new_v4();
        assert_eq!(h.try_request(t, Request::Status), Err(Failure::Off));
        assert_eq!(h.native_refresh(), Err(Failure::Off));
        h.native_enable(true).unwrap();
        // While on, every thread has access without a separate grant.
        let id = h.try_request(t, Request::Status).unwrap();
        assert_eq!(h.try_request(t, Request::Status), Err(Failure::Busy));
        assert_eq!(reply(&runtime).id, id);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(permissions.load(Ordering::SeqCst), 0);
        h.shutdown();
    }
    #[test]
    fn thread_identity_and_queued_late_reply_are_revoked_without_replay() {
        let (runtime, calls, _) = fake();
        let h = runtime.handle();
        let t = Uuid::new_v4();
        h.native_enable(true).unwrap();
        h.native_grant(t).unwrap();
        let id = h
            .try_request(t, Request::Call(Tool::ListApps(Empty {})))
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while calls.load(Ordering::SeqCst) == 0 {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        h.native_revoke(t);
        let result = reply(&runtime);
        assert_eq!(result.id, id);
        assert_eq!(result.thread, t);
        assert_eq!(result.result, Err(Failure::Revoked));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        h.shutdown();
    }
    #[test]
    fn request_mailbox_and_result_backpressure_are_bounded_and_stop_is_independent() {
        let (runtime, _, _) = fake();
        let h = runtime.handle();
        let t = Uuid::new_v4();
        h.native_enable(true).unwrap();
        h.native_grant(t).unwrap();
        let mut accepted = 0;
        let mut full = false;
        for _ in 0..31 {
            let thread = Uuid::new_v4();
            h.native_grant(thread).unwrap();
            match h.try_request(thread, Request::Status) {
                Ok(_) => accepted += 1,
                Err(Failure::Busy) => {
                    full = true;
                    break;
                }
                other => panic!("{other:?}"),
            }
        }
        assert!(full);
        assert!(accepted <= 17);
        h.native_enable(false).unwrap();
        while let Ok(r) = runtime.try_reply() {
            assert_eq!(r.result, Err(Failure::Revoked));
        }
        h.shutdown();
        assert_eq!(h.native_enable(true), Err(Failure::Revoked));
        assert_eq!(h.native_grant(t), Err(Failure::Revoked));
        assert!(!h.thread_enabled(t));
        assert_eq!(h.try_request(t, Request::Status), Err(Failure::Revoked));
    }
    #[test]
    fn gateway_deadline_is_preserved_clamped_and_rejected_before_admission() {
        let (runtime, calls, permissions) = fake();
        let h = runtime.handle();
        let t = Uuid::new_v4();
        h.native_enable(true).unwrap();
        h.native_grant(t).unwrap();
        assert_eq!(
            h.try_request_until(
                t,
                Request::Status,
                Instant::now() - Duration::from_millis(1)
            ),
            Err(Failure::TimedOut)
        );
        assert!(h.in_flight.lock().unwrap().is_empty());
        let original = Instant::now() + Duration::from_secs(1);
        h.try_request_until(t, Request::Status, original).unwrap();
        assert_eq!(reply(&runtime).deadline, original);
        let earliest_ceiling = Instant::now() + Duration::from_secs(10);
        h.try_request_until(t, Request::Status, Instant::now() + Duration::from_secs(60))
            .unwrap();
        let latest_ceiling = Instant::now() + Duration::from_secs(10);
        let result = reply(&runtime);
        assert!(result.deadline >= earliest_ceiling && result.deadline <= latest_ceiling);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(permissions.load(Ordering::SeqCst), 0);
        h.shutdown();
    }
    #[test]
    fn expired_gateway_request_waiting_behind_fake_work_never_calls_backend() {
        struct Blocked {
            calls: Arc<AtomicUsize>,
            permissions: Arc<AtomicUsize>,
            entered: SyncSender<()>,
            release: Receiver<()>,
        }
        impl Backend for Blocked {
            fn permissions(&mut self) -> Result<Permissions, Failure> {
                self.permissions.fetch_add(1, Ordering::SeqCst);
                Ok(Permissions {
                    accessibility: Permission::Granted,
                    screen_capture: Permission::Granted,
                })
            }
            fn request_permission(&mut self, _: PermissionKind) -> Result<Permissions, Failure> {
                unreachable!()
            }
            fn invalidate(&mut self) {}
            fn call(&mut self, _: NativeCall, _: &Permit) -> Result<NativeResult, Failure> {
                self.calls.fetch_add(1, Ordering::SeqCst);
                self.entered.try_send(()).unwrap();
                self.release.recv().unwrap();
                Ok(NativeResult::Done)
            }
        }
        struct ReleaseOnDrop(Option<SyncSender<()>>);
        impl Drop for ReleaseOnDrop {
            fn drop(&mut self) {
                if let Some(tx) = self.0.take() {
                    let _ = tx.try_send(());
                }
            }
        }
        let calls = Arc::new(AtomicUsize::new(0));
        let permissions = Arc::new(AtomicUsize::new(0));
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let runtime = Runtime::spawn(
            Blocked {
                calls: calls.clone(),
                permissions: permissions.clone(),
                entered: entered_tx,
                release: release_rx,
            },
            true,
        )
        .unwrap();
        let mut release = ReleaseOnDrop(Some(release_tx));
        let h = runtime.handle();
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        h.native_enable(true).unwrap();
        h.native_grant(first).unwrap();
        h.native_grant(second).unwrap();
        h.try_request(first, Request::Call(Tool::ListApps(Empty {})))
            .unwrap();
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let deadline = Instant::now() + Duration::from_millis(20);
        let id = h
            .try_request_until(second, Request::Call(Tool::ListApps(Empty {})), deadline)
            .unwrap();
        while Instant::now() < deadline {
            thread::sleep(deadline.saturating_duration_since(Instant::now()));
        }
        release.0.take().unwrap().try_send(()).unwrap();
        assert!(reply(&runtime).result.is_ok());
        let result = reply(&runtime);
        assert_eq!(result.id, id);
        assert_eq!(result.thread, second);
        assert_eq!(result.result, Err(Failure::TimedOut));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(permissions.load(Ordering::SeqCst), 1);
        // Expiry was a terminal failure, not a delivery retry or a leaked Busy slot.
        h.try_request(second, Request::Status).unwrap();
        assert!(reply(&runtime).result.is_ok());
        h.shutdown();
    }
    #[test]
    fn engine_handoff_never_retags_old_operation_after_regrant() {
        let (runtime, calls, permissions) = fake();
        let h = runtime.handle();
        let thread = Uuid::new_v4();
        h.native_enable(true).unwrap();
        h.native_grant(thread).unwrap();
        let old = h.authority_for_engine().grant(thread).unwrap();
        h.native_revoke(thread);
        h.native_grant(thread).unwrap();
        let current = h.authority_for_engine().grant(thread).unwrap();
        assert_ne!(old, current);
        assert_eq!(
            h.try_request_bound(
                thread,
                Request::Status,
                Instant::now() + Duration::from_secs(1),
                old
            ),
            Err(Failure::Revoked)
        );
        assert!(h.in_flight.lock().unwrap().is_empty());
        let id = h
            .try_request_bound(
                thread,
                Request::Status,
                Instant::now() + Duration::from_secs(1),
                current,
            )
            .unwrap();
        // Regrant after reservation also cannot authorize or expose old replies.
        h.native_grant(thread).unwrap();
        let result = reply(&runtime);
        assert_eq!(result.id, id);
        assert_eq!(result.result, Err(Failure::Revoked));
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(permissions.load(Ordering::SeqCst), 0);
        h.shutdown();
    }
    #[test]
    fn stopped_disabled_authority_has_deterministic_admission_precedence() {
        let (runtime, calls, permissions) = fake();
        let h = runtime.handle();
        let thread = Uuid::new_v4();
        h.native_enable(true).unwrap();
        h.native_grant(thread).unwrap();
        let grant = h.authority_for_engine().grant(thread).unwrap();
        h.shutdown();
        assert!(h.stop.load(Ordering::Acquire));
        assert_eq!(h.authority_for_engine().grant(thread), Err(Failure::Off));
        let future = Instant::now() + Duration::from_secs(1);
        assert_eq!(
            h.try_request(thread, Request::Status),
            Err(Failure::Revoked)
        );
        assert_eq!(
            h.try_request_until(thread, Request::Status, future),
            Err(Failure::Revoked)
        );
        assert_eq!(
            h.try_request_bound(thread, Request::Status, future, grant),
            Err(Failure::Revoked)
        );
        assert_eq!(h.native_refresh(), Err(Failure::Revoked));
        assert_eq!(
            h.native_request_permission(PermissionKind::Accessibility),
            Err(Failure::Revoked)
        );
        let expired = Instant::now() - Duration::from_secs(1);
        assert_eq!(
            h.try_request_until(thread, Request::Status, expired),
            Err(Failure::TimedOut)
        );
        assert_eq!(
            h.try_request_bound(thread, Request::Status, expired, grant),
            Err(Failure::TimedOut)
        );
        assert!(h.in_flight.lock().unwrap().is_empty());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(permissions.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn inactive_build_refuses_authority_without_any_backend_query() {
        let r = Runtime::spawn(UnsupportedBackend, false).unwrap();
        let h = r.handle();
        assert_eq!(h.native_enable(true), Err(Failure::Unsupported));
        assert_eq!(
            h.native_request_permission(PermissionKind::Accessibility),
            Err(Failure::Unsupported)
        );
        assert_eq!(
            h.try_request(Uuid::new_v4(), Request::Tools),
            Err(Failure::Off)
        );
        h.shutdown();
    }
    struct ExitGate {
        entered: mpsc::Sender<()>,
        release: Receiver<()>,
    }
    impl Drop for ExitGate {
        fn drop(&mut self) {
            let _ = self.entered.send(());
            let _ = self.release.recv();
        }
    }
    thread_local! {
        static EXIT_TLS_GATE: std::cell::RefCell<Option<ExitGate>> = const {
            std::cell::RefCell::new(None)
        };
    }
    struct CleanupBackend {
        backend_gate: Option<ExitGate>,
        tls_gate: Option<ExitGate>,
    }
    impl Backend for CleanupBackend {
        fn permissions(&mut self) -> Result<Permissions, Failure> {
            panic!("no permission call expected")
        }
        fn request_permission(&mut self, _: PermissionKind) -> Result<Permissions, Failure> {
            panic!("no permission request expected")
        }
        fn call(&mut self, _: NativeCall, _: &Permit) -> Result<NativeResult, Failure> {
            panic!("no native call expected")
        }
        fn invalidate(&mut self) {}
    }
    impl Drop for CleanupBackend {
        fn drop(&mut self) {
            EXIT_TLS_GATE.with(|slot| *slot.borrow_mut() = self.tls_gate.take());
            drop(self.backend_gate.take());
        }
    }
    struct CleanupFixture {
        backend: CleanupBackend,
        backend_entered: Receiver<()>,
        backend_release: mpsc::Sender<()>,
        tls_entered: Receiver<()>,
        tls_release: mpsc::Sender<()>,
    }
    fn cleanup_backend() -> CleanupFixture {
        let (backend_entered, backend_rx) = mpsc::channel();
        let (backend_release, backend_wait) = mpsc::channel();
        let (tls_entered, tls_rx) = mpsc::channel();
        let (tls_release, tls_wait) = mpsc::channel();
        CleanupFixture {
            backend: CleanupBackend {
                backend_gate: Some(ExitGate {
                    entered: backend_entered,
                    release: backend_wait,
                }),
                tls_gate: Some(ExitGate {
                    entered: tls_entered,
                    release: tls_wait,
                }),
            },
            backend_entered: backend_rx,
            backend_release,
            tls_entered: tls_rx,
            tls_release,
        }
    }
    fn joined_status(runtime: &mut Runtime) -> ShutdownStatus {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let status = runtime.shutdown_status();
            if status.worker != WorkerThreadStatus::Running {
                return status;
            }
            assert!(Instant::now() < deadline, "fake runtime did not join");
            thread::yield_now();
        }
    }
    #[test]
    fn shutdown_ack_waits_for_backend_drop_then_actual_tls_join() {
        let CleanupFixture {
            backend,
            backend_entered,
            backend_release,
            tls_entered,
            tls_release,
        } = cleanup_backend();
        let mut runtime = Runtime::spawn(backend, true).unwrap();
        let handle = runtime.handle();
        runtime.request_shutdown();
        backend_entered
            .recv_timeout(Duration::from_secs(5))
            .unwrap();
        assert_eq!(
            runtime.shutdown_status().worker,
            WorkerThreadStatus::Running
        );
        assert!(!handle.try_status().unwrap().stopped);
        backend_release.send(()).unwrap();
        tls_entered.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(
            runtime.shutdown_status().worker,
            WorkerThreadStatus::Running
        );
        assert!(!handle.try_status().unwrap().stopped);
        tls_release.send(()).unwrap();
        let status = joined_status(&mut runtime);
        assert!(status.requested);
        assert_eq!(status.worker, WorkerThreadStatus::Returned);
        assert!(status.backend.unwrap().stopped);
        assert!(status.observer_error.is_none());
        assert_eq!(status.pending_reservations, Some(0));
    }
    #[test]
    fn observer_spawn_failure_retains_worker_and_requires_explicit_retry() {
        let CleanupFixture {
            backend,
            backend_entered,
            backend_release,
            tls_entered,
            tls_release,
        } = cleanup_backend();
        let mut runtime = Runtime::spawn_with_observer(backend, true, |_| {
            Err(std::io::Error::other("synthetic observer spawn failure"))
        })
        .unwrap();
        runtime.handle().shutdown(); // Existing signal does not fabricate join ACK.
        backend_entered
            .recv_timeout(Duration::from_secs(5))
            .unwrap();
        assert!(runtime.worker.try_lock().unwrap().is_some());
        let pending = runtime.shutdown_status();
        assert_eq!(pending.worker, WorkerThreadStatus::Running);
        assert!(pending.observer_error.is_some());
        assert!(!pending.backend.unwrap().stopped);
        backend_release.send(()).unwrap();
        tls_entered.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(runtime.worker.try_lock().unwrap().is_some());
        assert_eq!(
            runtime.shutdown_status().worker,
            WorkerThreadStatus::Running
        );
        tls_release.send(()).unwrap();
        runtime.request_shutdown();
        let status = joined_status(&mut runtime);
        assert_eq!(status.worker, WorkerThreadStatus::Returned);
        assert!(status.observer_error.is_none());
        assert!(status.backend.unwrap().stopped);
    }
    #[test]
    fn caught_backend_panic_is_not_erased_by_successful_thread_join() {
        struct PanicBackend;
        impl Backend for PanicBackend {
            fn permissions(&mut self) -> Result<Permissions, Failure> {
                panic!("synthetic backend failure")
            }
            fn request_permission(&mut self, _: PermissionKind) -> Result<Permissions, Failure> {
                self.permissions()
            }
            fn call(&mut self, _: NativeCall, _: &Permit) -> Result<NativeResult, Failure> {
                unreachable!()
            }
            fn invalidate(&mut self) {}
        }
        let mut runtime = Runtime::spawn(PanicBackend, true).unwrap();
        let handle = runtime.handle();
        handle.native_enable(true).unwrap();
        handle.native_refresh().unwrap();
        let status = joined_status(&mut runtime);
        assert!(status.requested);
        assert_eq!(status.worker, WorkerThreadStatus::Returned);
        let backend = status.backend.unwrap();
        assert!(backend.stopped);
        assert_eq!(backend.error, Some(Failure::Native));
    }
    #[test]
    fn shutdown_discards_retained_private_replies_and_reservations() {
        let mut runtime = Runtime::spawn(UnsupportedBackend, false).unwrap();
        let (sender, receiver) = mpsc::sync_channel(8);
        runtime.rx = receiver;
        let owner = Uuid::new_v4();
        runtime.handle.in_flight.lock().unwrap().insert(owner);
        sender
            .send(Reply {
                grant: Uuid::new_v4(),
                deadline: Instant::now() + Duration::from_secs(1),
                id: Uuid::new_v4(),
                thread: owner,
                result: Ok(serde_json::json!({"private":"synthetic observation"})),
            })
            .unwrap();
        runtime.request_shutdown();
        assert!(matches!(runtime.rx.try_recv(), Err(TryRecvError::Empty)));
        assert!(matches!(
            runtime.try_reply(),
            Err(TryRecvError::Disconnected)
        ));
        let status = joined_status(&mut runtime);
        assert_eq!(status.pending_reservations, Some(0));
        assert_eq!(status.worker, WorkerThreadStatus::Returned);
    }
}
