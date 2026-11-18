//! Settings › Usage's state, after Swift's `UsageDashboardModel`: the saved
//! turns and account rows it reads in the background, the filters, and each
//! account's limits. Limits are read only when the user refreshes; opening the
//! page reads saved local history alone.
use crate::codex_limits_view::{Bucket, Phase as CodexPhase, ResetCredits};
use chrono::{DateTime, Local, NaiveDate, Utc};
use coincide_core::{
    api::SharedEngine,
    cli_session_import::ImportProvider,
    cli_usage_logs::{Scan as CliScan, Source as CliSource},
    usage_limits::{Credits, Figure, Limits, Unit, Window, WindowKind},
    usage_report::{self, DEFAULT_ACCOUNT, PROVIDERS, Report, TurnRecord, turn_records},
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

pub(crate) const USAGE_BUSY: &str = "The app is busy. Refresh to try again.";

/// One provider account as Usage lists it.
#[derive(Clone, Debug, PartialEq)]
pub struct Account {
    pub provider: &'static str,
    pub id: String,
    pub name: String,
    pub api_key: bool,
    pub key_variable: Option<String>,
}

/// Configured ACP agents can report additive turns even when they have no
/// standard account-limit endpoint. Registry websites are optional.
#[derive(Clone, Debug, PartialEq)]
pub struct RegisteredAgent {
    pub provider: String,
    pub name: String,
    pub website: Option<String>,
}
impl Account {
    pub fn is_default(&self) -> bool {
        self.id == DEFAULT_ACCOUNT
    }
    /// An Anthropic API key, whose card lists Coincide's own turns with it.
    pub fn shows_tracked(&self) -> bool {
        self.provider == "claude"
            && !self.is_default()
            && self.api_key
            && self.key_variable.as_deref() == Some("ANTHROPIC_API_KEY")
    }
}

/// What one background read found.
#[derive(Clone, Debug)]
pub struct Data {
    pub records: Vec<TurnRecord>,
    /// Saved turns without a known provider or finish time.
    pub skipped: usize,
    pub accounts: Vec<Account>,
    pub registered: Vec<RegisteredAgent>,
    pub registered_unavailable: bool,
    pub read_at: DateTime<Utc>,
    pub logs: Option<Arc<CliScan>>,
    pub(crate) report_cache: Arc<Mutex<ReportCache>>,
}

#[derive(Debug, PartialEq, Eq)]
struct ReportKey {
    includes_other_sessions: bool,
    enabled: Vec<String>,
    provider: Option<String>,
    account: Option<String>,
    days: u32,
    minute: i64,
    local_offset: i32,
}

#[derive(Debug, PartialEq, Eq)]
struct PartialKey {
    enabled: Vec<String>,
    provider: Option<String>,
    account: Option<String>,
    days: u32,
    minute: i64,
    local_offset: i32,
}

#[derive(Debug, Default)]
pub(crate) struct ReportCache {
    reports: VecDeque<(ReportKey, Arc<Report>)>,
    partial: VecDeque<(PartialKey, bool)>,
    history_days: Option<(i64, u32)>,
}

impl Data {
    /// The full available history need not be rendered as thousands of chart
    /// columns. The caller can chart a shorter range while summing every day.
    pub fn history_days(&self, now: DateTime<Utc>) -> u32 {
        let minute = now.timestamp().div_euclid(60);
        if let Ok(cache) = self.report_cache.lock()
            && let Some((when, days)) = cache.history_days
            && when == minute
        {
            return days;
        }
        let oldest = self
            .records
            .iter()
            .map(|row| row.finished_at)
            .chain(
                self.logs
                    .iter()
                    .flat_map(|scan| scan.events.iter().map(|row| row.event.date)),
            )
            .filter(|date| *date <= now + chrono::Duration::seconds(60))
            .min();
        let days = oldest
            .map(|date| {
                let today = now.with_timezone(&Local).date_naive();
                let first = date.with_timezone(&Local).date_naive();
                (today - first)
                    .num_days()
                    .saturating_add(1)
                    .clamp(1, i64::from(u32::MAX)) as u32
            })
            .unwrap_or(1);
        if let Ok(mut cache) = self.report_cache.lock() {
            cache.history_days = Some((minute, days));
        }
        days
    }

    /// Missing turn totals or an unfinished/partial local scan mean that a
    /// zero cannot be presented as proof that no tokens were used.
    pub fn history_partial(
        &self,
        enabled: &[&str],
        provider: Option<&str>,
        account: Option<&str>,
        days: u32,
        now: DateTime<Utc>,
    ) -> bool {
        let Some(logs) = &self.logs else { return true };
        let key = PartialKey {
            enabled: enabled.iter().map(|value| (*value).to_owned()).collect(),
            provider: provider.map(str::to_owned),
            account: account.map(str::to_owned),
            days,
            minute: now.timestamp().div_euclid(60),
            local_offset: now.with_timezone(&Local).offset().local_minus_utc(),
        };
        if let Ok(cache) = self.report_cache.lock()
            && let Some((_, partial)) = cache.partial.iter().find(|(cached, _)| *cached == key)
        {
            return *partial;
        }
        let in_scope = |name: &str| enabled.contains(&name) && provider.is_none_or(|p| p == name);
        let since = usage_report::days_back(now.with_timezone(&Local).date_naive(), days);
        let covered = logs
            .events
            .iter()
            .filter(|event| event.is_from_coincide)
            .map(|event| {
                (
                    event.event.provider.as_str(),
                    event.event.account_id.as_str(),
                    event.event.date.with_timezone(&Local).date_naive(),
                )
            })
            .collect::<std::collections::HashSet<_>>();
        let partial = (self.registered_unavailable && provider.is_none())
            || logs.incomplete_providers.iter().any(|name| in_scope(name))
            || self.records.iter().any(|record| {
                in_scope(&record.provider)
                    && account.is_none_or(|id| record.account_id == id)
                    && record.finished_at <= now + chrono::Duration::seconds(60)
                    && record.finished_at.with_timezone(&Local).date_naive() >= since
                    && record.turn_totals.is_none()
                    && !(logs.complete_providers.contains(&record.provider.as_str())
                        && covered.contains(&(
                            record.provider.as_str(),
                            record.account_id.as_str(),
                            record.finished_at.with_timezone(&Local).date_naive(),
                        )))
            });
        if let Ok(mut cache) = self.report_cache.lock() {
            cache.partial.push_back((key, partial));
            while cache.partial.len() > 12 {
                cache.partial.pop_front();
            }
        }
        partial
    }

    pub fn set_logs(&mut self, logs: Option<Arc<CliScan>>) {
        self.logs = logs;
        // Clones may still use the previous scan, so give this Data a new cache.
        self.report_cache = Arc::new(Mutex::new(ReportCache::default()));
    }

    /// Merge saved turns and local logs conservatively by provider/day.
    /// Complete Claude/Codex logs replace overlapping saved days, preserving
    /// older saved days whose logs are gone. OpenCode's supplemental database
    /// instead fills days with no saved totals.
    pub fn events(&self, include_other_sessions: bool) -> Vec<usage_report::Event> {
        let Some(logs) = &self.logs else {
            return usage_report::events(&self.records, &[]);
        };
        let has_own = logs
            .events
            .iter()
            .filter(|logged| logged.is_from_coincide)
            .map(|logged| {
                (
                    logged.event.provider.as_str(),
                    logged.event.account_id.as_str(),
                )
            })
            .collect::<std::collections::HashSet<_>>();
        let logged_days = logs
            .events
            .iter()
            .filter(|logged| {
                logs.complete_providers
                    .contains(&logged.event.provider.as_str())
            })
            .filter(|logged| {
                has_own.contains(&(
                    logged.event.provider.as_str(),
                    logged.event.account_id.as_str(),
                ))
            })
            .filter(|logged| include_other_sessions || logged.is_from_coincide)
            .map(|logged| {
                (
                    logged.event.provider.as_str(),
                    logged.event.account_id.as_str(),
                    logged.event.date.with_timezone(&Local).date_naive(),
                )
            })
            .collect::<std::collections::HashSet<_>>();
        let mut events = usage_report::events(&self.records, &[]);
        events.retain(|event| {
            !logged_days.contains(&(
                event.provider.as_str(),
                event.account_id.as_str(),
                event.date.with_timezone(&Local).date_naive(),
            ))
        });
        let saved_days = self
            .records
            .iter()
            .filter(|record| record.turn_totals.is_some())
            .filter(|record| matches!(record.provider.as_str(), "opencode" | "lithos"))
            .map(|record| {
                (
                    record.provider.as_str(),
                    record.finished_at.with_timezone(&Local).date_naive(),
                )
            })
            .collect::<std::collections::HashSet<_>>();
        events.extend(
            logs.events
                .iter()
                .filter(|logged| {
                    let provider = logged.event.provider.as_str();
                    (logs.complete_providers.contains(&provider)
                        || logs.supplemental_providers.contains(&provider))
                        && (include_other_sessions || logged.is_from_coincide)
                        && (!logs.supplemental_providers.contains(&provider)
                            || !saved_days.contains(&(
                                provider,
                                logged.event.date.with_timezone(&Local).date_naive(),
                            )))
                })
                .map(|logged| logged.event.clone()),
        );
        events
    }

    /// Reports are reused across frames and by the menu bar; rescanning a
    /// large CLI history while the user scrolls would block the UI thread.
    pub fn report(
        &self,
        includes_other_sessions: bool,
        enabled: &[&str],
        provider: Option<&str>,
        account: Option<&str>,
        days: u32,
        now: DateTime<Utc>,
    ) -> Arc<Report> {
        let key = ReportKey {
            includes_other_sessions,
            enabled: enabled.iter().map(|value| (*value).to_owned()).collect(),
            provider: provider.map(str::to_owned),
            account: account.map(str::to_owned),
            days,
            minute: now.timestamp().div_euclid(60),
            local_offset: now.with_timezone(&Local).offset().local_minus_utc(),
        };
        if let Ok(cache) = self.report_cache.lock()
            && let Some((_, report)) = cache.reports.iter().find(|(cached, _)| *cached == key)
        {
            return report.clone();
        }
        let events = self
            .events(includes_other_sessions)
            .into_iter()
            .filter(|event| {
                enabled.contains(&event.provider.as_str())
                    && provider.is_none_or(|value| event.provider == value)
                    && account.is_none_or(|value| event.account_id == value)
            })
            .collect::<Vec<_>>();
        let report = Arc::new(Report::make(&events, days, now, &Local));
        if let Ok(mut cache) = self.report_cache.lock() {
            cache.reports.retain(|(cached, _)| *cached != key);
            cache.reports.push_back((key, report.clone()));
            while cache.reports.len() > 12 {
                cache.reports.pop_front();
            }
        }
        report
    }
}

/// Worker side: holds the engine only to copy saved bytes and account rows.
pub(crate) fn read(engine: &SharedEngine) -> Result<Data, String> {
    let deadline = Instant::now() + Duration::from_secs(3);
    let (bytes, accounts, registered, registered_unavailable, registry) = loop {
        match engine.try_lock() {
            Ok(engine) => {
                if engine.admissions_frozen() {
                    return Err("Usage is closing.".into());
                }
                let (bytes, _) = engine.store.saved_usage_snapshot().map_err(|_| {
                    "Usage history could not be read. Its saved contents have been retained."
                        .to_owned()
                })?;
                let accounts = accounts(&engine);
                let registered = engine.native_acp_agents();
                let registered_unavailable = registered.is_err();
                let registry = engine.native_acp_usage_sites();
                break (
                    bytes,
                    accounts,
                    registered.unwrap_or_default(),
                    registered_unavailable,
                    registry,
                );
            }
            Err(std::sync::TryLockError::WouldBlock) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25))
            }
            Err(_) => return Err(USAGE_BUSY.into()),
        }
    };
    let (records, skipped) = turn_records(&bytes).map_err(|_| {
        "Usage history is invalid. Its saved contents have been retained.".to_owned()
    })?;
    let local = if registered.is_empty() {
        Vec::new()
    } else {
        coincide_core::acp_registry::local_agents()
    };
    let registered = registered
        .into_iter()
        .filter_map(|row| {
            let provider = row["provider"].as_str()?;
            let id = coincide_core::acp_registry::registry_id(provider)?;
            let name = row["displayName"].as_str()?;
            let website = registry
                .iter()
                .find(|(agent_id, _)| agent_id == id)
                .and_then(|(_, website)| website.as_deref())
                .or_else(|| {
                    local
                        .iter()
                        .find(|agent| agent.id == id)
                        .and_then(|agent| agent.website.as_deref())
                })
                .and_then(|site| url::Url::parse(site).ok())
                .filter(|site| {
                    site.scheme() == "https"
                        && site.host_str().is_some()
                        && site.username().is_empty()
                        && site.password().is_none()
                        && site.query().is_none()
                        && site.fragment().is_none()
                })
                .map(|site| site.to_string());
            Some(RegisteredAgent {
                provider: provider.into(),
                name: name.into(),
                website,
            })
        })
        .collect();
    Ok(Data {
        records,
        skipped,
        accounts,
        registered,
        registered_unavailable,
        read_at: Utc::now(),
        logs: None,
        report_cache: Arc::default(),
    })
}

fn log_roots(provider: ImportProvider, home: &Path) -> Vec<PathBuf> {
    match provider {
        ImportProvider::Claude => vec![home.join("projects")],
        ImportProvider::Codex => vec![home.join("sessions"), home.join("archived_sessions")],
    }
}

/// Snapshot only authorized paths and account IDs while holding the Engine;
/// reading the logs and the separate read-only Store happens after release.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct UsageSources {
    pub cli: Vec<CliSource>,
    pub database: PathBuf,
    pub opencode_database: Option<PathBuf>,
}

pub(crate) fn cli_sources(engine: &coincide_core::api::Engine) -> Result<UsageSources, String> {
    let mut sources = Vec::new();
    let default_home = coincide_core::cli_session_discovery::home_directory();
    for (provider, kind, variable, folder) in [
        (
            "claude",
            ImportProvider::Claude,
            "CLAUDE_CONFIG_DIR",
            ".claude",
        ),
        ("codex", ImportProvider::Codex, "CODEX_HOME", ".codex"),
    ] {
        let configuration = engine
            .native_provider_configuration(provider)
            .map_err(|_| "Provider configuration is unavailable.".to_owned())?;
        let configured = configuration
            .approved
            .then(|| configuration.environment.get(variable))
            .flatten()
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from);
        let home = configured
            .or_else(|| {
                std::env::var_os(variable)
                    .filter(|value| !value.is_empty())
                    .map(PathBuf::from)
            })
            .or_else(|| default_home.as_ref().map(|home| home.join(folder)));
        if let Some(home) = home {
            if !home.is_absolute() {
                return Err("A provider log folder is not an absolute path.".into());
            }
            sources.push(CliSource {
                provider: kind,
                account_id: DEFAULT_ACCOUNT.into(),
                roots: log_roots(kind, &home),
            });
        }
        let accounts = engine
            .native_usage_log_homes(provider)
            .map_err(|_| "An account's log folder could not be verified.".to_owned())?;
        for account in accounts {
            sources.push(CliSource {
                provider: kind,
                account_id: account.id,
                roots: log_roots(kind, &account.home),
            });
        }
        if provider == "codex" {
            let legacy = engine
                .native_legacy_codex_accounts()
                .map_err(|_| "Codex accounts could not be read.".to_owned())?;
            for account in legacy {
                if sources
                    .iter()
                    .any(|source| source.provider == kind && source.account_id == account.id)
                {
                    continue;
                }
                let home = engine
                    .native_legacy_codex_usage_home(&account.id)
                    .map_err(|_| {
                        "A Codex account's log folder could not be verified.".to_owned()
                    })?;
                sources.push(CliSource {
                    provider: kind,
                    account_id: account.id,
                    roots: log_roots(kind, &home),
                });
            }
        }
    }
    let database = engine
        .store
        .usage_database_path()
        .map_err(|_| "Usage store is unavailable.".to_owned())?;
    let configuration = engine
        .native_provider_configuration("opencode")
        .map_err(|_| "OpenCode configuration is unavailable.".to_owned())?;
    let variable = |key: &str| {
        configuration
            .approved
            .then(|| configuration.environment.get(key).cloned())
            .flatten()
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os(key)
                    .filter(|value| !value.is_empty())
                    .map(PathBuf::from)
            })
    };
    let data_root = variable("XDG_DATA_HOME")
        .or_else(|| default_home.as_ref().map(|home| home.join(".local/share")));
    if data_root.as_ref().is_some_and(|path| !path.is_absolute()) {
        return Err("The OpenCode data folder is not an absolute path.".into());
    }
    let opencode_database = data_root.and_then(|root| {
        let database = variable("OPENCODE_DB").unwrap_or_else(|| PathBuf::from("opencode.db"));
        if database == Path::new(":memory:") {
            None
        } else if database.is_absolute() {
            Some(database)
        } else {
            Some(root.join("opencode").join(database))
        }
    });
    Ok(UsageSources {
        cli: sources,
        database,
        opencode_database,
    })
}

/// Every provider's default account, then its saved accounts in their order.
fn accounts(engine: &coincide_core::api::Engine) -> Vec<Account> {
    let mut rows = Vec::new();
    for provider in PROVIDERS {
        rows.push(Account {
            provider,
            id: DEFAULT_ACCOUNT.into(),
            name: "Default".into(),
            api_key: false,
            key_variable: None,
        });
        let mut saved = engine
            .native_provider_accounts(provider)
            .unwrap_or_default()
            .into_iter()
            .map(|row| Account {
                provider,
                id: row.id,
                name: row.name,
                api_key: row.authentication
                    == coincide_core::provider_configuration::NativeAccountAuthentication::ApiKey,
                key_variable: row.key_variable,
            })
            .collect::<Vec<_>>();
        if provider == "codex" {
            for legacy in engine.native_legacy_codex_accounts().unwrap_or_default() {
                if !saved.iter().any(|row| row.id == legacy.id) {
                    saved.push(Account {
                        provider,
                        id: legacy.id,
                        name: legacy.name,
                        api_key: false,
                        key_variable: None,
                    });
                }
            }
            let order = engine.native_codex_account_order().unwrap_or_default();
            saved.sort_by_key(|row| {
                order
                    .iter()
                    .position(|id| id == &row.id)
                    .unwrap_or(usize::MAX)
            });
        }
        rows.extend(saved.into_iter().filter(|row| row.id != DEFAULT_ACCOUNT));
    }
    rows
}

/// A plan-limits read as the account card shows it.
#[derive(Clone, Debug, PartialEq)]
pub enum LimitState {
    /// No read yet: Refresh reads the limits.
    NotChecked,
    Reading,
    Ready(Limits),
    /// The read failed or reported nothing; the text says which.
    Unavailable(String),
    /// Coincide does not read this account's limits.
    NotRead(String),
}

const CLAUDE_FAILURE: &str = "The last check failed.";

/// The explicit Claude Code `get_usage` read for the default account.
#[derive(Default)]
pub struct ClaudeLimits {
    request: Option<(String, u64)>,
    pub state: Option<LimitState>,
    closed: bool,
}
impl ClaudeLimits {
    fn decode(value: &Value) -> Result<(String, u64, LimitState), ()> {
        if value["provider"] != "claude" || value["accountIdentityVerified"] != false {
            return Err(());
        }
        let id = value["requestId"].as_str().ok_or(())?.to_owned();
        let generation = value["generation"].as_u64().ok_or(())?;
        let state = match value["state"].as_str() {
            Some("loading") => LimitState::Reading,
            Some("ready") => {
                LimitState::Ready(serde_json::from_value(value["limits"].clone()).map_err(|_| ())?)
            }
            Some("failed") => LimitState::Unavailable(
                match value["error"].as_str() {
                    Some("unavailable_executable") => "Not installed.",
                    Some("unsupported_platform") => {
                        "Claude Code limits are unavailable on this platform."
                    }
                    Some("cancelled") => "The limits check was cancelled. Refresh to try again.",
                    Some("no_reported_limits") => {
                        "No plan limits reported. Accounts that use an API key have none."
                    }
                    _ => CLAUDE_FAILURE,
                }
                .into(),
            ),
            _ => return Err(()),
        };
        Ok((id, generation, state))
    }
    pub fn refresh(&mut self, engine: &SharedEngine) {
        if !self.try_refresh(engine) {
            self.state = Some(LimitState::Unavailable(
                "The limits check could not start. Refresh to try again.".into(),
            ));
        }
    }
    /// Returns false only when no request was admitted because the engine is
    /// busy. Keep the previous account observation for a later retry.
    pub fn try_refresh(&mut self, engine: &SharedEngine) -> bool {
        if self.closed {
            return true;
        }
        let response = match crate::call(engine, "usage.claudeLimits.refresh", json!({})) {
            Err(error) if crate::engine_busy(&error) => return false,
            response => response,
        };
        self.request = None;
        self.state = Some(
            match response
                .map_err(|_| ())
                .and_then(|value| Self::decode(&value))
            {
                Ok((id, generation, state)) => {
                    self.request = Some((id, generation));
                    state
                }
                Err(()) => LimitState::Unavailable(
                    "The limits check could not start. Refresh to try again.".into(),
                ),
            },
        );
        true
    }
    /// Collects a running read's outcome. True when it changed.
    pub fn poll(&mut self, engine: &SharedEngine) -> bool {
        if self.closed || self.state != Some(LimitState::Reading) {
            return false;
        }
        let Some((id, generation)) = self.request.clone() else {
            return false;
        };
        let next = match crate::call(engine, "usage.claudeLimits.status", json!({"requestId":id})) {
            Err(error) if crate::engine_busy(&error) => return false,
            Ok(value) => match Self::decode(&value) {
                Ok((next, next_generation, state))
                    if next == id && next_generation == generation =>
                {
                    state
                }
                _ => LimitState::Unavailable(CLAUDE_FAILURE.into()),
            },
            Err(_) => LimitState::Unavailable(CLAUDE_FAILURE.into()),
        };
        if !matches!(next, LimitState::Reading) {
            self.request = None;
        }
        let changed = self.state.as_ref() != Some(&next);
        self.state = Some(next);
        changed
    }
    pub fn close(&mut self) {
        self.closed = true;
        self.request = None;
    }
}

const SESSION_MINUTES: u64 = 5 * 60;
const WEEK_MINUTES: u64 = 7 * 24 * 60;
const MONTH_MINUTES: u64 = 30 * 24 * 60;

fn kind(minutes: u64) -> WindowKind {
    if minutes >= MONTH_MINUTES {
        WindowKind::Monthly
    } else if minutes >= WEEK_MINUTES {
        WindowKind::Weekly
    } else {
        WindowKind::Session
    }
}
fn epoch(seconds: Option<f64>) -> Option<DateTime<Utc>> {
    let seconds = seconds.filter(|s| s.is_finite() && *s > 0. && *s < 8.64e12)?;
    DateTime::from_timestamp_millis((seconds * 1000.) as i64)
}

/// A bucket's windows, as Swift's `CodexUsageLimits.windows(ofBucket:)`:
/// `primary` and `secondary` are positions, not lengths, so a window without a
/// reported length is five hours (a month on Free and Go plans) or a week.
fn codex_windows(bucket: &Bucket) -> Vec<Window> {
    let monthly = matches!(bucket.plan.as_deref(), Some("free" | "go"));
    let credits = bucket.credits.as_ref();
    let continues = credits.is_some_and(|c| c.unlimited == Some(true) || c.has == Some(true));
    let mut windows = Vec::new();
    for report in &bucket.windows {
        let fallback = match report.position.as_str() {
            "primary" if monthly => MONTH_MINUTES,
            "primary" => SESSION_MINUTES,
            "secondary" => WEEK_MINUTES,
            "individual" => {
                if let Some(remaining) = report.remaining.filter(|r| r.is_finite()) {
                    windows.push(
                        Window::new(
                            "individual",
                            WindowKind::Monthly,
                            "Monthly credit limit",
                            100. - remaining,
                        )
                        .resetting(epoch(report.resets), None),
                    );
                }
                continue;
            }
            _ => continue,
        };
        let Some(used) = report.used.filter(|u| u.is_finite()) else {
            continue;
        };
        let minutes = report.minutes.unwrap_or(fallback);
        let kind = kind(minutes);
        let mut window = Window::new(&report.position, kind, kind.label(), used)
            .resetting(epoch(report.resets), Some(minutes));
        window.continues_on_credits = continues;
        windows.push(window);
    }
    windows
}

/// A Codex observation as one account's limits, after Swift's
/// `CodexUsageLimits.limits(fromRead:at:)`.
pub fn codex_limits(
    buckets: &[Bucket],
    observed_ms: Option<u64>,
    reset_credits: Option<&ResetCredits>,
) -> Limits {
    let checked_at = observed_ms
        .and_then(|ms| DateTime::from_timestamp_millis(ms as i64))
        .unwrap_or_else(Utc::now);
    let main = buckets.iter().find(|bucket| bucket.id == "codex");
    let mut limits = Limits::new(main.map(codex_windows).unwrap_or_default(), checked_at);
    if let Some(main) = main {
        limits.plan = main.plan.clone();
        limits.credits = main.credits.as_ref().and_then(|credits| {
            Some(Credits {
                has_credits: credits.has?,
                unlimited: credits.unlimited.unwrap_or(false),
                balance: credits.balance.clone(),
            })
        });
        limits.notes = main.notes.clone();
        if let Some(amounts) = &main.individual_amounts {
            let mut figure = Figure::new("individual", "Credit limit", Unit::Credits);
            figure.used = amounts.used;
            figure.limit = amounts.limit;
            figure.resets_at = epoch(amounts.resets);
            limits.figures.push(figure);
        }
    }
    if let Some(resets) = reset_credits {
        let mut figure = Figure::new("reset_credits", "Limit resets available", Unit::Count);
        figure.remaining = Some(resets.available as f64);
        figure.expires_at = epoch(resets.expires);
        limits.figures.push(figure);
    }
    for bucket in buckets.iter().filter(|bucket| bucket.id != "codex") {
        let name = bucket.name.clone().unwrap_or_else(|| bucket.id.clone());
        for mut window in codex_windows(bucket)
            .into_iter()
            .filter(|w| w.id != "individual")
        {
            window.id = format!("{}/{}", bucket.id, window.id);
            window.label = format!("{name} · {}", window.label);
            window.continues_on_credits = false;
            limits.model_windows.push(window);
        }
    }
    limits.sort();
    limits
}

/// The Codex panel's read as the card for the account it targets.
pub fn codex_state(phase: &CodexPhase) -> LimitState {
    match phase {
        CodexPhase::Idle => LimitState::NotChecked,
        CodexPhase::Loading => LimitState::Reading,
        CodexPhase::Ready {
            observed_ms,
            buckets,
            reset_credits,
        } => LimitState::Ready(codex_limits(buckets, *observed_ms, reset_credits.as_ref())),
        CodexPhase::Failed(text) => LimitState::Unavailable((*text).into()),
        CodexPhase::Closing => LimitState::Unavailable("Usage is closing.".into()),
    }
}

/// Settings › Usage's filters and what it last read.
pub struct Dashboard {
    /// None for every provider.
    pub provider: Option<String>,
    /// An account of `provider`, or None for all of them.
    pub account: Option<String>,
    pub days: u32,
    /// The chart shows estimated cost instead of tokens.
    pub cost: bool,
    pub hovered: Option<NaiveDate>,
    /// Detailed local and organization reports are available on demand.
    pub details_open: bool,
    pub data: Option<Data>,
    pub error: Option<String>,
    pub loading: bool,
    /// When the last read started, so a failing read is not retried on every poll.
    pub attempted_at: Option<DateTime<Utc>>,
    /// Whether Settings › Usage showed at the last poll, to read when it appears.
    pub visible: bool,
    pub claude: ClaudeLimits,
    /// Default-account reads for providers with native usage endpoints.
    pub external: HashMap<&'static str, LimitState>,
}
impl Default for Dashboard {
    fn default() -> Self {
        Self {
            provider: None,
            account: None,
            days: 30,
            cost: false,
            hovered: None,
            details_open: false,
            data: None,
            error: None,
            loading: false,
            attempted_at: None,
            visible: false,
            claude: ClaudeLimits::default(),
            external: HashMap::new(),
        }
    }
}
impl Dashboard {
    pub fn accept(&mut self, result: Result<Data, String>) {
        self.loading = false;
        match result {
            Ok(data) => {
                self.data = Some(data);
                self.error = None;
            }
            Err(error) => self.error = Some(error.chars().take(1024).collect()),
        }
    }
    /// Whether the page, appearing now, should read saved history again: at
    /// most every minute, as Swift's scan interval. Returns true once per appearance.
    pub fn appeared(&mut self, visible: bool, now: DateTime<Utc>) -> bool {
        let appeared = visible && !self.visible;
        self.visible = visible;
        appeared
            && !self.loading
            && self
                .attempted_at
                .is_none_or(|attempted| (now - attempted).num_seconds() >= 60)
    }
    pub fn select_provider(&mut self, provider: Option<String>) {
        if self.provider != provider {
            self.provider = provider;
            self.account = None;
            self.hovered = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codex_limits_view::{Credits as CodexCredits, WindowReport};

    #[::core::prelude::v1::test]
    fn cli_usage_replaces_only_complete_providers_and_honors_the_other_sessions_toggle() {
        use coincide_core::cli_usage_logs::{LoggedEvent, Scan};
        use coincide_core::usage_report::{Event, TokenTotals};
        let now = Utc::now();
        let saved = |provider: &str, count| TurnRecord {
            thread_id: None,
            project_id: None,
            provider: provider.into(),
            account_id: "default".into(),
            model: None,
            started_at: None,
            finished_at: now,
            turn_totals: Some(TokenTotals::new(count, 0, 0, 0, 0, 0)),
        };
        let logged = |count, own| LoggedEvent {
            event: Event {
                date: now,
                provider: "codex".into(),
                account_id: "default".into(),
                model: None,
                tokens: TokenTotals::new(count, 0, 0, 0, 0, 0),
                prompt_tokens: 0,
                project_id: None,
            },
            is_from_coincide: own,
        };
        let mut data = Data {
            records: vec![
                saved("codex", 100),
                saved("claude", 200),
                saved("grok", 300),
            ],
            skipped: 0,
            accounts: vec![],
            registered: vec![],
            registered_unavailable: false,
            read_at: now,
            logs: Some(Arc::new(Scan {
                events: vec![logged(30, true), logged(40, false)],
                complete_providers: vec!["codex"],
                incomplete_providers: vec!["claude"],
                ..Scan::default()
            })),
            report_cache: Arc::default(),
        };
        let total =
            |events: Vec<Event>| events.iter().map(|event| event.tokens.total()).sum::<u64>();
        assert_eq!(total(data.events(true)), 570);
        assert_eq!(total(data.events(false)), 530);
        let enabled = ["codex", "claude", "grok"];
        let cached = data.report(false, &enabled, None, None, 30, now);
        assert_eq!(cached.period.tokens.total(), 530);
        assert!(Arc::ptr_eq(
            &cached,
            &data.report(false, &enabled, None, None, 30, now)
        ));
        let filtered = data.report(false, &enabled, Some("codex"), None, 30, now);
        assert_eq!(filtered.period.tokens.total(), 30);
        data.set_logs(Some(Arc::new(Scan {
            events: vec![logged(40, false)],
            complete_providers: vec!["codex"],
            ..Scan::default()
        })));
        assert_eq!(total(data.events(true)), 640);
        assert_eq!(total(data.events(false)), 600);
        let replaced = data.report(false, &enabled, None, None, 30, now);
        assert!(!Arc::ptr_eq(&cached, &replaced));
        assert_eq!(replaced.period.tokens.total(), 600);
        data.set_logs(None);
        assert_eq!(total(data.events(true)), 600);
    }

    #[::core::prelude::v1::test]
    fn opencode_supplement_keeps_saved_days_and_adds_nonoverlapping_history() {
        use coincide_core::cli_usage_logs::{LoggedEvent, Scan};
        use coincide_core::usage_report::{Event, TokenTotals};
        let now = Utc::now();
        let saved = TurnRecord {
            thread_id: None,
            project_id: None,
            provider: "opencode".into(),
            account_id: "default".into(),
            model: None,
            started_at: None,
            finished_at: now,
            turn_totals: Some(TokenTotals::new(100, 0, 0, 0, 0, 0)),
        };
        let logged = |when, count, own| LoggedEvent {
            event: Event {
                date: when,
                provider: "opencode".into(),
                account_id: "default".into(),
                model: None,
                tokens: TokenTotals::new(count, 0, 0, 0, 0, 0),
                prompt_tokens: 0,
                project_id: None,
            },
            is_from_coincide: own,
        };
        let old = now - chrono::Duration::days(2);
        let data = Data {
            records: vec![saved],
            skipped: 0,
            accounts: vec![],
            registered: vec![],
            registered_unavailable: false,
            read_at: now,
            logs: Some(Arc::new(Scan {
                events: vec![
                    logged(now, 900, true),
                    logged(old, 30, true),
                    logged(old, 40, false),
                ],
                supplemental_providers: vec!["opencode"],
                ..Scan::default()
            })),
            report_cache: Arc::default(),
        };
        let total = |include| {
            data.events(include)
                .iter()
                .map(|event| event.tokens.total())
                .sum::<u64>()
        };
        assert_eq!(total(true), 170);
        assert_eq!(total(false), 130);
    }

    #[::core::prelude::v1::test]
    fn complete_cli_logs_preserve_saved_days_without_local_logs() {
        use coincide_core::cli_usage_logs::{LoggedEvent, Scan};
        use coincide_core::usage_report::{Event, TokenTotals};
        let now = Utc::now();
        let saved = |date, count| TurnRecord {
            thread_id: None,
            project_id: None,
            provider: "codex".into(),
            account_id: "default".into(),
            model: None,
            started_at: None,
            finished_at: date,
            turn_totals: Some(TokenTotals::new(count, 0, 0, 0, 0, 0)),
        };
        let data = Data {
            records: vec![saved(now, 100), saved(now - chrono::Duration::days(3), 200)],
            skipped: 0,
            accounts: vec![],
            registered: vec![],
            registered_unavailable: false,
            read_at: now,
            logs: Some(Arc::new(Scan {
                events: vec![LoggedEvent {
                    event: Event {
                        date: now,
                        provider: "codex".into(),
                        account_id: "default".into(),
                        model: None,
                        tokens: TokenTotals::new(30, 0, 0, 0, 0, 0),
                        prompt_tokens: 0,
                        project_id: None,
                    },
                    is_from_coincide: true,
                }],
                complete_providers: vec!["codex"],
                ..Scan::default()
            })),
            report_cache: Arc::default(),
        };
        let report = data.report(true, &["codex"], None, None, 30, now);
        assert_eq!(report.today.tokens.total(), 30);
        assert_eq!(report.last_month.tokens.total(), 230);
    }

    #[::core::prelude::v1::test]
    fn all_available_history_includes_saved_turns_older_than_a_year() {
        use coincide_core::usage_report::TokenTotals;
        let now = Utc::now();
        let data = Data {
            records: vec![TurnRecord {
                thread_id: None,
                project_id: None,
                provider: "codex".into(),
                account_id: "default".into(),
                model: None,
                started_at: None,
                finished_at: now - chrono::Duration::days(500),
                turn_totals: Some(TokenTotals::new(42, 0, 0, 0, 0, 0)),
            }],
            skipped: 0,
            accounts: vec![],
            registered: vec![],
            registered_unavailable: false,
            read_at: now,
            logs: None,
            report_cache: Arc::default(),
        };
        let days = data.history_days(now);
        assert!(days >= 500);
        assert_eq!(
            data.report(false, &["codex"], None, None, days, now)
                .period
                .tokens
                .total(),
            42
        );
        assert_eq!(
            data.report(false, &["codex"], None, None, 365, now)
                .period
                .tokens
                .total(),
            0
        );
    }

    #[::core::prelude::v1::test]
    fn claude_busy_start_keeps_previous_state_for_background_retry() {
        let dir = tempfile::tempdir().unwrap();
        let engine = std::sync::Arc::new(std::sync::Mutex::new(coincide_core::api::Engine::new(
            coincide_core::store::Store::open(&dir.path().join("state.sqlite")).unwrap(),
        )));
        let guard = engine.lock().unwrap();
        let mut limits = ClaudeLimits {
            state: Some(LimitState::NotChecked),
            ..Default::default()
        };
        assert!(!limits.try_refresh(&engine));
        assert_eq!(limits.state, Some(LimitState::NotChecked));
        drop(guard);
    }

    fn report(position: &str, used: Option<f64>, minutes: Option<u64>) -> WindowReport {
        WindowReport {
            position: position.into(),
            used,
            remaining: None,
            minutes,
            resets: Some(2_000_000_000.),
        }
    }

    #[::core::prelude::v1::test]
    fn codex_buckets_become_swift_windows_credits_and_model_limits() {
        let main = Bucket {
            id: "codex".into(),
            name: None,
            plan: Some("plus".into()),
            windows: vec![
                report("primary", Some(42.), None),
                report("secondary", Some(10.), Some(10_080)),
                WindowReport {
                    remaining: Some(30.),
                    ..report("individual", None, None)
                },
            ],
            credits: Some(CodexCredits {
                has: Some(true),
                unlimited: None,
                balance: Some("12.30".into()),
            }),
            individual_amounts: None,
            notes: vec!["The workspace is out of credits.".into()],
        };
        let spark = Bucket {
            id: "spark".into(),
            name: Some("Spark".into()),
            plan: Some("free".into()),
            windows: vec![
                report("primary", Some(5.), None),
                report("secondary", None, None),
            ],
            credits: None,
            individual_amounts: None,
            notes: vec![],
        };
        let limits = codex_limits(&[main, spark], Some(1_793_934_061_000), None);
        let windows = limits
            .windows
            .iter()
            .map(|w| (w.id.as_str(), w.kind))
            .collect::<Vec<_>>();
        assert_eq!(
            windows,
            [
                ("primary", WindowKind::Session),
                ("secondary", WindowKind::Weekly),
                ("individual", WindowKind::Monthly)
            ]
        );
        assert_eq!(limits.windows[0].duration_minutes, Some(300));
        assert!(limits.windows[0].continues_on_credits);
        assert_eq!(limits.windows[2].used_percent, 70.);
        assert_eq!(limits.plan.as_deref(), Some("plus"));
        assert_eq!(
            limits.credits.as_ref().unwrap().balance.as_deref(),
            Some("12.30")
        );
        assert_eq!(limits.notes, ["The workspace is out of credits."]);
        // A Free bucket's unlabeled primary window is monthly, and never continues on credits.
        assert_eq!(limits.model_windows.len(), 1);
        assert_eq!(limits.model_windows[0].id, "spark/primary");
        assert_eq!(limits.model_windows[0].label, "Spark · Monthly");
        assert!(!limits.model_windows[0].continues_on_credits);
        assert_eq!(limits.checked_at.timestamp(), 1_793_934_061);
    }

    #[::core::prelude::v1::test]
    fn codex_reset_credits_survive_provider_decode_and_become_a_visible_row() {
        let value = json!({
            "requestId":"read", "generation":1, "provider":"codex",
            "accountScope":"default_runtime_account_identity_unknown", "accountIdentityVerified":false,
            "state":"ready", "observedAtEpochMs":1_793_934_061_000u64, "error":null,
            "snapshot":{
                "provenance":"codex_app_server_account_rate_limits",
                "accountScope":"default_runtime_account_identity_unknown", "accountIdentityVerified":false,
                "main":{"id":"codex","displayName":null,"plan":"pro","windows":[],
                        "credits":null,"individualAmounts":null,"notes":[]},
                "modelBuckets":[],
                "resetCredits":{"availableCount":1,"expiresAtEpochSeconds":2_000_000_000}
            }
        });
        let observation = crate::codex_limits_view::decode(&value).unwrap();
        let LimitState::Ready(limits) = codex_state(&observation.phase) else {
            panic!("missing limits")
        };
        let row = coincide_core::usage_presentation::rows(
            &limits,
            coincide_core::usage_limits::DisplayMode::Used,
            chrono::DateTime::from_timestamp(1_793_934_061, 0).unwrap(),
            &chrono::Utc,
        )
        .into_iter()
        .find(|row| row.title == "Limit resets available")
        .unwrap();
        assert_eq!(row.value, "1");
        assert!(row.details.iter().any(|detail| detail.contains("expires")));
    }

    #[::core::prelude::v1::test]
    fn saved_history_reads_once_per_appearance_at_most_every_minute() {
        let now = Utc::now();
        let mut dashboard = Dashboard::default();
        assert!(!dashboard.appeared(false, now));
        assert!(dashboard.appeared(true, now));
        dashboard.attempted_at = Some(now);
        // Staying on the page never reads again by itself.
        assert!(!dashboard.appeared(true, now + chrono::Duration::minutes(5)));
        assert!(!dashboard.appeared(false, now));
        assert!(!dashboard.appeared(true, now + chrono::Duration::seconds(30)));
        dashboard.appeared(false, now);
        assert!(dashboard.appeared(true, now + chrono::Duration::seconds(61)));
        dashboard.appeared(false, now);
        dashboard.loading = true;
        assert!(!dashboard.appeared(true, now + chrono::Duration::minutes(5)));
    }

    #[::core::prelude::v1::test]
    fn claude_status_decodes_limits_and_failures_without_fallback() {
        let ready = json!({"requestId":"a","provider":"claude","accountIdentityVerified":false,"state":"ready","generation":1,
            "limits":{"windows":[],"checkedAt":"2026-11-07T12:00:00Z","plan":null,"credits":null,"modelWindows":[],"figures":[],"notes":[]}});
        assert!(matches!(
            ClaudeLimits::decode(&ready).unwrap().2,
            LimitState::Ready(_)
        ));
        let mut failed = ready.clone();
        failed["state"] = json!("failed");
        failed["error"] = json!("unavailable_executable");
        assert_eq!(
            ClaudeLimits::decode(&failed).unwrap().2,
            LimitState::Unavailable("Not installed.".into())
        );
        let mut spoofed = ready.clone();
        spoofed["accountIdentityVerified"] = json!(true);
        assert!(ClaudeLimits::decode(&spoofed).is_err());
        let mut codex = ready;
        codex["provider"] = json!("codex");
        assert!(ClaudeLimits::decode(&codex).is_err());
    }
}
