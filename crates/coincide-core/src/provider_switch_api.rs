//! Atomic provider switching. Historical preferences never grant execution authority.
use super::*;

pub(super) use super::provider_restore_api::RestoreIntent;

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
            (3..=6).contains(&fields.len())
                && fields.keys().all(|key| matches!(
                    key.as_str(),
                    "threadId"
                        | "provider"
                        | "expected"
                        | "restoreRequestId"
                        | "restoreCurrent"
                        | "accountId"
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
                    .is_some_and(|intent| intent.token == request),
                "Provider restoration was cancelled or superseded; draft retained"
            );
        } else {
            self.cancel_provider_restore();
        }
        Provider::from_name(provider)?;
        ensure!(
            (p.get("accountId").is_none() && p.get("restoreCurrent").is_none())
                || provider == "codex",
            "Explicit account restoration is available only for Codex"
        );
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
            current["selection"]["provider"] != provider
                || (provider == "codex" && p.get("accountId").is_some())
                || (p.get("restoreCurrent") == Some(&json!(true))
                    && provider == "codex"
                    && !crate::composer_selection::default_account(
                        &current["selection"]["accountID"]
                    )),
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
        if provider == "codex" {
            let configuration = crate::codex_login_profiles::configuration(&self.store)?;
            if p.get("accountId").is_some()
                || p.get("restoreCurrent").is_some()
                || remembered_account(&current, provider).is_some()
                || configuration["accounts"]
                    .as_object()
                    .is_some_and(|accounts| !accounts.is_empty())
            {
                return self.restore_provider_accounts(current, p);
            }
        }
        self.select_default_provider(current, provider)
    }

    pub(super) fn select_default_provider(
        &mut self,
        current: Value,
        provider: &str,
    ) -> Result<Value> {
        let id = required(&current, "id")?;
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
        let preference = &current["rustProviderSelections"][provider];
        if restored.is_some()
            && crate::composer_selection::default_account(&preference["accountID"])
            && preference["modelID"] == model
        {
            for key in ["effort", "speed"] {
                if let Some(value) = preference.get(key) {
                    selection[key] = value.clone();
                }
            }
        }
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
        self.save_composer_choice(
            &current,
            &mut thread,
            &json!({"rememberComposerChoice":true}),
        )?;
        self.revision += 1;
        Ok(
            json!({"thread":thread,"model":model,"restored":restored.is_some(),
            "provenance":if restored.is_some(){"latest_default_catalog"}else{"provider_default"},
            "authenticationChecked":false,"accountRestored":false}),
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

pub(super) fn remember_source(target: &mut Value, source: &Value) -> Result<()> {
    if target["rustProviderSelections"].is_null() {
        target["rustProviderSelections"] = json!({});
    }
    ensure!(
        target["rustProviderSelections"].is_object(),
        "Invalid saved provider preferences; draft retained"
    );
    let provider = required(&source["selection"], "provider")?;
    target["rustProviderSelections"][provider] = source["selection"].clone();
    if !crate::composer_selection::default_account(&source["selection"]["accountID"]) {
        if target["rustAccountSelections"].is_null() {
            target["rustAccountSelections"] = json!({});
        }
        ensure!(
            target["rustAccountSelections"].is_object(),
            "Invalid saved account selections"
        );
        let key = composer_choices_api::account_key(&source["selection"])?;
        target["rustAccountSelections"][key] = source["selection"].clone();
    }
    Ok(())
}

pub(super) fn remembered_account(thread: &Value, provider: &str) -> Option<String> {
    let reference = provider_session(thread, provider);
    let value = reference
        .and_then(|session| session.get("accountID"))
        .or_else(|| thread["rustProviderSelections"][provider].get("accountID"))?;
    (!crate::composer_selection::default_account(value))
        .then(|| value.as_str().map(str::to_owned))
        .flatten()
}

pub(super) fn provider_session<'a>(thread: &'a Value, provider: &str) -> Option<&'a Value> {
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

pub(super) fn historical_account_model<'a>(
    thread: &'a Value,
    provider: &str,
    account: &Value,
) -> Option<&'a str> {
    let item = thread["items"].as_array()?.iter().rev().find(|item| {
        if item["provider"] != provider || item["modelID"].is_null() {
            return false;
        }
        item.get("accountID")
            .or_else(|| provider_session(thread, provider)?.get("accountID"))
            .is_some_and(|value| {
                value == account
                    || (crate::composer_selection::default_account(value)
                        && crate::composer_selection::default_account(account))
            })
    })?;
    item["modelID"].as_str()
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
