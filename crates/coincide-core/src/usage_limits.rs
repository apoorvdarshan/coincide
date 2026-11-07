//! Plan limits as Settings › Usage lists them for every provider account, ported
//! from Swift's `UsageLimits`, `UsageLimitWindow`, `UsageCredits` and
//! `UsageFigure`. Values are only what a provider reported; nothing is
//! estimated, and a missing window is not a zero allowance.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WindowKind {
    Session,
    Weekly,
    Monthly,
    Other,
}
impl WindowKind {
    fn rank(self) -> u8 {
        match self {
            Self::Session => 0,
            Self::Weekly => 1,
            Self::Monthly => 2,
            Self::Other => 3,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Session => "Session",
            Self::Weekly => "Weekly",
            Self::Monthly => "Monthly",
            Self::Other => "Other",
        }
    }
}

/// Whether usage reads as what is used (bars fill up) or what is left (bars drain).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DisplayMode {
    #[default]
    Used,
    Remaining,
}
impl DisplayMode {
    /// Swift's `usageDisplayMode` setting; anything else reads as used.
    pub fn saved(value: &Value) -> Self {
        if value == "remaining" {
            Self::Remaining
        } else {
            Self::Used
        }
    }
}

/// Spending compared with the time that has passed in the window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pace {
    Ahead,
    OnPace,
    Under,
}

/// Used from this percentage on, the limit counts as near.
pub const WARNING_PERCENT: f64 = 90.;

/// One window of a plan's limits, such as a five-hour session or a weekly allowance.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    /// Stable for the provider, so a later report of the same window replaces it.
    pub id: String,
    pub kind: WindowKind,
    pub label: String,
    /// How much of the window is used, 0–100.
    pub used_percent: f64,
    pub resets_at: Option<DateTime<Utc>>,
    pub duration_minutes: Option<u64>,
    /// Once used up, the agent keeps working on the account's paid credits.
    pub continues_on_credits: bool,
}
impl Window {
    pub fn new(id: &str, kind: WindowKind, label: &str, used_percent: f64) -> Self {
        Self {
            id: id.into(),
            kind,
            label: label.into(),
            used_percent: if used_percent.is_finite() {
                used_percent.clamp(0., 100.)
            } else {
                0.
            },
            resets_at: None,
            duration_minutes: None,
            continues_on_credits: false,
        }
    }
    pub fn resetting(mut self, resets_at: Option<DateTime<Utc>>, minutes: Option<u64>) -> Self {
        self.resets_at = resets_at;
        self.duration_minutes = minutes.filter(|minutes| *minutes > 0);
        self
    }
    pub fn is_exhausted(&self) -> bool {
        self.used_percent >= 100.
    }
    /// Used up with nothing to fall back on, so work stops until the window resets.
    pub fn blocks_work(&self) -> bool {
        self.is_exhausted() && !self.continues_on_credits
    }
    pub fn is_near_limit(&self) -> bool {
        self.used_percent >= WARNING_PERCENT
    }
    /// The whole percent shown in `mode`; used and left always add up to 100.
    pub fn shown_percent(&self, mode: DisplayMode) -> i64 {
        let used = self.used_percent.round() as i64;
        match mode {
            DisplayMode::Used => used,
            DisplayMode::Remaining => 100 - used,
        }
    }
    /// How much of a bar is filled in `mode`, 0–1.
    pub fn bar_fill(&self, mode: DisplayMode) -> f64 {
        match mode {
            DisplayMode::Used => self.used_percent / 100.,
            DisplayMode::Remaining => 1. - self.used_percent / 100.,
        }
    }
    /// How much of the window has passed, 0–1, when its length and reset are known.
    pub fn elapsed_share(&self, now: DateTime<Utc>) -> Option<f64> {
        let minutes = self.duration_minutes.filter(|minutes| *minutes > 0)?;
        let length = minutes as f64 * 60.;
        let left = (self.resets_at? - now).num_milliseconds() as f64 / 1000.;
        Some(((length - left) / length).clamp(0., 1.))
    }
    /// More than five points either side of even spending is ahead of or under pace.
    pub fn pace(&self, now: DateTime<Utc>) -> Option<Pace> {
        let gap = self.used_percent - self.elapsed_share(now)? * 100.;
        Some(if gap > 5. {
            Pace::Ahead
        } else if gap < -5. {
            Pace::Under
        } else {
            Pace::OnPace
        })
    }
    /// Where even spending would put the fill in `mode`, 0–1.
    pub fn pace_mark(&self, now: DateTime<Utc>, mode: DisplayMode) -> Option<f64> {
        self.elapsed_share(now).map(|share| match mode {
            DisplayMode::Used => share,
            DisplayMode::Remaining => 1. - share,
        })
    }
    /// "resets in 2h 5m", or None without a reset time.
    pub fn reset_description(&self, now: DateTime<Utc>) -> Option<String> {
        let seconds = (self.resets_at? - now).num_seconds();
        Some(if seconds <= 0 {
            "resets now".into()
        } else if seconds < 60 {
            "resets momentarily".into()
        } else {
            format!("resets in {}", duration(seconds as f64))
        })
    }
}

/// "2d 3h", "4h 10m" or "12m", rounded down.
pub fn duration(seconds: f64) -> String {
    let minutes = (seconds.max(0.) / 60.) as u64;
    let (days, hours) = (minutes / 1440, minutes % 1440 / 60);
    if days > 0 {
        format!("{days}d {hours}h")
    } else if hours > 0 {
        format!("{hours}h {}m", minutes % 60)
    } else {
        format!("{minutes}m")
    }
}

/// Credits the account can spend past its plan's windows.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credits {
    pub has_credits: bool,
    pub unlimited: bool,
    /// As the provider writes it (Codex sends a decimal string).
    pub balance: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "code", rename_all = "snake_case")]
pub enum Unit {
    /// Money in an ISO 4217 currency, in major units.
    Currency(String),
    Credits,
    Requests,
    Tokens,
    Count,
}

/// An amount a provider reports beside its percentage windows. A figure with no
/// amounts says what state the feature is in (`detail`, "Off").
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Figure {
    pub id: String,
    pub label: String,
    pub unit: Unit,
    pub used: Option<f64>,
    pub limit: Option<f64>,
    pub remaining: Option<f64>,
    pub resets_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
    pub detail: Option<String>,
}
impl Figure {
    pub fn new(id: &str, label: &str, unit: Unit) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            unit,
            used: None,
            limit: None,
            remaining: None,
            resets_at: None,
            expires_at: None,
            detail: None,
        }
    }
    /// What is left: as reported, else the limit less what is used.
    pub fn left(&self) -> Option<f64> {
        self.remaining
            .or_else(|| Some((self.limit? - self.used?).max(0.)))
    }
    /// Past its reset time a figure starts over, with nothing used.
    pub fn current(&self, now: DateTime<Utc>) -> Self {
        let mut figure = self.clone();
        if self.resets_at.is_some_and(|reset| reset <= now)
            && (self.limit.is_some() || self.used.is_some())
        {
            figure.used = self.used.map(|_| 0.);
            figure.remaining = self.remaining.and(self.limit);
            figure.resets_at = None;
        }
        figure
    }
}
fn finite(value: Option<f64>) -> Option<f64> {
    value.filter(|value| value.is_finite())
}

/// A provider account's limits as last reported, with when they were read.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    /// Session windows first, then weekly, monthly and others.
    pub windows: Vec<Window>,
    pub checked_at: DateTime<Utc>,
    /// The plan as the provider names it (`pro`, `plus`, …), when reported.
    pub plan: Option<String>,
    pub credits: Option<Credits>,
    /// Limits of single models that run apart from the main allowance.
    pub model_windows: Vec<Window>,
    pub figures: Vec<Figure>,
    /// What the provider does not show this account.
    pub notes: Vec<String>,
}
impl Limits {
    pub fn new(windows: Vec<Window>, checked_at: DateTime<Utc>) -> Self {
        let mut limits = Self {
            windows,
            checked_at,
            plan: None,
            credits: None,
            model_windows: Vec::new(),
            figures: Vec::new(),
            notes: Vec::new(),
        };
        limits.sort();
        limits
    }
    pub fn sort(&mut self) {
        for windows in [&mut self.windows, &mut self.model_windows] {
            windows.sort_by(|a, b| (a.kind.rank(), &a.id).cmp(&(b.kind.rank(), &b.id)));
        }
    }
    /// Whether there is anything to show: a window, credits, a figure or a note.
    pub fn is_empty(&self) -> bool {
        self.windows.is_empty()
            && self.model_windows.is_empty()
            && self.credits.is_none()
            && self.figures.is_empty()
            && self.notes.is_empty()
    }
    /// Whether there is a window, credits or a figure, as opposed to notes alone.
    pub fn has_rows(&self) -> bool {
        !self.windows.is_empty()
            || !self.model_windows.is_empty()
            || self.credits.is_some()
            || !self.figures.is_empty()
    }
    /// As they stand at `now`: a window whose reset passed starts over, until the agent reports it again.
    pub fn current(&self, now: DateTime<Utc>) -> Self {
        let current = |window: &Window| {
            let mut window = window.clone();
            if window.resets_at.is_some_and(|reset| reset <= now) {
                window.used_percent = 0.;
                window.resets_at = None;
            }
            window
        };
        Self {
            windows: self.windows.iter().map(current).collect(),
            model_windows: self.model_windows.iter().map(current).collect(),
            figures: self
                .figures
                .iter()
                .map(|figure| figure.current(now))
                .collect(),
            ..self.clone()
        }
    }
    /// The window to warn about: an exhausted one that resets last (preferring one
    /// that stops work), otherwise the fullest at or past the warning level.
    pub fn warning(&self) -> Option<&Window> {
        let blocking = self
            .windows
            .iter()
            .filter(|w| w.blocks_work())
            .collect::<Vec<_>>();
        let exhausted = if blocking.is_empty() {
            self.windows.iter().filter(|w| w.is_exhausted()).collect()
        } else {
            blocking
        };
        if !exhausted.is_empty() {
            // No reset time counts as resetting last; ties keep the first, as Swift's `max`.
            let key = |w: &Window| {
                w.resets_at
                    .map_or(i64::MAX, |reset| reset.timestamp_millis())
            };
            let mut best = exhausted[0];
            for window in exhausted {
                if key(window) > key(best) {
                    best = window;
                }
            }
            return Some(best);
        }
        let mut best: Option<&Window> = None;
        for window in self.windows.iter().filter(|w| w.is_near_limit()) {
            if best.is_none_or(|current| window.used_percent > current.used_percent) {
                best = Some(window);
            }
        }
        best
    }
}

/// What a composer or Usage line says about a window near or at its limit.
pub fn warning_text(
    window: &Window,
    provider: &str,
    mode: DisplayMode,
    now: DateTime<Utc>,
) -> String {
    let limit = window.label.to_lowercase();
    let resets = window
        .resets_at
        .filter(|reset| *reset > now)
        .map(|reset| duration((reset - now).num_seconds() as f64));
    if window.is_exhausted() && window.continues_on_credits {
        return match resets {
            Some(left) => format!(
                "{provider} {limit} limit reached. Using credits until it resets in {left}."
            ),
            None => format!("{provider} {limit} limit reached. Using credits."),
        };
    }
    if window.is_exhausted() {
        return match resets {
            Some(left) => {
                format!("{provider} usage limit reached. The {limit} limit resets in {left}.")
            }
            None => format!("{provider} usage limit reached."),
        };
    }
    let used = window.used_percent.floor() as i64;
    let (amount, verb) = match mode {
        DisplayMode::Used => (used, "used"),
        DisplayMode::Remaining => (100 - used, "left"),
    };
    match resets {
        Some(left) => {
            format!("{amount}% of your {provider} {limit} limit is {verb}. It resets in {left}.")
        }
        None => format!("{amount}% of your {provider} {limit} limit is {verb}."),
    }
}

/// The most used window across accounts, model-specific windows included; ties
/// go to the window that resets last. Returns the account's index.
pub fn most_constrained<'a>(
    accounts: impl IntoIterator<Item = Option<&'a Limits>>,
) -> Option<(usize, &'a Window)> {
    let mut best: Option<(usize, &Window)> = None;
    for (index, limits) in accounts.into_iter().enumerate() {
        let Some(limits) = limits else { continue };
        for window in limits.windows.iter().chain(&limits.model_windows) {
            let replace = best.is_none_or(|(_, current)| {
                window.used_percent > current.used_percent
                    || (window.used_percent == current.used_percent
                        && window.resets_at.unwrap_or(DateTime::<Utc>::MIN_UTC)
                            > current.resets_at.unwrap_or(DateTime::<Utc>::MIN_UTC))
            });
            if replace {
                best = Some((index, window));
            }
        }
    }
    best
}

/// Claude Code's `get_usage` control response, ported from Swift's `ClaudeUsageLimits`.
pub mod claude {
    use super::*;

    const SESSION_MINUTES: u64 = 5 * 60;
    const WEEK_MINUTES: u64 = 7 * 24 * 60;

    fn number(value: Option<&Value>) -> Option<f64> {
        finite(value?.as_f64())
    }
    fn text(value: Option<&Value>) -> Option<&str> {
        value?
            .as_str()
            .map(str::trim)
            .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
    }
    /// `2026-10-27T14:10:00.340563+00:00`, with or without a fraction.
    pub fn date(value: Option<&Value>) -> Option<DateTime<Utc>> {
        let text = value?.as_str()?;
        DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|date| date.with_timezone(&Utc))
    }
    fn window(bucket: &str, used: f64, resets_at: Option<DateTime<Utc>>) -> Option<Window> {
        let (kind, label, minutes) = match bucket {
            "five_hour" => (WindowKind::Session, "Session", SESSION_MINUTES),
            "seven_day" => (WindowKind::Weekly, "Weekly", WEEK_MINUTES),
            _ => return None,
        };
        Some(Window::new(bucket, kind, label, used).resetting(resets_at, Some(minutes)))
    }
    /// A weekly limit of one model, such as "Weekly · Opus".
    fn scoped_window(name: &str, used: f64, resets_at: Option<DateTime<Utc>>) -> Window {
        let mut slug = String::new();
        for c in name.to_lowercase().chars() {
            if c.is_ascii_lowercase() || c.is_ascii_digit() {
                slug.push(c);
            } else if !slug.ends_with('_') {
                slug.push('_');
            }
        }
        Window::new(
            &format!("seven_day_{slug}"),
            WindowKind::Weekly,
            &format!("Weekly · {name}"),
            used,
        )
        .resetting(resets_at, Some(WEEK_MINUTES))
    }
    fn limits(response: &Value) -> Option<&Value> {
        (response["rate_limits_available"] == true)
            .then(|| &response["rate_limits"])
            .filter(|limits| limits.is_object())
    }
    fn model_scoped(limits: &Value) -> Vec<(&str, f64, Option<DateTime<Utc>>)> {
        limits["model_scoped"]
            .as_array()
            .map(|rows| {
                rows.iter()
                    .filter_map(|row| {
                        Some((
                            text(row.get("display_name"))?,
                            number(row.get("utilization"))?,
                            date(row.get("resets_at")),
                        ))
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
    /// Explicitly enabled extra usage with budget left (or no cap). A balance alone
    /// never enables overage, and an exhausted cap cannot be bypassed.
    fn extra_usage_available(limits: &Value) -> bool {
        let extra = &limits["extra_usage"];
        if let Some(enabled) = extra["is_enabled"].as_bool() {
            if !enabled || extra["user_disabled"] == true {
                return false;
            }
            let cap = &extra["monthly_limit"];
            if cap.is_null() {
                return true;
            }
            let Some(limit) = number(Some(cap)).filter(|limit| *limit > 0.) else {
                return false;
            };
            if let Some(used) = number(extra.get("used_credits")) {
                return used >= 0. && used < limit;
            }
            if let Some(percent) = number(extra.get("utilization")) {
                return (0. ..100.).contains(&percent);
            }
            return false;
        }
        let spend = &limits["spend"];
        if spend["enabled"] != true {
            return false;
        }
        let cap = &spend["limit"];
        if cap.is_null() {
            return true;
        }
        let used = &spend["used"];
        let (Some(used_amount), Some(limit_amount)) = (
            number(used.get("amount_minor")),
            number(cap.get("amount_minor")),
        ) else {
            return false;
        };
        used_amount >= 0.
            && limit_amount > used_amount
            && text(used.get("currency")).is_some()
            && used["currency"] == cap["currency"]
            && used["exponent"] == cap["exponent"]
    }
    fn percent(used: Option<f64>, limit: Option<f64>) -> Option<f64> {
        let (used, limit) = (used?, limit?);
        (used >= 0. && limit > 0.).then(|| (used / limit * 100.).min(100.))
    }
    /// How much of the monthly spend budget is used, when one is on.
    fn spend_percent(limits: &Value) -> Option<f64> {
        let spend = &limits["spend"];
        if spend["enabled"] == true {
            let (used, limit) = (&spend["used"], &spend["limit"]);
            if text(used.get("currency")).is_some()
                && used["currency"] == limit["currency"]
                && used["exponent"] == limit["exponent"]
                && let Some(value) = percent(
                    number(used.get("amount_minor")),
                    number(limit.get("amount_minor")),
                )
            {
                return Some(value);
            }
        }
        let extra = &limits["extra_usage"];
        if extra["is_enabled"] != true {
            return None;
        }
        let value = percent(
            number(extra.get("used_credits")),
            number(extra.get("monthly_limit")),
        )
        .or_else(|| number(extra.get("utilization")))?;
        (value >= 0.).then(|| value.min(100.))
    }
    /// How many minor units make one unit of `currency`: 100 for USD, 1 for JPY.
    pub fn minor_unit_scale(currency: &str) -> f64 {
        const NONE: [&str; 16] = [
            "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "VND",
            "VUV", "XAF", "XOF", "XPF",
        ];
        const THREE: [&str; 7] = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"];
        if NONE.contains(&currency) {
            1.
        } else if THREE.contains(&currency) {
            1000.
        } else {
            100.
        }
    }

    /// The windows of a `get_usage` answer, percentages 0–100. None when Claude
    /// Code has no plan limits to report (an API key, say).
    pub fn windows(response: &Value) -> Option<Vec<Window>> {
        let limits = limits(response)?;
        let extra = extra_usage_available(limits);
        let mut windows = Vec::new();
        for bucket in ["five_hour", "seven_day"] {
            let value = &limits[bucket];
            if let Some(used) = number(value.get("utilization"))
                && let Some(mut window) = window(bucket, used, date(value.get("resets_at")))
            {
                window.continues_on_credits = extra;
                windows.push(window);
            }
        }
        for (name, used, resets_at) in model_scoped(limits) {
            windows.push(scoped_window(name, used, resets_at));
        }
        if let Some(spend) = spend_percent(limits) {
            windows.push(Window::new(
                "monthly_spend",
                WindowKind::Monthly,
                "Monthly spend",
                spend,
            ));
        }
        Some(windows)
    }

    /// The amounts a `get_usage` answer reports besides its percentages.
    pub fn figures(response: &Value) -> Vec<Figure> {
        let Some(limits) = limits(response) else {
            return Vec::new();
        };
        let mut figures = Vec::new();
        let spend_rows = limits["limits"]
            .as_array()
            .map(|rows| {
                rows.iter()
                    .filter(|row| row["kind"] == "spend")
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let spend_reset = spend_rows
            .iter()
            .find(|row| row["is_active"] == true)
            .or(spend_rows.first())
            .and_then(|row| date(row.get("resets_at")));
        let extra = &limits["extra_usage"];
        if extra.is_object() {
            let currency = text(extra.get("currency")).map_or("USD".into(), str::to_uppercase);
            let scale = minor_unit_scale(&currency);
            let mut figure = Figure::new("extra_usage", "Extra usage", Unit::Currency(currency));
            if extra["is_enabled"] == true {
                figure.used = number(extra.get("used_credits")).map(|v| v / scale);
                figure.limit = number(extra.get("monthly_limit")).map(|v| v / scale);
                figure.resets_at = spend_reset;
                if figure.limit.is_none() {
                    figure.detail = Some("No cap".into());
                }
            } else {
                figure.detail = Some("Off".into());
            }
            figures.push(figure);
        }
        let spend = &limits["spend"];
        let used = &spend["used"];
        if spend["enabled"] == true
            && let Some(currency) = text(used.get("currency")).map(str::to_uppercase)
            && let Some(minor) = number(used.get("amount_minor"))
        {
            let exponent = number(used.get("exponent")).unwrap_or(2.);
            let cap = &spend["limit"];
            let mut figure = Figure::new("spend", "Spend", Unit::Currency(currency.clone()));
            figure.used = Some(minor / 10f64.powf(exponent));
            figure.limit = (text(cap.get("currency")).map(str::to_uppercase) == Some(currency))
                .then(|| number(cap.get("amount_minor")))
                .flatten()
                .map(|amount| amount / 10f64.powf(number(cap.get("exponent")).unwrap_or(exponent)));
            figure.resets_at = spend_reset;
            figures.push(figure);
        }
        // Dollar allowances in whole dollars; only named ones are shown.
        if let Some(buckets) = limits.as_object() {
            let mut buckets = buckets.iter().collect::<Vec<_>>();
            buckets.sort_by(|a, b| a.0.cmp(b.0));
            for (bucket, value) in buckets {
                let Some(limit) = value
                    .is_object()
                    .then(|| number(value.get("limit_dollars")))
                    .flatten()
                    .filter(|limit| *limit > 0.)
                else {
                    continue;
                };
                let named = text(value.get("label"));
                let Some(label) = named.or((bucket == "iguana_necktie").then_some("Cloud credits"))
                else {
                    continue;
                };
                let mut figure = Figure::new(bucket, label, Unit::Currency("USD".into()));
                figure.limit = Some(limit);
                figure.used = number(value.get("used_dollars"));
                figure.remaining = number(value.get("remaining_dollars"));
                if figure.used.is_none()
                    && figure.remaining.is_none()
                    && let Some(utilization) = number(value.get("utilization"))
                {
                    figure.used = Some(limit * utilization.clamp(0., 100.) / 100.);
                }
                // Promotional credits end at their `resets_at` rather than start over.
                let end = date(value.get("resets_at"));
                if bucket == "iguana_necktie" && named.is_none() {
                    figure.expires_at = end;
                } else {
                    figure.resets_at = end;
                }
                figures.push(figure);
            }
        }
        figures
    }

    /// The limits of a `get_usage` answer, or None when it reports none.
    pub fn limits_from_usage(response: &Value, checked_at: DateTime<Utc>) -> Option<Limits> {
        let mut limits = Limits::new(windows(response)?, checked_at);
        limits.figures = figures(response);
        Some(limits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn windows_clamp_sort_and_count_pace_like_swift() {
        let now = at("2026-11-07T12:00:00Z");
        let session = Window::new("primary", WindowKind::Session, "Session", 62.4)
            .resetting(Some(at("2026-11-07T14:30:00Z")), Some(300));
        assert_eq!(session.shown_percent(DisplayMode::Used), 62);
        assert_eq!(session.shown_percent(DisplayMode::Remaining), 38);
        // 150 of 300 minutes left: half elapsed, 12 points ahead.
        assert_eq!(session.elapsed_share(now), Some(0.5));
        assert_eq!(session.pace(now), Some(Pace::Ahead));
        assert_eq!(session.pace_mark(now, DisplayMode::Remaining), Some(0.5));
        assert_eq!(session.reset_description(now).unwrap(), "resets in 2h 30m");
        assert_eq!(
            Window::new("x", WindowKind::Other, "X", f64::NAN).used_percent,
            0.
        );
        assert_eq!(
            Window::new("x", WindowKind::Other, "X", 140.).used_percent,
            100.
        );
        let limits = Limits::new(
            vec![
                Window::new("b", WindowKind::Weekly, "Weekly", 1.),
                session.clone(),
                Window::new("a", WindowKind::Weekly, "Weekly", 1.),
            ],
            now,
        );
        assert_eq!(
            limits
                .windows
                .iter()
                .map(|w| w.id.as_str())
                .collect::<Vec<_>>(),
            ["primary", "a", "b"]
        );
        assert_eq!(duration(2. * 86_400. + 3. * 3600. + 59.), "2d 3h");
        assert_eq!(duration(59.), "0m");
    }

    #[test]
    fn current_resets_passed_windows_and_figures() {
        let now = at("2026-11-07T12:00:00Z");
        let mut limits = Limits::new(
            vec![
                Window::new("w", WindowKind::Weekly, "Weekly", 80.)
                    .resetting(Some(at("2026-11-07T11:00:00Z")), None),
            ],
            now,
        );
        let mut figure = Figure::new("f", "Spend", Unit::Currency("USD".into()));
        figure.used = Some(4.);
        figure.limit = Some(10.);
        figure.remaining = Some(6.);
        figure.resets_at = Some(at("2026-11-07T11:00:00Z"));
        limits.figures.push(figure);
        let current = limits.current(now);
        assert_eq!(current.windows[0].used_percent, 0.);
        assert_eq!(current.windows[0].resets_at, None);
        assert_eq!(current.figures[0].used, Some(0.));
        assert_eq!(current.figures[0].remaining, Some(10.));
    }

    #[test]
    fn warning_prefers_blocking_exhaustion_then_the_fullest_near_window() {
        let now = at("2026-11-07T12:00:00Z");
        let mut credits = Window::new("primary", WindowKind::Session, "Session", 100.)
            .resetting(Some(at("2026-11-08T12:00:00Z")), None);
        credits.continues_on_credits = true;
        let blocking = Window::new("secondary", WindowKind::Weekly, "Weekly", 100.)
            .resetting(Some(at("2026-11-07T13:00:00Z")), None);
        let limits = Limits::new(vec![credits.clone(), blocking], now);
        assert_eq!(limits.warning().unwrap().id, "secondary");
        assert_eq!(
            warning_text(limits.warning().unwrap(), "Codex", DisplayMode::Used, now),
            "Codex usage limit reached. The weekly limit resets in 1h 0m."
        );
        assert_eq!(
            warning_text(&credits, "Codex", DisplayMode::Used, now),
            "Codex session limit reached. Using credits until it resets in 1d 0h."
        );
        let near = Limits::new(
            vec![
                Window::new("a", WindowKind::Session, "Session", 91.5),
                Window::new("b", WindowKind::Weekly, "Weekly", 95.),
                Window::new("c", WindowKind::Weekly, "Weekly", 50.),
            ],
            now,
        );
        let warning = near.warning().unwrap();
        assert_eq!(warning.id, "b");
        assert_eq!(
            warning_text(warning, "Claude Code", DisplayMode::Remaining, now),
            "5% of your Claude Code weekly limit is left."
        );
        assert!(
            Limits::new(
                vec![Window::new("a", WindowKind::Session, "Session", 89.)],
                now
            )
            .warning()
            .is_none()
        );
    }

    #[test]
    fn most_constrained_counts_model_windows_and_breaks_ties_by_later_reset() {
        let now = at("2026-11-07T12:00:00Z");
        let a = Limits::new(
            vec![
                Window::new("a", WindowKind::Session, "Session", 70.)
                    .resetting(Some(at("2026-11-07T13:00:00Z")), None),
            ],
            now,
        );
        let mut b = Limits::new(vec![], now);
        b.model_windows.push(
            Window::new("m", WindowKind::Weekly, "Spark · Weekly", 70.)
                .resetting(Some(at("2026-11-09T13:00:00Z")), None),
        );
        let (index, window) = most_constrained([Some(&a), None, Some(&b)]).unwrap();
        assert_eq!((index, window.id.as_str()), (2, "m"));
        assert!(most_constrained([None]).is_none());
    }

    #[test]
    fn claude_get_usage_reads_windows_scoped_models_spend_and_allowances() {
        let response = json!({"rate_limits_available":true,"rate_limits":{
            "five_hour":{"utilization":42.0,"resets_at":"2026-11-07T14:10:00.340563+00:00"},
            "seven_day":{"utilization":10.5,"resets_at":"2026-11-10T00:00:00Z"},
            "model_scoped":[{"display_name":"Opus 4","utilization":77,"resets_at":"2026-11-10T00:00:00Z"},{"display_name":"","utilization":1}],
            "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"currency":"usd"},
            "limits":[{"kind":"spend","is_active":true,"resets_at":"2026-12-01T00:00:00Z"}],
            "iguana_necktie":{"limit_dollars":100,"utilization":25,"resets_at":"2026-12-31T00:00:00Z"},
            "unnamed":{"limit_dollars":5}
        }});
        let limits = claude::limits_from_usage(&response, at("2026-11-07T12:00:00Z")).unwrap();
        let ids = limits
            .windows
            .iter()
            .map(|w| w.id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            ids,
            [
                "five_hour",
                "seven_day",
                "seven_day_opus_4",
                "monthly_spend"
            ]
        );
        assert_eq!(limits.windows[0].duration_minutes, Some(300));
        assert_eq!(
            limits.windows[0].resets_at,
            Some(at("2026-11-07T14:10:00.340563Z"))
        );
        assert!(limits.windows[0].continues_on_credits);
        assert!(!limits.windows[2].continues_on_credits);
        assert_eq!(limits.windows[2].label, "Weekly · Opus 4");
        assert_eq!(limits.windows[3].used_percent, 25.);
        let extra = &limits.figures[0];
        assert_eq!((extra.used, extra.limit), (Some(12.5), Some(50.)));
        assert_eq!(extra.unit, Unit::Currency("USD".into()));
        assert_eq!(extra.resets_at, Some(at("2026-12-01T00:00:00Z")));
        let cloud = &limits.figures[1];
        assert_eq!(
            (cloud.label.as_str(), cloud.used),
            ("Cloud credits", Some(25.))
        );
        assert_eq!(cloud.expires_at, Some(at("2026-12-31T00:00:00Z")));
        assert_eq!(limits.figures.len(), 2);
    }

    #[test]
    fn claude_without_plan_limits_or_with_disabled_or_spent_overage_never_continues() {
        assert!(
            claude::windows(&json!({"rate_limits_available":false,"rate_limits":{}})).is_none()
        );
        assert!(
            claude::windows(&json!({"rate_limits_available":true,"rate_limits":null})).is_none()
        );
        for extra in [
            json!({"is_enabled":false}),
            json!({"is_enabled":true,"user_disabled":true}),
            json!({"is_enabled":true,"monthly_limit":100,"used_credits":100}),
            json!({"is_enabled":true,"monthly_limit":0}),
        ] {
            let response = json!({"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":5},"extra_usage":extra}});
            assert!(!claude::windows(&response).unwrap()[0].continues_on_credits);
        }
        let off = json!({"rate_limits_available":true,"rate_limits":{"extra_usage":{"is_enabled":false,"currency":"jpy"}}});
        let figure = &claude::figures(&off)[0];
        assert_eq!(figure.detail.as_deref(), Some("Off"));
        assert_eq!(figure.unit, Unit::Currency("JPY".into()));
        let spend = json!({"rate_limits_available":true,"rate_limits":{"spend":{"enabled":true,
            "used":{"currency":"EUR","amount_minor":1234,"exponent":2},"limit":{"currency":"EUR","amount_minor":5000,"exponent":2}}}});
        let limits = claude::limits_from_usage(&spend, Utc::now()).unwrap();
        assert!((limits.windows[0].used_percent - 24.68).abs() < 1e-9);
        assert_eq!(
            (limits.figures[0].used, limits.figures[0].limit),
            (Some(12.34), Some(50.))
        );
        assert_eq!(claude::minor_unit_scale("KWD"), 1000.);
    }

    #[test]
    fn limits_round_trip_through_json_without_loss() {
        let mut limits = claude::limits_from_usage(
            &json!({"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":5}}}),
            at("2026-11-07T12:00:00Z"),
        )
        .unwrap();
        limits.credits = Some(Credits {
            has_credits: true,
            unlimited: false,
            balance: Some("12.30".into()),
        });
        let value = serde_json::to_value(&limits).unwrap();
        assert_eq!(serde_json::from_value::<Limits>(value).unwrap(), limits);
    }
}
