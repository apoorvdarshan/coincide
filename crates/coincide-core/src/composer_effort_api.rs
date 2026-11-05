//! Trusted Engine-owned effort proof lookup. No client-supplied proof or refresh.
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
                "Configure and explicitly refresh the Codex model catalog before choosing effort",
            )
    }
    pub(super) fn composer_effort_proof(
        &self,
        selection: &Value,
    ) -> Result<Option<crate::model_catalog::CodexEffortProof>> {
        if selection["effort"].is_null() {
            return Ok(None);
        }
        self.model_catalog
            .codex_effort_proof(selection, &self.composer_codex_executable()?)
    }
    pub(super) fn composer_target_effort_proof(
        &self,
        params: &Value,
    ) -> Result<Option<crate::model_catalog::CodexEffortProof>> {
        self.composer_effort_proof(&json!({"provider":params["provider"],"modelID":params.get("model").unwrap_or(&json!("default")),"accountID":params["accountId"],"effort":params["effort"]}))
    }
    pub(super) fn composer_effort_capability(&self, selection: &Value) -> Value {
        match self.composer_codex_executable() {
            Ok(executable) => self.model_catalog.effort_capability(selection, &executable),
            Err(error) => json!({"supported":false,"choices":[],"reason":error.to_string()}),
        }
    }
    pub(super) fn validate_composer_defaults(&self, defaults: &Value) -> Result<Value> {
        let proof = self.composer_effort_proof(&defaults["selection"])?;
        crate::composer_selection::validate_defaults_with_proof(defaults, proof.as_ref())
    }
}
