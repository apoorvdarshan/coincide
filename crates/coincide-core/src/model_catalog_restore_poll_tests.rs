//! A completion may arrive between an Engine's ready lookup and admission.
//! Restoration observes that exact result; explicit Refresh still replaces it.
use super::*;
use crate::codex_login_profiles::LaunchContext;

fn fixture() -> (
    tempfile::TempDir,
    NamedBinding,
    ModelCatalog,
    Arc<AtomicBool>,
) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("private-model-restore");
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
    }
    #[cfg(windows)]
    crate::private_fs::windows::create_directory(&root).unwrap();
    let root = root.canonicalize().unwrap();
    let account = uuid::Uuid::new_v4().to_string();
    crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
    let executable = root.join("synthetic-file-never-executed");
    std::fs::write(&executable, b"synthetic executable metadata").unwrap();
    let profile = LaunchContext::capture(&root, &account, &executable).unwrap();
    let binding = NamedBinding::capture(profile, &uuid::Uuid::new_v4().to_string(), &root).unwrap();
    let cancelled = Arc::new(AtomicBool::new(false));
    let mut catalog = ModelCatalog::default();
    catalog.jobs.insert("existing".into(), Job {
        named:Some(binding.clone()), binding:None, cancelled:cancelled.clone(),
        response:json!({"provider":"codex","requestId":"existing","state":"loading","authenticationChecked":false,"models":[]}),
    });
    catalog.order.push_back("existing".into());
    (dir, binding, catalog, cancelled)
}
fn finish(catalog: &mut ModelCatalog, id: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        catalog.poll();
        if catalog.workers.is_empty() {
            assert_eq!(catalog.jobs[id].response["state"], "ready");
            return;
        }
        assert!(
            Instant::now() < deadline,
            "Actual model metadata worker did not return"
        );
        std::thread::yield_now();
    }
}
#[test]
fn completion_between_lookup_and_refresh_reuses_exact_authenticated_actor() {
    let (_dir, binding, mut catalog, cancelled) = fixture();
    assert!(catalog.ready_named_restore(&binding).is_none());
    // Deterministically occupy the exact poll gap: the response is queued but
    // not visible to the earlier Engine lookup until the refresh polls it.
    catalog
        .tx
        .send(("existing".into(), Ok(vec![json!({"id":"synthetic-model"})])))
        .unwrap();
    let result = catalog.refresh_named_restore(binding, false).unwrap();
    assert_eq!(result["requestId"], "existing");
    assert_eq!(result["state"], "ready");
    assert_eq!(result["authenticationChecked"], true);
    assert!(!cancelled.load(Ordering::Acquire));
    assert!(
        catalog.workers.is_empty(),
        "Restoration must not launch a replacement worker"
    );
    assert_eq!(catalog.order.len(), 1);
}
#[test]
fn loading_observation_can_be_reused_without_starting_or_revoking_any_worker() {
    let (_dir, binding, mut catalog, cancelled) = fixture();
    let result = catalog.refresh_named_restore(binding, false).unwrap();
    assert_eq!(result["requestId"], "existing");
    assert_eq!(result["state"], "loading");
    assert_eq!(result["authenticationChecked"], false);
    assert!(!cancelled.load(Ordering::Acquire));
    assert!(catalog.workers.is_empty());
}
#[test]
fn explicit_refresh_and_private_force_fresh_never_reuse_ready_or_revoked_actors() {
    for (reuse, revoked) in [
        (RefreshReuse::Loading, false),
        (RefreshReuse::Never, false),
        (RefreshReuse::AuthenticatedReadyOrLoading, true),
    ] {
        let (_dir, binding, mut catalog, cancelled) = fixture();
        catalog
            .tx
            .send(("existing".into(), Ok(vec![json!({"id":"synthetic-model"})])))
            .unwrap();
        catalog.poll();
        cancelled.store(revoked, Ordering::Release);
        // Inject metadata work instead of invoking an actual provider process.
        let result = catalog
            .refresh_scoped_reusing("codex", None, Some(binding), reuse, |_| {
                Ok(vec![json!({"id":"synthetic-model"})])
            })
            .unwrap();
        let id = result["requestId"].as_str().unwrap();
        assert_ne!(id, "existing");
        assert!(cancelled.load(Ordering::Acquire));
        finish(&mut catalog, id);
        assert_eq!(catalog.shutdown_status().returned, 1);
    }
}
#[test]
fn private_force_fresh_also_bypasses_a_loading_departure_actor() {
    let (_dir, binding, mut catalog, cancelled) = fixture();
    let result = catalog
        .refresh_scoped_reusing("codex", None, Some(binding), RefreshReuse::Never, |_| {
            Ok(vec![json!({"id":"synthetic-model"})])
        })
        .unwrap();
    let id = result["requestId"].as_str().unwrap();
    assert_ne!(id, "existing");
    assert!(cancelled.load(Ordering::Acquire));
    finish(&mut catalog, id);
}
