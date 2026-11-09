//! Compact composer meters. Context is a latest request snapshot, never the
//! sum of billed turn totals. Reads are off-thread and bound to the selection.
use super::*;
use crate::native_menu::AccessibleMenuExt as _;
use chrono::DateTime;
use coincide_core::organization::Records;
use gpui_kit::component::{menu::PopupMenuItem, progress::ProgressCircle};

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Target {
    pub thread: String,
    pub selection: Value,
    pub provider: String,
    pub account: String,
    pub last_provider: Option<String>,
}
impl Target {
    pub fn from_thread(thread: &Value) -> Self {
        Self {
            thread: text(thread, "id"),
            selection: thread["selection"].clone(),
            provider: text(&thread["selection"], "provider"),
            account: thread["selection"]["accountID"]
                .as_str()
                .filter(|s| !s.is_empty())
                .unwrap_or("default")
                .into(),
            last_provider: thread["items"]
                .as_array()
                .and_then(|items| items.iter().rev().find(|item| item["kind"] == "user"))
                .and_then(|item| item["provider"].as_str())
                .map(str::to_owned),
        }
    }
    pub fn matches(&self, thread: &Value) -> bool {
        thread["id"] == self.thread && thread["selection"] == self.selection
    }
}
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Snapshot {
    pub input: u64,
    pub output: Option<u64>,
    pub cached: Option<u64>,
    pub window: Option<u64>,
    pub cost: Option<f64>,
}
impl Snapshot {
    fn fraction(&self) -> Option<f64> {
        self.window
            .filter(|n| *n > 0)
            .map(|n| (self.input as f64 / n as f64).clamp(0., 1.))
    }
}
pub(crate) fn read(bytes: &[u8], target: &Target) -> anyhow::Result<Option<Snapshot>> {
    if target
        .last_provider
        .as_deref()
        .is_some_and(|p| p != target.provider)
    {
        return Ok(None);
    }
    let records = Records::parse(bytes)?;
    let latest = records
        .records()
        .iter()
        .filter_map(|record| {
            let thread = record["threadID"].as_str()?;
            let account = record["accountID"]
                .as_str()
                .filter(|s| !s.is_empty())
                .unwrap_or("default");
            if !thread.eq_ignore_ascii_case(&target.thread)
                || record["provider"] != target.provider
                || account != target.account
            {
                return None;
            }
            let finished = DateTime::parse_from_rfc3339(record["finishedAt"].as_str()?).ok()?;
            Some((finished, record))
        })
        .max_by_key(|(date, _)| *date)
        .map(|(_, record)| record);
    let Some(usage) = latest.map(|record| &record["usage"]) else {
        return Ok(None);
    };
    let Some(input) = usage["inputTokens"].as_u64() else {
        return Ok(None);
    };
    Ok(Some(Snapshot {
        input,
        output: usage["outputTokens"].as_u64(),
        cached: usage["cachedInputTokens"].as_u64(),
        window: usage["contextWindow"].as_u64().filter(|n| *n > 0),
        cost: usage["costUSD"]
            .as_f64()
            .filter(|n| n.is_finite() && *n >= 0.),
    }))
}
fn tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.)
    } else {
        n.to_string()
    }
}
impl Coincide {
    pub(super) fn composer_meter_width(&self, cx: &App) -> f32 {
        let Some(thread) = self.selected.as_ref() else {
            return 0.;
        };
        let context = self
            .usage_history
            .context_usage
            .as_ref()
            .is_some_and(|(target, _)| target.matches(thread));
        let provider = thread["selection"]["provider"].as_str().unwrap_or_default();
        let account = thread["selection"]["accountID"]
            .as_str()
            .filter(|s| !s.is_empty())
            .unwrap_or("default");
        let limits = if provider == "codex" {
            let panel = self.codex_limits.panel.read(cx);
            panel.account().unwrap_or("default") == account
                && matches!(panel.phase(), crate::codex_limits_view::Phase::Ready { buckets, .. } if buckets.iter().any(|bucket| !bucket.windows.is_empty()))
        } else {
            provider == "claude"
                && account == "default"
                && matches!(&self.usage_history.dashboard.claude.state, Some(crate::usage_dashboard::LimitState::Ready(limits)) if !limits.windows.is_empty())
        };
        (if context { 28. } else { 0. }) + (if limits { 32. } else { 0. })
    }
    pub(super) fn composer_meters(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(thread) = self.selected.as_ref() else {
            return div().into_any_element();
        };
        let mut context_meter = None;
        let mut view = div().flex().items_center().flex_shrink_0().gap(px(2.));
        if let Some((target, usage)) = self
            .usage_history
            .context_usage
            .as_ref()
            .filter(|(target, _)| target.matches(thread))
        {
            let mut usage = usage.clone();
            if usage.window.is_none() {
                usage.window = self.selection_ui.catalog["models"]
                    .as_array()
                    .and_then(|models| {
                        models
                            .iter()
                            .find(|row| row["id"] == target.selection["modelID"])
                    })
                    .and_then(|row| row["contextWindow"].as_u64())
                    .filter(|n| *n > 0);
            }
            let fraction = usage.fraction();
            let summary = match usage.window {
                Some(window) => format!(
                    "Context window: {:.0}% used ({} of {} tokens)",
                    fraction.unwrap_or(0.) * 100.,
                    tokens(usage.input),
                    tokens(window)
                ),
                None => format!("Context window: {} tokens used", tokens(usage.input)),
            };
            let color = match fraction.unwrap_or(0.) {
                x if x > 0.9 => cx.theme().danger,
                x if x > 0.75 => cx.theme().warning,
                _ => cx.theme().muted_foreground,
            };
            let mut accessible = summary.clone();
            if let Some(value) = usage.output {
                accessible.push_str(&format!(". Output tokens: {}", tokens(value)));
            }
            if let Some(value) = usage.cached {
                accessible.push_str(&format!(". Cached input: {}", tokens(value)));
            }
            if let Some(value) = usage.cost {
                accessible.push_str(&format!(". Cost: ${value:.4}"));
            }
            context_meter = Some(
                Button::new("composer-context-meter")
                    .ghost()
                    .compact()
                    .w(px(26.))
                    .h(px(26.))
                    .p_1()
                    .accessibility_label(accessible.clone())
                    .tooltip(accessible)
                    .child(
                        ProgressCircle::new("composer-context-ring")
                            .value((fraction.unwrap_or(0.) * 100.) as f32)
                            .color(color)
                            .with_size(px(16.)),
                    )
                    .accessible_menu_with_anchor(Anchor::BottomRight, move |mut menu, _, _| {
                        menu = menu.item(PopupMenuItem::new(summary.clone()).disabled(true));
                        for (label, value) in [
                            ("Output tokens", usage.output),
                            ("Cached input", usage.cached),
                        ] {
                            if let Some(value) = value {
                                menu = menu.item(
                                    PopupMenuItem::new(format!("{label}: {}", tokens(value)))
                                        .disabled(true),
                                );
                            }
                        }
                        if let Some(cost) = usage.cost {
                            menu = menu.item(
                                PopupMenuItem::new(format!("Cost: ${cost:.4}")).disabled(true),
                            );
                        }
                        menu
                    })
                    .into_any_element(),
            );
        }
        let provider = text(&thread["selection"], "provider");
        let account = thread["selection"]["accountID"]
            .as_str()
            .filter(|s| !s.is_empty())
            .unwrap_or("default");
        let limits = if provider == "codex" {
            let panel = self.codex_limits.panel.read(cx);
            let matches = panel.account().unwrap_or("default") == account;
            if matches {
                match crate::usage_dashboard::codex_state(panel.phase()) {
                    crate::usage_dashboard::LimitState::Ready(limits) => Some(limits),
                    _ => None,
                }
            } else {
                None
            }
        } else if provider == "claude" && account == "default" {
            match &self.usage_history.dashboard.claude.state {
                Some(crate::usage_dashboard::LimitState::Ready(limits)) => Some(limits.clone()),
                _ => None,
            }
        } else {
            None
        };
        if let Some(limits) = limits
            .map(|limits| limits.current(chrono::Utc::now()))
            .filter(|limits| !limits.windows.is_empty())
        {
            let mut bars = div()
                .flex()
                .flex_col()
                .justify_center()
                .gap(px(3.))
                .w(px(24.))
                .h(px(24.));
            for limit in limits.windows.iter().take(2) {
                let used = limit.used_percent.clamp(0., 100.);
                let color = if used >= 95. {
                    cx.theme().danger
                } else if used >= 90. {
                    cx.theme().warning
                } else {
                    self.provider_ink(&provider).into()
                };
                bars = bars.child(
                    div()
                        .w_full()
                        .h(px(3.))
                        .rounded(px(1.5))
                        .bg(cx.theme().muted_foreground.opacity(0.2))
                        .child(
                            div()
                                .w(relative(((100. - used) / 100.) as f32))
                                .h_full()
                                .rounded(px(1.5))
                                .bg(color),
                        ),
                );
            }
            let label = format!(
                "{} usage limits",
                models_settings::provider_display_name(&provider)
            );
            let accessible = format!(
                "{}. {}",
                label,
                limits
                    .windows
                    .iter()
                    .map(|window| format!(
                        "{}: {:.0}% left",
                        window.label,
                        100. - window.used_percent.clamp(0., 100.)
                    ))
                    .collect::<Vec<_>>()
                    .join(". ")
            );
            let owner = cx.entity().downgrade();
            view = view.child(
                Button::new("composer-usage-meter")
                    .ghost()
                    .compact()
                    .w(px(30.))
                    .h(px(26.))
                    .p_0()
                    .child(bars)
                    .accessibility_label(accessible.clone())
                    .tooltip(accessible)
                    .accessible_menu_with_anchor(Anchor::BottomRight, move |mut menu, _, _| {
                        menu = menu.item(PopupMenuItem::new(label.clone()).disabled(true));
                        for limit in &limits.windows {
                            let reset = limit
                                .resets_at
                                .map(|at| {
                                    format!(
                                        " · resets {}",
                                        at.with_timezone(&chrono::Local).format("%a %H:%M")
                                    )
                                })
                                .unwrap_or_default();
                            menu = menu.item(
                                PopupMenuItem::new(format!(
                                    "{}: {:.0}% left{}",
                                    limit.label,
                                    100. - limit.used_percent.clamp(0., 100.),
                                    reset
                                ))
                                .disabled(true),
                            );
                        }
                        let owner = owner.clone();
                        menu.separator()
                            .item(PopupMenuItem::new("Open Usage").on_click(
                                move |_, window, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.navigate_settings_section(
                                            settings::SettingsSection::Usage,
                                            window,
                                            cx,
                                        )
                                    });
                                },
                            ))
                            .item(
                                PopupMenuItem::new(format!(
                                    "Updated {}",
                                    limits
                                        .checked_at
                                        .with_timezone(&chrono::Local)
                                        .format("%a %H:%M")
                                ))
                                .disabled(true),
                            )
                    }),
            );
        }
        view.children(context_meter).into_any_element()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn target() -> Target {
        Target {
            thread: "T".into(),
            selection: json!({"provider":"codex"}),
            provider: "codex".into(),
            account: "default".into(),
            last_provider: Some("codex".into()),
        }
    }
    #[::core::prelude::v1::test]
    fn context_uses_latest_snapshot_and_rejects_other_accounts_and_provider_switches() {
        let mut rows = vec![];
        for (time, provider, account, usage) in [
            (
                "2026-01-01T01:00:00Z",
                "codex",
                "default",
                json!({"inputTokens":100,"contextWindow":1000}),
            ),
            (
                "2026-01-01T02:00:00Z",
                "codex",
                "default",
                json!({"inputTokens":200,"contextWindow":1000,"turnTotals":{"input":99999}}),
            ),
            (
                "2026-01-01T03:00:00Z",
                "codex",
                "named",
                json!({"inputTokens":999}),
            ),
            (
                "2026-01-01T04:00:00Z",
                "claude",
                "default",
                json!({"inputTokens":888}),
            ),
        ] {
            rows.push(json!({"id":uuid::Uuid::new_v4(),"threadID":"T","provider":provider,"accountID":account,"finishedAt":time,"usage":usage}));
        }
        let bytes = serde_json::to_vec(&rows).unwrap();
        let snapshot = read(&bytes, &target()).unwrap().unwrap();
        assert_eq!(snapshot.input, 200);
        assert_eq!(snapshot.fraction(), Some(0.2));
        let mut changed = target();
        changed.last_provider = Some("claude".into());
        assert!(read(&bytes, &changed).unwrap().is_none());
    }
    #[::core::prelude::v1::test]
    fn context_does_not_invent_snapshot_from_totals_or_reuse_an_older_report() {
        let rows = json!([{"id":uuid::Uuid::new_v4(),"threadID":"T","provider":"codex","finishedAt":"2026-01-01T01:00:00Z","usage":{"inputTokens":12}},
            {"id":uuid::Uuid::new_v4(),"threadID":"T","provider":"codex","finishedAt":"2026-01-01T02:00:00Z","usage":{"turnTotals":{"input":999}}}]);
        assert!(
            read(&serde_json::to_vec(&rows).unwrap(), &target())
                .unwrap()
                .is_none()
        );
    }
}
