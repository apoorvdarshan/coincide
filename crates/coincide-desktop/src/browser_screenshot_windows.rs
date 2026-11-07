//! Closed WebView2 page snapshot pipeline. No desktop capture, ExecuteScript,
//! public CDP endpoint, page-world evaluation or numeric-context fallback.
//!
//! Page.captureScreenshot receives one fixed bounded viewport clip. Native
//! controller geometry/scale and unique frame/loader are bound before/after.
//! The SDK's internal allocations are not under a process-wide hard quota; the
//! requested rectangle, returned PNG and our decoder/encoder are bounded.
use super::{Callbacks, Completion, Data, Handle, Pixels};
#[path = "browser_credential_context.rs"]
mod context;
use coincide_core::browser_screenshot::{Geometry, MAX_NATIVE_PIXELS, Rect, mask};
use context::{Custody, UniqueContext, WorldBinding};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::ThreadId,
};
use webview2_com::{
    CallDevToolsProtocolMethodCompletedHandler, CoTaskMemPWSTR,
    DevToolsProtocolEventReceivedEventHandler, Microsoft::Web::WebView2::Win32::*,
};
use windows::{
    Win32::Foundation::RECT,
    core::{HSTRING, Interface, PWSTR},
};
use wry::WebViewExtWindows;
const MAX_METADATA: usize = 512 * 1024;
use super::windows_plan::{MAX_CAPTURE_REPLY, png_reply, viewport};
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Layout {
    width: f64,
    height: f64,
    masks: Vec<Rect>,
    x: f64,
    y: f64,
}
struct Source {
    view: ICoreWebView2,
    controller: ICoreWebView2Controller,
    scaled: ICoreWebView2Controller3,
    bounds: RECT,
    raster: f64,
    zoom: f64,
    navigation: Arc<AtomicU64>,
    epoch: u64,
    url: String,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    callbacks: Callbacks,
    owner: ThreadId,
    // Native interface references above are released before their counted lease.
    _target: super::super::shutdown::NativeLease,
}
impl Source {
    fn valid(&self) -> bool {
        if self.owner != std::thread::current().id()
            || self.callbacks.closed()
            || self.cancelled.load(Ordering::Acquire)
            || self.protected.load(Ordering::Acquire)
            || self.navigation.load(Ordering::Acquire) != self.epoch
        {
            return false;
        }
        let mut raw = PWSTR::null();
        let result = unsafe { self.view.Source(&mut raw) };
        let url = unsafe { native_string(raw, 16384) };
        let mut bounds = RECT::default();
        let mut raster = 0.;
        let mut zoom = 0.;
        result.is_ok()
            && url.as_deref() == Some(self.url.as_str())
            && unsafe { self.controller.Bounds(&mut bounds) }.is_ok()
            && bounds == self.bounds
            && unsafe { self.scaled.RasterizationScale(&mut raster) }.is_ok()
            && raster == self.raster
            && unsafe { self.controller.ZoomFactor(&mut zoom) }.is_ok()
            && zoom == self.zoom
            && self.navigation.load(Ordering::Acquire) == self.epoch
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    Frame,
    Enable,
    Create,
    AwaitProof,
    Prepare,
    Snapshot,
    Verify,
    Restore,
    Terminal,
}
#[derive(Clone, Copy)]
enum Method {
    Frame,
    Enable,
    Create,
    Prepare,
    Snapshot,
    Restore,
}
impl Method {
    fn name(self) -> &'static str {
        match self {
            Self::Frame => "Page.getFrameTree",
            Self::Enable => "Runtime.enable",
            Self::Create => "Page.createIsolatedWorld",
            Self::Prepare | Self::Restore => "Runtime.callFunctionOn",
            Self::Snapshot => "Page.captureScreenshot",
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
    stage: Stage,
    nonce: uuid::Uuid,
    custody: Custody,
    pending: bool,
    registration: Option<Registration>,
    world: Option<WorldBinding>,
    unique: Option<UniqueContext>,
    frame: Option<String>,
    loader: Option<String>,
    world_name: String,
    mask_started: bool,
    geometry: Option<Geometry>,
    png: Option<Vec<u8>>,
    terminal: Option<&'static str>,
    done: bool,
    completion: Option<Completion>,
}
struct Operation {
    source: Source,
    ticket: String,
    full_page: bool,
    state: RefCell<State>,
}
impl Operation {
    fn poll(self: &Rc<Self>) {
        if !self.source.valid() {
            self.stop("Snapshot source changed or was cancelled");
        }
        self.finish_if_returned();
    }
    fn stop(self: &Rc<Self>, error: &'static str) {
        let (pending, restore, registration) = {
            let mut s = self.state.borrow_mut();
            if s.done {
                return;
            }
            if s.terminal.is_none() {
                s.terminal = Some(error);
            }
            let registration = s.registration.take();
            (
                s.pending,
                s.mask_started && s.unique.is_some() && s.stage != Stage::Restore,
                registration,
            )
        };
        drop(registration);
        if !pending {
            if restore {
                self.restore();
            } else {
                self.state.borrow_mut().stage = Stage::Terminal;
                self.finish_if_returned();
            }
        }
    }
    fn finish_if_returned(&self) {
        let result = {
            let mut s = self.state.borrow_mut();
            if s.done || s.stage != Stage::Terminal || !s.custody.returned_all() {
                None
            } else {
                s.done = true;
                let result = if let Some(error) = s.terminal {
                    Err(error)
                } else if self.source.valid() {
                    match (s.png.take(), s.geometry.take()) {
                        (Some(png), Some(geometry)) => Ok(Pixels {
                            data: Data::Png(png),
                            geometry,
                        }),
                        _ => Err("Native snapshot produced no bounded image"),
                    }
                } else {
                    Err("Snapshot source changed or was cancelled")
                };
                s.completion.take().map(|done| (done, result))
            }
        };
        if let Some((done, result)) = result {
            done(result);
        }
    }
    fn call(
        self: &Rc<Self>,
        method: Method,
        parameters: Value,
        stage: Stage,
        returned: fn(Rc<Self>, Value),
    ) {
        // Restore is the only call allowed after revocation. Its fixed source is
        // bound to the old system-unique isolated world + opaque mask ticket;
        // it cannot capture, fill or mutate a new/recycled document.
        if !matches!(method, Method::Restore) && !self.source.valid() {
            self.stop("Snapshot source changed or was cancelled");
            return;
        }
        let payload = match serde_json::to_string(&parameters) {
            Ok(value) => HSTRING::from(value),
            Err(_) => {
                self.stop("Snapshot parameters are unavailable");
                return;
            }
        };
        let nonce = {
            let mut s = self.state.borrow_mut();
            if s.done {
                return;
            }
            s.stage = stage;
            s.pending = true;
            s.nonce = uuid::Uuid::new_v4();
            s.custody.began();
            s.nonce
        };
        let operation = self.clone();
        let ack = self.source.callbacks.begin();
        let lease = self.source.callbacks.lifetimes().block();
        let once = Cell::new(false);
        let handler =
            CallDevToolsProtocolMethodCompletedHandler::create(Box::new(move |code, body| {
                let _held = &lease;
                if once.replace(true) {
                    return Ok(());
                }
                ack.ack();
                let eligible = {
                    let mut s = operation.state.borrow_mut();
                    s.custody.returned();
                    s.pending = false;
                    s.stage == stage && s.nonce == nonce
                };
                if eligible {
                    let limit = if matches!(method, Method::Snapshot) {
                        MAX_CAPTURE_REPLY
                    } else {
                        MAX_METADATA
                    };
                    if code.is_err() || body.len() > limit {
                        operation.stop("Native snapshot SDK request failed");
                    } else if let Ok(value) = serde_json::from_str::<Value>(&body) {
                        returned(operation.clone(), value);
                    } else {
                        operation.stop("Native snapshot SDK response was invalid");
                    }
                }
                operation.finish_if_returned();
                Ok(())
            }));
        // An uncertain synchronous SDK rejection is not a callback receipt.
        // Retain the reservation until its actual callback, if any, returns.
        if unsafe {
            self.source.view.CallDevToolsProtocolMethod(
                &HSTRING::from(method.name()),
                &payload,
                &handler,
            )
        }
        .is_err()
        {
            self.stop("Native snapshot SDK dispatch is unconfirmed");
        }
    }
    fn frame_returned(operation: Rc<Self>, value: Value) {
        let frame = value["frameTree"]["frame"]["id"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
            .map(str::to_owned);
        let loader = value["frameTree"]["frame"]["loaderId"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 128 && !s.chars().any(char::is_control))
            .map(str::to_owned);
        let (Some(frame), Some(loader)) = (frame, loader) else {
            operation.stop("Snapshot frame identity unavailable");
            return;
        };
        let name = operation.state.borrow().world_name.clone();
        let world = match WorldBinding::new(frame.clone(), name) {
            Ok(world) => world,
            Err(_) => {
                operation.stop("Snapshot isolated world unavailable");
                return;
            }
        };
        {
            let mut s = operation.state.borrow_mut();
            s.frame = Some(frame);
            s.loader = Some(loader);
            s.world = Some(world);
        }
        if !operation.source.valid() {
            operation.stop("Snapshot source changed");
            return;
        }
        if !operation.listen() {
            operation.stop("Snapshot context events unavailable");
            return;
        }
        operation.call(Method::Enable, json!({}), Stage::Enable, Operation::enabled);
    }
    fn listen(self: &Rc<Self>) -> bool {
        let receiver = match unsafe {
            self.source
                .view
                .GetDevToolsProtocolEventReceiver(&HSTRING::from("Runtime.executionContextCreated"))
        } {
            Ok(receiver) => receiver,
            Err(_) => return false,
        };
        let owner = match self.state.borrow_mut().custody.event_owner() {
            Ok(owner) => owner,
            Err(_) => return false,
        };
        let weak = Rc::downgrade(self);
        let lease = self.source.callbacks.lifetimes().block();
        let handler =
            DevToolsProtocolEventReceivedEventHandler::create(Box::new(move |_, args| {
                let _held = (&owner, &lease);
                let Some(operation) = weak.upgrade() else {
                    return Ok(());
                };
                if operation.state.borrow().terminal.is_some() {
                    return Ok(());
                }
                let Some(args) = args else {
                    operation.stop("Snapshot context event unavailable");
                    return Ok(());
                };
                let mut raw = PWSTR::null();
                let success = unsafe { args.ParameterObjectAsJson(&mut raw) }.is_ok();
                let value = unsafe { native_string(raw, 65536) }
                    .and_then(|v| serde_json::from_str::<Value>(&v).ok());
                if !success || value.is_none() {
                    operation.stop("Snapshot context event invalid");
                    return Ok(());
                }
                let proof = {
                    let mut s = operation.state.borrow_mut();
                    s.world.as_mut().map(|world| world.observe(&value.unwrap()))
                };
                match proof {
                    Some(Ok(Some(unique))) => operation.proof_ready(unique),
                    Some(Ok(None)) => {}
                    _ => operation.stop("Snapshot context identity changed"),
                };
                Ok(())
            }));
        let mut token = 0;
        if unsafe { receiver.add_DevToolsProtocolEventReceived(&handler, &mut token) }.is_err() {
            return false;
        }
        let mut registration = Some(Registration {
            receiver,
            token,
            _handler: handler,
        });
        {
            let mut s = self.state.borrow_mut();
            if s.terminal.is_none() {
                s.registration = registration.take();
            }
        }
        drop(registration);
        true
    }
    fn enabled(operation: Rc<Self>, _: Value) {
        let (frame, name) = {
            let s = operation.state.borrow();
            (s.frame.clone().unwrap(), s.world_name.clone())
        };
        operation.call(
            Method::Create,
            json!({"frameId":frame,"worldName":name,"grantUniveralAccess":false}),
            Stage::Create,
            Operation::created,
        );
    }
    fn created(operation: Rc<Self>, value: Value) {
        let Some(number) = value["executionContextId"].as_i64() else {
            operation.stop("Snapshot context proof unavailable");
            return;
        };
        let proof = {
            let mut s = operation.state.borrow_mut();
            s.stage = Stage::AwaitProof;
            s.world.as_mut().map(|world| world.created(number))
        };
        match proof {
            Some(Ok(Some(unique))) => operation.proof_ready(unique),
            Some(Ok(None)) => {}
            _ => operation.stop("Snapshot context proof changed"),
        };
    }
    fn proof_ready(self: &Rc<Self>, unique: UniqueContext) {
        let registration = {
            let mut s = self.state.borrow_mut();
            if !matches!(s.stage, Stage::Create | Stage::AwaitProof) || s.unique.is_some() {
                return;
            }
            s.unique = Some(unique);
            s.registration.take()
        };
        drop(registration);
        if !self.source.valid() || self.state.borrow().terminal.is_some() {
            self.stop("Snapshot source changed");
            return;
        }
        let function = format!(
            "async function(ticket,expectedURL,fullPage) {{const result=await(async()=>{{\n{}\n}})();if(!result)return '';const data=JSON.parse(result),state=globalThis.__coincidePrivateSnapshotV1;data.x=state.sx;data.y=state.sy;return JSON.stringify(data);}}",
            mask::PREPARE
        );
        self.state.borrow_mut().mask_started = true;
        let unique = self.state.borrow().unique.clone().unwrap();
        self.call(Method::Prepare,json!({"functionDeclaration":function,"uniqueContextId":unique.as_str(),"arguments":[{"value":self.ticket},{"value":self.source.url},{"value":if self.full_page{"yes"}else{"no"}}],"returnByValue":true,"silent":true,"awaitPromise":true}),Stage::Prepare,Operation::prepared);
    }
    fn prepared(operation: Rc<Self>, value: Value) {
        let layout = value["result"]["value"]
            .as_str()
            .filter(|v| v.len() <= 256 * 1024)
            .and_then(|s| serde_json::from_str::<Layout>(s).ok());
        let Some(layout) = layout else {
            operation.stop("Snapshot mask preparation failed");
            return;
        };
        if value.get("exceptionDetails").is_some()
            || !layout.x.is_finite()
            || !layout.y.is_finite()
            || layout.x.abs() > 1_000_000.
            || layout.y.abs() > 1_000_000.
        {
            operation.stop("Snapshot layout is invalid");
            return;
        }
        let geometry = match Geometry::checked(layout.width, layout.height, layout.masks) {
            Ok(geometry) => geometry,
            Err(_) => {
                operation.stop("Snapshot layout exceeds bounds");
                return;
            }
        };
        // Use the native controller's bound raster/zoom, never a caller JSON
        // scale or a page-provided devicePixelRatio. A subsequent native scale
        // or geometry change revokes/discards this snapshot.
        let Some(parameters) = viewport(
            layout.width,
            layout.height,
            layout.x,
            layout.y,
            operation.source.raster,
            operation.source.zoom,
        ) else {
            operation.stop("Snapshot scale exceeds bounds");
            return;
        };
        operation.state.borrow_mut().geometry = Some(geometry);
        operation.call(
            Method::Snapshot,
            parameters,
            Stage::Snapshot,
            Operation::captured,
        );
    }
    fn captured(operation: Rc<Self>, value: Value) {
        let data = png_reply(&value);
        if data.is_none() {
            operation.stop("Native snapshot PNG exceeds bounds or is invalid");
            return;
        }
        operation.state.borrow_mut().png = data;
        operation.call(Method::Frame, json!({}), Stage::Verify, Operation::verified);
    }
    fn verified(operation: Rc<Self>, value: Value) {
        let valid = {
            let s = operation.state.borrow();
            value["frameTree"]["frame"]["id"].as_str() == s.frame.as_deref()
                && value["frameTree"]["frame"]["loaderId"].as_str() == s.loader.as_deref()
        };
        if !valid || !operation.source.valid() {
            operation.stop("Snapshot frame changed");
            return;
        }
        operation.restore();
    }
    fn restore(self: &Rc<Self>) {
        let unique = self.state.borrow().unique.clone();
        let Some(unique) = unique else {
            self.state.borrow_mut().stage = Stage::Terminal;
            self.finish_if_returned();
            return;
        };
        let function = format!(
            "function(ticket,expectedURL,fullPage) {{\n{}\n}}",
            mask::FINISH
        );
        self.call(Method::Restore,json!({"functionDeclaration":function,"uniqueContextId":unique.as_str(),"arguments":[{"value":self.ticket},{"value":self.source.url},{"value":"no"}],"returnByValue":true,"silent":true,"awaitPromise":false}),Stage::Restore,Operation::restored);
    }
    fn restored(operation: Rc<Self>, value: Value) {
        let valid = value.get("exceptionDetails").is_none()
            && value["result"]["type"] == "boolean"
            && value["result"]["value"] == true;
        {
            let mut s = operation.state.borrow_mut();
            s.mask_started = false;
            s.stage = Stage::Terminal;
            if !valid && s.terminal.is_none() {
                s.terminal = Some("Snapshot document mask changed");
            }
        }
        operation.finish_if_returned();
    }
}
pub(super) fn capture(
    view: &wry::WebView,
    navigation: Arc<AtomicU64>,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    callbacks: Callbacks,
    full_page: bool,
    completion: Completion,
) -> Handle {
    let controller = view.controller();
    let scaled = match controller.cast::<ICoreWebView2Controller3>() {
        Ok(scaled) => scaled,
        Err(_) => {
            completion(Err(
                "Native snapshot requires WebView2 raster-scale metadata",
            ));
            return Handle::default();
        }
    };
    let native = view.webview();
    let mut raw = PWSTR::null();
    let source = unsafe { native.Source(&mut raw) };
    let url = unsafe { native_string(raw, 16384) };
    let mut bounds = RECT::default();
    let mut raster = 0f64;
    let mut zoom = 0f64;
    if source.is_err()
        || url.is_none()
        || unsafe { controller.Bounds(&mut bounds) }.is_err()
        || unsafe { scaled.RasterizationScale(&mut raster) }.is_err()
        || unsafe { controller.ZoomFactor(&mut zoom) }.is_err()
    {
        completion(Err("Native snapshot source unavailable"));
        return Handle::default();
    }
    let width = i64::from(bounds.right) - i64::from(bounds.left);
    let height = i64::from(bounds.bottom) - i64::from(bounds.top);
    if width <= 0
        || height <= 0
        || width > 20000
        || height > 20000
        || width as u64 * height as u64 > MAX_NATIVE_PIXELS
        || !raster.is_finite()
        || !zoom.is_finite()
        || !(0.25..=4.).contains(&raster)
        || !(0.25..=5.).contains(&zoom)
    {
        completion(Err("Native snapshot viewport allocation exceeds bounds"));
        return Handle::default();
    }
    let epoch = navigation.load(Ordering::Acquire);
    let operation = Rc::new(Operation {
        source: Source {
            view: native,
            controller,
            scaled,
            bounds,
            raster,
            zoom,
            navigation,
            epoch,
            url: url.unwrap(),
            protected,
            cancelled,
            owner: std::thread::current().id(),
            _target: callbacks.lifetimes().target(),
            callbacks,
        },
        ticket: uuid::Uuid::new_v4().to_string(),
        full_page,
        state: RefCell::new(State {
            stage: Stage::Frame,
            nonce: uuid::Uuid::new_v4(),
            custody: Custody::new(),
            pending: false,
            registration: None,
            world: None,
            unique: None,
            frame: None,
            loader: None,
            world_name: format!("CoincidePrivateSnapshotV1-{}", uuid::Uuid::new_v4()),
            mask_started: false,
            geometry: None,
            png: None,
            terminal: None,
            done: false,
            completion: Some(completion),
        }),
    });
    operation.call(
        Method::Frame,
        json!({}),
        Stage::Frame,
        Operation::frame_returned,
    );
    Handle {
        poll: Some(Box::new(move || operation.poll())),
    }
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
