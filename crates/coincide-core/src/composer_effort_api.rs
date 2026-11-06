//! Trusted Engine-owned effort/speed proof lookup. No client-supplied proof or refresh.
use super::*;
impl Engine {
    pub(super) fn composer_codex_executable(&self) -> Result<PathBuf> {
        std::env::var_os("COINCIDE_CODEX_EXECUTABLE")
            .map(PathBuf::from)
            .or_else(|| {
                self.provider_discovery.as_ref()?["providers"]
                    .as_array()?
                    .iter()
                    .find(|entry| entry["provider"] == "codex")?["executable"]
                    .as_str()
                    .map(PathBuf::from)
            })
            .context(
                "Configure and explicitly refresh the Codex model catalog before choosing effort/speed",
            )
    }
    pub(super) fn composer_effort_proof(
        &self,
        selection: &Value,
    ) -> Result<Option<crate::model_catalog::CodexEffortProof>> {
        if selection["effort"].is_null()
            && selection["speed"].is_null()
            && !crate::model_catalog::astra_default_needed(selection)
        {
            return Ok(None);
        }
        self.model_catalog
            .codex_effort_proof(selection, &self.composer_codex_executable()?)
    }
    /// Only ordinary stored threads may obtain automatic Astra default proof.
    pub(super) fn composer_thread_effort_proof(
        &self,
        thread: &Value,
    ) -> Result<Option<crate::model_catalog::CodexEffortProof>> {
        if !thread["rustBotContext"].is_null()
            || !thread["botID"].is_null()
            || self.store.is_imported(required(thread, "id")?)?
        {
            return Ok(None);
        }
        self.composer_effort_proof(&thread["selection"])
    }
    /// Editing an all-null Astra selection is not a request to execute its
    /// default. Target validation still requires admitted runtime authority.
    pub(super) fn composer_current_selection_proof(
        &self,
        thread: &Value,
    ) -> Result<Option<crate::model_catalog::CodexEffortProof>> {
        if crate::model_catalog::astra_default_needed(&thread["selection"])
            && thread["selection"]["speed"].is_null()
        {
            return Ok(None);
        }
        self.composer_thread_effort_proof(thread)
    }
    pub(super) fn composer_target_effort_proof(
        &self,
        params: &Value,
    ) -> Result<Option<crate::model_catalog::CodexEffortProof>> {
        self.composer_effort_proof(&json!({"provider":params["provider"],"modelID":params.get("model").unwrap_or(&json!("default")),"accountID":params["accountId"],"effort":params["effort"],"speed":params["speed"]}))
    }
    pub(super) fn composer_effort_capability(&self, selection: &Value) -> Value {
        match self.composer_codex_executable() {
            Ok(executable) => self.model_catalog.effort_capability(selection, &executable),
            Err(error) => {
                let mut null_selection = selection.clone();
                null_selection["effort"] = Value::Null;
                json!({"supported":false,"choices":[],"reportedDefault":null,"effectiveDefault":null,
                    "appDefaultRequired":crate::model_catalog::astra_default_needed(&null_selection),"appDefaultAvailable":false,"reason":error.to_string()})
            }
        }
    }
    pub(super) fn composer_speed_capability(&self, selection: &Value) -> Value {
        match self.composer_codex_executable() {
            Ok(executable) => self.model_catalog.speed_capability(selection, &executable),
            Err(error) => json!({"supported":false,"choices":[],"reason":error.to_string()}),
        }
    }
    pub(super) fn validate_composer_defaults(&self, defaults: &Value) -> Result<Value> {
        if defaults["selection"]["provider"] == "codex"
            && !crate::composer_selection::default_account(&defaults["selection"]["accountID"])
        {
            let fields = defaults
                .as_object()
                .context("Composer defaults must be an object")?;
            ensure!(
                fields.keys().all(|key| matches!(
                    key.as_str(),
                    "selection" | "accessMode" | "interactionMode"
                )),
                "Composer defaults contain unsupported options"
            );
            let mut value = defaults.clone();
            if value["accessMode"].is_null() {
                value["accessMode"] = json!("approval");
            }
            if value["interactionMode"].is_null() {
                value["interactionMode"] = json!("build");
            }
            crate::codex_login_profiles::validate_model_thread(&value)?;
            let account = required(&value["selection"], "accountID")?;
            crate::codex_login_profiles::account(
                &crate::codex_login_profiles::configuration(&self.store)?,
                account,
            )?;
            // Saving a default admits metadata only. A new thread cannot borrow
            // this thread's catalog proof; it authenticates its own observation.
            let mut syntax = crate::codex_login_profiles::validation_view(&value);
            for option in ["effort", "speed"] {
                syntax["selection"].as_object_mut().unwrap().remove(option);
            }
            crate::composer_selection::validate_thread_base(&syntax)?;
            return Ok(value);
        }
        let proof = self.composer_effort_proof(&defaults["selection"])?;
        crate::composer_selection::validate_defaults_with_proof(defaults, proof.as_ref())
    }
}
