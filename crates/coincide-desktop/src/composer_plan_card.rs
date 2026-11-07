//! The "Plan ready" card above the composer (Swift ComposerPlanCard and the
//! composer's refreshPlan/implementPlan). In plan mode, once a turn settles
//! with a plan, the card shows it and the empty composer offers Implement,
//! which switches to build mode and sends "Implement the plan."; typing
//! refines the plan instead.
use super::*;
use gpui_kit::assets::IconName;
use gpui_kit::component::text::TextViewState;

pub(super) const IMPLEMENT_PROMPT: &str = "Implement the plan.";
pub(super) const PLAN_PLACEHOLDER: &str =
    "Add feedback to refine the plan, or leave this blank to implement it";
pub(super) const DEFAULT_PLACEHOLDER: &str = "Ask anything. @ files, / commands";
/// Swift keeps the collapsed threads in its interface preferences, most
/// recent first and capped so threads deleted long ago don't pile up.
const COLLAPSED_KEY: &str = "composerCollapsedPlanThreads";
const COLLAPSED_LIMIT: usize = 200;
/// The tallest the card gets, its share of the window, and the conversation
/// room it always leaves (ComposerPlanCardLayout).
const MAXIMUM_HEIGHT: f32 = 260.;
const HEIGHT_FRACTION: f32 = 0.4;
const TRANSCRIPT_RESERVE: f32 = 120.;
const PREVIEW_LINES: usize = 4;
const CHROME_HEIGHT: f32 = 8. + 22. + 6. + 10.;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ProposedPlan {
    /// The plan item, or the reply that stands in for one.
    pub item_id: String,
    pub text: String,
}

/// The card's own rendering of the plan; it caches only the source it was
/// given, as the transcript's bodies do.
struct PlanBody {
    state: Entity<TextViewState>,
    source: String,
}

#[derive(Default)]
pub(super) struct State {
    /// Plans whose card the user hid; the next plan shows again. Implement
    /// stays offered either way.
    hidden: std::collections::HashSet<String>,
    /// Whether the composer shows the plan placeholder now.
    plan_placeholder: bool,
}

/// A plan's text: Swift's plan items, and the plan items providers report in
/// the Rust transcript as tool activity.
pub(super) fn plan_text(item: &Value) -> Option<String> {
    match item["kind"].as_str()? {
        "plan" => item["text"].as_str().map(str::to_owned),
        "tool" => {
            let frame: Value = serde_json::from_str(item["text"].as_str()?).ok()?;
            (frame["type"] == "plan")
                .then(|| frame["text"].as_str().map(str::to_owned))
                .flatten()
        }
        _ => None,
    }
}

/// The plan to implement when the thread is in plan mode and its latest turn
/// settled with one: the turn's plan, or failing that its reply.
pub(super) fn proposed_plan(thread: &Value, running: bool) -> Option<ProposedPlan> {
    if thread["interactionMode"] != "plan"
        || running
        || thread["rustDraftImages"]
            .as_array()
            .is_some_and(|images| !images.is_empty())
        || coincide_core::composer_context::has_context(&thread["draftContext"])
    {
        return None;
    }
    let mut plan = None;
    let mut reply = None;
    // The latest turn's plan or reply, past any message steered into it.
    for item in thread["items"].as_array()?.iter().rev() {
        if item["kind"] == "user" && item["steered"] != true {
            break;
        }
        match item["kind"].as_str() {
            Some("error") => return None,
            Some("assistant") if reply.is_none() => reply = Some(item),
            _ if plan.is_none() => {
                if let Some(text) = plan_text(item) {
                    plan = Some((item, text));
                }
            }
            _ => {}
        }
    }
    let (source, text) = match plan {
        Some((item, text)) => (item, text),
        None => {
            let item = reply?;
            (item, item["text"].as_str().unwrap_or_default().to_owned())
        }
    };
    let text = text.trim();
    (!text.is_empty()).then(|| ProposedPlan {
        item_id: text_field(source, "id"),
        text: text.to_owned(),
    })
}

fn text_field(item: &Value, key: &str) -> String {
    item[key].as_str().unwrap_or_default().to_owned()
}

/// The card's accessible name: the plan's first heading, else its first line.
pub(super) fn plan_title(plan: &str) -> Option<String> {
    let lines = plan.lines().map(str::trim).collect::<Vec<_>>();
    let heading = lines
        .iter()
        .find(|line| line.starts_with('#'))
        .or_else(|| lines.iter().find(|line| !line.is_empty()))?;
    let title = heading.trim_start_matches(['#', ' ']).trim();
    (!title.is_empty()).then(|| title.to_owned())
}

/// Whether the plan runs longer than its four-line preview, estimated from
/// its lines and how they wrap at the composer's width.
pub(super) fn can_collapse(plan: &str, columns: usize) -> bool {
    plan.lines()
        .map(|line| line.chars().count().div_ceil(columns.max(1)).max(1))
        .sum::<usize>()
        > PREVIEW_LINES
}

/// The card's height limit in a window `viewport` tall, where the rest of the
/// composer takes `others`.
pub(super) fn maximum_card_height(viewport: f32, others: f32) -> f32 {
    let room = viewport - others - TRANSCRIPT_RESERVE;
    MAXIMUM_HEIGHT
        .min((viewport * HEIGHT_FRACTION).floor())
        .min(room)
        .max(0.)
}

pub(super) fn collapsed_threads(saved: &[String], thread: &str, collapsed: bool) -> Vec<String> {
    let mut ids = saved
        .iter()
        .filter(|id| id.as_str() != thread)
        .cloned()
        .collect::<Vec<_>>();
    if collapsed {
        ids.insert(0, thread.to_owned());
    }
    ids.truncate(COLLAPSED_LIMIT);
    ids
}

impl Coincide {
    pub(super) fn proposed_plan(&self) -> Option<ProposedPlan> {
        let thread = self.selected.as_ref()?;
        proposed_plan(thread, self.running.contains(&text(thread, "id")))
    }

    fn plan_collapsed(&self, thread: &str) -> bool {
        self.sidebar_preferences
            .strings(COLLAPSED_KEY)
            .iter()
            .any(|id| id == thread)
    }

    fn set_plan_collapsed(&mut self, thread: &str, collapsed: bool, cx: &mut Context<Self>) {
        let ids = collapsed_threads(
            &self.sidebar_preferences.strings(COLLAPSED_KEY),
            thread,
            collapsed,
        );
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
            let current = engine.store.document("ui-state.json")?.unwrap_or(json!({}));
            anyhow::ensure!(
                current.is_object(),
                "Interface preferences are invalid; existing data was retained"
            );
            let mut patch = json!({});
            patch[COLLAPSED_KEY] = if ids.is_empty() {
                Value::Null
            } else {
                json!(ids)
            };
            engine.store.patch_document("ui-state.json", &patch)
        })();
        match result {
            Ok(document) => self.sidebar_preferences.document = document,
            Err(error) => self.status = format!("Plan card preference could not be saved: {error}"),
        }
        cx.notify();
    }

    /// Switches to build mode and sends "Implement the plan.".
    pub(super) fn implement_plan(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.clone() else {
            return;
        };
        if self.proposed_plan().is_none() {
            return;
        }
        if thread["interactionMode"] != "build" {
            self.perform_composer_command(
                composer_commands::Command::Build,
                composer_commands::Submission::new(&thread, ""),
                window,
                cx,
            );
            if self.selected.as_ref().is_none_or(|selected| {
                selected["id"] != thread["id"] || selected["interactionMode"] != "build"
            }) {
                return;
            }
        }
        self.composer.update(cx, |input, cx| {
            input.set_value(IMPLEMENT_PROMPT, window, cx)
        });
        self.send_selected(false, window, cx);
        if !self.running.contains(&text(&thread, "id")) {
            // Sending failed; its status says why. Leave no prompt behind.
            self.composer
                .update(cx, |input, cx| input.set_value("", window, cx));
        }
    }

    fn open_plan_in_transcript(&mut self, item_id: &str, cx: &mut Context<Self>) {
        let Some(index) = self
            .selected
            .as_ref()
            .and_then(|thread| thread["items"].as_array())
            .and_then(|items| items.iter().position(|item| item["id"] == item_id))
        else {
            return;
        };
        // Tool rows fold their body; the plan opens in full, as Swift's
        // revealItem opens the turn that folds it away.
        if self.expanded.insert(index) {
            self.transcript_list.splice(index..index + 1, 1);
        }
        self.transcript_list.scroll_to_reveal_item(index);
        cx.notify();
    }

    /// The composer's placeholder follows the offer to implement.
    pub(super) fn sync_plan_placeholder(
        &mut self,
        plan: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.plan_card.plan_placeholder != plan {
            self.plan_card.plan_placeholder = plan;
            let wanted = if plan {
                PLAN_PLACEHOLDER
            } else {
                DEFAULT_PLACEHOLDER
            };
            self.composer
                .update(cx, |input, cx| input.set_placeholder(wanted, window, cx));
        }
    }

    pub(super) fn plan_card(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let plan = self.proposed_plan();
        self.sync_plan_placeholder(plan.is_some(), window, cx);
        let plan = plan?;
        if self.plan_card.hidden.contains(&plan.item_id) {
            return None;
        }
        let thread = self
            .selected
            .as_ref()
            .map(|v| text(v, "id"))
            .unwrap_or_default();
        let font = self.conversation_font_size();
        let line = (font * 1.45).ceil();
        let viewport = f32::from(window.viewport_size().height);
        let limit = maximum_card_height(viewport, 160.);
        let collapsible = can_collapse(
            &plan.text,
            (presentation::CONTENT_WIDTH / (font * 0.55)) as usize,
        );
        let collapsed = collapsible && self.plan_collapsed(&thread);
        let body_limit = (limit - CHROME_HEIGHT).max(line);
        let body_height = if collapsed {
            (line * PREVIEW_LINES as f32).min(body_limit)
        } else {
            body_limit
        };
        let key = SharedString::from(format!(
            "plan-card/{}:{thread}/{}",
            thread.len(),
            plan.item_id
        ));
        let body = window.use_keyed_state(key, cx, |_, cx| PlanBody {
            state: cx.new(|cx| TextViewState::markdown(&plan.text, cx)),
            source: plan.text.clone(),
        });
        let state = body.update(cx, |body, cx| {
            if body.source != plan.text {
                body.state
                    .update(cx, |state, cx| state.set_text(&plan.text, cx));
                body.source = plan.text.clone();
            }
            body.state.clone()
        });
        let title = plan_title(&plan.text);
        let icon_button = |id: &str, icon: IconName, label: &'static str| {
            Button::new(SharedString::from(format!("plan-card-{id}")))
                .accessibility_id(SharedString::from(format!("plan-card-{id}")))
                .icon(icon)
                .accessibility_label(label)
                .tooltip(label)
                .ghost()
                .compact()
                .xsmall()
                .w(px(22.))
        };
        let toggle_label = if collapsed {
            "Expand Plan"
        } else {
            "Collapse Plan"
        };
        let header = div()
            .flex()
            .items_center()
            .gap(px(6.))
            .h(px(22.))
            .child(
                div()
                    .text_color(self.color(0xe4e9f2))
                    .child(Icon::new(IconName::ListChecks).xsmall()),
            )
            .child(
                div()
                    .font_semibold()
                    .text_sm()
                    .text_color(self.color(0xe4e9f2).opacity(0.7))
                    .child("Plan ready"),
            )
            .child(div().flex_1())
            .when(collapsible, |header| {
                let thread = thread.clone();
                header.child(
                    icon_button(
                        "toggle",
                        if collapsed {
                            IconName::Maximize2
                        } else {
                            IconName::Minimize2
                        },
                        toggle_label,
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.set_plan_collapsed(&thread, !collapsed, cx)
                    })),
                )
            })
            .child({
                let item = plan.item_id.clone();
                icon_button(
                    "open",
                    IconName::SquareArrowOutUpRight,
                    "Open in Transcript",
                )
                .on_click(
                    cx.listener(move |this, _, _, cx| this.open_plan_in_transcript(&item, cx)),
                )
            })
            .child({
                let text = plan.text.clone();
                icon_button("copy", IconName::Copy, "Copy Plan").on_click(cx.listener(
                    move |this, _, _, cx| {
                        cx.write_to_clipboard(ClipboardItem::new_string(text.clone()));
                        this.status = "Copied".into();
                        cx.notify();
                    },
                ))
            })
            .child({
                let item = plan.item_id.clone();
                icon_button("hide", IconName::X, "Hide Plan").on_click(cx.listener(
                    move |this, _, _, cx| {
                        this.plan_card.hidden.insert(item.clone());
                        this.status = "Plan hidden. It stays in the transcript.".into();
                        cx.notify();
                    },
                ))
            });
        Some(
            div()
                .id("composer-plan-card")
                .role(Role::Group)
                .aria_label(SharedString::from(
                    ["Plan ready".to_owned()]
                        .into_iter()
                        .chain(title)
                        .collect::<Vec<_>>()
                        .join(", "),
                ))
                .flex()
                .flex_col()
                .flex_shrink_0()
                .gap(px(6.))
                .mb_2()
                .pt(px(8.))
                .pb(px(10.))
                .pl(px(14.))
                .pr(px(8.))
                .rounded(px(14.))
                .bg(self.color(0xe4e9f2).opacity(0.05))
                .border_1()
                .border_color(self.color(0x29303d))
                .child(header)
                .child(
                    div()
                        .id("composer-plan-card-body")
                        .max_h(px(body_height))
                        .overflow_y_scroll()
                        .text_size(px(font))
                        .child(transcript::routed(TextView::new(&state), cx)),
                )
                .into_any_element(),
        )
    }

    /// Implement replaces Send while a plan is offered and nothing is typed.
    pub(super) fn implement_button(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let selected = self.selected.as_ref()?;
        if self.proposed_plan().is_none()
            || !self.composer.read(cx).value().trim().is_empty()
            || self.running.contains(&text(selected, "id"))
        {
            return None;
        }
        Some(
            Button::new("implement-plan")
                .accessibility_id("implement-plan")
                .label("Implement")
                .primary()
                .compact()
                .h(px(28.))
                .rounded(px(14.))
                .tooltip("Switch to build mode and implement the plan")
                .on_click(cx.listener(|this, _, window, cx| this.implement_plan(window, cx)))
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thread(items: Value) -> Value {
        json!({"id":"T","interactionMode":"plan","items":items,"draft":""})
    }

    #[::core::prelude::v1::test]
    fn the_latest_settled_turn_offers_its_plan_or_its_reply() {
        let plan = json!({"id":"p","kind":"tool","text":json!({"type":"plan","id":"x","text":"  # Do it\n1. step  "}).to_string()});
        let reply = json!({"id":"r","kind":"assistant","text":"Here is my plan"});
        let user = json!({"id":"u","kind":"user","text":"plan this"});
        let notice = json!({"id":"n","kind":"notice","text":"Turn ended"});
        let found = proposed_plan(&thread(json!([user, plan, reply, notice])), false).unwrap();
        assert_eq!(
            found,
            ProposedPlan {
                item_id: "p".into(),
                text: "# Do it\n1. step".into()
            }
        );
        let found = proposed_plan(&thread(json!([user, reply])), false).unwrap();
        assert_eq!(found.item_id, "r");
        // Swift transcripts keep plans as their own kind.
        let swift = json!({"id":"s","kind":"plan","text":"Swift plan"});
        assert_eq!(
            proposed_plan(&thread(json!([user, swift])), false)
                .unwrap()
                .item_id,
            "s"
        );
    }

    #[::core::prelude::v1::test]
    fn nothing_is_offered_outside_a_settled_plan_turn() {
        let user = json!({"id":"u","kind":"user","text":"plan this"});
        let reply = json!({"id":"r","kind":"assistant","text":"plan"});
        let error = json!({"id":"e","kind":"error","text":"failed"});
        assert!(proposed_plan(&thread(json!([user, reply])), true).is_none());
        assert!(proposed_plan(&thread(json!([user, reply, error])), false).is_none());
        assert!(proposed_plan(&thread(json!([reply, user])), false).is_none());
        let mut build = thread(json!([user, reply]));
        build["interactionMode"] = json!("build");
        assert!(proposed_plan(&build, false).is_none());
        let mut attached = thread(json!([user, reply]));
        attached["draftContext"] = json!([{"kind":"quote"}]);
        assert!(proposed_plan(&attached, false).is_none());
        let empty = json!({"id":"r","kind":"assistant","text":"  \n"});
        assert!(proposed_plan(&thread(json!([user, empty])), false).is_none());
    }

    #[::core::prelude::v1::test]
    fn a_steered_message_does_not_end_the_turn() {
        let user = json!({"id":"u","kind":"user","text":"plan"});
        let plan = json!({"id":"p","kind":"plan","text":"the plan"});
        let steer = json!({"id":"s","kind":"user","text":"also","steered":true});
        let reply = json!({"id":"r","kind":"assistant","text":"ok"});
        assert_eq!(
            proposed_plan(&thread(json!([user, plan, steer, reply])), false)
                .unwrap()
                .item_id,
            "p"
        );
    }

    #[::core::prelude::v1::test]
    fn titles_layout_and_memory_follow_swift() {
        assert_eq!(plan_title("intro\n## Steps\n1."), Some("Steps".into()));
        assert_eq!(plan_title("\n  First line\n"), Some("First line".into()));
        assert_eq!(plan_title("#\n"), None);
        assert!(!can_collapse("a\nb\nc\nd", 80));
        assert!(can_collapse("a\nb\nc\nd\ne", 80));
        assert!(can_collapse(&"x".repeat(400), 80));
        assert_eq!(maximum_card_height(2000., 200.), 260.);
        assert_eq!(maximum_card_height(500., 200.), 180.);
        assert_eq!(maximum_card_height(300., 200.), 0.);
        let saved = vec!["a".to_owned(), "b".to_owned()];
        assert_eq!(collapsed_threads(&saved, "b", true), ["b", "a"]);
        assert_eq!(collapsed_threads(&saved, "a", false), ["b"]);
        let many = (0..250).map(|n| n.to_string()).collect::<Vec<_>>();
        assert_eq!(collapsed_threads(&many, "new", true).len(), 200);
    }
}
