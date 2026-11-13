//! Settings › Usage's figures, ported from Swift's `UsageReport` and
//! `UsageEvents.fromRecords`. Events come only from saved turns whose provider
//! reported what the whole turn used (additive `usage.turnTotals`); context and
//! output snapshots never add up. Costs are API list-price estimates
//! (`usage_pricing`), never billing. Days follow the caller's time zone.
use crate::organization::Records;
use anyhow::Result;
use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};

/// `ProviderAccount.defaultID`; a record without an account ran with it.
pub const DEFAULT_ACCOUNT: &str = "default";
/// Swift's `ProviderKind.allCases`, which orders the chart's stacks and legend.
pub const PROVIDERS: [&str; 6] = [
    "claude",
    "codex",
    "cursor",
    "grok",
    "opencode",
    "antigravity",
];

/// Tokens billed across one or more model requests, split the way prices are.
/// Unlike a context snapshot, these add up.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TokenTotals {
    /// Input tokens that were neither read from nor written to the prompt cache.
    pub input: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    /// The part of `cache_write` kept for an hour.
    pub cache_write_long: u64,
    /// Output tokens, reasoning included.
    pub output: u64,
    /// The part of `output` the model spent reasoning.
    pub reasoning: u64,
}
impl TokenTotals {
    pub fn new(
        input: u64,
        cache_read: u64,
        cache_write: u64,
        cache_write_long: u64,
        output: u64,
        reasoning: u64,
    ) -> Self {
        Self {
            input,
            cache_read,
            cache_write,
            cache_write_long: cache_write_long.min(cache_write),
            output,
            reasoning: reasoning.min(output),
        }
    }
    /// Swift's lenient `TokenTotals` decoding: a field that is missing, negative or
    /// not an integer counts 0. None when nothing was reported.
    pub fn saved(value: &Value) -> Option<Self> {
        value.as_object()?;
        let count = |key: &str| value.get(key).and_then(Value::as_u64).unwrap_or(0);
        let totals = Self::new(
            count("input"),
            count("cacheRead"),
            count("cacheWrite"),
            count("cacheWriteLong"),
            count("output"),
            count("reasoning"),
        );
        (!totals.is_empty()).then_some(totals)
    }
    /// Every token read or written.
    pub fn total(&self) -> u64 {
        self.input
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_write)
            .saturating_add(self.output)
    }
    pub fn is_empty(&self) -> bool {
        self.total() == 0
    }
    fn add(&mut self, other: &Self) {
        self.input = self.input.saturating_add(other.input);
        self.cache_read = self.cache_read.saturating_add(other.cache_read);
        self.cache_write = self.cache_write.saturating_add(other.cache_write);
        self.cache_write_long = self.cache_write_long.saturating_add(other.cache_write_long);
        self.output = self.output.saturating_add(other.output);
        self.reasoning = self.reasoning.saturating_add(other.reasoning);
    }
}

/// One saved Coincide turn, as much of it as Usage reads. Records without a
/// valid provider or finish time are left out by `turn_records`.
#[derive(Clone, Debug, PartialEq)]
pub struct TurnRecord {
    pub thread_id: Option<String>,
    pub project_id: Option<String>,
    pub provider: String,
    /// `DEFAULT_ACCOUNT` for a record that names none.
    pub account_id: String,
    pub model: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: DateTime<Utc>,
    /// Additive totals the provider reported for the whole turn.
    pub turn_totals: Option<TokenTotals>,
}
impl TurnRecord {
    /// How long the turn ran; 0 without a valid start.
    pub fn duration_seconds(&self) -> f64 {
        self.started_at.map_or(0., |started| {
            (self.finished_at - started).num_milliseconds().max(0) as f64 / 1000.
        })
    }
}

fn text(value: Option<&Value>) -> Option<String> {
    value?
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
        .map(str::to_owned)
}
fn date(value: Option<&Value>) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value?.as_str()?)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

/// The saved `usage-history.json` document's turns. A malformed document fails
/// as a whole (as the saved-history list does); records Usage cannot place are
/// counted in the second value rather than guessed.
pub fn turn_records(bytes: &[u8]) -> Result<(Vec<TurnRecord>, usize)> {
    let records = Records::parse(bytes)?;
    let mut turns = Vec::with_capacity(records.records().len());
    let mut skipped = 0;
    for record in records.records() {
        let provider = text(record.get("provider")).filter(|p| PROVIDERS.contains(&p.as_str()));
        let (Some(provider), Some(finished_at)) = (provider, date(record.get("finishedAt"))) else {
            skipped += 1;
            continue;
        };
        let started_at = date(record.get("startedAt")).map(|started| started.min(finished_at));
        let account_id = text(record.get("accountID")).unwrap_or_else(|| DEFAULT_ACCOUNT.into());
        turns.push(TurnRecord {
            thread_id: text(record.get("threadID")).map(|id| id.to_uppercase()),
            project_id: text(record.get("projectID")).map(|id| id.to_uppercase()),
            provider,
            account_id,
            model: text(record.get("modelID")),
            started_at,
            finished_at,
            turn_totals: record
                .get("usage")
                .and_then(|usage| usage.get("turnTotals"))
                .and_then(TokenTotals::saved),
        });
    }
    Ok((turns, skipped))
}

/// Tokens one provider account spent on one Coincide turn.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub date: DateTime<Utc>,
    pub provider: String,
    pub account_id: String,
    pub model: Option<String>,
    pub tokens: TokenTotals,
    /// The request's whole prompt, for long-context pricing; 0 when unknown (a turn's totals).
    pub prompt_tokens: u64,
    pub project_id: Option<String>,
}
impl Event {
    /// The API-equivalent cost at list prices, or None when the model has no known price.
    pub fn estimated_cost(&self) -> Option<f64> {
        crate::usage_pricing::cost(&self.tokens, self.model.as_deref(), self.prompt_tokens)
    }
}

/// The events of Coincide's turns whose provider reported what the whole turn
/// used, leaving out `excluding` (providers whose logs are read instead, so no
/// turn counts twice).
pub fn events(records: &[TurnRecord], excluding: &[&str]) -> Vec<Event> {
    records
        .iter()
        .filter(|record| !excluding.contains(&record.provider.as_str()))
        .filter_map(|record| {
            Some(Event {
                date: record.finished_at,
                provider: record.provider.clone(),
                account_id: record.account_id.clone(),
                model: record.model.clone(),
                tokens: record.turn_totals?,
                prompt_tokens: 0,
                project_id: record.project_id.clone(),
            })
        })
        .collect()
}

/// Totals over a set of usage events.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Totals {
    pub tokens: TokenTotals,
    /// The API-equivalent cost of the priced events.
    pub cost: f64,
    /// Tokens of events whose model has no known price, left out of `cost`.
    pub unpriced_tokens: u64,
    pub requests: u64,
}
impl Totals {
    fn add(&mut self, event: &Event, cost: Option<f64>) {
        self.tokens.add(&event.tokens);
        self.requests = self.requests.saturating_add(1);
        match cost {
            Some(cost) => self.cost += cost,
            None => {
                self.unpriced_tokens = self.unpriced_tokens.saturating_add(event.tokens.total())
            }
        }
    }
    /// Every token was priced.
    pub fn is_fully_priced(&self) -> bool {
        self.unpriced_tokens == 0
    }
    pub fn has_priced_tokens(&self) -> bool {
        self.tokens.total() > self.unpriced_tokens
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DayRow {
    pub day: NaiveDate,
    pub provider: String,
    pub totals: Totals,
}
#[derive(Clone, Debug, PartialEq)]
pub struct ModelRow {
    pub provider: String,
    /// Empty for turns that named no model.
    pub model: String,
    pub totals: Totals,
}
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectRow {
    pub project_id: String,
    pub totals: Totals,
}

/// The key of a provider account in `Report::accounts`.
pub fn account_key(provider: &str, account: &str) -> String {
    format!("{provider}/{account}")
}

/// How a period compares with the one before: 0.12 for 12% more tokens. None
/// when the one before had none.
pub fn trend(current: &Totals, previous: &Totals) -> Option<f64> {
    let previous = previous.tokens.total();
    (previous > 0).then(|| (current.tokens.total() as f64 - previous as f64) / previous as f64)
}

/// The Usage page's figures for the events a filter kept.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Report {
    pub today: Totals,
    pub last_week: Totals,
    pub last_month: Totals,
    /// The periods just before those, for the trend.
    pub yesterday: Totals,
    pub previous_week: Totals,
    pub previous_month: Totals,
    /// The whole chosen period.
    pub period: Totals,
    /// Per day and provider over the period, oldest first, providers in Swift's order.
    pub days: Vec<DayRow>,
    /// Models over the period, most tokens first.
    pub models: Vec<ModelRow>,
    /// Coincide's projects over the period, most tokens first.
    pub projects: Vec<ProjectRow>,
    /// The period by provider account, keyed by `account_key`.
    pub accounts: BTreeMap<String, Totals>,
}

/// The local date `count` days back from `today`, counting today as one.
pub fn days_back(today: NaiveDate, count: u32) -> NaiveDate {
    today - Duration::days(i64::from(count.max(1)) - 1)
}

impl Report {
    /// Sums `events` over `period_days` days ending today (counting today as one),
    /// along with today and the last 7 and 30 days whatever the period. Days
    /// follow `zone`; events more than a minute in the future are left out.
    pub fn make<Tz: TimeZone>(
        events: &[Event],
        period_days: u32,
        now: DateTime<Utc>,
        zone: &Tz,
    ) -> Self {
        let mut report = Self::default();
        let today = now.with_timezone(zone).date_naive();
        let week = days_back(today, 7);
        let month = days_back(today, 30);
        let period = days_back(today, period_days);
        let yesterday = days_back(today, 2);
        let previous_week = days_back(today, 14);
        let previous_month = days_back(today, 60);
        let earliest = previous_month.min(period);
        let latest = now + Duration::seconds(60);
        let mut days: BTreeMap<NaiveDate, HashMap<&str, Totals>> = BTreeMap::new();
        let mut models: HashMap<String, ModelRow> = HashMap::new();
        let mut projects: HashMap<&str, Totals> = HashMap::new();
        for event in events {
            if event.date > latest {
                continue;
            }
            let day = event.date.with_timezone(zone).date_naive();
            if day < earliest {
                continue;
            }
            let cost = event.estimated_cost();
            if day >= today {
                report.today.add(event, cost);
            }
            if day >= week {
                report.last_week.add(event, cost);
            }
            if day >= month {
                report.last_month.add(event, cost);
            } else if day >= previous_month {
                report.previous_month.add(event, cost);
            }
            if day < week && day >= previous_week {
                report.previous_week.add(event, cost);
            }
            if day < today && day >= yesterday {
                report.yesterday.add(event, cost);
            }
            if day < period {
                continue;
            }
            report.period.add(event, cost);
            days.entry(day)
                .or_default()
                .entry(event.provider.as_str())
                .or_default()
                .add(event, cost);
            let model = event.model.as_deref().map(str::trim).unwrap_or_default();
            models
                .entry(format!("{}/{model}", event.provider))
                .or_insert_with(|| ModelRow {
                    provider: event.provider.clone(),
                    model: model.to_owned(),
                    totals: Totals::default(),
                })
                .totals
                .add(event, cost);
            if let Some(project) = &event.project_id {
                projects.entry(project).or_default().add(event, cost);
            }
            report
                .accounts
                .entry(account_key(&event.provider, &event.account_id))
                .or_default()
                .add(event, cost);
        }
        report.days = days
            .into_iter()
            .flat_map(|(day, providers)| {
                PROVIDERS.iter().filter_map(move |provider| {
                    providers.get(provider).map(|totals| DayRow {
                        day,
                        provider: (*provider).to_owned(),
                        totals: totals.clone(),
                    })
                })
            })
            .collect();
        let mut models = models.into_iter().collect::<Vec<_>>();
        models.sort_by(|(a_id, a), (b_id, b)| {
            (b.totals.tokens.total(), b_id).cmp(&(a.totals.tokens.total(), a_id))
        });
        report.models = models.into_iter().map(|(_, row)| row).collect();
        let mut projects = projects
            .into_iter()
            .map(|(project_id, totals)| ProjectRow {
                project_id: project_id.to_owned(),
                totals,
            })
            .collect::<Vec<_>>();
        projects.sort_by(|a, b| {
            (b.totals.tokens.total(), &b.project_id).cmp(&(a.totals.tokens.total(), &a.project_id))
        });
        report.projects = projects;
        report
    }
}

/// Coincide's turns in a period, for "Activity in Coincide".
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Activity {
    pub turns: usize,
    pub active_seconds: f64,
    pub threads: usize,
}

/// Turns that finished from `period_days` days ago (counting today) with the
/// provider and account filters, whether or not they reported tokens.
pub fn activity<Tz: TimeZone>(
    records: &[TurnRecord],
    period_days: u32,
    provider: Option<&str>,
    account: Option<&str>,
    now: DateTime<Utc>,
    zone: &Tz,
) -> Activity {
    activity_filtered(records.iter(), period_days, provider, account, now, zone)
}

/// As `activity`, for the provider subset currently shown in a usage view.
pub fn activity_filtered<'a, Tz: TimeZone>(
    records: impl IntoIterator<Item = &'a TurnRecord>,
    period_days: u32,
    provider: Option<&str>,
    account: Option<&str>,
    now: DateTime<Utc>,
    zone: &Tz,
) -> Activity {
    let since = days_back(now.with_timezone(zone).date_naive(), period_days);
    let mut threads = HashSet::new();
    let mut activity = Activity::default();
    for record in records {
        if record.finished_at.with_timezone(zone).date_naive() < since
            || provider.is_some_and(|provider| record.provider != provider)
            || account.is_some_and(|account| record.account_id != account)
        {
            continue;
        }
        activity.turns += 1;
        activity.active_seconds += record.duration_seconds();
        if let Some(thread) = &record.thread_id {
            threads.insert(thread.as_str());
        }
    }
    activity.threads = threads.len();
    activity
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;
    use serde_json::json;

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }
    fn event(date: &str, provider: &str, model: Option<&str>, input: u64) -> Event {
        Event {
            date: at(date),
            provider: provider.into(),
            account_id: DEFAULT_ACCOUNT.into(),
            model: model.map(str::to_owned),
            tokens: TokenTotals::new(input, 0, 0, 0, 0, 0),
            prompt_tokens: 0,
            project_id: None,
        }
    }

    #[test]
    fn saved_turn_totals_decode_leniently_and_clamp_subsets_like_swift() {
        let totals = TokenTotals::saved(&json!({"input":10,"cacheRead":-3,"cacheWrite":4,"cacheWriteLong":9,"output":"7","reasoning":2})).unwrap();
        assert_eq!(totals, TokenTotals::new(10, 0, 4, 4, 0, 0));
        assert_eq!(totals.total(), 14);
        assert!(TokenTotals::saved(&json!({"input":0})).is_none());
        assert!(TokenTotals::saved(&json!([1])).is_none());
        let max = TokenTotals::new(u64::MAX, 1, 0, 0, 0, 0);
        assert_eq!(max.total(), u64::MAX);
    }

    #[test]
    fn records_keep_turns_with_dates_and_only_reported_totals_become_events() {
        let bytes = serde_json::to_vec(&json!([
            {"id":uuid::Uuid::from_u128(1),"threadID":"a","projectID":"p","provider":"cursor","accountID":null,"modelID":"claude-sonnet-4-5",
             "startedAt":"2026-11-05T09:59:00Z","finishedAt":"2026-11-05T10:00:00Z","usage":{"turnTotals":{"input":1000,"output":10}}},
            {"id":uuid::Uuid::from_u128(2),"threadID":"a","provider":"codex","accountID":"work",
             "startedAt":"2026-11-05T11:00:00Z","finishedAt":"2026-11-05T10:00:00Z","usage":{"inputTokens":900}},
            {"id":uuid::Uuid::from_u128(3),"provider":"future","finishedAt":"2026-11-05T10:00:00Z"},
            {"id":uuid::Uuid::from_u128(4),"provider":"claude","finishedAt":"not a date"},
        ]))
        .unwrap();
        let (records, skipped) = turn_records(&bytes).unwrap();
        assert_eq!((records.len(), skipped), (2, 2));
        assert_eq!(records[0].account_id, DEFAULT_ACCOUNT);
        assert_eq!(records[0].project_id.as_deref(), Some("P"));
        assert_eq!(records[0].duration_seconds(), 60.);
        // A start after the finish is a zero-length turn, as Swift's init clamps it.
        assert_eq!(records[1].duration_seconds(), 0.);
        assert_eq!(records[1].account_id, "work");
        let events = events(&records, &[]);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].tokens.total(), 1010);
        assert!(super::events(&records, &["cursor"]).is_empty());
        assert!(turn_records(b"{}").is_err());
    }

    #[test]
    fn periods_and_trends_follow_local_days() {
        let now = at("2026-11-07T12:00:00Z");
        let zone = FixedOffset::east_opt(0).unwrap();
        let events = [
            event("2026-11-07T08:00:00Z", "codex", Some("gpt-5"), 100),
            event("2026-11-06T08:00:00Z", "codex", Some("gpt-5"), 50),
            event(
                "2026-11-01T08:00:00Z",
                "claude",
                Some("claude-opus-4-5"),
                30,
            ),
            event("2026-10-28T08:00:00Z", "claude", None, 20),
            event("2026-10-01T08:00:00Z", "claude", None, 7),
            event("2026-09-10T08:00:00Z", "claude", None, 5),
            // More than a minute ahead of now, and before the 60-day window.
            event("2026-11-07T12:02:00Z", "codex", None, 1000),
            event("2026-08-01T08:00:00Z", "codex", None, 1000),
        ];
        let report = Report::make(&events, 30, now, &zone);
        assert_eq!(report.today.tokens.total(), 100);
        assert_eq!(report.yesterday.tokens.total(), 50);
        assert_eq!(report.last_week.tokens.total(), 180);
        assert_eq!(report.previous_week.tokens.total(), 20);
        assert_eq!(report.last_month.tokens.total(), 200);
        assert_eq!(report.previous_month.tokens.total(), 12);
        assert_eq!(report.period, report.last_month);
        assert_eq!(trend(&report.today, &report.yesterday), Some(1.));
        assert_eq!(trend(&report.previous_week, &Totals::default()), None);
        // Days oldest first; models most tokens first; unknown models stay apart.
        assert_eq!(
            report.days.first().unwrap().day,
            NaiveDate::from_ymd_opt(2026, 10, 28).unwrap()
        );
        assert_eq!(report.days.last().unwrap().provider, "codex");
        assert_eq!(report.models[0].model, "gpt-5");
        assert_eq!(report.models[1].model, "claude-opus-4-5");
        assert_eq!(report.models[2].model, "");
        assert_eq!(report.accounts["codex/default"].tokens.total(), 150);
        // A 7-day period narrows only the period figures.
        let week = Report::make(&events, 7, now, &zone);
        assert_eq!(week.period.tokens.total(), 180);
        assert_eq!(week.last_month.tokens.total(), 200);
        // A 90-day period reaches back past the 60-day comparison window.
        assert_eq!(
            Report::make(&events, 90, now, &zone).period.tokens.total(),
            212
        );
        // Thirteen hours east it is already the 8th: this morning's UTC turn was yesterday.
        let east = FixedOffset::east_opt(13 * 3600).unwrap();
        let shifted = Report::make(&events, 30, now, &east);
        assert_eq!(shifted.today.tokens.total(), 0);
        assert_eq!(shifted.yesterday.tokens.total(), 100);
    }

    #[test]
    fn costs_split_priced_and_unpriced_tokens() {
        let now = at("2026-11-07T12:00:00Z");
        let events = [
            event("2026-11-07T08:00:00Z", "codex", Some("gpt-5"), 1_000_000),
            event("2026-11-07T09:00:00Z", "cursor", Some("auto"), 500),
        ];
        let report = Report::make(&events, 7, now, &Utc);
        assert!((report.today.cost - 1.25).abs() < 1e-9);
        assert_eq!(report.today.unpriced_tokens, 500);
        assert!(report.today.has_priced_tokens());
        assert!(!report.today.is_fully_priced());
        let unpriced = Report::make(&events[1..], 7, now, &Utc);
        assert!(!unpriced.today.has_priced_tokens());
        // Stacks follow Swift's provider order within a day.
        assert_eq!(
            report
                .days
                .iter()
                .map(|row| row.provider.as_str())
                .collect::<Vec<_>>(),
            ["codex", "cursor"]
        );
    }

    #[test]
    fn projects_rank_by_tokens_and_activity_counts_every_turn() {
        let now = at("2026-11-07T12:00:00Z");
        let mut a = event("2026-11-07T08:00:00Z", "codex", None, 10);
        a.project_id = Some("A".into());
        let mut b = event("2026-11-07T08:00:00Z", "codex", None, 30);
        b.project_id = Some("B".into());
        let report = Report::make(&[a, b], 7, now, &Utc);
        assert_eq!(report.projects[0].project_id, "B");
        assert_eq!(report.projects[1].totals.tokens.total(), 10);
        let record = |thread: &str, provider: &str, account: &str, finished: &str| TurnRecord {
            thread_id: Some(thread.into()),
            project_id: None,
            provider: provider.into(),
            account_id: account.into(),
            model: None,
            started_at: Some(at(finished) - Duration::seconds(90)),
            finished_at: at(finished),
            turn_totals: None,
        };
        let records = [
            record("1", "codex", "default", "2026-11-07T08:00:00Z"),
            record("1", "codex", "work", "2026-11-06T08:00:00Z"),
            record("2", "claude", "default", "2026-11-01T08:00:00Z"),
            record("3", "claude", "default", "2026-10-01T08:00:00Z"),
        ];
        let all = activity(&records, 7, None, None, now, &Utc);
        assert_eq!((all.turns, all.threads), (3, 2));
        assert_eq!(all.active_seconds, 270.);
        let codex = activity(&records, 30, Some("codex"), Some("work"), now, &Utc);
        assert_eq!((codex.turns, codex.threads), (1, 1));
        let enabled = activity_filtered(
            records.iter().filter(|record| record.provider == "claude"),
            7,
            None,
            None,
            now,
            &Utc,
        );
        assert_eq!((enabled.turns, enabled.threads), (1, 1));
        assert_eq!(enabled.active_seconds, 90.);
    }
}
