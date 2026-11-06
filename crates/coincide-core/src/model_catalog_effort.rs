//! Private proof derived only from an Engine-owned completed model-list job.
use super::*;
use std::{path::Path, time::SystemTime};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct EffortExecutable {
    requested: PathBuf,
    canonical: PathBuf,
    length: u64,
    modified: SystemTime,
    identity: crate::private_fs::Identity,
}
impl EffortExecutable {
    pub(super) fn read(path: &Path) -> Result<Self> {
        ensure!(
            path.is_absolute(),
            "Effort requires an absolute configured executable"
        );
        let canonical = path.canonicalize()?;
        let metadata = std::fs::metadata(&canonical)?;
        let identity = crate::private_fs::identity(&canonical)?;
        ensure!(metadata.is_file(), "Provider executable is not a file");
        Ok(Self {
            requested: path.into(),
            canonical,
            length: metadata.len(),
            modified: metadata.modified()?,
            identity,
        })
    }
}
/// Exact explicit family only. A provider-resolved default never triggers this.
pub(crate) fn astra_model(model: &str) -> bool {
    matches!(model, "gpt-6-astra" | "openai.gpt-6-astra")
}
pub(crate) fn astra_default_needed(selection: &Value) -> bool {
    selection["provider"] == "codex"
        && crate::composer_selection::default_account(&selection["accountID"])
        && selection["effort"].is_null()
        && selection["modelID"].as_str().is_some_and(astra_model)
}
/// Private admitted model options. The historical name is retained internally;
/// both effort and speed are bound, never caller-supplied proof metadata.
#[derive(Clone, Debug)]
pub(crate) struct CodexEffortProof {
    model: String,
    effort: Option<String>,
    effective_effort: Option<String>,
    speed: Option<String>,
    executable: EffortExecutable,
    revoked: Arc<AtomicBool>,
}
impl PartialEq for CodexEffortProof {
    fn eq(&self, other: &Self) -> bool {
        self.model == other.model
            && self.effort == other.effort
            && self.effective_effort == other.effective_effort
            && self.speed == other.speed
            && self.executable == other.executable
            && Arc::ptr_eq(&self.revoked, &other.revoked)
    }
}
impl Eq for CodexEffortProof {}
impl CodexEffortProof {
    pub(crate) fn effective_effort(&self) -> Option<&str> {
        self.effective_effort.as_deref()
    }
    pub(crate) fn validate(&self, selection: &Value) -> Result<()> {
        ensure!(
            selection["provider"] == "codex"
                && crate::composer_selection::default_account(&selection["accountID"])
                && selection["modelID"] == self.model
                && selection["effort"] == json!(self.effort)
                && selection["speed"] == json!(self.speed),
            "Catalog proof does not match provider, account, model, effort and speed"
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
            "Effort/speed is supported only for ordinary Codex default-account selections"
        );
        let model = selection["modelID"]
            .as_str()
            .context("An explicit model is required for effort/speed")?;
        ensure!(
            model != "default",
            "Effort/speed requires an explicit provider-reported model"
        );
        let job = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.jobs.get(id))
            .find(|job| job.named.is_none() && job.response["provider"] == "codex")
            .context("Refresh the Codex model catalog before choosing effort/speed")?;
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
        if selection["effort"].is_null()
            && selection["speed"].is_null()
            && !astra_default_needed(selection)
        {
            return Ok(None);
        }
        let effort = selection["effort"].as_str();
        let speed = selection["speed"].as_str();
        ensure!(
            selection["effort"].is_null() || effort.is_some(),
            "Effort must be text or null"
        );
        ensure!(
            selection["speed"].is_null() || speed.is_some(),
            "Speed must be text or null"
        );
        let (job, model) = self.effort_model(selection, executable)?;
        if let Some(effort) = effort {
            ensure!(
                model["reportedEfforts"]
                    .as_array()
                    .is_some_and(|choices| choices
                        .iter()
                        .any(|choice| choice.as_str() == Some(effort))),
                "Effort was not advertised for this exact model"
            );
        }
        let effective_effort = if astra_default_needed(selection) {
            ensure!(
                model["reportedEfforts"]
                    .as_array()
                    .is_some_and(|choices| choices.iter().any(|choice| choice == "medium")),
                "Refresh the exact Astra model catalog advertising medium before using its app default"
            );
            Some("medium")
        } else {
            effort
        };
        if let Some(speed) = speed {
            ensure!(
                speed != "default"
                    && model["reportedSpeeds"]
                        .as_array()
                        .is_some_and(|choices| choices
                            .iter()
                            .any(|choice| choice["id"].as_str() == Some(speed))),
                "Speed was not advertised for this exact model; choose null for Standard"
            );
        }
        Ok(Some(CodexEffortProof {
            model: selection["modelID"].as_str().unwrap().into(),
            effort: effort.map(str::to_owned),
            effective_effort: effective_effort.map(str::to_owned),
            speed: speed.map(str::to_owned),
            executable: job.binding.clone().unwrap(),
            revoked: job.cancelled.clone(),
        }))
    }
    pub(crate) fn speed_capability(&self, selection: &Value, executable: &Path) -> Value {
        match self.effort_model(selection, executable) {
            Ok((_, model)) => {
                json!({"supported":true,"ordinaryThreadsOnly":true,"requiresExplicitModel":true,
                "provenance":"provider_model_list","standard":null,"choices":model["reportedSpeeds"],"reason":null})
            }
            Err(error) => json!({"supported":false,"choices":[],"reason":error.to_string()}),
        }
    }
    pub(crate) fn effort_capability(&self, selection: &Value, executable: &Path) -> Value {
        match self.effort_model(selection, executable) {
            Ok((_, model)) => {
                let mut null_selection = selection.clone();
                null_selection["effort"] = Value::Null;
                let astra = astra_default_needed(&null_selection);
                let medium = astra
                    && model["reportedEfforts"]
                        .as_array()
                        .is_some_and(|choices| choices.iter().any(|choice| choice == "medium"));
                json!({"supported":true,"ordinaryThreadsOnly":true,"requiresExplicitModel":true,"provenance":"provider_model_list","choices":model["reportedEfforts"],"reportedDefault":model["reportedDefaultEffort"],
                    "effectiveDefault":if medium {json!("medium")}else{Value::Null},"effectiveDefaultProvenance":if medium {json!("app_policy+provider_model_list")}else{Value::Null},
                    "appDefaultRequired":astra,"appDefaultAvailable":!astra||medium,"appDefaultReason":if astra&&!medium {json!("Refresh an Astra catalog advertising medium before using its app default")}else{Value::Null},"reason":null})
            }
            Err(error) => {
                let mut null_selection = selection.clone();
                null_selection["effort"] = Value::Null;
                json!({"supported":false,"choices":[],"reportedDefault":null,"effectiveDefault":null,"appDefaultRequired":astra_default_needed(&null_selection),"appDefaultAvailable":false,"reason":error.to_string()})
            }
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
        catalog.jobs.insert(id.clone(), Job { named:None, binding:Some(EffortExecutable::read(&executable).unwrap()), response:json!({"provider":"codex","accountID":"default","state":"ready","models":[model]}),cancelled:Arc::new(AtomicBool::new(false)) });
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
                    named: None,
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
    fn admitted_refresh_revokes_proof_for_failed_or_unsupported_catalog() {
        let (_dir, mut catalog, path, selection) = fixture();
        let proof = catalog
            .codex_effort_proof(&selection, &path)
            .unwrap()
            .unwrap();
        let ran = Arc::new(AtomicBool::new(false));
        let worker_ran = ran.clone();
        let request = catalog
            .refresh_bound(
                "codex",
                Some(EffortExecutable::read(&path).unwrap()),
                move |_| {
                    worker_ran.store(true, Ordering::Release);
                    Err("synthetic catalog failure".into())
                },
            )
            .unwrap();
        assert!(proof.validate(&selection).is_err());
        assert!(catalog.codex_effort_proof(&selection, &path).is_err());
        // Windows deliberately does not launch this discovery worker; its
        // terminal response is Unsupported, which must revoke old proof too.
        let expected = if supported("codex") {
            "failed"
        } else {
            "unsupported"
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            catalog.poll();
            if catalog
                .status(request["requestId"].as_str().unwrap())
                .unwrap()["state"]
                == expected
            {
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(ran.load(Ordering::Acquire), supported("codex"));
        assert!(catalog.codex_effort_proof(&selection, &path).is_err());
        assert!(proof.validate(&selection).is_err());
        while catalog.shutdown_status().running != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    }
    #[test]
    fn speed_proof_is_exact_combined_revocable_and_policy_gated() {
        let (_dir, mut catalog, path, mut selection) = fixture();
        catalog
            .jobs
            .get_mut("trusted-private-job")
            .unwrap()
            .response["models"][0]["reportedSpeeds"] = json!([{"id":"priority","name":"Fast"}]);
        selection["speed"] = json!("priority");
        let proof = catalog
            .codex_effort_proof(&selection, &path)
            .unwrap()
            .unwrap();
        proof.validate(&selection).unwrap();
        let thread =
            json!({"selection":selection,"accessMode":"approval","interactionMode":"build"});
        let policy = crate::composer_policy::Policy::parse_with_effort_proof(
            &thread,
            crate::composer_policy::Origin::Ordinary,
            Some(&proof),
        )
        .unwrap();
        policy.preflight().unwrap();
        assert_eq!(policy.codex_speed(), Some("priority"));
        for speed in [
            json!("default"),
            json!("fast"),
            json!(" priority "),
            json!(false),
            Value::Null,
        ] {
            let mut changed = selection.clone();
            changed["speed"] = speed;
            assert!(proof.validate(&changed).is_err());
            if !changed["speed"].is_null() {
                assert!(catalog.codex_effort_proof(&changed, &path).is_err());
            }
        }
        let mut speed_only = selection.clone();
        speed_only.as_object_mut().unwrap().remove("effort");
        assert!(proof.validate(&speed_only).is_err());
        let speed_proof = catalog
            .codex_effort_proof(&speed_only, &path)
            .unwrap()
            .unwrap();
        speed_proof.validate(&speed_only).unwrap();
        catalog
            .jobs
            .get_mut("trusted-private-job")
            .unwrap()
            .cancelled
            .store(true, Ordering::Release);
        assert!(proof.validate(&selection).is_err());
        assert!(speed_proof.validate(&speed_only).is_err());
        assert!(policy.preflight().is_err());
    }
    #[test]
    fn astra_exact_family_and_advertised_medium_are_required_without_stored_mutation() {
        let (_dir, mut catalog, path, _) = fixture();
        let model = &mut catalog
            .jobs
            .get_mut("trusted-private-job")
            .unwrap()
            .response["models"][0];
        model["id"] = json!("gpt-6-astra");
        model["reportedEfforts"] = json!(["low", "medium", "high"]);
        model["reportedDefaultEffort"] = json!("low");
        let selection =
            json!({"provider":"codex","modelID":"gpt-6-astra","effort":null,"speed":null});
        let original = selection.clone();
        let proof = catalog
            .codex_effort_proof(&selection, &path)
            .unwrap()
            .unwrap();
        assert_eq!(proof.effort, None);
        assert_eq!(proof.effective_effort(), Some("medium"));
        proof.validate(&selection).unwrap();
        assert_eq!(selection, original);
        let caps = catalog.effort_capability(&selection, &path);
        assert_eq!(caps["reportedDefault"], "low");
        assert_eq!(caps["effectiveDefault"], "medium");
        assert_eq!(
            caps["effectiveDefaultProvenance"],
            "app_policy+provider_model_list"
        );
        let mut explicit = selection.clone();
        explicit["effort"] = json!("high");
        assert!(proof.validate(&explicit).is_err());
        let explicit_proof = catalog
            .codex_effort_proof(&explicit, &path)
            .unwrap()
            .unwrap();
        assert_eq!(explicit_proof.effective_effort(), Some("high"));
        let thread =
            json!({"selection":selection,"accessMode":"approval","interactionMode":"plan"});
        let policy = crate::composer_policy::Policy::parse_with_effort_proof(
            &thread,
            crate::composer_policy::Origin::Ordinary,
            Some(&proof),
        )
        .unwrap();
        policy.preflight().unwrap();
        let fields = policy
            .codex_turn_fields(
                "source",
                None,
                crate::composer_policy::CollaborationHistory::NeverApplied,
            )
            .unwrap();
        assert_eq!(fields["effort"], "medium");
        assert_eq!(
            fields["collaborationMode"]["settings"]["reasoning_effort"],
            "medium"
        );
        catalog
            .jobs
            .get_mut("trusted-private-job")
            .unwrap()
            .cancelled
            .store(true, Ordering::Release);
        assert!(policy.preflight().is_err());
        assert!(proof.validate(&selection).is_err());
        for model in [
            "gpt-6-astra-v2",
            "GPT-6-Astra",
            "bedrock.gpt-6-astra",
            "openai.gpt-6-astra-v2",
            "default",
            "gpt-6-sol",
        ] {
            assert!(
                !astra_default_needed(&json!({"provider":"codex","modelID":model})),
                "{model}"
            );
        }
        assert!(astra_default_needed(
            &json!({"provider":"codex","modelID":"openai.gpt-6-astra"})
        ));
        assert!(!astra_default_needed(
            &json!({"provider":"claude","modelID":"gpt-6-astra"})
        ));
        assert!(!astra_default_needed(
            &json!({"provider":"codex","modelID":"gpt-6-astra","accountID":"named"})
        ));
    }
    #[test]
    fn astra_missing_medium_never_falls_back_and_base_repair_never_authorizes_runtime() {
        let (_dir, mut catalog, path, _) = fixture();
        let mut thread = json!({"selection":{"provider":"codex","modelID":"gpt-6-astra","effort":null},"accessMode":"approval","interactionMode":"build"});
        catalog
            .jobs
            .get_mut("trusted-private-job")
            .unwrap()
            .response["models"][0]["id"] = json!("gpt-6-astra");
        for efforts in [json!([]), json!(["low", "high"]), Value::Null] {
            catalog
                .jobs
                .get_mut("trusted-private-job")
                .unwrap()
                .response["models"][0]["reportedEfforts"] = efforts;
            assert!(
                catalog
                    .codex_effort_proof(&thread["selection"], &path)
                    .is_err()
            );
            assert!(crate::composer_selection::validate_thread_base(&thread).is_ok());
            assert!(crate::composer_selection::validate_thread(&thread).is_err());
            let caps = catalog.effort_capability(&thread["selection"], &path);
            assert!(caps["effectiveDefault"].is_null());
            assert_eq!(caps["appDefaultAvailable"], false);
        }
        thread["selection"]["effort"] = json!("stale");
        thread["selection"]["speed"] = json!("stale");
        let repaired = crate::composer_selection::repair_clear_options(
            &json!({"effort":null,"speed":null}),
            &thread,
        )
        .unwrap();
        thread["selection"] = repaired;
        assert!(crate::composer_selection::validate_thread_base(&thread).is_ok());
        assert!(crate::composer_selection::validate_thread(&thread).is_err());
        let mut bot = thread.clone();
        bot["rustBotContext"] = json!({"selection":thread["selection"]});
        let policy =
            crate::composer_policy::Policy::parse(&bot, crate::composer_policy::Origin::FrozenBot)
                .unwrap();
        policy.preflight().unwrap();
        assert!(
            policy
                .codex_turn_fields(
                    "source",
                    None,
                    crate::composer_policy::CollaborationHistory::NeverApplied
                )
                .unwrap()
                .get("effort")
                .is_none()
        );
        assert!(
            crate::composer_policy::Policy::parse(
                &thread,
                crate::composer_policy::Origin::Imported
            )
            .is_err()
        );
        let mut named = thread.clone();
        named["selection"]["accountID"] = json!("named");
        assert!(crate::composer_selection::validate_thread_base(&named).is_err());
    }
    #[test]
    fn astra_effective_default_proof_rechecks_changed_executable() {
        let (_dir, mut catalog, path, _) = fixture();
        let model = &mut catalog
            .jobs
            .get_mut("trusted-private-job")
            .unwrap()
            .response["models"][0];
        model["id"] = json!("gpt-6-astra");
        model["reportedEfforts"] = json!(["medium"]);
        let selection = json!({"provider":"codex","modelID":"gpt-6-astra","effort":null});
        let proof = catalog
            .codex_effort_proof(&selection, &path)
            .unwrap()
            .unwrap();
        let policy = crate::composer_policy::Policy::parse_with_effort_proof(
            &json!({"selection":selection}),
            crate::composer_policy::Origin::Ordinary,
            Some(&proof),
        )
        .unwrap();
        policy.preflight().unwrap();
        std::fs::write(&path, b"different executable length and identity metadata").unwrap();
        assert!(proof.validate(&selection).is_err());
        assert!(policy.preflight().is_err());
        assert!(catalog.codex_effort_proof(&selection, &path).is_err());
    }
}
