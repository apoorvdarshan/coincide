//! Explicit Codex limits read. Intended as a child of `model_catalog`, reusing
//! its bounded process transport; no credentials, account/read or turn RPCs.
//! A returned snapshot describes one observation, not live account readiness.
#[cfg(unix)]
use super::ProcessRpc;
use super::Rpc;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
#[cfg(unix)]
use std::time::Duration;
use std::{path::PathBuf, sync::atomic::AtomicBool};

const MAX_BYTES: usize = 1024 * 1024;
const MAX_NODES: usize = 8192;
const MAX_BUCKETS: usize = 64;
const MAX_TEXT: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Failure {
    UnsupportedPlatform,
    UnavailableExecutable,
    ReadFailed,
    Cancelled,
    InvalidResponse,
    ResponseTooLarge,
    NoReportedLimits,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub position: String,
    /// Provider-reported, never clamped or converted to an entitlement verdict.
    pub used_percent: Option<f64>,
    pub remaining_percent: Option<f64>,
    pub duration_minutes: Option<u64>,
    pub resets_at_epoch_seconds: Option<f64>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credits {
    pub has_credits: Option<bool>,
    pub unlimited: Option<bool>,
    /// Reported display amount, not currency/cost or inferred token capacity.
    pub balance: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Note {
    WorkspaceCreditsDepleted,
    WorkspaceUsageLimitReached,
    WorkspaceSpendControlReached,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bucket {
    pub id: String,
    pub display_name: Option<String>,
    pub plan: Option<String>,
    pub windows: Vec<Window>,
    pub credits: Option<Credits>,
    pub notes: Vec<Note>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub provenance: String,
    pub account_scope: String,
    pub account_identity_verified: bool,
    pub main: Option<Bucket>,
    pub model_buckets: Vec<Bucket>,
}

fn bounded(
    value: &Value,
    nodes: &mut usize,
    bytes: &mut usize,
    depth: usize,
) -> Result<(), Failure> {
    if depth > 64 {
        return Err(Failure::ResponseTooLarge);
    }
    *nodes = nodes.checked_add(1).ok_or(Failure::ResponseTooLarge)?;
    if *nodes > MAX_NODES {
        return Err(Failure::ResponseTooLarge);
    }
    match value {
        Value::String(s) => {
            *bytes = bytes
                .checked_add(s.len())
                .ok_or(Failure::ResponseTooLarge)?
        }
        Value::Array(values) => {
            for value in values {
                bounded(value, nodes, bytes, depth + 1)?;
            }
        }
        Value::Object(values) => {
            for (key, value) in values {
                *bytes = bytes
                    .checked_add(key.len())
                    .ok_or(Failure::ResponseTooLarge)?;
                bounded(value, nodes, bytes, depth + 1)?;
            }
        }
        _ => {}
    }
    if *bytes > MAX_BYTES {
        return Err(Failure::ResponseTooLarge);
    }
    Ok(())
}
fn text(value: Option<&Value>) -> Option<String> {
    value?
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= MAX_TEXT && !s.chars().any(char::is_control))
        .map(str::to_owned)
}
fn number(value: Option<&Value>) -> Option<f64> {
    value?.as_f64().filter(|v| v.is_finite())
}
fn epoch(value: Option<&Value>) -> Option<f64> {
    number(value).filter(|v| *v > 0.0 && *v < 8.64e12)
}
fn amount(value: Option<&Value>) -> Option<String> {
    let value = value?;
    match value {
        Value::String(_) => text(Some(value)),
        Value::Number(_) => number(Some(value)).map(|_| value.to_string()),
        _ => None,
    }
}
fn bucket(id: &str, value: &Value, individual: bool) -> Result<Bucket, Failure> {
    let object = value.as_object().ok_or(Failure::InvalidResponse)?;
    let mut windows = Vec::new();
    for position in ["primary", "secondary"] {
        if let Some(window) = object.get(position).filter(|v| !v.is_null()) {
            let window = window.as_object().ok_or(Failure::InvalidResponse)?;
            windows.push(Window {
                position: position.into(),
                used_percent: number(window.get("usedPercent")),
                remaining_percent: None,
                duration_minutes: window
                    .get("windowDurationMins")
                    .and_then(Value::as_u64)
                    .filter(|v| *v > 0),
                resets_at_epoch_seconds: epoch(window.get("resetsAt")),
            });
        }
    }
    if individual && let Some(window) = object.get("individualLimit").filter(|v| !v.is_null()) {
        let window = window.as_object().ok_or(Failure::InvalidResponse)?;
        windows.push(Window {
            position: "individual".into(),
            used_percent: None,
            remaining_percent: number(window.get("remainingPercent")),
            duration_minutes: None,
            resets_at_epoch_seconds: epoch(window.get("resetsAt")),
        });
    }
    let credits = match object.get("credits").filter(|v| !v.is_null()) {
        None => None,
        Some(value) => {
            let value = value.as_object().ok_or(Failure::InvalidResponse)?;
            Some(Credits {
                has_credits: value.get("hasCredits").and_then(Value::as_bool),
                unlimited: value.get("unlimited").and_then(Value::as_bool),
                balance: amount(value.get("balance")),
            })
        }
    };
    let note = match object.get("rateLimitReachedType").and_then(Value::as_str) {
        Some("workspace_owner_credits_depleted" | "workspace_member_credits_depleted") => {
            Some(Note::WorkspaceCreditsDepleted)
        }
        Some("workspace_owner_usage_limit_reached" | "workspace_member_usage_limit_reached") => {
            Some(Note::WorkspaceUsageLimitReached)
        }
        _ if object.get("spendControlReached").and_then(Value::as_bool) == Some(true) => {
            Some(Note::WorkspaceSpendControlReached)
        }
        _ => None,
    };
    Ok(Bucket {
        id: id.into(),
        display_name: text(object.get("limitName")).or_else(|| text(object.get("normalModelSlug"))),
        plan: text(object.get("planType")).filter(|s| s != "unknown"),
        windows,
        credits,
        notes: note.into_iter().collect(),
    })
}

/// Parses provider data only. No raw response, account identifiers, executable
/// paths, or provider errors are returned. Unknown fields are not authority.
pub fn parse(value: &Value) -> Result<Snapshot, Failure> {
    bounded(value, &mut 0, &mut 0, 0)?;
    let object = value.as_object().ok_or(Failure::InvalidResponse)?;
    let buckets = match object.get("rateLimitsByLimitId").filter(|v| !v.is_null()) {
        None => None,
        Some(value) => Some(value.as_object().ok_or(Failure::InvalidResponse)?),
    };
    if buckets.is_some_and(|b| b.len() > MAX_BUCKETS) {
        return Err(Failure::ResponseTooLarge);
    }
    let main_value = buckets
        .and_then(|b| b.get("codex"))
        .filter(|v| v.is_object())
        .or_else(|| object.get("rateLimits").filter(|v| !v.is_null()));
    let main = match main_value {
        Some(value)
            if value
                .get("limitId")
                .and_then(Value::as_str)
                .is_none_or(|id| id == "codex") =>
        {
            Some(bucket("codex", value, true)?)
        }
        _ => None,
    };
    let mut model_buckets = Vec::new();
    if let Some(buckets) = buckets {
        for (id, value) in buckets {
            if id == "codex" || value.is_null() {
                continue;
            }
            if id.is_empty() || id.len() > MAX_TEXT || id.chars().any(char::is_control) {
                return Err(Failure::InvalidResponse);
            }
            model_buckets.push(bucket(id, value, false)?);
        }
    }
    model_buckets.sort_by(|a, b| a.id.cmp(&b.id));
    if main.is_none() && model_buckets.is_empty() {
        return Err(Failure::NoReportedLimits);
    }
    Ok(Snapshot {
        provenance: "codex_app_server_account_rate_limits".into(),
        account_scope: "default_runtime_account_identity_unknown".into(),
        account_identity_verified: false,
        main,
        model_buckets,
    })
}

fn protocol(rpc: &mut impl Rpc) -> Result<Snapshot, Failure> {
    rpc.write(&json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"coincide","title":"Coincide","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}})).map_err(|_| Failure::ReadFailed)?;
    rpc.response(1).map_err(|_| Failure::ReadFailed)?;
    rpc.write(&json!({"method":"initialized"}))
        .map_err(|_| Failure::ReadFailed)?;
    rpc.write(&json!({"id":2,"method":"account/rateLimits/read","params":{}}))
        .map_err(|_| Failure::ReadFailed)?;
    parse(&rpc.response(2).map_err(|_| Failure::ReadFailed)?)
}
/// Blocking worker-side read ONLY; host must retain/join its worker and poll
/// during shutdown. Uses existing transport limits, cancellation and child reaping.
/// Host supplies trusted configured executable, never a request JSON path.
#[cfg(unix)]
pub fn read(executable: Option<PathBuf>, cancelled: &AtomicBool) -> Result<Snapshot, Failure> {
    if cancelled.load(std::sync::atomic::Ordering::Acquire) {
        return Err(Failure::Cancelled);
    }
    let executable = executable.ok_or(Failure::UnavailableExecutable)?;
    let mut rpc = ProcessRpc::spawn("codex", executable, Duration::from_secs(15), cancelled)
        .map_err(|_| Failure::ReadFailed)?;
    let result = protocol(&mut rpc);
    if cancelled.load(std::sync::atomic::Ordering::Acquire) {
        return Err(Failure::Cancelled);
    }
    result
}
#[cfg(not(unix))]
pub fn read(_: Option<PathBuf>, _: &AtomicBool) -> Result<Snapshot, Failure> {
    Err(Failure::UnsupportedPlatform)
}

/// Host-side freshness ledger: begin BEFORE dispatch; only the exact current
/// ticket may publish. Failure clears current data; no TTL or old-data fallback.
pub struct Observations {
    identity: uuid::Uuid,
    generation: u64,
    current: Option<Observation>,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Observation {
    pub generation: u64,
    pub observed_at_epoch_ms: u64,
    pub snapshot: Option<Snapshot>,
    pub failure: Option<Failure>,
}
#[derive(Clone, Copy)]
pub struct Ticket {
    identity: uuid::Uuid,
    generation: u64,
}
impl Default for Observations {
    fn default() -> Self {
        Self {
            identity: uuid::Uuid::new_v4(),
            generation: 0,
            current: None,
        }
    }
}
impl Observations {
    pub fn begin(&mut self) -> Option<Ticket> {
        self.current = None;
        self.generation = self.generation.checked_add(1)?;
        Some(Ticket {
            identity: self.identity,
            generation: self.generation,
        })
    }
    /// `observed_at_epoch_ms` comes from host clock at completion, not provider.
    pub fn complete(
        &mut self,
        ticket: Ticket,
        observed_at_epoch_ms: u64,
        result: Result<Snapshot, Failure>,
    ) -> bool {
        if ticket.identity != self.identity
            || ticket.generation != self.generation
            || self.current.is_some()
        {
            return false;
        }
        let (snapshot, failure) = match result {
            Ok(snapshot) => (Some(snapshot), None),
            Err(error) => (None, Some(error)),
        };
        self.current = Some(Observation {
            generation: self.generation,
            observed_at_epoch_ms,
            snapshot,
            failure,
        });
        true
    }
    /// Required when the host changes configured executable/account context or
    /// closes admission. Invalidates even outstanding tickets without new work.
    pub fn invalidate(&mut self) {
        self.identity = uuid::Uuid::new_v4();
        self.generation = 0;
        self.current = None;
    }
    pub fn current(&self) -> Option<&Observation> {
        self.current.as_ref()
    }
}

/// A separate owner: limits results never enter catalog jobs or mint model proof.
pub(super) struct Owner {
    observations: Observations,
    current_id: Option<String>,
    context: Option<PathBuf>,
    workers: Vec<LimitsWorker>,
    closed: bool,
    totals: super::ShutdownStatus,
    tx: std::sync::mpsc::SyncSender<Completion>,
    rx: std::sync::mpsc::Receiver<Completion>,
}
struct LimitsWorker {
    ticket: Ticket,
    cancelled: std::sync::Arc<AtomicBool>,
    completion: crate::agent::WorkerCompletion,
}
type Completion = (Ticket, u64, Result<Snapshot, Failure>);
impl Default for Owner {
    fn default() -> Self {
        let (tx, rx) = std::sync::mpsc::sync_channel(2);
        Self {
            observations: Observations::default(),
            current_id: None,
            context: None,
            workers: Vec::new(),
            closed: false,
            totals: super::ShutdownStatus::default(),
            tx,
            rx,
        }
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}
impl Owner {
    pub(super) fn context(&mut self, executable: Option<PathBuf>) -> bool {
        if self.context != executable {
            self.context = executable;
            self.observations.invalidate();
            self.current_id = None;
            for worker in &self.workers {
                worker
                    .cancelled
                    .store(true, std::sync::atomic::Ordering::Release);
            }
            return true;
        }
        false
    }
    pub(super) fn refresh(&mut self, executable: Option<PathBuf>) -> anyhow::Result<Value> {
        self.refresh_with(executable, read)
    }
    fn refresh_with(
        &mut self,
        executable: Option<PathBuf>,
        work: impl FnOnce(Option<PathBuf>, &AtomicBool) -> Result<Snapshot, Failure> + Send + 'static,
    ) -> anyhow::Result<Value> {
        anyhow::ensure!(!self.closed, "Codex limits reader is shutting down");
        self.poll();
        anyhow::ensure!(
            self.workers.len() < 2,
            "Codex limits workers are still draining"
        );
        self.context(executable.clone());
        for worker in &self.workers {
            worker
                .cancelled
                .store(true, std::sync::atomic::Ordering::Release);
        }
        let ticket = self
            .observations
            .begin()
            .ok_or_else(|| anyhow::anyhow!("Limits generation exhausted"))?;
        let id = uuid::Uuid::new_v4().to_string();
        self.current_id = Some(id.clone());
        let cancelled = std::sync::Arc::new(AtomicBool::new(false));
        let cancel = cancelled.clone();
        let tx = self.tx.clone();
        match std::thread::Builder::new()
            .name("coincide-codex-limits".into())
            .spawn(move || {
                let result = work(executable, &cancel);
                let result = if cancel.load(std::sync::atomic::Ordering::Acquire) {
                    Err(Failure::Cancelled)
                } else {
                    result
                };
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .ok()
                    .and_then(|v| u64::try_from(v.as_millis()).ok())
                    .unwrap_or(0);
                let _ = tx.send((ticket, now, result));
            }) {
            Ok(worker) => self.workers.push(LimitsWorker {
                ticket,
                cancelled,
                completion: crate::agent::WorkerCompletion::observe(worker),
            }),
            Err(_) => {
                self.observations
                    .complete(ticket, 0, Err(Failure::ReadFailed));
            }
        }
        self.status(&id)
    }
    fn receive(&mut self) -> bool {
        let mut changed = false;
        for (ticket, at, result) in self.rx.try_iter() {
            changed |= self.observations.complete(ticket, at, result);
        }
        changed
    }
    pub(super) fn poll(&mut self) -> bool {
        let mut changed = self.receive();
        let mut exited = Vec::new();
        self.workers.retain(|worker| {
            use crate::agent::WorkerThreadStatus;
            let counter = match worker.completion.status() {
                WorkerThreadStatus::Running | WorkerThreadStatus::Unclassified => return true,
                WorkerThreadStatus::Returned => &mut self.totals.returned,
                WorkerThreadStatus::Panicked => &mut self.totals.panicked,
            };
            *counter = counter.saturating_add(1);
            exited.push(worker.ticket);
            false
        });
        changed |= self.receive();
        for ticket in exited {
            changed |= self
                .observations
                .complete(ticket, 0, Err(Failure::ReadFailed));
        }
        changed
    }
    pub(super) fn status(&self, id: &str) -> anyhow::Result<Value> {
        anyhow::ensure!(
            self.current_id.as_deref() == Some(id),
            "Codex limits request not found or superseded"
        );
        let observation = self.observations.current();
        Ok(
            json!({"requestId":id,"provider":"codex","accountScope":"default_runtime_account_identity_unknown","accountIdentityVerified":false,
            "state":match observation {None=>"loading",Some(v) if v.snapshot.is_some()=>"ready",_=>"failed"},
            "generation":self.observations.generation,"observedAtEpochMs":observation.map(|v|v.observed_at_epoch_ms).filter(|v|*v>0),
            "snapshot":observation.and_then(|v|v.snapshot.as_ref()),"error":observation.and_then(|v|v.failure)}),
        )
    }
    pub(super) fn request_shutdown(&mut self) {
        self.closed = true;
        for worker in &self.workers {
            worker
                .cancelled
                .store(true, std::sync::atomic::Ordering::Release);
        }
        self.observations.invalidate();
        self.current_id = None;
    }
    pub(super) fn shutdown_status(&mut self) -> super::ShutdownStatus {
        self.poll();
        super::ShutdownStatus {
            closed: self.closed,
            running: self.workers.len(),
            unclassified: self
                .workers
                .iter()
                .filter(|w| w.completion.status() == crate::agent::WorkerThreadStatus::Unclassified)
                .count() as u64,
            ..self.totals
        }
    }
}
/// Deliberately no provider/account/path/trust arguments are accepted.
pub(crate) fn validate_refresh(params: &Value) -> anyhow::Result<()> {
    anyhow::ensure!(
        params.as_object().is_some_and(|p| p.is_empty()),
        "Codex limits refresh requires an empty object"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample() -> Value {
        json!({"rateLimits":{"primary":{"usedPercent":42.5},"credits":{"hasCredits":true,"balance":"12.30"}}})
    }
    #[test]
    fn preserves_absent_duration_reset_and_credit_boolean() {
        let parsed = parse(&sample()).unwrap();
        let main = parsed.main.unwrap();
        assert_eq!(main.windows[0].used_percent, Some(42.5));
        assert_eq!(main.windows[0].duration_minutes, None);
        assert_eq!(main.windows[0].resets_at_epoch_seconds, None);
        let credits = main.credits.unwrap();
        assert_eq!(credits.unlimited, None);
        assert_eq!(credits.balance.as_deref(), Some("12.30"));
        assert!(!parsed.account_identity_verified);
    }
    #[test]
    fn codex_bucket_precedes_legacy_and_models_stay_separate() {
        let parsed=parse(&json!({"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"planType":"plus","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":2000000000}},"spark":{"limitName":"Spark","secondary":{"usedPercent":2},"individualLimit":{"remainingPercent":5}}}})).unwrap();
        assert_eq!(parsed.main.unwrap().windows[0].used_percent, Some(1.0));
        assert_eq!(parsed.model_buckets[0].id, "spark");
        assert_eq!(parsed.model_buckets[0].windows.len(), 1);
    }
    #[test]
    fn invalid_optional_values_are_unknown_not_zero_or_fallback() {
        let parsed=parse(&json!({"rateLimits":{"planType":"unknown","primary":{"usedPercent":"90","windowDurationMins":-1,"resetsAt":-2},"credits":{"balance":false}}})).unwrap();
        let main = parsed.main.unwrap();
        assert_eq!(main.plan, None);
        assert_eq!(main.windows[0].used_percent, None);
        assert_eq!(main.windows[0].duration_minutes, None);
        assert_eq!(main.credits.unwrap().balance, None);
    }
    #[test]
    fn workspace_note_and_individual_remaining_keep_reported_scope() {
        let main=parse(&json!({"rateLimits":{"individualLimit":{"remainingPercent":12},"rateLimitReachedType":"workspace_member_credits_depleted"}})).unwrap().main.unwrap();
        assert_eq!(main.notes, vec![Note::WorkspaceCreditsDepleted]);
        assert_eq!(main.windows[0].remaining_percent, Some(12.0));
        assert_eq!(main.windows[0].used_percent, None);
    }
    #[test]
    fn rejects_missing_malformed_and_oversized_responses() {
        assert_eq!(
            parse(&json!({"rateLimits":null})),
            Err(Failure::NoReportedLimits)
        );
        assert_eq!(
            parse(&json!({"rateLimits":[]})),
            Err(Failure::InvalidResponse)
        );
        let mut buckets = serde_json::Map::new();
        for i in 0..=MAX_BUCKETS {
            buckets.insert(i.to_string(), json!({}));
        }
        assert_eq!(
            parse(&json!({"rateLimitsByLimitId":buckets})),
            Err(Failure::ResponseTooLarge)
        );
        assert_eq!(
            parse(&json!({"unknown":"x".repeat(MAX_BYTES+1)})),
            Err(Failure::ResponseTooLarge)
        );
    }
    #[test]
    fn stale_completion_and_failed_refresh_have_no_current_fallback() {
        let mut observations = Observations::default();
        let old = observations.begin().unwrap();
        assert!(observations.complete(old, 1, parse(&sample())));
        let current = observations.begin().unwrap();
        assert!(observations.current().is_none());
        assert!(!observations.complete(old, 2, parse(&sample())));
        assert!(observations.complete(current, 3, Err(Failure::ReadFailed)));
        assert!(observations.current().unwrap().snapshot.is_none());
        assert_eq!(
            observations.current().unwrap().failure,
            Some(Failure::ReadFailed)
        );
    }
    struct Fake {
        writes: Vec<Value>,
        failure: bool,
    }
    impl Rpc for Fake {
        fn write(&mut self, value: &Value) -> anyhow::Result<()> {
            self.writes.push(value.clone());
            Ok(())
        }
        fn response(&mut self, id: u64) -> anyhow::Result<Value> {
            if self.failure {
                anyhow::bail!("secret provider error")
            };
            Ok(if id == 1 { json!({}) } else { sample() })
        }
    }
    #[test]
    fn exact_read_only_protocol_no_account_auth_model_or_turn_calls() {
        let mut fake = Fake {
            writes: vec![],
            failure: false,
        };
        protocol(&mut fake).unwrap();
        assert_eq!(
            fake.writes
                .iter()
                .map(|v| v["method"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["initialize", "initialized", "account/rateLimits/read"]
        );
        assert_eq!(fake.writes[2]["params"], json!({}));
    }
    #[test]
    fn foreign_tickets_and_duplicate_completion_are_rejected() {
        let mut a = Observations::default();
        let mut b = Observations::default();
        let ticket = a.begin().unwrap();
        b.begin().unwrap();
        assert!(!b.complete(ticket, 1, parse(&sample())));
        assert!(a.complete(ticket, 1, parse(&sample())));
        assert!(!a.complete(ticket, 2, Err(Failure::ReadFailed)));
    }
    #[test]
    fn context_invalidation_rejects_in_flight_result_without_new_work() {
        let mut observations = Observations::default();
        let ticket = observations.begin().unwrap();
        observations.invalidate();
        assert!(!observations.complete(ticket, 1, parse(&sample())));
        assert!(observations.current().is_none());
    }
    #[test]
    fn depth_is_bounded_before_projection() {
        let mut value = json!({});
        for _ in 0..66 {
            value = json!([value]);
        }
        assert_eq!(parse(&value), Err(Failure::ResponseTooLarge));
    }
    fn joined(observer: &crate::agent::WorkerCompletion) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while observer.status() == crate::agent::WorkerThreadStatus::Running {
            assert!(
                std::time::Instant::now() < deadline,
                "fake limits worker failed to join"
            );
            std::thread::yield_now();
        }
    }
    #[test]
    fn strict_refresh_rejects_caller_account_executable_and_trust() {
        assert!(validate_refresh(&json!({})).is_ok());
        for value in [
            json!({"accountId":"default"}),
            json!({"executable":"/fake"}),
            json!({"trusted":true}),
            Value::Null,
        ] {
            assert!(validate_refresh(&value).is_err());
        }
    }
    #[test]
    fn latest_worker_wins_out_of_order_and_cancels_old_without_losing_join() {
        let mut owner = Owner::default();
        let (tx, rx) = std::sync::mpsc::channel();
        let first = owner
            .refresh_with(None, move |_, cancel| {
                rx.recv().unwrap();
                assert!(cancel.load(std::sync::atomic::Ordering::Acquire));
                parse(&sample())
            })
            .unwrap();
        let old = owner.workers[0].completion.clone();
        let second = owner
            .refresh_with(None, |_, _| Err(Failure::NoReportedLimits))
            .unwrap();
        let current = owner.workers[1].completion.clone();
        joined(&current);
        owner.poll();
        assert_eq!(
            owner.status(second["requestId"].as_str().unwrap()).unwrap()["error"],
            "no_reported_limits"
        );
        assert!(owner.status(first["requestId"].as_str().unwrap()).is_err());
        assert_eq!(owner.shutdown_status().running, 1);
        tx.send(()).unwrap();
        joined(&old);
        owner.poll();
        assert_eq!(
            owner.status(second["requestId"].as_str().unwrap()).unwrap()["error"],
            "no_reported_limits"
        );
        assert_eq!(owner.shutdown_status().returned, 2);
    }
    struct ExitGate {
        entered: std::sync::mpsc::Sender<()>,
        release: std::sync::mpsc::Receiver<()>,
    }
    impl Drop for ExitGate {
        fn drop(&mut self) {
            self.entered.send(()).unwrap();
            self.release.recv().unwrap();
        }
    }
    thread_local! {static EXIT_GATE:std::cell::RefCell<Option<ExitGate>>=const {std::cell::RefCell::new(None)};}
    #[test]
    fn aggregate_waits_actual_limits_tls_join_and_never_mints_catalog_job() {
        let mut catalog = super::super::ModelCatalog::default();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let response = catalog
            .limits
            .refresh_with(None, move |_, _| {
                EXIT_GATE.with(|slot| {
                    *slot.borrow_mut() = Some(ExitGate {
                        entered: entered_tx,
                        release: release_rx,
                    })
                });
                parse(&sample())
            })
            .unwrap();
        entered_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        catalog.poll();
        assert_eq!(
            catalog
                .limits_status(response["requestId"].as_str().unwrap())
                .unwrap()["state"],
            "ready"
        );
        assert!(catalog.jobs.is_empty());
        assert_eq!(catalog.shutdown_status().running, 1);
        let observer = catalog.limits.workers[0].completion.clone();
        catalog.request_shutdown();
        assert!(catalog.refresh_limits(None).is_err());
        assert_eq!(catalog.shutdown_status().running, 1);
        release_tx.send(()).unwrap();
        joined(&observer);
        let status = catalog.shutdown_status();
        assert_eq!(status.running, 0);
        assert_eq!(status.returned, 1);
        assert!(status.closed);
        assert_eq!(catalog.shutdown_status(), status);
    }
    #[test]
    fn panicked_worker_remains_failure_and_actual_join_is_accounted() {
        let mut owner = Owner::default();
        let response = owner
            .refresh_with(None, |_, _| panic!("synthetic limits failure"))
            .unwrap();
        let observer = owner.workers[0].completion.clone();
        joined(&observer);
        owner.poll();
        let status = owner
            .status(response["requestId"].as_str().unwrap())
            .unwrap();
        assert_eq!(status["error"], "read_failed");
        assert!(status["snapshot"].is_null());
        assert_eq!(owner.shutdown_status().panicked, 1);
        assert_eq!(owner.shutdown_status().running, 0);
    }
    #[test]
    fn ready_context_revocation_is_published_without_new_work() {
        let mut owner = Owner::default();
        let path = Some(PathBuf::from("/synthetic-a"));
        let response = owner
            .refresh_with(path.clone(), |_, _| parse(&sample()))
            .unwrap();
        joined(&owner.workers[0].completion.clone());
        owner.poll();
        let id = response["requestId"].as_str().unwrap();
        assert_eq!(owner.status(id).unwrap()["state"], "ready");
        assert!(!owner.context(path));
        assert!(owner.context(Some(PathBuf::from("/synthetic-b"))));
        assert!(owner.status(id).is_err());
        assert!(owner.observations.current().is_none());
        assert!(!owner.poll());
        assert_eq!(owner.shutdown_status().running, 0);
        assert_eq!(owner.shutdown_status().returned, 1);
        assert!(!owner.context(Some(PathBuf::from("/synthetic-b"))));
    }
    #[test]
    fn context_loss_revokes_worker_result_and_shutdown_rejects_without_spawning() {
        let mut owner = Owner::default();
        let (tx, rx) = std::sync::mpsc::channel();
        let response = owner
            .refresh_with(Some(PathBuf::from("/synthetic-a")), move |_, _| {
                rx.recv().unwrap();
                parse(&sample())
            })
            .unwrap();
        let observer = owner.workers[0].completion.clone();
        owner.context(Some(PathBuf::from("/synthetic-b")));
        tx.send(()).unwrap();
        joined(&observer);
        owner.poll();
        assert!(
            owner
                .status(response["requestId"].as_str().unwrap())
                .is_err()
        );
        owner.request_shutdown();
        owner.request_shutdown();
        assert!(
            owner
                .refresh_with(None, |_, _| panic!("must not start"))
                .is_err()
        );
        assert_eq!(owner.shutdown_status().running, 0);
    }
    #[test]
    fn provider_error_is_static_and_contains_no_raw_payload() {
        let mut fake = Fake {
            writes: vec![],
            failure: true,
        };
        assert_eq!(protocol(&mut fake), Err(Failure::ReadFailed));
        assert_eq!(fake.writes.len(), 1);
    }
}
