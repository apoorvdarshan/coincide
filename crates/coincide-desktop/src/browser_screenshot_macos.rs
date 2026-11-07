//! WKWebView software snapshot with private-world, re-measured masking. No
//! screen capture, permission query or page-world script execution.
//!
//! A full page follows Swift: the view takes the bounded document height, but
//! only for one main-thread turn that queues PREPARE, the snapshot and FINISH
//! to the web process in order and then restores the frame, so GPUI never
//! lays out or draws the resized view. The reader's scroll position returns
//! once the original viewport is back.
use super::{Callbacks, Completion, Data, Pixels};
use block2::RcBlock;
use coincide_core::browser_screenshot::{
    self, Channels, Geometry, MAX_NATIVE_PIXELS, MAX_PNG_BYTES, Metrics, mask,
};
use objc2::{AllocAnyThread, MainThreadMarker, rc::Retained, runtime::AnyObject};
use objc2_app_kit::{NSBitmapFormat, NSBitmapImageFileType, NSBitmapImageRep, NSImage};
use objc2_foundation::{NSDictionary, NSError, NSNumber, NSRect, NSSize, NSString};
use objc2_web_kit::{WKContentWorld, WKSnapshotConfiguration, WKWebView};
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use wry::WebViewExtMacOS;

const WORLD: &str = "CoincidePrivateSnapshotV1";

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
        arguments: &[(&str, &str)],
        done: impl FnOnce(*mut AnyObject, *mut NSError) + 'static,
    ) {
        let Some(mtm) = MainThreadMarker::new() else {
            done(std::ptr::null_mut(), std::ptr::null_mut());
            return;
        };
        let world = unsafe { WKContentWorld::worldWithName(&NSString::from_str(WORLD), mtm) };
        let keys = arguments
            .iter()
            .map(|(key, _)| NSString::from_str(key))
            .collect::<Vec<_>>();
        let values = arguments
            .iter()
            .map(|(_, value)| NSString::from_str(value))
            .collect::<Vec<_>>();
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
/// The full-page view size for one turn, in CSS pixels and view points, and
/// the reader's scroll position and viewport height to restore afterwards.
struct Resize {
    css: (f64, f64),
    points: f64,
    restore: (f64, f64, f64),
}
/// Three native replies; the capture settles only once every one returned.
struct Transaction {
    metrics: Option<Option<Metrics>>,
    image: Option<Option<Data>>,
    finished: Option<bool>,
    expected: Option<(f64, f64)>,
    truncated: bool,
    completion: Option<Completion>,
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
    let bounds = source.view.bounds();
    let Some(backing) = source.view.window().map(|w| w.backingScaleFactor()) else {
        completion(Err("Show the browser before taking a screenshot"));
        return;
    };
    if !bounds.size.width.is_finite()
        || !bounds.size.height.is_finite()
        || bounds.size.width < 1.
        || bounds.size.height < 1.
        || bounds.size.width > 20000.
        || bounds.size.height > 20000.
        || !backing.is_finite()
        || !(1. ..=4.).contains(&backing)
    {
        completion(Err("Native snapshot viewport exceeds bounds"));
        return;
    }
    if !full_page {
        begin(source, mtm, bounds, backing, None, false, completion);
        return;
    }
    let ticket = uuid::Uuid::new_v4().to_string();
    let measured = source.clone();
    let url = source.url.clone();
    source.evaluate(
        mask::PREPARE,
        &[
            ("ticket", &ticket),
            ("expectedURL", &url),
            ("mode", "measure"),
        ],
        move |value, error| {
            let metrics = read_metrics(value, error)
                .filter(|_| measured.valid() && measured.view.bounds() == bounds);
            let Some(metrics) = metrics else {
                completion(Err("Snapshot page measurement failed"));
                return;
            };
            let (height, truncated) =
                browser_screenshot::full_page_height(metrics.inner_height, metrics.document_height);
            // Page zoom makes CSS pixels differ from view points.
            let points_per_css = bounds.size.height / metrics.inner_height;
            let resize = (height > metrics.inner_height + 0.5).then(|| Resize {
                css: (metrics.inner_width, height),
                points: (height * points_per_css).round(),
                restore: (metrics.scroll_x, metrics.scroll_y, metrics.inner_height),
            });
            begin(
                measured, mtm, bounds, backing, resize, truncated, completion,
            );
        },
    );
}
fn begin(
    source: Source,
    mtm: MainThreadMarker,
    bounds: NSRect,
    backing: f64,
    resize: Option<Resize>,
    truncated: bool,
    completion: Completion,
) {
    // Bound native rendering BEFORE asking WebKit to allocate a snapshot. No
    // renderer-provided geometry can override this actual native view bound.
    let (width, height, device) = match &resize {
        Some(resize) => (
            resize.css.0,
            resize.css.1,
            backing * resize.points / resize.css.1,
        ),
        None => (bounds.size.width, bounds.size.height, backing),
    };
    let Ok(scale) = browser_screenshot::output_scale(width, height, device) else {
        completion(Err("Native snapshot exceeds its allocation budget"));
        return;
    };
    // The snapshot width is in view points; WebKit renders it at the backing scale.
    let snapshot_width = width * scale / backing;
    let ticket = uuid::Uuid::new_v4().to_string();
    let transaction = Rc::new(RefCell::new(Transaction {
        metrics: None,
        image: None,
        finished: None,
        expected: resize.as_ref().map(|resize| resize.css),
        truncated,
        completion: Some(completion),
    }));
    let original = source.view.frame();
    let rect = match &resize {
        Some(resize) => NSRect::new(bounds.origin, NSSize::new(bounds.size.width, resize.points)),
        None => bounds,
    };
    if let Some(resize) = &resize {
        source
            .view
            .setFrameSize(NSSize::new(original.size.width, resize.points));
    }
    let url = source.url.clone();
    let prepared = transaction.clone();
    let owner = source.clone();
    source.evaluate(
        mask::PREPARE,
        &[
            ("ticket", &ticket),
            ("expectedURL", &url),
            ("mode", if resize.is_some() { "mask-top" } else { "mask" }),
        ],
        move |value, error| {
            prepared.borrow_mut().metrics = Some(read_metrics(value, error));
            settle(&owner, &prepared);
        },
    );
    let config = unsafe { WKSnapshotConfiguration::new(mtm) };
    unsafe {
        config.setRect(rect);
        config.setSnapshotWidth(Some(&NSNumber::new_f64(snapshot_width)));
        config.setAfterScreenUpdates(true);
    }
    let ack = source.callbacks.begin();
    let lease = source.callbacks.lifetimes().block();
    let shot = transaction.clone();
    let owner = source.clone();
    let block = RcBlock::new(move |image: *mut NSImage, error: *mut NSError| {
        let _held = &lease;
        ack.ack();
        if shot.borrow().image.is_some() {
            return;
        }
        let data = if error.is_null() && owner.valid() {
            unsafe { image.as_ref() }.and_then(image_pixels)
        } else {
            None
        };
        shot.borrow_mut().image = Some(data);
        settle(&owner, &shot);
    });
    unsafe {
        source
            .view
            .takeSnapshotWithConfiguration_completionHandler(Some(&config), &block);
    }
    let restore = resize.as_ref().map_or_else(
        || [String::new(), String::new(), String::new()],
        |resize| {
            [
                resize.restore.0.to_string(),
                resize.restore.1.to_string(),
                resize.restore.2.to_string(),
            ]
        },
    );
    let finished = transaction.clone();
    let owner = source.clone();
    source.evaluate(
        mask::FINISH,
        &[
            ("ticket", &ticket),
            ("expectedURL", &url),
            ("restoreX", &restore[0]),
            ("restoreY", &restore[1]),
            ("restoreHeight", &restore[2]),
        ],
        move |value, error| {
            let valid = error.is_null()
                && unsafe { value.as_ref() }
                    .and_then(|v| v.downcast_ref::<NSNumber>())
                    .is_some_and(|v| v.boolValue());
            finished.borrow_mut().finished = Some(valid);
            settle(&owner, &finished);
        },
    );
    if resize.is_some() {
        source.view.setFrame(original);
    }
}
// Raw pixels never leave this owner until the DOM transaction, the native
// source and the native result size all agree.
fn settle(source: &Source, transaction: &RefCell<Transaction>) {
    let (metrics, image, finished, expected, truncated, completion) = {
        let mut state = transaction.borrow_mut();
        if state.metrics.is_none() || state.image.is_none() || state.finished.is_none() {
            return;
        }
        let Some(completion) = state.completion.take() else {
            return;
        };
        (
            state.metrics.take().flatten(),
            state.image.take().flatten(),
            state.finished.unwrap_or(false),
            state.expected,
            state.truncated,
            completion,
        )
    };
    let result = (|| {
        if !finished || !source.valid() {
            return Err("Snapshot document changed or was cancelled");
        }
        let metrics = metrics.ok_or("Snapshot mask preparation failed")?;
        if let Some((width, height)) = expected
            && ((metrics.inner_width - width).abs() > 0.5
                || (metrics.inner_height - height).abs() > 1.)
        {
            return Err("The native view did not take its full-page size");
        }
        let geometry = Geometry::checked(metrics.inner_width, metrics.inner_height, metrics.masks)
            .map_err(|_| "Snapshot geometry exceeds bounds")?;
        let data = image.ok_or("Native snapshot failed or changed")?;
        if let Data::Raw { width, height, .. } = &data {
            geometry
                .check_native_size(*width, *height)
                .map_err(|_| "Native snapshot no longer matches its page")?;
        }
        Ok(Pixels {
            data,
            geometry,
            truncated,
        })
    })();
    completion(result);
}
fn read_metrics(value: *mut AnyObject, error: *mut NSError) -> Option<Metrics> {
    if !error.is_null() {
        return None;
    }
    let text = unsafe { value.as_ref() }?
        .downcast_ref::<NSString>()?
        .to_string();
    browser_screenshot::parse_metrics(&text).ok()
}
/// Copy bounded row pixels for the encoder worker; only an unknown sample
/// layout falls back to WebKit's own PNG encoding on this thread.
fn image_pixels(image: &NSImage) -> Option<Data> {
    let tiff = image.TIFFRepresentation()?;
    if tiff.len() > MAX_NATIVE_PIXELS as usize * 8 + (1 << 20) {
        return None;
    }
    let bitmap = NSBitmapImageRep::initWithData(NSBitmapImageRep::alloc(), &tiff)?;
    let width = u32::try_from(bitmap.pixelsWide()).ok()?;
    let height = u32::try_from(bitmap.pixelsHigh()).ok()?;
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_NATIVE_PIXELS {
        return None;
    }
    if let Some(channels) = channels(&bitmap) {
        let stride = usize::try_from(bitmap.bytesPerRow()).ok()?;
        let data = bitmap.bitmapData();
        if !data.is_null() && stride >= width as usize * channels.bytes_per_pixel {
            let length = stride.checked_mul(height as usize)?;
            // SAFETY: the retained bitmap owns `bytesPerRow * pixelsHigh` bytes.
            let bytes = unsafe { std::slice::from_raw_parts(data, length) }.to_vec();
            return Some(Data::Raw {
                width,
                height,
                stride,
                bytes,
                channels,
            });
        }
    }
    let png = unsafe {
        bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())
    }?;
    (png.len() <= MAX_PNG_BYTES).then(|| Data::Png(png.to_vec()))
}
fn channels(bitmap: &NSBitmapImageRep) -> Option<Channels> {
    let format = bitmap.bitmapFormat();
    if bitmap.isPlanar()
        || bitmap.bitsPerSample() != 8
        || format.contains(NSBitmapFormat::FloatingPointSamples)
    {
        return None;
    }
    let little = format.contains(NSBitmapFormat::ThirtyTwoBitLittleEndian);
    match (
        bitmap.samplesPerPixel(),
        bitmap.hasAlpha(),
        bitmap.bitsPerPixel(),
    ) {
        (4, true, 32) => {
            // Logical sample positions, reversed in memory for 32-bit little endian.
            let [red, green, blue, alpha] = if format.contains(NSBitmapFormat::AlphaFirst) {
                [1, 2, 3, 0]
            } else {
                [0, 1, 2, 3]
            };
            let at = |sample: usize| if little { 3 - sample } else { sample };
            Some(Channels {
                red: at(red),
                green: at(green),
                blue: at(blue),
                alpha: Some(at(alpha)),
                bytes_per_pixel: 4,
                premultiplied: !format.contains(NSBitmapFormat::AlphaNonpremultiplied),
            })
        }
        (3, false, 24) if !little => Some(Channels {
            red: 0,
            green: 1,
            blue: 2,
            alpha: None,
            bytes_per_pixel: 3,
            premultiplied: false,
        }),
        _ => None,
    }
}
