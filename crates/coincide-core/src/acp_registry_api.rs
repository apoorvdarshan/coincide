//! Native-only ACP discovery and activation. Conversation JSON cannot approve a binary.
use super::*;

impl Engine {
    /// Re-scan local executables after the user installs a provider. Metadata
    /// checks are kept off the UI thread and do not start a provider process.
    pub fn refresh_native_provider_discovery(&mut self) -> Result<()> {
        self.require_background_admission()?;
        if self.provider_discovery_pending {
            return Ok(());
        }
        self.provider_discovery_pending = true;
        let tx = self.workspace_tx.clone();
        let worker = std::thread::spawn(move || {
            workspace_api::publish_completion(
                tx,
                "provider-discovery".into(),
                json!(crate::provider_catalog::discover_installed_tools()),
            );
        });
        self.background_workers.track(worker);
        Ok(())
    }
    pub(super) fn append_native_acp_capabilities(&self, capabilities: &mut Value) -> Result<()> {
        let rows = capabilities["providers"]
            .as_array_mut()
            .context("Provider list missing")?;
        for entry in self.native_acp_agents()? {
            let provider = entry["provider"].as_str().context("ACP provider missing")?;
            let name = entry["displayName"].as_str().context("ACP name missing")?;
            rows.push(crate::composer_selection::acp_capability(provider, name));
        }
        Ok(())
    }
    pub fn native_acp_registry_view(&mut self) -> Value {
        self.poll_workspace_completions();
        let configured = self.native_configured_providers().unwrap_or_default();
        json!({"agents":self.acp_registry,"registered":self.native_acp_agents().unwrap_or_default(),
            "loading":self.acp_registry_pending,"error":self.acp_registry_error,
            "discovery":self.provider_discovery,"configured":configured})
    }
    pub fn refresh_native_acp_registry(&mut self) -> Result<()> {
        self.require_background_admission()?;
        if self.acp_registry_pending {
            return Ok(());
        }
        self.acp_registry_pending = true;
        let tx = self.workspace_tx.clone();
        let worker = std::thread::spawn(move || {
            workspace_api::publish_completion(
                tx.clone(),
                "acp-registry-local".into(),
                json!({"agents":crate::acp_registry::local_agents()}),
            );
            let result = match crate::acp_registry::fetch() {
                Ok(agents) => json!({"agents":agents}),
                Err(error) => {
                    json!({"agents":crate::acp_registry::local_agents(),"error":error.to_string()})
                }
            };
            workspace_api::publish_completion(tx, "acp-registry".into(), result);
        });
        self.background_workers.track(worker);
        Ok(())
    }
    /// The registry result is captured by the engine, not supplied by a chat or API caller.
    pub fn add_native_registry_agent(&mut self, id: &str) -> Result<String> {
        self.poll_workspace_completions();
        let provider = crate::acp_registry::provider_id(id).context("Invalid agent")?;
        if self
            .native_acp_agents()?
            .iter()
            .any(|row| row["provider"] == provider)
        {
            if self
                .provider_launch_configuration(&provider)
                .and_then(|configuration| configuration.context("Agent configuration missing"))
                .and_then(|configuration| configuration.validate_launch())
                .is_err()
            {
                self.reapprove_native_acp_agent(&provider)?;
            }
            return Ok(provider);
        }
        let agent = self
            .acp_registry
            .iter()
            .find(|agent| agent.id == id)
            .cloned()
            .context("Agent is no longer in the registry; refresh and try again")?;
        self.register_native_acp_agent(&agent)?;
        Ok(provider)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn native_registration_binds_the_selected_executable_and_arguments() {
        let (_root, mut engine, binary) = crate::provider_configuration::tests::fixture();
        let provider = "acp-fixture";
        assert!(engine.provider_launch_configuration(provider).is_err());
        let agent = crate::acp_registry::Agent {
            id: "fixture".into(),
            name: "Fixture Agent".into(),
            website: None,
            executable: Some(binary.clone()),
            arguments: vec!["--acp".into()],
            environment: Default::default(),
        };
        engine.register_native_acp_agent(&agent).unwrap();
        let rows = engine.native_acp_agents().unwrap();
        assert_eq!(
            rows,
            [json!({"provider":provider,"displayName":"Fixture Agent"})]
        );
        let config = engine
            .provider_launch_configuration(provider)
            .unwrap()
            .unwrap();
        let _scope = crate::provider_configuration::enter(Some(config));
        assert_eq!(
            crate::provider_configuration::current_acp_arguments(provider).unwrap(),
            ["--acp"]
        );
        assert!(crate::provider_configuration::current_acp_arguments("acp-other").is_err());
        std::fs::write(binary, b"changed executable").unwrap();
        assert!(engine.provider_launch_configuration(provider).is_err());
        assert_eq!(
            engine.add_native_registry_agent("fixture").unwrap(),
            provider
        );
        assert!(
            engine
                .provider_launch_configuration(provider)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn local_rescan_refreshes_installation_without_overwriting_live_registry_metadata() {
        let (_root, mut engine, binary) = crate::provider_configuration::tests::fixture();
        let live = crate::acp_registry::Agent {
            id: "fixture".into(),
            name: "Updated agent".into(),
            website: None,
            executable: None,
            arguments: vec!["--new-acp".into()],
            environment: Default::default(),
        };
        engine.acp_registry = vec![live.clone()];
        let local = crate::acp_registry::Agent {
            name: "Older agent".into(),
            executable: Some(binary.clone()),
            arguments: vec!["--old-acp".into()],
            ..live
        };
        engine
            .workspace_tx
            .send(("acp-registry-local".into(), json!({"agents":[local]})))
            .unwrap();
        engine.poll_workspace_completions();
        assert_eq!(engine.acp_registry[0].name, "Updated agent");
        assert_eq!(engine.acp_registry[0].arguments, ["--new-acp"]);
        assert_eq!(
            engine.acp_registry[0].executable.as_deref(),
            Some(binary.as_path())
        );
    }
}
