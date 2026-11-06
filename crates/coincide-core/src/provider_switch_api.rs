//! Atomic provider switching. Historical preferences never grant execution authority.
use super::*;
use crate::model_catalog::NamedBinding;

pub(super) struct RestoreIntent {
    source: Value,
    target: Value,
    binding: NamedBinding,
    request: String,
    serial: u64,
}

const EXPECTED_FIELDS: [&str; 7] = [
    "id",
    "draft",
    "selection",
    "accessMode",
    "interactionMode",
    "rustDraftImages",
    "draftContext",
];

impl Engine {
    pub(super) fn select_provider_from_history(&mut self, p: &Value) -> Result<Value> {
        let fields = p
            .as_object()
            .context("Provider selection must be an object")?;
        ensure!(
            (fields.len() == 3 || fields.len() == 4)
                && fields.keys().all(|key| matches!(
                    key.as_str(),
                    "threadId" | "provider" | "expected" | "restoreRequestId"
                )),
            "Provider selection requires threadId, provider and expected only"
        );
        let id = required(p, "threadId")?;
        let provider = required(p, "provider")?;
        if let Some(request) = p.get("restoreRequestId") {
            let request = request.as_str().context("Invalid restore request")?;
            self.poll_provider_restore();
            ensure!(
                self.provider_restore
                    .as_ref()
                    .is_some_and(|intent| intent.request == request),
                "Provider restoration was cancelled or superseded; draft retained"
            );
        } else {
            self.cancel_provider_restore();
        }
        Provider::from_name(provider)?;
        ensure!(
            self.active_thread() == Some(id),
            "Active conversation changed; draft retained"
        );
        ensure!(
            !self.unsaved_threads.contains_key(id),
            "Transcript persistence is recovering; retry after recovery"
        );
        ensure!(
            !self.runs.contains_key(id),
            "Stop the current turn before changing provider"
        );
        ensure!(
            !self.store.is_imported(id)?,
            "Fork an imported thread before changing its provider"
        );
        let current = self.store.thread(id)?;
        ensure!(
            current["rustBotContext"].is_null() && current["botID"].is_null(),
            "Bot selection is fixed for this conversation"
        );
        let expected = p["expected"]
            .as_object()
            .context("Expected composer snapshot is required")?;
        ensure!(
            expected.len() == EXPECTED_FIELDS.len()
                && EXPECTED_FIELDS
                    .iter()
                    .all(|key| expected.contains_key(*key)),
            "Expected composer snapshot has unsupported or missing fields"
        );
        ensure!(
            EXPECTED_FIELDS
                .iter()
                .all(|key| p["expected"][*key] == current[*key]),
            "Saved composer changed; command draft retained"
        );
        ensure!(
            current["selection"]["provider"] != provider,
            "This conversation already uses {provider}; command draft retained"
        );
        ensure!(
            crate::message_queue::read(&current)?
                .iter()
                .all(|message| !matches!(
                    message.state,
                    crate::message_queue::State::Pending | crate::message_queue::State::Dispatching
                )),
            "Finish or remove queued messages before changing provider"
        );
        // A superseded intent is irreversibly cancelled before considering a new
        // target. A later A -> B -> A action cannot resurrect the old catalog.
        if self.provider_restore.as_ref().is_some_and(|intent| {
            intent.source != current || intent.target["selection"]["provider"] != provider
        }) {
            self.cancel_provider_restore();
        }
        if provider == "codex"
            && let Some(account) = remembered_account(&current, provider)
        {
            return self.restore_named_provider(current, account);
        }
        if current["selection"]["provider"] == "codex"
            && !crate::composer_selection::default_account(&current["selection"]["accountID"])
        {
            crate::codex_login_profiles::validate_model_thread(&current)?;
        } else {
            crate::composer_selection::validate_thread_base(&current)?;
        }
        let capabilities = crate::composer_selection::capabilities();
        let target = capabilities["providers"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["provider"] == provider))
            .context("Provider is unavailable in the current runtime")?;
        ensure!(
            target["accountPolicy"] == "default_only"
                && target["models"]
                    .as_array()
                    .is_some_and(|rows| rows.iter().any(|row| row["id"] == "default")),
            "Choose this provider/account explicitly in model controls"
        );

        // Only the latest private job for this exact default provider/executable
        // can corroborate a historical name. No discovery, credential read,
        // catalog refresh, named proof or provider execution occurs here.
        ensure!(
            crate::composer_selection::default_account(&current["selection"]["accountID"])
                || current["selection"]["provider"] == "codex",
            "This named account type cannot be switched automatically"
        );

        let restored = historical_default_model(&current, provider).and_then(|model| {
            let executable = self.provider_switch_executable(provider)?;
            self.model_catalog
                .reported_default_model(provider, model, &executable)
        });
        let model = restored.as_deref().unwrap_or("default");
        let mut selection = json!({"threadId":id,"provider":provider,"model":model,"accountId":null,"effort":null,"speed":null});
        for key in ["accessMode", "interactionMode"] {
            if !current[key].is_null() {
                selection[key] = current[key].clone();
            }
        }
        // Preserve every existing selection/policy guard; this is not a new
        // execution grant and cannot repair or silently clear saved options.
        let mut thread = current.clone();
        let mut validation = current.clone();
        // The source is retained in its provider preference; only target syntax
        // and authority determine whether this atomic replacement is valid.
        validation["selection"] = json!({"provider":provider,"modelID":"default"});
        let target_proof = self.composer_target_effort_proof(&selection)?;
        thread["selection"] = crate::composer_selection::select_with_proofs(
            &selection,
            &validation,
            None,
            target_proof.as_ref(),
        )?;
        crate::composer_selection::apply_modes_with_proof(
            &selection,
            &mut thread,
            target_proof.as_ref(),
        )?;
        remember_source(&mut thread, &current)?;
        self.store.save(&thread)?;
        self.revision += 1;
        Ok(
            json!({"thread":thread,"model":model,"restored":restored.is_some(),
            "provenance":if restored.is_some(){"latest_default_catalog"}else{"provider_default"},
            "authenticationChecked":false,"accountRestored":false}),
        )
    }

    pub(super) fn cancel_provider_restore(&mut self) {
        if let Some(intent) = self.provider_restore.take() {
            self.model_catalog.cancel_named_restore(&intent.request);
        }
    }

    pub(super) fn poll_provider_restore(&mut self) {
        let valid = self.provider_restore.as_ref().is_none_or(|intent| {
            let id = intent.source["id"].as_str().unwrap_or("");
            !self.admissions_frozen()
                && self.active_thread() == Some(id)
                && !self.runs.contains_key(id)
                && !self.unsaved_threads.contains_key(id)
                && self
                    .store
                    .mutation_serial()
                    .is_ok_and(|serial| serial == intent.serial)
                && self
                    .store
                    .thread(id)
                    .is_ok_and(|thread| thread == intent.source)
                && self
                    .profile_model_binding(&intent.target)
                    .is_ok_and(|binding| binding == intent.binding)
        });
        if !valid {
            self.cancel_provider_restore();
        }
    }

    fn restore_named_provider(&mut self, current: Value, account: String) -> Result<Value> {
        let mut candidate = current.clone();
        let preference = &current["rustProviderSelections"]["codex"];
        let model = historical_account_model(&current, "codex", &json!(account))
            .or_else(|| {
                (preference["accountID"] == account)
                    .then(|| preference["modelID"].as_str())
                    .flatten()
            })
            .unwrap_or("default")
            .to_owned();
        candidate["selection"] = json!({"provider":"codex","accountID":account,"modelID":model});
        if preference["accountID"] == account && preference["modelID"] == model {
            for key in ["effort", "speed"] {
                if let Some(value) = preference.get(key) {
                    candidate["selection"][key] = value.clone();
                }
            }
        }
        let binding = self.profile_model_binding(&candidate)?;
        // A still-live authenticated exact catalog is sufficient for a warm
        // switch. A historical account/session alone is never sufficient.
        if self.provider_restore.is_none() {
            if model != "default"
                && self
                    .model_catalog
                    .named_model_proof(&candidate, &binding, None)
                    .is_ok()
            {
                return self.commit_named_restore(current, candidate, &binding, None);
            }
            let response = self.model_catalog.refresh_named(binding.clone())?;
            let request = required(&response, "requestId")?.to_owned();
            self.provider_restore = Some(RestoreIntent {
                source: current,
                target: candidate,
                binding,
                serial: self.store.mutation_serial()?,
                request: request.clone(),
            });
            self.revision += 1;
            return Ok(
                json!({"pending":true,"requestId":request,"provider":"codex","accountID":account,"authenticationChecked":false}),
            );
        }
        self.poll_provider_restore();
        let intent = self
            .provider_restore
            .as_ref()
            .context("Provider restoration was cancelled; draft retained")?;
        ensure!(
            intent.source == current && intent.binding == binding && intent.target == candidate,
            "Provider restoration context changed; draft retained"
        );
        if self.model_catalog.poll() {
            self.revision += 1;
        }
        let status = self.model_catalog.named_status(&intent.request, &binding)?;
        if status["state"] == "loading" {
            return Ok(
                json!({"pending":true,"requestId":intent.request,"provider":"codex","accountID":account,"authenticationChecked":false}),
            );
        }
        ensure!(
            status["state"] == "ready" && status["authenticationChecked"] == true,
            "The remembered account is not authenticated or its catalog lookup failed; draft retained"
        );
        // Match Swift's same-account first-model fallback, never an older model
        // or another account's catalog. Unsupported remembered options remain
        // explicit errors rather than silently changing their meaning.
        let rows = status["models"]
            .as_array()
            .context("Invalid profile catalog")?;
        if !rows.iter().any(|row| row["id"] == model) {
            ensure!(
                candidate["selection"]["effort"].is_null()
                    && candidate["selection"]["speed"].is_null(),
                "Remembered model/options are unavailable; choose them explicitly"
            );
            candidate["selection"]["modelID"] = rows
                .first()
                .and_then(|row| row.get("id"))
                .context("This account reported no available models")?
                .clone();
        }
        let request = intent.request.clone();
        let result = self.commit_named_restore(current, candidate, &binding, Some(&request));
        if result.is_ok() {
            // Transfer the still-live job to ordinary selection authority. Do
            // not cancel it, reset its revocation bit, or manufacture a proof.
            self.provider_restore.take();
        }
        result
    }

    fn commit_named_restore(
        &mut self,
        current: Value,
        mut candidate: Value,
        binding: &NamedBinding,
        request: Option<&str>,
    ) -> Result<Value> {
        let id = required(&current, "id")?;
        ensure!(
            self.active_thread() == Some(id)
                && self.store.thread(id)? == current
                && !self.runs.contains_key(id)
                && !self.unsaved_threads.contains_key(id),
            "Saved composer changed; command draft retained"
        );
        ensure!(
            self.profile_model_binding(&candidate)? == *binding,
            "Target profile changed; draft retained"
        );
        let proof = self
            .model_catalog
            .named_model_proof(&candidate, binding, request)?;
        ensure!(
            proof.is_some(),
            "Automatic named restoration requires an authenticated explicit model"
        );
        crate::composer_policy::Policy::parse_named(
            &candidate,
            crate::composer_policy::Origin::Ordinary,
            proof.as_ref(),
        )?
        .preflight()?;
        remember_source(&mut candidate, &current)?;
        self.store.save(&candidate)?;
        self.revision += 1;
        Ok(
            json!({"thread":candidate,"model":candidate["selection"]["modelID"],"accountID":candidate["selection"]["accountID"],"restored":true,"provenance":"latest_authenticated_named_catalog","authenticationChecked":true,"accountRestored":true}),
        )
    }

    fn provider_switch_executable(&self, provider: &str) -> Option<PathBuf> {
        let variable = match provider {
            "codex" => "COINCIDE_CODEX_EXECUTABLE",
            "claude" => "COINCIDE_CLAUDE_EXECUTABLE",
            _ => return None,
        };
        std::env::var_os(variable).map(PathBuf::from).or_else(|| {
            self.provider_discovery.as_ref()?["providers"]
                .as_array()?
                .iter()
                .find(|row| row["provider"] == provider)?["executable"]
                .as_str()
                .map(PathBuf::from)
        })
    }
}

fn remember_source(target: &mut Value, source: &Value) -> Result<()> {
    if target["rustProviderSelections"].is_null() {
        target["rustProviderSelections"] = json!({});
    }
    ensure!(
        target["rustProviderSelections"].is_object(),
        "Invalid saved provider preferences; draft retained"
    );
    let provider = required(&source["selection"], "provider")?;
    target["rustProviderSelections"][provider] = source["selection"].clone();
    Ok(())
}

fn remembered_account(thread: &Value, provider: &str) -> Option<String> {
    let reference = provider_session(thread, provider);
    let value = reference
        .and_then(|session| session.get("accountID"))
        .or_else(|| thread["rustProviderSelections"][provider].get("accountID"))?;
    (!crate::composer_selection::default_account(value))
        .then(|| value.as_str().map(str::to_owned))
        .flatten()
}

fn provider_session<'a>(thread: &'a Value, provider: &str) -> Option<&'a Value> {
    thread["sessions"]
        .as_object()
        .and_then(|rows| rows.get(provider))
        .or_else(|| {
            thread["sessions"]
                .as_array()?
                .as_chunks::<2>()
                .0
                .iter()
                .find(|pair| pair[0] == provider)
                .map(|pair| &pair[1])
        })
}

fn historical_account_model<'a>(
    thread: &'a Value,
    provider: &str,
    account: &Value,
) -> Option<&'a str> {
    let item = thread["items"]
        .as_array()?
        .iter()
        .rev()
        .find(|item| item["provider"] == provider && !item["modelID"].is_null())?;
    // Do not skip a newer model from another account to find an older match.
    let item_account = item
        .get("accountID")
        .or_else(|| provider_session(thread, provider)?.get("accountID"))?;
    (item_account == account)
        .then(|| item["modelID"].as_str())
        .flatten()
}

fn historical_default_model<'a>(thread: &'a Value, provider: &str) -> Option<&'a str> {
    let item = thread["items"]
        .as_array()?
        .iter()
        .rev()
        .find(|item| item["provider"] == provider && !item["modelID"].is_null())?;
    // Legacy transcript items have no account field. Only an explicit default
    // session, with no archived named session, disambiguates those old rows.
    let default = crate::composer_selection::default_account;
    if let Some(account) = item.get("accountID") {
        if !default(account) {
            return None;
        }
    } else {
        let sessions = &thread["sessions"];
        let reference = sessions
            .as_object()
            .and_then(|rows| rows.get(provider))
            .or_else(|| {
                sessions
                    .as_array()?
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .find(|pair| pair[0] == provider)
                    .map(|pair| &pair[1])
            })?;
        if !reference.is_object()
            || !reference["sessionID"]
                .as_str()
                .is_some_and(|id| !id.is_empty())
            || !default(&reference["accountID"])
            || (!thread["accountSessions"].is_null() && !thread["accountSessions"].is_object())
            || thread["accountSessions"].as_object().is_some_and(|rows| {
                rows.keys()
                    .any(|key| key.starts_with(&format!("{provider}/")))
            })
        {
            return None;
        }
    }
    item["modelID"].as_str().filter(|model| *model != "default")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newly_appended_items_remember_selected_model_and_account_without_rewriting_history() {
        let previous = json!({"id":Uuid::new_v4(),"kind":"assistant","provider":"claude","text":"Retained","future":{"keep":true}});
        let mut thread = json!({"selection":{"provider":"codex","modelID":"synthetic-last-model","accountID":"synthetic-named"},"items":[previous]});
        append(&mut thread, "assistant", "Synthetic answer", None);
        assert_eq!(thread["items"][0], previous);
        assert_eq!(thread["items"][1]["modelID"], "synthetic-last-model");
        assert_eq!(thread["items"][1]["accountID"], "synthetic-named");
        assert!(historical_default_model(&thread, "codex").is_none());
        thread["selection"]["accountID"] = Value::Null;
        append(
            &mut thread,
            "assistant",
            "Synthetic default-account answer",
            None,
        );
        assert_eq!(
            historical_default_model(&thread, "codex"),
            Some("synthetic-last-model")
        );
    }

    #[test]
    fn recovering_transcript_and_closed_admissions_refuse_switch_without_writes() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let mut thread = engine.execute("threads.create", &json!({})).unwrap();
        thread["selection"] = json!({"provider":"claude","modelID":"default"});
        thread["draft"] = json!("/codex");
        engine.store.save(&thread).unwrap();
        let id = thread["id"].as_str().unwrap();
        engine.set_active_thread(Some(id.into())).unwrap();
        let expected: serde_json::Map<String, Value> = EXPECTED_FIELDS
            .into_iter()
            .map(|key| (key.into(), thread[key].clone()))
            .collect();
        let params = json!({"threadId":id,"provider":"codex","expected":expected});
        engine.unsaved_threads.insert(id.into(), thread.clone());
        assert!(
            engine
                .execute("agent.provider.select", &params)
                .unwrap_err()
                .to_string()
                .contains("recovering")
        );
        assert_eq!(engine.store.thread(id).unwrap(), thread);
        engine.unsaved_threads.remove(id);
        engine.freeze_admissions();
        assert!(
            engine
                .execute("agent.provider.select", &params)
                .unwrap_err()
                .to_string()
                .contains("frozen")
        );
        assert_eq!(engine.store.thread(id).unwrap(), thread);
        let workers = engine.provider_workers_status();
        assert_eq!(
            (
                workers.running,
                workers.returned,
                workers.panicked,
                workers.unclassified
            ),
            (0, 0, 0, 0)
        );
        let catalog = engine.model_catalog_shutdown_status().unwrap();
        assert_eq!(
            (
                catalog.running,
                catalog.returned,
                catalog.panicked,
                catalog.unclassified
            ),
            (0, 0, 0, 0)
        );
    }
}
