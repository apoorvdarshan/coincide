//! A previous model name is a suggestion, never account or execution authority.
use super::*;

impl ModelCatalog {
    pub(crate) fn reported_default_model(
        &self,
        provider: &str,
        model: &str,
        executable: &std::path::Path,
    ) -> Option<String> {
        let latest = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.jobs.get(id))
            .find(|job| job.named.is_none() && job.response["provider"] == provider)?;
        if latest.response["state"] != "ready"
            || latest.cancelled.load(Ordering::Acquire)
            || latest.binding.as_ref() != Some(&EffortExecutable::read(executable).ok()?)
        {
            return None;
        }
        latest.response["models"]
            .as_array()?
            .iter()
            .any(|row| row["id"] == model)
            .then(|| model.to_owned())
    }
}

pub(crate) fn resolve_reported_preferences(
    thread: &mut Value,
    account: &str,
    rows: &[Value],
) -> Result<()> {
    let row = rows
        .iter()
        .find(|row| row["id"] == thread["selection"]["modelID"])
        .context("Model is absent from the account observation")?;
    let key = format!("codex/{account}");
    let desired = thread["modelPreferences"]
        .get(&key)
        .cloned()
        .unwrap_or_else(
            || json!({"effort":thread["selection"]["effort"],"speed":thread["selection"]["speed"]}),
        );
    ensure!(
        desired.is_object(),
        "Saved account options are unsupported; choose them explicitly"
    );
    let efforts = row["reportedEfforts"].as_array();
    let supported_effort = |effort: &Value| {
        effort.is_string() && efforts.is_some_and(|choices| choices.contains(effort))
    };
    let effort = if supported_effort(&desired["effort"]) {
        desired["effort"].clone()
    } else if !astra_model(thread["selection"]["modelID"].as_str().unwrap_or(""))
        && supported_effort(&row["reportedDefaultEffort"])
    {
        row["reportedDefaultEffort"].clone()
    } else {
        Value::Null
    };
    let speed = if desired["speed"].is_string()
        && row["reportedSpeeds"].as_array().is_some_and(|choices| {
            choices
                .iter()
                .any(|choice| choice["id"] == desired["speed"])
        }) {
        desired["speed"].clone()
    } else {
        Value::Null
    };
    for (option, value) in [("effort", effort), ("speed", speed)] {
        if !value.is_null() || thread["selection"].get(option).is_some() {
            thread["selection"][option] = value;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(executable: &std::path::Path, provider: &str, state: &str) -> Job {
        Job {
            named: None,
            binding: Some(EffortExecutable::read(executable).unwrap()),
            response: json!({"provider":provider,"accountID":"default","state":state,"models":[{"id":"synthetic-model"}]}),
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }
    fn insert(catalog: &mut ModelCatalog, id: &str, job: Job) {
        catalog.jobs.insert(id.into(), job);
        catalog.order.push_back(id.into());
    }
    #[test]
    fn only_latest_live_provider_and_executable_can_corroborate_history() {
        let dir = tempfile::tempdir().unwrap();
        let executable = dir.path().join("synthetic-executable");
        std::fs::write(&executable, b"metadata only, never executed").unwrap();
        let mut catalog = ModelCatalog::default();
        insert(&mut catalog, "first", job(&executable, "codex", "ready"));
        assert_eq!(
            catalog.reported_default_model("codex", "synthetic-model", &executable),
            Some("synthetic-model".into())
        );
        assert!(
            catalog
                .reported_default_model("claude", "synthetic-model", &executable)
                .is_none()
        );
        assert!(
            catalog
                .reported_default_model("codex", "unreported", &executable)
                .is_none()
        );
        for state in ["loading", "failed", "unsupported"] {
            insert(&mut catalog, state, job(&executable, "codex", state));
            assert!(
                catalog
                    .reported_default_model("codex", "synthetic-model", &executable)
                    .is_none()
            );
        }
        let cancelled = job(&executable, "codex", "ready");
        cancelled.cancelled.store(true, Ordering::Release);
        insert(&mut catalog, "cancelled", cancelled);
        assert!(
            catalog
                .reported_default_model("codex", "synthetic-model", &executable)
                .is_none()
        );
        insert(&mut catalog, "current", job(&executable, "codex", "ready"));
        std::fs::write(&executable, b"different executable identity and length").unwrap();
        assert!(
            catalog
                .reported_default_model("codex", "synthetic-model", &executable)
                .is_none()
        );
    }
    #[cfg(unix)]
    #[test]
    fn authenticated_named_catalog_is_never_default_account_authority() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let executable = root.join("synthetic-executable");
        std::fs::write(&executable, b"metadata only, never executed").unwrap();
        let account = uuid::Uuid::new_v4().to_string();
        crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
        let profile =
            crate::codex_login_profiles::LaunchContext::capture(&root, &account, &executable)
                .unwrap();
        let named =
            NamedBinding::capture(profile, &uuid::Uuid::new_v4().to_string(), &root).unwrap();
        let mut scoped = job(&executable, "codex", "ready");
        scoped.named = Some(named);
        scoped.response["accountID"] = json!(account);
        scoped.response["authenticationChecked"] = json!(true);
        let mut catalog = ModelCatalog::default();
        insert(&mut catalog, "named", scoped);
        assert!(
            catalog
                .reported_default_model("codex", "synthetic-model", &executable)
                .is_none()
        );
    }
}
