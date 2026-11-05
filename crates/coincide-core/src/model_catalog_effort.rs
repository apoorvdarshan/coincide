//! Private proof derived only from an Engine-owned completed model-list job.
use super::*;
use std::{path::Path, time::SystemTime};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct EffortExecutable {
    requested: PathBuf,
    canonical: PathBuf,
    length: u64,
    modified: SystemTime,
    #[cfg(unix)]
    identity: (u64, u64),
}
impl EffortExecutable {
    pub(super) fn read(path: &Path) -> Result<Self> {
        ensure!(
            path.is_absolute(),
            "Effort requires an absolute configured executable"
        );
        let canonical = path.canonicalize()?;
        let metadata = std::fs::metadata(&canonical)?;
        ensure!(metadata.is_file(), "Provider executable is not a file");
        Ok(Self {
            requested: path.into(),
            canonical,
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
#[derive(Clone, Debug)]
pub(crate) struct CodexEffortProof {
    model: String,
    effort: String,
    executable: EffortExecutable,
    revoked: Arc<AtomicBool>,
}
impl PartialEq for CodexEffortProof {
    fn eq(&self, other: &Self) -> bool {
        self.model == other.model
            && self.effort == other.effort
            && self.executable == other.executable
            && Arc::ptr_eq(&self.revoked, &other.revoked)
    }
}
impl Eq for CodexEffortProof {}
impl CodexEffortProof {
    pub(crate) fn validate(&self, selection: &Value) -> Result<()> {
        ensure!(
            selection["provider"] == "codex"
                && crate::composer_selection::default_account(&selection["accountID"])
                && selection["modelID"] == self.model
                && selection["effort"] == self.effort,
            "Effort proof does not match provider, account, model and effort"
        );
        self.validate_executable(&self.executable.requested)
    }
    pub(crate) fn validate_executable_for_policy(&self) -> Result<()> {
        self.validate_executable(&self.executable.requested)
    }
    pub(crate) fn validate_executable(&self, path: &Path) -> Result<()> {
        ensure!(
            !self.revoked.load(Ordering::Acquire),
            "Model catalog proof was revoked; refresh and reselect the model"
        );
        ensure!(
            EffortExecutable::read(path)? == self.executable,
            "Provider executable changed since model discovery; refresh the catalog"
        );
        Ok(())
    }
}
impl ModelCatalog {
    fn effort_model(&self, selection: &Value, executable: &Path) -> Result<(&Job, &Value)> {
        ensure!(!self.shutdown.closed, "Model catalog is shutting down");
        ensure!(
            selection["provider"] == "codex"
                && crate::composer_selection::default_account(&selection["accountID"]),
            "Effort is supported only for ordinary Codex default-account selections"
        );
        let model = selection["modelID"]
            .as_str()
            .context("An explicit model is required for effort")?;
        ensure!(
            model != "default",
            "Effort requires an explicit provider-reported model"
        );
        let job = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.jobs.get(id))
            .find(|job| job.response["provider"] == "codex")
            .context("Refresh the Codex model catalog before choosing effort")?;
        ensure!(
            job.response["state"] == "ready" && !job.cancelled.load(Ordering::Acquire),
            "Latest Codex catalog is not ready; previous choices are not authoritative"
        );
        ensure!(
            job.binding.as_ref() == Some(&EffortExecutable::read(executable)?),
            "Catalog belongs to another or changed provider executable"
        );
        let reported = job.response["models"]
            .as_array()
            .and_then(|models| models.iter().find(|entry| entry["id"] == model))
            .context("Model was not reported by the latest Codex catalog")?;
        Ok((job, reported))
    }
    pub(crate) fn codex_effort_proof(
        &self,
        selection: &Value,
        executable: &Path,
    ) -> Result<Option<CodexEffortProof>> {
        if selection["effort"].is_null() {
            return Ok(None);
        }
        let effort = selection["effort"]
            .as_str()
            .context("Effort must be text or null")?;
        let (job, model) = self.effort_model(selection, executable)?;
        ensure!(
            model["reportedEfforts"]
                .as_array()
                .is_some_and(|choices| choices
                    .iter()
                    .any(|choice| choice.as_str() == Some(effort))),
            "Effort was not advertised for this exact model"
        );
        Ok(Some(CodexEffortProof {
            model: selection["modelID"].as_str().unwrap().into(),
            effort: effort.into(),
            executable: job.binding.clone().unwrap(),
            revoked: job.cancelled.clone(),
        }))
    }
    pub(crate) fn effort_capability(&self, selection: &Value, executable: &Path) -> Value {
        match self.effort_model(selection, executable) {
            Ok((_, model)) => {
                json!({"supported":true,"ordinaryThreadsOnly":true,"requiresExplicitModel":true,"provenance":"provider_model_list","choices":model["reportedEfforts"],"reportedDefault":model["reportedDefaultEffort"],"reason":null})
            }
            Err(error) => json!({"supported":false,"choices":[],"reason":error.to_string()}),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, ModelCatalog, PathBuf, Value) {
        let dir = tempfile::tempdir().unwrap();
        let executable = dir.path().join("reported-provider");
        std::fs::write(&executable, b"synthetic executable identity").unwrap();
        let mut catalog = ModelCatalog::default();
        let id = "trusted-private-job".to_owned();
        let model = parse_model(&json!({"model":"reported-model","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}],"defaultReasoningEffort":"low"})).unwrap().unwrap();
        catalog.jobs.insert(id.clone(), Job { binding:Some(EffortExecutable::read(&executable).unwrap()), response:json!({"provider":"codex","accountID":"default","state":"ready","models":[model]}),cancelled:Arc::new(AtomicBool::new(false)) });
        catalog.order.push_back(id);
        let selection = json!({"provider":"codex","modelID":"reported-model","effort":"high"});
        (dir, catalog, executable, selection)
    }
    #[test]
    fn private_catalog_proof_binds_model_effort_account_and_executable() {
        let (_dir, catalog, path, selection) = fixture();
        let proof = catalog
            .codex_effort_proof(&selection, &path)
            .unwrap()
            .unwrap();
        proof.validate(&selection).unwrap();
        for (field, value) in [
            ("provider", json!("claude")),
            ("accountID", json!("named")),
            ("modelID", json!("unknown")),
            ("modelID", json!("default")),
            ("effort", json!("invented")),
        ] {
            let mut changed = selection.clone();
            changed[field] = value;
            assert!(catalog.codex_effort_proof(&changed, &path).is_err());
            assert!(proof.validate(&changed).is_err());
        }
        let other = path.with_file_name("other-provider");
        std::fs::write(&other, b"synthetic executable identity").unwrap();
        assert!(proof.validate_executable(&other).is_err());
        std::fs::write(&path, b"changed executable with distinct length").unwrap();
        assert!(proof.validate(&selection).is_err());
        assert!(catalog.codex_effort_proof(&selection, &path).is_err());
    }
    #[test]
    fn unproven_json_cannot_enable_effort_and_shutdown_revokes_existing_proof() {
        let (_dir, mut catalog, path, selection) = fixture();
        let thread = json!({"selection":selection,"accessMode":"approval","interactionMode":"build","catalogProof":true,"effortSupported":true});
        assert!(crate::composer_selection::validate_thread(&thread).is_err());
        let proof = catalog
            .codex_effort_proof(&selection, &path)
            .unwrap()
            .unwrap();
        crate::composer_selection::validate_thread_with_proof(&thread, Some(&proof)).unwrap();
        for mode in ["build", "plan"] {
            let mut thread = thread.clone();
            thread["interactionMode"] = json!(mode);
            let policy = crate::composer_policy::Policy::parse_with_effort_proof(
                &thread,
                crate::composer_policy::Origin::Ordinary,
                Some(&proof),
            )
            .unwrap();
            let fields = policy
                .codex_turn_fields(
                    "source",
                    None,
                    crate::composer_policy::CollaborationHistory::NeverApplied,
                )
                .unwrap();
            assert_eq!(fields["effort"], "high");
            assert_eq!(
                fields["collaborationMode"]["settings"]["reasoning_effort"],
                "high"
            );
            assert!(fields.get("serviceTier").is_none());
            thread["rustBotContext"] = json!({"selection":selection});
            assert!(
                crate::composer_policy::Policy::parse_with_effort_proof(
                    &thread,
                    crate::composer_policy::Origin::FrozenBot,
                    Some(&proof)
                )
                .is_err()
            );
            assert!(
                crate::composer_policy::Policy::parse_with_effort_proof(
                    &thread,
                    crate::composer_policy::Origin::Imported,
                    Some(&proof)
                )
                .is_err()
            );
        }
        catalog.request_shutdown();
        assert!(proof.validate(&selection).is_err());
        assert!(catalog.codex_effort_proof(&selection, &path).is_err());
    }
    #[test]
    fn latest_loading_or_failed_catalog_never_falls_back_to_previous_ready_job() {
        let (_dir, mut catalog, path, selection) = fixture();
        for state in ["loading", "failed"] {
            catalog.jobs.insert(
                "latest".into(),
                Job {
                    binding: Some(EffortExecutable::read(&path).unwrap()),
                    response: json!({"provider":"codex","state":state,"models":[]}),
                    cancelled: Arc::new(AtomicBool::new(false)),
                },
            );
            catalog.order.push_back("latest".into());
            assert!(catalog.codex_effort_proof(&selection, &path).is_err());
            assert_eq!(
                catalog.effort_capability(&selection, &path)["supported"],
                false
            );
        }
    }
    #[test]
    fn admitted_failed_refresh_revokes_proof_without_falling_back() {
        let (_dir, mut catalog, path, selection) = fixture();
        let proof = catalog
            .codex_effort_proof(&selection, &path)
            .unwrap()
            .unwrap();
        let request = catalog
            .refresh_bound(
                "codex",
                Some(EffortExecutable::read(&path).unwrap()),
                |_| Err("synthetic catalog failure".into()),
            )
            .unwrap();
        assert!(proof.validate(&selection).is_err());
        assert!(catalog.codex_effort_proof(&selection, &path).is_err());
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            catalog.poll();
            if catalog
                .status(request["requestId"].as_str().unwrap())
                .unwrap()["state"]
                == "failed"
            {
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert!(catalog.codex_effort_proof(&selection, &path).is_err());
        assert!(proof.validate(&selection).is_err());
        while catalog.shutdown_status().running != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    }
}
