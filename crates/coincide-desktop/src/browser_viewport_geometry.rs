//! Windows child views have integral native-pixel bounds. Select bounds and a
//! continuous page zoom together so their CSS viewport does not lose a row when
//! a fitting height is rounded (for example 400x300 in a 287px-wide panel).
#[derive(Clone, Copy, Debug)]
pub(crate) struct Layout {
    pub width: f32,
    pub height: f32,
    pub zoom: f64,
}
pub(crate) fn aligned(requested: (u32, u32), fit: f64, dpi: f64) -> Option<Layout> {
    if !fit.is_finite()
        || !dpi.is_finite()
        || fit <= 0.
        || dpi <= 0.
        || dpi > 16.
        || requested.0 == 0
        || requested.1 == 0
    {
        return None;
    }
    let (width, height) = (f64::from(requested.0), f64::from(requested.1));
    let ceiling = fit * dpi;
    let (mut pixels_w, mut pixels_h) = ((width * ceiling).floor(), (height * ceiling).floor());
    for _ in 0..1024 {
        if pixels_w < 1. || pixels_h < 1. {
            return None;
        }
        // Keep both CSS extents in [requested, requested+0.49): this is stable
        // under both integer truncation and nearest-integer viewport getters.
        let lower = (pixels_w / (width + 0.49)).max(pixels_h / (height + 0.49));
        let upper = (pixels_w / width).min(pixels_h / height).min(ceiling);
        if lower < upper {
            return Some(Layout {
                width: (pixels_w / dpi) as f32,
                height: (pixels_h / dpi) as f32,
                zoom: ((lower + upper) / 2.) / dpi,
            });
        }
        if pixels_w / width > pixels_h / height {
            pixels_w -= 1.;
        } else {
            pixels_h -= 1.;
        }
    }
    None
}
#[cfg(test)]
mod tests {
    use super::*;
    fn verify(size: (u32, u32), fit: f64, dpi: f64) {
        let layout = aligned(size, fit, dpi).expect("representable fixture viewport");
        let w = (f64::from(layout.width) * dpi).round() / (layout.zoom * dpi);
        let h = (f64::from(layout.height) * dpi).round() / (layout.zoom * dpi);
        assert_eq!((w.floor() as u32, h.floor() as u32), size);
        assert_eq!((w.round() as u32, h.round() as u32), size);
        assert!(layout.zoom <= fit);
        assert!(f64::from(layout.width) <= f64::from(size.0) * fit + 0.001);
        assert!(f64::from(layout.height) <= f64::from(size.1) * fit + 0.001);
    }
    #[test]
    fn narrow_panel_keeps_exact_four_hundred_by_three_hundred() {
        // The old 287/400 zoom rounded 215.25px to 215, producing 299 CSS rows.
        for width in 280..=300 {
            for dpi in [1., 1.25, 1.5, 2., 2.5, 3.] {
                verify((400, 300), f64::from(width) / 400., dpi);
            }
        }
    }
    #[test]
    fn all_presets_preserve_css_dimensions_at_common_native_scales() {
        for size in [(390, 844), (820, 1180), (1280, 860)] {
            for dpi in [1., 1.25, 1.5, 2.] {
                verify(
                    size,
                    (287. / f64::from(size.0)).min(462. / f64::from(size.1)),
                    dpi,
                );
            }
        }
    }
    #[test]
    fn invalid_or_unrepresentable_geometry_is_not_claimed_aligned() {
        assert!(aligned((400, 300), 0.7, 0.).is_none());
        assert!(aligned((0, 300), 1., 1.).is_none());
        assert!(aligned((2560, 2559), 0.1, 1.).is_none());
    }
}
