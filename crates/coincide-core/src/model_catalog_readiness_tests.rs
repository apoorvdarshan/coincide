//! The automatic native warmup retries a changed launch context without
//! restarting for draft writes or changes to the catalog's transient actor.
use super::*;
use std::io::Write;

fn fixture() -> (tempfile::TempDir, PathBuf, NamedBinding) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("private-data");
    crate::native_file::private_directory(&root).unwrap();
    let root = root.canonicalize().unwrap();
    let account = uuid::Uuid::new_v4().to_string();
    crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
    let executable = root.join("synthetic-executable");
    fs::write(&executable, b"synthetic executable metadata").unwrap();
    let profile = LaunchContext::capture(&root, &account, &executable).unwrap();
    let binding = NamedBinding::capture(profile, &uuid::Uuid::new_v4().to_string(), &root).unwrap();
    (dir, root, binding)
}

fn recapture(root: &Path, prior: &NamedBinding) -> NamedBinding {
    let profile =
        LaunchContext::capture(root, prior.account(), prior.profile.executable()).unwrap();
    NamedBinding::capture(profile, prior.thread(), &prior.cwd).unwrap()
}

#[test]
fn draft_store_and_catalog_actor_changes_do_not_restart_automatic_warmup() {
    let (_dir, root, binding) = fixture();
    let generation = binding.readiness_generation().unwrap();
    let mut store = crate::store::Store::open(&root.join("state.sqlite")).unwrap();
    for draft in ["typing", "typing more"] {
        store
            .save_document("synthetic-draft.json", &json!({"draft":draft}))
            .unwrap();
        assert_eq!(
            recapture(&root, &binding).readiness_generation().unwrap(),
            generation
        );
    }
    let mut catalog = ModelCatalog::default();
    let mut previous_actor = None;
    for request in ["first", "replacement"] {
        let cancelled = Arc::new(AtomicBool::new(false));
        if let Some(prior) = previous_actor.replace(cancelled.clone()) {
            let prior: Arc<AtomicBool> = prior;
            prior.store(true, Ordering::Release);
        }
        catalog.jobs.insert(request.into(), Job {
            named:Some(binding.clone()), binding:None, cancelled,
            response:json!({"requestId":request,"state":"ready","authenticationChecked":true,"models":[]}),
        });
        catalog.order.push_back(request.into());
        assert_eq!(
            recapture(&root, &binding).readiness_generation().unwrap(),
            generation
        );
    }
}

#[test]
fn auth_instructions_executable_and_project_changes_get_a_new_warmup_key() {
    let (_dir, root, mut binding) = fixture();
    let mut generation = binding.readiness_generation().unwrap();
    let auth = binding.profile.home().join("auth.json");
    let mut auth_file = crate::native_file::create_private_file(&auth).unwrap();
    auth_file
        .write_all(b"synthetic private auth metadata, no credential")
        .unwrap();
    drop(auth_file);
    for changed_path in [
        auth,
        binding.profile.home().join("AGENTS.md"),
        root.join("AGENTS.override.md"),
        binding.profile.executable().to_owned(),
    ] {
        if changed_path
            .file_name()
            .is_some_and(|name| name != "auth.json")
        {
            fs::write(&changed_path, b"changed synthetic context, different size").unwrap();
        }
        let changed = recapture(&root, &binding);
        let next = changed.readiness_generation().unwrap();
        assert_ne!(next, generation, "Changed launch context must rearm warmup");
        assert!(
            binding.validate().is_err(),
            "The key never revives stale proof"
        );
        generation = next;
        binding = changed;
    }
    let project = root.join("other-project");
    fs::create_dir(&project).unwrap();
    let changed =
        NamedBinding::capture(binding.profile.clone(), binding.thread(), &project).unwrap();
    assert_ne!(changed.readiness_generation().unwrap(), generation);
}

#[test]
fn account_and_thread_changes_get_distinct_keys_without_exposing_paths() {
    let (_dir, root, binding) = fixture();
    let generation = binding.readiness_generation().unwrap();
    assert_eq!(generation.len(), 64);
    assert!(generation.bytes().all(|byte| byte.is_ascii_hexdigit()));
    let thread = NamedBinding::capture(
        binding.profile.clone(),
        &uuid::Uuid::new_v4().to_string(),
        &root,
    )
    .unwrap();
    assert_ne!(thread.readiness_generation().unwrap(), generation);
    let account = uuid::Uuid::new_v4().to_string();
    crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
    let profile = LaunchContext::capture(&root, &account, binding.profile.executable()).unwrap();
    let account = NamedBinding::capture(profile, binding.thread(), &root).unwrap();
    assert_ne!(account.readiness_generation().unwrap(), generation);
}
