//! Named model/effort authority stays local to one captured subscription profile.
use super::*;
use crate::codex_login_profiles::LaunchContext;
use std::{fs, path::Path, time::SystemTime};

#[derive(Clone, Debug, PartialEq, Eq)]
struct FileStamp {
    length: u64,
    modified: SystemTime,
    #[cfg(unix)]
    identity: (u64, u64),
}
impl FileStamp {
    fn read(path: &Path) -> Result<Self> {
        let metadata = fs::symlink_metadata(path)?;
        Ok(Self {
            length: metadata.len(),
            modified: metadata.modified()?,
            #[cfg(unix)]
            identity: {
                use std::os::unix::fs::MetadataExt;
                (metadata.dev(), metadata.ino())
            },
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct NamedBinding {
    pub(super) profile: LaunchContext,
    thread: String,
    pub(super) cwd: PathBuf,
    canonical_cwd: PathBuf,
    #[cfg(unix)]
    cwd_identity: (u64, u64),
    auth: Option<FileStamp>,
}
impl NamedBinding {
    pub(crate) fn capture(profile: LaunchContext, thread: &str, cwd: &Path) -> Result<Self> {
        profile.validate()?;
        ensure!(
            uuid::Uuid::parse_str(thread).is_ok(),
            "Invalid catalog thread identity"
        );
        ensure!(
            cwd.is_absolute() && cwd.is_dir(),
            "Model catalog requires the actual project directory"
        );
        let canonical_cwd = cwd.canonicalize()?;
        let auth = match FileStamp::read(&profile.home().join("auth.json")) {
            Ok(stamp) => Some(stamp),
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
            {
                None
            }
            Err(error) => return Err(error),
        };
        Ok(Self {
            profile,
            thread: thread.into(),
            cwd: cwd.into(),
            #[cfg(unix)]
            cwd_identity: {
                use std::os::unix::fs::MetadataExt;
                let metadata = fs::metadata(&canonical_cwd)?;
                (metadata.dev(), metadata.ino())
            },
            canonical_cwd,
            auth,
        })
    }
    pub(crate) fn account(&self) -> &str {
        self.profile.account()
    }
    pub(crate) fn thread(&self) -> &str {
        &self.thread
    }
    pub(super) fn validate(&self) -> Result<()> {
        self.profile.validate()?;
        ensure!(
            Self::capture(self.profile.clone(), &self.thread, &self.cwd)? == *self,
            "Codex profile, authentication file or project directory changed; refresh this profile's catalog"
        );
        Ok(())
    }
}
pub(super) fn same_scope(a: Option<&NamedBinding>, b: Option<&NamedBinding>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => a.thread == b.thread && a.account() == b.account(),
        _ => false,
    }
}
/// Cannot be constructed by caller JSON. Revocation is shared with its owned job.
#[derive(Clone, Debug)]
pub(crate) struct NamedModelProof {
    model: String,
    effort: Option<String>,
    speed: Option<String>,
    binding: NamedBinding,
    revoked: Arc<AtomicBool>,
}
impl PartialEq for NamedModelProof {
    fn eq(&self, other: &Self) -> bool {
        self.model == other.model
            && self.effort == other.effort
            && self.speed == other.speed
            && self.binding == other.binding
            && Arc::ptr_eq(&self.revoked, &other.revoked)
    }
}
impl Eq for NamedModelProof {}
impl NamedModelProof {
    pub(crate) fn validate_thread(&self, thread: &Value) -> Result<()> {
        self.validate_selection(thread, &self.binding)
    }
    pub(crate) fn validate_policy(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
        speed: Option<&str>,
    ) -> Result<()> {
        ensure!(
            !self.revoked.load(Ordering::Acquire),
            "Profile model proof was revoked; refresh the catalog"
        );
        ensure!(
            model == Some(self.model.as_str())
                && effort == self.effort.as_deref()
                && speed == self.speed.as_deref(),
            "Named model options do not match the captured policy"
        );
        self.binding.validate()
    }
    pub(crate) fn validate_executable(&self, executable: &Path) -> Result<()> {
        ensure!(
            executable == self.binding.profile.executable(),
            "Named effort executable changed"
        );
        self.validate_policy(
            Some(&self.model),
            self.effort.as_deref(),
            self.speed.as_deref(),
        )
    }
    pub(crate) fn validate_selection(&self, thread: &Value, binding: &NamedBinding) -> Result<()> {
        ensure!(
            thread["id"] == self.binding.thread
                && thread["selection"]["provider"] == "codex"
                && thread["selection"]["accountID"] == self.binding.account()
                && thread["selection"]["modelID"] == self.model
                && thread["selection"]["effort"] == json!(self.effort)
                && thread["selection"]["speed"] == json!(self.speed)
                && binding == &self.binding,
            "Named model proof belongs to another account, thread or directory"
        );
        self.validate_launch(
            &binding.profile,
            &binding.cwd,
            Some(&self.model),
            self.effort.as_deref(),
            self.speed.as_deref(),
        )
    }
    pub(crate) fn validate_launch(
        &self,
        profile: &LaunchContext,
        cwd: &Path,
        model: Option<&str>,
        effort: Option<&str>,
        speed: Option<&str>,
    ) -> Result<()> {
        ensure!(
            !self.revoked.load(Ordering::Acquire),
            "Profile model proof was revoked; refresh the catalog"
        );
        ensure!(
            profile == &self.binding.profile
                && cwd == self.binding.cwd.as_path()
                && model == Some(self.model.as_str()),
            "Named model proof does not match the captured launch"
        );
        self.validate_policy(model, effort, speed)
    }
    pub(crate) fn validate_resolved(&self, result: &Value) -> Result<()> {
        ensure!(
            result["model"] == self.model,
            "Codex resolved a different named-profile model"
        );
        Ok(())
    }
}
impl ModelCatalog {
    pub(crate) fn refresh_named(&mut self, binding: NamedBinding) -> Result<Value> {
        binding.validate()?;
        let work_binding = binding.clone();
        self.refresh_scoped("codex", None, Some(binding), move |cancelled| {
            discover_named(&work_binding, cancelled).map_err(|error| error.to_string())
        })
    }
    pub(crate) fn named_status(&self, id: &str, binding: &NamedBinding) -> Result<Value> {
        binding.validate()?;
        let job = self
            .jobs
            .get(id)
            .context("Unknown profile model catalog request")?;
        ensure!(
            job.named.as_ref() == Some(binding) && !job.cancelled.load(Ordering::Acquire),
            "Profile model catalog scope changed; refresh explicitly"
        );
        Ok(job.response.clone())
    }
    fn named_model_row(
        &self,
        thread: &Value,
        binding: &NamedBinding,
        request: Option<&str>,
    ) -> Result<(&Job, &Value)> {
        ensure!(!self.shutdown.closed, "Model catalog is shutting down");
        // Binding capture is intentionally broader for read/repair. Advertised
        // execution options must still satisfy the actual supported model shape.
        crate::codex_login_profiles::validate_model_thread(thread)?;
        binding.validate()?;
        ensure!(
            thread["id"] == binding.thread()
                && thread["selection"]["provider"] == "codex"
                && thread["selection"]["accountID"] == binding.account(),
            "Profile catalog row belongs to another thread/account"
        );
        let job = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.jobs.get(id))
            .find(|job| same_scope(job.named.as_ref(), Some(binding)))
            .context(
                "Refresh this Codex profile's model catalog before sending an explicit model",
            )?;
        ensure!(
            job.named.as_ref() == Some(binding)
                && job.response["state"] == "ready"
                && !job.cancelled.load(Ordering::Acquire)
                && job.response["authenticationChecked"] == true,
            "Latest profile model catalog is not ready or its captured context changed"
        );
        ensure!(
            request.is_none_or(|request| job.response["requestId"] == request),
            "Profile catalog request was superseded"
        );
        let model = thread["selection"]["modelID"]
            .as_str()
            .context("Invalid named model")?;
        ensure!(
            model != "default",
            "Options require an explicit profile-catalog model"
        );
        let reported = job.response["models"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["id"] == model))
            .context("Model was not reported by this profile's latest catalog")?;
        Ok((job, reported))
    }
    pub(crate) fn named_effort_capability(&self, thread: &Value, binding: &NamedBinding) -> Value {
        match self.named_model_row(thread, binding, None) {
            Ok((_, row)) => {
                let choices = row["reportedEfforts"]
                    .as_array()
                    .filter(|choices| !choices.is_empty());
                json!({"supported":choices.is_some(),"choices":choices.cloned().unwrap_or_default(),"reportedDefault":row["reportedDefaultEffort"],
                    "provenance":"named_profile_model_list","requiresExplicitModel":true,"effectiveDefault":null,
                    "reason":if choices.is_some() {Value::Null} else {json!("This profile's model did not advertise reasoning efforts")}})
            }
            Err(error) => json!({"supported":false,"choices":[],"reason":error.to_string()}),
        }
    }
    pub(crate) fn named_speed_capability(&self, thread: &Value, binding: &NamedBinding) -> Value {
        match self.named_model_row(thread, binding, None) {
            Ok((_, row)) => {
                let choices = row["reportedSpeeds"]
                    .as_array()
                    .filter(|choices| !choices.is_empty());
                json!({"supported":choices.is_some(),"choices":choices.cloned().unwrap_or_default(),
                    "provenance":"named_profile_model_list","requiresExplicitModel":true,"standard":null,
                    "reason":if choices.is_some() {Value::Null} else {json!("This profile's model did not advertise faster speeds")}})
            }
            Err(error) => json!({"supported":false,"choices":[],"reason":error.to_string()}),
        }
    }
    pub(crate) fn named_model_proof(
        &self,
        thread: &Value,
        binding: &NamedBinding,
        request: Option<&str>,
    ) -> Result<Option<NamedModelProof>> {
        ensure!(!self.shutdown.closed, "Model catalog is shutting down");
        binding.validate()?;
        crate::codex_login_profiles::validate_model_thread(thread)?;
        if thread["selection"]["modelID"] == "default" {
            return Ok(None);
        }
        let (job, reported) = self.named_model_row(thread, binding, request)?;
        let model = thread["selection"]["modelID"]
            .as_str()
            .context("Invalid named model")?;
        let effort = thread["selection"]["effort"].as_str();
        let speed = thread["selection"]["speed"].as_str();
        if let Some(effort) = effort {
            ensure!(
                reported["reportedEfforts"]
                    .as_array()
                    .is_some_and(|choices| choices
                        .iter()
                        .any(|choice| choice.as_str() == Some(effort))),
                "Effort was not advertised for this exact profile model"
            );
        }
        if let Some(speed) = speed {
            ensure!(
                speed != "default"
                    && reported["reportedSpeeds"]
                        .as_array()
                        .is_some_and(|choices| choices
                            .iter()
                            .any(|choice| choice["id"].as_str() == Some(speed))),
                "Speed was not advertised for this exact profile model; choose null for Standard"
            );
        }
        let proof = NamedModelProof {
            model: model.into(),
            effort: effort.map(str::to_owned),
            speed: speed.map(str::to_owned),
            binding: binding.clone(),
            revoked: job.cancelled.clone(),
        };
        proof.validate_selection(thread, binding)?;
        Ok(Some(proof))
    }
}
#[cfg(unix)]
pub(super) fn validate_notification(frame: &Value) -> Result<()> {
    ensure!(
        frame["method"].as_str().is_none_or(
            |method| !method.starts_with("account/") || method == "account/rateLimits/updated"
        ),
        "Codex profile authentication changed during model discovery"
    );
    Ok(())
}
#[cfg(unix)]
fn discover_named(binding: &NamedBinding, cancelled: &AtomicBool) -> Result<Vec<Value>> {
    binding.validate()?;
    let mut rpc = ProcessRpc::spawn_scoped(
        "codex",
        binding.profile.executable().into(),
        DEADLINE,
        cancelled,
        Some(binding),
    )?;
    codex_initialize(&mut rpc)?;
    const ACCOUNT: u64 = 4_000_000_001;
    rpc.write(&json!({"id":ACCOUNT,"method":"account/read","params":{"refreshToken":false}}))?;
    binding.profile.admit_account(&rpc.response(ACCOUNT)?)?;
    rpc.named_account_admitted = true;
    let models = codex_model_pages(&mut rpc)?;
    binding.validate()?;
    Ok(models)
}
#[cfg(not(unix))]
fn discover_named(_: &NamedBinding, _: &AtomicBool) -> Result<Vec<Value>> {
    bail!("Named model discovery is unsupported on this platform")
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    fn fixture() -> (tempfile::TempDir, NamedBinding, Value) {
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root = dir.path().canonicalize().unwrap();
        let account = uuid::Uuid::new_v4().to_string();
        crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
        let executable = root.join("synthetic-executable");
        fs::write(&executable, b"synthetic executable metadata").unwrap();
        let context = LaunchContext::capture(&root, &account, &executable).unwrap();
        let thread = uuid::Uuid::new_v4().to_string();
        let binding = NamedBinding::capture(context, &thread, &root).unwrap();
        let document = json!({"id":thread,"selection":{"provider":"codex","modelID":"synthetic-a","accountID":account}});
        (dir, binding, document)
    }
    fn ready(catalog: &mut ModelCatalog, binding: NamedBinding, id: &str) {
        catalog.jobs.insert(id.into(),Job { binding:None,named:Some(binding.clone()),response:json!({"requestId":id,"provider":"codex","accountID":binding.account(),"threadId":binding.thread(),"authenticationChecked":true,"state":"ready","models":[{"id":"synthetic-a"}]}),cancelled:Arc::new(AtomicBool::new(false)) });
        catalog.order.push_back(id.into());
    }
    #[test]
    fn named_model_proof_is_bound_to_account_thread_cwd_auth_generation_and_job() {
        let (_dir, binding, document) = fixture();
        let mut catalog = ModelCatalog::default();
        ready(&mut catalog, binding.clone(), "a");
        let proof = catalog
            .named_model_proof(&document, &binding, Some("a"))
            .unwrap()
            .unwrap();
        proof.validate_selection(&document, &binding).unwrap();
        let mut changed = document.clone();
        changed["id"] = json!(uuid::Uuid::new_v4());
        assert!(proof.validate_selection(&changed, &binding).is_err());
        changed = document.clone();
        changed["selection"]["accountID"] = json!(uuid::Uuid::new_v4());
        assert!(proof.validate_selection(&changed, &binding).is_err());
        changed = document.clone();
        changed["selection"]["accountID"] = json!("default");
        assert!(proof.validate_selection(&changed, &binding).is_err());
        let nested = binding.cwd.join("other-cwd");
        fs::create_dir(&nested).unwrap();
        let other =
            NamedBinding::capture(binding.profile.clone(), binding.thread(), &nested).unwrap();
        assert!(catalog.named_model_proof(&document, &other, None).is_err());
        assert!(
            proof
                .validate_launch(&binding.profile, &nested, Some("synthetic-a"), None, None)
                .is_err()
        );
        assert!(
            proof
                .validate_resolved(&json!({"model":"synthetic-b"}))
                .is_err()
        );
        assert!(
            catalog
                .named_model_proof(&document, &binding, Some("wrong-job"))
                .is_err()
        );
        let auth = binding.profile.home().join("auth.json");
        fs::write(&auth, b"synthetic auth marker, not credentials").unwrap();
        fs::set_permissions(auth, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(proof.validate_selection(&document, &binding).is_err());
        fs::remove_file(binding.profile.home().join("auth.json")).unwrap();
        proof.validate_selection(&document, &binding).unwrap();
        fs::write(
            binding.profile.executable(),
            b"changed executable metadata, longer than the original",
        )
        .unwrap();
        assert!(proof.validate_selection(&document, &binding).is_err());
    }
    #[test]
    fn named_proofs_never_authorize_default_effort_and_honor_revocation() {
        let (_dir, binding, document) = fixture();
        let mut catalog = ModelCatalog::default();
        ready(&mut catalog, binding.clone(), "a");
        let proof = catalog
            .named_model_proof(&document, &binding, None)
            .unwrap()
            .unwrap();
        // A distinct named scope remains distinct even with the same provider.
        let mut other = binding.clone();
        other.thread = uuid::Uuid::new_v4().to_string();
        ready(&mut catalog, other, "b");
        proof.validate_selection(&document, &binding).unwrap();
        let default = json!({"provider":"codex","modelID":"synthetic-a","effort":"high"});
        assert!(
            catalog
                .codex_effort_proof(&default, binding.profile.executable())
                .is_err()
        );
        catalog.jobs["a"].cancelled.store(true, Ordering::Release);
        assert!(proof.validate_selection(&document, &binding).is_err());
        assert!(
            catalog
                .named_model_proof(&document, &binding, None)
                .is_err()
        );
        catalog.request_shutdown();
        assert!(catalog.refresh_named(binding).is_err());
    }
    #[test]
    fn named_speed_binds_combined_options_policy_and_revocation() {
        let (_dir, binding, mut document) = fixture();
        let mut catalog = ModelCatalog::default();
        ready(&mut catalog, binding.clone(), "speed-a");
        catalog.jobs.get_mut("speed-a").unwrap().response["models"] = json!([
            {"id":"synthetic-a","reportedEfforts":["high"],
             "reportedSpeeds":[{"id":"priority","name":"Fast"}]}
        ]);
        document["selection"]["effort"] = json!("high");
        document["selection"]["speed"] = json!("priority");
        document["accessMode"] = json!("approval");
        document["interactionMode"] = json!("build");
        let proof = catalog
            .named_model_proof(&document, &binding, Some("speed-a"))
            .unwrap()
            .unwrap();
        let policy = crate::composer_policy::Policy::parse_named(
            &document,
            crate::composer_policy::Origin::Ordinary,
            Some(&proof),
        )
        .unwrap();
        policy.preflight().unwrap();
        assert_eq!(policy.codex_effort(), Some("high"));
        assert_eq!(policy.codex_speed(), Some("priority"));
        assert!(
            proof
                .validate_policy(Some("synthetic-a"), Some("high"), None)
                .is_err()
        );
        assert!(
            proof
                .validate_policy(Some("synthetic-a"), None, Some("priority"))
                .is_err()
        );
        proof
            .validate_launch(
                &binding.profile,
                &binding.cwd,
                Some("synthetic-a"),
                Some("high"),
                Some("priority"),
            )
            .unwrap();
        assert_eq!(
            catalog.named_speed_capability(&document, &binding)["choices"],
            json!([{"id":"priority","name":"Fast"}])
        );
        assert!(
            catalog
                .codex_effort_proof(&document["selection"], binding.profile.executable())
                .is_err(),
            "named speed must not borrow default-account proof"
        );
        for speed in [
            json!("ultrafast"),
            json!("default"),
            json!(" priority "),
            json!(17),
        ] {
            let mut changed = document.clone();
            changed["selection"]["speed"] = speed;
            assert!(
                catalog
                    .named_model_proof(&changed, &binding, Some("speed-a"))
                    .is_err()
            );
            assert!(proof.validate_thread(&changed).is_err());
        }
        let mut standard = document.clone();
        standard["selection"]["speed"] = Value::Null;
        assert!(proof.validate_thread(&standard).is_err());
        let standard_proof = catalog
            .named_model_proof(&standard, &binding, Some("speed-a"))
            .unwrap()
            .unwrap();
        assert_ne!(
            proof, standard_proof,
            "speed is part of private proof identity"
        );
        let standard_policy = crate::composer_policy::Policy::parse_named(
            &standard,
            crate::composer_policy::Origin::Ordinary,
            Some(&standard_proof),
        )
        .unwrap();
        assert_eq!(standard_policy.codex_speed(), None);
        catalog.jobs["speed-a"]
            .cancelled
            .store(true, Ordering::Release);
        assert!(policy.preflight().is_err());
        assert!(standard_policy.preflight().is_err());
    }
    #[test]
    fn named_speed_capability_never_uses_ineligible_or_unadvertised_models() {
        let (_dir, binding, mut document) = fixture();
        let mut catalog = ModelCatalog::default();
        ready(&mut catalog, binding.clone(), "speed-a");
        catalog.jobs.get_mut("speed-a").unwrap().response["models"] = json!([
            {"id":"synthetic-a","reportedSpeeds":[]},
            {"id":"default","reportedSpeeds":[{"id":"priority"}]},
            {"id":"gpt-6-astra","reportedSpeeds":[{"id":"priority"}]}
        ]);
        for model in ["synthetic-a", "default", "gpt-6-astra", "missing"] {
            document["selection"]["modelID"] = json!(model);
            let capability = catalog.named_speed_capability(&document, &binding);
            assert_eq!(capability["supported"], false, "{model}");
            assert_eq!(capability["choices"], json!([]));
        }
    }
    #[test]
    fn named_effort_requires_exact_reported_model_and_private_policy() {
        let (_dir, binding, mut document) = fixture();
        let mut catalog = ModelCatalog::default();
        ready(&mut catalog, binding.clone(), "a");
        catalog.jobs.get_mut("a").unwrap().response["models"] = json!([
            {"id":"synthetic-a","reportedEfforts":["low","high"],"reportedDefaultEffort":"low"},
            {"id":"synthetic-b","reportedEfforts":["low"]}
        ]);
        document["selection"]["effort"] = json!("high");
        document["accessMode"] = json!("approval");
        document["interactionMode"] = json!("build");
        let proof = catalog
            .named_model_proof(&document, &binding, Some("a"))
            .unwrap()
            .unwrap();
        let policy = crate::composer_policy::Policy::parse_named(
            &document,
            crate::composer_policy::Origin::Ordinary,
            Some(&proof),
        )
        .unwrap();
        policy.preflight().unwrap();
        let fields = policy
            .codex_turn_fields(
                "native-a",
                None,
                crate::composer_policy::CollaborationHistory::NeverApplied,
            )
            .unwrap();
        assert_eq!(fields["effort"], "high");
        assert_eq!(
            fields["collaborationMode"]["settings"]["reasoning_effort"],
            "high"
        );
        assert_eq!(
            catalog.named_effort_capability(&document, &binding)["choices"],
            json!(["low", "high"])
        );
        // The validation alias alone cannot turn named metadata into a default proof.
        assert!(
            crate::composer_selection::validate_thread_with_proof(
                &crate::codex_login_profiles::validation_view(&document),
                None
            )
            .is_err()
        );
        assert!(
            proof
                .validate_launch(
                    &binding.profile,
                    &binding.cwd,
                    Some("synthetic-a"),
                    Some("low"),
                    None,
                )
                .is_err()
        );
        let mut changed = document.clone();
        changed["selection"]["effort"] = json!("low");
        assert!(proof.validate_thread(&changed).is_err());
        assert!(
            catalog
                .named_model_proof(&changed, &binding, Some("a"))
                .is_ok()
        );
        changed["selection"]["effort"] = json!("medium");
        assert!(
            catalog
                .named_model_proof(&changed, &binding, Some("a"))
                .is_err()
        );
        // An unreported but syntactically valid saved effort must remain
        // repairable through this same model's advertised options.
        assert_eq!(
            catalog.named_effort_capability(&changed, &binding)["supported"],
            true
        );
        changed = document.clone();
        changed["selection"]["modelID"] = json!("synthetic-b");
        assert!(
            catalog
                .named_model_proof(&changed, &binding, Some("a"))
                .is_err()
        );
        changed["selection"]["modelID"] = json!("default");
        assert!(catalog.named_model_proof(&changed, &binding, None).is_err());
        changed["selection"]["effort"] = Value::Null;
        catalog.jobs.get_mut("a").unwrap().response["models"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":"default","reportedEfforts":["high"]}));
        assert_eq!(
            catalog.named_effort_capability(&changed, &binding)["supported"],
            false
        );
        catalog.jobs.get_mut("a").unwrap().response["models"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":"gpt-6-astra","reportedEfforts":["high"]}));
        for effort in [Value::Null, json!("high")] {
            changed["selection"]["modelID"] = json!("gpt-6-astra");
            changed["selection"]["effort"] = effort;
            let capability = catalog.named_effort_capability(&changed, &binding);
            assert_eq!(capability["supported"], false);
            assert_eq!(capability["choices"], json!([]));
            assert!(
                catalog
                    .named_model_proof(&changed, &binding, Some("a"))
                    .is_err()
            );
        }
        catalog.jobs["a"].cancelled.store(true, Ordering::Release);
        assert!(policy.preflight().is_err());
        assert!(
            policy
                .codex_turn_fields(
                    "native-a",
                    None,
                    crate::composer_policy::CollaborationHistory::NeverApplied
                )
                .is_err()
        );
    }
    #[test]
    fn profile_model_notifications_accept_quota_but_never_new_auth_authority() {
        assert!(validate_notification(&json!({"method":"account/rateLimits/updated"})).is_ok());
        assert!(validate_notification(&json!({"method":"account/updated"})).is_err());
        assert!(validate_notification(&json!({"method":"account/login/completed"})).is_err());
        assert!(validate_notification(&json!({"method":"account/unknown"})).is_err());
    }
}
