//! Private, closed WebView2 isolated-world credential bridge. Never ExecuteScript,
//! numeric-context fallback, arbitrary CDP, public IPC, source interpolation or logs.
use super::super::shutdown::{NativeLease, NativeLifetimes};
use super::context::{Custody, UniqueContext, WorldBinding};
use super::scripts::{Attempt, Completion, FillSlot, PROBE, Secrets, windows_mutation_parameters};
use crate::credentials::FillPermit;
use coincide_core::credentials::{Failure, PageBinding};
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    thread::ThreadId,
    time::{SystemTime, UNIX_EPOCH},
};
use webview2_com::{
    CallDevToolsProtocolMethodCompletedHandler, CoTaskMemPWSTR,
    DevToolsProtocolEventReceivedEventHandler, Microsoft::Web::WebView2::Win32::*,
};
use windows::core::{HSTRING, PWSTR};
use wry::WebViewExtWindows;
// Production bridge passed the isolated native SDK fixture on all three hosts
// in Rust CI run 42353376575 (f4249ba4). Runtime checks still fail closed.
const NATIVE_FILL_VALIDATED: bool = true;
pub fn available() -> bool {
    NATIVE_FILL_VALIDATED
}
struct Cached {
    epoch: u64,
    frame: String,
    loader: String,
    unique: UniqueContext,
}
struct Source {
    view: ICoreWebView2,
    navigation: Arc<AtomicU64>,
    owner: ThreadId,
    closed: Cell<bool>,
    world: String,
    cache: RefCell<Option<Cached>>,
    lifetimes: RefCell<Option<NativeLifetimes>>,
    // The retained view above is dropped before its counted Rust owner below.
    _view_lease: RefCell<Option<NativeLease>>,
}
impl Source {
    fn matches(&self, binding: &PageBinding) -> bool {
        if self.closed.get()
            || self.owner != std::thread::current().id()
            || self.navigation.load(Ordering::Acquire) != binding.navigation
        {
            return false;
        }
        let mut raw = PWSTR::null();
        let result = unsafe { self.view.Source(&mut raw) };
        let current = unsafe { native_string(raw, 16384) }
            .and_then(|url| PageBinding::new(binding.tab.clone(), binding.navigation, &url).ok());
        result.is_ok()
            && current.as_ref() == Some(binding)
            && self.navigation.load(Ordering::Acquire) == binding.navigation
    }
    fn block(&self) -> Option<NativeLease> {
        self.lifetimes.borrow().as_ref().map(NativeLifetimes::block)
    }
}
#[derive(Clone)]
pub struct NativeCredentialTarget {
    source: Rc<Source>,
    operations: Rc<RefCell<Vec<Rc<Operation>>>>,
}
impl NativeCredentialTarget {
    pub fn new(view: &wry::WebView, navigation: Arc<AtomicU64>) -> Option<Self> {
        Some(Self {
            source: Rc::new(Source {
                view: view.webview(),
                navigation,
                owner: std::thread::current().id(),
                closed: Cell::new(false),
                world: format!("CoincidePrivateCredentialFillV1-{}", uuid::Uuid::new_v4()),
                cache: RefCell::new(None),
                lifetimes: RefCell::new(None),
                _view_lease: RefCell::new(None),
            }),
            operations: Rc::new(RefCell::new(Vec::new())),
        })
    }
    pub(in super::super) fn with_lifetimes(self, lifetimes: NativeLifetimes) -> Self {
        if self.source.lifetimes.borrow().is_none() {
            *self.source._view_lease.borrow_mut() = Some(lifetimes.target());
            *self.source.lifetimes.borrow_mut() = Some(lifetimes);
        }
        self
    }
    pub(in super::super) fn close(&self) {
        self.source.closed.set(true);
        self.poll_ownership();
    }
    pub(in super::super) fn poll_ownership(&self) -> bool {
        let operations = self.operations.borrow().clone();
        for operation in operations {
            operation.poll();
        }
        self.operations
            .borrow_mut()
            .retain(|operation| !operation.state.borrow().done);
        self.operations.borrow().is_empty()
    }
    pub fn fill(
        &self,
        binding: PageBinding,
        permit: FillPermit,
        username: &str,
        password: &str,
        totp: Option<&str>,
        completion: Completion,
    ) {
        if !permit.is_valid() {
            completion(Err(Failure::FillFailed));
            return;
        }
        if !self.source.matches(&binding) {
            completion(Err(Failure::StalePage));
            return;
        }
        if self
            .operations
            .borrow()
            .iter()
            .any(|op| !op.state.borrow().done)
        {
            completion(Err(Failure::FillFailed));
            return;
        }
        let Some(slot) = FillSlot::reserve() else {
            completion(Err(Failure::FillFailed));
            return;
        };
        let operation = Rc::new(Operation {
            source: self.source.clone(),
            binding,
            permit,
            ticket: uuid::Uuid::new_v4().to_string(),
            state: RefCell::new(State {
                attempt: Some(Attempt::new(
                    slot,
                    Secrets::new(username, password, totp),
                    completion,
                )),
                stage: Stage::Frame,
                nonce: uuid::Uuid::new_v4(),
                custody: Custody::new(),
                registration: None,
                world: None,
                unique: None,
                frame: None,
                loader: None,
                world_name: None,
                terminal: None,
                done: false,
            }),
        });
        self.operations.borrow_mut().push(operation.clone());
        operation.call(
            Method::Frame,
            json!({}),
            Stage::Frame,
            Operation::frame_returned,
        );
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    Frame,
    Enable,
    Create,
    AwaitProof,
    Probe,
    Mutation,
    BeforeMutation,
    Terminal,
}
enum Method {
    Frame,
    Enable,
    Create,
    Probe,
    Mutation,
}
enum Parameters {
    Metadata(Value),
    Secret(zeroize::Zeroizing<String>),
}
impl From<Value> for Parameters {
    fn from(value: Value) -> Self {
        Self::Metadata(value)
    }
}
impl Method {
    fn name(&self) -> &'static str {
        match self {
            Self::Frame => "Page.getFrameTree",
            Self::Enable => "Runtime.enable",
            Self::Create => "Page.createIsolatedWorld",
            Self::Probe | Self::Mutation => "Runtime.callFunctionOn",
        }
    }
}
struct Registration {
    receiver: ICoreWebView2DevToolsProtocolEventReceiver,
    token: i64,
    _handler: ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
}
impl Drop for Registration {
    fn drop(&mut self) {
        unsafe {
            let _ = self
                .receiver
                .remove_DevToolsProtocolEventReceived(self.token);
        }
    }
}
struct State {
    attempt: Option<Attempt>,
    stage: Stage,
    nonce: uuid::Uuid,
    custody: Custody,
    registration: Option<Registration>,
    world: Option<WorldBinding>,
    unique: Option<UniqueContext>,
    frame: Option<String>,
    loader: Option<String>,
    world_name: Option<String>,
    terminal: Option<Result<(), Failure>>,
    done: bool,
}
struct Operation {
    source: Rc<Source>,
    binding: PageBinding,
    permit: FillPermit,
    ticket: String,
    state: RefCell<State>,
}
impl Operation {
    fn live(&self) -> Result<(), Failure> {
        if !self.permit.is_valid() {
            return Err(Failure::FillFailed);
        }
        if !self.source.matches(&self.binding) {
            return Err(Failure::StalePage);
        }
        Ok(())
    }
    fn stop(self: &Rc<Self>, result: Result<(), Failure>) {
        let registration = {
            let mut state = self.state.borrow_mut();
            if state.terminal.is_none() {
                state.terminal = Some(result);
                state.stage = Stage::Terminal;
                if let Some(attempt) = &mut state.attempt {
                    attempt.expire(false);
                }
            }
            state.registration.take()
        };
        drop(registration);
        self.finish_if_returned();
    }
    fn finish_if_returned(&self) {
        let completion = {
            let mut state = self.state.borrow_mut();
            if state.done || !state.custody.returned_all() {
                None
            } else if let Some(result) = state.terminal {
                state.done = true;
                state.attempt.take().map(|attempt| (attempt, result))
            } else {
                None
            }
        };
        if let Some((attempt, result)) = completion {
            attempt.finish(result);
        }
    }
    fn poll(self: &Rc<Self>) {
        if self.state.borrow().terminal.is_none() {
            if let Err(error) = self.live() {
                self.stop(Err(error));
            }
        }
        self.finish_if_returned();
    }
    fn call(
        self: &Rc<Self>,
        method: Method,
        parameters: impl Into<Parameters>,
        stage: Stage,
        returned: fn(Rc<Self>, Value),
    ) {
        if let Err(error) = self.live() {
            self.stop(Err(error));
            return;
        }
        let encoded = match parameters.into() {
            Parameters::Secret(value) => value,
            Parameters::Metadata(value) => match serde_json::to_string(&value) {
                Ok(value) => zeroize::Zeroizing::new(value),
                Err(_) => {
                    self.stop(Err(Failure::FillFailed));
                    return;
                }
            },
        };
        let payload = HSTRING::from(encoded.as_str());
        let name = HSTRING::from(method.name());
        let nonce = {
            let mut state = self.state.borrow_mut();
            if state.terminal.is_some() {
                return;
            }
            state.stage = stage;
            state.nonce = uuid::Uuid::new_v4();
            state.custody.began();
            state.nonce
        };
        let operation = self.clone();
        let block = self.source.block();
        let handler =
            CallDevToolsProtocolMethodCompletedHandler::create(Box::new(move |code, body| {
                let _held = &block;
                let eligible = {
                    let mut state = operation.state.borrow_mut();
                    state.custody.returned();
                    state.terminal.is_none() && state.stage == stage && state.nonce == nonce
                };
                if eligible {
                    if code.is_err() || body.len() > 1024 * 1024 {
                        operation.stop(Err(Failure::Unavailable));
                    } else {
                        match serde_json::from_str::<Value>(&body) {
                            Ok(value) => {
                                if let Err(error) = operation.live() {
                                    operation.stop(Err(error));
                                } else {
                                    returned(operation.clone(), value);
                                }
                            }
                            Err(_) => operation.stop(Err(Failure::FillFailed)),
                        }
                    }
                }
                operation.finish_if_returned();
                Ok(())
            }));
        // Last reversible source/permit check. The final payload uses only the
        // system-unique old context; never a potentially recycled numeric ID.
        if let Err(error) = self.live() {
            // No SDK invocation began: retire precisely this local reservation.
            self.state.borrow_mut().custody.returned();
            self.stop(Err(error));
            return;
        }
        if unsafe {
            self.source
                .view
                .CallDevToolsProtocolMethod(&name, &payload, &handler)
        }
        .is_err()
        {
            // An uncertain SDK rejection is not a callback. Keep its pending
            // invocation accounted until a real callback arrives, if it does.
            self.stop(Err(Failure::Unavailable));
        }
    }
    fn frame_returned(operation: Rc<Self>, value: Value) {
        let Some(frame) = value["frameTree"]["frame"]["id"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 256)
            .map(str::to_owned)
        else {
            operation.stop(Err(Failure::Unavailable));
            return;
        };
        let Some(loader) = value["frameTree"]["frame"]["loaderId"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 128 && !id.chars().any(char::is_control))
            .map(str::to_owned)
        else {
            operation.stop(Err(Failure::Unavailable));
            return;
        };
        let world_name = format!("{}-{}", operation.source.world, loader);
        {
            let mut state = operation.state.borrow_mut();
            state.frame = Some(frame.clone());
            state.loader = Some(loader.clone());
            state.world_name = Some(world_name.clone());
        }
        let cached = operation
            .source
            .cache
            .borrow()
            .as_ref()
            .filter(|cache| {
                cache.epoch == operation.binding.navigation
                    && cache.frame == frame
                    && cache.loader == loader
            })
            .map(|cache| cache.unique.clone());
        if let Some(unique) = cached {
            operation.begin_probe(unique);
            return;
        }
        let world = match WorldBinding::new(frame.clone(), world_name) {
            Ok(world) => world,
            Err(error) => {
                operation.stop(Err(error));
                return;
            }
        };
        operation.state.borrow_mut().world = Some(world);
        if let Err(error) = operation.listen() {
            operation.stop(Err(error));
            return;
        }
        operation.call(Method::Enable, json!({}), Stage::Enable, Operation::enabled);
    }
    fn listen(self: &Rc<Self>) -> Result<(), Failure> {
        let receiver = unsafe {
            self.source
                .view
                .GetDevToolsProtocolEventReceiver(&HSTRING::from("Runtime.executionContextCreated"))
        }
        .map_err(|_| Failure::Unavailable)?;
        let owner = self.state.borrow_mut().custody.event_owner()?;
        let block = self.source.block();
        let weak = Rc::downgrade(self);
        let handler =
            DevToolsProtocolEventReceivedEventHandler::create(Box::new(move |_, args| {
                let _held = (&owner, &block);
                let Some(operation) = weak.upgrade() else {
                    return Ok(());
                };
                if operation.state.borrow().terminal.is_some() {
                    return Ok(());
                }
                let Some(args) = args else {
                    operation.stop(Err(Failure::Unavailable));
                    return Ok(());
                };
                let mut raw = PWSTR::null();
                let success = unsafe { args.ParameterObjectAsJson(&mut raw) }.is_ok();
                let body = unsafe { native_string(raw, 65536) };
                if !success {
                    operation.stop(Err(Failure::Unavailable));
                    return Ok(());
                }
                let value = body.and_then(|body| serde_json::from_str::<Value>(&body).ok());
                let Some(value) = value else {
                    operation.stop(Err(Failure::Unavailable));
                    return Ok(());
                };
                let proof = {
                    let mut state = operation.state.borrow_mut();
                    match &mut state.world {
                        Some(world) => world.observe(&value),
                        None => Err(Failure::Unavailable),
                    }
                };
                match proof {
                    Ok(Some(unique)) => operation.proof_ready(unique),
                    Ok(None) => {}
                    Err(error) => operation.stop(Err(error)),
                }
                Ok(())
            }));
        let mut token = 0;
        unsafe { receiver.add_DevToolsProtocolEventReceived(&handler, &mut token) }
            .map_err(|_| Failure::Unavailable)?;
        let mut registration = Some(Registration {
            receiver,
            token,
            _handler: handler,
        });
        {
            let mut state = self.state.borrow_mut();
            if state.terminal.is_none() {
                state.registration = registration.take();
            }
        }
        // A synchronous SDK event may have canceled this operation while add
        // was returning. Unregister outside the state borrow in that case.
        drop(registration);
        Ok(())
    }
    fn enabled(operation: Rc<Self>, _value: Value) {
        let frame = operation
            .state
            .borrow()
            .frame
            .clone()
            .expect("owned main frame");
        let world_name = operation
            .state
            .borrow()
            .world_name
            .clone()
            .expect("owned document world");
        operation.call(
            Method::Create,
            json!({"frameId":frame,"worldName":world_name,"grantUniveralAccess":false}),
            Stage::Create,
            Operation::created,
        );
    }
    fn created(operation: Rc<Self>, value: Value) {
        let Some(number) = value["executionContextId"].as_i64() else {
            operation.stop(Err(Failure::Unavailable));
            return;
        };
        let proof = {
            let mut state = operation.state.borrow_mut();
            state.stage = Stage::AwaitProof;
            match &mut state.world {
                Some(world) => world.created(number),
                None => Err(Failure::Unavailable),
            }
        };
        match proof {
            Ok(Some(unique)) => operation.proof_ready(unique),
            Ok(None) => {}
            Err(error) => operation.stop(Err(error)),
        }
    }
    fn proof_ready(self: &Rc<Self>, unique: UniqueContext) {
        if let Err(error) = self.live() {
            self.stop(Err(error));
            return;
        }
        let registration = {
            let mut state = self.state.borrow_mut();
            if !matches!(state.stage, Stage::Create | Stage::AwaitProof) || state.unique.is_some() {
                return;
            }
            state.unique = Some(unique.clone());
            state.registration.take()
        };
        drop(registration);
        if self.state.borrow().terminal.is_some() {
            return;
        }
        let frame = self.state.borrow().frame.clone().expect("owned frame");
        *self.source.cache.borrow_mut() = Some(Cached {
            epoch: self.binding.navigation,
            frame,
            loader: self.state.borrow().loader.clone().expect("owned loader"),
            unique: unique.clone(),
        });
        self.begin_probe(unique);
    }
    fn begin_probe(self: &Rc<Self>, unique: UniqueContext) {
        self.state.borrow_mut().unique = Some(unique.clone());
        let function = format!("function(ticket,expectedOrigin,hasOtp) {{\n{PROBE}\n}}");
        let has_otp = self
            .state
            .borrow()
            .attempt
            .as_ref()
            .is_some_and(Attempt::has_otp);
        self.call(Method::Probe,json!({"functionDeclaration":function,"uniqueContextId":unique.as_str(),"arguments":[{"value":self.ticket},{"value":self.binding.origin()},{"value":if has_otp {"yes"}else{"no"}}],"returnByValue":true,"silent":true,"awaitPromise":false}),Stage::Probe,Operation::probed);
    }
    fn probed(operation: Rc<Self>, value: Value) {
        if !boolean_reply(&value) {
            operation.stop(Err(Failure::FillFailed));
            return;
        }
        operation.call(
            Method::Frame,
            json!({}),
            Stage::BeforeMutation,
            Operation::commit,
        );
    }
    fn commit(operation: Rc<Self>, value: Value) {
        let matches = {
            let state = operation.state.borrow();
            value["frameTree"]["frame"]["id"].as_str() == state.frame.as_deref()
                && value["frameTree"]["frame"]["loaderId"].as_str() == state.loader.as_deref()
        };
        if !matches {
            operation.stop(Err(Failure::StalePage));
            return;
        }
        let Some(remaining) = operation.permit.remaining() else {
            operation.stop(Err(Failure::FillFailed));
            return;
        };
        let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH) else {
            operation.stop(Err(Failure::FillFailed));
            return;
        };
        let secrets = {
            operation
                .state
                .borrow_mut()
                .attempt
                .as_mut()
                .and_then(Attempt::take_for_dispatch)
        };
        let Some(secrets) = secrets else {
            operation.stop(Err(Failure::FillFailed));
            return;
        };
        let unique = operation
            .state
            .borrow()
            .unique
            .clone()
            .expect("proved unique context");
        let deadline = (now + remaining).as_millis().to_string();
        let parameters = windows_mutation_parameters(
            unique.as_str(),
            &operation.ticket,
            operation.binding.origin(),
            &deadline,
            &secrets,
        );
        match parameters {
            Ok(parameters) => operation.call(
                Method::Mutation,
                Parameters::Secret(parameters),
                Stage::Mutation,
                Operation::mutated,
            ),
            Err(error) => operation.stop(Err(error)),
        }
    }
    fn mutated(operation: Rc<Self>, value: Value) {
        operation.stop(if boolean_reply(&value) {
            Ok(())
        } else {
            Err(Failure::FillFailed)
        });
    }
}
fn boolean_reply(value: &Value) -> bool {
    value.get("exceptionDetails").is_none()
        && value["result"]["type"] == "boolean"
        && value["result"]["value"] == true
}
unsafe fn native_string(raw: PWSTR, limit: usize) -> Option<String> {
    let _owner = CoTaskMemPWSTR::from(raw);
    if raw.is_null() {
        return None;
    }
    for length in 0..=limit {
        if unsafe { *raw.0.add(length) } == 0 {
            return String::from_utf16(unsafe { std::slice::from_raw_parts(raw.0, length) }).ok();
        }
    }
    None
}
