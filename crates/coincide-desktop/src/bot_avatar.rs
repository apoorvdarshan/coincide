//! Bot avatars as GPUI images: `coincide_core::bot_artwork` draws each character
//! as SVG, which GPUI rasterizes in full color on every platform. Images are
//! drawn at three times their size for high-density screens and cached, so a
//! render never redraws or re-decodes the same avatar.
use coincide_core::bot_artwork::{Character, Tint, svg};
use gpui_kit::{Image, ImageFormat, IntoElement, Styled, img, px};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

const PIXEL_SCALE: f32 = 3.;

/// The avatar `side` points wide, cached by look and size.
pub(crate) fn image(character: Character, tint: Tint, side: f32) -> Arc<Image> {
    static CACHE: OnceLock<Mutex<HashMap<(Character, Tint, u32), Arc<Image>>>> = OnceLock::new();
    let key = (character, tint, side.to_bits());
    let mut cache = CACHE
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    cache
        .entry(key)
        .or_insert_with(|| {
            let pixels = (side * PIXEL_SCALE).ceil().max(1.) as u32;
            Arc::new(Image::from_bytes(
                ImageFormat::Svg,
                svg(character, tint, side as f64, pixels, 1.).into_bytes(),
            ))
        })
        .clone()
}

/// The avatar as an element `side` points square.
pub(crate) fn avatar(character: Character, tint: Tint, side: f32) -> impl IntoElement {
    img(image(character, tint, side))
        .w(px(side))
        .h(px(side))
        .flex_none()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_avatar_rasterizes_with_visible_pixels_and_is_cached() {
        let renderer = gpui_kit::SvgRenderer::new(Arc::new(()));
        for character in Character::ALL {
            for side in [16., 26., 56.] {
                let image = image(character, character.default_tint(), side);
                assert!(Arc::ptr_eq(
                    &image,
                    &super::image(character, character.default_tint(), side)
                ));
                let rendered = image.to_image_data(renderer.clone()).unwrap();
                let pixels = (side * PIXEL_SCALE).ceil() as i32;
                let size = rendered.size(0);
                assert_eq!((size.width.0, size.height.0), (pixels, pixels));
                let bytes = rendered.as_bytes(0).unwrap();
                let opaque = bytes.chunks_exact(4).filter(|pixel| pixel[3] > 0).count();
                // The characters fill a good part of their square.
                assert!(
                    opaque * 4 > bytes.len() / 4,
                    "{character:?} at {side}: {opaque}"
                );
            }
        }
    }
}
