//! Transcript find uses full native-rendered Markdown text, not sidebar filtering.
//! Native entity/reveal hooks are coordinated with the parent mount owner.
use std::ops::Range;

const MAX_QUERY_CHARS: usize = 256;
const MAX_MATCHES: usize = 10_000;
fn query_text(value: &str) -> String {
    value
        .chars()
        .filter(|ch| *ch != '\0')
        .take(MAX_QUERY_CHARS)
        .collect()
}
/// Lowercase scalar expansion retains original UTF-8 byte boundaries. This is
/// Unicode lowercase matching, not accent folding, regex, or full case folding.
fn match_ranges(text: &str, query: &str, limit: usize) -> (Vec<Range<usize>>, bool) {
    if query.is_empty() {
        return (Vec::new(), false);
    }
    let needle = query.to_lowercase();
    if needle.is_empty() {
        return (Vec::new(), false);
    }
    let mut folded = String::new();
    let mut spans = Vec::new();
    for (start, ch) in text.char_indices() {
        let source = start..start + ch.len_utf8();
        for lower in ch.to_lowercase() {
            let begin = folded.len();
            folded.push(lower);
            spans.push((begin..folded.len(), source.clone()));
        }
    }
    let mut result = Vec::new();
    for (start, found) in folded.match_indices(&needle) {
        let end = start + found.len();
        let first = spans.partition_point(|(range, _)| range.end <= start);
        let last = spans.partition_point(|(range, _)| range.start < end);
        if first >= last {
            continue;
        }
        let range = spans[first].1.start..spans[last - 1].1.end;
        if result.last() == Some(&range) {
            continue;
        }
        if result.len() == limit {
            return (result, true);
        }
        result.push(range);
    }
    (result, false)
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Match {
    item: String,
    range: Range<usize>,
}
#[derive(Default)]
struct Search {
    query: String,
    matches: Vec<Match>,
    active: Option<usize>,
    truncated: bool,
}
impl Search {
    fn rebuild<'a>(&mut self, items: impl IntoIterator<Item = (&'a str, &'a str)>, reset: bool) {
        let previous = if reset {
            None
        } else {
            self.active.and_then(|i| self.matches.get(i)).cloned()
        };
        self.matches.clear();
        self.truncated = false;
        for (item, text) in items {
            let (ranges, truncated) =
                match_ranges(text, &self.query, MAX_MATCHES - self.matches.len());
            self.matches.extend(ranges.into_iter().map(|range| Match {
                item: item.into(),
                range,
            }));
            if truncated {
                self.truncated = true;
                break;
            }
        }
        self.active = previous
            .and_then(|old| self.matches.iter().position(|m| m == &old))
            .or_else(|| (!self.matches.is_empty()).then_some(0));
    }
    /// Do not publish an order-dependent partial document set. Keep the prior
    /// stable match through an async append; a new query discards prior matches.
    fn rebuild_ready<'a>(
        &mut self,
        items: impl IntoIterator<Item = (&'a str, Option<&'a str>)>,
        reset: bool,
    ) -> bool {
        let items = items.into_iter().collect::<Vec<_>>();
        if items.iter().any(|(_, text)| text.is_none()) {
            if reset {
                self.matches.clear();
                self.active = None;
                self.truncated = false;
            }
            return false;
        }
        self.rebuild(
            items
                .into_iter()
                .map(|(id, text)| (id, text.unwrap_or_default())),
            reset,
        );
        true
    }
    fn step(&mut self, next: bool) {
        if self.matches.is_empty() {
            self.active = None;
            return;
        }
        let len = self.matches.len();
        self.active = Some(match self.active {
            Some(i) if next => (i + 1) % len,
            Some(i) => (i + len - 1) % len,
            None => 0,
        });
    }
    fn selected(&self) -> Option<&Match> {
        self.active.and_then(|i| self.matches.get(i))
    }
}

use anyhow::{Result, ensure};
use gpui_kit::{
    base::{Disableable, RangeHighlight, RenderedText},
    component::{
        button::*,
        input::{Input, InputEvent, InputState},
        text::TextViewState,
    },
    *,
};
use std::{
    cell::Cell,
    collections::{HashMap, HashSet},
    rc::Rc,
    time::Duration,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FindItem {
    pub item_id: String,
    pub source: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FindSnapshot {
    pub thread_id: String,
    pub generation: u64,
    pub items: Vec<FindItem>,
}
#[derive(Clone, Debug)]
pub enum FindEvent {
    Reveal {
        thread_id: String,
        item_id: String,
        generation: u64,
        match_serial: u64,
        range: Range<usize>,
    },
    Cleared {
        thread_id: String,
        generation: u64,
        match_serial: u64,
    },
    Dismissed,
}
fn validate_snapshot(s: &FindSnapshot) -> Result<()> {
    ensure!(
        !s.thread_id.is_empty() && s.thread_id.len() <= 512 && !s.thread_id.contains('\0'),
        "Invalid find thread ID"
    );
    ensure!(
        s.items.len() <= 2000,
        "Find supports at most 2000 full messages"
    );
    let mut ids = HashSet::new();
    let mut bytes = 0usize;
    for item in &s.items {
        ensure!(
            !item.item_id.is_empty()
                && item.item_id.len() <= 512
                && !item.item_id.contains('\0')
                && ids.insert(&item.item_id),
            "Invalid/duplicate find item ID"
        );
        ensure!(
            item.source.len() <= 2 * 1024 * 1024,
            "Find message exceeds 2 MiB"
        );
        bytes = bytes
            .saturating_add(item.source.capacity())
            .saturating_add(item.item_id.capacity());
        ensure!(
            bytes <= 16 * 1024 * 1024,
            "Find full-source snapshot exceeds 16 MiB"
        );
    }
    Ok(())
}
fn consume_reveal(validity: &Cell<u64>, serial: u64, receipt: &Cell<bool>) -> bool {
    if validity.get() != serial || receipt.get() {
        return false;
    }
    receipt.set(true);
    true
}
#[derive(Clone)]
pub struct FindProjection {
    pub thread_id: String,
    pub item_id: String,
    pub generation: u64,
    pub match_serial: u64,
    pub(crate) rendered: RenderedText,
    ranges: Vec<Range<usize>>,
    active: Option<Range<usize>>,
    validity: Rc<Cell<u64>>,
    applied: Rc<Cell<bool>>,
    receipt: Rc<Cell<bool>>,
    reveal_requested: bool,
}
impl FindProjection {
    pub(crate) fn current(&self) -> bool {
        self.validity.get() == self.match_serial
    }
    pub(crate) fn highlights(&self) -> Vec<RangeHighlight> {
        self.ranges
            .iter()
            .map(|range| {
                RangeHighlight::new(
                    range.clone(),
                    if self.active.as_ref() == Some(range) {
                        rgba(0xffa500a0)
                    } else {
                        rgba(0xffd54f55)
                    },
                )
            })
            .collect()
    }
    pub(crate) fn highlights_applied(&self) -> bool {
        self.applied.get()
    }
    pub(crate) fn mark_applied(&self) {
        self.applied.set(true);
    }
    pub(crate) fn reveal_range(&self) -> Option<Range<usize>> {
        if self.reveal_requested && !self.receipt.get() {
            self.active.clone()
        } else {
            None
        }
    }
    pub(crate) fn mark_revealed(&self) -> bool {
        consume_reveal(&self.validity, self.match_serial, &self.receipt)
    }
}
struct NativeItem {
    id: String,
    source: String,
    state: Entity<TextViewState>,
    rendered: Option<RenderedText>,
    applied: Rc<Cell<bool>>,
    _observer: Subscription,
}
pub struct TranscriptFind {
    thread: Option<String>,
    generation: u64,
    items: Vec<NativeItem>,
    search: Search,
    input: Entity<InputState>,
    opened: bool,
    restore: Option<FocusHandle>,
    serial: u64,
    validity: Rc<Cell<u64>>,
    receipt: Rc<Cell<bool>>,
    pending: Option<u64>,
    per_item: HashMap<String, Vec<Range<usize>>>,
    dirty: bool,
    error: String,
    _input_events: Subscription,
    _poll: Task<()>,
}
impl EventEmitter<FindEvent> for TranscriptFind {}
impl Drop for TranscriptFind {
    fn drop(&mut self) {
        self.validity.set(self.serial.wrapping_add(1));
    }
}
impl TranscriptFind {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| InputState::new(window, cx).placeholder("Find in this transcript"));
        let input_events =
            cx.subscribe_in(&input, window, |this, _, event, window, cx| match event {
                InputEvent::Change if this.opened => {
                    let raw = this.input.read(cx).value().to_string();
                    let query = query_text(&raw);
                    if raw != query {
                        this.input
                            .update(cx, |input, cx| input.set_value(query.clone(), window, cx));
                    }
                    if this.search.query != query {
                        this.search.query = query;
                        this.rescan(true, true, cx);
                    }
                }
                InputEvent::PressEnter {
                    secondary: false,
                    shift,
                } if this.opened => this.step(!shift, cx),
                _ => {}
            });
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(50))
                    .await;
                if this
                    .update_in(cx, |this, _, cx| {
                        if this.opened && this.dirty {
                            this.rescan(false, false, cx);
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        Self {
            thread: None,
            generation: 0,
            items: Vec::new(),
            search: Search::default(),
            input,
            opened: false,
            restore: None,
            serial: 0,
            validity: Rc::new(Cell::new(0)),
            receipt: Rc::new(Cell::new(false)),
            pending: None,
            per_item: HashMap::new(),
            dirty: false,
            error: String::new(),
            _input_events: input_events,
            _poll: poll,
        }
    }
    fn invalidate(&mut self) {
        self.serial = self.serial.wrapping_add(1);
        self.validity.set(self.serial);
        self.pending = None;
        self.receipt = Rc::new(Cell::new(false));
    }
    fn install(&mut self, s: FindSnapshot, cx: &mut Context<Self>) -> Result<()> {
        validate_snapshot(&s)?;
        if self.thread.as_deref() == Some(s.thread_id.as_str()) {
            ensure!(
                s.generation >= self.generation,
                "Find snapshot generation moved backwards"
            );
            if s.generation == self.generation {
                ensure!(
                    s.items.len() == self.items.len()
                        && s.items
                            .iter()
                            .zip(&self.items)
                            .all(|(a, b)| a.item_id == b.id && a.source == b.source),
                    "Find source changed without a new generation"
                );
                return Ok(());
            }
        }
        self.invalidate();
        let same = self.thread.as_deref() == Some(s.thread_id.as_str());
        if !same {
            self.search.matches.clear();
            self.search.active = None;
            self.search.truncated = false;
        }
        let mut old = if same {
            std::mem::take(&mut self.items)
                .into_iter()
                .map(|i| (i.id.clone(), i))
                .collect::<HashMap<_, _>>()
        } else {
            for item in &self.items {
                item.state
                    .update(cx, |state, cx| state.clear_range_highlights(cx));
            }
            self.items.clear();
            HashMap::new()
        };
        let mut items = Vec::with_capacity(s.items.len());
        for item in s.items {
            if let Some(mut native) = old.remove(&item.item_id) {
                if native.source != item.source {
                    let appended =
                        !native.source.is_empty() && item.source.starts_with(&native.source);
                    native.state.update(cx, |state, cx| {
                        if !appended {
                            state.clear_selection(cx);
                        }
                        state.set_text(&item.source, cx);
                    });
                    native.source = item.source;
                    native.rendered = None;
                }
                items.push(native);
            } else {
                let state = cx.new(|cx| TextViewState::markdown(&item.source, cx).selectable(true));
                let observer = cx.observe(&state, |this, _, cx| {
                    this.dirty = true;
                    cx.notify();
                });
                items.push(NativeItem {
                    id: item.item_id,
                    source: item.source,
                    state,
                    rendered: None,
                    applied: Rc::new(Cell::new(false)),
                    _observer: observer,
                });
            }
        }
        for item in old.values() {
            item.state
                .update(cx, |state, cx| state.clear_range_highlights(cx));
        }
        self.items = items;
        self.thread = Some(s.thread_id);
        self.generation = s.generation;
        self.dirty = true;
        Ok(())
    }
    pub fn open(
        &mut self,
        snapshot: FindSnapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        self.install(snapshot, cx)?;
        if !self.opened {
            self.restore = window.focused(cx);
        }
        self.opened = true;
        self.input.read(cx).focus_handle(cx).focus(window, cx);
        self.rescan(true, false, cx);
        cx.notify();
        Ok(())
    }
    pub fn replace_snapshot(
        &mut self,
        snapshot: FindSnapshot,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        self.install(snapshot, cx)?;
        if self.opened {
            self.rescan(true, false, cx);
        }
        cx.notify();
        Ok(())
    }
    pub fn is_open(&self) -> bool {
        self.opened
    }
    pub fn dismiss(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.opened {
            return;
        }
        self.opened = false;
        self.invalidate();
        for item in &self.items {
            item.state
                .update(cx, |state, cx| state.clear_range_highlights(cx));
        }
        if let Some(focus) = self.restore.take() {
            focus.focus(window, cx);
        }
        cx.notify();
        cx.emit(FindEvent::Dismissed);
    }
    pub fn state_for(
        &self,
        thread_id: &str,
        item_id: &str,
        generation: u64,
    ) -> Option<Entity<TextViewState>> {
        if self.thread.as_deref() != Some(thread_id) || self.generation != generation {
            return None;
        }
        self.items
            .iter()
            .find(|item| item.id == item_id)
            .map(|item| item.state.clone())
    }
    pub fn projection_for(
        &self,
        thread_id: &str,
        item_id: &str,
        generation: u64,
    ) -> Option<FindProjection> {
        if !self.opened
            || self.thread.as_deref() != Some(thread_id)
            || self.generation != generation
        {
            return None;
        }
        let item = self.items.iter().find(|item| item.id == item_id)?;
        let rendered = item.rendered.as_ref()?.clone();
        let active = self
            .search
            .selected()
            .filter(|m| m.item == item_id)
            .map(|m| m.range.clone());
        Some(FindProjection {
            thread_id: thread_id.into(),
            item_id: item_id.into(),
            generation,
            match_serial: self.serial,
            rendered,
            ranges: self.per_item.get(item_id).cloned().unwrap_or_default(),
            active,
            validity: self.validity.clone(),
            applied: item.applied.clone(),
            receipt: self.receipt.clone(),
            reveal_requested: self.pending == Some(self.serial),
        })
    }
    pub fn acknowledge_reveal(&mut self, match_serial: u64) -> bool {
        if self.serial == match_serial && self.pending == Some(match_serial) && self.receipt.get() {
            self.pending = None;
            true
        } else {
            false
        }
    }
    fn apply_highlights(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.thread.clone() else {
            return;
        };
        for item in &self.items {
            if let Some(projection) = self.projection_for(&thread, &item.id, self.generation) {
                let result = item.state.update(cx, |state, cx| {
                    if state.rendered_text() != projection.rendered {
                        return Ok(());
                    }
                    state.set_range_highlights(projection.highlights(), cx)
                });
                if result.is_ok() {
                    projection.mark_applied();
                } else {
                    self.error =
                        "Native highlight projection rejected; refresh this transcript.".into();
                }
            } else {
                item.state
                    .update(cx, |state, cx| state.clear_range_highlights(cx));
            }
        }
    }
    fn publish(&mut self, cx: &mut Context<Self>) {
        self.invalidate();
        self.per_item.clear();
        for m in &self.search.matches {
            self.per_item
                .entry(m.item.clone())
                .or_default()
                .push(m.range.clone());
        }
        for item in &mut self.items {
            item.applied = Rc::new(Cell::new(false));
        }
        self.pending = self.search.selected().map(|_| self.serial);
        self.apply_highlights(cx);
        if let Some(thread) = &self.thread {
            if let Some(m) = self.search.selected() {
                cx.emit(FindEvent::Reveal {
                    thread_id: thread.clone(),
                    item_id: m.item.clone(),
                    generation: self.generation,
                    match_serial: self.serial,
                    range: m.range.clone(),
                });
            } else {
                cx.emit(FindEvent::Cleared {
                    thread_id: thread.clone(),
                    generation: self.generation,
                    match_serial: self.serial,
                });
            }
        }
        cx.notify();
    }
    fn rescan(&mut self, force: bool, reset: bool, cx: &mut Context<Self>) {
        self.dirty = false;
        if !self.opened {
            return;
        }
        let mut changed = false;
        for item in &mut self.items {
            let rendered = item.state.read(cx).rendered_text();
            let ready = (rendered.source() == item.source).then_some(rendered);
            if item.rendered != ready {
                item.rendered = ready;
                changed = true;
            }
        }
        if force || changed {
            self.error.clear();
            let ready = self.search.rebuild_ready(
                self.items.iter().map(|item| {
                    (
                        item.id.as_str(),
                        item.rendered.as_ref().map(RenderedText::as_str),
                    )
                }),
                reset,
            );
            if ready {
                self.publish(cx);
            } else {
                self.invalidate();
                self.per_item.clear();
                for item in &self.items {
                    item.state
                        .update(cx, |state, cx| state.clear_range_highlights(cx));
                }
                if let Some(thread) = &self.thread {
                    cx.emit(FindEvent::Cleared {
                        thread_id: thread.clone(),
                        generation: self.generation,
                        match_serial: self.serial,
                    });
                }
                cx.notify();
            }
        }
    }
    fn step(&mut self, next: bool, cx: &mut Context<Self>) {
        if !self.opened || self.items.iter().any(|item| item.rendered.is_none()) {
            return;
        }
        self.search.step(next);
        self.publish(cx);
    }
}
impl Render for TranscriptFind {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if !self.opened {
            return div().into_any_element();
        }
        let pending = self
            .items
            .iter()
            .filter(|item| item.rendered.is_none())
            .count();
        let count = format!(
            "{} / {}{}{}",
            self.search.active.map_or(0, |i| i + 1),
            self.search.matches.len(),
            if self.search.truncated {
                "+ (match limit)"
            } else {
                ""
            },
            if pending > 0 {
                format!(" · indexing {pending} messages")
            } else {
                String::new()
            }
        );
        div()
            .id("transcript-find")
            .flex()
            .flex_col()
            .gap_1()
            .p_2()
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape"
                    && !event.keystroke.modifiers.control
                    && !event.keystroke.modifiers.platform
                    && !event.keystroke.modifiers.alt
                {
                    this.dismiss(window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().child(Input::new(&self.input)))
                    .child(count)
                    .child(
                        Button::new("find-previous")
                            .label("Previous")
                            .disabled(self.search.matches.is_empty() || pending > 0)
                            .on_click(cx.listener(|this, _, _, cx| this.step(false, cx))),
                    )
                    .child(
                        Button::new("find-next")
                            .label("Next")
                            .disabled(self.search.matches.is_empty() || pending > 0)
                            .on_click(cx.listener(|this, _, _, cx| this.step(true, cx))),
                    )
                    .child(
                        Button::new("find-dismiss")
                            .label("Close · Esc")
                            .on_click(cx.listener(|this, _, window, cx| this.dismiss(window, cx))),
                    ),
            )
            .child(self.error.clone())
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        FindItem, FindSnapshot, MAX_MATCHES, Search, consume_reveal, match_ranges, query_text,
        validate_snapshot,
    };
    use std::cell::Cell;
    fn item(id: &str, source: &str) -> FindItem {
        FindItem {
            item_id: id.into(),
            source: source.into(),
        }
    }
    #[::core::prelude::v1::test]
    fn lowercase_expansion_maps_back_to_complete_unicode_byte_boundaries() {
        let text = "İ i CAFÉ 中文";
        let (ranges, truncated) = match_ranges(text, "i", 100);
        assert_eq!(ranges, vec![0..2, 3..4]);
        assert!(!truncated);
        assert_eq!(
            ranges
                .iter()
                .map(|r| text.get(r.clone()).unwrap())
                .collect::<Vec<_>>(),
            vec!["İ", "i"]
        );
        assert_eq!(
            match_ranges(text, "café", 100)
                .0
                .iter()
                .map(|r| &text[r.clone()])
                .collect::<Vec<_>>(),
            vec!["CAFÉ"]
        );
        assert_eq!(match_ranges("İİ", "\u{307}", 100).0, vec![0..2, 2..4]);
    }
    #[::core::prelude::v1::test]
    fn combining_characters_cjk_and_emoji_ranges_preserve_selected_content() {
        let text = "prefix E\u{301} 中文 👩🏽‍💻 suffix";
        for query in ["e\u{301}", "中文", "👩🏽‍💻"] {
            let (ranges, limited) = match_ranges(text, query, 100);
            assert!(!limited);
            assert_eq!(ranges.len(), 1);
            let range = &ranges[0];
            assert!(text.is_char_boundary(range.start) && text.is_char_boundary(range.end));
            assert_eq!(text[range.clone()].to_lowercase(), query.to_lowercase());
        }
    }
    #[::core::prelude::v1::test]
    fn nonoverlapping_matches_empty_queries_and_limits_are_explicit() {
        assert_eq!(match_ranges("aaaaa", "aa", 10), (vec![0..2, 2..4], false));
        assert_eq!(
            match_ranges("aa aa", "aa", 1),
            (std::iter::once(0..2).collect::<Vec<_>>(), true)
        );
        assert_eq!(
            match_ranges("aa", "aa", 1),
            (std::iter::once(0..2).collect::<Vec<_>>(), false)
        );
        assert_eq!(match_ranges("aa", "aa", 0), (vec![], true));
        assert_eq!(match_ranges("aa", "", 0), (vec![], false));
    }
    #[::core::prelude::v1::test]
    fn rendered_text_matching_does_not_count_markdown_delimiters() {
        // Native adapter passes RenderedText::as_str(), never FindItem::source.
        let rendered = "café and 中文\n";
        assert!(match_ranges(rendered, "**", 10).0.is_empty());
        let ranges = match_ranges(rendered, "and 中文", 10).0;
        assert_eq!(&rendered[ranges[0].clone()], "and 中文");
    }
    #[::core::prelude::v1::test]
    fn all_snapshot_items_participate_even_if_folded_or_offscreen_in_parent() {
        let mut search = Search {
            query: "needle".into(),
            ..Search::default()
        };
        search.rebuild(
            [
                ("assistant", "needle"),
                ("folded-tool", "hidden needle"),
                ("offscreen", "NEEDLE"),
            ],
            true,
        );
        assert_eq!(
            search
                .matches
                .iter()
                .map(|m| m.item.as_str())
                .collect::<Vec<_>>(),
            vec!["assistant", "folded-tool", "offscreen"]
        );
        search.step(false);
        assert_eq!(search.selected().unwrap().item, "offscreen");
        search.step(true);
        assert_eq!(search.selected().unwrap().item, "assistant");
        search.step(true);
        assert_eq!(search.selected().unwrap().item, "folded-tool");
    }
    #[::core::prelude::v1::test]
    fn stable_item_selection_survives_append_reorder_and_is_removed_on_edit() {
        let mut search = Search {
            query: "hit".into(),
            ..Search::default()
        };
        search.rebuild([("a", "hit"), ("b", "hit")], true);
        search.step(true);
        search.rebuild([("b", "hit plus appended text"), ("a", "hit")], false);
        assert_eq!(search.selected().unwrap().item, "b");
        search.rebuild([("b", "changed"), ("a", "hit")], false);
        assert_eq!(search.selected().unwrap().item, "a");
        search.rebuild([("b", "changed")], false);
        assert!(search.selected().is_none());
        search.step(true);
        assert!(search.selected().is_none());
    }
    #[::core::prelude::v1::test]
    fn new_query_resets_active_and_query_bound_is_unicode_safe() {
        let mut search = Search {
            query: "one".into(),
            ..Search::default()
        };
        search.rebuild([("a", "one"), ("b", "one")], true);
        search.step(true);
        search.query = "o".into();
        search.rebuild([("a", "one"), ("b", "one")], true);
        assert_eq!(search.selected().unwrap().item, "a");
        assert_eq!(
            query_text(&format!("\0{}", "中".repeat(300)))
                .chars()
                .count(),
            256
        );
    }
    #[::core::prelude::v1::test]
    fn reveal_serial_consumes_only_current_receipt_once_and_rejects_stale_clone() {
        let epoch = Cell::new(9);
        let receipt = Cell::new(false);
        assert!(!consume_reveal(&epoch, 8, &receipt));
        assert!(!receipt.get());
        assert!(consume_reveal(&epoch, 9, &receipt));
        assert!(!consume_reveal(&epoch, 9, &receipt));
        epoch.set(10);
        let next = Cell::new(false);
        assert!(!consume_reveal(&epoch, 9, &next));
        assert!(consume_reveal(&epoch, 10, &next));
    }
    #[::core::prelude::v1::test]
    fn duplicate_ids_and_source_bounds_are_rejected_without_native_state_work() {
        let make = |items| FindSnapshot {
            thread_id: "thread".into(),
            generation: 1,
            items,
        };
        validate_snapshot(&make(vec![item("a", "**source**"), item("b", "source")])).unwrap();
        assert!(validate_snapshot(&make(vec![item("a", "first"), item("a", "second")])).is_err());
        assert!(
            validate_snapshot(&make(vec![item("a", &"x".repeat(2 * 1024 * 1024 + 1))])).is_err()
        );
        let entries = (0..2001).map(|i| item(&i.to_string(), "body")).collect();
        assert!(validate_snapshot(&make(entries)).is_err());
    }
    #[::core::prelude::v1::test]
    fn global_match_cap_includes_later_messages_without_false_exact_count() {
        let body = "x ".repeat(MAX_MATCHES);
        let mut search = Search {
            query: "x".into(),
            ..Search::default()
        };
        search.rebuild([("a", body.as_str()), ("b", "no matches")], true);
        assert_eq!(search.matches.len(), MAX_MATCHES);
        assert!(!search.truncated);
        search.rebuild([("a", body.as_str()), ("b", "x")], true);
        assert!(search.truncated);
        assert_eq!(search.matches.len(), MAX_MATCHES);
    }
    #[::core::prelude::v1::test]
    fn async_parse_batches_do_not_publish_timing_order_or_lose_streamed_active_match() {
        let mut search = Search {
            query: "hit".into(),
            ..Search::default()
        };
        assert!(!search.rebuild_ready([("first", None), ("second", Some("hit"))], true));
        assert!(search.matches.is_empty());
        assert!(search.rebuild_ready([("first", Some("hit")), ("second", Some("hit"))], false));
        assert_eq!(search.selected().unwrap().item, "first");
        search.step(true);
        assert!(!search.rebuild_ready([("first", Some("hit")), ("second", None)], false));
        assert_eq!(search.selected().unwrap().item, "second");
        assert!(search.rebuild_ready(
            [("first", Some("hit")), ("second", Some("hit plus append"))],
            false
        ));
        assert_eq!(search.selected().unwrap().item, "second");
        search.query = "new query".into();
        assert!(!search.rebuild_ready([("first", None), ("second", Some("hit"))], true));
        assert!(search.matches.is_empty());
        assert!(search.selected().is_none());
    }
}
