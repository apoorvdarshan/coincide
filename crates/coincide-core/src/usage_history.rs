//! Read-only history projection. Provider snapshots are never summed as billed usage.
use crate::organization::Records;
use anyhow::Result;
use chrono::{DateTime, FixedOffset};
use serde_json::Value;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TurnTotals {
    pub input: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub output: u64,
    pub contributing_turns: usize,
}
impl TurnTotals {
    pub fn total(&self) -> u64 {
        self.input
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_write)
            .saturating_add(self.output)
    }
}
#[derive(Default)]
pub struct HistoryFilter<'a> {
    pub since: Option<DateTime<FixedOffset>>,
    pub provider: Option<&'a str>,
    pub project_id: Option<&'a str>,
    pub account_id: Option<&'a str>,
}
pub struct UsageHistory {
    source: Records,
}
impl UsageHistory {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        Ok(Self {
            source: Records::parse(bytes)?,
        })
    }
    pub fn original(&self) -> &[u8] {
        self.source.original()
    }
    /// Invalid/missing dates are excluded when a date filter is requested.
    pub fn filtered(&self, filter: &HistoryFilter<'_>) -> Vec<&Value> {
        self.source
            .records()
            .iter()
            .filter(|r| {
                filter
                    .provider
                    .is_none_or(|v| r["provider"].as_str() == Some(v))
                    && filter.project_id.is_none_or(|v| {
                        r["projectID"]
                            .as_str()
                            .is_some_and(|s| s.eq_ignore_ascii_case(v))
                    })
                    && filter
                        .account_id
                        .is_none_or(|v| r["accountID"].as_str() == Some(v))
                    && filter.since.is_none_or(|since| {
                        r["finishedAt"]
                            .as_str()
                            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                            .is_some_and(|date| date >= since)
                    })
            })
            .collect()
    }
    pub fn turn_totals(&self, filter: &HistoryFilter<'_>) -> TurnTotals {
        let mut totals = TurnTotals::default();
        for record in self.filtered(filter) {
            let Some(turn) = record["usage"]["turnTotals"].as_object() else {
                continue;
            };
            let count = |key: &str| turn.get(key).and_then(Value::as_u64).unwrap_or(0);
            totals.input = totals.input.saturating_add(count("input"));
            totals.cache_read = totals.cache_read.saturating_add(count("cacheRead"));
            totals.cache_write = totals.cache_write.saturating_add(count("cacheWrite"));
            totals.output = totals.output.saturating_add(count("output"));
            totals.contributing_turns += 1;
        }
        totals
    }
}

/// Merge captured limit windows by stable ID, retaining omitted reset/duration
/// and unknown fields. No fetching, billing inference, or account selection.
pub fn merge_limit_windows(existing: &[Value], updates: &[Value]) -> Result<Vec<Value>> {
    anyhow::ensure!(
        existing.len() <= 1000 && updates.len() <= 1000,
        "too many windows"
    );
    let mut result = Vec::<Value>::new();
    for window in existing.iter().chain(updates) {
        let object = window
            .as_object()
            .ok_or_else(|| anyhow::anyhow!("window must be an object"))?;
        let id = object
            .get("id")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow::anyhow!("missing window id"))?;
        if let Some(old) = result.iter_mut().find(|w| w["id"].as_str() == Some(id)) {
            let target = old.as_object_mut().expect("validated object");
            for (key, value) in object {
                if (key == "resetsAt" || key == "durationMinutes") && value.is_null() {
                    continue;
                }
                target.insert(key.clone(), value.clone());
            }
        } else {
            result.push(window.clone());
        }
    }
    Ok(result)
}
