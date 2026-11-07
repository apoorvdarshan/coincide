//! WebKit side of passkeys (macOS 11+), the Swift app's `PasskeyRequestHandler`
//! and `BitwardenPasskeyHandler`: the two page scripts at document start in the
//! page's own world (the only place pages' calls can be seen and answered), a
//! report-only handler for the detection script, and a replying handler for the
//! sign-in script. The origin is WebKit's `WKFrameInfo` for the message, never the
//! page's word: only main frames are answered, and only when the frame's document
//! address agrees with its security origin.
use super::{Channel, Incoming, PageReply};
use block2::{Block, RcBlock};
use coincide_core::passkeys::{
    DETECTION_HANDLER, DETECTION_SCRIPT, SIGN_IN_HANDLER, SIGN_IN_SCRIPT, UserVerification,
    WebAuthnOrigin, WebAuthnReply, page_host,
};
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send,
    rc::Retained,
    runtime::{AnyClass, AnyObject, Bool, NSObject, NSObjectProtocol, ProtocolObject},
};
use objc2_foundation::{NSArray, NSDictionary, NSError, NSNumber, NSString};
use objc2_web_kit::{
    WKContentWorld, WKFrameInfo, WKScriptMessage, WKScriptMessageHandler,
    WKScriptMessageHandlerWithReply, WKUserContentController, WKUserScript,
    WKUserScriptInjectionTime, WKWebViewConfiguration,
};
use serde_json::{Map, Value};
use std::{
    ffi::c_void,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

/// Apple's managed browser passkey entitlement. Apps signed with it reach the
/// system's passkey sheet for any site, so, as in the Swift app, none of this is
/// installed then; this developer account can't get it.
const ENTITLEMENT: &str = "com.apple.developer.web-browser.public-key-credential";

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecTaskCreateFromSelf(allocator: *const c_void) -> *mut c_void;
    fn SecTaskCopyValueForEntitlement(
        task: *mut c_void,
        entitlement: *const c_void,
        error: *mut *mut c_void,
    ) -> *mut c_void;
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: *const c_void);
    fn CFGetTypeID(value: *const c_void) -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(value: *const c_void) -> u8;
}
// LAContext lives in LocalAuthentication, which nothing else links.
#[link(name = "LocalAuthentication", kind = "framework")]
unsafe extern "C" {}

/// True only when this process is signed with the entitlement as a Boolean true.
pub(in super::super) fn platform_passkeys_available() -> bool {
    let key = NSString::from_str(ENTITLEMENT);
    // SAFETY: CoreFoundation create/copy rule; both owned values are released
    // here. NSString is toll-free bridged to CFString.
    unsafe {
        let task = SecTaskCreateFromSelf(std::ptr::null());
        if task.is_null() {
            return false;
        }
        let value = SecTaskCopyValueForEntitlement(
            task,
            Retained::as_ptr(&key).cast(),
            std::ptr::null_mut(),
        );
        let granted = !value.is_null()
            && CFGetTypeID(value) == CFBooleanGetTypeID()
            && CFBooleanGetValue(value) != 0;
        if !value.is_null() {
            CFRelease(value);
        }
        CFRelease(task);
        granted
    }
}

pub(super) struct Ivars {
    tab: String,
    channel: Channel,
    navigation: Arc<AtomicU64>,
    /// The navigation epoch plus one of the last document that asked for a
    /// passkey, for the agent's `read`.
    requested: Arc<AtomicU64>,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "CoincidePasskeyRequestHandlerV1"]
    #[thread_kind = MainThreadOnly]
    #[ivars = Ivars]
    struct DetectionHandler;
    unsafe impl NSObjectProtocol for DetectionHandler {}
    unsafe impl WKScriptMessageHandler for DetectionHandler {
        #[unsafe(method(userContentController:didReceiveScriptMessage:))]
        fn received(&self, _controller: &WKUserContentController, message: &WKScriptMessage) {
            let ivars = self.ivars();
            // Any frame's request marks the page; the notice names the tab's site.
            // SAFETY: WebKit delivers script messages on the main thread.
            let Some(url) = (unsafe { message.webView() })
                .and_then(|view| unsafe { view.URL() })
                .and_then(|url| url.absoluteString())
            else {
                return;
            };
            let Some(host) = page_host(&url.to_string()) else {
                return;
            };
            ivars.requested.store(
                ivars.navigation.load(Ordering::Acquire) + 1,
                Ordering::Release,
            );
            ivars.channel.push(Incoming::Requested {
                tab: ivars.tab.clone(),
                host,
            });
        }
    }
);

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "CoincideBitwardenPasskeyHandlerV1"]
    #[thread_kind = MainThreadOnly]
    #[ivars = Ivars]
    struct SignInHandler;
    unsafe impl NSObjectProtocol for SignInHandler {}
    unsafe impl WKScriptMessageHandlerWithReply for SignInHandler {
        #[unsafe(method(userContentController:didReceiveScriptMessage:replyHandler:))]
        fn received(
            &self,
            _controller: &WKUserContentController,
            message: &WKScriptMessage,
            reply: &Block<dyn Fn(*mut AnyObject, *mut NSString)>,
        ) {
            let reply = reply.copy();
            let ivars = self.ivars();
            // SAFETY: WebKit delivers script messages on the main thread with a
            // retained body and frame.
            let (object, frame) = unsafe { (message.body(), message.frameInfo()) };
            let body = json(&object, 0);
            let kind = body["kind"].as_str().unwrap_or_default().to_owned();
            let Some(origin) = origin(&frame) else {
                if kind == "get" {
                    eprintln!(
                        "Passkey request left to the browser: it came from a frame Coincide doesn't answer"
                    );
                }
                if kind == "available" {
                    reply_bool(&reply, false);
                } else {
                    reply_map(&reply, WebAuthnReply::Fallback.message());
                }
                return;
            };
            match kind.as_str() {
                "available" => reply_bool(&reply, ivars.channel.available()),
                "abort" => {
                    if let Some(id) = body["id"].as_str() {
                        ivars.channel.push(Incoming::Abort {
                            tab: ivars.tab.clone(),
                            id: id.to_owned(),
                        });
                    }
                    reply_nil(&reply);
                }
                "get" => {
                    let block = reply.clone();
                    ivars.channel.push(Incoming::Get {
                        tab: ivars.tab.clone(),
                        origin,
                        body,
                        reply: PageReply::new(move |message| reply_map(&block, message)),
                    });
                }
                "skipped" => {
                    // The script's own word, so only a known reason is logged.
                    if let Some(reason @ ("signal" | "options")) = body["reason"].as_str() {
                        eprintln!(
                            "Passkey request left to the browser: the page script couldn't read its {reason}"
                        );
                    }
                    reply_nil(&reply);
                }
                _ => reply_nil(&reply),
            }
        }
    }
);

/// The main frame's origin when WebAuthn may run there and the frame's document
/// address agrees with it. Other frames (cross-origin iframes included) get
/// nothing: the script only runs in main frames, and a page can't post on another
/// frame's behalf.
fn origin(frame: &WKFrameInfo) -> Option<WebAuthnOrigin> {
    // SAFETY: retained frame info delivered with the message on the main thread.
    unsafe {
        if !frame.isMainFrame() {
            return None;
        }
        let security = frame.securityOrigin();
        let origin = WebAuthnOrigin::new(
            &security.protocol().to_string(),
            &security.host().to_string(),
            u32::try_from(security.port()).ok()?,
        )?;
        let address = frame.request().URL()?.absoluteString()?.to_string();
        (WebAuthnOrigin::from_url(&address).as_ref() == Some(&origin)).then_some(origin)
    }
}

/// The script's message as JSON: strings, numbers, Booleans, arrays and
/// dictionaries, bounded in depth and size; anything else is null. The parser
/// then checks every field.
fn json(object: &AnyObject, depth: usize) -> Value {
    const MAX_ITEMS: usize = 512;
    const MAX_TEXT: usize = 256 * 1024;
    if depth > 6 {
        return Value::Null;
    }
    if let Some(text) = object.downcast_ref::<NSString>() {
        let text = text.to_string();
        return if text.len() <= MAX_TEXT {
            Value::String(text)
        } else {
            Value::Null
        };
    }
    if let Some(number) = object.downcast_ref::<NSNumber>() {
        // JavaScript Booleans arrive as CFBoolean, numbers as other NSNumbers.
        if number.class().name().to_bytes() == b"__NSCFBoolean" {
            return Value::Bool(number.as_bool());
        }
        return serde_json::Number::from_f64(number.as_f64()).map_or(Value::Null, Value::Number);
    }
    if let Some(array) = object.downcast_ref::<NSArray>() {
        if array.count() > MAX_ITEMS {
            return Value::Null;
        }
        return Value::Array(
            (0..array.count())
                .map(|index| json(&array.objectAtIndex(index), depth + 1))
                .collect(),
        );
    }
    if let Some(dictionary) = object.downcast_ref::<NSDictionary>() {
        if dictionary.count() > MAX_ITEMS {
            return Value::Null;
        }
        let keys = dictionary.allKeys();
        let mut map = Map::new();
        for index in 0..keys.count() {
            let key = keys.objectAtIndex(index);
            let (Some(name), Some(value)) = (
                key.downcast_ref::<NSString>(),
                dictionary.objectForKey(&key),
            ) else {
                continue;
            };
            map.insert(name.to_string(), json(&value, depth + 1));
        }
        return Value::Object(map);
    }
    Value::Null
}

fn reply_nil(reply: &RcBlock<dyn Fn(*mut AnyObject, *mut NSString)>) {
    reply.call((std::ptr::null_mut(), std::ptr::null_mut()));
}

fn reply_bool(reply: &RcBlock<dyn Fn(*mut AnyObject, *mut NSString)>, value: bool) {
    let number = NSNumber::new_bool(value);
    reply.call((
        Retained::as_ptr(&number).cast_mut().cast(),
        std::ptr::null_mut(),
    ));
}

/// The reply as WebKit gives it to the script: a dictionary of strings.
fn reply_map(reply: &RcBlock<dyn Fn(*mut AnyObject, *mut NSString)>, message: Map<String, Value>) {
    let pairs: Vec<(Retained<NSString>, Retained<NSString>)> = message
        .iter()
        .filter_map(|(key, value)| {
            Some((NSString::from_str(key), NSString::from_str(value.as_str()?)))
        })
        .collect();
    let keys: Vec<&NSString> = pairs.iter().map(|(key, _)| &**key).collect();
    let values: Vec<&AnyObject> = pairs
        .iter()
        .map(|(_, value)| -> &AnyObject { value })
        .collect();
    let dictionary: Retained<NSDictionary<NSString, AnyObject>> =
        NSDictionary::from_slices(&keys, &values);
    reply.call((
        Retained::as_ptr(&dictionary).cast_mut().cast(),
        std::ptr::null_mut(),
    ));
}

/// A tab's installed scripts and handlers. Dropping it removes the handlers, which
/// the user content controller otherwise retains for the view's life.
pub(in super::super) struct Bridge {
    controller: Retained<WKUserContentController>,
}
impl Drop for Bridge {
    fn drop(&mut self) {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        // SAFETY: main thread; removes only the names this bridge added.
        unsafe {
            let world = WKContentWorld::pageWorld(mtm);
            for name in [DETECTION_HANDLER, SIGN_IN_HANDLER] {
                self.controller
                    .removeScriptMessageHandlerForName_contentWorld(
                        &NSString::from_str(name),
                        &world,
                    );
            }
        }
    }
}

/// Adds both scripts and handlers to a new tab's configuration before WebKit
/// creates the view, so the first document already has them. The detection
/// script goes first, so the sign-in script's fallback is the detection wrapper
/// and an unanswered request still reaches the notice.
pub(in super::super) fn install(
    configuration: &WKWebViewConfiguration,
    tab: &str,
    channel: &Channel,
    navigation: Arc<AtomicU64>,
    requested: Arc<AtomicU64>,
) -> Option<Bridge> {
    let mtm = MainThreadMarker::new()?;
    AnyClass::get(c"WKContentWorld")?;
    let ivars = || Ivars {
        tab: tab.to_owned(),
        channel: channel.clone(),
        navigation: navigation.clone(),
        requested: requested.clone(),
    };
    // SAFETY: main thread; configuration not yet used by any view.
    unsafe {
        let controller = configuration.userContentController();
        let world = WKContentWorld::pageWorld(mtm);
        for (source, main_only) in [(DETECTION_SCRIPT, false), (SIGN_IN_SCRIPT, true)] {
            let script = WKUserScript::initWithSource_injectionTime_forMainFrameOnly_inContentWorld(
                WKUserScript::alloc(mtm),
                &NSString::from_str(source),
                WKUserScriptInjectionTime::AtDocumentStart,
                main_only,
                &world,
            );
            controller.addUserScript(&script);
        }
        let detection = DetectionHandler::alloc(mtm).set_ivars(ivars());
        let detection: Retained<DetectionHandler> = msg_send![super(detection), init];
        controller.addScriptMessageHandler_contentWorld_name(
            ProtocolObject::from_ref(&*detection),
            &world,
            &NSString::from_str(DETECTION_HANDLER),
        );
        let sign_in = SignInHandler::alloc(mtm).set_ivars(ivars());
        let sign_in: Retained<SignInHandler> = msg_send![super(sign_in), init];
        controller.addScriptMessageHandlerWithReply_contentWorld_name(
            ProtocolObject::from_ref(&*sign_in),
            &world,
            &NSString::from_str(SIGN_IN_HANDLER),
        );
        Some(Bridge { controller })
    }
}

/// `LAPolicyDeviceOwnerAuthentication`: Touch ID, or the Mac's password.
const DEVICE_OWNER_AUTHENTICATION: isize = 2;

/// Touch ID or the Mac's password, as the Swift app asks with LocalAuthentication.
/// `done` runs once, on LocalAuthentication's queue. Returns how to stop the
/// dialog while it is asking.
pub(super) fn verify_user(
    reason: &str,
    done: Box<dyn FnOnce(UserVerification) + Send>,
    native_block: super::NativeLease,
) -> Option<Box<dyn FnOnce()>> {
    let Some(class) = AnyClass::get(c"LAContext") else {
        done(UserVerification::Unavailable);
        return None;
    };
    // SAFETY: LAContext's documented API; the context is retained by this
    // function and the returned cancel closure, and its reply block owns `done`.
    unsafe {
        let context: Retained<AnyObject> = msg_send![class, new];
        let _: () = msg_send![&*context, setLocalizedCancelTitle: &*NSString::from_str("Cancel")];
        let mut error: *mut NSError = std::ptr::null_mut();
        let can: Bool =
            msg_send![&*context, canEvaluatePolicy: DEVICE_OWNER_AUTHENTICATION, error: &mut error];
        if !can.as_bool() {
            // This Mac can't verify the user (no Touch ID and no password set).
            done(UserVerification::Unavailable);
            return None;
        }
        let done = Mutex::new(Some(done));
        let block = RcBlock::new(move |success: Bool, _error: *mut NSError| {
            // Borrow independently of `done`: invoking the result or invalidating
            // LAContext does not prove its native reply block has returned/released.
            let _held_native_block = &native_block;
            if let Some(done) = done.lock().unwrap_or_else(|e| e.into_inner()).take() {
                done(if success.as_bool() {
                    UserVerification::Verified
                } else {
                    UserVerification::Failed
                });
            }
        });
        let _: () = msg_send![
            &*context,
            evaluatePolicy: DEVICE_OWNER_AUTHENTICATION,
            localizedReason: &*NSString::from_str(reason),
            reply: &*block
        ];
        Some(Box::new(move || {
            // `invalidate` may be called from any thread; the reply then fails.
            let _: () = msg_send![&*context, invalidate];
        }))
    }
}
