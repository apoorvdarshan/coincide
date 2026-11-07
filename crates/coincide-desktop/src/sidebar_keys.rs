//! Swift's SidebarOutlineView keys: Delete deletes the selected conversations,
//! Down or Return in the search field moves into the results and opens the
//! first, and typing the start of a title selects it (AppKit's type-select).
use super::*;
use gpui_kit::assets::IconName;

#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_sidebar_search, no_json, no_register)]
struct SearchDown;
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_sidebar_search, no_json, no_register)]
struct SearchEnter;

/// Register after Kit's Input bindings, so the search field's Down and Return
/// reach the sidebar first; a declined action falls through to the Input.
pub(super) fn init(cx: &mut App) {
    const CONTEXT: &str = "CoincideSidebarSearch > Input";
    cx.bind_keys([
        KeyBinding::new("down", SearchDown, Some(CONTEXT)),
        KeyBinding::new("enter", SearchEnter, Some(CONTEXT)),
    ]);
}

/// Keys typed within this pause extend the type-select prefix, as in AppKit.
const TYPE_SELECT_PAUSE: Duration = Duration::from_secs(1);

#[derive(Default)]
pub(super) struct TypeSelect {
    typed: String,
    last: Option<Instant>,
}
impl TypeSelect {
    /// The prefix typed so far with `text` added, starting over after a pause.
    fn push(&mut self, text: &str, now: Instant) -> String {
        if self
            .last
            .is_none_or(|last| now.duration_since(last) > TYPE_SELECT_PAUSE)
        {
            self.typed.clear();
        }
        self.typed.push_str(text);
        self.last = Some(now);
        self.typed.clone()
    }
}

/// The first row from the selected one on, wrapping, whose title starts with
/// `prefix`, ignoring case.
fn type_select_match<'a>(
    rows: &[(&'a str, &str)],
    selected: Option<&str>,
    prefix: &str,
) -> Option<&'a str> {
    let prefix = prefix.to_lowercase();
    let start = selected
        .and_then(|id| rows.iter().position(|row| row.0 == id))
        .unwrap_or(0);
    (0..rows.len())
        .map(|offset| rows[(start + offset) % rows.len()])
        .find(|(_, title)| title.to_lowercase().starts_with(&prefix))
        .map(|(id, _)| id)
}

impl Coincide {
    /// The search field, its Down and Return moving into the results.
    pub(super) fn sidebar_search_field(&self, cx: &mut Context<Self>) -> Div {
        div()
            .key_context("CoincideSidebarSearch")
            .capture_action(cx.listener(|this, _: &SearchDown, window, cx| {
                this.sidebar_search_into_results(window, cx)
            }))
            .capture_action(cx.listener(|this, _: &SearchEnter, window, cx| {
                this.sidebar_search_into_results(window, cx)
            }))
            .child(
                Input::new(&self.search)
                    .appearance(false)
                    .bordered(false)
                    .prefix(IconName::Search)
                    .h(px(32.)),
            )
    }
    /// Opens the first result and moves the keyboard into the list. With no
    /// results the field keeps the key.
    fn sidebar_search_into_results(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let first = self
            .bulk_sidebar_binding(cx)
            .rows
            .first()
            .map(|row| row.0.clone());
        let Some(first) = first.filter(|_| !self.thread_bulk.mode) else {
            cx.propagate();
            return;
        };
        self.select(&first, window, cx);
        self.thread_list_focus.focus(window, cx);
    }
    /// Delete and type-select in the conversation list. True when the key was
    /// used.
    pub(super) fn sidebar_list_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let key = &event.keystroke;
        // A focused text field (a form inside the sidebar) keeps its typing.
        if event.prefer_character_input
            || key.modifiers.platform
            || key.modifiers.control
            || key.modifiers.alt
        {
            return false;
        }
        if matches!(key.key.as_str(), "backspace" | "delete") && !key.modifiers.shift {
            let ids = if self.thread_bulk.mode {
                self.thread_bulk.picked.iter().cloned().collect::<Vec<_>>()
            } else {
                self.selected
                    .as_ref()
                    .map(|thread| vec![text(thread, "id")])
                    .unwrap_or_default()
            };
            if ids.is_empty() {
                return false;
            }
            if self.thread_bulk.mode {
                self.thread_bulk.close_selection();
            }
            self.sidebar_delete_threads(ids, cx);
            return true;
        }
        let Some(typed) = key
            .key_char
            .as_deref()
            .filter(|typed| !typed.chars().any(char::is_control))
        else {
            return false;
        };
        if self.thread_bulk.mode
            || (self.sidebar_type_select.typed.is_empty() && typed.trim().is_empty())
        {
            return false;
        }
        let prefix = self.sidebar_type_select.push(typed, Instant::now());
        let rows = self.bulk_sidebar_binding(cx).rows;
        let titles = rows
            .iter()
            .map(|row| {
                let title = self
                    .threads
                    .iter()
                    .find(|thread| thread.id == row.0)
                    .map(|thread| thread.title.as_str())
                    .unwrap_or_default();
                (row.0.as_str(), title)
            })
            .collect::<Vec<_>>();
        let selected = self
            .selected
            .as_ref()
            .and_then(|thread| thread["id"].as_str());
        if let Some(id) = type_select_match(&titles, selected, &prefix).map(str::to_owned) {
            self.select(&id, window, cx);
            self.thread_list_focus.focus(window, cx);
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn type_select_finds_the_title_prefix_from_the_selection_on_and_wraps() {
        let rows = [
            ("1", "Alpha"),
            ("2", "beta tests"),
            ("3", "Bravo"),
            ("4", "Charlie"),
        ];
        assert_eq!(type_select_match(&rows, None, "b"), Some("2"));
        assert_eq!(type_select_match(&rows, Some("3"), "B"), Some("3"));
        assert_eq!(type_select_match(&rows, Some("4"), "a"), Some("1"));
        assert_eq!(type_select_match(&rows, Some("1"), "br"), Some("3"));
        assert_eq!(type_select_match(&rows, None, "delta"), None);
        assert_eq!(type_select_match(&[], None, "a"), None);
    }
    #[::core::prelude::v1::test]
    fn typed_keys_extend_the_prefix_until_a_pause() {
        let start = Instant::now();
        let mut select = TypeSelect::default();
        assert_eq!(select.push("b", start), "b");
        assert_eq!(select.push("r", start + Duration::from_millis(400)), "br");
        assert_eq!(select.push("c", start + Duration::from_millis(1600)), "c");
    }
}
