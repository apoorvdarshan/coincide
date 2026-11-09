//! Settings › Usage, laid out as Swift's `UsageSettingsView`: header, filters,
//! the overview tiles, the daily chart, top models and projects, every enabled
//! account's plan limits, Activity in Coincide and the notes. Tokens come from
//! saved turns whose agent reported them; plan limits are read on Refresh.
use super::*;
use crate::usage_dashboard::{Account, LimitState};
use chrono::{Local, NaiveDate, Utc};
use coincide_core::{
    provider_catalog::ProviderId,
    usage_limits::{DisplayMode, Limits, most_constrained, warning_text},
    usage_presentation::{self as format, Level, Row},
    usage_report::{self as report, Event, PROVIDERS, Report, Totals},
};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};

const PERIODS: [u32; 3] = [7, 30, 90];

fn provider_id(provider: &str) -> Option<ProviderId> {
    Some(match provider {
        "claude" => ProviderId::Claude,
        "codex" => ProviderId::Codex,
        "cursor" => ProviderId::Cursor,
        "grok" => ProviderId::Grok,
        "opencode" => ProviderId::Opencode,
        "antigravity" => ProviderId::Antigravity,
        _ => return None,
    })
}
fn provider_name(provider: &str) -> &'static str {
    provider_id(provider).map_or("Agent", |id| {
        coincide_core::provider_catalog::provider(id).display_name
    })
}
/// Where the Swift wording says "this Mac".
fn this_computer() -> &'static str {
    if cfg!(target_os = "macos") {
        "this Mac"
    } else {
        "this computer"
    }
}

/// An enabled account and what Usage knows of its limits.
struct Card {
    account: Account,
    shows_name: bool,
    state: LimitState,
}
impl Card {
    fn title(&self) -> String {
        format::account_title(
            provider_name(self.account.provider),
            &self.account.name,
            self.account.is_default(),
            self.shows_name,
        )
    }
    fn limits(&self) -> Option<&Limits> {
        match &self.state {
            LimitState::Ready(limits) => Some(limits),
            _ => None,
        }
    }
}

impl Coincide {
    fn usage_provider_enabled(&self, provider: &str) -> bool {
        provider_id(provider)
            .is_some_and(|id| settings_navigation::provider_enabled(&self.settings, id))
    }

    /// The Refresh button: saved history again, and the limits Coincide reads.
    pub(super) fn refresh_usage(&mut self, cx: &mut Context<Self>) {
        self.usage_history.load_dashboard();
        if self.usage_provider_enabled("codex") {
            self.codex_limits.set_context(self.selected.as_ref(), cx);
            self.codex_limits.refresh(cx);
        }
        if self.usage_provider_enabled("claude") {
            self.usage_history.dashboard.claude.refresh(&self.engine);
        }
        cx.notify();
    }

    /// Every enabled provider's accounts, with their limits as read.
    fn usage_cards(&self, cx: &App) -> Vec<Card> {
        let dashboard = &self.usage_history.dashboard;
        let accounts = dashboard
            .data
            .as_ref()
            .map(|data| data.accounts.clone())
            .unwrap_or_else(|| {
                PROVIDERS
                    .iter()
                    .map(|provider| Account {
                        provider,
                        id: report::DEFAULT_ACCOUNT.into(),
                        name: "Default".into(),
                        api_key: false,
                        key_variable: None,
                    })
                    .collect()
            });
        let codex = self.codex_limits.panel.read(cx);
        let codex_target = codex.account().map(str::to_owned);
        let codex_state = crate::usage_dashboard::codex_state(codex.phase());
        let mut cards = Vec::new();
        for provider in PROVIDERS {
            if !self.usage_provider_enabled(provider) {
                continue;
            }
            let own = accounts
                .iter()
                .filter(|a| a.provider == provider)
                .collect::<Vec<_>>();
            let shows_name = own.len() > 1;
            for account in own {
                let state = if account.api_key {
                    LimitState::Unavailable(
                        "This API key reports no usage figures. Coincide counts the tokens of turns it runs."
                            .into(),
                    )
                } else if provider == "codex" {
                    let target = if account.is_default() {
                        codex_target.is_none()
                    } else {
                        codex_target.as_deref() == Some(account.id.as_str())
                    };
                    if target {
                        codex_state.clone()
                    } else {
                        LimitState::NotRead(
                            "Select a conversation that uses this account, then refresh, to read its limits."
                                .into(),
                        )
                    }
                } else if provider == "claude" && account.is_default() {
                    dashboard
                        .claude
                        .state
                        .clone()
                        .unwrap_or(LimitState::NotChecked)
                } else if provider == "claude" {
                    LimitState::NotRead(
                        "This version reads plan limits for the default Claude Code account only."
                            .into(),
                    )
                } else {
                    LimitState::NotRead(format!(
                        "This version of Coincide doesn’t read {} plan limits yet.",
                        provider_name(provider)
                    ))
                };
                cards.push(Card {
                    account: account.clone(),
                    shows_name,
                    state,
                });
            }
        }
        cards
    }

    fn usage_muted(&self, cx: &App) -> Hsla {
        cx.theme().muted_foreground
    }

    fn usage_level_color(&self, level: Level, provider: &str, cx: &App) -> Hsla {
        match level {
            Level::Normal => self.provider_ink(provider).into(),
            Level::Near => cx.theme().warning,
            Level::Critical => cx.theme().danger,
        }
    }

    /// A grouped section: its header above a bordered box, as Swift's grouped `Form`.
    fn usage_section(
        &self,
        header: Option<AnyElement>,
        body: Vec<AnyElement>,
        footer: Option<AnyElement>,
        cx: &App,
    ) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .gap_1()
            .when_some(header, |view, header| {
                view.child(
                    div()
                        .px_1()
                        .text_sm()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(self.usage_muted(cx))
                        .child(header),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .p_3()
                    .rounded(px(8.))
                    .border_1()
                    .border_color(self.color(0x29303d))
                    .bg(self.color(0x111722))
                    .children(body),
            )
            .when_some(footer, |view, footer| {
                view.child(
                    div()
                        .px_1()
                        .text_xs()
                        .text_color(self.usage_muted(cx))
                        .child(footer),
                )
            })
            .into_any_element()
    }

    /// A section title with what it covers on the right, such as the period.
    fn usage_header_detail(&self, title: &str, detail: &str) -> AnyElement {
        div()
            .flex()
            .justify_between()
            .child(title.to_owned())
            .child(
                div()
                    .text_xs()
                    .font_weight(FontWeight::NORMAL)
                    .child(detail.to_owned()),
            )
            .into_any_element()
    }

    fn usage_chip(
        &self,
        id: SharedString,
        selected: bool,
        content: AnyElement,
        on_click: impl Fn(&mut Self, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        div()
            .id(id)
            .flex()
            .items_center()
            .gap_1()
            .px_2()
            .py(px(3.))
            .rounded(px(6.))
            .border_1()
            .border_color(if selected {
                self.color(0x98b1d4)
            } else {
                self.color(0x29303d)
            })
            .when(selected, |view| view.bg(self.color(0x202a3b)))
            .text_sm()
            .cursor_pointer()
            .child(content)
            .on_click(cx.listener(move |this, _, _, cx| {
                on_click(this, cx);
                cx.notify();
            }))
            .into_any_element()
    }

    fn usage_logo(&self, provider: &str, size: f32) -> AnyElement {
        match chat_layout::provider_logo(provider) {
            Some(logo) => img(logo)
                .w(px(size))
                .h(px(size))
                .flex_shrink_0()
                .rounded(px(size * 0.2))
                .bg(rgb(0x2b2b2b))
                .into_any_element(),
            None => Icon::new(gpui_kit::assets::IconName::Cpu)
                .xsmall()
                .into_any_element(),
        }
    }

    fn usage_labeled(
        &self,
        label: &str,
        detail: Option<&str>,
        control: AnyElement,
        cx: &App,
    ) -> AnyElement {
        div()
            .flex()
            .items_center()
            .justify_between()
            .gap_3()
            .child(
                div()
                    .flex_1()
                    .min_w(px(80.))
                    .child(label.to_owned())
                    .when_some(detail, |view, detail| {
                        view.child(
                            div()
                                .text_xs()
                                .text_color(self.usage_muted(cx))
                                .child(detail.to_owned()),
                        )
                    }),
            )
            .child(control)
            .into_any_element()
    }

    /// One `UsageRow`: title and value, a bar when there is a total, details below.
    fn usage_row(&self, row: &Row, provider: &str, cx: &App) -> AnyElement {
        let muted = self.usage_muted(cx);
        let color = self.usage_level_color(row.level, provider, cx);
        let value_color: Hsla = if row.is_state {
            muted
        } else if row.level == Level::Normal {
            self.color(0xe4e9f2).into()
        } else {
            color
        };
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .justify_between()
                    .gap_2()
                    .child(row.title.clone())
                    .child(div().text_color(value_color).child(row.value.clone())),
            )
            .when_some(row.bar.as_ref(), |view, bar| {
                view.child(self.usage_bar(bar.fill, bar.pace_mark, color, 6.))
            })
            .when(!row.details.is_empty(), |view| {
                view.child(
                    div()
                        .text_xs()
                        .text_color(muted)
                        .child(row.details.join(" · ")),
                )
            })
            .into_any_element()
    }

    /// A thin rounded track filled in the row's color, with a mark where even
    /// spending across the period would put the fill.
    fn usage_bar(&self, fill: f64, pace: Option<f64>, color: Hsla, height: f32) -> AnyElement {
        let fill = fill.clamp(0., 1.) as f32;
        div()
            .relative()
            .w_full()
            .h(px(height + 4.))
            .flex()
            .items_center()
            .child(
                div()
                    .w_full()
                    .h(px(height))
                    .rounded_full()
                    .bg(self.color(0x98a6ba).opacity(0.25))
                    .child(
                        div()
                            .h_full()
                            .rounded_full()
                            .bg(color)
                            .when(fill > 0., |view| view.min_w(px(height)))
                            .w(relative(fill)),
                    ),
            )
            .when_some(pace, |view, mark| {
                view.child(
                    div()
                        .absolute()
                        .top_0()
                        .left(relative(mark.clamp(0., 0.995) as f32))
                        .w(px(2.))
                        .h(px(height + 4.))
                        .rounded(px(1.))
                        .bg(self.color(0xe4e9f2)),
                )
            })
            .into_any_element()
    }

    fn usage_tile(
        &self,
        title: &str,
        totals: &Totals,
        trend: Option<f64>,
        compared: &str,
        cx: &App,
    ) -> AnyElement {
        let muted = self.usage_muted(cx);
        div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap(px(3.))
            .child(div().text_xs().text_color(muted).child(title.to_owned()))
            .child(
                div()
                    .text_2xl()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(format::tokens(totals.tokens.total())),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(muted)
                    .child(if totals.has_priced_tokens() {
                        format!("≈ {}", format::cost(totals.cost))
                    } else {
                        "No priced usage".into()
                    }),
            )
            .when_some(trend, |view, trend| {
                view.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_1()
                        .text_xs()
                        .text_color(muted)
                        .child(
                            Icon::new(if trend >= 0. {
                                gpui_kit::assets::IconName::ArrowUpRight
                            } else {
                                gpui_kit::assets::IconName::ArrowDownRight
                            })
                            .xsmall(),
                        )
                        .child(format!("{} vs {compared}", format::percent(trend.abs()))),
                )
            })
            .into_any_element()
    }

    /// How the period's tokens split into fresh input, cache reads, cache writes and output.
    fn usage_token_mix(&self, totals: &Totals, title: &str, cx: &App) -> AnyElement {
        let muted = self.usage_muted(cx);
        let ink = self.color(0xe4e9f2);
        let tokens = &totals.tokens;
        let parts = [
            ("Input", tokens.input, 0.95),
            ("Cache read", tokens.cache_read, 0.35),
            ("Cache write", tokens.cache_write, 0.6),
            ("Output", tokens.output, 0.8),
        ];
        let total = tokens.total().max(1) as f32;
        let summary = if totals.has_priced_tokens() {
            format!(
                "{} tokens · ≈ {}",
                format::tokens(tokens.total()),
                format::cost(totals.cost)
            )
        } else {
            format!("{} tokens", format::tokens(tokens.total()))
        };
        let mut bar = div()
            .w_full()
            .h(px(8.))
            .rounded_full()
            .overflow_hidden()
            .flex()
            .gap(px(2.))
            .bg(self.color(0x98a6ba).opacity(0.2));
        for (_, count, alpha) in parts.iter().filter(|part| part.1 > 0) {
            bar = bar.child(
                div()
                    .h_full()
                    .min_w(px(2.))
                    .w(relative(*count as f32 / total))
                    .bg(ink.opacity(*alpha)),
            );
        }
        let mut legend = div().flex().flex_wrap().gap_4();
        for (name, count, alpha) in parts {
            legend = legend.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .child(
                        div()
                            .w(px(7.))
                            .h(px(7.))
                            .rounded_full()
                            .bg(ink.opacity(alpha)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .child(div().text_sm().child(format::tokens(count)))
                            .child(div().text_xs().text_color(muted).child(name)),
                    ),
            );
        }
        legend = legend.child(
            div()
                .flex()
                .flex_col()
                .child(div().text_sm().child(format::tokens(tokens.reasoning)))
                .child(
                    div()
                        .text_xs()
                        .text_color(muted)
                        .child("Reasoning (in output)"),
                ),
        );
        div()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .flex()
                    .justify_between()
                    .text_xs()
                    .text_color(muted)
                    .child(title.to_owned())
                    .child(summary),
            )
            .child(bar)
            .child(legend)
            .into_any_element()
    }

    /// Tokens or estimated cost per day, stacked by provider in its color.
    fn usage_chart(&self, report: &Report, cx: &mut Context<Self>) -> AnyElement {
        let dashboard = &self.usage_history.dashboard;
        let muted = self.usage_muted(cx);
        let cost = dashboard.cost;
        let value = |totals: &Totals| {
            if cost {
                totals.cost
            } else {
                totals.tokens.total() as f64
            }
        };
        let today = Utc::now().with_timezone(&Local).date_naive();
        let start = report::days_back(today, dashboard.days);
        let dates = (0..dashboard.days)
            .map(|offset| start + chrono::Duration::days(i64::from(offset)))
            .collect::<Vec<_>>();
        let rows_for = |day: NaiveDate| report.days.iter().filter(move |row| row.day == day);
        let highest = dates
            .iter()
            .map(|day| rows_for(*day).map(|row| value(&row.totals)).sum::<f64>())
            .fold(0., f64::max);
        let scale = if highest > 0. { highest } else { 1. };
        let label = |amount: f64| {
            if cost {
                format::cost(amount)
            } else {
                format::tokens(amount.round().max(0.) as u64)
            }
        };
        let hovered = dashboard.hovered;
        let mut columns = div().size_full().flex().items_end().gap(px(1.));
        for (index, day) in dates.iter().copied().enumerate() {
            let mut column = div()
                .id(("usage-chart-day", index))
                .flex_1()
                .h_full()
                .flex()
                .flex_col()
                .justify_end()
                .opacity(if hovered.is_none() || hovered == Some(day) {
                    1.
                } else {
                    0.45
                })
                .on_hover(cx.listener(move |this, inside: &bool, _, cx| {
                    let hovered = &mut this.usage_history.dashboard.hovered;
                    if *inside {
                        *hovered = Some(day);
                    } else if *hovered == Some(day) {
                        *hovered = None;
                    }
                    cx.notify();
                }));
            // The first provider sits at the bottom of the stack.
            let rows = rows_for(day).collect::<Vec<_>>();
            for row in rows.iter().rev() {
                let share = (value(&row.totals) / scale) as f32;
                if share > 0. {
                    column = column.child(
                        div()
                            .w_full()
                            .h(relative(share))
                            .min_h(px(1.))
                            .bg(self.provider_ink(&row.provider)),
                    );
                }
            }
            columns = columns.child(column);
        }
        let grid = |at: f32| {
            div()
                .absolute()
                .left_0()
                .right_0()
                .top(relative(at))
                .h(px(1.))
                .bg(self.color(0x29303d))
        };
        let mut plot = div()
            .relative()
            .flex_1()
            .min_w_0()
            .h(px(180.))
            .child(grid(0.))
            .child(grid(0.5))
            .child(grid(0.999))
            .child(columns);
        if let Some(day) = hovered.filter(|day| dates.contains(day)) {
            let index = dates.iter().position(|d| *d == day).unwrap_or(0);
            let mut tooltip = div()
                .absolute()
                .top_0()
                .left(relative(
                    (index as f32 / dates.len().max(1) as f32).min(0.62),
                ))
                .min_w(px(180.))
                .p_2()
                .flex()
                .flex_col()
                .gap_1()
                .rounded(px(8.))
                .border_1()
                .border_color(self.color(0x29303d))
                .bg(self.color(0x202a3b))
                .text_xs()
                .child(
                    div()
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(format::weekday_label(day)),
                );
            for row in rows_for(day) {
                tooltip = tooltip.child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(5.))
                        .child(
                            div()
                                .w(px(6.))
                                .h(px(6.))
                                .rounded_full()
                                .bg(self.provider_ink(&row.provider)),
                        )
                        .child(div().flex_1().child(provider_name(&row.provider)))
                        .child(if cost {
                            format::exact_cost(&row.totals)
                        } else {
                            format::exact_tokens(row.totals.tokens.total())
                        }),
                );
            }
            plot = plot.child(tooltip);
        }
        let stride = match dashboard.days {
            days if days > 30 => 14,
            days if days > 7 => 7,
            _ => 1,
        };
        let mut axis = div().relative().h(px(16.)).ml(px(52.));
        for (index, day) in dates.iter().enumerate() {
            if index % stride == 0 {
                axis = axis.child(
                    div()
                        .absolute()
                        .top_0()
                        .left(relative(index as f32 / dates.len().max(1) as f32))
                        .text_xs()
                        .text_color(muted)
                        .child(format::day_label(*day)),
                );
            }
        }
        let shown = PROVIDERS
            .iter()
            .filter(|provider| report.days.iter().any(|row| row.provider == **provider))
            .collect::<Vec<_>>();
        let mut legend = div().flex().flex_wrap().gap_3().text_xs();
        for provider in shown {
            legend = legend.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .child(
                        div()
                            .w(px(8.))
                            .h(px(8.))
                            .rounded_full()
                            .bg(self.provider_ink(provider)),
                    )
                    .child(provider_name(provider)),
            );
        }
        div()
            .id("usage-daily-chart")
            .flex()
            .flex_col()
            .gap_1()
            .child(
                div()
                    .flex()
                    .gap_1()
                    .child(
                        div()
                            .w(px(48.))
                            .h(px(180.))
                            .flex()
                            .flex_col()
                            .justify_between()
                            .items_end()
                            .text_xs()
                            .text_color(muted)
                            .child(label(highest))
                            .child(label(highest / 2.))
                            .child(label(0.)),
                    )
                    .child(plot),
            )
            .child(axis)
            .child(legend)
            .into_any_element()
    }

    /// A model's or project's row: its name, a share bar of the period, tokens and cost.
    fn usage_totals_row(
        &self,
        label: AnyElement,
        totals: &Totals,
        period: &Totals,
        cx: &App,
    ) -> AnyElement {
        let share = if period.tokens.total() > 0 {
            totals.tokens.total() as f64 / period.tokens.total() as f64
        } else {
            0.
        };
        div()
            .flex()
            .items_center()
            .gap_3()
            .child(div().flex_1().min_w_0().child(label))
            .child(
                div()
                    .w(px(60.))
                    .h(px(5.))
                    .rounded_full()
                    .bg(self.color(0x98a6ba).opacity(0.3))
                    .child(
                        div()
                            .h_full()
                            .rounded_full()
                            .bg(self.color(0xe4e9f2).opacity(0.7))
                            .when(share > 0., |view| view.min_w(px(3.)))
                            .w(relative(share as f32)),
                    ),
            )
            .child(
                div()
                    .min_w(px(52.))
                    .flex()
                    .justify_end()
                    .child(format::tokens(totals.tokens.total())),
            )
            .child(
                div()
                    .min_w(px(64.))
                    .flex()
                    .justify_end()
                    .text_color(self.usage_muted(cx))
                    .child(format::cost_of(totals)),
            )
            .into_any_element()
    }

    fn usage_account_header(&self, card: &Card, cx: &App) -> AnyElement {
        let limits = card.limits();
        div()
            .flex()
            .items_center()
            .gap_2()
            .child(self.usage_logo(card.account.provider, 16.))
            .child(card.title())
            .when_some(limits.and_then(|l| l.plan.clone()), |view, plan| {
                view.child(
                    div()
                        .px(px(6.))
                        .py(px(1.))
                        .rounded_full()
                        .border_1()
                        .border_color(self.color(0x29303d))
                        .bg(self.color(0x202a3b))
                        .text_xs()
                        .font_weight(FontWeight::MEDIUM)
                        .child(format::plan(&plan)),
                )
            })
            .child(div().flex_1())
            .when_some(limits.map(|l| l.checked_at), |view, checked| {
                view.child(
                    div()
                        .text_xs()
                        .font_weight(FontWeight::NORMAL)
                        .text_color(self.usage_muted(cx))
                        .child(format!("Checked {}", format::relative(checked, Utc::now()))),
                )
            })
            .into_any_element()
    }

    fn usage_account_body(
        &self,
        card: &Card,
        report: &Report,
        events: &[Event],
        period_name: &str,
        mode: DisplayMode,
        cx: &App,
    ) -> Vec<AnyElement> {
        let now = Utc::now();
        let muted = self.usage_muted(cx);
        let provider = card.account.provider;
        let mut body = Vec::new();
        let tracked = card.account.shows_tracked().then(|| {
            let own = events
                .iter()
                .filter(|e| e.provider == provider && e.account_id == card.account.id)
                .cloned()
                .collect::<Vec<_>>();
            Report::make(&own, 30, now, &Local)
        });
        match &card.state {
            LimitState::Ready(limits) if limits.has_rows() => {
                let limits = limits.current(now);
                for row in format::rows(&limits, mode, now, &Local) {
                    body.push(self.usage_row(&row, provider, cx));
                }
                if let Some(warning) = limits.warning() {
                    body.push(
                        div()
                            .text_xs()
                            .text_color(if warning.blocks_work() {
                                cx.theme().danger
                            } else {
                                cx.theme().warning
                            })
                            // Swift words the card's warning as used, whatever the display mode.
                            .child(warning_text(
                                warning,
                                provider_name(provider),
                                DisplayMode::Used,
                                now,
                            ))
                            .into_any_element(),
                    );
                }
            }
            state if tracked.is_none() => {
                let text = match state {
                    LimitState::NotChecked => {
                        "Not checked yet. Refresh to read the plan’s limits.".to_owned()
                    }
                    LimitState::Reading => "Checking the plan’s limits…".to_owned(),
                    LimitState::Ready(_) => {
                        "No plan limits reported. Accounts that use an API key have none."
                            .to_owned()
                    }
                    LimitState::Unavailable(text) | LimitState::NotRead(text) => text.clone(),
                };
                body.push(div().text_color(muted).child(text).into_any_element());
            }
            _ => {}
        }
        if let Some(tracked) = tracked {
            let mut rows = div().flex().flex_col().gap_2().child(
                div()
                    .text_xs()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(muted)
                    .child("Turns in Coincide with this key"),
            );
            if tracked.last_month.tokens.total() > 0 {
                for (title, totals) in [
                    ("Today", &tracked.today),
                    ("Last 7 days", &tracked.last_week),
                    ("Last 30 days", &tracked.last_month),
                ] {
                    rows = rows.child(self.usage_row(
                        &format::tracked_row(title, totals),
                        provider,
                        cx,
                    ));
                }
            } else {
                rows = rows.child(
                    div()
                        .text_color(muted)
                        .child("No turns recorded with this key yet."),
                );
            }
            body.push(rows.into_any_element());
        }
        for note in card
            .limits()
            .map(|limits| limits.notes.as_slice())
            .unwrap_or_default()
        {
            body.push(
                div()
                    .text_xs()
                    .text_color(muted)
                    .child(note.clone())
                    .into_any_element(),
            );
        }
        let totals = report
            .accounts
            .get(&report::account_key(provider, &card.account.id))
            .filter(|totals| totals.tokens.total() > 0);
        body.push(
            self.usage_labeled(
                period_name,
                Some("Turns run in Coincide whose agent reported its token use."),
                match totals {
                    Some(totals) => div()
                        .flex()
                        .gap(px(10.))
                        .child(format::tokens(totals.tokens.total()))
                        .child(div().text_color(muted).child(format::cost_of(totals)))
                        .into_any_element(),
                    None => div()
                        .text_color(muted)
                        .child("None recorded")
                        .into_any_element(),
                },
                cx,
            ),
        );
        body
    }

    pub(super) fn usage_dashboard(&self, cx: &mut Context<Self>) -> AnyElement {
        let now = Utc::now();
        let dashboard = &self.usage_history.dashboard;
        let muted = self.usage_muted(cx);
        let mode = DisplayMode::saved(&self.settings["usageDisplayMode"]);
        let period_name = format!("Last {} days", dashboard.days);
        let records = dashboard
            .data
            .as_ref()
            .map(|data| data.records.as_slice())
            .unwrap_or_default();
        let all_events = report::events(records, &[]);
        let filter_provider = dashboard.provider;
        let filter_account = dashboard.account.clone();
        let events = all_events
            .iter()
            .filter(|event| {
                filter_provider.is_none_or(|provider| event.provider == provider)
                    && filter_account
                        .as_deref()
                        .is_none_or(|account| event.account_id == account)
            })
            .cloned()
            .collect::<Vec<_>>();
        let report = Report::make(&events, dashboard.days, now, &Local);
        let cards = self.usage_cards(cx);
        let shown = cards
            .iter()
            .filter(|card| {
                filter_provider.is_none_or(|provider| card.account.provider == provider)
                    && filter_account
                        .as_deref()
                        .is_none_or(|account| card.account.id == account)
            })
            .collect::<Vec<_>>();
        let account_choices = filter_provider
            .map(|provider| {
                cards
                    .iter()
                    .filter(|card| card.account.provider == provider)
                    .map(|card| (card.account.id.clone(), card.account.name.clone()))
                    .collect::<Vec<_>>()
            })
            .filter(|choices| choices.len() > 1)
            .unwrap_or_default();
        let scope_title = match filter_provider {
            None => "All Agents".to_owned(),
            Some(provider) => filter_account
                .as_deref()
                .and_then(|account| {
                    cards.iter().find(|card| {
                        card.account.provider == provider && card.account.id == account
                    })
                })
                .map(|card| {
                    format::account_title(
                        provider_name(provider),
                        &card.account.name,
                        card.account.is_default(),
                        true,
                    )
                })
                .unwrap_or_else(|| provider_name(provider).to_owned()),
        };
        let loading = dashboard.loading
            || matches!(dashboard.claude.state, Some(LimitState::Reading))
            || matches!(
                self.codex_limits.panel.read(cx).phase(),
                crate::codex_limits_view::Phase::Loading
            );

        // Header.
        let header = div()
            .flex()
            .items_center()
            .gap(px(14.))
            .child(
                div()
                    .w(px(44.))
                    .h(px(44.))
                    .flex_shrink_0()
                    .rounded(px(11.))
                    .bg(rgb(0x278349))
                    .text_color(rgb(0xffffff))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(Icon::new(gpui_kit::assets::IconName::ChartColumn)),
            )
            .child(div().flex_1().min_w_0().text_color(muted).child(format!(
                "Plan limits, and the tokens your agents used on {}.",
                this_computer()
            )))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .items_end()
                    .gap_1()
                    .child(
                        Button::new("usage-refresh")
                            .label("Refresh")
                            .loading(loading)
                            .disabled(loading)
                            .on_click(cx.listener(|this, _, _, cx| this.refresh_usage(cx))),
                    )
                    .child(div().text_xs().text_color(muted).child(
                        match (&dashboard.data, dashboard.loading) {
                            (None, true) => "Reading saved usage…".to_owned(),
                            (Some(data), _) => {
                                format!("Updated {}", format::relative(data.read_at, now))
                            }
                            (None, false) => String::new(),
                        },
                    )),
            );

        // Filters.
        let owner = cx.entity().downgrade();
        let providers = Button::new("usage-provider-filter")
            .label(filter_provider.map(provider_name).unwrap_or("All agents"))
            .accessibility_label("Show usage for agent")
            .compact()
            .dropdown_caret(true)
            .dropdown_menu_with_anchor(Anchor::TopRight, move |mut menu, _, _| {
                for provider in std::iter::once(None).chain(PROVIDERS.into_iter().map(Some)) {
                    let owner = owner.clone();
                    menu = menu.item(
                        PopupMenuItem::new(provider.map(provider_name).unwrap_or("All agents"))
                            .checked(filter_provider == provider)
                            .on_click(move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.usage_history.dashboard.select_provider(provider);
                                    cx.notify();
                                });
                            }),
                    );
                }
                menu
            });
        let mut filters = vec![self.usage_labeled("Show", None, providers.into_any_element(), cx)];
        if !account_choices.is_empty() {
            let mut accounts = div().flex().flex_wrap().gap_1().child(self.usage_chip(
                "usage-account-all".into(),
                filter_account.is_none(),
                div().child("All accounts").into_any_element(),
                |this, _| this.usage_history.dashboard.account = None,
                cx,
            ));
            for (index, (id, name)) in account_choices.into_iter().enumerate() {
                let selected = filter_account.as_deref() == Some(id.as_str());
                accounts = accounts.child(self.usage_chip(
                    SharedString::from(format!("usage-account-{index}")),
                    selected,
                    div().child(name).into_any_element(),
                    move |this, _| this.usage_history.dashboard.account = Some(id.clone()),
                    cx,
                ));
            }
            filters.push(self.usage_labeled("Account", None, accounts.into_any_element(), cx));
        }
        let owner = cx.entity().downgrade();
        let selected_days = dashboard.days;
        let periods = Button::new("usage-period-filter")
            .label(format!("Last {selected_days} days"))
            .accessibility_label("Usage period")
            .compact()
            .dropdown_caret(true)
            .dropdown_menu_with_anchor(Anchor::TopRight, move |mut menu, _, _| {
                for days in PERIODS {
                    let owner = owner.clone();
                    menu = menu.item(
                        PopupMenuItem::new(format!("Last {days} days"))
                            .checked(selected_days == days)
                            .on_click(move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.usage_history.dashboard.days = days;
                                    this.usage_history.dashboard.hovered = None;
                                    cx.notify();
                                });
                            }),
                    );
                }
                menu
            });
        filters.push(self.usage_labeled(
            "Period",
            Some("For the chart, the split and the lists below."),
            periods.into_any_element(),
            cx,
        ));

        // Overview.
        let mut overview = vec![
            div()
                .flex()
                .gap(px(14.))
                .child(self.usage_tile(
                    "Today",
                    &report.today,
                    report::trend(&report.today, &report.yesterday),
                    "yesterday",
                    cx,
                ))
                .child(div().w(px(1.)).bg(self.color(0x29303d)))
                .child(self.usage_tile(
                    "Last 7 days",
                    &report.last_week,
                    report::trend(&report.last_week, &report.previous_week),
                    "the 7 days before",
                    cx,
                ))
                .child(div().w(px(1.)).bg(self.color(0x29303d)))
                .child(self.usage_tile(
                    "Last 30 days",
                    &report.last_month,
                    report::trend(&report.last_month, &report.previous_month),
                    "the 30 days before",
                    cx,
                ))
                .into_any_element(),
            self.usage_token_mix(&report.period, &period_name, cx),
        ];
        let current = shown
            .iter()
            .map(|card| card.limits().map(|l| l.current(now)))
            .collect::<Vec<_>>();
        if let Some((index, window)) = most_constrained(current.iter().map(Option::as_ref)) {
            let card = shown[index];
            overview.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .text_xs()
                            .text_color(muted)
                            .child("Closest limit")
                            .child(div().flex_1())
                            .child(self.usage_logo(card.account.provider, 14.))
                            .child(card.title()),
                    )
                    .child(self.usage_row(
                        &format::window_row(window, mode, now, &Local),
                        card.account.provider,
                        cx,
                    ))
                    .into_any_element(),
            );
        }

        // Daily usage.
        let mut metric = div().flex().gap_1();
        for (index, (label, cost)) in [("Tokens", false), ("Estimated cost", true)]
            .into_iter()
            .enumerate()
        {
            metric = metric.child(self.usage_chip(
                SharedString::from(format!("usage-metric-{index}")),
                dashboard.cost == cost,
                div().child(label).into_any_element(),
                move |this, _| this.usage_history.dashboard.cost = cost,
                cx,
            ));
        }
        let chart_header = div()
            .flex()
            .items_center()
            .justify_between()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("Daily usage"))
                    .child(div().text_xs().text_color(muted).child(period_name.clone())),
            )
            .child(metric)
            .into_any_element();
        let chart = if report.days.is_empty() {
            div()
                .h(px(120.))
                .flex()
                .items_center()
                .justify_center()
                .text_color(muted)
                .child(if dashboard.loading {
                    "Reading saved usage…"
                } else {
                    "No usage in this period."
                })
                .into_any_element()
        } else {
            self.usage_chart(&report, cx)
        };

        let mut content = div()
            .flex()
            .flex_col()
            .gap_4()
            .child(self.usage_section(None, vec![header.into_any_element()], None, cx))
            .child(self.usage_section(None, filters, None, cx))
            .child(self.usage_section(Some(scope_title.into_any_element()), overview, None, cx))
            .child(self.usage_section(None, vec![chart_header, chart], None, cx));

        if !report.models.is_empty() {
            let rows = report
                .models
                .iter()
                .take(8)
                .map(|row| {
                    self.usage_totals_row(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(self.usage_logo(&row.provider, 18.))
                            .child(div().min_w_0().truncate().child(if row.model.is_empty() {
                                "Unknown model".to_owned()
                            } else {
                                row.model.clone()
                            }))
                            .into_any_element(),
                        &row.totals,
                        &report.period,
                        cx,
                    )
                })
                .collect();
            content = content.child(self.usage_section(
                Some(self.usage_header_detail("Top Models", &period_name)),
                rows,
                None,
                cx,
            ));
        }
        if !report.projects.is_empty() {
            let rows = report
                .projects
                .iter()
                .take(8)
                .map(|row| {
                    let name = self
                        .projects
                        .iter()
                        .find(|project| text(project, "id").eq_ignore_ascii_case(&row.project_id))
                        .map(|project| text(project, "name"))
                        .filter(|name| !name.is_empty())
                        .unwrap_or_else(|| "Removed project".into());
                    self.usage_totals_row(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .w(px(18.))
                                    .text_color(muted)
                                    .child(Icon::new(gpui_kit::assets::IconName::Folder).xsmall()),
                            )
                            .child(div().min_w_0().truncate().child(name))
                            .into_any_element(),
                        &row.totals,
                        &report.period,
                        cx,
                    )
                })
                .collect();
            content = content.child(self.usage_section(
                Some(self.usage_header_detail("Top Projects", &period_name)),
                rows,
                Some(
                    "Coincide’s threads only: sessions run elsewhere belong to no project here."
                        .into_any_element(),
                ),
                cx,
            ));
        }

        // Plan limits, one section per enabled account.
        if shown.is_empty() {
            content = content.child(self.usage_section(
                Some("Plan Limits".into_any_element()),
                vec![div().text_color(muted).child("No provider is turned on.").into_any_element()],
                None,
                cx,
            ));
        }
        for card in &shown {
            content = content.child(self.usage_section(
                Some(self.usage_account_header(card, cx)),
                self.usage_account_body(card, &report, &all_events, &period_name, mode, cx),
                None,
                cx,
            ));
        }

        // Activity in Coincide.
        let activity = report::activity(
            records,
            dashboard.days,
            filter_provider,
            filter_account.as_deref(),
            now,
            &Local,
        );
        let metric_tile = |title: &str, value: String| {
            div()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(div().text_lg().child(value))
                .child(div().text_xs().text_color(muted).child(title.to_owned()))
        };
        let mut activity_body = vec![
            div()
                .flex()
                .gap(px(28.))
                .child(metric_tile("Turns", format::integer(activity.turns as u64)))
                .child(metric_tile(
                    "Active time",
                    format::hours_minutes_seconds(activity.active_seconds),
                ))
                .child(metric_tile(
                    "Threads",
                    format::integer(activity.threads as u64),
                ))
                .into_any_element(),
        ];
        if let Some(error) = &dashboard.error {
            activity_body.push(
                div()
                    .text_color(cx.theme().danger)
                    .child(format!("Usage history could not be read: {error}"))
                    .into_any_element(),
            );
        }
        content = content.child(self.usage_section(
            Some(self.usage_header_detail("Activity in Coincide", &period_name)),
            activity_body,
            None,
            cx,
        ));

        // Notes.
        let mut notes = div()
            .flex()
            .flex_col()
            .gap(px(6.))
            .text_xs()
            .text_color(muted)
            .child("Costs are estimates at API list prices: what the tokens would cost through the API. Subscription plans aren’t billed per token.");
        if report.period.unpriced_tokens > 0 {
            notes = notes.child(format!(
                "{} tokens are from models without a known price and aren’t in the cost.",
                format::tokens(report.period.unpriced_tokens)
            ));
        }
        notes = notes.child(format!(
            "Usage counts turns run in Coincide whose agent reported its token use. This version doesn’t read the Claude Code or Codex logs on {}. Nothing is uploaded.",
            this_computer()
        ));
        if let Some(skipped) = dashboard
            .data
            .as_ref()
            .map(|data| data.skipped)
            .filter(|n| *n > 0)
        {
            notes = notes.child(format!(
                "{} saved turns have no known agent or finish time and aren’t counted.",
                format::integer(skipped as u64)
            ));
        }
        content = content.child(self.usage_section(None, vec![notes.into_any_element()], None, cx));
        content.into_any_element()
    }
}
