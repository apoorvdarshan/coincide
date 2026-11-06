//! Source-owned account restoration. Candidate readiness is an actual bounded
//! authenticated observation, never a configured path, account name or import.
use super::*;
use crate::model_catalog::{DefaultBinding, NamedBinding};

#[derive(Clone)]
enum Binding {
    Named(NamedBinding),
    Default(DefaultBinding),
}
#[derive(Clone)]
struct Candidate {
    thread: Value,
    binding: Binding,
    account: String,
}
pub(super) struct RestoreIntent {
    source: Value,
    configuration: Value,
    candidates: Vec<Candidate>,
    index: usize,
    request: Option<String>,
    pub(super) token: String,
    serial: u64,
    scope_generation: Option<u64>,
    requested: String,
    explicit: bool,
    automatic: bool,
}
impl RestoreIntent {
    fn account_ids(&self) -> Vec<String> {
        self.candidates
            .iter()
            .map(|candidate| candidate.account.clone())
            .collect()
    }
    fn pending(&self) -> Value {
        let candidate = &self.candidates[self.index];
        json!({"pending":true,"requestId":self.token,"catalogRequestId":self.request,"provider":"codex","accountID":candidate.account,
            "requestedAccountID":self.requested,"explicitAccount":self.explicit,"candidateAccountIDs":self.account_ids(),
            "fallback":candidate.account!=self.requested,"authenticationChecked":false})
    }
    fn receipt(&self, mut response: Value, account: &str) -> Value {
        response["requestId"] = json!(self.token);
        response["catalogRequestId"] = json!(self.request);
        response["requestedAccountID"] = json!(self.requested);
        response["explicitAccount"] = json!(self.explicit);
        response["candidateAccountIDs"] = json!(self.account_ids());
        response["fallback"] = json!(account != self.requested);
        response
    }
}
fn account_value(account: &str) -> Value {
    if account == "default" {
        Value::Null
    } else {
        json!(account)
    }
}
impl Engine {
    pub(super) fn cancel_provider_restore(&mut self) {
        if let Some(intent) = self.provider_restore.take()
            && let Some(request) = intent.request
        {
            self.model_catalog.cancel_named_restore(&request);
        }
    }
    fn restore_intent_valid(&self, intent: &RestoreIntent) -> bool {
        let id = intent.source["id"].as_str().unwrap_or("");
        if self.admissions_frozen()
            || self.active_thread() != Some(id)
            || self.runs.contains_key(id)
            || self.unsaved_threads.contains_key(id)
        {
            return false;
        }
        let Ok(current) = self.store.thread(id) else {
            return false;
        };
        if intent.automatic {
            if self.store.selection_scope_generation(id) != intent.scope_generation
                || !crate::store::same_composer_scope(&current, &intent.source)
                || !current["botID"].is_null()
                || !current["rustBotContext"].is_null()
                || !self.store.is_imported(id).is_ok_and(|imported| !imported)
            {
                return false;
            }
            return intent.candidates.len() == 1
                && match &intent.candidates[0].binding {
                    Binding::Named(binding) => self
                        .profile_model_binding(&current)
                        .is_ok_and(|current| current == *binding),
                    Binding::Default(_) => false,
                };
        }
        self.store
            .mutation_serial()
            .is_ok_and(|serial| serial == intent.serial)
            && current == intent.source
            && crate::codex_login_profiles::configuration(&self.store)
                .is_ok_and(|configuration| configuration == intent.configuration)
            && intent
                .candidates
                .iter()
                .all(|candidate| self.restore_candidate_valid(candidate))
    }
    fn restore_candidate_valid(&self, candidate: &Candidate) -> bool {
        match &candidate.binding {
            Binding::Named(binding) => self
                .profile_model_binding(&candidate.thread)
                .is_ok_and(|current| current == *binding),
            Binding::Default(binding) => self
                .composer_codex_executable()
                .and_then(|exe| {
                    DefaultBinding::capture(
                        binding.thread(),
                        &self.working_directory(&candidate.thread)?,
                        &exe,
                    )
                })
                .is_ok_and(|current| current == *binding),
        }
    }
    pub(super) fn poll_provider_restore(&mut self) {
        if self
            .provider_restore
            .as_ref()
            .is_some_and(|intent| !self.restore_intent_valid(intent))
        {
            self.cancel_provider_restore();
        }
    }
    fn restore_candidate(&self, current: &Value, account: &str) -> Result<Candidate> {
        let mut thread = current.clone();
        let value = account_value(account);
        let key = format!("codex/{account}");
        let remembered = &current["rustAccountSelections"][&key];
        let provider_preference = &current["rustProviderSelections"]["codex"];
        let preference = if remembered.is_object() {
            remembered
        } else {
            provider_preference
        };
        let same = crate::composer_selection::default_account(&current["selection"]["accountID"])
            == (account == "default")
            && (account == "default" || current["selection"]["accountID"] == account)
            && current["selection"]["provider"] == "codex";
        let model = if same {
            current["selection"]["modelID"].as_str()
        } else {
            None
        }
        .or_else(|| provider_switch_api::historical_account_model(current, "codex", &value))
        .or_else(|| {
            let own = if account == "default" {
                crate::composer_selection::default_account(&preference["accountID"])
            } else {
                preference["accountID"] == account
            };
            own.then(|| preference["modelID"].as_str()).flatten()
        })
        .unwrap_or("default");
        thread["selection"] = json!({"provider":"codex","modelID":model});
        if account != "default" {
            thread["selection"]["accountID"] = json!(account);
        }
        let options = if same {
            &current["selection"]
        } else {
            preference
        };
        let own = if account == "default" {
            crate::composer_selection::default_account(&options["accountID"])
        } else {
            options["accountID"] == account
        };
        if own && options["modelID"] == model {
            for option in ["effort", "speed"] {
                if let Some(value) = options.get(option) {
                    thread["selection"][option] = value.clone();
                }
            }
        }
        composer_choices_api::seed_preferences(&mut thread, current)?;
        let desired = thread.clone();
        composer_choices_api::seed_preferences(&mut thread, &desired)?;
        let binding = if account == "default" {
            Binding::Default(DefaultBinding::capture(
                required(current, "id")?,
                &self.working_directory(current)?,
                &self.composer_codex_executable()?,
            )?)
        } else {
            Binding::Named(self.profile_model_binding(&thread)?)
        };
        Ok(Candidate {
            thread,
            binding,
            account: account.into(),
        })
    }
    pub(super) fn restore_provider_accounts(&mut self, current: Value, p: &Value) -> Result<Value> {
        if let Some(intent) = self.provider_restore.as_ref() {
            let explicit_match = p.get("accountId").is_some() == intent.explicit
                && (p["restoreCurrent"] == true) == intent.automatic
                && (!intent.explicit
                    || (if crate::composer_selection::default_account(&p["accountId"]) {
                        Some("default")
                    } else {
                        p["accountId"].as_str()
                    }) == Some(intent.requested.as_str()));
            let valid = explicit_match
                && (intent.automatic || intent.source == current)
                && self.restore_intent_valid(intent);
            if !valid {
                self.cancel_provider_restore();
                bail!(
                    "Provider restore source, requested account or target changed; draft retained"
                );
            }
            let intent = self.provider_restore.take().unwrap();
            return self.advance_restore(intent);
        }
        let mut source_syntax = current.clone();
        if current["selection"]["provider"] == "codex"
            && !crate::composer_selection::default_account(&current["selection"]["accountID"])
        {
            crate::codex_login_profiles::validate_model_thread(&current)?;
            source_syntax = crate::codex_login_profiles::validation_view(&current);
        }
        crate::composer_selection::validate_selection(&source_syntax["selection"])?;
        for option in ["effort", "speed"] {
            source_syntax["selection"]
                .as_object_mut()
                .unwrap()
                .remove(option);
        }
        crate::composer_selection::validate_thread_base(&source_syntax)?;
        let explicit = p.get("accountId").is_some();
        let automatic = p["restoreCurrent"] == true;
        ensure!(
            p.get("restoreCurrent").is_none() || automatic,
            "restoreCurrent must be true when supplied"
        );
        ensure!(
            !automatic
                || (current["selection"]["provider"] == "codex"
                    && !crate::composer_selection::default_account(
                        &current["selection"]["accountID"]
                    )
                    && !explicit),
            "Only a saved named selection can restore itself"
        );
        let requested = if explicit {
            let value = &p["accountId"];
            ensure!(
                value.is_null() || value.is_string(),
                "Account must be text or null"
            );
            if crate::composer_selection::default_account(value) {
                "default".into()
            } else {
                required(p, "accountId")?.to_owned()
            }
        } else if automatic {
            required(&current["selection"], "accountID")?.to_owned()
        } else {
            let value = provider_switch_api::provider_session(&current, "codex")
                .and_then(|session| session.get("accountID"))
                .or_else(|| current["rustProviderSelections"]["codex"].get("accountID"))
                .unwrap_or(&Value::Null);
            if crate::composer_selection::default_account(value) {
                "default".into()
            } else {
                value
                    .as_str()
                    .context("Invalid remembered account")?
                    .to_owned()
            }
        };
        let configuration = crate::codex_login_profiles::configuration(&self.store)?;
        let mut accounts = if !explicit
            && !automatic
            && configuration["accounts"]
                .as_object()
                .is_some_and(|accounts| accounts.is_empty())
        {
            Vec::new()
        } else {
            vec![requested.clone()]
        };
        if !explicit && !automatic && !accounts.is_empty() {
            if requested != "default" {
                accounts.push("default".into());
            }
            for account in crate::codex_login_profiles::ordered_accounts(&configuration)? {
                if !accounts.contains(&account) {
                    accounts.push(account);
                }
            }
        }
        let mut candidates = Vec::new();
        for account in accounts {
            match self.restore_candidate(&current, &account) {
                Ok(mut candidate) => {
                    if automatic {
                        candidate.thread = current.clone();
                    }
                    candidates.push(candidate)
                }
                Err(error) if explicit || automatic => return Err(error),
                Err(_) => {} // A missing/invalid configured account is not ready.
            }
        }
        let scope_generation = if automatic {
            Some(
                self.store
                    .capture_selection_scope(required(&current, "id")?)?,
            )
        } else {
            None
        };
        let intent = RestoreIntent {
            source: current,
            configuration,
            candidates,
            index: 0,
            request: None,
            token: Uuid::new_v4().to_string(),
            serial: self.store.mutation_serial()?,
            scope_generation,
            requested,
            explicit,
            automatic,
        };
        self.advance_restore(intent)
    }
    fn advance_restore(&mut self, mut intent: RestoreIntent) -> Result<Value> {
        if !self.restore_intent_valid(&intent) {
            if let Some(request) = &intent.request {
                self.model_catalog.cancel_named_restore(request);
            }
            bail!("Provider restore source or target changed; draft retained");
        }
        while intent.index < intent.candidates.len() {
            let candidate = intent.candidates[intent.index].clone();
            let ready = match &candidate.binding {
                Binding::Named(binding) => self.model_catalog.ready_named_restore(binding),
                Binding::Default(binding) => self.model_catalog.ready_default_restore(binding),
            };
            let status = if let Some(request) = &intent.request {
                let result = match &candidate.binding {
                    Binding::Named(binding) => self.model_catalog.named_status(request, binding),
                    Binding::Default(binding) => {
                        self.model_catalog.default_restore_status(request, binding)
                    }
                };
                match result {
                    Ok(status) => status,
                    Err(error) => {
                        self.model_catalog.cancel_named_restore(request);
                        return Err(error);
                    }
                }
            } else if let Some(ready) = ready {
                intent.request = ready["requestId"].as_str().map(str::to_owned);
                ready
            } else {
                let scope_busy = match &candidate.binding {
                    Binding::Default(binding) => {
                        self.model_catalog.default_restore_scope_busy(binding)
                    }
                    Binding::Named(_) => false,
                };
                if !self.model_catalog.restore_admission_available() || scope_busy {
                    let response = intent.pending();
                    self.provider_restore = Some(intent);
                    return Ok(response);
                }
                let response = match &candidate.binding {
                    Binding::Named(binding) => self.model_catalog.refresh_named(binding.clone()),
                    Binding::Default(binding) => {
                        self.model_catalog.refresh_default_restore(binding.clone())
                    }
                };
                match response {
                    Ok(response) => {
                        intent.request = Some(required(&response, "requestId")?.to_owned());
                        response
                    }
                    Err(error) => return Err(error),
                }
            };
            if status["state"] == "loading" {
                let response = intent.pending();
                self.provider_restore = Some(intent);
                self.revision += 1;
                return Ok(response);
            }
            if status["state"] == "ready" && status["authenticationChecked"] == true {
                let rows = status["models"]
                    .as_array()
                    .context("Invalid account model observation")?;
                if intent.automatic || rows.iter().any(|row| row["id"] != "default") {
                    let result = self.commit_restored_candidate(&intent, candidate, &status);
                    if result.is_err() {
                        if let Some(request) = &intent.request {
                            self.model_catalog.cancel_named_restore(request);
                        }
                    }
                    return result;
                }
            }
            if let Some(request) = intent.request.take() {
                self.model_catalog.cancel_named_restore(&request);
            }
            ensure!(
                !intent.explicit && !intent.automatic,
                "This account is not authenticated or reported no runnable models; draft retained"
            );
            intent.index += 1;
        }
        ensure!(
            !intent.automatic && (!intent.explicit || intent.requested == "default"),
            "This account is unavailable; draft retained"
        );
        let response = self.select_default_provider(intent.source.clone(), "codex")?;
        let mut response = intent.receipt(response, "default");
        response["fallbackReason"] = json!("no_authenticated_account_ready");
        Ok(response)
    }
    fn commit_restored_candidate(
        &mut self,
        intent: &RestoreIntent,
        mut candidate: Candidate,
        status: &Value,
    ) -> Result<Value> {
        ensure!(
            self.restore_intent_valid(intent),
            "Saved composer or target changed; draft retained"
        );
        if intent.automatic {
            let Binding::Named(binding) = &candidate.binding else {
                bail!("Saved account warmup requires its named profile");
            };
            let request = intent
                .request
                .as_deref()
                .context("Missing saved account observation")?;
            let current = self.store.thread(required(&intent.source, "id")?)?;
            let readiness = (|| -> Result<()> {
                let proof =
                    self.model_catalog
                        .named_model_proof(&current, binding, Some(request))?;
                crate::composer_policy::Policy::parse_named(
                    &current,
                    crate::composer_policy::Origin::Ordinary,
                    proof.as_ref(),
                )?
                .preflight()
            })();
            let execution_ready = readiness.is_ok();
            let reason = readiness.err().map(|error| error.to_string());
            // An ordinary reopen is not a composer choice: no selection,
            // preference, default, draft, session or transcript write occurs.
            let response = json!({"thread":current,"model":current["selection"]["modelID"],"accountID":candidate.account,
                "selectionUnchanged":true,"executionReady":execution_ready,"reason":reason,"restored":false,"accountRestored":false,"authenticationChecked":true,"provenance":"selected_account_catalog","catalog":status});
            return Ok(intent.receipt(response, &candidate.account));
        }
        let rows = status["models"]
            .as_array()
            .context("Invalid account model list")?;
        if candidate.thread["selection"]["modelID"] == "default"
            || !rows
                .iter()
                .any(|row| row["id"] == candidate.thread["selection"]["modelID"])
        {
            candidate.thread["selection"]["modelID"] = rows
                .iter()
                .find(|row| row["id"] != "default")
                .and_then(|row| row.get("id"))
                .context("No runnable models")?
                .clone();
        }
        let request = intent
            .request
            .as_deref()
            .context("Missing account observation")?;
        match &candidate.binding {
            Binding::Named(binding) => {
                self.model_catalog.resolve_named_preferences(
                    &mut candidate.thread,
                    binding,
                    Some(request),
                )?;
                let proof = self.model_catalog.named_model_proof(
                    &candidate.thread,
                    binding,
                    Some(request),
                )?;
                ensure!(
                    proof.is_some(),
                    "Named restore requires an explicit authenticated model"
                );
                crate::composer_policy::Policy::parse_named(
                    &candidate.thread,
                    crate::composer_policy::Origin::Ordinary,
                    proof.as_ref(),
                )?
                .preflight()?;
            }
            Binding::Default(binding) => {
                binding.validate()?;
                crate::model_catalog::resolve_reported_preferences(
                    &mut candidate.thread,
                    &candidate.account,
                    rows,
                )?;
                let proof = self.composer_effort_proof(&candidate.thread["selection"])?;
                crate::composer_policy::Policy::parse_with_effort_proof(
                    &candidate.thread,
                    crate::composer_policy::Origin::Ordinary,
                    proof.as_ref(),
                )?
                .preflight()?;
            }
        }
        provider_switch_api::remember_source(&mut candidate.thread, &intent.source)?;
        if intent.automatic {
            self.store.save(&candidate.thread)?;
        } else {
            self.save_composer_choice(
                &intent.source,
                &mut candidate.thread,
                &json!({"rememberComposerChoice":true}),
            )?;
        }
        self.revision += 1;
        let named = candidate.account != "default";
        let response = json!({"thread":candidate.thread,"model":candidate.thread["selection"]["modelID"],"accountID":candidate.account,"restored":true,"accountRestored":named,"authenticationChecked":true,
            "provenance":if named{"latest_authenticated_named_catalog"}else{"latest_authenticated_default_catalog"},"catalog":status});
        Ok(intent.receipt(response, &candidate.account))
    }
}
