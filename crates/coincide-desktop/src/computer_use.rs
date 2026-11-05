//! Serialized Computer Use adapter. Construction is inert. Native controls are
//! deliberately distinct from the agent Request protocol. No listener is started.
use coincide_core::computer_use::*;
use serde_json::Value;
#[cfg(all(target_os = "macos", feature = "native-computer-use"))]
use serde_json::json;
use std::{
    collections::BTreeSet,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;
pub fn native_compiled() -> bool {
    cfg!(all(target_os = "macos", feature = "native-computer-use"))
}
#[derive(Debug, Clone)]
pub struct Status {
    pub enabled: bool,
    pub native_compiled: bool,
    pub permissions: Permissions,
    pub busy: bool,
    pub stopped: bool,
    pub error: Option<Failure>,
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
}
impl Handle {
    /// Native UI only; revocation is immediate even when the mailbox is full.
    pub fn native_enable(&self, enabled: bool) -> Result<(), Failure> {
        if enabled && !self.compiled {
            return Err(Failure::Unsupported);
        }
        self.authority.native_enable(enabled);
        Ok(())
    }
    pub fn native_grant(&self, thread: Uuid) -> Result<(), Failure> {
        if !self.compiled {
            return Err(Failure::Unsupported);
        }
        self.authority.native_grant(thread)
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
        if !self.compiled {
            return Err(Failure::Unsupported);
        }
        if !self.authority.enabled() {
            return Err(Failure::Off);
        }
        if self.stop.load(Ordering::Acquire) {
            return Err(Failure::Revoked);
        }
        self.tx.try_send(message).map_err(|e| match e {
            TrySendError::Full(_) => Failure::Busy,
            TrySendError::Disconnected(_) => Failure::Revoked,
        })
    }
    /// Agent endpoint: authenticated parent supplies thread UUID, never from JSON.
    /// One bounded request; errors are returned without changing native authority.
    pub fn try_request(&self, thread: Uuid, request: Request) -> Result<Uuid, Failure> {
        if self.stop.load(Ordering::Acquire) {
            return Err(Failure::Revoked);
        }
        let grant = self.authority.grant(thread)?;
        let id = Uuid::new_v4();
        let job = Job {
            id,
            thread,
            grant,
            request,
            deadline: Instant::now() + Duration::from_secs(10),
        };
        let mut in_flight = self.in_flight.try_lock().map_err(|_| Failure::Busy)?;
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
    pub fn try_status(&self) -> Option<Status> {
        self.status.try_lock().ok().map(|s| {
            let mut status = s.clone();
            status.enabled = self.authority.enabled();
            status
        })
    }
    pub fn shutdown(&self) {
        self.authority.native_enable(false);
        self.stop.store(true, Ordering::Release);
    }
}
/// Drop signals only. The worker owns native object cleanup; no join on GPUI.
pub struct Runtime {
    handle: Handle,
    rx: Receiver<Reply>,
}
impl Runtime {
    pub fn spawn_native() -> std::io::Result<Self> {
        #[cfg(all(target_os = "macos", feature = "native-computer-use"))]
        {
            Self::spawn(NativeBackend::default(), true)
        }
        #[cfg(not(all(target_os = "macos", feature = "native-computer-use")))]
        {
            Self::spawn(UnsupportedBackend, false)
        }
    }
    pub fn spawn<B: Backend + Send + 'static>(backend: B, compiled: bool) -> std::io::Result<Self> {
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
        };
        let h = handle.clone();
        thread::Builder::new()
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
                status.stopped = true;
                status.enabled = false;
                status.busy = false;
                if outcome.is_err() {
                    status.error = Some(Failure::Native);
                }
            })?;
        Ok(Self { handle, rx })
    }
    pub fn handle(&self) -> Handle {
        self.handle.clone()
    }
    /// Replies can contain private UI data. Parent routes ONLY to matching thread.
    pub fn try_reply(&self) -> Result<Reply, TryRecvError> {
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
        self.handle.shutdown();
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
    impl Backend for NativeBackend {
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
        assert_eq!(h.try_request(t, Request::Status), Err(Failure::NotGranted));
        h.native_grant(t).unwrap();
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
        assert!(!h.thread_enabled(t));
        assert_eq!(h.try_request(t, Request::Status), Err(Failure::Revoked));
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
}
