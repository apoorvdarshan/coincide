//! Explicit Claude Code plan-limits read, Swift's `ClaudeCapabilitiesProbe` with
//! `get_usage`. A child of `model_catalog`, reusing its bounded read-only
//! process transport: no prompt, credential read or session is created. The
//! default runtime's account identity is unverified, as for Codex limits.
#[cfg(any(unix, windows))]
use super::{ProcessRpc, Rpc};
use crate::usage_limits::{Limits, claude};
use serde::Serialize;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Failure {
    #[cfg_attr(any(unix, windows), allow(dead_code))]
    UnsupportedPlatform,
    UnavailableExecutable,
    ReadFailed,
    Cancelled,
    InvalidResponse,
    NoReportedLimits,
}

const INITIALIZE: &str = "coincide-usage-initialize";
const USAGE: &str = "coincide-usage-limits";

/// The frames of one probe: requests out, frames back.
trait Frames {
    fn send(&mut self, value: &Value) -> Result<(), Failure>;
    fn next(&mut self) -> Result<Value, Failure>;
}
#[cfg(any(unix, windows))]
impl Frames for ProcessRpc<'_> {
    fn send(&mut self, value: &Value) -> Result<(), Failure> {
        self.write(value).map_err(|_| Failure::ReadFailed)
    }
    fn next(&mut self) -> Result<Value, Failure> {
        self.frame().map_err(|_| Failure::ReadFailed)
    }
}

/// The answer to one control request, or None when Claude refused it. Claude may
/// interleave status frames; a request for an action fails the read.
fn answer(rpc: &mut impl Frames, id: &str) -> Result<Option<Value>, Failure> {
    loop {
        let frame = rpc.next()?;
        match frame["type"].as_str() {
            Some("control_request") => return Err(Failure::InvalidResponse),
            Some("control_response") => {
                if frame["response"]["request_id"] != id {
                    return Err(Failure::InvalidResponse);
                }
                return Ok((frame["response"]["subtype"] == "success")
                    .then(|| frame["response"]["response"].clone()));
            }
            _ => {}
        }
    }
}

fn protocol(rpc: &mut impl Frames) -> Result<Limits, Failure> {
    rpc.send(&json!({"type":"control_request","request_id":INITIALIZE,"request":{"subtype":"initialize"}}))?;
    answer(rpc, INITIALIZE)?.ok_or(Failure::ReadFailed)?;
    // As in Swift and T3 Code, only the plan's limits are read, so Claude skips
    // scanning local transcripts for the rest.
    rpc.send(&json!({"type":"control_request","request_id":USAGE,"request":{"subtype":"get_usage","skip_behaviors":true}}))?;
    // An older Claude Code without `get_usage` refuses it: no limits to show.
    let usage = answer(rpc, USAGE)?.ok_or(Failure::NoReportedLimits)?;
    if !usage.is_object() {
        return Err(Failure::InvalidResponse);
    }
    claude::limits_from_usage(&usage, chrono::Utc::now()).ok_or(Failure::NoReportedLimits)
}

/// Blocking worker-side read. The host supplies its trusted configured executable.
#[cfg(any(unix, windows))]
pub fn read(executable: Option<PathBuf>, cancelled: &AtomicBool) -> Result<Limits, Failure> {
    if cancelled.load(Ordering::Acquire) {
        return Err(Failure::Cancelled);
    }
    let executable = executable.ok_or(Failure::UnavailableExecutable)?;
    let mut rpc = ProcessRpc::spawn(
        "claude",
        executable,
        std::time::Duration::from_secs(25),
        cancelled,
    )
    .map_err(|_| Failure::ReadFailed)?;
    let result = protocol(&mut rpc);
    if cancelled.load(Ordering::Acquire) {
        return Err(Failure::Cancelled);
    }
    result
}
#[cfg(not(any(unix, windows)))]
pub fn read(_: Option<PathBuf>, _: &AtomicBool) -> Result<Limits, Failure> {
    Err(Failure::UnsupportedPlatform)
}

/// The current read and its outcome. A newer read supersedes the old one and
/// never falls back to its limits; a failed read clears them.
#[derive(Clone)]
struct Current {
    id: String,
    generation: u64,
    observed_at_epoch_ms: Option<u64>,
    outcome: Option<Result<Limits, Failure>>,
}
struct LimitsWorker {
    generation: u64,
    cancelled: Arc<AtomicBool>,
    completion: crate::agent::WorkerCompletion,
}
type Completion = (u64, u64, Result<Limits, Failure>);
pub(super) struct Owner {
    generation: u64,
    current: Option<Current>,
    context: Option<PathBuf>,
    workers: Vec<LimitsWorker>,
    closed: bool,
    totals: super::ShutdownStatus,
    tx: std::sync::mpsc::SyncSender<Completion>,
    rx: std::sync::mpsc::Receiver<Completion>,
}
impl Default for Owner {
    fn default() -> Self {
        let (tx, rx) = std::sync::mpsc::sync_channel(2);
        Self {
            generation: 0,
            current: None,
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
    fn cancel_workers(&self) {
        for worker in &self.workers {
            worker.cancelled.store(true, Ordering::Release);
        }
    }
    pub(super) fn running(&mut self) -> usize {
        self.poll();
        self.workers.len()
    }
    pub(super) fn refresh(&mut self, executable: Option<PathBuf>) -> anyhow::Result<Value> {
        self.refresh_with(executable, read)
    }
    fn refresh_with(
        &mut self,
        executable: Option<PathBuf>,
        work: impl FnOnce(Option<PathBuf>, &AtomicBool) -> Result<Limits, Failure> + Send + 'static,
    ) -> anyhow::Result<Value> {
        anyhow::ensure!(!self.closed, "Claude limits reader is shutting down");
        self.poll();
        anyhow::ensure!(
            self.workers.len() < 2,
            "Claude limits workers are still draining"
        );
        self.context = executable.clone();
        self.cancel_workers();
        self.generation = self
            .generation
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("Limits generation exhausted"))?;
        let generation = self.generation;
        let id = uuid::Uuid::new_v4().to_string();
        self.current = Some(Current {
            id: id.clone(),
            generation,
            observed_at_epoch_ms: None,
            outcome: None,
        });
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel = cancelled.clone();
        let tx = self.tx.clone();
        let configuration = crate::provider_configuration::current();
        match std::thread::Builder::new()
            .name("coincide-claude-limits".into())
            .spawn(move || {
                let _configuration_scope = crate::provider_configuration::enter(configuration);
                let result = work(executable, &cancel);
                let result = if cancel.load(Ordering::Acquire) {
                    Err(Failure::Cancelled)
                } else {
                    result
                };
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .ok()
                    .and_then(|v| u64::try_from(v.as_millis()).ok())
                    .unwrap_or(0);
                let _ = tx.send((generation, now, result));
            }) {
            Ok(worker) => self.workers.push(LimitsWorker {
                generation,
                cancelled,
                completion: crate::agent::WorkerCompletion::observe(worker),
            }),
            Err(_) => {
                self.complete(generation, 0, Err(Failure::ReadFailed));
            }
        }
        self.status(&id)
    }
    fn complete(&mut self, generation: u64, at: u64, result: Result<Limits, Failure>) -> bool {
        match &mut self.current {
            Some(current) if current.generation == generation && current.outcome.is_none() => {
                current.observed_at_epoch_ms = (at > 0).then_some(at);
                current.outcome = Some(result);
                true
            }
            _ => false,
        }
    }
    pub(super) fn poll(&mut self) -> bool {
        let mut changed = false;
        let receive = |owner: &mut Self, changed: &mut bool| {
            for (generation, at, result) in owner.rx.try_iter().collect::<Vec<_>>() {
                *changed |= owner.complete(generation, at, result);
            }
        };
        receive(self, &mut changed);
        let mut exited = Vec::new();
        self.workers.retain(|worker| {
            use crate::agent::WorkerThreadStatus;
            let counter = match worker.completion.status() {
                WorkerThreadStatus::Running | WorkerThreadStatus::Unclassified => return true,
                WorkerThreadStatus::Returned => &mut self.totals.returned,
                WorkerThreadStatus::Panicked => &mut self.totals.panicked,
            };
            *counter = counter.saturating_add(1);
            exited.push(worker.generation);
            false
        });
        // A worker may publish between the first pass and its join acknowledgement.
        receive(self, &mut changed);
        for generation in exited {
            changed |= self.complete(generation, 0, Err(Failure::ReadFailed));
        }
        changed
    }
    pub(super) fn status(&self, id: &str) -> anyhow::Result<Value> {
        let current = self
            .current
            .as_ref()
            .filter(|current| current.id == id)
            .ok_or_else(|| anyhow::anyhow!("Claude limits request not found or superseded"))?;
        let (state, limits, error) = match &current.outcome {
            None => ("loading", None, None),
            Some(Ok(limits)) => ("ready", Some(limits), None),
            Some(Err(failure)) => ("failed", None, Some(*failure)),
        };
        Ok(
            json!({"requestId":id,"provider":"claude","accountScope":"default_runtime_account_identity_unknown","accountIdentityVerified":false,
            "state":state,"generation":current.generation,"observedAtEpochMs":current.observed_at_epoch_ms,"limits":limits,"error":error}),
        )
    }
    pub(super) fn request_shutdown(&mut self) {
        self.closed = true;
        self.cancel_workers();
        self.current = None;
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
/// Deliberately no provider, account, path or trust arguments are accepted.
pub(crate) fn validate_refresh(params: &Value) -> anyhow::Result<()> {
    anyhow::ensure!(
        params.as_object().is_some_and(|p| p.is_empty()),
        "Claude limits refresh requires an empty object"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::time::{Duration, Instant};

    struct Scripted {
        sent: Vec<Value>,
        frames: VecDeque<Value>,
    }
    impl Frames for Scripted {
        fn send(&mut self, value: &Value) -> Result<(), Failure> {
            self.sent.push(value.clone());
            Ok(())
        }
        fn next(&mut self) -> Result<Value, Failure> {
            self.frames.pop_front().ok_or(Failure::ReadFailed)
        }
    }
    fn reply(id: &str, response: Value) -> Value {
        json!({"type":"control_response","response":{"request_id":id,"subtype":"success","response":response}})
    }
    fn usage() -> Value {
        json!({"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":12}}})
    }

    #[test]
    fn reads_get_usage_after_initialize_skipping_status_frames() {
        let mut rpc = Scripted {
            sent: Vec::new(),
            frames: VecDeque::from([
                json!({"type":"system","subtype":"init"}),
                reply(INITIALIZE, json!({"models":[]})),
                json!({"type":"rate_limit_event","rate_limit_info":{}}),
                reply(USAGE, usage()),
            ]),
        };
        let limits = protocol(&mut rpc).unwrap();
        assert_eq!(limits.windows[0].id, "five_hour");
        assert_eq!(rpc.sent[0]["request"]["subtype"], "initialize");
        assert_eq!(
            rpc.sent[1]["request"],
            json!({"subtype":"get_usage","skip_behaviors":true})
        );
        assert!(rpc.sent.iter().all(|sent| sent.get("message").is_none()));
    }

    #[test]
    fn refusals_actions_and_mismatched_ids_never_become_limits() {
        let refused = json!({"type":"control_response","response":{"request_id":USAGE,"subtype":"error","error":"unknown"}});
        for (frames, failure) in [
            (
                vec![reply(INITIALIZE, json!({})), refused],
                Failure::NoReportedLimits,
            ),
            (
                vec![
                    reply(INITIALIZE, json!({})),
                    reply(USAGE, json!({"rate_limits_available":false})),
                ],
                Failure::NoReportedLimits,
            ),
            (
                vec![json!({"type":"control_request","request":{"subtype":"can_use_tool"}})],
                Failure::InvalidResponse,
            ),
            (vec![reply("other", json!({}))], Failure::InvalidResponse),
            (
                vec![reply(INITIALIZE, json!({})), reply(USAGE, json!([]))],
                Failure::InvalidResponse,
            ),
            (vec![], Failure::ReadFailed),
        ] {
            let mut rpc = Scripted {
                sent: Vec::new(),
                frames: frames.into(),
            };
            assert_eq!(protocol(&mut rpc), Err(failure));
        }
    }

    fn settle(owner: &mut Owner, id: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            owner.poll();
            let status = owner.status(id).unwrap();
            if status["state"] != "loading" {
                return status;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn newer_reads_supersede_and_failures_clear_without_fallback() {
        let mut owner = Owner::default();
        let first = owner
            .refresh_with(None, |_, _| {
                claude::limits_from_usage(&usage(), chrono::Utc::now())
                    .ok_or(Failure::InvalidResponse)
            })
            .unwrap();
        let id = first["requestId"].as_str().unwrap().to_owned();
        let ready = settle(&mut owner, &id);
        assert_eq!(ready["state"], "ready");
        assert_eq!(ready["limits"]["windows"][0]["id"], "five_hour");
        assert_eq!(ready["accountIdentityVerified"], false);
        let second = owner
            .refresh_with(None, |_, _| Err(Failure::UnavailableExecutable))
            .unwrap();
        assert!(owner.status(&id).is_err());
        let failed = settle(&mut owner, second["requestId"].as_str().unwrap());
        assert_eq!(failed["state"], "failed");
        assert_eq!(failed["error"], "unavailable_executable");
        assert!(failed["limits"].is_null());
        owner.request_shutdown();
        assert!(
            owner
                .refresh_with(None, |_, _| Err(Failure::ReadFailed))
                .is_err()
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        while owner.shutdown_status().running > 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(owner.shutdown_status().returned, 2);
    }

    #[test]
    fn refresh_accepts_no_parameters() {
        assert!(validate_refresh(&json!({})).is_ok());
        assert!(validate_refresh(&json!({"executable":"/bin/sh"})).is_err());
        assert!(validate_refresh(&json!(null)).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn fake_claude_process_answers_without_a_prompt() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("requests");
        let script = dir.path().join("claude");
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
IFS= read -r line
printf '%s\n' "$line" >> '{log}'
printf '%s\n' '{{"type":"control_response","response":{{"request_id":"{INITIALIZE}","subtype":"success","response":{{}}}}}}'
IFS= read -r line
printf '%s\n' "$line" >> '{log}'
printf '%s\n' '{{"type":"control_response","response":{{"request_id":"{USAGE}","subtype":"success","response":{{"rate_limits_available":true,"rate_limits":{{"seven_day":{{"utilization":33}}}}}}}}}}'
sleep 5
"#,
                log = log.display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let limits = read(Some(script), &AtomicBool::new(false)).unwrap();
        assert_eq!(limits.windows[0].id, "seven_day");
        assert_eq!(limits.windows[0].used_percent, 33.);
        let requests = std::fs::read_to_string(log).unwrap();
        assert_eq!(requests.lines().count(), 2);
        assert!(!requests.contains("\"message\""));
        assert_eq!(
            read(None, &AtomicBool::new(false)),
            Err(Failure::UnavailableExecutable)
        );
    }
}
