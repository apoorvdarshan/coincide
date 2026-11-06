//! Explicit selected-thread subscription limits; no quota or auth data is saved.
use super::*;
use crate::model_catalog::LimitsBinding;

impl Engine {
    pub(super) fn current_profile_limits_binding(&self) -> Option<LimitsBinding> {
        // An idle named-limits panel performs no profile filesystem inspection.
        if !self.model_catalog.has_named_limits_context() {
            return None;
        }
        let thread = self.store.thread(self.active_thread()?).ok()?;
        let named = self.profile_model_binding(&thread).ok()?;
        Some(LimitsBinding::capture(named, &thread))
    }
    pub(super) fn codex_profile_limits_command(
        &mut self,
        method: &str,
        p: &Value,
    ) -> Result<Value> {
        self.require_admissions()?;
        let fields = p
            .as_object()
            .context("Profile limits request must be an object")?;
        ensure!(
            fields.keys().all(|key| matches!(
                key.as_str(),
                "threadId" | "accountId" | "expectedSelection" | "requestId"
            )),
            "Unsupported profile limits option"
        );
        let refresh = method == "providers.codex.profiles.limits.refresh";
        ensure!(
            !refresh || !fields.contains_key("requestId"),
            "Refresh does not accept a request ID"
        );
        let thread = self.store.thread(required(p, "threadId")?)?;
        ensure!(
            p.get("accountId") == thread["selection"].get("accountID"),
            "Selected Codex profile changed"
        );
        ensure!(
            p.get("expectedSelection") == thread.get("selection"),
            "Selection changed; reload profile limits"
        );
        let named = self.profile_model_binding(&thread)?;
        let binding = LimitsBinding::capture(named, &thread);
        let result = if refresh {
            self.model_catalog.refresh_named_limits(binding)?
        } else {
            let id = required(p, "requestId")?;
            ensure!(id.len() <= 128, "Invalid profile limits request");
            if self.model_catalog.poll() {
                self.revision += 1;
            }
            return self.model_catalog.named_limits_status(id, &binding);
        };
        self.revision += 1;
        Ok(result)
    }
}
