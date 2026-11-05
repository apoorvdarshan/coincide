//! Rust-owned opt-in for temporary idle inhibition, not Swift's privileged
//! always-on/lid/battery settings. Construction and disabled startup have no effects.
use super::*;
use crate::platform_host::{
    power::AwakePolicy,
    runtime::{HostRuntime, LeaseState, Phase, Settings},
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
    requested: AwakePolicy,
    submitted: Option<AwakePolicy>,
    error: Option<String>,
    retry_after: Option<Instant>,
    factory: Box<dyn Fn() -> Result<HostRuntime> + Send>,
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
    pub fn background_job(&self) -> BackgroundJob {
        self.jobs.fetch_add(1, Ordering::SeqCst);
        BackgroundJob(self.jobs.clone())
    }
    pub fn update(&mut self, active_turns: usize, shutdown: bool) {
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
        let mut status = json!({"enabled":self.enabled,"supported":cfg!(any(target_os="macos",target_os="linux")),
            "scope":"idle_sleep_during_work","configurationSource":"rust_owned","workerStarted":self.runtime.is_some(),
            "requestedPolicy":policy_json(self.requested),"phase":"idle","lease":"released",
            "requestedRevision":0,"processedRevision":null,"acknowledgedRevision":null,"acknowledgedPolicy":null,
            "error":self.error,"batteryMonitoring":false,"persistentPowerSettings":false,
            "remaining":["lid_closed_operation","battery_policy","external_jobs_after_provider_completion"]});
        if let Some(runtime) = &self.runtime {
            let current = runtime.handle().status();
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
