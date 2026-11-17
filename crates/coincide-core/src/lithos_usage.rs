//! Opt-in, read-only Lithos console account usage. The console API is not a
//! public inference-key API; the browser account may differ from the agent key.
use crate::usage_limits::{Figure, Limits, Unit};
use chrono::{Duration, Local, NaiveDate, Utc};
use serde_json::Value;
use std::{io::Read, sync::mpsc::Receiver, time::Duration as Timeout};
use zeroize::Zeroizing;

const MAX_RESPONSE: u64 = 2 * 1024 * 1024;
const BASE: &str = "https://console.lithosai.cloud";

fn csrf(cookie: &str) -> Option<Option<&str>> {
    let mut session = false;
    let mut csrf = None;
    for item in cookie.split(';') {
        let (name, value) = item.trim().split_once('=')?;
        if value.is_empty()
            || value.len() > 4096
            || value.chars().any(|c| c.is_control() || c.is_whitespace())
        {
            return None;
        }
        match name {
            "__Host-console_session" if !session => session = true,
            "__Host-console_csrf" if csrf.is_none() => csrf = Some(value),
            _ => return None,
        }
    }
    session.then_some(csrf).filter(|_| cookie.len() <= 8192)
}

fn org(me: &Value) -> Option<&str> {
    me["activeOrganization"]["id"].as_str().filter(|id| {
        !id.is_empty()
            && id.len() <= 128
            && id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    })
}

fn read_json(
    path: &str,
    cookie: &str,
    csrf: Option<&str>,
    org: Option<&str>,
) -> Result<Value, &'static str> {
    let agent = ureq::Agent::config_builder()
        .proxy(None)
        .max_redirects(0)
        .http_status_as_error(false)
        .timeout_global(Some(Timeout::from_secs(10)))
        .build()
        .new_agent();
    let mut request = ureq::http::Request::builder()
        .method("GET")
        .uri(format!("{BASE}{path}"))
        .header("Cookie", cookie)
        .header("Accept", "application/json");
    if let Some(csrf) = csrf {
        request = request.header("X-Console-Csrf", csrf);
    }
    if let Some(org) = org {
        request = request.header("X-Organization-Id", org);
    }
    let mut response = agent
        .run(
            request
                .body("")
                .map_err(|_| "Lithos usage check could not start.")?,
        )
        .map_err(|_| "Lithos usage check failed or timed out.")?;
    if !response.status().is_success() {
        return Err("Lithos console sign-in could not read account usage.");
    }
    let mut body = Zeroizing::new(Vec::new());
    response
        .body_mut()
        .as_reader()
        .take(MAX_RESPONSE + 1)
        .read_to_end(&mut body)
        .map_err(|_| "Lithos usage response could not be read.")?;
    if body.len() as u64 > MAX_RESPONSE {
        return Err("Lithos usage response was too large.");
    }
    serde_json::from_slice(&body).map_err(|_| "Lithos usage response was not recognized.")
}

fn balance(billing: &Value) -> Result<Figure, &'static str> {
    let balance = billing["balanceNanos"]
        .as_i64()
        .ok_or("Lithos did not report a balance.")?;
    let mut figure = Figure::new(
        "lithos-balance",
        "Console balance",
        Unit::Currency("USD".into()),
    );
    figure.remaining = Some(balance as f64 / 1_000_000_000.);
    Ok(figure)
}

fn spend_figures(
    spend: &Value,
    start: NaiveDate,
    end: NaiveDate,
) -> Result<Vec<Figure>, &'static str> {
    let range_start = spend["start"]
        .as_str()
        .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok());
    let range_end = spend["end"]
        .as_str()
        .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok());
    if range_start != Some(start) || range_end != Some(end) {
        return Err("Lithos returned a different usage period.");
    }
    let days = spend["days"]
        .as_array()
        .filter(|days| days.len() <= 10000)
        .ok_or("Lithos spend data was not recognized.")?;
    let mut sums = [(0_u64, 0_u64); 3];
    for row in days {
        let day = row["day"]
            .as_str()
            .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
            .filter(|day| *day >= start && *day <= end)
            .ok_or("Lithos spend dates were not recognized.")?;
        let money = row["nanos"]
            .as_u64()
            .ok_or("Lithos spend amount was not recognized.")?;
        let input = row["inputTokens"]
            .as_u64()
            .ok_or("Lithos input tokens were not recognized.")?;
        let cached = row["cachedTokens"]
            .as_u64()
            .ok_or("Lithos cached tokens were not recognized.")?;
        let output = row["outputTokens"]
            .as_u64()
            .ok_or("Lithos output tokens were not recognized.")?;
        let tokens = input
            .checked_add(cached)
            .and_then(|n| n.checked_add(output))
            .ok_or("Lithos token totals were too large.")?;
        for (index, since) in [end, end - Duration::days(6), start]
            .into_iter()
            .enumerate()
        {
            if day >= since {
                sums[index].0 = sums[index]
                    .0
                    .checked_add(money)
                    .ok_or("Lithos spend was too large.")?;
                sums[index].1 = sums[index]
                    .1
                    .checked_add(tokens)
                    .ok_or("Lithos token totals were too large.")?;
            }
        }
    }
    let mut figures = Vec::new();
    for (index, label) in ["Today", "Last 7 days", "Last 30 days"]
        .into_iter()
        .enumerate()
    {
        let mut money = Figure::new(
            &format!("lithos-spend-{index}"),
            &format!("{label} spend"),
            Unit::Currency("USD".into()),
        );
        money.used = Some(sums[index].0 as f64 / 1_000_000_000.);
        let mut tokens = Figure::new(
            &format!("lithos-tokens-{index}"),
            &format!("{label} tokens"),
            Unit::Tokens,
        );
        tokens.used = Some(sums[index].1 as f64);
        figures.extend([money, tokens]);
    }
    Ok(figures)
}

fn figures(
    billing: Result<Value, &'static str>,
    spend: Result<Value, &'static str>,
    start: NaiveDate,
    end: NaiveDate,
) -> Result<Limits, &'static str> {
    let mut limits = Limits::new(Vec::new(), Utc::now());
    let balance = billing.and_then(|value| balance(&value));
    let spend = spend.and_then(|value| spend_figures(&value, start, end));
    if let Ok(value) = &balance {
        limits.figures.push(value.clone());
    }
    if let Ok(value) = &spend {
        limits.figures.extend(value.clone());
    }
    if limits.figures.is_empty() {
        return Err(balance
            .err()
            .or_else(|| spend.err())
            .unwrap_or("Lithos did not report usage."));
    }
    if balance.is_err() {
        limits
            .notes
            .push("Lithos console balance could not be read.".into());
    }
    if spend.is_err() {
        limits
            .notes
            .push("Lithos console spend could not be read.".into());
    }
    limits.notes.push("Lithos console active organization; it may differ from the agent's inference key. Console figures are provider-reported and are separate from tracked local tokens.".into());
    Ok(limits)
}

pub(crate) fn read(
    receiver: Option<Receiver<Option<Zeroizing<String>>>>,
) -> Result<Limits, &'static str> {
    let cookie = receiver
        .and_then(|r| r.recv_timeout(Timeout::from_secs(4)).ok())
        .flatten()
        .ok_or(
            "Sign in to the Lithos console in Coincide's default browser profile to see its usage.",
        )?;
    let csrf = csrf(&cookie).ok_or("Lithos console sign-in is incomplete.")?;
    let me = read_json("/api/me", &cookie, csrf, None)?;
    let org = org(&me).ok_or("Lithos console did not identify an active organization.")?;
    let end = Local::now().date_naive();
    let start = end - Duration::days(29);
    let billing = read_json("/api/billing", &cookie, csrf, Some(org));
    let spend = read_json(
        &format!("/api/billing/spend?start={start}&end={end}"),
        &cookie,
        csrf,
        Some(org),
    );
    let again = read_json("/api/me", &cookie, csrf, None)?;
    if self::org(&again) != Some(org) {
        return Err("Lithos console organization changed. Refresh to try again.");
    }
    figures(billing, spend, start, end)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn browser_session_requires_exact_cookie_pair_and_safe_org() {
        assert_eq!(
            csrf("__Host-console_session=a; __Host-console_csrf=b"),
            Some(Some("b"))
        );
        assert_eq!(csrf("__Host-console_session=a"), Some(None));
        assert!(csrf("__Host-console_session=a; other=b").is_none());
        assert!(
            csrf("__Host-console_session=a; __Host-console_csrf=b; __Host-console_csrf=c")
                .is_none()
        );
        assert!(org(&json!({"activeOrganization":{"id":"org\r\nX: y"}})).is_none());
    }
    #[test]
    fn provider_report_preserves_balance_and_aggregates_exact_periods() {
        let start = NaiveDate::from_ymd_opt(2026, 10, 19).unwrap();
        let end = NaiveDate::from_ymd_opt(2026, 11, 17).unwrap();
        let report = json!({"start":"2026-10-19","end":"2026-11-17","days":[
            {"day":"2026-11-17","nanos":1_000_000_000_u64,"inputTokens":5,"cachedTokens":3,"outputTokens":2},
            {"day":"2026-11-12","nanos":500_000_000_u64,"inputTokens":20,"cachedTokens":0,"outputTokens":1},
            {"day":"2026-10-25","nanos":250_000_000_u64,"inputTokens":7,"cachedTokens":0,"outputTokens":0}]});
        let result = figures(
            Ok(json!({"balanceNanos":2_500_000_000_i64})),
            Ok(report),
            start,
            end,
        )
        .unwrap();
        assert_eq!(result.figures[0].remaining, Some(2.5));
        assert_eq!(result.figures[1].used, Some(1.0));
        assert_eq!(result.figures[4].used, Some(31.0));
        assert_eq!(result.figures[5].used, Some(1.75));
        assert_eq!(result.figures[6].used, Some(38.0));
        let partial = figures(
            Ok(json!({"balanceNanos":1})),
            Ok(json!({"days":[]})),
            start,
            end,
        )
        .unwrap();
        assert_eq!(partial.figures.len(), 1);
        assert!(
            partial
                .notes
                .iter()
                .any(|note| note.contains("spend could not"))
        );
        assert!(
            figures(
                Err("balance unavailable"),
                Err("spend unavailable"),
                start,
                end
            )
            .is_err()
        );
    }
}
