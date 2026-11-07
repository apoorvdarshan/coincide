//! WebKitGTK software snapshot with private-world, re-measured masking. The
//! viewport uses the Visible region. A full page uses FullDocument, which
//! paints the document without resizing the view; its allocation is bounded
//! from the private-world metrics before WebKit renders, and only the captured
//! rows (at most 20,000 CSS pixels) are copied out of the native surface.
use super::super::shutdown::NativeLease;
use super::{Callbacks, Completion, Data, Pixels};
use coincide_core::browser_screenshot::{
    self, Channels, Geometry, MAX_NATIVE_EDGE, MAX_NATIVE_PIXELS, Metrics, Rect, mask,
};
use gtk::{cairo, prelude::WidgetExt};
use java_script_core::ValueExt;
use std::{
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use webkit2gtk::{SnapshotOptions, SnapshotRegion, WebView, WebViewExt};
use wry::WebViewExtUnix;
const WORLD: &str = "CoincidePrivateSnapshotV1";
// FullDocument renders the whole document into one shared surface before
// rows can be cropped. Refuse larger documents instead of allocating them.
const MAX_FULL_DOCUMENT_PIXELS: f64 = 64_000_000.;
struct Source {
    view: WebView,
    navigation: Arc<AtomicU64>,
    epoch: u64,
    url: String,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    callbacks: Callbacks,
    width: i32,
    height: i32,
    scale: i32,
    _target: NativeLease,
}
impl Source {
    fn valid(&self) -> bool {
        !self.callbacks.closed()
            && !self.cancelled.load(Ordering::Acquire)
            && !self.protected.load(Ordering::Acquire)
            && self.navigation.load(Ordering::Acquire) == self.epoch
            && self.view.uri().is_some_and(|url| url.as_str() == self.url)
            && self.view.allocated_width() == self.width
            && self.view.allocated_height() == self.height
            && self.view.scale_factor() == self.scale
            && self.navigation.load(Ordering::Acquire) == self.epoch
    }
    fn evaluate(
        &self,
        script: &'static str,
        arguments: &[(&str, &str)],
        done: impl FnOnce(Result<java_script_core::Value, webkit2gtk::glib::Error>) + 'static,
    ) {
        let args = webkit2gtk::glib::VariantDict::new(None);
        for (key, value) in arguments {
            args.insert(key, *value);
        }
        let ack = self.callbacks.begin();
        let lease = self.callbacks.lifetimes().block();
        self.view.call_async_javascript_function(
            script,
            Some(&args.end()),
            Some(WORLD),
            None,
            None::<&webkit2gtk::gio::Cancellable>,
            move |result| {
                let _held = &lease;
                ack.ack();
                done(result);
            },
        );
    }
}
/// What the native surface must contain once WebKit returns it.
enum Plan {
    Viewport(Metrics),
    Document {
        metrics: Metrics,
        height: f64,
        truncated: bool,
    },
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
    if !gtk::is_initialized_main_thread() {
        completion(Err("Snapshot requires the GTK UI thread"));
        return;
    }
    let view = view.webview();
    let Some(url) = view.uri().map(|url| url.to_string()) else {
        completion(Err("Native snapshot has no document"));
        return;
    };
    let width = view.allocated_width();
    let height = view.allocated_height();
    let scale = view.scale_factor();
    if width <= 1
        || height <= 1
        || width > 20000
        || height > 20000
        || !(1..=4).contains(&scale)
        || width as u64 * height as u64 * scale as u64 * scale as u64 > MAX_NATIVE_PIXELS
    {
        completion(Err("Show the browser before taking a screenshot"));
        return;
    }
    let source = Rc::new(Source {
        view,
        navigation: navigation.clone(),
        epoch: navigation.load(Ordering::Acquire),
        url,
        protected,
        cancelled,
        width,
        height,
        scale,
        _target: callbacks.lifetimes().target(),
        callbacks,
    });
    if !source.valid() {
        completion(Err("Snapshot source changed"));
        return;
    }
    let ticket = uuid::Uuid::new_v4().to_string();
    let target = source.clone();
    let prepared_ticket = ticket.clone();
    let url = source.url.clone();
    source.evaluate(
        mask::PREPARE,
        &[("ticket", &ticket), ("expectedURL", &url), ("mode", "mask")],
        move |result| {
            let metrics = result
                .ok()
                .filter(|v| v.is_string())
                .map(|v| v.to_str().to_string())
                .and_then(|v| browser_screenshot::parse_metrics(&v).ok());
            let plan = match metrics {
                Some(metrics) if target.valid() => plan(&target, metrics, full_page),
                _ => Err("Snapshot mask preparation failed"),
            };
            let plan = match plan {
                Ok(plan) => plan,
                Err(error) => {
                    finish(target, prepared_ticket, completion, Err(error));
                    return;
                }
            };
            let region = match plan {
                Plan::Viewport(_) => SnapshotRegion::Visible,
                Plan::Document { .. } => SnapshotRegion::FullDocument,
            };
            let owner = target.clone();
            let ack = target.callbacks.begin();
            let lease = target.callbacks.lifetimes().block();
            target.view.snapshot(
                region,
                SnapshotOptions::NONE,
                None::<&webkit2gtk::gio::Cancellable>,
                move |result| {
                    let _held = &lease;
                    ack.ack();
                    let pixels = if owner.valid() {
                        result
                            .ok()
                            .and_then(|surface| cairo::ImageSurface::try_from(surface).ok())
                            .ok_or("Native snapshot failed")
                            .and_then(|image| pixels(&image, plan))
                    } else {
                        Err("Snapshot source changed")
                    };
                    finish(owner, prepared_ticket, completion, pixels);
                },
            );
        },
    );
}
fn plan(source: &Source, metrics: Metrics, full_page: bool) -> Result<Plan, &'static str> {
    if !full_page {
        return Ok(Plan::Viewport(metrics));
    }
    let (height, truncated) =
        browser_screenshot::full_page_height(metrics.client_height, metrics.document_height);
    // Device pixels per CSS pixel: GTK's integer scale times the page zoom
    // that matches GPUI's scale. WebKit's devicePixelRatio omits page zoom.
    let scale = f64::from(source.scale) * source.view.zoom_level();
    let width = metrics.document_width.max(metrics.client_width) * scale;
    let document = metrics.document_height.max(metrics.client_height) * scale;
    if !scale.is_finite()
        || scale <= 0.
        || width * document > MAX_FULL_DOCUMENT_PIXELS
        || document > f64::from(MAX_NATIVE_EDGE) - 2.
        || width > f64::from(MAX_NATIVE_EDGE) - 2.
        || width * (height * scale).ceil() > MAX_NATIVE_PIXELS as f64
    {
        return Err(
            "This page is too large for a full-page snapshot on Linux at this display scale; take a viewport screenshot",
        );
    }
    Ok(Plan::Document {
        metrics,
        height,
        truncated,
    })
}
/// Copies only checked rows. A surface that no longer matches the measured
/// document or viewport at one uniform scale is refused before any copy.
fn pixels(image: &cairo::ImageSurface, plan: Plan) -> Result<Pixels, &'static str> {
    let width = u32::try_from(image.width()).map_err(|_| "Native snapshot failed")?;
    let height = u32::try_from(image.height()).map_err(|_| "Native snapshot failed")?;
    let stride = usize::try_from(image.stride()).map_err(|_| "Native snapshot failed")?;
    if image.format() != cairo::Format::ARgb32
        || width == 0
        || height == 0
        || width > MAX_NATIVE_EDGE
        || height > MAX_NATIVE_EDGE
        || stride < width as usize * 4
    {
        return Err("Native snapshot failed");
    }
    let (geometry, rows, truncated) = match plan {
        Plan::Viewport(metrics) => {
            // The visible region excludes classic scrollbars; overlay ones
            // take no layout space. Accept exactly one uniform match.
            let geometry = [
                (metrics.client_width, metrics.client_height),
                (metrics.inner_width, metrics.inner_height),
            ]
            .into_iter()
            .filter_map(|(w, h)| Geometry::checked(w, h, metrics.masks.clone()).ok())
            .find(|geometry| geometry.check_native_size(width, height).is_ok())
            .ok_or("Native snapshot no longer matches its page")?;
            (geometry, height, false)
        }
        Plan::Document {
            metrics,
            height: css_height,
            truncated,
        } => {
            let document_width = metrics.document_width.max(metrics.client_width);
            let document_height = metrics.document_height.max(metrics.client_height);
            let sx = f64::from(width) / document_width;
            let sy = f64::from(height) / document_height;
            if !sx.is_finite()
                || !sy.is_finite()
                || (sx - sy).abs() > 2. / document_width + 2. / document_height
            {
                return Err("The page changed size during its snapshot");
            }
            let rows = ((css_height * sy).ceil() as u32).min(height);
            let masks = metrics
                .masks
                .iter()
                .map(|mask| mask.translated(metrics.scroll_x, metrics.scroll_y))
                .collect::<Vec<Rect>>();
            let geometry = Geometry::checked(f64::from(width) / sy, f64::from(rows) / sy, masks)
                .map_err(|_| "Snapshot geometry exceeds bounds")?;
            (geometry, rows, truncated)
        }
    };
    geometry
        .check_native_size(width, rows)
        .map_err(|_| "Native snapshot exceeds bounds")?;
    let length = stride
        .checked_mul(rows as usize - 1)
        .and_then(|n| n.checked_add(width as usize * 4))
        .ok_or("Native snapshot failed")?;
    let mut bytes = None;
    image
        .with_data(|data| bytes = data.get(..length).map(<[u8]>::to_vec))
        .map_err(|_| "Native snapshot failed")?;
    Ok(Pixels {
        data: Data::Raw {
            width,
            height: rows,
            stride,
            bytes: bytes.ok_or("Native snapshot failed")?,
            channels: Channels::cairo_argb32(),
        },
        geometry,
        truncated,
    })
}
fn finish(
    source: Rc<Source>,
    ticket: String,
    completion: Completion,
    pixels: Result<Pixels, &'static str>,
) {
    let owner = source.clone();
    let url = source.url.clone();
    source.evaluate(
        mask::FINISH,
        &[
            ("ticket", &ticket),
            ("expectedURL", &url),
            ("restoreX", ""),
            ("restoreY", ""),
            ("restoreHeight", ""),
        ],
        move |result| {
            let valid =
                result.is_ok_and(|value| value.is_boolean() && value.to_boolean()) && owner.valid();
            completion(match pixels {
                Ok(_) if !valid => Err("Snapshot document changed or was cancelled"),
                pixels => pixels,
            });
        },
    );
}
