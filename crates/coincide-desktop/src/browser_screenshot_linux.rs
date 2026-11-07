//! WebKitGTK visible-region snapshot. FullDocument is intentionally not used:
//! that API provides no preallocation clip/budget against a growing document.
use super::super::shutdown::NativeLease;
use super::{Callbacks, Completion, Data, Pixels};
use coincide_core::browser_screenshot::{Geometry, MAX_NATIVE_PIXELS, Rect, mask};
use gtk::{cairo, prelude::WidgetExt};
use java_script_core::ValueExt;
use serde::Deserialize;
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
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Layout {
    width: f64,
    height: f64,
    masks: Vec<Rect>,
}
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
        ticket: &str,
        full_page: bool,
        done: impl FnOnce(Result<java_script_core::Value, webkit2gtk::glib::Error>) + 'static,
    ) {
        let args = webkit2gtk::glib::VariantDict::new(None);
        args.insert("ticket", ticket);
        args.insert("expectedURL", self.url.as_str());
        args.insert("fullPage", if full_page { "yes" } else { "no" });
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
pub(in crate::browser) fn capture(
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
    if width <= 0
        || height <= 0
        || width > 20000
        || height > 20000
        || !(1..=4).contains(&scale)
        || width as u64 * height as u64 * scale as u64 * scale as u64 > MAX_NATIVE_PIXELS
    {
        completion(Err(
            "Native snapshot viewport exceeds its allocation budget",
        ));
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
    source.evaluate(mask::PREPARE, &ticket, full_page, move |result| {
        let layout = result
            .ok()
            .filter(|v| v.is_string())
            .map(|v| v.to_str().to_string())
            .filter(|v| v.len() <= 256 * 1024)
            .and_then(|v| serde_json::from_str::<Layout>(&v).ok());
        let geometry = layout.and_then(|v| Geometry::checked(v.width, v.height, v.masks).ok());
        if geometry.is_none() || !target.valid() {
            finish(target, prepared_ticket, completion, None);
            return;
        }
        let owner = target.clone();
        let ack = target.callbacks.begin();
        let lease = target.callbacks.lifetimes().block();
        target.view.snapshot(
            SnapshotRegion::Visible,
            SnapshotOptions::NONE,
            None::<&webkit2gtk::gio::Cancellable>,
            move |result| {
                let _held = &lease;
                ack.ack();
                let geometry = geometry.unwrap();
                let data = (|| {
                    if !owner.valid() {
                        return None;
                    }
                    let mut image = cairo::ImageSurface::try_from(result.ok()?).ok()?;
                    let width = u32::try_from(image.width()).ok()?;
                    let height = u32::try_from(image.height()).ok()?;
                    geometry.check_native_size(width, height).ok()?;
                    if image.format() != cairo::Format::ARgb32 {
                        return None;
                    }
                    let stride = usize::try_from(image.stride()).ok()?;
                    if stride < width as usize * 4
                        || stride.checked_mul(height as usize)? > MAX_NATIVE_PIXELS as usize * 4
                    {
                        return None;
                    }
                    image.flush();
                    let bytes = image.data().ok()?.to_vec();
                    Some(Data::Argb32 {
                        width,
                        height,
                        stride,
                        bytes,
                    })
                })();
                let pixels = data.map(|data| Pixels { data, geometry });
                finish(owner, prepared_ticket, completion, pixels);
            },
        );
    });
}
fn finish(source: Rc<Source>, ticket: String, completion: Completion, pixels: Option<Pixels>) {
    let owner = source.clone();
    source.evaluate(mask::FINISH, &ticket, false, move |result| {
        let valid =
            result.is_ok_and(|value| value.is_boolean() && value.to_boolean()) && owner.valid();
        completion(if valid {
            pixels.ok_or("Native snapshot failed")
        } else {
            Err("Snapshot document changed or was cancelled")
        });
    });
}
