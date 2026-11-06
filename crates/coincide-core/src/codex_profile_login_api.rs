//! Explicit profile enrollment commands; operation IDs never become account
//! authority and profile selection remains a separate optimistic thread action.
use super::*;
use crate::codex_login_profiles as profiles;

impl Engine {
    pub(super) fn codex_profile_login_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        let fields = p
            .as_object()
            .context("Codex sign-in request must be an object")?;
        let account = required(p, "accountId")?;
        profiles::canonical_id(account)?;
        if method == "providers.codex.profiles.login.start" {
            ensure!(
                fields.keys().all(|key| key == "accountId"),
                "Unsupported sign-in parameter"
            );
            ensure!(
                self.runs.is_empty(),
                "Stop running turns before signing into a Codex profile"
            );
            ensure!(
                self.codex_profile_login
                    .as_ref()
                    .is_none_or(|operation| !operation.active()),
                "Finish or cancel the current Codex sign-in first"
            );
            profiles::account(&profiles::configuration(&self.store)?, account)?;
            let profile = profiles::LaunchContext::capture(
                &self.store.data_directory()?,
                account,
                &self.composer_codex_executable()?,
            )?;
            let operation = agent::codex_profile_login::Operation::start(profile);
            self.provider_workers.push(operation.completion());
            let status = operation.status();
            self.codex_profile_login = Some(operation);
            self.revision += 1;
            return Ok(status);
        }
        ensure!(
            fields
                .keys()
                .all(|key| matches!(key.as_str(), "accountId" | "operationId")),
            "Unsupported sign-in parameter"
        );
        let id = required(p, "operationId")?;
        profiles::canonical_id(id)?;
        let operation = self
            .codex_profile_login
            .as_mut()
            .context("Codex sign-in operation is no longer available")?;
        ensure!(
            operation.matches(id, account),
            "Codex sign-in target changed"
        );
        if method == "providers.codex.profiles.login.cancel" {
            operation.cancel();
        }
        operation.poll();
        Ok(operation.status())
    }
    pub(super) fn poll_codex_profile_login(&mut self) {
        if self
            .codex_profile_login
            .as_mut()
            .is_some_and(|operation| operation.poll())
        {
            self.revision += 1;
        }
    }
    /// Native shutdown owner only. Cancellation remains a request until the
    /// shared provider-worker accounting observes the actual thread join.
    pub fn cancel_codex_profile_login(&mut self) {
        if let Some(operation) = &mut self.codex_profile_login {
            operation.cancel();
        }
    }
}
