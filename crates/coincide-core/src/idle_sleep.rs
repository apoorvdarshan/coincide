//! Rust-owned opt-in for temporary idle inhibition, not Swift's privileged
//! always-on/lid/battery settings. Construction and disabled startup have no effects.
use super::*;
use crate::platform_host::{
    power::AwakePolicy,
    runtime::{HostRuntime, LeaseState, PendingShutdown, Phase, Settings, ShutdownStatus},
};
use std::sync::atomic::{AtomicUsize, Ordering};

const DOCUMENT: &str = "rust-idle-sleep.json";
fn policy_json(policy: AwakePolicy) -> Value {
    json!({"enabled":policy.enabled,"activeTurns":policy.active_turns,"backgroundJobs":policy.background_jobs})
}
pub(super) struct BackgroundJob(Arc<AtomicUsize>);
impl Drop for BackgroundJob {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}
pub(super) struct IdleSleep {
    enabled: bool,
    jobs: Arc<AtomicUsize>,
    runtime: Option<HostRuntime>,
    shutdown_requested: bool,
    pending_shutdown: Option<PendingShutdown>,
    requested: AwakePolicy,
    submitted: Option<AwakePolicy>,
    error: Option<String>,
    retry_after: Option<Instant>,
    factory: Box<dyn Fn() -> Result<HostRuntime> + Send>,
}
/// Trusted Engine-owner observation; this is not a JSON shutdown authority.
#[derive(Debug, Clone)]
pub struct IdleShutdownStatus {
    pub requested: bool,
    pub worker_started: bool,
    pub joined: bool,
    pub phase: Option<Phase>,
    pub lease: LeaseState,
    pub error: Option<String>,
}
impl IdleShutdownStatus {
    pub fn ready(&self) -> bool {
        self.requested
            && (!self.worker_started
                || (self.joined
                    && self.phase == Some(Phase::Stopped)
                    && self.lease == LeaseState::Released
                    && self.error.is_none()))
    }
}
impl IdleSleep {
    pub fn new(store: &Store) -> Self {
        let loaded = (|| -> Result<bool> {
            let Some(document) = store.local_document(DOCUMENT)? else {
                return Ok(false);
            };
            ensure!(
                document["version"] == 1,
                "Unsupported idle-sleep configuration"
            );
            document["enabled"]
                .as_bool()
                .context("Invalid idle-sleep opt-in")
        })();
        let (enabled, error) = match loaded {
            Ok(enabled) => (enabled, None),
            Err(error) => (false, Some(error.to_string())),
        };
        Self {
            enabled,
            jobs: Arc::new(AtomicUsize::new(0)),
            runtime: None,
            shutdown_requested: false,
            pending_shutdown: None,
            requested: AwakePolicy::default(),
            submitted: None,
            error,
            retry_after: None,
            factory: Box::new(|| {
                HostRuntime::spawn_native(Settings {
                    allow_inhibition: true,
                    ..Settings::default()
                })
            }),
        }
    }
    pub fn request_shutdown(&mut self) {
        if self.shutdown_requested {
            return;
        }
        self.shutdown_requested = true;
        self.requested.enabled = false;
        self.pending_shutdown = self.runtime.take().map(HostRuntime::into_pending_shutdown);
    }
    pub fn poll_shutdown(&mut self) -> IdleShutdownStatus {
        let current: Option<ShutdownStatus> = self
            .pending_shutdown
            .as_ref()
            .map(PendingShutdown::poll)
            .or_else(|| {
                self.runtime.as_ref().map(|runtime| ShutdownStatus {
                    joined: false,
                    status: runtime.handle().status(),
                })
            });
        IdleShutdownStatus {
            requested: self.shutdown_requested,
            worker_started: current.is_some() || self.runtime.is_some(),
            joined: current.as_ref().is_some_and(|s| s.joined),
            phase: current.as_ref().map(|s| s.status.phase),
            lease: current
                .as_ref()
                .map_or(LeaseState::Released, |s| s.status.lease),
            error: current.and_then(|s| s.status.error),
        }
    }
    pub fn background_job(&self) -> BackgroundJob {
        self.jobs.fetch_add(1, Ordering::SeqCst);
        BackgroundJob(self.jobs.clone())
    }
    pub fn update(&mut self, active_turns: usize, shutdown: bool) {
        if self.shutdown_requested {
            return;
        }
        self.requested = AwakePolicy {
            enabled: self.enabled && !shutdown,
            active_turns,
            background_jobs: self.jobs.load(Ordering::SeqCst),
            ..AwakePolicy::default()
        };
        if self.runtime.is_none() && self.requested.needs_lease() {
            if self
                .retry_after
                .is_some_and(|deadline| Instant::now() < deadline)
            {
                return;
            }
            match (self.factory)() {
                Ok(runtime) => {
                    self.runtime = Some(runtime);
                    self.submitted = None;
                    self.error = None;
                    self.retry_after = None;
                }
                Err(error) => {
                    self.error = Some(error.to_string().chars().take(1024).collect());
                    self.retry_after = Some(Instant::now() + Duration::from_secs(5));
                    return;
                }
            }
        }
        if let Some(runtime) = &self.runtime
            && self.submitted != Some(self.requested)
        {
            match runtime.handle().submit(self.requested) {
                Ok(_) => {
                    self.submitted = Some(self.requested);
                    self.error = None;
                }
                Err(error) => self.error = Some(error.to_string()),
            }
        }
    }
    pub fn status(&self) -> Value {
        let mut status = json!({"enabled":self.enabled,"supported":cfg!(any(target_os="macos",target_os="linux",target_os="windows")),
            "scope":"idle_sleep_during_work","configurationSource":"rust_owned","workerStarted":self.runtime.is_some() || self.pending_shutdown.is_some(),
            "requestedPolicy":policy_json(self.requested),"phase":"idle","lease":"released",
            "requestedRevision":0,"processedRevision":null,"acknowledgedRevision":null,"acknowledgedPolicy":null,
            "error":self.error,"batteryMonitoring":false,"persistentPowerSettings":false,
            "remaining":["lid_closed_operation","battery_policy","external_jobs_after_provider_completion"]});
        let current = self
            .runtime
            .as_ref()
            .map(|runtime| runtime.handle().status())
            .or_else(|| {
                self.pending_shutdown
                    .as_ref()
                    .map(|pending| pending.poll().status)
            });
        if let Some(current) = current {
            status["phase"] = json!(match current.phase {
                Phase::Starting => "starting",
                Phase::Applying => "applying",
                Phase::Waiting => "waiting",
                Phase::Stopping => "stopping",
                Phase::Stopped => "stopped",
            });
            status["lease"] = json!(match current.lease {
                LeaseState::Released => "released",
                LeaseState::Held => "held",
                LeaseState::Unknown => "unknown",
            });
            status["requestedRevision"] = json!(current.requested_revision);
            status["processedRevision"] = json!(current.processed_revision);
            status["acknowledgedRevision"] = json!(current.acknowledged_revision);
            status["acknowledgedPolicy"] = current
                .acknowledged_policy
                .map(policy_json)
                .unwrap_or(Value::Null);
            if current.error.is_some() {
                status["error"] = json!(current.error);
            }
        }
        status
    }
}
impl Engine {
    pub(super) fn awake_command(&mut self, method: &str, params: &Value) -> Result<Value> {
        match method {
            "host.awake.status" => {}
            "host.awake.configure" => {
                let params = params
                    .as_object()
                    .context("Idle-sleep params must be an object")?;
                ensure!(
                    params.len() == 1 && params.contains_key("enabled"),
                    "Specify only the enabled opt-in"
                );
                let enabled = params["enabled"]
                    .as_bool()
                    .context("enabled must be a boolean")?;
                ensure!(
                    !enabled || cfg!(any(target_os = "macos", target_os = "linux")),
                    "Idle-sleep inhibition is unavailable on this platform"
                );
                let mut document = self.store.local_document(DOCUMENT)?.unwrap_or(json!({}));
                ensure!(document.is_object(), "Invalid idle-sleep configuration");
                document["version"] = json!(1);
                document["enabled"] = json!(enabled);
                self.store.save_document(DOCUMENT, &document)?;
                self.idle_sleep.enabled = enabled;
                self.idle_sleep.error = None;
                self.idle_sleep.retry_after = None;
                self.revision += 1;
            }
            _ => bail!("Unknown idle-sleep command"),
        }
        self.idle_sleep.update(self.runs.len(), self.shutdown);
        Ok(self.idle_sleep.status())
    }
}

#[cfg(test)]
#[path = "idle_sleep_tests.rs"]
mod tests;
