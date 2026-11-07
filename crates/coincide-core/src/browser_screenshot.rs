//! Data-only bounds and redaction for native WebView snapshots.
//!
//! A layout receipt is untrusted page data, never permission to capture a view.
//! The desktop owner must additionally bind its actual native view, thread,
//! navigation, private-world mask transaction and actual SDK completion. Nothing
//! here invokes JavaScript, reads a file, captures a desktop or starts a process.
#[path = "browser_screenshot_artifact.rs"]
pub mod artifact;
#[path = "browser_screenshot_mask.rs"]
pub mod mask;

use anyhow::{Result, ensure};
use image::{ExtendedColorType, ImageEncoder, ImageFormat, ImageReader, codecs::png::PngEncoder};
use serde::Deserialize;
use std::io::{Cursor, Write};

pub const MAX_OUTPUT_WIDTH: u32 = 1600;
pub const MAX_CSS_HEIGHT: u32 = 20_000;
pub const MAX_NATIVE_PIXELS: u64 = 8_000_000;
pub const MAX_PNG_BYTES: usize = 16 * 1024 * 1024;
const MAX_NATIVE_EDGE: u32 = 20_000;
const MAX_MASKS: usize = 2048;
const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

/// Coordinates are CSS pixels in the native snapshot's original rectangle,
/// not screen coordinates. Negative/offscreen coordinates are clipped only
/// after every component has passed finite/range checks.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    fn valid(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .into_iter()
            .all(|n| n.is_finite() && n.abs() <= 1_000_000.)
            && self.width >= 0.
            && self.height >= 0.
    }
}

/// This is intentionally not serializable and contains no authority or path.
/// Construct only after a private-world, native-source-bound layout response;
/// the constructor still treats every number as hostile.
#[derive(Clone, Debug)]
pub struct Geometry {
    width: f64,
    height: f64,
    masks: Vec<Rect>,
}
impl Geometry {
    pub fn checked(width: f64, height: f64, masks: Vec<Rect>) -> Result<Self> {
        ensure!(
            width.is_finite()
                && height.is_finite()
                && width > 0.
                && width <= f64::from(MAX_NATIVE_EDGE)
                && height > 0.
                && height <= f64::from(MAX_CSS_HEIGHT),
            "WebView snapshot geometry exceeds bounds"
        );
        ensure!(masks.len() <= MAX_MASKS, "Too many snapshot privacy masks");
        ensure!(
            masks.iter().all(|mask| mask.valid()),
            "Invalid snapshot privacy mask"
        );
        Ok(Self {
            width,
            height,
            masks,
        })
    }
    /// Native allocation must be bounded *before* asking the SDK to render.
    /// A renderer-supplied size alone cannot satisfy that requirement. In
    /// particular GTK FullDocument has no clipped/allocation-bounded overload.
    pub fn check_native_size(&self, width: u32, height: u32) -> Result<()> {
        ensure!(
            width > 0
                && height > 0
                && width <= MAX_NATIVE_EDGE
                && height <= MAX_NATIVE_EDGE
                && u64::from(width) * u64::from(height) <= MAX_NATIVE_PIXELS,
            "Native WebView snapshot allocation exceeds bounds"
        );
        // SDK output may round a fractional point by at most one device pixel.
        let sx = f64::from(width) / self.width;
        let sy = f64::from(height) / self.height;
        ensure!(
            sx.is_finite()
                && sy.is_finite()
                && sx > 0.
                && sy > 0.
                && (sx - sy).abs() <= 1. / self.width + 1. / self.height,
            "Native snapshot no longer matches its layout rectangle"
        );
        Ok(())
    }
}

pub struct Png {
    bytes: Vec<u8>,
    width: u32,
    height: u32,
}
impl Png {
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }
}

/// Decode only a bounded PNG from an actual native callback; never write the
/// original unredacted bytes. Mask BEFORE downsampling so interpolation cannot
/// blend secret pixels into the redacted image's edge.
pub fn redact_png(bytes: &[u8], geometry: &Geometry) -> Result<Png> {
    ensure!(
        bytes.len() <= MAX_PNG_BYTES && bytes.starts_with(PNG_SIGNATURE),
        "Invalid native snapshot PNG"
    );
    let reader = || ImageReader::with_format(Cursor::new(bytes), ImageFormat::Png);
    let (width, height) = reader().into_dimensions()?;
    geometry.check_native_size(width, height)?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_NATIVE_EDGE);
    limits.max_image_height = Some(MAX_NATIVE_EDGE);
    limits.max_alloc = Some(MAX_NATIVE_PIXELS * 8);
    let mut decoder = reader();
    decoder.limits(limits);
    let rgba = decoder.decode()?.into_rgba8().into_raw();
    redact_rgba(width, height, rgba, geometry)
}

/// Cairo ARGB32 is native-endian premultiplied data. Convert on the owned
/// encoder worker; never expose hidden RGB from fully transparent pixels.
pub fn redact_argb32(
    width: u32,
    height: u32,
    stride: usize,
    bytes: &[u8],
    geometry: &Geometry,
) -> Result<Png> {
    geometry.check_native_size(width, height)?;
    ensure!(
        stride >= width as usize * 4
            && stride.checked_mul(height as usize) == Some(bytes.len())
            && bytes.len() <= MAX_NATIVE_PIXELS as usize * 4,
        "Invalid native ARGB32 pixels"
    );
    let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
    for row in bytes.chunks_exact(stride) {
        for pixel in row[..width as usize * 4].as_chunks::<4>().0 {
            let argb = u32::from_ne_bytes(*pixel);
            let alpha = (argb >> 24) as u8;
            let channel = |shift: u32| {
                let value = ((argb >> shift) & 255u32) as u16;
                if alpha == 0 {
                    0
                } else {
                    ((value * 255 + u16::from(alpha) / 2) / u16::from(alpha)).min(255) as u8
                }
            };
            rgba.extend_from_slice(&[channel(16), channel(8), channel(0), alpha]);
        }
    }
    redact_rgba(width, height, rgba, geometry)
}

pub fn redact_rgba(width: u32, height: u32, mut rgba: Vec<u8>, geometry: &Geometry) -> Result<Png> {
    geometry.check_native_size(width, height)?;
    ensure!(
        rgba.len() == width as usize * height as usize * 4,
        "Invalid native snapshot pixels"
    );
    let sx = f64::from(width) / geometry.width;
    let sy = f64::from(height) / geometry.height;
    for mask in &geometry.masks {
        // Include a one-device-pixel guard around each sensitive rectangle;
        // fractional geometry and antialiasing must not expose border pixels.
        let x0 = (mask.x * sx).floor().max(0.) as u32;
        let y0 = (mask.y * sy).floor().max(0.) as u32;
        let x1 = ((mask.x + mask.width) * sx)
            .ceil()
            .max(0.)
            .min(f64::from(width)) as u32;
        let y1 = ((mask.y + mask.height) * sy)
            .ceil()
            .max(0.)
            .min(f64::from(height)) as u32;
        if x0 >= x1 || y0 >= y1 {
            continue;
        }
        for y in y0.saturating_sub(1)..y1.saturating_add(1).min(height) {
            for x in x0.saturating_sub(1)..x1.saturating_add(1).min(width) {
                let offset = (y as usize * width as usize + x as usize) * 4;
                rgba[offset..offset + 4].copy_from_slice(&[32, 32, 32, 255]);
            }
        }
    }
    let image = image::RgbaImage::from_raw(width, height, rgba).expect("checked exact RGBA size");
    let image = if width > MAX_OUTPUT_WIDTH {
        let output_height =
            (u64::from(height) * u64::from(MAX_OUTPUT_WIDTH)).div_ceil(u64::from(width)) as u32;
        image::imageops::resize(
            &image,
            MAX_OUTPUT_WIDTH,
            output_height,
            image::imageops::FilterType::Triangle,
        )
    } else {
        image
    };
    // The writer refuses excess bytes during encoding rather than allocating
    // an unbounded Vec and checking only after completion.
    let mut output = BoundedPng(Vec::new());
    PngEncoder::new(&mut output).write_image(
        image.as_raw(),
        image.width(),
        image.height(),
        ExtendedColorType::Rgba8,
    )?;
    Ok(Png {
        bytes: output.0,
        width: image.width(),
        height: image.height(),
    })
}
struct BoundedPng(Vec<u8>);
impl Write for BoundedPng {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > MAX_PNG_BYTES.saturating_sub(self.0.len()) {
            return Err(std::io::Error::other("Snapshot PNG exceeds 16 MiB"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_argb_premultiplication_and_transparent_pixels_are_safe() {
        let geometry = Geometry::checked(2., 1., vec![]).unwrap();
        let bytes = [0x80804020u32.to_ne_bytes(), 0x00ffffffu32.to_ne_bytes()].concat();
        let png = redact_argb32(2, 1, 8, &bytes, &geometry).unwrap();
        let image = image::load_from_memory_with_format(png.bytes(), ImageFormat::Png)
            .unwrap()
            .into_rgba8();
        assert_eq!(image.get_pixel(0, 0).0, [255, 128, 64, 128]);
        assert_eq!(image.get_pixel(1, 0).0, [0; 4]);
        assert!(redact_argb32(2, 1, 4, &bytes, &geometry).is_err());
    }
    #[test]
    fn hostile_geometry_and_native_allocation_refused_before_decode() {
        for width in [f64::NAN, f64::INFINITY, -1., 0., 20_001.] {
            assert!(Geometry::checked(width, 1., vec![]).is_err());
        }
        assert!(Geometry::checked(10., 20_001., vec![]).is_err());
        assert!(
            Geometry::checked(
                10.,
                10.,
                vec![Rect {
                    x: f64::NAN,
                    y: 0.,
                    width: 1.,
                    height: 1.
                }]
            )
            .is_err()
        );
        let geometry = Geometry::checked(1000., 1000., vec![]).unwrap();
        assert!(geometry.check_native_size(4000, 4000).is_err());
        assert!(geometry.check_native_size(1000, 999).is_ok());
        assert!(geometry.check_native_size(1000, 990).is_err());
        assert!(redact_png(b"not PNG", &geometry).is_err());
    }
    #[test]
    fn masks_cover_fractional_edges_and_png_contains_only_redacted_pixels() {
        let geometry = Geometry::checked(
            8.,
            8.,
            vec![Rect {
                x: 2.2,
                y: 2.2,
                width: 1.1,
                height: 1.1,
            }],
        )
        .unwrap();
        let png = redact_rgba(8, 8, vec![255; 8 * 8 * 4], &geometry).unwrap();
        let image = image::load_from_memory_with_format(png.bytes(), ImageFormat::Png)
            .unwrap()
            .into_rgba8();
        for y in 1..5 {
            for x in 1..5 {
                assert_eq!(image.get_pixel(x, y).0, [32, 32, 32, 255]);
            }
        }
        assert_eq!(image.get_pixel(0, 0).0, [255; 4]);
        assert_eq!((png.width(), png.height()), (8, 8));
    }
    #[test]
    fn bounded_resize_clipping_and_encoder_limit() {
        let geometry = Geometry::checked(
            2000.,
            2.,
            vec![Rect {
                x: -10.,
                y: -10.,
                width: 3000.,
                height: 30.,
            }],
        )
        .unwrap();
        let png = redact_rgba(2000, 2, vec![255; 2000 * 2 * 4], &geometry).unwrap();
        assert_eq!((png.width(), png.height()), (1600, 2));
        let image = image::load_from_memory_with_format(png.bytes(), ImageFormat::Png)
            .unwrap()
            .into_rgba8();
        assert!(image.pixels().all(|p| p.0 == [32, 32, 32, 255]));
        let mut writer = BoundedPng(vec![0; MAX_PNG_BYTES - 1]);
        assert!(writer.write_all(&[1, 2]).is_err());
        assert_eq!(writer.0.len(), MAX_PNG_BYTES - 1);
        assert!(
            redact_rgba(
                1,
                1,
                vec![0; 3],
                &Geometry::checked(1., 1., vec![]).unwrap()
            )
            .is_err()
        );
    }
}
