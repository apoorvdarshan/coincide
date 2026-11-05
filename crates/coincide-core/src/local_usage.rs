//! Metadata-only projection of actual saved provider reports. No source scanning,
//! live account requests, pricing estimates, or snapshot-to-billing conversion.
use crate::organization::Records;
use anyhow::{Result, ensure};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    LocalDocument,
    CapturedOriginal,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CaptureCoverage {
    NotConnected,
    CodexRequestSnapshots,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "state", content = "value", rename_all = "snake_case")]
pub enum Figure<T> {
    Missing,
    Null,
    Invalid,
    Reported(T),
}
impl<T> Figure<T> {
    pub fn value(&self) -> Option<&T> {
        if let Self::Reported(value) = self {
            Some(value)
        } else {
            None
        }
    }
}
fn read<T>(value: Option<&Value>, parse: impl FnOnce(&Value) -> Option<T>) -> Figure<T> {
    match value {
        None => Figure::Missing,
        Some(Value::Null) => Figure::Null,
        Some(value) => parse(value).map_or(Figure::Invalid, Figure::Reported),
    }
}
fn string(value: Option<&Value>, limit: usize) -> Figure<String> {
    read(value, |value| {
        value
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= limit && !s.chars().any(char::is_control))
            .map(str::to_owned)
    })
}
fn date_string(value: Option<&Value>) -> Figure<String> {
    read(value, |value| {
        value
            .as_str()
            .filter(|text| text.len() <= 128 && DateTime::parse_from_rfc3339(text).is_ok())
            .map(str::to_owned)
    })
}
fn number(value: Option<&Value>) -> Figure<u64> {
    read(value, Value::as_u64)
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Query {
    pub provider: Option<String>,
    pub project_id: Option<String>,
    pub account_id: Option<String>,
    pub since: Option<String>,
    pub offset: usize,
    pub limit: usize,
}
impl Default for Query {
    fn default() -> Self {
        Self {
            provider: None,
            project_id: None,
            account_id: None,
            since: None,
            offset: 0,
            limit: 100,
        }
    }
}
impl Query {
    pub fn first_page() -> Self {
        Self::default()
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Provenance {
    pub kind: Figure<String>,
    pub scope: Figure<String>,
    pub source_thread_id: Figure<String>,
    pub source_turn_id: Figure<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Usage {
    pub container_state: Figure<()>,
    pub turn_totals_state: Figure<()>,
    pub input_tokens: Figure<u64>,
    pub output_tokens: Figure<u64>,
    pub cached_input_tokens: Figure<u64>,
    pub context_window: Figure<u64>,
    pub cost_usd: Figure<f64>,
    pub turn_input: Figure<u64>,
    pub turn_cache_read: Figure<u64>,
    pub turn_cache_write: Figure<u64>,
    pub turn_cache_write_long: Figure<u64>,
    pub turn_output: Figure<u64>,
    pub turn_reasoning: Figure<u64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Row {
    pub id: String,
    pub thread_id: Figure<String>,
    pub project_id: Figure<String>,
    pub provider: Figure<String>,
    pub account_id: Figure<String>,
    pub model_id: Figure<String>,
    pub started_at: Figure<String>,
    pub finished_at: Figure<String>,
    pub outcome: Figure<String>,
    pub usage: Usage,
    pub provenance: Provenance,
}
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct CounterSummary {
    pub reported_sum: Option<u64>,
    pub reported: usize,
    pub missing: usize,
    pub null: usize,
    pub invalid: usize,
    pub overflow: bool,
}
impl CounterSummary {
    fn add(&mut self, value: &Figure<u64>) {
        match value {
            Figure::Reported(value) => {
                self.reported += 1;
                if !self.overflow {
                    match self.reported_sum.unwrap_or(0).checked_add(*value) {
                        Some(sum) => self.reported_sum = Some(sum),
                        None => {
                            self.reported_sum = None;
                            self.overflow = true;
                        }
                    }
                }
            }
            Figure::Missing => self.missing += 1,
            Figure::Null => self.null += 1,
            Figure::Invalid => self.invalid += 1,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Totals {
    pub input: CounterSummary,
    pub cache_read: CounterSummary,
    pub cache_write: CounterSummary,
    pub output: CounterSummary,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Report {
    pub source: Source,
    pub capture: CaptureCoverage,
    pub query: Query,
    pub available_providers: Vec<String>,
    pub stored_records: usize,
    pub matched_records: usize,
    pub missing_date_excluded: usize,
    pub rows: Vec<Row>,
    pub totals: Totals,
}
fn row(record: &Value) -> Row {
    let usage = record.get("usage");
    let field = |key| usage.and_then(|value| value.get(key));
    let turn = field("turnTotals");
    let total = |key| number(turn.and_then(|value| value.get(key)));
    let provenance = record.get("provenance");
    let reported = |key| provenance.and_then(|value| value.get(key));
    Row {
        id: record["id"]
            .as_str()
            .expect("Records validated identity")
            .into(),
        thread_id: string(record.get("threadID"), 128),
        project_id: string(record.get("projectID"), 128),
        provider: string(record.get("provider"), 128),
        account_id: string(record.get("accountID"), 512),
        model_id: string(record.get("modelID"), 512),
        started_at: date_string(record.get("startedAt")),
        finished_at: date_string(record.get("finishedAt")),
        outcome: string(record.get("outcome"), 128),
        usage: Usage {
            container_state: read(usage, |value| value.as_object().map(|_| ())),
            turn_totals_state: read(turn, |value| value.as_object().map(|_| ())),
            input_tokens: number(field("inputTokens")),
            output_tokens: number(field("outputTokens")),
            cached_input_tokens: number(field("cachedInputTokens")),
            context_window: number(field("contextWindow")),
            cost_usd: read(field("costUSD"), |v| {
                v.as_f64().filter(|n| n.is_finite() && *n >= 0.0)
            }),
            turn_input: total("input"),
            turn_cache_read: total("cacheRead"),
            turn_cache_write: total("cacheWrite"),
            turn_cache_write_long: total("cacheWriteLong"),
            turn_output: total("output"),
            turn_reasoning: total("reasoning"),
        },
        provenance: Provenance {
            kind: string(reported("kind"), 128),
            scope: string(reported("scope"), 128),
            source_thread_id: string(reported("sourceThreadId"), 512),
            source_turn_id: string(reported("sourceTurnId"), 512),
        },
    }
}
/// Parent supplies exactly Store.document("usage-history.json") (local overlay
/// ELSE captured original); never concatenate original+overlay or scan sessions.
pub fn project(
    bytes: &[u8],
    source: Source,
    query: Query,
    capture: CaptureCoverage,
) -> Result<Report> {
    ensure!(
        (1..=200).contains(&query.limit) && query.offset <= 10_000,
        "Usage page bounds invalid"
    );
    for value in [&query.provider, &query.project_id, &query.account_id]
        .into_iter()
        .flatten()
    {
        ensure!(
            !value.is_empty() && value.len() <= 512 && !value.chars().any(char::is_control),
            "Invalid usage filter"
        );
    }
    let since = query
        .since
        .as_ref()
        .map(|value| DateTime::parse_from_rfc3339(value))
        .transpose()?;
    let records = Records::parse(bytes)?;
    let mut rows = Vec::new();
    let mut available_providers = std::collections::BTreeSet::new();
    let mut totals = Totals::default();
    let mut missing_date_excluded = 0;
    for record in records.records() {
        let row = row(record);
        if let Some(provider) = row.provider.value() {
            available_providers.insert(provider.clone());
        }
        if query
            .provider
            .as_ref()
            .is_some_and(|provider| row.provider.value() != Some(provider))
            || query
                .account_id
                .as_ref()
                .is_some_and(|account| row.account_id.value() != Some(account))
            || query.project_id.as_ref().is_some_and(|project| {
                row.project_id
                    .value()
                    .is_none_or(|id| !id.eq_ignore_ascii_case(project))
            })
        {
            continue;
        }
        if let Some(since) = since {
            let date = row
                .finished_at
                .value()
                .and_then(|value| DateTime::parse_from_rfc3339(value).ok());
            let Some(date) = date else {
                missing_date_excluded += 1;
                continue;
            };
            if date < since {
                continue;
            }
        }
        totals.input.add(&row.usage.turn_input);
        totals.cache_read.add(&row.usage.turn_cache_read);
        totals.cache_write.add(&row.usage.turn_cache_write);
        totals.output.add(&row.usage.turn_output);
        rows.push(row);
    }
    // Known timestamps newest first; unknown dates remain visible without a date
    // filter, deterministically ordered by record identity after known dates.
    rows.sort_by(|a, b| {
        let date = |row: &Row| {
            row.finished_at
                .value()
                .and_then(|v| DateTime::parse_from_rfc3339(v).ok())
        };
        date(b).cmp(&date(a)).then_with(|| a.id.cmp(&b.id))
    });
    let matched_records = rows.len();
    let rows = rows
        .into_iter()
        .skip(query.offset)
        .take(query.limit)
        .collect();
    Ok(Report {
        source,
        capture,
        query,
        available_providers: available_providers.into_iter().collect(),
        stored_records: records.records().len(),
        matched_records,
        missing_date_excluded,
        rows,
        totals,
    })
}
/// UI convenience only; explicit filtering uses UTC and never provider refreshes.
pub fn since_days(now_unix_seconds: i64, days: u16) -> Result<String> {
    ensure!((1..=366).contains(&days), "Usage period invalid");
    let date = DateTime::<Utc>::from_timestamp(now_unix_seconds, 0)
        .ok_or_else(|| anyhow::anyhow!("Usage clock unavailable"))?;
    Ok(date
        .checked_sub_signed(chrono::Duration::days(i64::from(days)))
        .ok_or_else(|| anyhow::anyhow!("Usage period out of range"))?
        .to_rfc3339())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn record(id: u128) -> Value {
        json!({"id":uuid::Uuid::from_u128(id),"threadID":uuid::Uuid::nil(),"provider":"codex","finishedAt":"2026-11-05T10:00:00Z"})
    }
    fn report(value: Value) -> Report {
        project(
            &serde_json::to_vec(&value).unwrap(),
            Source::CapturedOriginal,
            Query::default(),
            CaptureCoverage::NotConnected,
        )
        .unwrap()
    }
    #[test]
    fn snapshots_and_costs_never_become_additive_turn_usage() {
        let mut row = record(1);
        row["usage"] =
            json!({"inputTokens":900,"outputTokens":40,"costUSD":2.5,"contextWindow":1000});
        let output = report(json!([row]));
        assert!(matches!(
            output.rows[0].usage.input_tokens,
            Figure::Reported(900)
        ));
        assert_eq!(output.totals.input.reported_sum, None);
        assert_eq!(output.totals.input.missing, 1);
        assert!(matches!(output.rows[0].usage.cost_usd,Figure::Reported(value) if value==2.5));
    }
    #[test]
    fn missing_null_invalid_and_reported_zero_remain_distinct() {
        let mut row = record(1);
        row["usage"] =
            json!({"inputTokens":null,"outputTokens":-1,"cachedInputTokens":0,"costUSD":"unknown"});
        let output = report(json!([row]));
        let row = &output.rows[0];
        assert!(matches!(row.usage.input_tokens, Figure::Null));
        assert!(matches!(row.usage.output_tokens, Figure::Invalid));
        assert!(matches!(row.usage.cached_input_tokens, Figure::Reported(0)));
        assert!(matches!(row.usage.context_window, Figure::Missing));
        assert!(matches!(row.usage.cost_usd, Figure::Invalid));
        assert!(matches!(row.account_id, Figure::Missing));
    }
    #[test]
    fn turn_counter_coverage_and_overflow_never_saturate_or_zero_fill() {
        let mut a = record(1);
        a["usage"] =
            json!({"turnTotals":{"input":u64::MAX,"output":0,"cacheRead":null,"cacheWrite":-4}});
        let mut b = record(2);
        b["usage"] = json!({"turnTotals":{"input":1,"output":3}});
        let output = report(json!([a, b]));
        assert!(output.totals.input.overflow);
        assert_eq!(output.totals.input.reported_sum, None);
        assert_eq!(output.totals.input.reported, 2);
        assert_eq!(output.totals.output.reported_sum, Some(3));
        assert_eq!(output.totals.cache_read.null, 1);
        assert_eq!(output.totals.cache_write.invalid, 1);
        assert_eq!(output.totals.cache_write.reported_sum, None);
    }
    #[test]
    fn page_does_not_change_filtered_aggregates_and_dates_are_explicit() {
        let mut a = record(1);
        a["usage"] = json!({"turnTotals":{"input":2}});
        let mut b = record(2);
        b["finishedAt"] = json!("invalid");
        b["usage"] = json!({"turnTotals":{"input":99}});
        let value = json!([a, b]);
        let bytes = serde_json::to_vec(&value).unwrap();
        let output = project(
            &bytes,
            Source::LocalDocument,
            Query {
                limit: 1,
                ..Default::default()
            },
            CaptureCoverage::CodexRequestSnapshots,
        )
        .unwrap();
        assert_eq!(output.rows.len(), 1);
        assert_eq!(output.matched_records, 2);
        assert_eq!(output.totals.input.reported_sum, Some(101));
        let output = project(
            &bytes,
            Source::LocalDocument,
            Query {
                since: Some("2026-11-01T00:00:00Z".into()),
                ..Default::default()
            },
            CaptureCoverage::CodexRequestSnapshots,
        )
        .unwrap();
        assert_eq!(output.matched_records, 1);
        assert_eq!(output.missing_date_excluded, 1);
        assert_eq!(output.totals.input.reported_sum, Some(2));
        assert_eq!(serde_json::from_slice::<Value>(&bytes).unwrap(), value);
    }
    #[test]
    fn raw_provenance_unknown_payload_and_transcript_are_not_exposed() {
        let mut row = record(1);
        row["provenance"] = json!({"kind":"codex_app_server_snapshot","scope":"last_request","rawTokenUsage":{"private":"synthetic-private-marker"},"unknown":"synthetic-private-marker"});
        row["prompt"] = json!("synthetic-private-marker");
        let output = report(json!([row]));
        let serialized = serde_json::to_string(&output).unwrap();
        assert!(!serialized.contains("synthetic-private-marker"));
        assert_eq!(
            output.rows[0].provenance.scope.value().map(String::as_str),
            Some("last_request")
        );
    }
    #[test]
    fn raw_account_filter_does_not_alias_missing_null_or_custom_accounts() {
        let mut a = record(1);
        a["accountID"] = Value::Null;
        let mut b = record(2);
        b["accountID"] = json!("default");
        let mut c = record(3);
        c["accountID"] = json!(" custom ");
        let bytes = serde_json::to_vec(&json!([a, b, c])).unwrap();
        let output = project(
            &bytes,
            Source::LocalDocument,
            Query {
                account_id: Some("default".into()),
                ..Default::default()
            },
            CaptureCoverage::NotConnected,
        )
        .unwrap();
        assert_eq!(output.matched_records, 1);
        assert_eq!(output.rows[0].id, uuid::Uuid::from_u128(2).to_string());
    }
    #[test]
    fn duplicate_bad_documents_and_unbounded_queries_fail_without_partial_success() {
        assert_eq!(serde_json::from_str::<Query>("{}").unwrap().limit, 100);
        assert!(serde_json::from_str::<Query>(r#"{"unknown":true}"#).is_err());
        let row = record(1);
        assert!(
            project(
                &serde_json::to_vec(&json!([row, row])).unwrap(),
                Source::CapturedOriginal,
                Query::default(),
                CaptureCoverage::NotConnected
            )
            .is_err()
        );
        assert!(
            project(
                b"[]",
                Source::LocalDocument,
                Query {
                    limit: 201,
                    ..Default::default()
                },
                CaptureCoverage::NotConnected
            )
            .is_err()
        );
        assert!(
            project(
                b"[]",
                Source::LocalDocument,
                Query {
                    since: Some("invalid".into()),
                    ..Default::default()
                },
                CaptureCoverage::NotConnected
            )
            .is_err()
        );
        let output = report(json!([]));
        assert_eq!(output.matched_records, 0);
        assert_eq!(output.totals.input.reported_sum, None);
    }
}
