//! Trusted native rendered-selection data, never a JSON text/clipboard request.
//! The native caller binds this projection to its owned immutable parse and
//! rechecks renderer focus/revision/selection immediately before Core admission.
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::ops::Range;
use unicode_segmentation::GraphemeCursor;
use uuid::Uuid;
pub struct NativeReplySelection {
    pub(crate) item: Uuid,
    card_id: Uuid,
    pub(crate) source: String,
    pub(crate) source_kind: String,
    #[cfg(test)]
    source_range: Range<usize>,
    quote: String,
}
fn range_valid(text: &str, range: &Range<usize>) -> bool {
    range.start < range.end
        && range.end <= text.len()
        && text.is_char_boundary(range.start)
        && text.is_char_boundary(range.end)
        && [range.start, range.end].into_iter().all(|boundary| {
            GraphemeCursor::new(boundary, text.len(), true)
                .is_boundary(text, 0)
                .unwrap_or(false)
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
        Self::from_native_message_projection(
            item,
            source,
            source_range,
            rendered,
            rendered_range,
            "assistant",
        )
    }
    pub fn from_native_message_projection(
        item: &str,
        source: String,
        source_range: Range<usize>,
        rendered: String,
        rendered_range: Range<usize>,
        source_kind: &str,
    ) -> Result<Self> {
        ensure!(
            crate::composer_context::quotable_kind(source_kind),
            "Unsupported message kind"
        );
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
        let quote = rendered[rendered_range].trim();
        ensure!(
            !quote.is_empty() && quote.len() <= 16_000 && !quote.contains('\0'),
            "Select nonblank reply text of at most 16000 UTF-8 bytes"
        );
        Ok(Self {
            item: Uuid::parse_str(item)?,
            card_id: Uuid::new_v4(),
            source,
            source_kind: source_kind.into(),
            #[cfg(test)]
            source_range,
            quote: quote.into(),
        })
    }
    /// Display this card while the engine verifies the captured source and saves it.
    pub fn reference_preview(&self, provider: &Value) -> Result<Value> {
        crate::composer_context::quote_card(
            &json!({"id":self.item,"kind":self.source_kind,"text":self.quote,"provider":provider}),
            self.card_id,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use unicode_segmentation::UnicodeSegmentation;
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
        assert_eq!(selection.quote, "repeat");
        assert_eq!(selection.source_range, source_start..source_start + 6);
    }
    #[test]
    fn blank_nul_oversized_reversed_and_out_of_bounds_are_refused() {
        for (source, range) in [
            (" ", 0..1),
            ("a\0b", 0..3),
            ("abc", std::ops::Range { start: 2, end: 1 }),
            ("abc", 0..4),
            ("abc", 0..0),
        ] {
            assert!(selection(source, range.clone(), source, range).is_err());
        }
        let source = "x".repeat(16001);
        assert!(selection(&source, 0..source.len(), &source, 0..source.len()).is_err());
    }
}
