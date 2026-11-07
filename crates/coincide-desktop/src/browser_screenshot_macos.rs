//! WKWebView snapshot + private-world, mutation-checked masking. No view resize,
//! scrolling, screen capture, permission query or page-world script execution.
use super::{Callbacks, Completion, Pixels};
use block2::RcBlock;
use coincide_core::browser_screenshot::{Geometry, MAX_NATIVE_PIXELS, MAX_PNG_BYTES, Rect, mask};
use objc2::{AllocAnyThread, MainThreadMarker, rc::Retained, runtime::AnyObject};
use objc2_app_kit::{NSBitmapImageFileType, NSBitmapImageRep, NSImage};
use objc2_foundation::{NSDictionary, NSError, NSNumber, NSString};
use objc2_web_kit::{WKContentWorld, WKSnapshotConfiguration, WKWebView};
use serde::Deserialize;
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use wry::WebViewExtMacOS;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Layout {
    width: f64,
    height: f64,
    masks: Vec<Rect>,
}
#[derive(Clone)]
struct Source {
    view: Retained<WKWebView>,
    navigation: Arc<AtomicU64>,
    epoch: u64,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    callbacks: Callbacks,
    url: String,
    _target: super::super::shutdown::NativeLease,
}
impl Source {
    fn valid(&self) -> bool {
        !self.callbacks.closed()
            && !self.cancelled.load(Ordering::Acquire)
            && !self.protected.load(Ordering::Acquire)
            && self.navigation.load(Ordering::Acquire) == self.epoch
            && unsafe { self.view.URL() }
                .and_then(|u| u.absoluteString())
                .is_some_and(|u| u.to_string() == self.url)
            && self.navigation.load(Ordering::Acquire) == self.epoch
    }
    /// Actual callbacks ACK even after cancellation; dropped/unresponsive native
    /// blocks never manufacture a completion receipt.
    fn evaluate(
        &self,
        script: &'static str,
        ticket: &str,
        full_page: bool,
        done: impl FnOnce(*mut AnyObject, *mut NSError) + 'static,
    ) {
        let Some(mtm) = MainThreadMarker::new() else {
            done(std::ptr::null_mut(), std::ptr::null_mut());
            return;
        };
        let world = unsafe {
            WKContentWorld::worldWithName(&NSString::from_str("CoincidePrivateSnapshotV1"), mtm)
        };
        let values = [
            NSString::from_str(ticket),
            NSString::from_str(&self.url),
            NSString::from_str(if full_page { "yes" } else { "no" }),
        ];
        let keys = [
            NSString::from_str("ticket"),
            NSString::from_str("expectedURL"),
            NSString::from_str("fullPage"),
        ];
        let args = NSDictionary::from_slices(
            &keys.iter().map(|k| &**k).collect::<Vec<_>>(),
            &values
                .iter()
                .map(|v| -> &AnyObject { v })
                .collect::<Vec<_>>(),
        );
        let ack = self.callbacks.begin();
        let lease = self.callbacks.lifetimes().block();
        let pending = RefCell::new(Some(done));
        let block = RcBlock::new(move |value: *mut AnyObject, error: *mut NSError| {
            let _held = &lease;
            ack.ack();
            if let Some(done) = pending.borrow_mut().take() {
                done(value, error);
            }
        });
        unsafe {
            self.view
                .callAsyncJavaScript_arguments_inFrame_inContentWorld_completionHandler(
                    &NSString::from_str(script),
                    Some(&args),
                    None,
                    &world,
                    Some(&block),
                );
        }
    }
}
pub(in crate::browser) fn capture(
    view: &wry::WebView,
    navigation: Arc<AtomicU64>,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    callbacks: Callbacks,
    full_page: bool,
    completion: Completion,
) {
    let Some(mtm) = MainThreadMarker::new() else {
        completion(Err("Native snapshot requires the UI thread"));
        return;
    };
    let view = view.webview().into_super();
    let Some(url) = (unsafe { view.URL() })
        .and_then(|u| u.absoluteString())
        .map(|u| u.to_string())
    else {
        completion(Err("Native snapshot has no document"));
        return;
    };
    let epoch = navigation.load(Ordering::Acquire);
    let source = Source {
        view,
        navigation,
        epoch,
        protected,
        cancelled,
        _target: callbacks.lifetimes().target(),
        callbacks,
        url,
    };
    if !source.valid() {
        completion(Err("Snapshot document is stale"));
        return;
    }
    // Bound native rendering BEFORE asking WebKit to allocate a snapshot. No
    // renderer-provided geometry can override this actual native view bound.
    let bounds = source.view.bounds();
    let width = bounds.size.width;
    let height = bounds.size.height;
    let scale = source.view.window().map_or(2., |w| w.backingScaleFactor());
    if !width.is_finite()
        || !height.is_finite()
        || !scale.is_finite()
        || width <= 0.
        || height <= 0.
        || width > 20000.
        || height > 20000.
        || !(1. ..=4.).contains(&scale)
    {
        completion(Err("Native snapshot viewport exceeds bounds"));
        return;
    }
    let output_width = (1600. / scale).min(width);
    let expected_width = (output_width * scale).ceil();
    let expected_height = (height * output_width / width * scale).ceil();
    if expected_width * expected_height > MAX_NATIVE_PIXELS as f64 {
        completion(Err("Native snapshot exceeds pixel budget"));
        return;
    }
    let ticket = uuid::Uuid::new_v4().to_string();
    let pending = Rc::new(RefCell::new(Some(completion)));
    let target = source.clone();
    let prepared_ticket = ticket.clone();
    source.evaluate(mask::PREPARE, &ticket, full_page, move |value, error| {
        let layout = if error.is_null() {
            unsafe { value.as_ref() }
                .and_then(|v| v.downcast_ref::<NSString>())
                .map(|v| v.to_string())
                .filter(|v| v.len() <= 256 * 1024)
                .and_then(|v| serde_json::from_str::<Layout>(&v).ok())
        } else {
            None
        };
        let geometry = layout
            .and_then(|layout| Geometry::checked(layout.width, layout.height, layout.masks).ok());
        if geometry.is_none() || !target.valid() || target.view.bounds() != bounds {
            finish(
                target,
                prepared_ticket,
                pending,
                None,
                "Snapshot mask preparation failed",
            );
            return;
        }
        let config = unsafe { WKSnapshotConfiguration::new(mtm) };
        unsafe {
            config.setRect(bounds);
            config.setSnapshotWidth(Some(&NSNumber::new_f64(output_width)));
            config.setAfterScreenUpdates(true);
        }
        let ack = target.callbacks.begin();
        let lease = target.callbacks.lifetimes().block();
        let owner = target.clone();
        if !target.valid() {
            finish(target, prepared_ticket, pending, None, "Snapshot cancelled");
            return;
        }
        let state = RefCell::new(Some((geometry.unwrap(), pending, prepared_ticket)));
        let block = RcBlock::new(move |image: *mut NSImage, error: *mut NSError| {
            let _held = &lease;
            ack.ack();
            let Some((geometry, pending, ticket)) = state.borrow_mut().take() else {
                return;
            };
            let png = (|| {
                if !error.is_null() || !owner.valid() || owner.view.bounds() != bounds {
                    return None;
                }
                let image = unsafe { image.as_ref() }?;
                let tiff = image.TIFFRepresentation()?;
                if tiff.len() > MAX_NATIVE_PIXELS as usize * 8 {
                    return None;
                }
                let bitmap = NSBitmapImageRep::initWithData(NSBitmapImageRep::alloc(), &tiff)?;
                let width = u32::try_from(bitmap.pixelsWide()).ok()?;
                let height = u32::try_from(bitmap.pixelsHigh()).ok()?;
                geometry.check_native_size(width, height).ok()?;
                let data = unsafe {
                    bitmap.representationUsingType_properties(
                        NSBitmapImageFileType::PNG,
                        &NSDictionary::new(),
                    )
                }?;
                (data.len() <= MAX_PNG_BYTES).then(|| data.to_vec())
            })();
            let result = png.map(|png| Pixels {
                data: super::Data::Png(png),
                geometry,
            });
            finish(
                owner.clone(),
                ticket,
                pending,
                result,
                "Native snapshot failed or changed",
            );
        });
        unsafe {
            target
                .view
                .takeSnapshotWithConfiguration_completionHandler(Some(&config), &block);
        }
    });
}
// Final isolated-world callback validates and restores only owned styles. Raw
// pixels never leave this owner until both native and DOM source checks pass.
fn finish(
    source: Source,
    ticket: String,
    pending: Rc<RefCell<Option<Completion>>>,
    pixels: Option<Pixels>,
    error: &'static str,
) {
    let owner = source.clone();
    source.evaluate(mask::FINISH, &ticket, false, move |value, native_error| {
        let valid = native_error.is_null()
            && unsafe { value.as_ref() }
                .and_then(|v| v.downcast_ref::<NSNumber>())
                .is_some_and(|v| v.boolValue())
            && owner.valid();
        if let Some(done) = pending.borrow_mut().take() {
            done(if valid {
                pixels.ok_or(error)
            } else {
                Err("Snapshot document changed or was cancelled")
            });
        }
    });
}
