//! Settings › Usage's state, after Swift's `UsageDashboardModel`: the saved
//! turns and account rows it reads in the background, the filters, and each
//! account's limits. Limits are read only when the user refreshes; opening the
//! page reads saved local history alone.
use crate::codex_limits_view::{Bucket, Phase as CodexPhase};
use chrono::{DateTime, NaiveDate, Utc};
use coincide_core::{
    api::SharedEngine,
    usage_limits::{Credits, Limits, Window, WindowKind},
    usage_report::{DEFAULT_ACCOUNT, PROVIDERS, TurnRecord, turn_records},
};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

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
    pub read_at: DateTime<Utc>,
}

/// Worker side: holds the engine only to copy saved bytes and account rows.
pub(crate) fn read(engine: &SharedEngine) -> Result<Data, String> {
    let deadline = Instant::now() + Duration::from_secs(3);
    let (bytes, accounts) = loop {
        match engine.try_lock() {
            Ok(engine) => {
                if engine.admissions_frozen() {
                    return Err("Usage is closing.".into());
                }
                let (bytes, _) = engine.store.saved_usage_snapshot().map_err(|_| {
                    "Usage history could not be read. Its saved contents have been retained."
                        .to_owned()
                })?;
                break (bytes, accounts(&engine));
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
    Ok(Data {
        records,
        skipped,
        accounts,
        read_at: Utc::now(),
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
pub fn codex_limits(buckets: &[Bucket], observed_ms: Option<u64>) -> Limits {
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
        } => LimitState::Ready(codex_limits(buckets, *observed_ms)),
        CodexPhase::Failed(text) => LimitState::Unavailable((*text).into()),
        CodexPhase::Closing => LimitState::Unavailable("Usage is closing.".into()),
    }
}

/// Settings › Usage's filters and what it last read.
pub struct Dashboard {
    /// None for every provider.
    pub provider: Option<&'static str>,
    /// An account of `provider`, or None for all of them.
    pub account: Option<String>,
    pub days: u32,
    /// The chart shows estimated cost instead of tokens.
    pub cost: bool,
    pub hovered: Option<NaiveDate>,
    pub data: Option<Data>,
    pub error: Option<String>,
    pub loading: bool,
    /// When the last read started, so a failing read is not retried on every poll.
    pub attempted_at: Option<DateTime<Utc>>,
    /// Whether Settings › Usage showed at the last poll, to read when it appears.
    pub visible: bool,
    pub claude: ClaudeLimits,
}
impl Default for Dashboard {
    fn default() -> Self {
        Self {
            provider: None,
            account: None,
            days: 30,
            cost: false,
            hovered: None,
            data: None,
            error: None,
            loading: false,
            attempted_at: None,
            visible: false,
            claude: ClaudeLimits::default(),
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
    pub fn select_provider(&mut self, provider: Option<&'static str>) {
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
            notes: vec![],
        };
        let limits = codex_limits(&[main, spark], Some(1_793_934_061_000));
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
