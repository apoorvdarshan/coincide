//! Trusted native rendered-selection data, never a JSON text/clipboard request.
//! The native caller binds this projection to its owned immutable parse and
//! rechecks renderer focus/revision/selection immediately before Core admission.
use anyhow::{Result, ensure};
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;
pub struct NativeReplySelection {
    pub(crate) item: Uuid,
    pub(crate) source: String,
    source_range: Range<usize>,
    rendered: String,
    rendered_range: Range<usize>,
}
fn range_valid(text: &str, range: &Range<usize>) -> bool {
    range.start < range.end
        && range.end <= text.len()
        && text.is_char_boundary(range.start)
        && text.is_char_boundary(range.end)
        && [range.start, range.end].into_iter().all(|boundary| {
            boundary == text.len()
                || text
                    .grapheme_indices(true)
                    .any(|(index, _)| index == boundary)
        })
}
impl NativeReplySelection {
    pub fn from_native_projection(
        item: &str,
        source: String,
        source_range: Range<usize>,
        rendered: String,
        rendered_range: Range<usize>,
    ) -> Result<Self> {
        ensure!(
            source.len() <= 8 * 1024 * 1024 && rendered.len() <= 8 * 1024 * 1024,
            "Reply selection source exceeds 8 MiB"
        );
        ensure!(
            range_valid(&source, &source_range),
            "Reply selection is not on complete source grapheme boundaries"
        );
        ensure!(
            range_valid(&rendered, &rendered_range),
            "Reply selection is not on complete rendered grapheme boundaries"
        );
        let value = Self {
            item: Uuid::parse_str(item)?,
            source,
            source_range,
            rendered,
            rendered_range,
        };
        value.quote()?;
        Ok(value)
    }
    pub(crate) fn quote(&self) -> Result<&str> {
        ensure!(
            range_valid(&self.source, &self.source_range)
                && range_valid(&self.rendered, &self.rendered_range),
            "Reply selection range changed"
        );
        let quote = self.rendered[self.rendered_range.clone()].trim();
        ensure!(
            !quote.is_empty() && quote.len() <= 16000 && !quote.contains('\0'),
            "Select nonblank reply text of at most 16000 UTF-8 bytes"
        );
        Ok(quote)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selection(
        source: &str,
        source_range: Range<usize>,
        rendered: &str,
        range: Range<usize>,
    ) -> Result<NativeReplySelection> {
        NativeReplySelection::from_native_projection(
            &Uuid::new_v4().to_string(),
            source.into(),
            source_range,
            rendered.into(),
            range,
        )
    }
    #[test]
    fn grapheme_and_utf8_boundaries_reject_partial_unicode_selections() {
        for text in ["cafe\u{301}", "👩🏽‍💻", "🇮🇳", "中文"] {
            assert!(selection(text, 0..text.len(), text, 0..text.len()).is_ok());
            for byte in 1..text.len() {
                let valid = text.grapheme_indices(true).any(|(index, _)| index == byte);
                assert_eq!(
                    selection(text, 0..byte, text, 0..byte).is_ok(),
                    valid,
                    "byte boundary {byte}"
                );
            }
        }
    }
    #[test]
    fn actual_rendered_range_not_repeated_text_search_determines_quote() {
        let source = "first **repeat** and second `repeat`";
        let rendered = "first repeat and second repeat";
        let start = rendered.rfind("repeat").unwrap();
        let source_start = source.rfind("repeat").unwrap();
        let selection = selection(
            source,
            source_start..source_start + 6,
            rendered,
            start..start + 6,
        )
        .unwrap();
        assert_eq!(selection.quote().unwrap(), "repeat");
        assert_eq!(selection.source_range, source_start..source_start + 6);
    }
    #[test]
    fn blank_nul_oversized_reversed_and_out_of_bounds_are_refused() {
        for (source, range) in [
            (" ", 0..1),
            ("a\0b", 0..3),
            ("abc", 2..1),
            ("abc", 0..4),
            ("abc", 0..0),
        ] {
            assert!(selection(source, range.clone(), source, range).is_err());
        }
        let source = "x".repeat(16001);
        assert!(selection(&source, 0..source.len(), &source, 0..source.len()).is_err());
    }
}
