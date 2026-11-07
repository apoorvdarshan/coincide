//! How usage figures read in Settings › Usage, ported from Swift's `UsageFormat`
//! and `UsageRow`. Numbers group thousands with commas and use a dot for
//! decimals; times read in the caller's time zone. Nothing here estimates a
//! value: a figure without a total gets no bar.
use crate::usage_limits::{
    Credits, DisplayMode, Figure, Limits, Pace, Unit, WARNING_PERCENT, Window, duration,
};
use crate::usage_report::Totals;
use chrono::{DateTime, TimeZone, Utc};
use std::fmt::Display;

fn group(digits: &str) -> String {
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, c) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// "1,234,567".
pub fn integer(value: u64) -> String {
    group(&value.to_string())
}

/// "1,250.5": up to `fraction` decimals, trailing zeros dropped.
pub fn decimal(value: f64, fraction: usize) -> String {
    fixed(value, fraction, false)
}

/// Grouped, with `fraction` decimals; trailing zeros are dropped unless `keep_zeros`.
fn fixed(value: f64, fraction: usize, keep_zeros: bool) -> String {
    if !value.is_finite() {
        return "—".into();
    }
    let text = format!("{:.*}", fraction, value.abs());
    let (whole, part) = text.split_once('.').unwrap_or((&text, ""));
    let part = if keep_zeros {
        part
    } else {
        part.trim_end_matches('0')
    };
    let sign = if value < 0. && text.chars().any(|c| c.is_ascii_digit() && c != '0') {
        "-"
    } else {
        ""
    };
    if part.is_empty() {
        format!("{sign}{}", group(whole))
    } else {
        format!("{sign}{}.{part}", group(whole))
    }
}

/// "1.2M", "845K", "312": at most three significant digits.
pub fn tokens(count: u64) -> String {
    if count < 1000 {
        return count.to_string();
    }
    const UNITS: [(&str, f64); 4] = [("K", 1e3), ("M", 1e6), ("B", 1e9), ("T", 1e12)];
    let mut index = UNITS
        .iter()
        .rposition(|(_, size)| count as f64 >= *size)
        .unwrap_or(0);
    loop {
        let value = count as f64 / UNITS[index].1;
        let decimals = if value >= 100. {
            0
        } else if value >= 10. {
            1
        } else {
            2
        };
        let rounded = format!("{value:.decimals$}");
        // 999,950 rounds to "1000K"; read it as "1M".
        if rounded.parse::<f64>().unwrap_or(0.) >= 1000. && index + 1 < UNITS.len() {
            index += 1;
            continue;
        }
        let trimmed = if rounded.contains('.') {
            rounded.trim_end_matches('0').trim_end_matches('.')
        } else {
            &rounded
        };
        return format!("{trimmed}{}", UNITS[index].0);
    }
}

/// "1,234,567 tokens", for tooltips.
pub fn exact_tokens(count: u64) -> String {
    format!("{} tokens", integer(count))
}

/// Money: "$12.34", "€3.20", or "CHF 5.00" for a currency without a short symbol.
pub fn currency(value: f64, code: &str, fraction: usize) -> String {
    let amount = fixed(value.abs(), fraction, true);
    let sign = if value < 0. { "-" } else { "" };
    match code {
        "USD" => format!("{sign}${amount}"),
        "EUR" => format!("{sign}€{amount}"),
        "GBP" => format!("{sign}£{amount}"),
        "JPY" => format!("{sign}¥{amount}"),
        _ => format!("{sign}{code} {amount}"),
    }
}

/// "$12.34", "<$0.01" for a cost that rounds to nothing.
pub fn cost(dollars: f64) -> String {
    if dollars > 0. && dollars < 0.01 {
        return format!("<{}", currency(0.01, "USD", 2));
    }
    currency(dollars, "USD", if dollars >= 1000. { 0 } else { 2 })
}

/// The cost of `totals`, or "—" when none of its tokens has a known price.
pub fn cost_of(totals: &Totals) -> String {
    if totals.has_priced_tokens() {
        cost(totals.cost)
    } else {
        "—".into()
    }
}

/// The cost to the cent's hundredth, for tooltips, or why there is none.
pub fn exact_cost(totals: &Totals) -> String {
    if !totals.has_priced_tokens() {
        return "No list price for these models".into();
    }
    let cost = currency(totals.cost, "USD", 4);
    if totals.is_fully_priced() {
        format!("≈ {cost} at API list prices")
    } else {
        format!(
            "≈ {cost} at API list prices, without {} unpriced tokens",
            tokens(totals.unpriced_tokens)
        )
    }
}

/// "12%", or "4.5%" for a share under a tenth.
pub fn percent(share: f64) -> String {
    let value = share * 100.;
    if share > 0. && share < 0.1 {
        format!("{value:.1}%")
    } else {
        format!("{value:.0}%")
    }
}

/// A plan's name made readable: "pro" → "Pro", "edu_plus" → "Edu Plus".
pub fn plan(plan: &str) -> String {
    plan.split('_')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect::<String>())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// "1:02:03": hours, minutes and seconds of active time.
pub fn hours_minutes_seconds(seconds: f64) -> String {
    let seconds = seconds.max(0.).round() as u64;
    format!(
        "{}:{:02}:{:02}",
        seconds / 3600,
        seconds / 60 % 60,
        seconds % 60
    )
}

/// "9:00 AM" today, "Mon 9:00 AM" within the week, "Nov 3, 9:00 AM" after.
pub fn reset_time<Tz: TimeZone>(date: DateTime<Utc>, now: DateTime<Utc>, zone: &Tz) -> String
where
    Tz::Offset: Display,
{
    let local = date.with_timezone(zone);
    if local.date_naive() == now.with_timezone(zone).date_naive() {
        local.format("%-I:%M %p").to_string()
    } else if (date - now).num_seconds() < 6 * 86_400 {
        local.format("%a %-I:%M %p").to_string()
    } else {
        local.format("%b %-d, %-I:%M %p").to_string()
    }
}

/// "Nov 3", the chart's axis label.
pub fn day_label(day: chrono::NaiveDate) -> String {
    day.format("%b %-d").to_string()
}

/// "Mon, Nov 3", the chart's tooltip title.
pub fn weekday_label(day: chrono::NaiveDate) -> String {
    day.format("%a, %b %-d").to_string()
}

/// "just now", "2 min ago", "3 hr ago", "2 days ago".
pub fn relative(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = (now - date).num_seconds().max(0);
    match seconds {
        0..60 => "just now".into(),
        60..3600 => format!("{} min ago", seconds / 60),
        3600..86_400 => format!("{} hr ago", seconds / 3600),
        _ if seconds < 2 * 86_400 => "yesterday".into(),
        _ => format!("{} days ago", seconds / 86_400),
    }
}

/// How close a row is to its limit, which colors its bar and value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Normal,
    /// At or past the warning level.
    Near,
    /// At 95% used, or the limit reached or passed.
    Critical,
}
impl Level {
    pub fn used_share(share: f64) -> Self {
        if share >= 0.95 {
            Self::Critical
        } else if share * 100. >= WARNING_PERCENT {
            Self::Near
        } else {
            Self::Normal
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Bar {
    /// How much of the track is filled, 0–1: what is used, or what is left.
    pub fill: f64,
    /// Where even spending across the period would put the fill.
    pub pace_mark: Option<f64>,
}

/// One usage row: the title with the value on the right, a bar when there is a
/// real total to measure against, and its timing underneath.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub title: String,
    pub value: String,
    /// The value is a state, such as "Off", rather than an amount.
    pub is_state: bool,
    pub bar: Option<Bar>,
    pub level: Level,
    pub details: Vec<String>,
}
impl Row {
    fn new(title: &str, value: String) -> Self {
        Self {
            title: title.into(),
            value,
            is_state: false,
            bar: None,
            level: Level::Normal,
            details: Vec::new(),
        }
    }
}

/// "62% used", or "38% left" when showing what is left.
pub fn shown(window: &Window, mode: DisplayMode) -> String {
    match mode {
        DisplayMode::Used => format!("{}% used", window.shown_percent(mode)),
        DisplayMode::Remaining => format!("{}% left", window.shown_percent(mode)),
    }
}

fn pace(window: &Window, now: DateTime<Utc>) -> Option<&'static str> {
    Some(match window.pace(now)? {
        Pace::Ahead => "Ahead of pace",
        Pace::OnPace => "On pace",
        Pace::Under => "Under pace",
    })
}

/// A limit window: its share, bar with the pace mark, reset and pace.
pub fn window_row<Tz: TimeZone>(
    window: &Window,
    mode: DisplayMode,
    now: DateTime<Utc>,
    zone: &Tz,
) -> Row
where
    Tz::Offset: Display,
{
    let mut row = Row::new(&window.label, shown(window, mode));
    row.bar = Some(Bar {
        fill: window.bar_fill(mode),
        pace_mark: window.pace_mark(now, mode),
    });
    row.level = if window.is_exhausted() {
        Level::Critical
    } else {
        Level::used_share(window.used_percent / 100.)
    };
    if let (Some(reset), Some(countdown)) = (window.resets_at, window.reset_description(now)) {
        row.details
            .push(format!("{countdown} · {}", reset_time(reset, now, zone)));
    }
    row.details.extend(pace(window, now).map(str::to_owned));
    row
}

/// An amount in its unit: "$12.40", "1,250 credits", "48 requests", "12K tokens".
pub fn amount(value: f64, unit: &Unit) -> String {
    match unit {
        Unit::Currency(code) => currency(
            value,
            code,
            if value != 0. && value.abs() < 0.01 {
                4
            } else {
                2
            },
        ),
        Unit::Credits => format!("{} credits", decimal(value, 2)),
        Unit::Requests => format!("{} requests", decimal(value, 0)),
        Unit::Tokens => format!("{} tokens", tokens(value.round().max(0.) as u64)),
        Unit::Count => decimal(value, 0),
    }
}

/// An amount without its unit's word, to go before "of 50 requests".
pub fn bare_amount(value: f64, unit: &Unit) -> String {
    match unit {
        Unit::Currency(_) => amount(value, unit),
        Unit::Tokens => tokens(value.round().max(0.) as u64),
        Unit::Credits => decimal(value, 2),
        Unit::Requests | Unit::Count => decimal(value, 0),
    }
}

/// What a figure says: "$271.40 of $500.00 used", "$3.20", or its state ("Off").
pub fn figure_value(figure: &Figure) -> String {
    if let Some(limit) = figure.limit {
        if let Some(used) = figure.used {
            return format!(
                "{} of {} used",
                bare_amount(used, &figure.unit),
                amount(limit, &figure.unit)
            );
        }
        if let Some(left) = figure.left() {
            return format!(
                "{} of {} left",
                bare_amount(left, &figure.unit),
                amount(limit, &figure.unit)
            );
        }
        return format!("Limit {}", amount(limit, &figure.unit));
    }
    if let Some(used) = figure.used {
        return amount(used, &figure.unit);
    }
    if let Some(remaining) = figure.remaining {
        return if figure.unit == Unit::Count {
            amount(remaining, &figure.unit)
        } else {
            format!("{} left", amount(remaining, &figure.unit))
        };
    }
    figure.detail.clone().unwrap_or_else(|| "—".into())
}

/// A figure: with a limit, what is used or left of it over a bar; without one,
/// the amount alone or its state.
pub fn figure_row<Tz: TimeZone>(
    figure: &Figure,
    mode: DisplayMode,
    now: DateTime<Utc>,
    zone: &Tz,
) -> Row
where
    Tz::Offset: Display,
{
    let mut row = Row::new(&figure.label, figure_value(figure));
    let used = figure
        .used
        .or_else(|| Some(figure.limit? - figure.remaining?));
    if let (Some(limit), Some(used)) = (figure.limit.filter(|limit| *limit > 0.), used) {
        let share = used.max(0.) / limit;
        let left = figure.left().unwrap_or((limit - used).max(0.));
        let unit = &figure.unit;
        row.value = match mode {
            DisplayMode::Used => format!(
                "{} of {} used",
                bare_amount(used, unit),
                amount(limit, unit)
            ),
            DisplayMode::Remaining => format!(
                "{} of {} left",
                bare_amount(left, unit),
                amount(limit, unit)
            ),
        };
        row.bar = Some(Bar {
            fill: match mode {
                DisplayMode::Used => share.min(1.),
                DisplayMode::Remaining => (1. - share).max(0.),
            },
            pace_mark: None,
        });
        row.level = Level::used_share(share);
        if mode == DisplayMode::Remaining && used > limit {
            row.details
                .push(format!("{} over the limit", amount(used - limit, unit)));
        }
    } else {
        row.is_state =
            figure.limit.is_none() && figure.used.is_none() && figure.remaining.is_none();
    }
    if figure.limit.is_some() || figure.used.is_some() || figure.remaining.is_some() {
        row.details.extend(figure.detail.clone());
    }
    if let Some(reset) = figure.resets_at.filter(|reset| *reset > now) {
        row.details.push(format!(
            "resets in {} · {}",
            duration((reset - now).num_seconds() as f64),
            reset_time(reset, now, zone)
        ));
    } else if let Some(expires) = figure.expires_at {
        row.details
            .push(format!("expires {}", reset_time(expires, now, zone)));
    }
    row
}

fn balance(credits: &Credits) -> Option<String> {
    let balance = credits.balance.as_deref()?.trim();
    Some(
        balance
            .parse::<f64>()
            .ok()
            .filter(|value| value.is_finite())
            .map_or_else(|| balance.to_owned(), |value| decimal(value, 2)),
    )
}

/// Credits the account can spend past its plan. Unlimited credits have no bar.
pub fn credits_row(credits: &Credits, mode: DisplayMode) -> Row {
    if credits.unlimited {
        return Row::new("Credits", "Unlimited".into());
    }
    match balance(credits) {
        Some(balance) => Row::new(
            "Credits",
            match mode {
                DisplayMode::Used => balance,
                DisplayMode::Remaining => format!("{balance} left"),
            },
        ),
        None => {
            let mut row = Row::new(
                "Credits",
                if credits.has_credits {
                    "Credits available"
                } else {
                    "No credits"
                }
                .into(),
            );
            row.is_state = true;
            row
        }
    }
}

/// Every row of an account, in order: windows, model windows, credits, then figures.
pub fn rows<Tz: TimeZone>(
    limits: &Limits,
    mode: DisplayMode,
    now: DateTime<Utc>,
    zone: &Tz,
) -> Vec<Row>
where
    Tz::Offset: Display,
{
    limits
        .windows
        .iter()
        .chain(&limits.model_windows)
        .map(|window| window_row(window, mode, now, zone))
        .chain(
            limits
                .credits
                .iter()
                .map(|credits| credits_row(credits, mode)),
        )
        .chain(
            limits
                .figures
                .iter()
                .map(|figure| figure_row(figure, mode, now, zone)),
        )
        .collect()
}

/// Turns Coincide ran with an account over a period: "1.2M tokens · ≈ $3.40".
pub fn tracked_row(title: &str, totals: &Totals) -> Row {
    let tokens_used = &totals.tokens;
    let mut value = amount(tokens_used.total() as f64, &Unit::Tokens);
    if totals.has_priced_tokens() {
        value.push_str(&format!(" · ≈ {}", cost(totals.cost)));
    }
    let mut row = Row::new(title, value);
    row.details.push(format!(
        "Input {} · output {} · cache {}",
        tokens(tokens_used.input),
        tokens(tokens_used.output),
        tokens(
            tokens_used
                .cache_read
                .saturating_add(tokens_used.cache_write)
        )
    ));
    row
}

/// The account's name for headers: "Claude Code", or "Claude Code · Work" when
/// the provider has several accounts.
pub fn account_title(
    provider: &str,
    account: &str,
    is_default: bool,
    shows_account_name: bool,
) -> String {
    if shows_account_name && !is_default {
        format!("{provider} · {account}")
    } else {
        provider.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage_limits::WindowKind;
    use crate::usage_report::TokenTotals;

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn numbers_read_like_the_swift_page() {
        assert_eq!(integer(1_234_567), "1,234,567");
        assert_eq!(integer(12), "12");
        assert_eq!(tokens(312), "312");
        assert_eq!(tokens(845_000), "845K");
        assert_eq!(tokens(1_234), "1.23K");
        assert_eq!(tokens(12_345), "12.3K");
        assert_eq!(tokens(1_200_000), "1.2M");
        assert_eq!(tokens(999_950), "1M");
        assert_eq!(tokens(1_000), "1K");
        assert_eq!(exact_tokens(1_234_567), "1,234,567 tokens");
        assert_eq!(cost(12.344), "$12.34");
        assert_eq!(cost(0.004), "<$0.01");
        assert_eq!(cost(0.), "$0.00");
        assert_eq!(cost(1234.6), "$1,235");
        assert_eq!(percent(0.12), "12%");
        assert_eq!(percent(0.045), "4.5%");
        assert_eq!(percent(0.), "0%");
        assert_eq!(plan("edu_plus"), "Edu Plus");
        assert_eq!(hours_minutes_seconds(3723.4), "1:02:03");
        assert_eq!(decimal(1250.5, 2), "1,250.5");
        assert_eq!(decimal(-0.001, 2), "0");
        assert_eq!(currency(5., "CHF", 2), "CHF 5.00");
    }

    #[test]
    fn costs_say_when_tokens_have_no_list_price() {
        let mut totals = Totals::default();
        assert_eq!(cost_of(&totals), "—");
        assert_eq!(exact_cost(&totals), "No list price for these models");
        totals.tokens = TokenTotals::new(2_000_000, 0, 0, 0, 0, 0);
        totals.cost = 1.5;
        totals.unpriced_tokens = 1_000_000;
        assert_eq!(cost_of(&totals), "$1.50");
        assert_eq!(
            exact_cost(&totals),
            "≈ $1.5000 at API list prices, without 1M unpriced tokens"
        );
    }

    #[test]
    fn window_rows_show_used_or_left_with_reset_and_pace() {
        let now = at("2026-11-07T12:00:00Z");
        let window = Window::new("primary", WindowKind::Session, "Session", 91.)
            .resetting(Some(at("2026-11-07T13:00:00Z")), Some(300));
        let row = window_row(&window, DisplayMode::Used, now, &Utc);
        assert_eq!(row.value, "91% used");
        assert_eq!(row.level, Level::Near);
        assert_eq!(row.details, ["resets in 1h 0m · 1:00 PM", "Ahead of pace"]);
        let left = window_row(&window, DisplayMode::Remaining, now, &Utc);
        assert_eq!(left.value, "9% left");
        assert!((left.bar.unwrap().fill - 0.09).abs() < 1e-9);
        let later = Window::new("w", WindowKind::Weekly, "Weekly", 10.)
            .resetting(Some(at("2026-11-20T09:05:00Z")), None);
        assert_eq!(
            window_row(&later, DisplayMode::Used, now, &Utc).details,
            ["resets in 12d 21h · Nov 20, 9:05 AM"]
        );
    }

    #[test]
    fn figures_and_credits_follow_their_reported_amounts() {
        let now = at("2026-11-07T12:00:00Z");
        let mut spend = Figure::new("extra_usage", "Extra usage", Unit::Currency("USD".into()));
        spend.used = Some(271.4);
        spend.limit = Some(500.);
        let row = figure_row(&spend, DisplayMode::Used, now, &Utc);
        assert_eq!(row.value, "$271.40 of $500.00 used");
        assert!((row.bar.unwrap().fill - 0.5428).abs() < 1e-9);
        spend.used = Some(600.);
        let over = figure_row(&spend, DisplayMode::Remaining, now, &Utc);
        assert_eq!(over.value, "$0.00 of $500.00 left");
        assert_eq!(over.details, ["$100.00 over the limit"]);
        assert_eq!(over.level, Level::Critical);
        let mut off = Figure::new("extra_usage", "Extra usage", Unit::Currency("USD".into()));
        off.detail = Some("Off".into());
        let state = figure_row(&off, DisplayMode::Used, now, &Utc);
        assert!(state.is_state && state.details.is_empty());
        assert_eq!(state.value, "Off");
        let mut resets = Figure::new("reset_credits", "Limit resets available", Unit::Count);
        resets.remaining = Some(2.);
        resets.expires_at = Some(at("2026-11-07T18:30:00Z"));
        let row = figure_row(&resets, DisplayMode::Used, now, &Utc);
        assert_eq!(
            (row.value.as_str(), row.details[0].as_str()),
            ("2", "expires 6:30 PM")
        );
        let credits = Credits {
            has_credits: true,
            unlimited: false,
            balance: Some("1250.5".into()),
        };
        assert_eq!(
            credits_row(&credits, DisplayMode::Remaining).value,
            "1,250.5 left"
        );
        let none = Credits {
            has_credits: false,
            unlimited: false,
            balance: None,
        };
        assert!(credits_row(&none, DisplayMode::Used).is_state);
        assert_eq!(
            credits_row(
                &Credits {
                    has_credits: true,
                    unlimited: true,
                    balance: None
                },
                DisplayMode::Used
            )
            .value,
            "Unlimited"
        );
    }

    #[test]
    fn titles_and_relative_times() {
        assert_eq!(account_title("Codex", "Work", false, true), "Codex · Work");
        assert_eq!(account_title("Codex", "Default", true, true), "Codex");
        assert_eq!(account_title("Codex", "Work", false, false), "Codex");
        let now = at("2026-11-07T12:00:00Z");
        assert_eq!(relative(at("2026-11-07T11:59:30Z"), now), "just now");
        assert_eq!(relative(at("2026-11-07T11:58:00Z"), now), "2 min ago");
        assert_eq!(relative(at("2026-11-04T12:00:00Z"), now), "3 days ago");
        assert_eq!(day_label(now.date_naive()), "Nov 7");
        assert_eq!(weekday_label(now.date_naive()), "Sat, Nov 7");
    }
}
