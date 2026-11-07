//! WebView2 snapshot through the host's own DevTools protocol session. A
//! private isolated world, proved by its system-unique context ID rather than
//! a reusable numeric ID, runs the fixed mask transaction. Page.captureScreenshot
//! renders the bounded clip at the output scale, so the native result is no
//! larger than the encoded image. No ExecuteScript, page-world script,
//! arbitrary DevTools method, view resize or screen capture.
#[allow(dead_code)] // Shares only the proved-world binding with credential fill.
#[path = "browser_credential_context.rs"]
mod context;
use super::super::shutdown::NativeLease;
use super::{Callbacks, Completion, Data, Pixels};
use base64::Engine as _;
use coincide_core::browser_screenshot::{self, Geometry, MAX_PNG_BYTES, Metrics, Rect, mask};
use context::{UniqueContext, WorldBinding};
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use webview2_com::{
    CallDevToolsProtocolMethodCompletedHandler, CoTaskMemPWSTR,
    DevToolsProtocolEventReceivedEventHandler, Microsoft::Web::WebView2::Win32::*,
};
use windows::core::{HSTRING, PWSTR};
use wry::WebViewExtWindows;
const MAX_REPLY: usize = 1024 * 1024;
// Base64 PNG plus its JSON envelope.
const MAX_IMAGE_REPLY: usize = MAX_PNG_BYTES / 3 * 4 + 64 * 1024;
struct Source {
    view: ICoreWebView2,
    navigation: Arc<AtomicU64>,
    epoch: u64,
    url: String,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    callbacks: Callbacks,
    _target: NativeLease,
}
impl Source {
    fn valid(&self) -> bool {
        !self.callbacks.closed()
            && !self.cancelled.load(Ordering::Acquire)
            && !self.protected.load(Ordering::Acquire)
            && self.navigation.load(Ordering::Acquire) == self.epoch
            && current_url(&self.view).as_deref() == Some(self.url.as_str())
            && self.navigation.load(Ordering::Acquire) == self.epoch
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    Frame,
    Enable,
    Create,
    Prepare,
    Capture,
    Finish,
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
    calls: usize,
    registration: Option<Registration>,
    world: Option<WorldBinding>,
    frame: Option<String>,
    unique: Option<UniqueContext>,
    // PREPARE returned a transaction that FINISH must restore.
    prepared: bool,
    finishing: bool,
    stopped: bool,
    planned: Option<(Geometry, bool)>,
    pixels: Option<Pixels>,
    failure: Option<&'static str>,
    completion: Option<Completion>,
}
struct Operation {
    source: Source,
    ticket: String,
    world: String,
    full_page: bool,
    state: RefCell<State>,
}
pub(in super::super) fn capture(
    view: &wry::WebView,
    navigation: Arc<AtomicU64>,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    callbacks: Callbacks,
    full_page: bool,
    completion: Completion,
) {
    let view = view.webview();
    let Some(url) = current_url(&view) else {
        completion(Err("Native snapshot has no document"));
        return;
    };
    let source = Source {
        view,
        epoch: navigation.load(Ordering::Acquire),
        navigation,
        url,
        protected,
        cancelled,
        _target: callbacks.lifetimes().target(),
        callbacks,
    };
    if !source.valid() {
        completion(Err("Snapshot document is stale"));
        return;
    }
    let operation = Rc::new(Operation {
        source,
        ticket: uuid::Uuid::new_v4().to_string(),
        world: format!("CoincidePrivateSnapshotV1-{}", uuid::Uuid::new_v4()),
        full_page,
        state: RefCell::new(State {
            stage: Stage::Frame,
            nonce: uuid::Uuid::new_v4(),
            calls: 0,
            registration: None,
            world: None,
            frame: None,
            unique: None,
            prepared: false,
            finishing: false,
            stopped: false,
            planned: None,
            pixels: None,
            failure: None,
            completion: Some(completion),
        }),
    });
    operation.call(
        "Page.getFrameTree",
        json!({}),
        Stage::Frame,
        Operation::frame_returned,
    );
}
impl Operation {
    /// Ends the capture. A prepared page transaction still gets FINISH, and
    /// the caller hears back only once every DevTools call has returned.
    fn stop(self: &Rc<Self>, error: &'static str) {
        let (registration, finish) = {
            let mut state = self.state.borrow_mut();
            if state.failure.is_none() {
                state.failure = Some(error);
            }
            state.stopped = true;
            (
                state.registration.take(),
                state.prepared && !state.finishing,
            )
        };
        drop(registration);
        if finish {
            self.finish();
        } else {
            self.complete(false);
        }
    }
    fn complete(&self, finished: bool) {
        let (completion, result) = {
            let mut state = self.state.borrow_mut();
            if state.calls != 0 || state.registration.is_some() {
                return;
            }
            let Some(completion) = state.completion.take() else {
                return;
            };
            let result = match (state.failure, state.pixels.take()) {
                (Some(error), _) => Err(error),
                (None, Some(pixels)) if finished && self.source.valid() => Ok(pixels),
                (None, Some(_)) => Err("Snapshot document changed or was cancelled"),
                (None, None) => Err("Native snapshot did not complete"),
            };
            (completion, result)
        };
        completion(result);
    }
    fn call(
        self: &Rc<Self>,
        method: &'static str,
        parameters: Value,
        stage: Stage,
        returned: fn(Rc<Self>, Value),
    ) {
        if stage != Stage::Finish && (self.state.borrow().stopped || !self.source.valid()) {
            self.stop("Snapshot source changed");
            return;
        }
        let Ok(payload) = serde_json::to_string(&parameters) else {
            self.stop("Native snapshot failed");
            return;
        };
        let nonce = {
            let mut state = self.state.borrow_mut();
            state.stage = stage;
            state.nonce = uuid::Uuid::new_v4();
            state.calls += 1;
            state.nonce
        };
        let limit = if stage == Stage::Capture {
            MAX_IMAGE_REPLY
        } else {
            MAX_REPLY
        };
        let retired = Rc::new(std::cell::Cell::new(false));
        let operation = self.clone();
        let ack = self.source.callbacks.begin();
        let returned_ack = ack.clone();
        let returned_retired = retired.clone();
        let block = self.source.callbacks.lifetimes().block();
        let handler =
            CallDevToolsProtocolMethodCompletedHandler::create(Box::new(move |code, body| {
                let _held = &block;
                returned_ack.ack();
                if returned_retired.replace(true) {
                    return Ok(());
                }
                let eligible = {
                    let mut state = operation.state.borrow_mut();
                    state.calls -= 1;
                    state.stage == stage
                        && state.nonce == nonce
                        && (!state.stopped || stage == Stage::Finish)
                };
                if eligible {
                    let value = (code.is_ok() && body.len() <= limit)
                        .then(|| serde_json::from_str::<Value>(&body).ok())
                        .flatten();
                    match value {
                        Some(value) => returned(operation.clone(), value),
                        None if stage == Stage::Finish => operation.complete(false),
                        None => operation.stop("Native snapshot failed"),
                    }
                } else {
                    operation.complete(false);
                }
                Ok(())
            }));
        let name = HSTRING::from(method);
        let payload = HSTRING::from(payload.as_str());
        if unsafe {
            self.source
                .view
                .CallDevToolsProtocolMethod(&name, &payload, &handler)
        }
        .is_err()
        {
            // A failed COM call never invokes its handler: retire exactly this
            // reservation. A late invocation would find it already retired.
            if !retired.replace(true) {
                ack.ack();
                self.state.borrow_mut().calls -= 1;
            }
            self.state.borrow_mut().prepared &= stage != Stage::Finish;
            self.stop("Native snapshot is unavailable");
        }
    }
    fn frame_returned(operation: Rc<Self>, value: Value) {
        let frame = value["frameTree"]["frame"]["id"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 256)
            .map(str::to_owned);
        let Some(frame) = frame else {
            operation.stop("Native snapshot is unavailable");
            return;
        };
        let Ok(world) = WorldBinding::new(frame.clone(), operation.world.clone()) else {
            operation.stop("Native snapshot is unavailable");
            return;
        };
        {
            let mut state = operation.state.borrow_mut();
            state.frame = Some(frame);
            state.world = Some(world);
        }
        if operation.listen().is_err() {
            operation.stop("Native snapshot is unavailable");
            return;
        }
        operation.call(
            "Runtime.enable",
            json!({}),
            Stage::Enable,
            Operation::enabled,
        );
    }
    fn listen(self: &Rc<Self>) -> Result<(), ()> {
        let receiver = unsafe {
            self.source
                .view
                .GetDevToolsProtocolEventReceiver(&HSTRING::from("Runtime.executionContextCreated"))
        }
        .map_err(|_| ())?;
        let block = self.source.callbacks.lifetimes().block();
        let weak = Rc::downgrade(self);
        let handler =
            DevToolsProtocolEventReceivedEventHandler::create(Box::new(move |_, args| {
                let _held = &block;
                let Some(operation) = weak.upgrade() else {
                    return Ok(());
                };
                if operation.state.borrow().registration.is_none() {
                    return Ok(());
                }
                let mut raw = PWSTR::null();
                let body = args.and_then(|args| {
                    unsafe { args.ParameterObjectAsJson(&mut raw) }.ok()?;
                    unsafe { native_string(raw, 65536) }
                });
                let value = body.and_then(|body| serde_json::from_str::<Value>(&body).ok());
                let proof = {
                    let mut state = operation.state.borrow_mut();
                    match (&mut state.world, value) {
                        (Some(world), Some(value)) => world.observe(&value).map_err(|_| ()),
                        _ => Err(()),
                    }
                };
                match proof {
                    Ok(Some(unique)) => operation.proved(unique),
                    Ok(None) => {}
                    Err(()) => operation.stop("Native snapshot is unavailable"),
                }
                Ok(())
            }));
        let mut token = 0;
        unsafe { receiver.add_DevToolsProtocolEventReceived(&handler, &mut token) }
            .map_err(|_| ())?;
        self.state.borrow_mut().registration = Some(Registration {
            receiver,
            token,
            _handler: handler,
        });
        Ok(())
    }
    fn enabled(operation: Rc<Self>, _value: Value) {
        let frame = operation.state.borrow().frame.clone().expect("owned frame");
        operation.call(
            "Page.createIsolatedWorld",
            json!({"frameId":frame,"worldName":operation.world,"grantUniveralAccess":false}),
            Stage::Create,
            Operation::created,
        );
    }
    fn created(operation: Rc<Self>, value: Value) {
        let proof = {
            let mut state = operation.state.borrow_mut();
            match (&mut state.world, value["executionContextId"].as_i64()) {
                (Some(world), Some(number)) => world.created(number).map_err(|_| ()),
                _ => Err(()),
            }
        };
        match proof {
            Ok(Some(unique)) => operation.proved(unique),
            // The executionContextCreated event supplies the unique proof.
            Ok(None) => operation.complete(false),
            Err(()) => operation.stop("Native snapshot is unavailable"),
        }
    }
    /// Both the createIsolatedWorld reply and its creation event must agree.
    /// PREPARE starts once that proof exists and no other call is in flight.
    fn proved(self: &Rc<Self>, unique: UniqueContext) {
        let (registration, ready) = {
            let mut state = self.state.borrow_mut();
            if state.stopped || state.stage != Stage::Create {
                return;
            }
            state.unique = Some(unique);
            (state.registration.take(), state.calls == 0)
        };
        drop(registration);
        if ready {
            self.prepare();
        }
    }
    fn prepare(self: &Rc<Self>) {
        let unique = self.state.borrow().unique.clone().expect("proved world");
        let function = format!(
            "function(ticket,expectedURL,mode) {{\n{}\n}}",
            mask::PREPARE
        );
        self.call("Runtime.callFunctionOn",json!({"functionDeclaration":function,"uniqueContextId":unique.as_str(),"arguments":[{"value":self.ticket},{"value":self.source.url},{"value":"mask"}],"returnByValue":true,"silent":true,"awaitPromise":false}),Stage::Prepare,Operation::prepared);
    }
    fn prepared(operation: Rc<Self>, value: Value) {
        let text = (value.get("exceptionDetails").is_none() && value["result"]["type"] == "string")
            .then(|| value["result"]["value"].as_str())
            .flatten()
            .unwrap_or_default();
        operation.state.borrow_mut().prepared = !text.is_empty();
        let plan = browser_screenshot::parse_metrics(text)
            .map_err(|_| "Snapshot mask preparation failed")
            .and_then(|metrics| plan(metrics, operation.full_page));
        match plan {
            Ok((geometry, truncated, clip)) => {
                operation.state.borrow_mut().planned = Some((geometry, truncated));
                operation.call(
                    "Page.captureScreenshot",
                    json!({"format":"png","clip":clip,"captureBeyondViewport":operation.full_page,"fromSurface":true}),
                    Stage::Capture,
                    Operation::captured,
                );
            }
            Err(error) => operation.stop(error),
        }
    }
    fn captured(operation: Rc<Self>, value: Value) {
        let png = value["data"]
            .as_str()
            .filter(|data| data.len() <= MAX_PNG_BYTES / 3 * 4 + 4)
            .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok());
        let planned = operation.state.borrow_mut().planned.take();
        match (planned, png) {
            (Some((geometry, truncated)), Some(png)) => {
                operation.state.borrow_mut().pixels = Some(Pixels {
                    data: Data::Png(png),
                    geometry,
                    truncated,
                });
                operation.finish();
            }
            _ => operation.stop("Native snapshot failed"),
        }
    }
    fn finish(self: &Rc<Self>) {
        let unique = {
            let mut state = self.state.borrow_mut();
            state.finishing = true;
            state.unique.clone()
        };
        let Some(unique) = unique else {
            self.complete(false);
            return;
        };
        let function = format!(
            "function(ticket,expectedURL,restoreX,restoreY,restoreHeight) {{\n{}\n}}",
            mask::FINISH
        );
        self.call("Runtime.callFunctionOn",json!({"functionDeclaration":function,"uniqueContextId":unique.as_str(),"arguments":[{"value":self.ticket},{"value":self.source.url},{"value":""},{"value":""},{"value":""}],"returnByValue":true,"silent":true,"awaitPromise":false}),Stage::Finish,Operation::finished);
    }
    fn finished(operation: Rc<Self>, value: Value) {
        let valid = value.get("exceptionDetails").is_none()
            && value["result"]["type"] == "boolean"
            && value["result"]["value"] == true;
        {
            let mut state = operation.state.borrow_mut();
            state.prepared = false;
            if !valid && state.failure.is_none() {
                let reason = (value["result"]["type"] == "string")
                    .then(|| value["result"]["value"].as_str())
                    .flatten();
                state.failure = Some(mask::finish_failure(reason.unwrap_or_default()));
            }
        }
        operation.complete(valid);
    }
}
/// The clip is in document CSS pixels at the scroll position PREPARE saw; the
/// output scale keeps the image at most 1600 pixels wide and within budget.
fn plan(metrics: Metrics, full_page: bool) -> Result<(Geometry, bool, Value), &'static str> {
    let width = metrics.client_width;
    let (height, truncated, x, y, masks) = if full_page {
        let (height, truncated) =
            browser_screenshot::full_page_height(metrics.client_height, metrics.document_height);
        let masks = metrics
            .masks
            .iter()
            .map(|mask| mask.translated(metrics.scroll_x, metrics.scroll_y))
            .collect::<Vec<Rect>>();
        (height, truncated, 0., 0., masks)
    } else {
        (
            metrics.client_height,
            false,
            metrics.scroll_x,
            metrics.scroll_y,
            metrics.masks,
        )
    };
    // Chromium composites the clip into one GPU texture; stay under 16,384.
    let scale = browser_screenshot::output_scale(width, height, metrics.device_pixel_ratio)
        .map_err(|_| "Native snapshot exceeds its allocation budget")?
        .min(16_000. / height)
        .min(16_000. / width);
    let geometry =
        Geometry::checked(width, height, masks).map_err(|_| "Snapshot geometry exceeds bounds")?;
    let clip = json!({"x":x,"y":y,"width":width,"height":height,"scale":scale / metrics.device_pixel_ratio});
    Ok((geometry, truncated, clip))
}
fn current_url(view: &ICoreWebView2) -> Option<String> {
    let mut raw = PWSTR::null();
    let result = unsafe { view.Source(&mut raw) };
    let url = unsafe { native_string(raw, 16384) };
    result.ok().and(url)
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
