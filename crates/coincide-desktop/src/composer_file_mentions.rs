//! Pure current-word proof; native IME/history/editing stay with TextareaState.
use super::Binding;
use gpui_kit::component::input::{InlineToken, InputContent};
use std::ops::Range;
#[derive(Clone, PartialEq)]
pub(super) struct Ticket {
    pub binding: Binding,
    pub selection: Range<usize>,
    pub range: Range<usize>,
    pub query: String,
    pub revision: u64,
}
#[derive(Default)]
pub(super) struct Revision {
    value: u64,
    observed: Option<(String, Range<usize>, bool)>,
}
impl Revision {
    pub fn get(&self) -> u64 {
        self.value
    }
    pub fn text_changed(&mut self) {
        self.value = self.value.wrapping_add(1);
    }
    pub fn observe(&mut self, text: String, selection: Range<usize>, reversed: bool) -> bool {
        let current = (text, selection, reversed);
        if self.observed.as_ref() == Some(&current) {
            return false;
        }
        self.text_changed();
        self.observed = Some(current);
        true
    }
}
pub(super) fn detect(
    text: &str,
    selection: Range<usize>,
    marked: bool,
    token_ranges: &[Range<usize>],
) -> Option<(Range<usize>, String)> {
    if marked
        || text.len() > 1024 * 1024
        || selection.start != selection.end
        || selection.end > text.len()
        || !text.is_char_boundary(selection.end)
    {
        return None;
    }
    let prefix = &text[..selection.end];
    let start = prefix
        .char_indices()
        .rev()
        .find(|(_, c)| c.is_whitespace())
        .map_or(0, |(index, c)| index + c.len_utf8());
    let word = &prefix[start..];
    let query = word.strip_prefix('@')?;
    if query.len() > 256 || query.chars().any(char::is_control) {
        return None;
    }
    let range = start..selection.end;
    if token_ranges
        .iter()
        .any(|token| token.start < range.end && range.start < token.end)
    {
        return None;
    }
    // This public, pure constructor validates the pinned toolkit's grapheme
    // boundaries without installing a token or mutating native input state.
    InputContent::new(text)
        .with_token(
            range.clone(),
            InlineToken::new("file-mention-range-proof", word),
        )
        .ok()?;
    Some((range, query.to_owned()))
}
pub(super) fn removal(text: &str, range: Range<usize>) -> Option<(String, Range<usize>)> {
    let (actual, _) = detect(text, range.end..range.end, false, &[])?;
    if actual != range {
        return None;
    }
    let utf16 =
        text[..range.start].encode_utf16().count()..text[..range.end].encode_utf16().count();
    let mut next = text.to_owned();
    next.replace_range(range, "");
    Some((next, utf16))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn unicode_trigger_range_and_utf16_removal_preserve_every_surrounding_byte() {
        let text = "👩🏽‍💻 café @src/中文 suffix";
        let caret = text.find(" suffix").unwrap();
        let before = text.to_owned();
        let (range, query) = detect(text, caret..caret, false, &[]).unwrap();
        assert_eq!(query, "src/中文");
        assert_eq!(&text[range.clone()], "@src/中文");
        let (next, utf16) = removal(text, range.clone()).unwrap();
        assert_eq!(next, "👩🏽‍💻 café  suffix");
        assert_eq!(utf16.start, text[..range.start].encode_utf16().count());
        assert_eq!(utf16.end, text[..caret].encode_utf16().count());
        assert_eq!(text, before);
    }
    #[::core::prelude::v1::test]
    fn blink_notifications_are_stable_but_caret_and_same_text_roundtrips_revoke_tickets() {
        let mut revision = Revision::default();
        assert!(revision.observe("@file".into(), 5..5, false));
        let initial = revision.get();
        for _ in 0..3 {
            assert!(!revision.observe("@file".into(), 5..5, false));
            assert_eq!(revision.get(), initial);
        }
        assert!(revision.observe("@file".into(), 4..4, false));
        assert!(revision.observe("@file".into(), 5..5, false));
        assert_ne!(revision.get(), initial);
        let before = revision.get();
        revision.text_changed();
        revision.text_changed();
        assert_ne!(revision.get(), before);
        assert!(!revision.observe("@file".into(), 5..5, false));
    }
    #[::core::prelude::v1::test]
    fn ime_noncollapsed_email_slash_and_partial_graphemes_are_never_replaced() {
        for (text, selection, marked) in [
            ("@file", 5..5, true),
            ("@file", 0..5, false),
            ("mail user@example.test", 22..22, false),
            ("/plan", 5..5, false),
            ("@e\u{301}", 2..2, false),
            ("@👩\u{200d}💻", 5..5, false),
        ] {
            let before = text.to_owned();
            assert!(detect(text, selection, marked, &[]).is_none());
            assert_eq!(text, before);
        }
        assert!(detect("@e\u{301}", 4..4, false, &[]).is_some());
        assert!(detect("@👩\u{200d}💻", 12..12, false, &[]).is_some());
        assert!(detect("@file", 5..5, false, &[0..5]).is_none());
        assert!(removal("other @file", 0..11).is_none());
    }
}
