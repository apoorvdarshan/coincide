//! Explicit native Anthropic reporting. Fixed official HTTPS GETs, no inference.
//! Contract: platform.claude.com/docs/en/manage-claude/usage-cost-api (Swift parity).
use super::*;
use chrono::{Datelike, Utc};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;
#[derive(Debug)]
struct Refused(u16);
impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self.0 {
            401 => "Anthropic did not accept the Admin key",
            403 => "This key may not read Anthropic organization reports",
            _ => "Anthropic reporting request was refused",
        })
    }
}
impl std::error::Error for Refused {}
fn privilege_failure(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<Refused>()
        .is_some_and(|error| matches!(error.0, 401 | 403))
}

#[derive(Clone, Default)]
pub struct NativeAdminTokens {
    pub input: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
    pub output: u64,
}
impl NativeAdminTokens {
    pub fn total(&self) -> u64 {
        self.input
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_creation)
            .saturating_add(self.output)
    }
    fn add(&mut self, row: &Value) {
        self.input = self
            .input
            .saturating_add(row["uncached_input_tokens"].as_u64().unwrap_or(0));
        self.cache_read = self
            .cache_read
            .saturating_add(row["cache_read_input_tokens"].as_u64().unwrap_or(0));
        self.cache_creation = self
            .cache_creation
            .saturating_add(
                row["cache_creation"]["ephemeral_5m_input_tokens"]
                    .as_u64()
                    .unwrap_or(0),
            )
            .saturating_add(
                row["cache_creation"]["ephemeral_1h_input_tokens"]
                    .as_u64()
                    .unwrap_or(0),
            );
        self.output = self
            .output
            .saturating_add(row["output_tokens"].as_u64().unwrap_or(0));
    }
}
#[derive(Clone)]
pub struct NativeAdminModel {
    pub name: String,
    pub tokens: NativeAdminTokens,
    pub organization_cost_usd: Option<f64>,
}
#[derive(Clone)]
pub struct NativeAdminUsageReport {
    /// None means organization-wide tokens; costs are always organization-wide.
    pub token_key_name: Option<String>,
    pub today: NativeAdminTokens,
    pub month: NativeAdminTokens,
    pub cost_today_usd: Option<f64>,
    pub cost_month_usd: Option<f64>,
    pub checked_at: String,
    pub models: Vec<NativeAdminModel>,
}
pub struct NativeAdminUsage {
    source: Value,
    account: Account,
    admin: Zeroizing<Vec<u8>>,
    api: Option<Zeroizing<Vec<u8>>>,
    now: chrono::DateTime<Utc>,
}
impl Engine {
    /// Explicit native account action only. Not exposed through agent JSON APIs.
    pub fn prepare_native_account_admin_usage(
        &self,
        provider: &str,
        id: &str,
        revision: &str,
    ) -> Result<NativeAdminUsage> {
        self.require_admissions()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let payload = read(
            &owner,
            provider,
            self.store.native_accounts_payload(provider)?.as_deref(),
        )?;
        let account = account(&payload, provider, id)?;
        ensure!(
            super::eligible(&account) && account.revision == revision,
            "Anthropic API account changed; reload before reading usage"
        );
        let slot = account
            .admin_key
            .as_ref()
            .context("Save an Admin key before reading organization reports")?;
        let secrets = account_secret_store::NativeSecretStore::from_owner(&owner)?;
        let admin = secrets.read(slot)?;
        let api = account
            .key
            .as_ref()
            .map(|slot| secrets.read(slot))
            .transpose()?;
        Ok(NativeAdminUsage {
            source: owner.source.clone(),
            account,
            admin,
            api,
            now: Utc::now(),
        })
    }
}
impl NativeAdminUsage {
    fn validate(&self) -> Result<()> {
        let path = PathBuf::from(
            self.source["path"]
                .as_str()
                .context("Report source missing")?,
        );
        let owner = Private::open_path(&path, false)?.context("Report authority missing")?;
        ensure!(owner.source == self.source, "Report source changed");
        let held = setup_source::Source::open(&path)?;
        ensure!(
            serde_json::to_value(crate::private_fs::file_identity(&held.file)?)?
                == self.source["identity"],
            "Report source changed"
        );
        let db = rusqlite::Connection::open_with_flags(
            &path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        held.verify(&path, &db)?;
        let raw: Option<String> = db
            .query_row(
                "SELECT value FROM metadata WHERE key=?1",
                [format!(
                    "native-login-accounts-v1/{}",
                    self.account.provider
                )],
                |row| row.get(0),
            )
            .optional()?;
        held.verify(&path, &db)?;
        let payload = read(&owner, &self.account.provider, raw.as_deref())?;
        let current = account(&payload, &self.account.provider, &self.account.id)?;
        ensure!(
            serde_json::to_value(current)? == serde_json::to_value(&self.account)?,
            "Reporting account changed; refresh explicitly"
        );
        Ok(())
    }
    pub fn run(self, allowed: impl Fn() -> bool) -> Result<NativeAdminUsageReport> {
        self.validate()?;
        let agent = ureq::Agent::config_builder()
            .proxy(None)
            .max_redirects(0)
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(3)))
            .build()
            .new_agent();
        let key = std::str::from_utf8(&self.admin).context("Invalid Admin key encoding")?;
        ensure!(
            !key.is_empty() && !key.chars().any(char::is_control),
            "Invalid Admin key"
        );
        let deadline = Instant::now() + Duration::from_secs(30);
        let reporting_allowed = || allowed() && Instant::now() < deadline;
        let result = read_report(
            self.api
                .as_deref()
                .and_then(|value| std::str::from_utf8(value).ok()),
            self.now,
            &reporting_allowed,
            |path, query| {
                ensure!(
                    allowed() && Instant::now() < deadline,
                    "Report cancelled or timed out"
                );
                self.validate()?;
                let mut url =
                    url::Url::parse("https://api.anthropic.com/v1/organizations/")?.join(path)?;
                url.query_pairs_mut()
                    .extend_pairs(query.iter().map(|(key, value)| (*key, value.as_str())));
                let request = ureq::http::Request::builder()
                    .method("GET")
                    .uri(url.as_str())
                    .header("x-api-key", key)
                    .header("anthropic-version", "2023-06-01")
                    .header("Accept", "application/json")
                    .body(String::new())?;
                let remaining = deadline
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_secs(5));
                ensure!(!remaining.is_zero(), "Report timed out");
                let request = agent
                    .configure_request(request)
                    .timeout_global(Some(remaining))
                    .build();
                let mut response = agent.run(request).map_err(|_| {
                    anyhow::anyhow!("Anthropic reporting request failed or timed out")
                })?;
                let status = response.status().as_u16();
                if !(200..300).contains(&status) {
                    return Err(Refused(status).into());
                }
                let mut bytes = Zeroizing::new(Vec::new());
                let mut reader = response.body_mut().as_reader();
                let mut chunk = [0u8; 8192];
                loop {
                    ensure!(
                        allowed() && Instant::now() < deadline,
                        "Report cancelled or timed out"
                    );
                    let size = reader
                        .read(&mut chunk)
                        .map_err(|_| anyhow::anyhow!("Anthropic report body failed"))?;
                    if size == 0 {
                        break;
                    }
                    ensure!(
                        bytes.len() + size <= 2 * 1024 * 1024,
                        "Anthropic report exceeds its bound"
                    );
                    bytes.extend_from_slice(&chunk[..size]);
                }
                serde_json::from_slice(&bytes)
                    .map_err(|_| anyhow::anyhow!("Anthropic report has invalid JSON"))
            },
        );
        let report = result?;
        ensure!(reporting_allowed(), "Report cancelled or timed out");
        self.validate()?;
        Ok(report)
    }
}
fn pages(
    path: &'static str,
    base: &[(&'static str, String)],
    allowed: &impl Fn() -> bool,
    get: &mut impl FnMut(&'static str, &[(&'static str, String)]) -> Result<Value>,
) -> Result<Vec<Value>> {
    let mut result = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut cursor: Option<String> = None;
    for _ in 0..10 {
        ensure!(allowed(), "Report cancelled");
        let mut query = base.to_vec();
        if let Some(cursor) = &cursor {
            query.push((
                if path == "api_keys" {
                    "after_id"
                } else {
                    "page"
                },
                cursor.clone(),
            ));
        }
        let body = get(path, &query)?;
        let rows = body["data"]
            .as_array()
            .context("Anthropic report rows missing")?;
        ensure!(
            rows.len() <= 1000 && result.len() + rows.len() <= 10_000,
            "Anthropic report rows exceed their bound"
        );
        result.extend(rows.iter().cloned());
        if body["has_more"].as_bool() != Some(true) {
            return Ok(result);
        }
        let next = body[if path == "api_keys" {
            "last_id"
        } else {
            "next_page"
        }]
        .as_str()
        .context("Anthropic report cursor missing")?;
        ensure!(
            !next.is_empty() && next.len() <= 1024 && seen.insert(next.to_owned()),
            "Anthropic report cursor repeated or invalid"
        );
        cursor = Some(next.to_owned());
    }
    anyhow::bail!("Anthropic report exceeds ten pages; no partial totals displayed")
}
fn read_report(
    api: Option<&str>,
    now: chrono::DateTime<Utc>,
    allowed: &impl Fn() -> bool,
    mut get: impl FnMut(&'static str, &[(&'static str, String)]) -> Result<Value>,
) -> Result<NativeAdminUsageReport> {
    let mut key_match = None;
    if let Some(api) = api {
        let rows = match pages(
            "api_keys",
            &[("limit", "1000".into()), ("status", "active".into())],
            allowed,
            &mut get,
        ) {
            Ok(rows) => rows,
            Err(error) if !privilege_failure(&error) && allowed() => Vec::new(),
            Err(error) => return Err(error),
        };
        let matches = rows
            .iter()
            .filter_map(|row| {
                let (head, tail) = row["partial_key_hint"].as_str()?.split_once("...")?;
                (head.len() >= 8
                    && tail.len() >= 2
                    && api.len() > head.len() + tail.len()
                    && api.starts_with(head)
                    && api.ends_with(tail))
                .then(|| {
                    (
                        row["id"].as_str().map(str::to_owned),
                        row["name"].as_str().map(str::to_owned),
                    )
                })
            })
            .filter_map(|(id, name)| id.map(|id| (id, name)))
            .collect::<Vec<_>>();
        if matches.len() == 1 {
            key_match = matches.into_iter().next();
        }
    }
    let start = now
        .date_naive()
        .with_day(1)
        .context("UTC month missing")?
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc();
    let mut query = vec![
        ("starting_at", start.to_rfc3339()),
        ("bucket_width", "1d".into()),
        ("limit", "31".into()),
        ("group_by[]", "model".into()),
    ];
    if let Some((id, _)) = &key_match {
        query.push(("api_key_ids[]", id.clone()));
    }
    let usage = pages("usage_report/messages", &query, allowed, &mut get)?;
    let costs = match pages(
        "cost_report",
        &[
            ("starting_at", start.to_rfc3339()),
            ("bucket_width", "1d".into()),
            ("limit", "31".into()),
            ("group_by[]", "description".into()),
        ],
        allowed,
        &mut get,
    ) {
        Ok(rows) => Some(rows),
        Err(error) if !privilege_failure(&error) && allowed() => None,
        Err(error) => return Err(error),
    };
    let mut report = NativeAdminUsageReport {
        token_key_name: key_match.map(|(id, name)| name.unwrap_or(id)),
        today: NativeAdminTokens::default(),
        month: NativeAdminTokens::default(),
        cost_today_usd: costs.as_ref().map(|_| 0.),
        cost_month_usd: costs.as_ref().map(|_| 0.),
        checked_at: now.to_rfc3339(),
        models: Vec::new(),
    };
    let mut models: BTreeMap<String, NativeAdminModel> = BTreeMap::new();
    for bucket in usage {
        let day = chrono::DateTime::parse_from_rfc3339(
            bucket["starting_at"]
                .as_str()
                .context("Usage bucket date missing")?,
        )?
        .with_timezone(&Utc);
        if day < start || day > now {
            continue;
        }
        for row in bucket["results"]
            .as_array()
            .context("Usage bucket rows missing")?
        {
            report.month.add(row);
            if let Some(name) = row["model"]
                .as_str()
                .filter(|name| !name.is_empty() && name.len() <= 256)
            {
                models
                    .entry(name.into())
                    .or_insert_with(|| NativeAdminModel {
                        name: name.into(),
                        tokens: NativeAdminTokens::default(),
                        organization_cost_usd: None,
                    })
                    .tokens
                    .add(row);
            }
            if day.date_naive() == now.date_naive() {
                report.today.add(row);
            }
        }
    }
    for bucket in costs.into_iter().flatten() {
        let day = chrono::DateTime::parse_from_rfc3339(
            bucket["starting_at"]
                .as_str()
                .context("Cost bucket date missing")?,
        )?
        .with_timezone(&Utc);
        if day < start || day > now {
            continue;
        }
        for row in bucket["results"]
            .as_array()
            .context("Cost bucket rows missing")?
        {
            ensure!(
                row["currency"].as_str().unwrap_or("USD") == "USD",
                "Unsupported reporting currency"
            );
            let cents = row["amount"]
                .as_str()
                .and_then(|value| value.parse::<f64>().ok())
                .or_else(|| row["amount"].as_f64())
                .context("Invalid reported amount")?;
            ensure!(cents.is_finite(), "Invalid reported amount");
            let month = report.cost_month_usd.unwrap() + cents / 100.;
            ensure!(month.is_finite(), "Reported cost exceeds its bound");
            report.cost_month_usd = Some(month);
            if let Some(name) = row["model"]
                .as_str()
                .filter(|name| !name.is_empty() && name.len() <= 256)
            {
                let model = models
                    .entry(name.into())
                    .or_insert_with(|| NativeAdminModel {
                        name: name.into(),
                        tokens: NativeAdminTokens::default(),
                        organization_cost_usd: None,
                    });
                let sum = model.organization_cost_usd.unwrap_or(0.) + cents / 100.;
                ensure!(sum.is_finite(), "Reported model cost exceeds its bound");
                model.organization_cost_usd = Some(sum);
            }
            if day.date_naive() == now.date_naive() {
                report.cost_today_usd = Some(report.cost_today_usd.unwrap() + cents / 100.);
            }
        }
    }
    report.models = models.into_values().collect();
    report.models.sort_by(|a, b| {
        b.tokens
            .total()
            .cmp(&a.tokens.total())
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn now() -> chrono::DateTime<Utc> {
        chrono::DateTime::parse_from_rfc3339("2026-11-07T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }
    #[test]
    fn matched_key_tokens_and_organization_costs_keep_distinct_scope() {
        let report = read_report(Some("synthetic-prefix-secret-zz"), now(), &|| true, |path, query| {
            assert!(!query.iter().any(|(_, value)| value.contains("secret")));
            match path {
                "api_keys" => Ok(json!({"data":[{"id":"owned-key-id","name":"Synthetic named key","partial_key_hint":"synthetic-prefix...zz"}],"has_more":false})),
                "usage_report/messages" => {
                    assert!(query.contains(&("api_key_ids[]", "owned-key-id".into())));
                    Ok(json!({"data":[{"starting_at":"2026-11-07T00:00:00Z","results":[{"uncached_input_tokens":12,"output_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":2}}]},{"starting_at":"2026-11-06T00:00:00Z","results":[{"output_tokens":8}]}],"has_more":false}))
                }
                "cost_report" => {
                    assert!(!query.iter().any(|(key, _)| *key == "api_key_ids[]"));
                    Ok(json!({"data":[{"starting_at":"2026-11-07T00:00:00Z","results":[{"currency":"USD","amount":"125"}]},{"starting_at":"2026-11-06T00:00:00Z","results":[{"currency":"USD","amount":"250"}]}],"has_more":false}))
                }
                _ => panic!("Unexpected reporting endpoint"),
            }
        }).unwrap();
        assert_eq!(
            report.token_key_name.as_deref(),
            Some("Synthetic named key")
        );
        assert_eq!(report.today.total(), 17);
        assert_eq!(report.month.total(), 25);
        assert_eq!(report.cost_today_usd, Some(1.25));
        assert_eq!(report.cost_month_usd, Some(3.75));
    }
    #[test]
    fn unavailable_cost_stays_unknown_but_permission_errors_never_become_totals() {
        let report = read_report(None, now(), &|| true, |path, _| {
            if path == "cost_report" {
                anyhow::bail!("Synthetic unavailable report");
            }
            Ok(json!({"data":[], "has_more":false}))
        })
        .unwrap();
        assert!(report.cost_today_usd.is_none() && report.cost_month_usd.is_none());
        for status in [401, 403] {
            assert!(
                read_report(None, now(), &|| true, |path, _| {
                    if path == "cost_report" {
                        return Err(Refused(status).into());
                    }
                    Ok(json!({"data":[], "has_more":false}))
                })
                .is_err()
            );
        }
    }
    #[test]
    fn ambiguous_keys_do_not_narrow_and_repeated_pages_never_display_partial_totals() {
        let mut usage_calls = 0;
        let result = read_report(
            Some("synthetic-prefix-secret-zz"),
            now(),
            &|| true,
            |path, query| {
                if path == "api_keys" {
                    return Ok(
                        json!({"data":[{"id":"a","partial_key_hint":"synthetic-prefix...zz"},{"id":"b","partial_key_hint":"synthetic-prefix...zz"}]}),
                    );
                }
                assert_eq!(path, "usage_report/messages");
                assert!(!query.iter().any(|(key, _)| *key == "api_key_ids[]"));
                usage_calls += 1;
                Ok(json!({"data":[],"has_more":true,"next_page":"repeat"}))
            },
        );
        assert!(result.is_err());
        assert_eq!(usage_calls, 2);
        let mut requested = false;
        assert!(
            read_report(None, now(), &|| false, |_, _| {
                requested = true;
                Ok(json!({}))
            })
            .is_err()
        );
        assert!(!requested);
    }
}
