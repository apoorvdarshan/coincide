//! A bot's avatar, drawn from the same vector data as Swift's `BotArtwork` (and
//! the Windows runtime's SVG port): its character in its tint. The saved
//! `avatar` uses Swift's keys; unknown or legacy values read as Swift does.
use super::*;
use crate::bot_artwork_data::{Draw, PATHS, SETS};
use std::{
    collections::{BTreeSet, HashMap},
    fmt::Write as _,
    sync::Mutex,
};

const CHARACTERS: [&str; 7] = [
    "alien",
    "star",
    "croissant",
    "bomboloni",
    "cherry",
    "teddy",
    "brulee",
];
const TINTS: [&str; 11] = [
    "sunflower",
    "tangerine",
    "coral",
    "cherry",
    "rose",
    "lilac",
    "sky",
    "mint",
    "leaf",
    "sage",
    "caramel",
];
/// Rasterized above the drawn size, so the image stays sharp on HiDPI displays.
const OVERSAMPLE: f32 = 3.;

/// Earlier versions saved plain body shapes; each reads as the closest character.
fn legacy_shape(raw: &str) -> Option<&'static str> {
    Some(match raw {
        "blob" => "alien",
        "pebble" => "croissant",
        "cloud" => "teddy",
        "drop" => "brulee",
        "bean" | "sprout" => "cherry",
        "bun" => "bomboloni",
        _ => return None,
    })
}

/// The color a character starts with, Swift's `Shape.defaultTint`.
fn default_tint(character: &str) -> &'static str {
    match character {
        "star" | "bomboloni" => "sunflower",
        "croissant" => "tangerine",
        "cherry" => "cherry",
        "teddy" => "caramel",
        "brulee" => "rose",
        _ => "leaf",
    }
}

/// The character and tint a saved avatar shows, as Swift's lenient decoder.
pub(super) fn look(avatar: &Value) -> (&'static str, &'static str) {
    let raw = avatar["shape"].as_str().unwrap_or_default();
    let character = CHARACTERS
        .iter()
        .copied()
        .find(|character| *character == raw)
        .or_else(|| legacy_shape(raw))
        .unwrap_or("alien");
    let tint = avatar["tint"].as_str().unwrap_or_default();
    let tint = TINTS
        .iter()
        .copied()
        .find(|known| *known == tint)
        .unwrap_or_else(|| default_tint(character));
    (character, tint)
}

fn number(value: f64) -> String {
    let text = format!("{value:.5}");
    let text = text.trim_end_matches('0').trim_end_matches('.');
    if text.is_empty() || text == "-" {
        "0".into()
    } else {
        text.to_owned()
    }
}

/// The detail level Swift draws for a size: fewer strokes when small.
fn detail(side: f32) -> u32 {
    if side < 20. {
        16
    } else if side < 34. {
        28
    } else {
        100
    }
}

/// SVG for a character in a tint, `pixels` wide, drawn with the detail of
/// `side` points; a port of the Windows runtime's `BotArtwork::svg`.
pub(super) fn svg(character: &str, tint: &str, side: f32, pixels: f32) -> Option<String> {
    let color = TINTS.iter().position(|known| *known == tint)?;
    let detail = detail(side);
    let draws: &[Draw] = SETS
        .iter()
        .find(|(name, level, _)| *name == character && *level == detail)?
        .2;
    let size = number(pixels as f64);
    let mut out = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{size}\" height=\"{size}\" viewBox=\"0 0 100 100\">"
    );
    let clips = draws
        .iter()
        .filter_map(|draw| u16::try_from(draw.clip).ok())
        .collect::<BTreeSet<_>>();
    if !clips.is_empty() {
        out.push_str("<defs>");
        for clip in &clips {
            let _ = write!(
                out,
                "<clipPath id=\"c{clip}\"><path d=\"{}\"/></clipPath>",
                PATHS.get(*clip as usize)?
            );
        }
        out.push_str("</defs>");
    }
    for draw in draws {
        let rgba = draw.colors[color];
        let rgb = rgba >> 8;
        let alpha = number(f64::from(rgba & 255) / 255.);
        let _ = write!(out, "<path d=\"{}\"", PATHS.get(draw.path as usize)?);
        if draw.clip >= 0 {
            let _ = write!(out, " clip-path=\"url(#c{})\"", draw.clip);
        }
        if draw.fill {
            let _ = write!(out, " fill=\"#{rgb:06x}\" fill-opacity=\"{alpha}\"");
        } else {
            let width = f64::from(draw.width).max(f64::from(draw.minimum) * 100. / f64::from(side));
            let _ = write!(
                out,
                " fill=\"none\" stroke=\"#{rgb:06x}\" stroke-opacity=\"{alpha}\" stroke-width=\"{}\" stroke-linecap=\"round\" stroke-linejoin=\"round\"",
                number(width)
            );
        }
        out.push_str("/>");
    }
    out.push_str("</svg>");
    Some(out)
}

/// Rendered avatars by character, tint and drawn size.
type Cache = HashMap<(&'static str, &'static str, u32), Arc<Image>>;

fn image(character: &'static str, tint: &'static str, side: f32) -> Option<Arc<Image>> {
    static CACHE: Mutex<Option<Cache>> = Mutex::new(None);
    let key = (character, tint, side.round() as u32);
    let mut cache = CACHE.lock().ok()?;
    let cache = cache.get_or_insert_with(HashMap::new);
    if let Some(image) = cache.get(&key) {
        return Some(image.clone());
    }
    let pixels = (side * OVERSAMPLE).min(512.);
    let image = Arc::new(Image::from_bytes(
        ImageFormat::Svg,
        svg(character, tint, side, pixels)?.into_bytes(),
    ));
    cache.insert(key, image.clone());
    Some(image)
}

/// The avatar at `side` points, as Swift's `BotAvatarView` in sidebar rows.
pub(super) fn avatar(avatar: &Value, side: f32) -> AnyElement {
    let (character, tint) = look(avatar);
    match image(character, tint, side) {
        Some(image) => img(image)
            .w(px(side))
            .h(px(side))
            .flex_none()
            .into_any_element(),
        None => div()
            .w(px(side))
            .h(px(side))
            .flex_none()
            .child(gpui_kit::assets::IconName::Bot)
            .into_any_element(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn saved_avatars_read_like_swifts_lenient_decoder() {
        assert_eq!(
            look(&json!({"shape":"teddy","tint":"sky"})),
            ("teddy", "sky")
        );
        assert_eq!(look(&json!({"shape":"teddy"})), ("teddy", "caramel"));
        assert_eq!(
            look(&json!({"shape":"blob","tint":"mint"})),
            ("alien", "mint")
        );
        assert_eq!(look(&json!({"shape":"bun"})), ("bomboloni", "sunflower"));
        assert_eq!(
            look(&json!({"shape":"future","tint":"future"})),
            ("alien", "leaf")
        );
        assert_eq!(look(&Value::Null), ("alien", "leaf"));
    }

    #[::core::prelude::v1::test]
    fn every_character_and_tint_renders_bounded_svg_from_valid_data() {
        assert_eq!(SETS.len(), CHARACTERS.len() * 3);
        for path in PATHS {
            assert!(!path.is_empty() && path.len() <= 8192);
            assert!(path.chars().all(|c| "MLCQZ0123456789 .-".contains(c)));
        }
        for character in CHARACTERS {
            for side in [16., 26., 56.] {
                for tint in TINTS {
                    let svg = svg(character, tint, side, side * OVERSAMPLE).unwrap();
                    assert!(svg.starts_with("<svg xmlns=\"http://www.w3.org/2000/svg\""));
                    assert!(svg.ends_with("</svg>") && svg.len() < 128 * 1024);
                    assert_eq!(svg.matches("<svg").count(), 1);
                }
            }
        }
        assert!(svg("alien", "unknown", 26., 78.).is_none());
        assert!(svg("unknown", "leaf", 26., 78.).is_none());
        // The tint changes the body color only where the artwork uses it.
        assert_ne!(
            svg("alien", "leaf", 26., 78.),
            svg("alien", "sky", 26., 78.)
        );
        assert_eq!(detail(16.), 16);
        assert_eq!(detail(26.), 28);
        assert_eq!(detail(52.), 100);
        assert_eq!(number(1.5), "1.5");
        assert_eq!(number(2.0), "2");
        assert_eq!(number(0.0), "0");
    }
}
