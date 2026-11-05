//! Preserve the pinned native TextView's selection, Markdown, focus and keyed
//! state. Only wrap the message-body TextView, not its action buttons or media.
//!
//! TextView::markdown is already selectable in gpui-base 0.9.0; Kit's Root mounts
//! TextSelectionLayer. Its Copy handlers trim selected_text(), losing whitespace.
//! Capture Copy inside the body subtree before those handlers. Empty selection
//! propagates normally; a whitespace-only selection is valid clipboard content.
use gpui_kit::{
    base::{TextSelection, input::Copy},
    *,
};

fn selection_id(thread: &str, item: &str) -> SharedString {
    // Semantic IDs, never the virtualized row index. Length framing prevents
    // separators inside imported identities from creating ambiguous keys.
    format!(
        "message-selection/{}:{thread}/{}:{item}",
        thread.len(),
        item.len()
    )
    .into()
}

fn copy_payload(selected: String) -> Option<String> {
    if selected.is_empty() {
        None
    } else {
        Some(selected)
    }
}

/// Mount around the existing styled TextView::markdown expression. Native drag,
/// Shift extension and Select All still select/project the rendered Markdown;
/// clipboard copy preserves exactly that projection (Plain or Source format).
/// This does not implement cross-message/offscreen range selection.
pub fn preserve_selected_copy(
    thread: &str,
    item: &str,
    body: impl IntoElement,
) -> impl IntoElement {
    div()
        .id(selection_id(thread, item))
        .min_w_0()
        .capture_action(|_: &Copy, window, cx| {
            match copy_payload(TextSelection::selected_text(window, cx)) {
                Some(text) => cx.write_to_clipboard(ClipboardItem::new_string(text)),
                None => cx.propagate(),
            }
        })
        .child(body)
}

#[cfg(test)]
mod tests {
    use super::{copy_payload, selection_id};

    #[test]
    fn full_markdown_source_copy_preserves_bytes_and_whitespace() {
        let source = "\n  # café 中文\n\n**bold** and `x`\n\n```rust\n  let x = \"👩🏽‍💻\";\n```\n\n";
        assert_eq!(
            copy_payload(source.into()).unwrap().as_bytes(),
            source.as_bytes()
        );
    }

    #[test]
    fn partial_unicode_range_copy_does_not_trim_normalize_or_expand() {
        let rendered = "prefix:  e\u{301} 中文 👩🏽‍💻\n\t: suffix";
        let start = rendered.find("  e").unwrap();
        let end = rendered.find(": suffix").unwrap();
        let selection = rendered.get(start..end).unwrap();
        assert_eq!(
            copy_payload(selection.into()).as_deref(),
            Some("  e\u{301} 中文 👩🏽‍💻\n\t")
        );
        // The native projector owns UTF-8 ranges; the copy path takes its exact
        // valid String and never rounds/normalizes a Unicode byte boundary.
        assert!(!rendered.is_char_boundary(rendered.find('中').unwrap() + 1));
    }

    #[test]
    fn whitespace_only_selection_is_copied_but_empty_selection_propagates() {
        assert_eq!(copy_payload(" \t\r\n".into()), Some(" \t\r\n".into()));
        assert_eq!(copy_payload(String::new()), None);
    }

    #[test]
    fn equal_rendered_occurrences_copy_only_the_projected_range() {
        let source = "**中文** then `中文`\n";
        let start = source.find('`').unwrap();
        let end = source.rfind('`').unwrap() + 1;
        assert_eq!(
            copy_payload(source[start..end].into()).as_deref(),
            Some("`中文`")
        );
    }

    #[test]
    fn identity_is_stable_per_thread_item_and_not_a_row_index() {
        assert_eq!(
            selection_id("thread", "item"),
            selection_id("thread", "item")
        );
        assert_ne!(
            selection_id("thread-a", "item"),
            selection_id("thread-b", "item")
        );
        assert_ne!(
            selection_id("thread", "item-a"),
            selection_id("thread", "item-b")
        );
        assert_ne!(selection_id("a/b", "c"), selection_id("a", "b/c"));
        assert_ne!(selection_id("中文", "item"), selection_id("中", "文/item"));
    }
}
