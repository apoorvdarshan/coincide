//! Settings › Usage surfaces reported token activity and provider plan limits.
use super::*;
use crate::native_menu::AccessibleMenuExt as _;
use crate::usage_dashboard::{Account, LimitState};
use chrono::{Local, Utc};
use coincide_core::{
    provider_catalog::ProviderId,
    usage_limits::{DisplayMode, Limits, most_constrained, warning_text},
    usage_presentation::{self as format, Level, Row},
    usage_report::{self as report, PROVIDERS, Report, Totals},
};
use gpui_kit::component::menu::PopupMenuItem;

// Zero selects all locally available history.
const PERIODS: [u32; 5] = [7, 30, 90, 365, 0];

/// Large changes stay readable within a narrow tile; the underlying value is unchanged.
fn compact_trend(trend: f64) -> String {
    let percent = trend.abs() * 100.;
    if percent >= 10_000. {
        format!("{}%", format::tokens(percent.round() as u64))
    } else {
        format::percent(trend.abs())
    }
}

/// A calm 1/2/5 chart scale, like the system chart used in the Swift app.
fn chart_ceiling(highest: f64) -> f64 {
    if !highest.is_finite() || highest <= 0. {
        return 1.;
    }
    let magnitude = 10_f64.powf(highest.log10().floor());
    let step = highest / magnitude;
    magnitude
        * if step <= 1. {
            1.
        } else if step <= 2. {
            2.
        } else if step <= 5. {
            5.
        } else {
            10.
        }
}

fn chart_bucket_days(days: u32) -> u32 {
    days.max(1).div_ceil(90)
}

pub(super) fn provider_id(provider: &str) -> Option<ProviderId> {
    Some(match provider {
        "claude" => ProviderId::Claude,
        "codex" => ProviderId::Codex,
        "cursor" => ProviderId::Cursor,
        "grok" => ProviderId::Grok,
        "opencode" => ProviderId::Opencode,
        "lithos" => ProviderId::Lithos,
        "antigravity" => ProviderId::Antigravity,
        _ => return None,
    })
}
pub(super) fn provider_name(provider: &str) -> &'static str {
    if provider == "acp-devin" {
        return "Devin";
    }
    provider_id(provider).map_or("Agent", |id| {
        coincide_core::provider_catalog::provider(id).display_name
    })
}

pub(super) fn provider_site(provider: &str) -> Option<&'static str> {
    Some(match provider {
        "claude" => "https://claude.ai/settings/usage",
        "codex" => "https://chatgpt.com/codex/settings/usage",
        "cursor" => "https://cursor.com/dashboard",
        "grok" => "https://grok.com/dashboard",
        "opencode" => "https://opencode.ai/console",
        "lithos" => "https://console.lithosai.cloud/",
        "antigravity" => "https://aistudio.google.com/usage",
        "acp-devin" => "https://app.devin.ai/settings/usage",
        _ => return None,
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
#[derive(Clone)]
pub(super) struct Card {
    pub account: Account,
    pub shows_name: bool,
    pub state: LimitState,
}
impl Card {
    pub(super) fn title(&self) -> String {
        format::account_title(
            provider_name(self.account.provider),
            &self.account.name,
            self.account.is_default(),
            self.shows_name,
        )
    }
    pub(super) fn limits(&self) -> Option<&Limits> {
        match &self.state {
            LimitState::Ready(limits) => Some(limits),
            _ => None,
        }
    }
}

/// Keep the phone's observations scoped to the same account as the desktop
/// card. A missing limit is omitted instead of turning it into a zero balance.
pub(super) fn remote_usage(cards: &[Card]) -> Vec<coincide_core::remote::protocol::RemoteUsage> {
    use coincide_core::remote::protocol::{RemoteUsage, RemoteUsageWindow};
    cards
        .iter()
        .filter_map(|card| {
            let limits = card.limits()?;
            let windows: Vec<_> = limits
                .windows
                .iter()
                .filter(|window| window.used_percent.is_finite())
                .map(|window| RemoteUsageWindow {
                    id: window.id.clone(),
                    label: window.label.clone(),
                    used_percent: window.used_percent,
                    resets_at: window.resets_at.map(|date| date.timestamp_millis()),
                })
                .collect();
            if windows.is_empty() {
                return None;
            }
            let provider = provider_name(card.account.provider);
            Some(RemoteUsage {
                provider: card.account.provider.into(),
                provider_name: provider.into(),
                account_id: card.account.id.clone(),
                account_name: (card.shows_name
                    && !card.account.is_default()
                    && card.account.name != provider)
                    .then(|| card.account.name.clone()),
                windows,
                checked_at: Some(limits.checked_at.timestamp_millis()),
            })
        })
        .collect()
}

/// The menu-bar extra and the Usage page share the same account boundaries.
pub(super) fn cards_for(
    settings: &Value,
    dashboard: &crate::usage_dashboard::Dashboard,
    codex_target: Option<&str>,
    codex_state: LimitState,
) -> Vec<Card> {
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
    let mut cards = Vec::new();
    for provider in PROVIDERS {
        if !provider_id(provider)
            .is_some_and(|id| settings_navigation::provider_enabled(settings, id))
        {
            continue;
        }
        let own = accounts
            .iter()
            .filter(|account| account.provider == provider)
            .collect::<Vec<_>>();
        let shows_name = own.len() > 1;
        for account in own {
            let state = if account.api_key {
                LimitState::Unavailable("This API key reports no usage figures. Coincide counts the tokens of turns it runs.".into())
            } else if provider == "codex" {
                let target = if account.is_default() {
                    codex_target.is_none()
                } else {
                    codex_target == Some(account.id.as_str())
                };
                if target {
                    codex_state.clone()
                } else {
                    LimitState::NotRead("Select a conversation that uses this account, then refresh, to read its limits.".into())
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
            } else if account.is_default()
                && matches!(
                    provider,
                    "grok" | "opencode" | "cursor" | "antigravity" | "lithos"
                )
            {
                dashboard
                    .external
                    .get(provider)
                    .cloned()
                    .unwrap_or(LimitState::NotChecked)
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
    if dashboard.data.as_ref().is_some_and(|data| {
        data.registered
            .iter()
            .any(|agent| agent.provider == "acp-devin")
    }) && coincide_core::provider_preferences::enabled(settings, "acp-devin").unwrap_or(false)
    {
        cards.push(Card {
            account: Account {
                provider: "acp-devin",
                id: report::DEFAULT_ACCOUNT.into(),
                name: "Default".into(),
                api_key: false,
                key_variable: None,
            },
            shows_name: false,
            state: dashboard
                .external
                .get("acp-devin")
                .cloned()
                .unwrap_or(LimitState::NotChecked),
        });
    }
    cards
}

impl Coincide {
    fn usage_provider_name(&self, provider: &str) -> String {
        self.usage_history
            .dashboard
            .data
            .as_ref()
            .and_then(|data| {
                data.registered
                    .iter()
                    .find(|agent| agent.provider == provider)
            })
            .map(|agent| agent.name.clone())
            .unwrap_or_else(|| provider_name(provider).to_owned())
    }

    fn usage_site_button(
        &self,
        id: String,
        site: String,
        title: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let external = self.opens_links_in_default_browser()
            || self.selected.is_none()
            || self.browser.is_none();
        let external_site = site.clone();
        div()
            .flex()
            .items_center()
            .gap_1()
            .child(
                Button::new(SharedString::from(id.clone()))
                    .label(title)
                    .small()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        let destination = if external {
                            crate::transcript_links::Destination::Default
                        } else {
                            crate::transcript_links::Destination::BrowserNewTab
                        };
                        this.open_web_link(site.clone(), destination, cx);
                    })),
            )
            .when(!external, |actions| {
                actions.child(
                    Button::new(SharedString::from(format!("{id}-external")))
                        .icon(gpui_kit::assets::IconName::ExternalLink)
                        .accessibility_label("Open in default browser")
                        .tooltip("Open in default browser")
                        .small()
                        .ghost()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.open_web_link(
                                external_site.clone(),
                                crate::transcript_links::Destination::Default,
                                cx,
                            );
                        })),
                )
            })
            .into_any_element()
    }

    fn usage_provider_enabled(&self, provider: &str) -> bool {
        provider_id(provider)
            .is_some_and(|id| settings_navigation::provider_enabled(&self.settings, id))
    }

    /// The Refresh button: saved history again, and the limits Coincide reads.
    pub(super) fn refresh_usage(&mut self, cx: &mut Context<Self>) {
        self.usage_history.load_dashboard();
        // On macOS, the status item owns the background reader while it is
        // visible. Reusing it avoids two refreshes cancelling one another.
        #[cfg(target_os = "macos")]
        if crate::usage_menubar::refresh_for_usage(self.selected.as_ref(), cx) {
            cx.notify();
            return;
        }
        if self.usage_provider_enabled("codex") {
            self.codex_limits.set_context(self.selected.as_ref(), cx);
            self.codex_limits.refresh(cx);
        }
        if self.usage_provider_enabled("claude") {
            self.usage_history.dashboard.claude.refresh(&self.engine);
        }
        self.usage_history.refresh_external(&self.settings);
        cx.notify();
    }

    /// Every enabled provider's accounts, with their limits as read.
    pub(super) fn usage_cards(&self, cx: &App) -> Vec<Card> {
        let codex = self.codex_limits.panel.read(cx);
        let cards = cards_for(
            &self.settings,
            &self.usage_history.dashboard,
            codex.account(),
            crate::usage_dashboard::codex_state(codex.phase()),
        );
        #[cfg(target_os = "macos")]
        {
            let mut cards = cards;
            crate::usage_menubar::reuse_cached(cx, &mut cards);
            cards
        }
        #[cfg(not(target_os = "macos"))]
        {
            cards
        }
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

    /// A quiet, themed surface shared by the usage sections.
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
            .gap_2()
            .when_some(header, |view, header| {
                view.child(
                    div()
                        .px_1()
                        .text_sm()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(cx.theme().foreground)
                        .child(header),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(14.))
                    .p(px(16.))
                    .rounded(px(12.))
                    .border_1()
                    .border_color(cx.theme().border)
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

    fn usage_divider(&self) -> AnyElement {
        div()
            .w_full()
            .h(px(1.))
            .bg(self.color(0x29303d).opacity(0.8))
            .into_any_element()
    }

    /// A section title with what it covers on the right, such as the period.
    fn usage_header_detail(&self, title: &str, detail: &str) -> AnyElement {
        div()
            .flex()
            .flex_wrap()
            .gap_2()
            .justify_between()
            .child(title.to_owned())
            .child(
                div()
                    .text_xs()
                    .text_color(self.color(0x98a6ba))
                    .font_weight(FontWeight::NORMAL)
                    .child(detail.to_owned()),
            )
            .into_any_element()
    }

    fn usage_chip(
        &self,
        id: SharedString,
        selected: bool,
        label: impl Into<SharedString>,
        on_click: impl Fn(&mut Self, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Button::new(id)
            .ghost()
            .compact()
            .selected(selected)
            .label(label)
            .on_click(cx.listener(move |this, _, _, cx| {
                on_click(this, cx);
                cx.notify();
            }))
            .into_any_element()
    }

    fn usage_logo(&self, provider: &str, size: f32) -> AnyElement {
        match chat_layout::provider_mark(provider, size) {
            Some(logo) => logo.into_any_element(),
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
            .flex_wrap()
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
        partial: bool,
        trend: Option<f64>,
        compared: &str,
        cx: &App,
    ) -> AnyElement {
        let muted = self.usage_muted(cx);
        div()
            .flex_1()
            .min_w(px(148.))
            .flex()
            .flex_col()
            .gap(px(4.))
            .px_3()
            .py_3()
            .rounded(px(10.))
            .border_1()
            .border_color(cx.theme().border)
            .bg(self.color(0x111722))
            .overflow_hidden()
            .child(div().text_xs().text_color(muted).child(title.to_owned()))
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_baseline()
                    .gap_1()
                    .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child(
                        if partial && totals.tokens.is_empty() {
                            "—".into()
                        } else {
                            format::tokens(totals.tokens.total())
                        },
                    ))
                    .child(div().text_xs().text_color(muted).child("tokens")),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(muted)
                    .child(format::cost_of(totals, partial)),
            )
            .when_some((!partial).then_some(trend).flatten(), |view, trend| {
                view.child(
                    div()
                        .flex()
                        .flex_wrap()
                        .items_center()
                        .gap_1()
                        .min_w_0()
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
                        .child(format!("{} vs {compared}", compact_trend(trend))),
                )
            })
            .into_any_element()
    }

    /// How the period's tokens split into fresh input, cache reads, cache writes and output.
    fn usage_token_mix(&self, totals: &Totals, cx: &App) -> AnyElement {
        let muted = self.usage_muted(cx);
        let tokens = &totals.tokens;
        let parts = [
            ("Input", tokens.input, self.provider_ink("codex")),
            ("Cache read", tokens.cache_read, self.provider_ink("cursor")),
            (
                "Cache write",
                tokens.cache_write,
                self.provider_ink("opencode"),
            ),
            ("Output", tokens.output, self.provider_ink("claude")),
        ];
        let total = tokens.total().max(1) as f32;
        let mut bar = div()
            .w_full()
            .h(px(6.))
            .rounded_full()
            .overflow_hidden()
            .flex()
            .gap(px(1.))
            .bg(self.color(0x98a6ba).opacity(0.2));
        for (_, count, color) in parts.iter().filter(|part| part.1 > 0) {
            bar = bar.child(
                div()
                    .h_full()
                    .min_w(px(2.))
                    .w(relative(*count as f32 / total))
                    .bg(*color),
            );
        }
        let mut legend = div().flex().flex_wrap().gap(px(16.));
        for (name, count, color) in parts {
            legend = legend.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .child(div().w(px(7.)).h(px(7.)).rounded_full().bg(color))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(FontWeight::MEDIUM)
                                    .child(format::tokens(count)),
                            )
                            .child(div().text_xs().text_color(muted).child(name)),
                    ),
            );
        }
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
                        .bg(self.provider_ink("antigravity")),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .text_sm()
                                .font_weight(FontWeight::MEDIUM)
                                .child(format::tokens(tokens.reasoning)),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(muted)
                                .child("Reasoning (in output)"),
                        ),
                ),
        );
        div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(bar)
            .child(legend)
            .into_any_element()
    }

    /// Tokens or estimated cost, grouped into at most 90 time buckets.
    fn usage_chart(&self, report: &Report, chart_days: u32, cx: &mut Context<Self>) -> AnyElement {
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
        let start = report::days_back(today, chart_days);
        let bucket_days = chart_bucket_days(chart_days);
        let dates = (0..chart_days)
            .step_by(bucket_days as usize)
            .map(|offset| start + chrono::Duration::days(i64::from(offset)))
            .collect::<Vec<_>>();
        let mut buckets = vec![std::collections::BTreeMap::<&str, f64>::new(); dates.len()];
        for row in &report.days {
            if cost && !row.totals.has_priced_tokens() {
                continue;
            }
            let offset = (row.day - start).num_days();
            if offset >= 0 && row.day <= today {
                let index = (offset as u64 / u64::from(bucket_days)) as usize;
                if let Some(bucket) = buckets.get_mut(index) {
                    *bucket.entry(row.provider.as_str()).or_default() += value(&row.totals);
                }
            }
        }
        let highest = buckets
            .iter()
            .map(|bucket| bucket.values().sum::<f64>())
            .fold(0., f64::max);
        let scale = chart_ceiling(highest);
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
            for (provider, amount) in buckets[index].iter().rev() {
                let share = (amount / scale) as f32;
                if share > 0. {
                    column = column.child(
                        div()
                            .w_full()
                            .h(relative(share))
                            .min_h(px(1.))
                            .bg(self.provider_ink(provider)),
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
                        .child(if bucket_days == 1 {
                            format::weekday_label(day)
                        } else {
                            let end = (day + chrono::Duration::days(i64::from(bucket_days - 1)))
                                .min(today);
                            format!("{} – {}", format::day_label(day), format::day_label(end))
                        }),
                );
            for (provider, amount) in &buckets[index] {
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
                                .bg(self.provider_ink(provider)),
                        )
                        .child(div().flex_1().child(self.usage_provider_name(provider)))
                        .child(if cost {
                            format!("≈ {}", format::cost(*amount))
                        } else {
                            format::exact_tokens(amount.round().max(0.) as u64)
                        }),
                );
            }
            plot = plot.child(tooltip);
        }
        let stride = match dates.len() {
            count if count > 30 => 14,
            count if count > 7 => 7,
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
        let mut shown = Vec::new();
        for row in &report.days {
            if !shown.contains(&row.provider.as_str()) {
                shown.push(row.provider.as_str());
            }
        }
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
                    .child(self.usage_provider_name(provider)),
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
                            .child(label(scale))
                            .child(label(scale / 2.))
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
                    .child(format::cost_of(totals, false)),
            )
            .into_any_element()
    }

    fn usage_account_header(&self, card: &Card, cx: &App) -> AnyElement {
        let limits = card.limits();
        div()
            .flex()
            .flex_wrap()
            .items_center()
            .gap_2()
            .child(self.usage_logo(card.account.provider, 16.))
            .child(div().min_w_0().truncate().child(card.title()))
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
        tracked: Option<&Report>,
        period_name: &str,
        mode: DisplayMode,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let now = Utc::now();
        let muted = self.usage_muted(cx);
        let provider = card.account.provider;
        let mut body = Vec::new();
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
                Some("Reported local tokens; may include other sessions if enabled."),
                match totals {
                    Some(totals) => div()
                        .flex()
                        .gap(px(10.))
                        .child(format::tokens(totals.tokens.total()))
                        .child(
                            div()
                                .text_color(muted)
                                .child(format::cost_of(totals, false)),
                        )
                        .into_any_element(),
                    None => div()
                        .text_color(muted)
                        .child("None recorded")
                        .into_any_element(),
                },
                cx,
            ),
        );
        if let Some(site) = provider_site(provider) {
            body.push(self.usage_site_button(
                format!("usage-site-{provider}-{}", card.account.id),
                site.into(),
                "Open provider usage",
                cx,
            ));
        }
        body
    }

    pub(super) fn usage_dashboard(&self, cx: &mut Context<Self>) -> AnyElement {
        let now = Utc::now();
        let dashboard = &self.usage_history.dashboard;
        let muted = self.usage_muted(cx);
        let mode = DisplayMode::saved(&self.settings["usageDisplayMode"]);
        let days = if dashboard.days == 0 {
            dashboard
                .data
                .as_ref()
                .map(|data| data.history_days(now))
                .unwrap_or(1)
        } else {
            dashboard.days
        };
        let period_name = if dashboard.days == 0 {
            "All available".to_owned()
        } else {
            format!("Last {days} days")
        };
        let cards = self.usage_cards(cx);
        let mut enabled = PROVIDERS
            .into_iter()
            .filter(|provider| cards.iter().any(|card| card.account.provider == *provider))
            .collect::<Vec<_>>();
        let registered = dashboard
            .data
            .as_ref()
            .map(|data| {
                data.registered
                    .iter()
                    .filter(|agent| {
                        coincide_core::provider_preferences::enabled(
                            &self.settings,
                            &agent.provider,
                        )
                        .unwrap_or(false)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        enabled.extend(registered.iter().map(|agent| agent.provider.as_str()));
        let records = dashboard
            .data
            .as_ref()
            .map(|data| data.records.as_slice())
            .unwrap_or_default();
        let includes_other_sessions = self.settings["usageIncludesOtherSessions"]
            .as_bool()
            .unwrap_or(true);
        let filter_provider = dashboard
            .provider
            .as_deref()
            .filter(|provider| enabled.contains(provider));
        let filter_account = filter_provider.and(dashboard.account.clone());
        let report = dashboard
            .data
            .as_ref()
            .map(|data| {
                data.report(
                    includes_other_sessions,
                    &enabled,
                    filter_provider,
                    filter_account.as_deref(),
                    days,
                    now,
                )
            })
            .unwrap_or_default();
        let partial = |days| {
            dashboard.data.as_ref().is_none_or(|data| {
                data.history_partial(
                    &enabled,
                    filter_provider,
                    filter_account.as_deref(),
                    days,
                    now,
                )
            })
        };
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
        let loading = dashboard.loading
            || matches!(dashboard.claude.state, Some(LimitState::Reading))
            || dashboard
                .external
                .values()
                .any(|state| matches!(state, LimitState::Reading))
            || matches!(
                self.codex_limits.panel.read(cx).phase(),
                crate::codex_limits_view::Phase::Loading
            );

        let refresh = Button::new("usage-refresh")
            .icon(gpui_kit::assets::IconName::RefreshCw)
            .accessibility_label("Refresh usage and limits")
            .tooltip("Refresh usage and limits")
            .compact()
            .loading(loading)
            .disabled(loading)
            .on_click(cx.listener(|this, _, _, cx| this.refresh_usage(cx)));
        let updated = if loading {
            "Refreshing…".to_owned()
        } else if let Some(data) = &dashboard.data {
            format!("Updated {}", format::relative(data.read_at, now))
        } else {
            String::new()
        };

        // Filters.
        let owner = cx.entity().downgrade();
        let provider_choices = std::iter::once((None, "All agents".to_owned()))
            .chain(enabled.iter().map(|provider| {
                (
                    Some((*provider).to_owned()),
                    self.usage_provider_name(provider),
                )
            }))
            .collect::<Vec<_>>();
        let selected_provider = filter_provider.map(str::to_owned);
        let providers = Button::new("usage-provider-filter")
            .label(
                filter_provider
                    .map(|id| self.usage_provider_name(id))
                    .unwrap_or_else(|| "All agents".to_owned()),
            )
            .accessibility_label("Show usage for agent")
            .compact()
            .dropdown_caret(true)
            .accessible_menu_with_anchor(Anchor::TopRight, move |mut menu, _, _| {
                for (provider, title) in &provider_choices {
                    let owner = owner.clone();
                    let provider = provider.clone();
                    menu = menu.item(
                        PopupMenuItem::new(title.clone())
                            .checked(selected_provider == provider)
                            .on_click(move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.usage_history
                                        .dashboard
                                        .select_provider(provider.clone());
                                    cx.notify();
                                });
                            }),
                    );
                }
                menu
            });
        let mut accounts_filter = None;
        if !account_choices.is_empty() {
            let mut accounts = div().flex().flex_wrap().gap_1().child(self.usage_chip(
                "usage-account-all".into(),
                filter_account.is_none(),
                "All accounts",
                |this, _| this.usage_history.dashboard.account = None,
                cx,
            ));
            for (index, (id, name)) in account_choices.into_iter().enumerate() {
                let selected = filter_account.as_deref() == Some(id.as_str());
                accounts = accounts.child(self.usage_chip(
                    SharedString::from(format!("usage-account-{index}")),
                    selected,
                    name,
                    move |this, _| this.usage_history.dashboard.account = Some(id.clone()),
                    cx,
                ));
            }
            accounts_filter = Some(accounts.into_any_element());
        }
        let owner = cx.entity().downgrade();
        let selected_days = dashboard.days;
        let periods = Button::new("usage-period-filter")
            .label(period_name.clone())
            .accessibility_label("Usage period")
            .compact()
            .dropdown_caret(true)
            .accessible_menu_with_anchor(Anchor::TopRight, move |mut menu, _, _| {
                for days in PERIODS {
                    let owner = owner.clone();
                    menu = menu.item(
                        PopupMenuItem::new(if days == 0 {
                            "All available".into()
                        } else {
                            format!("Last {days} days")
                        })
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
        let mut display_mode = div()
            .flex()
            .items_center()
            .gap(px(2.))
            .p(px(2.))
            .rounded(px(7.))
            .bg(self.color(0x202a3b));
        for (id, label, value, selected) in [
            (
                "usage-display-used",
                "Used",
                "used",
                mode == DisplayMode::Used,
            ),
            (
                "usage-display-remaining",
                "Left",
                "remaining",
                mode == DisplayMode::Remaining,
            ),
        ] {
            display_mode = display_mode.child(
                Button::new(id)
                    .ghost()
                    .compact()
                    .selected(selected)
                    .label(label)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_setting("usageDisplayMode", json!(value), window, cx);
                    })),
            );
        }
        let filters = div()
            .flex()
            .flex_wrap()
            .items_center()
            .gap_2()
            .child(providers)
            .child(periods)
            .child(div().flex_1())
            .child(div().text_xs().text_color(muted).child(updated))
            .child(refresh);

        let comparisons = div()
            .flex()
            .flex_wrap()
            .gap_2()
            .child(self.usage_tile(
                "Today",
                &report.today,
                partial(1),
                report::trend(&report.today, &report.yesterday),
                "yesterday",
                cx,
            ))
            .child(self.usage_tile(
                "Last 7 days",
                &report.last_week,
                partial(7),
                report::trend(&report.last_week, &report.previous_week),
                "prior week",
                cx,
            ))
            .child(self.usage_tile(
                "Last 30 days",
                &report.last_month,
                partial(30),
                report::trend(&report.last_month, &report.previous_month),
                "prior 30 days",
                cx,
            ));

        let current = shown
            .iter()
            .map(|card| card.limits().map(|l| l.current(now)))
            .collect::<Vec<_>>();
        let plan_header = div()
            .flex()
            .items_center()
            .justify_between()
            .gap_2()
            .child(div().font_weight(FontWeight::SEMIBOLD).child("Plan limits"))
            .child(display_mode);
        let closest =
            most_constrained(current.iter().map(Option::as_ref)).map(|(index, window)| {
                let card = shown[index];
                self.usage_section(
                    None,
                    vec![
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_sm()
                            .child(self.usage_logo(card.account.provider, 16.))
                            .child(div().font_weight(FontWeight::SEMIBOLD).child(card.title()))
                            .child(div().flex_1())
                            .child(div().text_xs().text_color(muted).child("Closest limit"))
                            .into_any_element(),
                        self.usage_row(
                            &format::window_row(window, mode, now, &Local),
                            card.account.provider,
                            cx,
                        ),
                    ],
                    None,
                    cx,
                )
            });

        // Daily usage.
        let mut metric = div().flex().gap_1();
        for (index, (label, cost)) in [("Tokens", false), ("Estimated cost", true)]
            .into_iter()
            .enumerate()
        {
            metric = metric.child(self.usage_chip(
                SharedString::from(format!("usage-metric-{index}")),
                dashboard.cost == cost,
                label,
                move |this, _| this.usage_history.dashboard.cost = cost,
                cx,
            ));
        }
        let chart_header = div()
            .flex()
            .flex_wrap()
            .gap_2()
            .items_center()
            .justify_between()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("Usage over time"),
                    )
                    .child(div().text_xs().text_color(muted).child(
                        if chart_bucket_days(days) > 1 {
                            format!(
                                "{period_name} · grouped by {} days",
                                chart_bucket_days(days)
                            )
                        } else {
                            period_name.clone()
                        },
                    )),
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
                } else if partial(days) {
                    "Local usage is incomplete for this period."
                } else {
                    "No reported usage in this period."
                })
                .into_any_element()
        } else if dashboard.cost && !report.period.has_priced_tokens() {
            div()
                .h(px(120.))
                .flex()
                .items_center()
                .justify_center()
                .text_color(muted)
                .child("No cost estimate for this period.")
                .into_any_element()
        } else {
            self.usage_chart(&report, days, cx)
        };

        let selected_total = if partial(days) && report.period.tokens.is_empty() {
            "—".to_owned()
        } else {
            format::tokens(report.period.tokens.total())
        };
        let summary = div()
            .flex()
            .flex_wrap()
            .items_end()
            .justify_between()
            .gap_3()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(div().text_sm().text_color(muted).child(period_name.clone()))
                    .child(
                        div()
                            .flex()
                            .items_baseline()
                            .gap_2()
                            .child(
                                div()
                                    .text_size(px(34.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(selected_total),
                            )
                            .child(div().text_sm().text_color(muted).child("tokens")),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_xs()
                            .text_color(muted)
                            .child("Standard API estimate"),
                    )
                    .child(
                        div()
                            .text_lg()
                            .font_weight(FontWeight::MEDIUM)
                            .child(format::cost_of(&report.period, partial(days))),
                    ),
            );
        let mut activity = vec![summary.into_any_element()];
        if partial(days) && dashboard.data.is_some() {
            activity.push(
                div()
                    .text_xs()
                    .text_color(muted)
                    .child("Usage history is incomplete for this range.")
                    .into_any_element(),
            );
        }
        activity.extend([self.usage_divider(), chart_header, chart]);
        let mut content = div()
            .flex()
            .flex_col()
            .gap_4()
            .child(filters)
            .when_some(accounts_filter, |view, accounts| view.child(accounts))
            .child(self.usage_section(None, activity, None, cx))
            .child(comparisons)
            .when(!report.period.tokens.is_empty(), |view| {
                view.child(self.usage_section(
                    Some(self.usage_header_detail("Token breakdown", &period_name)),
                    vec![self.usage_token_mix(&report.period, cx)],
                    None,
                    cx,
                ))
            })
            .child(plan_header)
            .when_some(closest, |view, card| view.child(card));

        // Plan limits, one section per enabled account.
        if shown.is_empty() && registered.is_empty() {
            content = content.child(self.usage_section(
                None,
                vec![div().text_color(muted).child("No provider is turned on.").into_any_element()],
                None,
                cx,
            ));
        }
        for card in &shown {
            let tracked = card.account.shows_tracked().then(|| {
                dashboard
                    .data
                    .as_ref()
                    .map(|data| {
                        data.report(
                            includes_other_sessions,
                            &enabled,
                            Some(card.account.provider),
                            Some(&card.account.id),
                            30,
                            now,
                        )
                    })
                    .unwrap_or_default()
            });
            content = content.child(self.usage_section(
                Some(self.usage_account_header(card, cx)),
                self.usage_account_body(card, &report, tracked.as_deref(), &period_name, mode, cx),
                None,
                cx,
            ));
        }
        for agent in registered.into_iter().filter(|agent| {
            filter_provider.is_none_or(|id| id == agent.provider)
                && !cards
                    .iter()
                    .any(|card| card.account.provider == agent.provider)
        }) {
            let agent_report = dashboard
                .data
                .as_ref()
                .map(|data| {
                    data.report(
                        includes_other_sessions,
                        &enabled,
                        Some(&agent.provider),
                        None,
                        days,
                        now,
                    )
                })
                .unwrap_or_default();
            let mut body = vec![div().text_color(muted)
                .child("Coincide tracks usage this agent reports. Check your provider account for plan limits.")
                .into_any_element()];
            let tracked = &agent_report.period;
            body.push(
                div()
                    .child(if tracked.tokens.is_empty() {
                        "No additive token usage reported in Coincide for this period.".to_owned()
                    } else {
                        format!(
                            "{} tracked tokens · {}",
                            format::tokens(tracked.tokens.total()),
                            format::cost_of(tracked, false)
                        )
                    })
                    .into_any_element(),
            );
            let usage_site = provider_site(&agent.provider);
            if let Some(site) = usage_site.or(agent.website.as_deref()) {
                body.push(self.usage_site_button(
                    format!("usage-site-{}", agent.provider),
                    site.to_owned(),
                    if usage_site.is_some() {
                        "Open provider usage"
                    } else {
                        "Open provider website"
                    },
                    cx,
                ));
            }
            let header = div()
                .flex()
                .items_center()
                .gap_2()
                .child(self.usage_logo(&agent.provider, 16.))
                .child(agent.name.clone())
                .into_any_element();
            content = content.child(self.usage_section(Some(header), body, None, cx));
        }

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

        // Activity in Coincide.
        let activity = report::activity_filtered(
            records
                .iter()
                .filter(|record| enabled.contains(&record.provider.as_str())),
            days,
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
                .flex_wrap()
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

        let cli_toggle = self.setting_toggle(
            "Include other CLI sessions",
            "Count Claude Code and Codex sessions from this computer alongside Coincide's activity.",
            "usageIncludesOtherSessions",
            true,
            "usage-include-cli-sessions",
            cx,
        );
        content = content.child(self.usage_section(
            Some("Local usage".into_any_element()),
            vec![cli_toggle],
            None,
            cx,
        ));

        // Settings stay below the usage and account details.
        #[cfg(target_os = "macos")]
        {
            let toggle = self.setting_toggle(
                "Show usage in the menu bar",
                "Click the menu-bar item for account limits and usage.",
                "showsUsageInMenuBar",
                true,
                "usage-menubar-enabled",
                cx,
            );
            content = content.child(self.usage_section(
                Some("Menu Bar".into_any_element()),
                vec![toggle],
                None,
                cx,
            ));
        }
        if cfg!(target_os = "macos")
            && enabled.contains(&"opencode")
            && filter_provider.is_none_or(|provider| provider == "opencode")
        {
            content = content.child(self.settings_group(
                "Browser details",
                div().flex().flex_col().gap_2()
                    .child(self.setting_toggle(
                        "Show OpenCode Zen balance",
                        "Use the matching sign-in in Coincide or your default Chrome browser. Chrome may need Full Disk Access and Keychain permission.",
                        "usageBrowserFallbackEnabled",
                        coincide_core::provider_usage::browser_fallback_enabled(&self.settings),
                        "usage-browser-fallback",
                        cx,
                    ))
                    .child(self.usage_site_button("usage-open-opencode-console".into(), "https://opencode.ai/console".into(), "Open OpenCode console", cx)),
            ));
        }

        if cfg!(target_os = "macos")
            && enabled.contains(&"lithos")
            && filter_provider.is_none_or(|provider| provider == "lithos")
        {
            content = content.child(self.settings_group("Lithos console", div().flex().flex_col().gap_2()
                .child(self.setting_toggle(
                    "Show Lithos console usage",
                    "Read balance and recent spend from the active organization signed in to Coincide’s default browser profile. It may differ from your agent’s inference key.",
                    "usageLithosBrowserFallbackEnabled",
                    self.settings["usageLithosBrowserFallbackEnabled"] == true,
                    "usage-lithos-browser-fallback", cx,
                ))
                .child(self.usage_site_button("usage-open-lithos-console".into(), "https://console.lithosai.cloud/".into(), "Open Lithos console", cx)),
            ));
        }

        // Notes.
        let mut notes = div()
            .flex()
            .flex_col()
            .gap(px(6.))
            .px_1()
            .text_xs()
            .text_color(muted)
            .child(
                "Estimates apply standard API rates to local token counts. Subscription limits measure plan usage separately.",
            );
        if report.period.unpriced_tokens > 0 {
            notes = notes.child(format!(
                "{} tokens have no known price and aren’t included in the estimate.",
                format::tokens(report.period.unpriced_tokens)
            ));
        }
        let logs = dashboard.data.as_ref().and_then(|data| data.logs.as_ref());
        notes = notes.child(match logs {
            Some(logs) if !logs.incomplete_providers.is_empty() => format!(
                "Some local usage could not be read completely for {}. Figures may be partial.",
                logs.incomplete_providers.join(" and ")
            ),
            Some(logs) if !logs.complete_providers.is_empty() || !logs.supplemental_providers.is_empty() =>
                "Agent history and reported Coincide turns are read on this computer.".into(),
            _ if self.usage_history.cli_error.is_some() =>
                "Local CLI usage is unavailable; saved Coincide usage is shown.".into(),
            _ => format!("Coincide turns with reported usage are counted. CLI logs on {} have not been read yet.", this_computer()),
        });
        if logs.is_some_and(|logs| !logs.supplemental_providers.is_empty()) {
            notes = notes.child("OpenCode history adds days without saved Coincide totals; overlapping days are left out to avoid double-counting.");
        }
        if logs.is_some_and(|logs| !logs.complete_providers.is_empty()) {
            notes = notes.child("For Claude and Codex, local logs replace saved totals on overlapping days; older saved days remain available.");
        }
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
        if dashboard
            .data
            .as_ref()
            .is_some_and(|data| data.registered_unavailable)
        {
            notes = notes.child("Registered agents could not be read; their usage may be missing. Refresh to try again.");
        }
        content = content.child(notes);
        content.into_any_element()
    }
}

#[cfg(test)]
mod presentation_tests {
    use super::{Card, cards_for, chart_bucket_days, chart_ceiling, compact_trend, remote_usage};
    use crate::usage_dashboard::{Account, Dashboard, LimitState};
    use chrono::{TimeZone, Utc};
    use coincide_core::usage_limits::{Limits, Window, WindowKind};
    use serde_json::json;

    #[test]
    fn large_trends_and_chart_ticks_remain_compact_and_meaningful() {
        assert_eq!(compact_trend(21312.11), "2.13M%");
        assert_eq!(compact_trend(0.025), "2.5%");
        assert_eq!(chart_ceiling(842_000_000.), 1_000_000_000.);
        assert_eq!(chart_ceiling(0.12), 0.2);
        assert_eq!(chart_ceiling(0.), 1.);
        assert_eq!(chart_bucket_days(7), 1);
        assert_eq!(chart_bucket_days(90), 1);
        assert_eq!(chart_bucket_days(91), 2);
        assert_eq!(chart_bucket_days(365), 5);
    }

    #[test]
    fn account_cards_follow_enabled_providers_in_swift_order() {
        let settings = json!({"providers": {"claude":{"isEnabled":false},"codex":{"isEnabled":true},"cursor":{"isEnabled":false},"grok":{"isEnabled":true},"opencode":{"isEnabled":false},"antigravity":{"isEnabled":false}}});
        let cards = cards_for(
            &settings,
            &Dashboard::default(),
            None,
            LimitState::NotChecked,
        );
        assert_eq!(
            cards
                .iter()
                .map(|card| card.account.provider)
                .collect::<Vec<_>>(),
            ["codex", "grok", "lithos"]
        );
    }

    #[test]
    fn remote_usage_preserves_all_provider_accounts_and_real_window_dates() {
        let checked = Utc.timestamp_millis_opt(1_750_000_000_000).unwrap();
        let reset = Utc.timestamp_millis_opt(1_750_100_000_000).unwrap();
        let mut cards = Vec::new();
        for provider in [
            "claude",
            "codex",
            "cursor",
            "grok",
            "opencode",
            "antigravity",
        ] {
            let window = Window::new("weekly", WindowKind::Weekly, "Weekly", 37.5)
                .resetting(Some(reset), None);
            cards.push(Card {
                account: Account {
                    provider,
                    id: "default".into(),
                    name: "Default".into(),
                    api_key: false,
                    key_variable: None,
                },
                shows_name: false,
                state: LimitState::Ready(Limits::new(vec![window], checked)),
            });
        }
        cards.push(Card {
            account: Account {
                provider: "codex",
                id: "work".into(),
                name: "Work".into(),
                api_key: false,
                key_variable: None,
            },
            shows_name: true,
            state: LimitState::Ready(Limits::new(
                vec![Window::new("session", WindowKind::Session, "Session", 12.)],
                checked,
            )),
        });
        cards.push(Card {
            account: Account {
                provider: "claude",
                id: "other".into(),
                name: "Other".into(),
                api_key: false,
                key_variable: None,
            },
            shows_name: true,
            state: LimitState::Unavailable("No reported limit".into()),
        });
        let rows = remote_usage(&cards);
        assert_eq!(rows.len(), 7);
        assert_eq!(
            rows.iter()
                .map(|row| row.provider.as_str())
                .collect::<Vec<_>>(),
            [
                "claude",
                "codex",
                "cursor",
                "grok",
                "opencode",
                "antigravity",
                "codex"
            ]
        );
        assert_eq!(rows[0].windows[0].used_percent, 37.5);
        assert_eq!(rows[0].windows[0].resets_at, Some(1_750_100_000_000));
        assert_eq!(rows[0].checked_at, Some(1_750_000_000_000));
        assert_eq!(rows[0].account_name, None);
        assert_eq!(rows[6].account_id, "work");
        assert_eq!(rows[6].account_name.as_deref(), Some("Work"));
        let wire = serde_json::to_value(&rows[0]).unwrap();
        assert_eq!(wire["accountID"], "default");
        assert_eq!(wire["windows"][0]["resetsAt"], 1_750_100_000_000_i64);
        assert_eq!(wire["checkedAt"], 1_750_000_000_000_i64);
    }
}
