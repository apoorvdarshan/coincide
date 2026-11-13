//! Swift's TranscriptBuilder turn layout: a running turn opens with "Working for
//! 12s", a finished turn folds its tool calls, reasoning and interim replies
//! under "Worked for 2m 13s", and work after a steered message folds under
//! "Continued for…". The virtualized list keeps exactly one row per stored item
//! (find, media and selection splice rows by item index), so this module only
//! decides what each item's row hides or draws below itself.
use super::*;
use gpui_kit::assets::IconName;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// Swift's `Date` reference (2001-01-01) as Unix seconds.
const REFERENCE_UNIX: f64 = 978_307_200.0;

/// Seconds since Swift's reference date, from either stored date format.
pub(super) fn seconds(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64().filter(|seconds| seconds.is_finite()),
        Value::String(_) => coincide_core::scheduling::parse_date(value)
            .ok()
            .map(|date| date.timestamp_millis() as f64 / 1000. - REFERENCE_UNIX),
        _ => None,
    }
}

/// The user's messages open turns, except those steered into a running turn.
/// Rust-run threads have no agent-initiated turn notices, so nothing else does.
pub(super) fn opens_turn(item: &Value) -> bool {
    item["kind"] == "user" && item["steered"] != true
}

fn blank(item: &Value) -> bool {
    item["text"]
        .as_str()
        .is_none_or(|text| text.trim().is_empty())
}

fn has_media(item: &Value) -> bool {
    ["rustImages", "attachments"]
        .iter()
        .any(|key| item[*key].as_array().is_some_and(|media| !media.is_empty()))
}

/// Swift's isVisible: empty reasoning, replies and plans never draw a row.
pub(super) fn visible(item: &Value, show_reasoning: bool) -> bool {
    match item["kind"].as_str() {
        Some("reasoning") => show_reasoning && !blank(item),
        Some("assistant") => !blank(item) || has_media(item),
        Some("plan") => !blank(item),
        _ => true,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(super) enum Header {
    Working { started_at: f64 },
    Worked { duration: f64, expanded: bool },
    Continued { duration: f64, expanded: bool },
}

impl Header {
    pub(super) fn label(&self, now: f64) -> String {
        match self {
            Self::Working { started_at } => {
                format!("Working for {}", elapsed(now - started_at))
            }
            Self::Worked { duration, .. } => format!("Worked for {}", duration_label(*duration)),
            Self::Continued { duration, .. } => {
                format!("Continued for {}", duration_label(*duration))
            }
        }
    }
    pub(super) fn expanded(&self) -> Option<bool> {
        match self {
            Self::Working { .. } => None,
            Self::Worked { expanded, .. } | Self::Continued { expanded, .. } => Some(*expanded),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct RowPlan {
    /// Folded away under a header, or not drawn at all (Swift's isVisible).
    pub hidden: bool,
    /// Only the final visible reply carries the turn signature.
    pub terminal_reply: bool,
    /// Drawn below this item's own row: it opens the turn, or is the steered
    /// message the folded work follows.
    pub header: Option<Header>,
    /// Consecutive tool/reasoning items folded into Swift's one-line group.
    pub group: Option<GroupPlan>,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct GroupPlan {
    pub items: Vec<usize>,
    pub expanded: bool,
}

pub(super) struct Turns<'a> {
    pub items: &'a [Value],
    /// The selected thread runs a turn, which is its last opening message.
    pub running: bool,
    pub show_reasoning: bool,
    /// Whether the user opened the header anchored at this item ID.
    pub expanded: &'a dyn Fn(&str) -> bool,
}

impl Turns<'_> {
    pub(super) fn running_opener(&self) -> Option<usize> {
        self.running
            .then(|| self.items.iter().rposition(opens_turn))
            .flatten()
    }

    /// A persisted running status is only live while its own turn is active.
    pub(super) fn is_running_item(&self, index: usize) -> bool {
        index < self.items.len() && self.running_opener().is_some_and(|opener| index >= opener)
    }

    /// The turn holding `index`: its opening message, and its items through
    /// the last one before the next turn. Items before the first turn have none.
    pub(super) fn turn(&self, index: usize) -> (Option<usize>, std::ops::Range<usize>) {
        if self.items.is_empty() {
            return (None, 0..0);
        }
        let index = index.min(self.items.len() - 1);
        let opener = self.items[..=index].iter().rposition(opens_turn);
        let end = self.items[index + 1..]
            .iter()
            .position(opens_turn)
            .map_or(self.items.len(), |offset| index + 1 + offset);
        (opener, opener.unwrap_or(0)..end)
    }

    pub(super) fn plan(&self, index: usize) -> RowPlan {
        if index >= self.items.len() {
            return RowPlan::default();
        }
        let (opener, range) = self.turn(index);
        let terminal = range.clone().rev().find(|&i| {
            self.items[i]["kind"] == "assistant" && visible(&self.items[i], self.show_reasoning)
        });
        let (hidden, headers, groups) = self.turn_plan(opener, range);
        RowPlan {
            hidden: hidden.contains(&index),
            terminal_reply: terminal == Some(index),
            header: headers
                .into_iter()
                .find_map(|(anchor, header)| (anchor == index).then_some(header)),
            group: groups.get(&index).cloned(),
        }
    }

    fn time(&self, index: usize, field: &str) -> Option<f64> {
        seconds(&self.items[index][field])
    }

    fn end(&self, indices: impl Iterator<Item = usize>) -> Option<f64> {
        indices
            .filter_map(|index| {
                self.time(index, "completedAt")
                    .or_else(|| self.time(index, "createdAt"))
            })
            .reduce(f64::max)
    }

    fn id(&self, index: usize) -> &str {
        self.items[index]["id"].as_str().unwrap_or_default()
    }

    /// Swift's appendTurnRows for one turn: the items it folds away and its headers.
    fn groupable(&self, index: usize) -> bool {
        let item = &self.items[index];
        (item["kind"] == "tool" || item["kind"] == "reasoning")
            && visible(item, self.show_reasoning)
            && !super::presentation::is_question_tool(item)
            && !super::presentation::is_duplicate_reasoning_tool(item)
    }

    fn turn_plan(
        &self,
        opener: Option<usize>,
        range: std::ops::Range<usize>,
    ) -> (
        HashSet<usize>,
        Vec<(usize, Header)>,
        HashMap<usize, GroupPlan>,
    ) {
        let items = self.items;
        let kind = |index: usize| items[index]["kind"].as_str().unwrap_or_default();
        let status = |index: usize| items[index]["status"].as_str();
        let first = range.start + usize::from(opener.is_some());
        let body = (first..range.end)
            .filter(|&index| visible(&items[index], self.show_reasoning))
            .collect::<Vec<_>>();
        let mut hidden = (first..range.end)
            .filter(|&index| !visible(&items[index], self.show_reasoning))
            .collect::<HashSet<_>>();
        // Consecutive tool/reasoning rows fold into Swift's group line. The
        // first member carries the summary row and the expanded children; the
        // rest are always hidden to avoid drawing a second copy.
        let mut groups = HashMap::new();
        let mut cursor = 0;
        while cursor < body.len() {
            if !self.groupable(body[cursor]) {
                cursor += 1;
                continue;
            }
            let start = cursor;
            while cursor < body.len() && self.groupable(body[cursor]) {
                cursor += 1;
            }
            if cursor - start < 2 {
                continue;
            }
            let run = body[start..cursor].to_vec();
            let first = run[0];
            let expanded = (self.expanded)(self.id(first));
            groups.insert(
                first,
                GroupPlan {
                    items: run.clone(),
                    expanded,
                },
            );
            for member in run.into_iter().skip(1) {
                hidden.insert(member);
            }
        }
        let mut headers = Vec::new();
        if let Some(opener) = opener
            && Some(opener) == self.running_opener()
        {
            let started_at = self.time(opener, "createdAt").unwrap_or_default();
            headers.push((opener, Header::Working { started_at }));
            return (hidden, headers, groups);
        }

        let terminal = body.iter().rposition(|&index| kind(index) == "assistant");
        let mut folded = HashSet::new();
        if !body.iter().any(|&index| kind(index) == "error") {
            for (position, &index) in body.iter().enumerate() {
                if Some(position) == terminal {
                    continue;
                }
                let before_reply = terminal.is_none_or(|terminal| position < terminal);
                let fold = match kind(index) {
                    "tool" | "reasoning" => before_reply || status(index) != Some("failed"),
                    // Rich results stay visible when the agent follows them with a text summary.
                    "assistant" => before_reply && !has_media(&items[index]),
                    "approval" => status(index) != Some("waiting"),
                    _ => false,
                };
                if fold {
                    folded.insert(index);
                }
            }
        }

        // As in T3, messages steered into the turn split its work into parts.
        // "Worked for…" carries the whole turn's time and folds the first part;
        // each later part folds under "Continued for…" below its message.
        let parts = steer_parts(&body, kind);
        let mut bounds = vec![0];
        bounds.extend(parts.iter().map(|(_, start)| *start));
        bounds.push(body.len());
        for part in 0..bounds.len() - 1 {
            let slice = &body[bounds[part]..bounds[part + 1]];
            let shown = slice.iter().filter(|index| !folded.contains(index)).count();
            let header = if part == 0 {
                // Swift folds work before the first turn too, with no header to
                // open it. Keep that work visible instead of unreachable.
                let Some(opener) = opener else {
                    for index in slice {
                        folded.remove(index);
                    }
                    continue;
                };
                if folded.is_empty() {
                    continue;
                }
                let start = self.time(opener, "createdAt").unwrap_or_default();
                let end = self.end(range.clone()).unwrap_or(start);
                let expanded = (self.expanded)(self.id(opener));
                (
                    opener,
                    Header::Worked {
                        duration: (end - start).max(0.),
                        expanded,
                    },
                )
            } else {
                if shown == slice.len() {
                    continue;
                }
                let steer = parts[part - 1].0;
                let start = self.time(steer, "createdAt").unwrap_or_default();
                let end = self.end(slice.iter().copied()).unwrap_or(start);
                let expanded = (self.expanded)(self.id(steer));
                (
                    steer,
                    Header::Continued {
                        duration: (end - start).max(0.),
                        expanded,
                    },
                )
            };
            if header.1.expanded() == Some(true) {
                for index in slice {
                    folded.remove(index);
                }
            }
            headers.push(header);
        }
        hidden.extend(folded);
        (hidden, headers, groups)
    }
}

/// Where steered messages split a finished turn's `body`: for each later part,
/// the message it follows and where in `body` it starts. A steer splits the
/// work only once the turn has shown something, and steers back to back split
/// it once, after the last.
fn steer_parts<'a>(body: &[usize], kind: impl Fn(usize) -> &'a str) -> Vec<(usize, usize)> {
    let mut parts = Vec::new();
    let mut has_output = false;
    let mut pending = None;
    for (position, &index) in body.iter().enumerate() {
        if kind(index) == "user" {
            if has_output {
                pending = Some(index);
            }
            continue;
        }
        if let Some(steer) = pending.take() {
            parts.push((steer, position));
        }
        has_output = true;
    }
    parts
}

#[derive(Clone, Debug, PartialEq)]
pub(super) enum Live {
    /// The provider has not answered yet: "Starting Claude…".
    Starting,
    Thinking,
}

/// Swift's needsLiveRow: the live line says the agent is busy when nothing
/// at the bottom of the running turn already does. `waiting` reports an
/// approval or question the agent still waits on.
pub(super) fn live(
    items: &[Value],
    running: bool,
    starting: bool,
    show_reasoning: bool,
    waiting: impl Fn(&Value) -> bool,
) -> Option<Live> {
    if !running {
        return None;
    }
    let status = if starting {
        Live::Starting
    } else {
        Live::Thinking
    };
    let Some(last) = items.iter().rposition(|item| visible(item, show_reasoning)) else {
        return Some(status);
    };
    let item = &items[last];
    let active = match item["kind"].as_str() {
        // Rust-run replies, thoughts and most tool calls carry no explicit
        // status while they stream. The newest item is the visible activity.
        Some("tool" | "reasoning" | "assistant") => match item["status"].as_str() {
            Some(status) => status == "running",
            None => last + 1 == items.len(),
        },
        Some("approval" | "question") => item["status"] == "waiting" || waiting(item),
        _ => false,
    };
    (!active).then_some(status)
}

/// "Worked for 2m 13s", T3 Code's duration format.
pub(super) fn duration_label(interval: f64) -> String {
    if !interval.is_finite() || interval < 0. {
        return "0s".into();
    }
    if interval < 10. {
        let tenths = (interval * 10.).round() / 10.;
        return if tenths < 1. {
            format!("{:.1}s", tenths.max(0.1))
        } else {
            format!("{:.1}s", tenths.min(9.9))
        };
    }
    let total = interval.round() as u64;
    if total < 60 {
        return format!("{total}s");
    }
    let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60);
    [(hours, "h"), (minutes, "m"), (seconds, "s")]
        .into_iter()
        .filter(|(value, _)| *value > 0)
        .map(|(value, unit)| format!("{value}{unit}"))
        .collect::<Vec<_>>()
        .join(" ")
}

/// A live timer: "12s", "1m 05s", "1h 02m".
pub(super) fn elapsed(interval: f64) -> String {
    let seconds = if interval.is_finite() {
        interval.max(0.) as u64
    } else {
        0
    };
    let minutes = seconds / 60;
    if minutes == 0 {
        return format!("{seconds}s");
    }
    let hours = minutes / 60;
    if hours == 0 {
        return format!("{minutes}m {:02}s", seconds % 60);
    }
    format!("{hours}h {:02}m", minutes % 60)
}

/// Opened headers, per conversation like Swift's expansion memory, the live
/// clock last drawn (the running header redraws once a second), and the runs
/// whose provider has not answered yet.
#[derive(Default)]
pub(super) struct State {
    expanded: HashSet<(String, String)>,
    // Cleared at the start of each render. A long turn is planned once per
    // layout pass, not once for every measured virtual row.
    plans: std::cell::RefCell<HashMap<usize, RowPlan>>,
    tick: Option<(String, String)>,
    pub starting: HashSet<String>,
}

impl State {
    pub(super) fn begin_render(&self) {
        self.plans.borrow_mut().clear();
    }
    pub(super) fn is_expanded(&self, thread: &str, anchor: &str) -> bool {
        self.expanded
            .contains(&(thread.to_owned(), anchor.to_owned()))
    }
    pub(super) fn toggle(&mut self, thread: &str, anchor: &str) {
        let key = (thread.to_owned(), anchor.to_owned());
        if !self.expanded.remove(&key) {
            self.expanded.insert(key);
        }
    }
}

impl super::Coincide {
    fn selected_turns<R>(&self, f: impl FnOnce(&Turns<'_>, &str) -> R) -> Option<R> {
        let thread = self.selected.as_ref()?;
        let id = thread["id"].as_str()?;
        let items = thread["items"].as_array()?;
        let expanded = |anchor: &str| self.chat_turns.is_expanded(id, anchor);
        let turns = Turns {
            items,
            running: self.running.iter().any(|running| running == id),
            show_reasoning: self.settings["showReasoning"].as_bool().unwrap_or(true),
            expanded: &expanded,
        };
        Some(f(&turns, id))
    }

    pub(super) fn is_running_turn_item(&self, index: usize) -> bool {
        self.selected_turns(|turns, _| turns.is_running_item(index))
            .unwrap_or(false)
    }

    pub(super) fn turn_plan(&self, index: usize) -> RowPlan {
        if let Some(plan) = self.chat_turns.plans.borrow().get(&index) {
            return plan.clone();
        }
        self.selected_turns(|turns, _| {
            if index >= turns.items.len() {
                return RowPlan::default();
            }
            let (opener, range) = turns.turn(index);
            let terminal = range.clone().rev().find(|&i| {
                turns.items[i]["kind"] == "assistant"
                    && visible(&turns.items[i], turns.show_reasoning)
            });
            let (hidden, headers, groups) = turns.turn_plan(opener, range.clone());
            let mut plans = self.chat_turns.plans.borrow_mut();
            for i in range {
                plans.insert(
                    i,
                    RowPlan {
                        hidden: hidden.contains(&i),
                        terminal_reply: terminal == Some(i),
                        header: headers
                            .iter()
                            .find_map(|(anchor, header)| (*anchor == i).then(|| header.clone())),
                        group: groups.get(&i).cloned(),
                    },
                );
            }
            plans.get(&index).cloned().unwrap_or_default()
        })
        .unwrap_or_default()
    }

    /// The live line below the selected thread's last row, with the agent it names.
    fn turn_live(&self) -> Option<(Live, String)> {
        let thread = self.selected.as_ref()?;
        let id = thread["id"].as_str()?;
        let items = thread["items"].as_array()?;
        let waiting = |item: &Value| {
            let external = &item["externalID"];
            !external.is_null()
                && self
                    .pending_requests
                    .iter()
                    .any(|request| request["requestId"] == *external)
        };
        let status = live(
            items,
            self.running.iter().any(|running| running == id),
            self.chat_turns.starting.contains(id),
            self.settings["showReasoning"].as_bool().unwrap_or(true),
            waiting,
        )?;
        let provider = items
            .iter()
            .rfind(|item| opens_turn(item))
            .and_then(|item| item["provider"].as_str())
            .or_else(|| thread["selection"]["provider"].as_str())
            .unwrap_or_default()
            .to_owned();
        Some((status, provider))
    }

    /// Opens or folds a header, redrawing every row of its turn.
    fn toggle_turn_header(&mut self, thread: &str, anchor: &str, cx: &mut Context<Self>) {
        let Some(range) = self
            .selected
            .as_ref()
            .filter(|selected| selected["id"] == thread)
            .and_then(|_| {
                self.selected_turns(|turns, _| {
                    let index = turns.items.iter().position(|item| item["id"] == anchor)?;
                    Some(turns.turn(index).1)
                })
                .flatten()
            })
        else {
            return;
        };
        self.chat_turns.toggle(thread, anchor);
        let end = range.end.min(self.transcript_count);
        if range.start < end {
            self.transcript_list
                .splice(range.start..end, end - range.start);
        }
        cx.notify();
    }

    /// Redraws the running turn's "Working for…" row when its clock changes.
    pub(super) fn tick_turn_clock(&mut self, cx: &mut Context<Self>) {
        let now = coincide_core::store::swift_timestamp();
        let tick = self
            .selected_turns(|turns, id| {
                let opener = turns.running_opener()?;
                let started = seconds(&turns.items[opener]["createdAt"]).unwrap_or(now);
                Some((opener, id.to_owned(), elapsed(now - started)))
            })
            .flatten();
        let Some((opener, thread, label)) = tick else {
            self.chat_turns.tick = None;
            return;
        };
        let key = Some((thread, label));
        if self.chat_turns.tick != key && opener < self.transcript_count {
            self.chat_turns.tick = key;
            self.transcript_list.splice(opener..opener + 1, 1);
            cx.notify();
        }
    }

    /// Records which runs are still starting; the last row redraws its live line.
    pub(super) fn set_starting_runs(&mut self, starting: HashSet<String>, cx: &mut Context<Self>) {
        if self.chat_turns.starting == starting {
            return;
        }
        self.chat_turns.starting = starting;
        self.redraw_live_row(cx);
    }

    pub(super) fn redraw_live_row(&mut self, cx: &mut Context<Self>) {
        if let Some(last) = self.transcript_count.checked_sub(1) {
            self.transcript_list.splice(last..last + 1, 1);
            cx.notify();
        }
    }

    /// `row` with its turn header below it and, on the last row, the live line.
    pub(super) fn turn_decorated(
        &mut self,
        index: usize,
        row: AnyElement,
        header: Option<Header>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let last = index + 1 == self.transcript_count;
        let live = last.then(|| self.turn_live()).flatten();
        if self.turn_plan(index).hidden && header.is_none() && live.is_none() {
            return row;
        }
        let provider = self
            .selected
            .as_ref()
            .and_then(|thread| thread["items"].as_array())
            .and_then(|items| {
                items
                    .get(index)
                    .and_then(|item| item["provider"].as_str())
                    .or_else(|| {
                        items[..=index.min(items.len().saturating_sub(1))]
                            .iter()
                            .rev()
                            .find_map(|item| item["provider"].as_str())
                    })
            })
            .unwrap_or("")
            .to_owned();
        let rail_color = self.provider_ink(&provider);
        let header_logo = header.is_some();
        let thread = self
            .selected
            .as_ref()
            .map(|thread| text(thread, "id"))
            .unwrap_or_default();
        let anchor = self
            .selected
            .as_ref()
            .and_then(|thread| thread["items"].get(index))
            .map(|item| text(item, "id"))
            .unwrap_or_default();
        let secondary = self.color(0xe4e9f2).opacity(0.6);
        let font = (self.conversation_font_size() - 1.).max(10.);
        let line = |child: AnyElement, height: f32| {
            div()
                .flex()
                .w_full()
                .px(px(presentation::CONTENT_GUTTER))
                .justify_center()
                .child(
                    div()
                        .flex()
                        .items_center()
                        .w_full()
                        .min_w_0()
                        .max_w(px(presentation::CONTENT_WIDTH))
                        .pl(px(presentation::RAIL_GUTTER))
                        .relative()
                        .h(px(height))
                        .text_size(px(font))
                        .text_color(secondary)
                        .child(child)
                        .when(header_logo && height == 40., |row| {
                            row.when_some(
                                chat_layout::provider_mark(&provider, 16.),
                                |row, logo| {
                                    row.child(
                                        div()
                                            .absolute()
                                            .left(px(8.))
                                            .top(px(12.))
                                            .size(px(16.))
                                            .child(logo),
                                    )
                                },
                            )
                        }),
                )
        };
        let header = header.map(|header| {
            let label = header.label(coincide_core::store::swift_timestamp());
            let content = match header.expanded() {
                None => div().pl_1().child(label).into_any_element(),
                Some(expanded) => {
                    let id = SharedString::from(format!("turn-header-{thread}-{anchor}"));
                    let (source, anchor) = (thread.clone(), anchor.clone());
                    Button::new(id.clone())
                        .accessibility_id(id)
                        .accessibility_label(SharedString::from(format!(
                            "{label}, {}",
                            if expanded { "expanded" } else { "collapsed" }
                        )))
                        .label(label)
                        .ghost()
                        .compact()
                        .small()
                        .text_color(secondary)
                        .child(
                            Icon::new(if expanded {
                                IconName::ChevronDown
                            } else {
                                IconName::ChevronRight
                            })
                            .xsmall(),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.toggle_turn_header(&source, &anchor, cx)
                        }))
                        .into_any_element()
                }
            };
            line(content, 40.)
        });
        let live = live.map(|(status, provider)| {
            let label = match status {
                Live::Starting => {
                    format!("Starting {}…", presentation::provider_name(&provider))
                }
                Live::Thinking => "Thinking…".into(),
            };
            line(div().pl_1().child(label).into_any_element(), 36.)
        });
        div()
            .relative()
            .w_full()
            // The overlay follows the same centered column as every row. It
            // has no input handlers; text selection and disclosure clicks keep
            // reaching the content above it.
            .child(
                div()
                    .absolute()
                    .inset_0()
                    .px(px(presentation::CONTENT_GUTTER))
                    .flex()
                    .justify_center()
                    .child(
                        div()
                            .relative()
                            .w_full()
                            .max_w(px(presentation::CONTENT_WIDTH))
                            .h_full()
                            .child(
                                div()
                                    .absolute()
                                    .left(px(15.))
                                    .top_0()
                                    .bottom_0()
                                    .w(px(1.))
                                    .bg(rail_color.opacity(0.4)),
                            ),
                    ),
            )
            .child(
                div()
                    .relative()
                    .flex()
                    .flex_col()
                    .w_full()
                    .child(row)
                    .children(header)
                    .children(live)
                    .children(self.fork_divider(&anchor, cx)),
            )
            .into_any_element()
    }

    /// T3's fork divider, on the fork side: after the copied history, a capsule
    /// naming the source conversation that opens it.
    fn fork_divider(&self, item: &str, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref()?;
        let history = &thread["rustHistory"];
        if history["forkItemID"].as_str() != Some(item) {
            return None;
        }
        let parent = history["parentThreadID"].as_str()?.to_owned();
        let title = history["parentTitle"]
            .as_str()
            .filter(|title| !title.trim().is_empty())
            .unwrap_or("conversation")
            .to_owned();
        let label: String = title.chars().take(60).collect();
        let id = SharedString::from(format!("fork-divider-{parent}-{item}"));
        Some(
            div()
                .flex()
                .w_full()
                .px(px(presentation::CONTENT_GUTTER))
                .justify_center()
                .child(
                    div()
                        .flex()
                        .items_center()
                        .w_full()
                        .max_w(px(presentation::CONTENT_WIDTH))
                        .pl(px(presentation::RAIL_GUTTER))
                        .h(px(26.))
                        .child(
                            Button::new(id.clone())
                                .accessibility_id(id)
                                .accessibility_label(format!("Forked from conversation, {title}"))
                                .tooltip("Open source conversation")
                                .label(format!("Forked from conversation · {label}"))
                                .ghost()
                                .compact()
                                .xsmall()
                                .text_color(self.color(0xe4e9f2).opacity(0.6))
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.select(&parent, window, cx);
                                })),
                        ),
                )
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[::core::prelude::v1::test]
    fn only_the_current_turn_can_show_running_work() {
        let mut steer = item("steer", "user", 4.);
        steer["steered"] = json!(true);
        let items = [
            item("old-user", "user", 0.),
            item("old-tool", "tool", 1.),
            item("new-user", "user", 2.),
            item("active-tool", "tool", 3.),
            steer,
            item("parallel-tool", "tool", 5.),
        ];
        let expanded = |_: &str| false;
        let mut turns = Turns {
            items: &items,
            running: true,
            show_reasoning: true,
            expanded: &expanded,
        };
        assert!(!turns.is_running_item(1));
        assert!(turns.is_running_item(3));
        assert!(turns.is_running_item(5));
        assert!(!turns.is_running_item(6));
        turns.running = false;
        assert!(!turns.is_running_item(3));
        assert!(!turns.is_running_item(5));
    }

    fn item(id: &str, kind: &str, created: f64) -> Value {
        json!({"id":id,"kind":kind,"text":format!("{kind} {id}"),"createdAt":created})
    }

    fn plans(items: &[Value], running: bool, opened: &[&str]) -> Vec<RowPlan> {
        let opened = opened
            .iter()
            .map(|id| id.to_string())
            .collect::<HashSet<_>>();
        let expanded = |id: &str| opened.contains(id);
        let turns = Turns {
            items,
            running,
            show_reasoning: true,
            expanded: &expanded,
        };
        (0..items.len()).map(|index| turns.plan(index)).collect()
    }

    fn hidden(plans: &[RowPlan]) -> Vec<usize> {
        plans
            .iter()
            .enumerate()
            .filter_map(|(index, plan)| plan.hidden.then_some(index))
            .collect()
    }

    #[::core::prelude::v1::test]
    fn only_last_nonempty_reply_per_turn_has_a_signature() {
        let items = [
            item("u1", "user", 0.),
            item("interim", "assistant", 1.),
            item("t", "tool", 2.),
            item("final", "assistant", 3.),
            json!({"id":"empty", "kind":"assistant", "text":"  "}),
            item("u2", "user", 4.),
            item("second", "assistant", 5.),
        ];
        let rows = plans(&items, false, &["u1"]);
        assert_eq!(
            rows.iter()
                .enumerate()
                .filter_map(|(i, p)| p.terminal_reply.then_some(i))
                .collect::<Vec<_>>(),
            vec![3, 6]
        );
        assert!(
            !rows[1].hidden,
            "expanded interim reply stays visible without a duplicate signature"
        );
    }

    #[::core::prelude::v1::test]
    fn consecutive_work_folds_into_one_expandable_group() {
        let items = [
            item("u", "user", 0.),
            item("t1", "tool", 1.),
            item("t2", "tool", 2.),
            item("r3", "reasoning", 3.),
            item("reply", "assistant", 4.),
        ];
        let rows = plans(&items, true, &[]);
        let group = rows[1].group.as_ref().expect("first tool opens the group");
        assert_eq!(group.items, vec![1, 2, 3]);
        assert!(!group.expanded);
        assert_eq!(hidden(&rows), vec![2, 3]);
        let opened = plans(&items, true, &["t1"]);
        assert!(opened[1].group.as_ref().unwrap().expanded);
        assert_eq!(hidden(&opened), vec![2, 3]);
    }

    #[::core::prelude::v1::test]
    fn a_single_work_row_never_becomes_a_group() {
        let items = [
            item("u", "user", 0.),
            item("t", "tool", 1.),
            item("reply", "assistant", 2.),
        ];
        let rows = plans(&items, true, &[]);
        assert!(rows[1].group.is_none());
    }

    #[::core::prelude::v1::test]
    fn finished_turn_folds_work_and_interim_replies_under_worked_for() {
        let mut tool = item("t", "tool", 2.);
        tool["completedAt"] = json!(30.);
        let items = [
            item("u", "user", 0.),
            item("r", "reasoning", 1.),
            tool,
            item("interim", "assistant", 31.),
            item("reply", "assistant", 40.),
            item("n", "notice", 133.),
        ];
        let rows = plans(&items, false, &[]);
        assert_eq!(hidden(&rows), vec![1, 2, 3]);
        assert_eq!(
            rows[0].header,
            Some(Header::Worked {
                duration: 133.,
                expanded: false
            })
        );
        assert_eq!(
            rows[0].header.as_ref().unwrap().label(0.),
            "Worked for 2m 13s"
        );
        let opened = plans(&items, false, &["u"]);
        // The reasoning/tool pair stays a collapsed group; opening the turn
        // reveals the group summary, not its nested members.
        assert_eq!(hidden(&opened), vec![2]);
        assert_eq!(opened[1].group.as_ref().unwrap().items, vec![1, 2]);
        assert_eq!(opened[0].header.as_ref().unwrap().expanded(), Some(true));
    }

    #[::core::prelude::v1::test]
    fn running_turn_shows_everything_under_a_ticking_working_header() {
        let items = [
            item("u0", "user", 0.),
            item("t0", "tool", 1.),
            item("a0", "assistant", 2.),
            item("u1", "user", 100.),
            item("t1", "tool", 101.),
        ];
        let rows = plans(&items, true, &[]);
        assert_eq!(hidden(&rows), vec![1]);
        assert_eq!(rows[3].header, Some(Header::Working { started_at: 100. }));
        assert_eq!(
            rows[3].header.as_ref().unwrap().label(165.),
            "Working for 1m 05s"
        );
        assert!(rows[0].header.as_ref().unwrap().expanded() == Some(false));
    }

    #[::core::prelude::v1::test]
    fn steered_messages_fold_later_work_under_continued_for() {
        let mut steer = item("s", "user", 50.);
        steer["steered"] = json!(true);
        let mut back_to_back = item("s2", "user", 51.);
        back_to_back["steered"] = json!(true);
        let mut late = item("t2", "tool", 52.);
        late["completedAt"] = json!(72.);
        let items = [
            item("u", "user", 0.),
            item("t1", "tool", 1.),
            steer,
            back_to_back,
            late,
            item("reply", "assistant", 60.),
        ];
        let rows = plans(&items, false, &[]);
        assert_eq!(hidden(&rows), vec![1, 4]);
        assert!(matches!(rows[0].header, Some(Header::Worked { .. })));
        assert_eq!(rows[2].header, None);
        assert_eq!(
            rows[3].header,
            Some(Header::Continued {
                duration: 21.,
                expanded: false
            })
        );
        let opened = plans(&items, false, &["s2"]);
        assert_eq!(hidden(&opened), vec![1]);
    }

    #[::core::prelude::v1::test]
    fn steer_before_any_output_does_not_split_the_turn() {
        let mut steer = item("s", "user", 1.);
        steer["steered"] = json!(true);
        let items = [
            item("u", "user", 0.),
            steer,
            item("t", "tool", 2.),
            item("reply", "assistant", 3.),
        ];
        let rows = plans(&items, false, &[]);
        assert_eq!(hidden(&rows), vec![2]);
        assert!(rows[1].header.is_none());
        assert!(matches!(rows[0].header, Some(Header::Worked { .. })));
    }

    #[::core::prelude::v1::test]
    fn errors_failures_waiting_and_media_stay_visible() {
        let items = [
            item("u", "user", 0.),
            item("t", "tool", 1.),
            item("e", "error", 2.),
        ];
        let rows = plans(&items, false, &[]);
        assert!(hidden(&rows).is_empty());
        assert!(rows[0].header.is_none(), "nothing folded means no header");

        let mut failed = item("f", "tool", 3.);
        failed["status"] = json!("failed");
        let mut waiting = item("w", "approval", 4.);
        waiting["status"] = json!("waiting");
        let mut media = item("m", "assistant", 1.);
        media["rustImages"] = json!([{"id":"image"}]);
        let items = [
            item("u", "user", 0.),
            media,
            item("reply", "assistant", 2.),
            failed,
            waiting,
            item("answered", "approval", 5.),
            item("q", "question", 6.),
            item("p", "plan", 7.),
        ];
        let rows = plans(&items, false, &[]);
        assert_eq!(hidden(&rows), vec![5]);
    }

    #[::core::prelude::v1::test]
    fn invisible_items_never_draw_and_work_before_any_turn_is_not_folded() {
        let mut blank = item("b", "assistant", 2.);
        blank["text"] = json!("  \n");
        let items = [
            item("t0", "tool", 0.),
            item("a0", "assistant", 0.5),
            item("u", "user", 1.),
            blank,
            item("reply", "assistant", 3.),
        ];
        let rows = plans(&items, false, &[]);
        assert_eq!(hidden(&rows), vec![3]);
        assert!(rows[0].header.is_none());
        assert!(rows[2].header.is_none());

        let hide_reasoning = |_: &str| false;
        let items = [item("u", "user", 0.), item("r", "reasoning", 1.)];
        let turns = Turns {
            items: &items,
            running: false,
            show_reasoning: false,
            expanded: &hide_reasoning,
        };
        assert!(turns.plan(1).hidden);
        assert!(turns.plan(0).header.is_none());
    }

    #[::core::prelude::v1::test]
    fn turn_bounds_follow_openers_and_ignore_steers() {
        let mut steer = item("s", "user", 2.);
        steer["steered"] = json!(true);
        let items = [
            item("pre", "notice", 0.),
            item("u0", "user", 1.),
            steer,
            item("u1", "user", 3.),
        ];
        let expanded = |_: &str| false;
        let turns = Turns {
            items: &items,
            running: true,
            show_reasoning: true,
            expanded: &expanded,
        };
        assert_eq!(turns.turn(0), (None, 0..1));
        assert_eq!(turns.turn(2), (Some(1), 1..3));
        assert_eq!(turns.turn(3), (Some(3), 3..4));
        assert_eq!(turns.running_opener(), Some(3));
    }

    #[::core::prelude::v1::test]
    fn live_row_appears_only_when_nothing_at_the_bottom_shows_activity() {
        let user = item("u", "user", 0.);
        assert_eq!(live(&[user.clone()], false, false, true, |_| false), None);
        assert_eq!(
            live(&[user.clone()], true, true, true, |_| false),
            Some(Live::Starting)
        );
        assert_eq!(
            live(&[user.clone()], true, false, true, |_| false),
            Some(Live::Thinking)
        );
        let mut running = item("t", "tool", 1.);
        running["status"] = json!("running");
        assert_eq!(
            live(&[user.clone(), running.clone()], true, false, true, |_| {
                false
            }),
            None
        );
        let mut done = running.clone();
        done["status"] = json!("completed");
        assert_eq!(
            live(&[user.clone(), done], true, false, true, |_| false),
            Some(Live::Thinking)
        );
        let streaming = item("a", "assistant", 1.);
        assert_eq!(
            live(
                &[user.clone(), streaming.clone()],
                true,
                false,
                true,
                |_| false
            ),
            None
        );
        let mut blank = item("b", "assistant", 2.);
        blank["text"] = json!("");
        assert_eq!(
            live(&[user.clone(), streaming, blank], true, false, true, |_| {
                false
            }),
            Some(Live::Thinking),
            "a reply followed by a newer item is no longer the activity"
        );
        let approval = item("p", "approval", 1.);
        assert_eq!(
            live(&[user.clone(), approval.clone()], true, false, true, |_| {
                true
            }),
            None
        );
        assert_eq!(
            live(&[user, approval], true, false, true, |_| false),
            Some(Live::Thinking)
        );
    }

    #[::core::prelude::v1::test]
    fn durations_and_live_clock_match_swift_formats() {
        for (seconds, label) in [
            (-1., "0s"),
            (f64::NAN, "0s"),
            (0., "0.1s"),
            (0.04, "0.1s"),
            (2., "2.0s"),
            (9.96, "9.9s"),
            (12.4, "12s"),
            (59.6, "1m"),
            (133., "2m 13s"),
            (3600., "1h"),
            (3725., "1h 2m 5s"),
        ] {
            assert_eq!(duration_label(seconds), label, "{seconds}");
        }
        for (seconds, label) in [
            (-3., "0s"),
            (12.9, "12s"),
            (65., "1m 05s"),
            (3720., "1h 02m"),
        ] {
            assert_eq!(elapsed(seconds), label, "{seconds}");
        }
    }

    #[::core::prelude::v1::test]
    fn stored_dates_read_swift_reference_seconds_and_rfc3339() {
        assert_eq!(seconds(&json!(12.5)), Some(12.5));
        assert_eq!(seconds(&json!("2001-01-01T00:01:00Z")), Some(60.));
        assert_eq!(seconds(&json!("2001-01-01T05:30:00+05:30")), Some(0.));
        assert_eq!(seconds(&json!("not a date")), None);
        assert_eq!(seconds(&Value::Null), None);
    }

    #[::core::prelude::v1::test]
    fn header_expansion_is_remembered_per_conversation() {
        let mut state = State::default();
        state.toggle("a", "u");
        assert!(state.is_expanded("a", "u"));
        assert!(!state.is_expanded("b", "u"));
        state.toggle("a", "u");
        assert!(!state.is_expanded("a", "u"));
    }
}
