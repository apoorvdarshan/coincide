use super::*;
use crate::platform_host::power::SleepInhibitor;
use std::sync::atomic::AtomicBool;

#[derive(Clone, Default)]
struct Probe {
    starts: Arc<AtomicUsize>,
    acquires: Arc<AtomicUsize>,
    held: Arc<AtomicBool>,
    fail: Arc<AtomicBool>,
}
impl SleepInhibitor for Probe {
    fn acquire(&mut self) -> Result<()> {
        self.acquires.fetch_add(1, Ordering::SeqCst);
        ensure!(
            !self.fail.load(Ordering::SeqCst),
            "synthetic acquire failure"
        );
        self.held.store(true, Ordering::SeqCst);
        Ok(())
    }
    fn release(&mut self) -> Result<()> {
        self.held.store(false, Ordering::SeqCst);
        Ok(())
    }
}
fn injected(engine: &mut Engine) -> Probe {
    let probe = Probe::default();
    let backend = probe.clone();
    engine.idle_sleep.factory = Box::new(move || {
        backend.starts.fetch_add(1, Ordering::SeqCst);
        HostRuntime::spawn(
            backend.clone(),
            Settings {
                allow_inhibition: true,
                tick_interval: Duration::from_millis(10),
            },
        )
    });
    probe
}
fn processed(state: &IdleSleep) -> crate::platform_host::runtime::Status {
    let handle = state.runtime.as_ref().unwrap().handle();
    let revision = handle.status().requested_revision;
    let status = handle.wait_processed(revision, Duration::from_secs(2));
    assert_eq!(status.processed_revision, Some(revision));
    status
}
fn engine() -> (tempfile::TempDir, Engine) {
    let directory = tempfile::tempdir().unwrap();
    let engine = Engine::new(Store::open(&directory.path().join("store.sqlite")).unwrap());
    (directory, engine)
}

#[test]
fn disabled_and_imported_opt_ins_never_start_worker_or_native_backend() {
    let (directory, mut engine) = engine();
    let probe = injected(&mut engine);
    let activity = engine.idle_sleep.background_job();
    engine.idle_sleep.update(3, false);
    assert_eq!(engine.idle_sleep.status()["workerStarted"], false);
    assert_eq!(probe.starts.load(Ordering::SeqCst), 0);
    drop(activity);
    let source = directory.path().join("original");
    std::fs::create_dir_all(source.join("threads")).unwrap();
    std::fs::write(source.join(DOCUMENT), br#"{"version":1,"enabled":true}"#).unwrap();
    std::fs::write(
        source.join("settings.json"),
        br#"{"alwaysOn":{"enabled":true}}"#,
    )
    .unwrap();
    engine.store.import_legacy(&source).unwrap();
    let mut reopened = Engine::new(Store::open(&directory.path().join("store.sqlite")).unwrap());
    let probe = injected(&mut reopened);
    reopened.idle_sleep.update(5, false);
    assert_eq!(reopened.idle_sleep.status()["enabled"], false);
    assert_eq!(probe.starts.load(Ordering::SeqCst), 0);
    assert!(reopened.store.local_document(DOCUMENT).unwrap().is_none());
}

#[test]
fn opt_in_requires_valid_boolean_and_does_not_reuse_imported_settings() {
    let (directory, mut engine) = engine();
    let probe = injected(&mut engine);
    for params in [
        json!({}),
        json!({"enabled":"true"}),
        json!({"enabled":true,"persistent":true}),
    ] {
        assert!(engine.execute("host.awake.configure", &params).is_err());
    }
    assert_eq!(probe.starts.load(Ordering::SeqCst), 0);
    assert!(engine.store.local_document(DOCUMENT).unwrap().is_none());
    if cfg!(any(target_os = "macos", target_os = "linux")) {
        let result = engine
            .execute("host.awake.configure", &json!({"enabled":true}))
            .unwrap();
        assert_eq!(result["enabled"], true);
        assert_eq!(
            result["workerStarted"], false,
            "idle opt-in must not launch anything"
        );
        drop(engine);
        let mut reopened =
            Engine::new(Store::open(&directory.path().join("store.sqlite")).unwrap());
        let probe = injected(&mut reopened);
        assert_eq!(
            reopened.execute("host.awake.status", &json!({})).unwrap()["enabled"],
            true
        );
        assert_eq!(probe.starts.load(Ordering::SeqCst), 0);
    } else {
        assert!(
            engine
                .execute("host.awake.configure", &json!({"enabled":true}))
                .is_err()
        );
    }
}

#[test]
fn activity_lifetime_drives_acknowledged_policy_and_release_without_result_polling() {
    let (_directory, mut engine) = engine();
    let probe = injected(&mut engine);
    // Internal injected backend on every platform; no native configure/acquire.
    engine.idle_sleep.enabled = true;
    let activity = engine.idle_sleep.background_job();
    engine.idle_sleep.update(2, false);
    let status = processed(&engine.idle_sleep);
    assert_eq!(status.lease, LeaseState::Held);
    assert_eq!(status.acknowledged_policy.unwrap().active_turns, 2);
    assert_eq!(status.acknowledged_policy.unwrap().background_jobs, 1);
    engine.idle_sleep.update(0, false);
    assert_eq!(
        processed(&engine.idle_sleep).lease,
        LeaseState::Held,
        "background work survives turn completion"
    );
    drop(activity);
    engine.idle_sleep.update(0, false);
    assert_eq!(processed(&engine.idle_sleep).lease, LeaseState::Released);
    assert!(!probe.held.load(Ordering::SeqCst));
    assert_eq!(probe.starts.load(Ordering::SeqCst), 1);
    assert_eq!(probe.acquires.load(Ordering::SeqCst), 1);
    engine.idle_sleep.update(1, false);
    assert_eq!(processed(&engine.idle_sleep).lease, LeaseState::Held);
    // Explicit shutdown releases even if active work still exists.
    engine.idle_sleep.update(1, true);
    assert_eq!(processed(&engine.idle_sleep).lease, LeaseState::Released);
}

#[test]
fn acquire_failure_is_visible_unacknowledged_and_timer_retries_without_new_commands() {
    let (_directory, mut engine) = engine();
    let probe = injected(&mut engine);
    probe.fail.store(true, Ordering::SeqCst);
    engine.idle_sleep.enabled = true;
    let activity = engine.idle_sleep.background_job();
    engine.idle_sleep.update(0, false);
    let status = processed(&engine.idle_sleep);
    assert_eq!(status.lease, LeaseState::Unknown);
    assert_ne!(
        status.acknowledged_revision,
        Some(status.requested_revision)
    );
    assert!(
        engine.idle_sleep.status()["error"]
            .as_str()
            .unwrap()
            .contains("synthetic")
    );
    probe.fail.store(false, Ordering::SeqCst);
    let deadline = Instant::now() + Duration::from_secs(2);
    while engine.idle_sleep.status()["lease"] != "held" {
        assert!(Instant::now() < deadline, "timer did not recover");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(engine.idle_sleep.status()["error"].is_null());
    drop(activity);
    drop(engine);
    assert!(
        !probe.held.load(Ordering::SeqCst),
        "Engine drop must release its worker lease"
    );
}
