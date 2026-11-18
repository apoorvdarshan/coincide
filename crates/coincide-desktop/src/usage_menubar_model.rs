//! Pure menu-bar presentation. Provider limits are never inferred from token totals.
use crate::usage_dashboard::{Data, LimitState};
use crate::usage_dashboard_ui::Card;
use chrono::{DateTime, Local, Utc};
use coincide_core::{
    usage_limits::{DisplayMode, Limits, Unit, Window, most_constrained},
    usage_presentation as format,
    usage_report::{self, Totals},
};
use serde_json::{Value, json};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Metric {
    MostUsed,
    Window(String),
    Balance,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Choice {
    LastActive,
    Closest,
    Account {
        provider: String,
        account: String,
        metric: Metric,
    },
}
impl Choice {
    /// Also reads the synthesized Swift Codable representation if settings were migrated.
    pub fn decode(value: &Value) -> Option<Self> {
        match value.as_str() {
            Some("lastActive") => return Some(Self::LastActive),
            Some("closest") => return Some(Self::Closest),
            _ => {}
        }
        if value.get("lastActive").is_some() {
            return Some(Self::LastActive);
        }
        if value.get("closest").is_some() {
            return Some(Self::Closest);
        }
        let account = value.get("account")?;
        let provider = account["provider"].as_str()?.to_owned();
        if !usage_report::PROVIDERS.contains(&provider.as_str()) {
            return None;
        }
        let id = account["accountID"].as_str()?.to_owned();
        if id.is_empty() || id.len() > 256 || id.chars().any(char::is_control) {
            return None;
        }
        let m = &account["metric"];
        let metric = if m == "mostUsed" || m.get("mostUsed").is_some() {
            Metric::MostUsed
        } else if m == "balance" || m.get("balance").is_some() {
            Metric::Balance
        } else {
            let name = m
                .get("window")
                .and_then(|w| w.as_str().or_else(|| w["_0"].as_str()))?;
            if name.is_empty() || name.len() > 256 || name.chars().any(char::is_control) {
                return None;
            }
            Metric::Window(name.to_owned())
        };
        Some(Self::Account {
            provider,
            account: id,
            metric,
        })
    }
    pub fn encode(&self) -> Value {
        match self {
            Self::LastActive => json!({"lastActive":{}}),
            Self::Closest => json!({"closest":{}}),
            Self::Account {
                provider,
                account,
                metric,
            } => {
                let metric = match metric {
                    Metric::MostUsed => json!({"mostUsed":{}}),
                    Metric::Balance => json!({"balance":{}}),
                    Metric::Window(id) => json!({"window":{"_0":id}}),
                };
                json!({"account":{"provider":provider,"accountID":account,"metric":metric}})
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reading {
    pub provider: Option<String>,
    pub text: Option<String>,
    pub summary: String,
}
fn windows(limits: &Limits) -> impl Iterator<Item = &Window> {
    limits.windows.iter().chain(&limits.model_windows)
}
fn most_used(limits: &Limits) -> Option<&Window> {
    most_constrained([Some(limits)]).map(|(_, window)| window)
}
fn balance(limits: &Limits) -> Option<String> {
    if let Some(credits) = &limits.credits {
        if credits.unlimited {
            return Some("∞".into());
        }
        if let Some(number) = credits
            .balance
            .as_ref()
            .and_then(|s| s.trim().parse::<f64>().ok())
            .filter(|n| n.is_finite() && *n >= 0.)
        {
            return Some(format::decimal(number, 2));
        }
    }
    limits.figures.iter().find_map(|figure| match figure.unit {
        Unit::Currency(_) | Unit::Credits => figure
            .left()
            .filter(|n| n.is_finite())
            .map(|n| format::bare_amount(n, &figure.unit)),
        _ => None,
    })
}
fn current_limits(card: &Card, now: DateTime<Utc>) -> Option<Limits> {
    card.limits().map(|l| l.current(now))
}
fn window_reading(
    card: &Card,
    window: &Window,
    mode: DisplayMode,
    gauge: bool,
    now: DateTime<Utc>,
) -> Reading {
    let percent = window.shown_percent(mode);
    let text = if mode == DisplayMode::Remaining {
        format!("{percent}% left")
    } else {
        format!("{percent}%")
    };
    let reset = window
        .reset_description(now)
        .map(|r| format!(", {r}"))
        .unwrap_or_default();
    Reading {
        provider: (!gauge).then(|| card.account.provider.to_owned()),
        text: Some(text.clone()),
        summary: format!(
            "{} {}: {}{}",
            card.title(),
            window.label,
            format::shown(window, mode),
            reset
        ),
    }
}
fn closest(cards: &[Card], mode: DisplayMode, now: DateTime<Utc>) -> Option<Reading> {
    let limits = cards
        .iter()
        .map(|card| current_limits(card, now))
        .collect::<Vec<_>>();
    let (index, window) = most_constrained(limits.iter().map(Option::as_ref))?;
    Some(window_reading(&cards[index], window, mode, true, now))
}
fn active_card<'a>(cards: &'a [Card], last: Option<(&str, &str)>) -> Option<&'a Card> {
    let (provider, account) = last?;
    cards
        .iter()
        .find(|card| card.account.provider == provider && card.account.id == account)
        .or_else(|| {
            cards
                .iter()
                .find(|card| card.account.provider == provider && card.account.is_default())
        })
}
fn for_card(
    card: &Card,
    metric: &Metric,
    mode: DisplayMode,
    now: DateTime<Utc>,
    active: bool,
) -> Reading {
    let limits = current_limits(card, now);
    if let Some(limits) = limits.as_ref() {
        let using_credits = active
            && limits
                .windows
                .iter()
                .any(|w| w.is_exhausted() && w.continues_on_credits)
            && !windows(limits).any(|w| w.blocks_work());
        if using_credits {
            let value = balance(limits);
            return Reading {
                provider: Some(card.account.provider.into()),
                text: Some(
                    value
                        .map(|v| format!("Credits: {v}"))
                        .unwrap_or_else(|| "Credits".into()),
                ),
                summary: format!("{} is using credits", card.title()),
            };
        }
        let window = match metric {
            Metric::MostUsed => most_used(limits),
            Metric::Window(id) => windows(limits).find(|w| w.id == *id),
            Metric::Balance => None,
        };
        if let Some(window) = window {
            return window_reading(card, window, mode, false, now);
        }
        if matches!(metric, Metric::Balance) || active {
            if let Some(value) = balance(limits) {
                return Reading {
                    provider: Some(card.account.provider.into()),
                    summary: format!("{} balance: {value}", card.title()),
                    text: Some(value),
                };
            }
        }
    }
    Reading {
        provider: Some(card.account.provider.into()),
        text: None,
        summary: format!("{}: no limit reported", card.title()),
    }
}
pub fn reading(
    choice: &Choice,
    cards: &[Card],
    last: Option<(&str, &str)>,
    mode: DisplayMode,
    now: DateTime<Utc>,
) -> Option<Reading> {
    match choice {
        Choice::Closest => closest(cards, mode, now),
        Choice::LastActive => active_card(cards, last)
            .map(|card| for_card(card, &Metric::MostUsed, mode, now, true))
            .or_else(|| closest(cards, mode, now)),
        Choice::Account {
            provider,
            account,
            metric,
        } => cards
            .iter()
            .find(|card| card.account.provider == provider && card.account.id == *account)
            .map(|card| for_card(card, metric, mode, now, false))
            .or_else(|| closest(cards, mode, now)),
    }
}
pub fn interval(value: &Value, busy: bool) -> Option<std::time::Duration> {
    let seconds = match value.as_str().unwrap_or("automatic") {
        "everyMinute" => 60,
        "every5Minutes" => 300,
        "every15Minutes" => 900,
        "every30Minutes" => 1800,
        "everyHour" => 3600,
        "manual" => return None,
        _ if busy => 300,
        _ => 900,
    };
    Some(std::time::Duration::from_secs(seconds))
}
fn choice_option(choice: Choice, title: String) -> Value {
    json!({"title":title,"value":choice.encode()})
}
pub fn options(cards: &[Card], secondary: bool) -> Vec<Value> {
    let mut choices = Vec::new();
    if secondary {
        choices.push(json!({"title":"None","value":null}));
    }
    choices.push(choice_option(
        Choice::LastActive,
        "Auto (last active agent)".into(),
    ));
    choices.push(choice_option(
        Choice::Closest,
        "Closest limit across all".into(),
    ));
    for card in cards {
        let choice = |metric| Choice::Account {
            provider: card.account.provider.into(),
            account: card.account.id.clone(),
            metric,
        };
        choices.push(choice_option(
            choice(Metric::MostUsed),
            format!("{} · Most used limit", card.title()),
        ));
        if let Some(limits) = card.limits() {
            for window in windows(limits) {
                choices.push(choice_option(
                    choice(Metric::Window(window.id.clone())),
                    format!("{} · {}", card.title(), window.label),
                ));
            }
            if balance(limits).is_some() {
                choices.push(choice_option(
                    choice(Metric::Balance),
                    format!("{} · Balance", card.title()),
                ));
            }
        }
    }
    choices
}

fn options_with_current(cards: &[Card], secondary: bool, selected: Option<&Choice>) -> Vec<Value> {
    let mut choices = options(cards, secondary);
    if let Some(selected) = selected {
        let value = selected.encode();
        if !choices.iter().any(|choice| choice["value"] == value) {
            choices.push(json!({"title":"Not reported now","value":value}));
        }
    }
    choices
}
fn period(name: &str, totals: &Totals, has_history: bool, partial: bool) -> Value {
    json!({
        "label": name,
        "tokens": if has_history && (totals.tokens.total() > 0 || !partial) { format::tokens(totals.tokens.total()) } else { "—".into() },
        "cost": format::cost_of(totals, partial),
    })
}

/// Send only the app's presentation colors to AppKit; its system appearance
/// selects the light or dark palette when the app is set to follow the system.
fn menu_palette(settings: &Value, dark: bool) -> Value {
    let (key, fallback) = if dark {
        ("darkTheme", "carbon")
    } else {
        ("lightTheme", "carbon-light")
    };
    let id = settings[key].as_str().unwrap_or(fallback);
    let palette = crate::settings::PALETTES
        .iter()
        .find(|p| p.id == id && p.dark == dark)
        .or_else(|| crate::settings::PALETTES.iter().find(|p| p.id == fallback))
        .expect("default usage menu palette");
    json!({"surface": palette.surface, "ink": palette.ink, "accent": palette.accent})
}
pub fn snapshot(
    cards: &[Card],
    data: Option<&Data>,
    settings: &Value,
    current: Option<(&str, &str)>,
    now: DateTime<Utc>,
) -> Value {
    let mode = DisplayMode::saved(&settings["usageDisplayMode"]);
    let is_enabled = |provider: &str| cards.iter().any(|card| card.account.provider == provider);
    let last = current
        .filter(|(provider, _)| is_enabled(provider))
        .or_else(|| {
            data.and_then(|d| {
                d.records
                    .iter()
                    .filter(|record| is_enabled(&record.provider))
                    .max_by_key(|record| record.finished_at)
                    .map(|record| (record.provider.as_str(), record.account_id.as_str()))
            })
        });
    let primary = Choice::decode(&settings["menuBarUsage"]).unwrap_or(Choice::LastActive);
    let secondary = Choice::decode(&settings["menuBarSecondaryUsage"]);
    let mut readings = Vec::new();
    if let Some(first) = reading(&primary, cards, last, mode, now) {
        readings.push(first);
    }
    if let Some(second) = secondary
        .as_ref()
        .and_then(|choice| reading(choice, cards, last, mode, now))
        && !readings.contains(&second)
    {
        readings.push(second);
    }
    let mut enabled = usage_report::PROVIDERS
        .into_iter()
        .filter(|provider| is_enabled(provider))
        .collect::<Vec<_>>();
    if let Some(data) = data {
        enabled.extend(
            data.registered
                .iter()
                .filter(|agent| {
                    coincide_core::provider_preferences::enabled(settings, &agent.provider)
                        .unwrap_or(false)
                })
                .map(|agent| agent.provider.as_str()),
        );
    }
    let report = data
        .map(|data| {
            data.report(
                settings["usageIncludesOtherSessions"]
                    .as_bool()
                    .unwrap_or(true),
                &enabled,
                None,
                None,
                30,
                now,
            )
        })
        .unwrap_or_default();
    let partial =
        |days| data.is_none_or(|data| data.history_partial(&enabled, None, None, days, now));
    let month_incomplete = partial(30);
    let tracked_label = |totals: &Totals| {
        let tokens = format!("{} tokens", format::tokens(totals.tokens.total()));
        match format::api_estimate(totals, month_incomplete) {
            Some(estimate) => format!("{tokens} · {estimate}"),
            None => tokens,
        }
    };
    let mut accounts = cards.iter().map(|card| {
        let limits = current_limits(card, now);
        let rows = limits.as_ref().map(|limits| format::rows(limits, mode, now, &Local))
            .unwrap_or_default().into_iter().map(|row| {
                let level = match row.level {
                    format::Level::Normal => "normal",
                    format::Level::Near => "near",
                    format::Level::Critical => "critical",
                };
                json!({"title":row.title,"value":row.value,"detail":row.details.join(" · "),"fill":row.bar.map(|bar|bar.fill),"level":level})
            }).collect::<Vec<_>>();
        let placeholder = match &card.state {
            LimitState::Reading => "Checking limits…",
            LimitState::NotChecked => "Limits not checked",
            LimitState::Unavailable(reason) | LimitState::NotRead(reason) => reason.as_str(),
            LimitState::Ready(_) if rows.is_empty() => "No limits reported",
            _ => "",
        };
        let key = usage_report::account_key(card.account.provider, &card.account.id);
        let tracked = report.accounts.get(&key).map(tracked_label);
        json!({
            "title":card.title(), "provider":card.account.provider,
            "plan":limits.as_ref().and_then(|l|l.plan.clone()),
            "checked":limits.as_ref().map(|l|format!("Checked {}",format::relative(l.checked_at,now))),
            "rows":rows, "placeholder":placeholder, "tracked":tracked,
        })
    }).collect::<Vec<_>>();
    if let Some(data) = data {
        for agent in data
            .registered
            .iter()
            .filter(|agent| enabled.contains(&agent.provider.as_str()))
        {
            let usage = data.report(
                settings["usageIncludesOtherSessions"]
                    .as_bool()
                    .unwrap_or(true),
                &enabled,
                Some(&agent.provider),
                None,
                30,
                now,
            );
            let totals = &usage.period;
            let tracked = (!totals.tokens.is_empty()).then(|| tracked_label(totals));
            accounts.push(json!({
                "title":agent.name, "provider":agent.provider,
                "plan":null, "checked":null, "rows":[],
                "placeholder":if agent.provider == "acp-devin" { "Open Usage & limits for quota and credits" } else { "Account limits not reported" }, "tracked":tracked,
            }));
        }
    }
    let empty = accounts.is_empty();
    let modes = if mode == DisplayMode::Remaining {
        "remaining"
    } else {
        "used"
    };
    let tooltip = if readings.is_empty() {
        "Coincide usage: no plan limits reported".to_owned()
    } else {
        format!(
            "Coincide usage: {}",
            readings
                .iter()
                .map(|r| r.summary.as_str())
                .collect::<Vec<_>>()
                .join(". ")
        )
    };
    json!({
        "readings":readings.iter().map(|r|json!({"provider":r.provider,"text":r.text})).collect::<Vec<_>>(),
        "tooltip":tooltip, "accounts":accounts,
        "periods":[period("Today",&report.today,data.is_some(),partial(1)),period("7 days",&report.last_week,data.is_some(),partial(7)),period("30 days",&report.last_month,data.is_some(),month_incomplete)],
        "overviewNote": if month_incomplete { "Standard API rates · Local history may be incomplete" } else { "Estimates at standard API rates" },
        "updated":data.map(|d|format::relative(d.read_at,now)), "mode":modes,
        "primary":primary.encode(), "secondary":secondary.as_ref().map(Choice::encode),
        "primaryOptions":options_with_current(cards,false,Some(&primary)),
        "secondaryOptions":options_with_current(cards,true,secondary.as_ref()),
        "refresh":settings["usageRefresh"].as_str().unwrap_or("automatic"), "empty":empty,
        "appearance":settings["appearance"].as_str().filter(|value| matches!(*value,"dark"|"light")).unwrap_or("system"),
        "themes":{"dark":menu_palette(settings,true),"light":menu_palette(settings,false)},
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage_dashboard::Account;
    use chrono::{Duration, TimeZone};
    use coincide_core::usage_limits::{Credits, WindowKind};
    use coincide_core::usage_report::{TokenTotals, TurnRecord};

    #[test]
    fn menu_snapshot_uses_selected_themes_and_safely_falls_back() {
        let now = Utc::now();
        let view = snapshot(
            &[],
            None,
            &json!({"appearance":"dark", "darkTheme":"forest", "lightTheme":"sepia"}),
            None,
            now,
        );
        assert_eq!(view["appearance"], "dark");
        assert_eq!(view["themes"]["dark"]["surface"], 0x18241D);
        assert_eq!(view["themes"]["light"]["surface"], 0xFBF6EC);

        let fallback = snapshot(
            &[],
            None,
            &json!({"appearance":"invalid", "darkTheme":"sepia", "lightTheme":"unknown"}),
            None,
            now,
        );
        assert_eq!(fallback["appearance"], "system");
        assert_eq!(fallback["themes"]["dark"]["surface"], 0x101010);
        assert_eq!(fallback["themes"]["light"]["surface"], 0xFFFFFF);
    }

    fn card(provider: &'static str, account: &str, used: f64, at: DateTime<Utc>) -> Card {
        Card {
            account: Account {
                provider,
                id: account.into(),
                name: if account == "default" {
                    "Default"
                } else {
                    "Work"
                }
                .into(),
                api_key: false,
                key_variable: None,
            },
            shows_name: account != "default",
            state: LimitState::Ready(Limits::new(
                vec![
                    Window::new("session", WindowKind::Session, "Session", used)
                        .resetting(Some(at + Duration::hours(2)), Some(300)),
                ],
                at,
            )),
        }
    }
    #[test]
    fn menu_marks_cost_coverage_separately_from_the_token_total() {
        let mut totals = Totals {
            tokens: TokenTotals::new(0, 7_300_000_000, 0, 0, 0, 0),
            cost: 1.77,
            unpriced_tokens: 7_299_000_000,
            ..Totals::default()
        };
        let mixed = period("7 days", &totals, true, false);
        assert_eq!(mixed["tokens"], "7.3B");
        assert_eq!(mixed["cost"], "≈ $1.77 (partial)");
        totals.unpriced_tokens = 0;
        assert_eq!(
            period("7 days", &totals, true, true)["cost"],
            "≈ $1.77 (partial)"
        );
        assert_eq!(period("7 days", &totals, true, false)["cost"], "≈ $1.77");
    }

    #[test]
    fn every_provider_uses_its_own_reported_limit_and_account() {
        let now = Utc.with_ymd_and_hms(2026, 11, 13, 12, 0, 0).unwrap();
        for provider in usage_report::PROVIDERS {
            let cards = vec![
                card(provider, "default", 20., now),
                card(provider, "work", 65., now),
            ];
            let active = reading(
                &Choice::LastActive,
                &cards,
                Some((provider, "work")),
                DisplayMode::Used,
                now,
            )
            .unwrap();
            assert_eq!(active.provider.as_deref(), Some(provider));
            assert_eq!(active.text.as_deref(), Some("65%"));
            let choice = Choice::Account {
                provider: provider.into(),
                account: "default".into(),
                metric: Metric::Window("session".into()),
            };
            assert_eq!(
                reading(
                    &choice,
                    &cards,
                    Some((provider, "work")),
                    DisplayMode::Remaining,
                    now
                )
                .unwrap()
                .text
                .as_deref(),
                Some("80% left")
            );
            assert_eq!(Choice::decode(&choice.encode()), Some(choice));
        }
    }
    #[test]
    fn closest_uses_all_model_windows_and_missing_accounts_do_not_borrow_another_account() {
        let now = Utc::now();
        let mut claude = card("claude", "default", 30., now);
        if let LimitState::Ready(limits) = &mut claude.state {
            limits
                .model_windows
                .push(Window::new("model", WindowKind::Weekly, "Model", 90.));
        }
        let cards = vec![card("codex", "work", 70., now), claude];
        let closest = reading(&Choice::Closest, &cards, None, DisplayMode::Used, now).unwrap();
        assert_eq!(closest.provider, None);
        assert_eq!(closest.text.as_deref(), Some("90%"));
        // A removed last-active account may fall back only to that provider's default.
        let missing = reading(
            &Choice::LastActive,
            &cards,
            Some(("codex", "removed")),
            DisplayMode::Used,
            now,
        )
        .unwrap();
        assert_eq!(missing.provider, None);
        assert_eq!(missing.text.as_deref(), Some("90%"));
    }
    #[test]
    fn credits_are_shown_only_when_the_provider_says_the_plan_continues_on_credits() {
        let now = Utc::now();
        let mut c = card("codex", "default", 100., now);
        if let LimitState::Ready(limits) = &mut c.state {
            limits.windows[0].continues_on_credits = true;
            limits.credits = Some(Credits {
                has_credits: true,
                unlimited: false,
                balance: Some("12.40".into()),
            });
        }
        let active = reading(
            &Choice::LastActive,
            &[c.clone()],
            Some(("codex", "default")),
            DisplayMode::Used,
            now,
        )
        .unwrap();
        assert_eq!(active.text.as_deref(), Some("Credits: 12.4"));
        if let LimitState::Ready(limits) = &mut c.state {
            limits
                .windows
                .push(Window::new("weekly", WindowKind::Weekly, "Weekly", 100.));
        }
        let blocked = reading(
            &Choice::LastActive,
            &[c],
            Some(("codex", "default")),
            DisplayMode::Used,
            now,
        )
        .unwrap();
        assert_eq!(blocked.text.as_deref(), Some("100%"));
    }
    #[test]
    fn absent_usage_is_not_invented_and_history_counts_all_providers() {
        let now = Utc::now();
        let mut cards = Vec::new();
        let mut records = Vec::new();
        for provider in usage_report::PROVIDERS {
            let mut c = card(provider, "default", 20., now);
            c.state = LimitState::NotRead("unavailable".into());
            cards.push(c);
            records.push(TurnRecord {
                thread_id: None,
                project_id: None,
                provider: provider.into(),
                account_id: "default".into(),
                model: None,
                started_at: None,
                finished_at: now,
                turn_totals: Some(TokenTotals::new(10, 0, 0, 0, 2, 0)),
            });
        }
        let data = Data {
            records,
            skipped: 0,
            accounts: vec![],
            registered: vec![],
            registered_unavailable: false,
            read_at: now,
            logs: None,
            report_cache: Default::default(),
        };
        let view = snapshot(&cards, Some(&data), &json!({}), None, now);
        assert_eq!(
            view["accounts"].as_array().unwrap().len(),
            usage_report::PROVIDERS.len()
        );
        assert!(
            view["accounts"]
                .as_array()
                .unwrap()
                .iter()
                .all(|row| row["rows"].as_array().unwrap().is_empty()
                    && row["placeholder"] == "unavailable")
        );
        assert_eq!(
            view["periods"][0]["tokens"],
            (12 * usage_report::PROVIDERS.len()).to_string()
        );
        assert!(
            view["readings"]
                .as_array()
                .unwrap()
                .iter()
                .all(|r| r["text"].is_null())
        );
    }
    #[test]
    fn missing_recent_turn_totals_are_not_shown_as_zero_while_logs_load() {
        use coincide_core::cli_usage_logs::{LoggedEvent, Scan};
        use coincide_core::usage_report::Event;
        let now = Utc::now();
        let cards = vec![card("codex", "default", 20., now)];
        let mut data = Data {
            records: vec![TurnRecord {
                thread_id: None,
                project_id: None,
                provider: "codex".into(),
                account_id: "default".into(),
                model: None,
                started_at: None,
                finished_at: now,
                turn_totals: None,
            }],
            skipped: 0,
            accounts: vec![],
            registered: vec![],
            registered_unavailable: false,
            read_at: now,
            logs: None,
            report_cache: Default::default(),
        };
        let loading = snapshot(&cards, Some(&data), &json!({}), None, now);
        assert_eq!(loading["periods"][0]["tokens"], "—");
        assert_eq!(loading["periods"][1]["tokens"], "—");
        let tokens = TokenTotals::new(30, 0, 0, 0, 5, 0);
        data.set_logs(Some(std::sync::Arc::new(Scan {
            events: vec![LoggedEvent {
                event: Event {
                    date: now,
                    provider: "codex".into(),
                    account_id: "default".into(),
                    model: None,
                    tokens,
                    prompt_tokens: 0,
                    project_id: None,
                },
                is_from_coincide: true,
            }],
            complete_providers: vec!["codex"],
            ..Scan::default()
        })));
        let loaded = snapshot(&cards, Some(&data), &json!({}), None, now);
        assert_eq!(loaded["periods"][0]["tokens"], "35");
        assert_eq!(loaded["periods"][1]["tokens"], "35");
        assert_eq!(loaded["overviewNote"], "Estimates at standard API rates");
    }
    #[test]
    fn registered_agent_usage_appears_without_inventing_account_limits() {
        use crate::usage_dashboard::RegisteredAgent;
        let now = Utc::now();
        let data = Data {
            records: vec![TurnRecord {
                thread_id: None,
                project_id: None,
                provider: "acp-example".into(),
                account_id: "default".into(),
                model: None,
                started_at: None,
                finished_at: now,
                turn_totals: Some(TokenTotals::new(25, 0, 0, 0, 5, 0)),
            }],
            skipped: 0,
            accounts: vec![],
            registered: vec![RegisteredAgent {
                provider: "acp-example".into(),
                name: "Example".into(),
                website: None,
            }],
            registered_unavailable: false,
            read_at: now,
            logs: None,
            report_cache: Default::default(),
        };
        let view = snapshot(&[], Some(&data), &json!({}), None, now);
        assert_eq!(view["periods"][0]["tokens"], "30");
        assert_eq!(view["accounts"][0]["title"], "Example");
        assert_eq!(
            view["accounts"][0]["placeholder"],
            "Account limits not reported"
        );
        assert_eq!(view["accounts"][0]["tracked"], "30 tokens");
        assert_eq!(view["empty"], false);
        let disabled = snapshot(
            &[],
            Some(&data),
            &json!({"providers":{"acp-example":{"isEnabled":false}}}),
            None,
            now,
        );
        assert!(disabled["accounts"].as_array().unwrap().is_empty());
        assert_eq!(disabled["empty"], true);
    }
    #[test]
    fn choices_and_refresh_settings_preserve_swift_values() {
        assert_eq!(
            Choice::decode(&json!({"lastActive":{}})),
            Some(Choice::LastActive)
        );
        assert_eq!(
            Choice::decode(&json!({"closest":{}})),
            Some(Choice::Closest)
        );
        assert_eq!(
            Choice::decode(
                &json!({"account":{"provider":"codex","accountID":"default","metric":{"window":{"_0":"primary"}}}})
            ),
            Some(Choice::Account {
                provider: "codex".into(),
                account: "default".into(),
                metric: Metric::Window("primary".into())
            })
        );
        assert!(
            Choice::decode(
                &json!({"account":{"provider":"bad","accountID":"default","metric":"balance"}})
            )
            .is_none()
        );
        assert_eq!(
            interval(&json!("automatic"), true),
            Some(std::time::Duration::from_secs(300))
        );
        assert_eq!(
            interval(&json!("automatic"), false),
            Some(std::time::Duration::from_secs(900))
        );
        assert_eq!(interval(&json!("manual"), true), None);
    }

    #[test]
    fn disabled_provider_history_does_not_appear_in_overall_or_auto_choice() {
        // Keep both earlier records on the same local day even when this test
        // runs just after midnight in the machine's time zone.
        let now = Local::now()
            .date_naive()
            .and_hms_opt(12, 0, 0)
            .unwrap()
            .and_local_timezone(Local)
            .single()
            .unwrap()
            .with_timezone(&Utc);
        let cards = vec![
            card("claude", "default", 40., now),
            card("codex", "default", 60., now),
        ];
        let record = |provider: &str, count: u64, when| TurnRecord {
            thread_id: None,
            project_id: None,
            provider: provider.into(),
            account_id: "default".into(),
            model: None,
            started_at: None,
            finished_at: when,
            turn_totals: Some(TokenTotals::new(count, 0, 0, 0, 0, 0)),
        };
        let data = Data {
            records: vec![
                record("claude", 10, now - Duration::minutes(2)),
                record("codex", 20, now - Duration::minutes(1)),
                record("grok", 10_000, now),
            ],
            skipped: 0,
            accounts: vec![],
            registered: vec![],
            registered_unavailable: false,
            read_at: now,
            logs: None,
            report_cache: Default::default(),
        };
        let view = snapshot(&cards, Some(&data), &json!({}), None, now);
        assert_eq!(view["periods"][0]["tokens"], "30");
        assert_eq!(view["readings"][0]["provider"], "codex");
        assert_eq!(
            view["accounts"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v["provider"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["claude", "codex"]
        );
    }
}
