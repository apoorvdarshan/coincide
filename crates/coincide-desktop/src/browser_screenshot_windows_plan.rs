//! Closed viewport request data; native source/isolated-context proof is
//! separately mandatory. No caller-supplied SDK method or allocation override.
use base64::Engine as _;
use coincide_core::browser_screenshot::{MAX_NATIVE_PIXELS, MAX_PNG_BYTES};
use serde_json::{Value, json};
pub(super) const MAX_CAPTURE_REPLY: usize = MAX_PNG_BYTES.div_ceil(3) * 4 + 1024;
pub(super) fn viewport(
    width: f64,
    height: f64,
    x: f64,
    y: f64,
    raster: f64,
    zoom: f64,
) -> Option<Value> {
    if ![width, height, x, y, raster, zoom]
        .into_iter()
        .all(f64::is_finite)
        || width <= 0.
        || height <= 0.
        || width > 20000.
        || height > 20000.
        || x.abs() > 1_000_000.
        || y.abs() > 1_000_000.
        || !(0.25..=4.).contains(&raster)
        || !(0.25..=5.).contains(&zoom)
    {
        return None;
    }
    let native_scale = raster * zoom;
    // Reserve rounding room before requesting the SDK's fixed clip. Native
    // scale/geometry changes revoke output; this does not impose a process-wide
    // hard quota on undocumented SDK compositor allocations.
    let scale = (1600. / (width * native_scale)).min(1.).min(
        ((MAX_NATIVE_PIXELS - 40_000) as f64 / (width * height * native_scale * native_scale))
            .sqrt(),
    );
    if !scale.is_finite() || scale <= 0. {
        return None;
    }
    Some(
        json!({"format":"png","fromSurface":true,"captureBeyondViewport":false,"clip":{"x":x,"y":y,"width":width,"height":height,"scale":scale}}),
    )
}
pub(super) fn png_reply(value: &Value) -> Option<Vec<u8>> {
    value["data"]
        .as_str()
        .filter(|v| v.len() <= MAX_PNG_BYTES.div_ceil(3) * 4)
        .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
        .filter(|v| v.len() <= MAX_PNG_BYTES && v.starts_with(b"\x89PNG\r\n\x1a\n"))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fixed_sdk_clip_is_bounded_and_has_no_remote_path_or_script_input() {
        for (width, height, raster, zoom) in [
            (800., 600., 1., 1.),
            (20000., 20000., 4., 5.),
            (2000., 18000., 2., 1.5),
        ] {
            let p = viewport(width, height, 10., 20., raster, zoom).unwrap();
            assert_eq!(p.as_object().unwrap().len(), 4);
            assert_eq!(p["format"], "png");
            assert_eq!(p["captureBeyondViewport"], false);
            assert_eq!(p["fromSurface"], true);
            let scale = p["clip"]["scale"].as_f64().unwrap();
            let pixels_x = (width * raster * zoom * scale).ceil();
            let pixels_y = (height * raster * zoom * scale).ceil();
            assert!(pixels_x <= 1601. && pixels_x * pixels_y <= MAX_NATIVE_PIXELS as f64);
            assert_eq!(p["clip"]["x"], 10.);
            assert_eq!(p["clip"]["y"], 20.);
        }
        for number in [f64::NAN, f64::INFINITY, -1., 0., 20001.] {
            assert!(viewport(number, 1., 0., 0., 1., 1.).is_none());
        }
        assert!(viewport(1., 1., 0., 0., 8., 1.).is_none());
        assert!(viewport(1., 1., 0., 0., 1., 6.).is_none());
    }
    #[test]
    fn only_bounded_png_sdk_data_is_accepted() {
        assert_eq!(MAX_CAPTURE_REPLY, MAX_PNG_BYTES.div_ceil(3) * 4 + 1024);
        assert!(png_reply(&json!({"data":"not base64"})).is_none());
        assert!(
            png_reply(
                &json!({"data":base64::engine::general_purpose::STANDARD.encode(b"not PNG")})
            )
            .is_none()
        );
        let png = coincide_core::appshots::encode_rgba(1, 1, vec![0; 4]).unwrap();
        assert_eq!(
            png_reply(&json!({"data":base64::engine::general_purpose::STANDARD.encode(&png)}))
                .unwrap(),
            png
        );
    }
}
