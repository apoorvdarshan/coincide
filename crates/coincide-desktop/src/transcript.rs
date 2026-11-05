//! Preserve the pinned native TextView's selection, Markdown, focus and keyed
//! state. Only wrap the message-body TextView, not its action buttons or media.
//!
//! TextView::markdown is already selectable in gpui-base 0.9.0; Kit's Root mounts
//! TextSelectionLayer. Its Copy handlers trim selected_text(), losing whitespace.
//! The selection layer may route Copy outside the message body. Install a Root
//! presentation plugin so the capture handler surrounds both content and layer.
//! Editable inputs retain their own Copy handling.
use gpui_kit::{
    base::{Root, RootPlugin, TextSelection, input::Copy},
    component::text::{TextView, TextViewState},
    *,
};
use std::collections::HashMap;

#[derive(Default)]
struct TranscriptViews {
    views: HashMap<(WindowId, EntityId), WeakEntity<TextViewState>>,
}
impl Global for TranscriptViews {}

// The native entity remains keyed by semantic message identity. This holder
// caches only source text; selection, layout and Markdown stay in TextViewState.
struct NativeBody {
    state: Entity<TextViewState>,
    source: SharedString,
}

pub fn markdown(
    thread: &str,
    item: &str,
    source: impl Into<SharedString>,
    window: &mut Window,
    cx: &mut App,
) -> TextView {
    let source = source.into();
    let key = SharedString::from(format!("native-state/{}", selection_id(thread, item)));
    let body = window.use_keyed_state(key, cx, |_, cx| NativeBody {
        state: cx.new(|cx| TextViewState::markdown(source.as_ref(), cx)),
        source: source.clone(),
    });
    let state = body.update(cx, |body, cx| {
        if body.source != source {
            let appended = !body.source.is_empty() && source.starts_with(body.source.as_ref());
            body.state.update(cx, |state, cx| {
                if !appended {
                    // A pending large reparse must not copy the previous
                    // document's multi-click/select-all override.
                    state.clear_selection(cx);
                }
                state.set_text(source.as_ref(), cx);
            });
            body.source = source;
        }
        body.state.clone()
    });
    let registry = cx.default_global::<TranscriptViews>();
    registry.views.retain(|_, state| state.upgrade().is_some());
    registry.views.insert(
        (window.window_handle().window_id(), state.entity_id()),
        state.downgrade(),
    );
    TextView::new(&state)
}

pub fn init(cx: &mut App) {
    Root::register_plugin(cx, |_, _| ExactSelectionCopy);
}

struct ExactSelectionCopy;
impl Render for ExactSelectionCopy {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        Empty
    }
}
impl RootPlugin for ExactSelectionCopy {
    fn decorate(
        &self,
        surface: AnyElement,
        _: &Root,
        _: &mut Window,
        _: &mut App,
    ) -> impl IntoElement {
        div()
            .size_full()
            .capture_action(|_: &Copy, window, cx| {
                // A stale rendered selection must never steal Copy from a
                // composer, search field, terminal or native web view.
                if !window
                    .context_stack()
                    .iter()
                    .any(|context| context.contains("TextView"))
                {
                    cx.propagate();
                    return;
                }
                let window_id = window.window_handle().window_id();
                let states = cx
                    .try_global::<TranscriptViews>()
                    .map(|registry| {
                        registry
                            .views
                            .iter()
                            .filter(|((owner, _), _)| *owner == window_id)
                            .filter_map(|(_, state)| state.upgrade())
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                let Some(focused) = states
                    .into_iter()
                    .find(|state| state.read(cx).focus_handle().is_focused(window))
                else {
                    cx.propagate();
                    return;
                };
                // Resolve native geometry projections first. The window-level
                // collector drops whitespace-only participants; selected_text
                // also adds a newline after each selected Markdown block, even
                // when only two spaces inside that block were highlighted.
                let mut selected = TextSelection::selected_text(window, cx);
                if TextSelection::has_selection(window, cx) {
                    let state = focused.read(cx);
                    let rendered = state.rendered_text();
                    // Both mappings come from the same committed native parse.
                    // This is the pinned component's public selection mapping,
                    // not a search for repeated text or an inferred byte range.
                    // It preserves real newlines inside the selected span and
                    // excludes only synthetic block separators at its ends.
                    if let Some(exact) = state
                        .selected_source_range()
                        .and_then(|range| rendered.range_for_source(range))
                        .and_then(|range| rendered.as_str().get(range))
                    {
                        selected = exact.to_owned();
                    } else if selected.is_empty() {
                        // Unmapped custom/HTML Markdown nodes still use the
                        // native projection; never guess their source offsets.
                        selected = state.selected_text();
                    }
                }
                match copy_payload(selected) {
                    Some(text) => {
                        cx.write_to_clipboard(ClipboardItem::new_string(text));
                        // Capture handlers propagate by default in pinned GPUI.
                        // Stop the downstream native handler trimming our copy.
                        cx.stop_propagation();
                    }
                    None => cx.propagate(),
                }
            })
            .child(surface)
    }
}

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
/// clipboard copy uses its exact rendered range whenever the native parser
/// supplies a source mapping; unmapped nodes retain the native projection.
/// This does not implement cross-message/offscreen range selection.
pub fn preserve_selected_copy(
    thread: &str,
    item: &str,
    body: impl IntoElement,
) -> impl IntoElement {
    div().id(selection_id(thread, item)).min_w_0().child(body)
}

/// Use a find-owned native state without bypassing the existing exact-copy
/// registry. The parent's typography, media and action siblings remain intact.
pub fn managed_markdown(
    _thread: &str,
    _item: &str,
    state: &Entity<TextViewState>,
    window: &mut Window,
    cx: &mut App,
) -> TextView {
    let registry = cx.default_global::<TranscriptViews>();
    registry.views.retain(|_, state| state.upgrade().is_some());
    registry.views.insert(
        (window.window_handle().window_id(), state.entity_id()),
        state.downgrade(),
    );
    TextView::new(state)
}

/// Apply only to the exact native document captured by the find controller.
/// true means this serial's one-shot reveal request was accepted, not proof of
/// a visible scroll. Parent first mounts/reveals the virtualized stable-ID row.
pub fn apply_find_projection(
    state: &Entity<TextViewState>,
    projection: &super::transcript_find::FindProjection,
    cx: &mut App,
) -> anyhow::Result<bool> {
    if !projection.current() || state.read(cx).rendered_text() != projection.rendered {
        return Ok(false);
    }
    state
        .update(cx, |state, cx| {
            if !projection.highlights_applied() {
                state.set_range_highlights(projection.highlights(), cx)?;
                projection.mark_applied();
            }
            if let Some(range) = projection.reveal_range() {
                state.reveal_range(range, cx)?;
                Ok(projection.mark_revealed())
            } else {
                Ok(false)
            }
        })
        .map_err(|error: gpui_kit::base::RangeHighlightError| {
            anyhow::anyhow!("Native find projection failed: {error:?}")
        })
}

#[cfg(test)]
mod tests {
    use super::{copy_payload, selection_id};

    #[::core::prelude::v1::test]
    fn full_markdown_source_copy_preserves_bytes_and_whitespace() {
        let source = "\n  # café 中文\n\n**bold** and `x`\n\n```rust\n  let x = \"👩🏽‍💻\";\n```\n\n";
        assert_eq!(
            copy_payload(source.into()).unwrap().as_bytes(),
            source.as_bytes()
        );
    }

    #[::core::prelude::v1::test]
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

    #[::core::prelude::v1::test]
    fn whitespace_only_selection_is_copied_but_empty_selection_propagates() {
        assert_eq!(copy_payload(" \t\r\n".into()), Some(" \t\r\n".into()));
        assert_eq!(copy_payload(String::new()), None);
    }

    #[::core::prelude::v1::test]
    fn equal_rendered_occurrences_copy_only_the_projected_range() {
        let source = "**中文** then `中文`\n";
        let start = source.find('`').unwrap();
        let end = source.rfind('`').unwrap() + 1;
        assert_eq!(
            copy_payload(source[start..end].into()).as_deref(),
            Some("`中文`")
        );
    }

    #[::core::prelude::v1::test]
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
