//! Explicit Rust configuration is kept separate from preserved/imported Swift
//! settings. Discovery and account selection never imply risk acknowledgement.
use super::*;
const DOCUMENT: &str = "rust-antigravity.json";
pub(super) const RISK_KEY: &str = "provider:antigravity-account-risk";
const NOTICE: &str = "Using Antigravity through third-party software may violate Google's terms and risk account suspension.";
fn account_id(value: &Value) -> Result<String> {
    let id = value.as_str().unwrap_or("default");
    ensure!(
        value.is_null() || value.is_string(),
        "Antigravity accountId must be text"
    );
    ensure!(
        id == "default" || Uuid::parse_str(id).is_ok_and(|uuid| uuid.to_string() == id),
        "Antigravity accountId must be default or a canonical UUID"
    );
    Ok(id.into())
}
fn acknowledged(config: &Value) -> bool {
    config["riskAcknowledgement"]["key"] == RISK_KEY
        && config["riskAcknowledgement"]["accepted"] == true
}
fn absolute_file(value: &Value) -> Result<PathBuf> {
    let path = PathBuf::from(
        value
            .as_str()
            .context("Antigravity executable must be explicitly configured")?,
    );
    ensure!(
        path.is_absolute(),
        "Antigravity executable must be an absolute path"
    );
    let path = path
        .canonicalize()
        .context("Antigravity executable is unavailable")?;
    ensure!(path.is_file(), "Antigravity executable is not a file");
    let helper = path.with_file_name("localharness_external");
    ensure!(
        helper.is_file(),
        "Antigravity requires localharness_external beside its executable"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        ensure!(
            std::fs::metadata(&path)?.permissions().mode() & 0o111 != 0
                && std::fs::metadata(helper)?.permissions().mode() & 0o111 != 0,
            "Antigravity executable/helper must be executable"
        );
    }
    Ok(path)
}
impl Engine {
    fn antigravity_configuration(&self) -> Result<Value> {
        let value = self
            .store
            .local_document(DOCUMENT)?
            .unwrap_or_else(|| json!({"version":1,"accounts":{}}));
        ensure!(
            value.is_object() && value["version"] == 1 && value["accounts"].is_object(),
            "Invalid Rust Antigravity configuration"
        );
        Ok(value)
    }
    pub(super) fn antigravity_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        let mut config = self.antigravity_configuration()?;
        match method {
            "providers.antigravity.status" => {}
            "providers.antigravity.configure" => {
                ensure!(
                    !self.runs.values().any(|run| run.provider == "antigravity"),
                    "Stop Antigravity turns before changing its configuration"
                );
                let id = account_id(&p["accountId"])?;
                ensure!(
                    p["auth"].as_str() == Some("login"),
                    "Antigravity currently supports explicitly selected subscription login accounts only"
                );
                let executable = absolute_file(&p["executable"])?;
                let source = PathBuf::from(
                    p["sourceProfile"]
                        .as_str()
                        .context("Select the original signed-in Antigravity profile explicitly")?,
                );
                ensure!(
                    source.is_absolute(),
                    "Antigravity sourceProfile must be absolute"
                );
                let source = source
                    .canonicalize()
                    .context("Antigravity source profile is unavailable")?;
                ensure!(
                    source.is_dir(),
                    "Antigravity source profile must be a directory"
                );
                let data = self.store.data_directory()?;
                ensure!(
                    !source.starts_with(&data) && !data.starts_with(&source),
                    "Antigravity source profile must be separate from Rust app data"
                );
                if let Some(previous) = config["accounts"].get(&id) {
                    ensure!(
                        previous["sourceProfile"] == json!(source),
                        "This Antigravity account is bound to a different source profile; add a new account UUID to switch accounts"
                    );
                }
                let mut account = config["accounts"].get(&id).cloned().unwrap_or(json!({}));
                ensure!(
                    account.is_object(),
                    "Invalid Antigravity account configuration"
                );
                if let Some(name) = p.get("name") {
                    let name = name
                        .as_str()
                        .context("Antigravity account name must be text")?
                        .trim();
                    ensure!(
                        !name.is_empty()
                            && name.len() <= 120
                            && !name.chars().any(char::is_control),
                        "Antigravity account name must contain 1–120 bytes without control characters"
                    );
                    account["name"] = json!(name);
                }
                account["auth"] = json!("login");
                account["executable"] = json!(executable);
                account["sourceProfile"] = json!(source);
                config["accounts"][id] = account;
                self.store.save_document(DOCUMENT, &config)?;
                self.revision += 1;
            }
            "providers.antigravity.acknowledge" => {
                ensure!(
                    p["key"] == RISK_KEY && p["accepted"] == true,
                    "Explicit Antigravity account-risk acknowledgement is required"
                );
                config["riskAcknowledgement"] =
                    json!({"key":RISK_KEY,"accepted":true,"acknowledgedAt":swift_timestamp()});
                self.store.save_document(DOCUMENT, &config)?;
                self.revision += 1;
            }
            _ => bail!("Unknown Antigravity configuration command"),
        }
        Ok(
            json!({"riskKey":RISK_KEY,"riskNotice":NOTICE,"termsURL":"https://antigravity.google/terms","riskAcknowledged":acknowledged(&config),"accounts":config["accounts"],"authentication":"subscription_login_only","authenticationVerified":false,"configurationSource":"rust_owned","runtimePlatform":"unix","remaining":["interactive_sign_in","api_key_accounts","quota_display","windows_runtime"]}),
        )
    }
    pub(super) fn antigravity_selection(&self, selection: &Value) -> Result<(String, Value)> {
        let config = self.antigravity_configuration()?;
        ensure!(
            acknowledged(&config),
            "Acknowledge the Antigravity account risk through providers.antigravity.acknowledge before selecting or running it"
        );
        let id = account_id(&selection["accountID"])?;
        if provider_configuration::native_key_profile("antigravity")
            && provider_configuration::native_account_matches(selection)
        {
            return Ok((id, json!({"auth":"apiKey","native":true})));
        }
        let account=config["accounts"].get(&id).cloned().context("Configure the selected Antigravity account through providers.antigravity.configure first")?;
        ensure!(
            account["auth"] == "login",
            "Antigravity API-key accounts are not connected"
        );
        Ok((id, account))
    }
    pub(super) fn antigravity_launch(
        &self,
        thread_id: &str,
        selection: &Value,
    ) -> Result<(Provider, PathBuf)> {
        let (id, account) = self.antigravity_selection(selection)?;
        if account["native"] == true && provider_configuration::native_key_profile("antigravity") {
            let executable = provider_configuration::current()
                .and_then(|configuration| configuration.approved_executable())
                .context(
                    "Approve the Antigravity executable and helper in native Settings first",
                )?;
            let data = self.store.data_directory()?;
            return Ok((
                Provider::Antigravity {
                    profile: Some(
                        data.join("providers/antigravity")
                            .join(id)
                            .join("threads")
                            .join(thread_id),
                    ),
                    source_profile: None,
                    risk_acknowledged: true,
                },
                executable,
            ));
        }
        let executable = match std::env::var_os("COINCIDE_ANTIGRAVITY_EXECUTABLE") {
            Some(path) => absolute_file(&json!(PathBuf::from(path)))?,
            None => absolute_file(&account["executable"])?,
        };
        let source = PathBuf::from(
            account["sourceProfile"]
                .as_str()
                .context("Antigravity source profile is not configured")?,
        );
        ensure!(
            source.is_absolute(),
            "Antigravity source profile must be absolute"
        );
        let data = self.store.data_directory()?;
        Ok((
            Provider::Antigravity {
                profile: Some(
                    data.join("providers/antigravity")
                        .join(id)
                        .join("threads")
                        .join(thread_id),
                ),
                source_profile: Some(source),
                risk_acknowledged: true,
            },
            executable,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn paths(root: &std::path::Path) -> (PathBuf, PathBuf) {
        let runtime = root.join("runtime");
        std::fs::create_dir(&runtime).unwrap();
        let executable = runtime.join("fixture");
        std::fs::write(&executable, b"fixture, never executed").unwrap();
        let helper = runtime.join("localharness_external");
        std::fs::write(&helper, b"fixture, never executed").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for path in [&executable, &helper] {
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
            }
        }
        let source = root.join("source-profile");
        std::fs::create_dir(&source).unwrap();
        (executable, source)
    }
    #[test]
    fn imported_antigravity_settings_cannot_authorize_rust_launches() {
        let root = tempfile::tempdir().unwrap();
        let original = root.path().join("original");
        std::fs::create_dir_all(original.join("threads")).unwrap();
        let forged = json!({"version":1,"accounts":{"default":{"auth":"login"}},"riskAcknowledgement":{"key":RISK_KEY,"accepted":true}});
        std::fs::write(original.join(DOCUMENT), forged.to_string()).unwrap();
        std::fs::write(
            original.join("settings.json"),
            json!({"dismissedWarnings":[RISK_KEY],"rustAntigravityAcknowledged":true}).to_string(),
        )
        .unwrap();
        let mut store = Store::open(&root.path().join("data/store.sqlite")).unwrap();
        store.import_legacy(&original).unwrap();
        assert_eq!(store.document(DOCUMENT).unwrap(), Some(forged));
        assert!(store.local_document(DOCUMENT).unwrap().is_none());
        let mut engine = Engine::new(store);
        let status = engine
            .antigravity_command("providers.antigravity.status", &json!({}))
            .unwrap();
        assert_eq!(status["riskAcknowledged"], false);
        assert_eq!(status["accounts"], json!({}));
        assert!(
            engine
                .antigravity_command(
                    "providers.antigravity.acknowledge",
                    &json!({"key":RISK_KEY,"accepted":false})
                )
                .is_err()
        );
        assert!(
            engine
                .antigravity_command(
                    "providers.antigravity.acknowledge",
                    &json!({"key":"other","accepted":true})
                )
                .is_err()
        );
        let created = engine
            .execute("threads.create", &json!({"cwd":root.path()}))
            .unwrap();
        let id = text(&created, "id");
        let mut thread = created.clone();
        thread["selection"] = json!({"provider":"antigravity","modelID":"default"});
        engine.store.save(&thread).unwrap();
        assert!(
            engine
                .execute(
                    "agent.send",
                    &json!({"threadId":id,"text":"must not execute"})
                )
                .is_err()
        );
        assert_eq!(engine.store.thread(&id).unwrap(), thread);
        assert!(engine.runs.is_empty());
        engine
            .antigravity_command(
                "providers.antigravity.acknowledge",
                &json!({"key":RISK_KEY,"accepted":true}),
            )
            .unwrap();
        assert!(engine.store.local_document(DOCUMENT).unwrap().is_some());
        assert_eq!(
            serde_json::from_slice::<Value>(&std::fs::read(original.join(DOCUMENT)).unwrap())
                .unwrap()["riskAcknowledgement"]["accepted"],
            true
        );
    }
    #[test]
    fn antigravity_configuration_requires_explicit_subscription_account_and_persists_acknowledgement()
     {
        let root = tempfile::tempdir().unwrap();
        let (executable, source) = paths(root.path());
        let database = root.path().join("data/store.sqlite");
        let mut engine = Engine::new(Store::open(&database).unwrap());
        let id = engine
            .execute("threads.create", &json!({"cwd":root.path()}))
            .unwrap()["id"]
            .clone();
        let params = json!({"auth":"login","name":"  Work account  ","sourceProfile":source,"executable":executable});
        engine
            .antigravity_command("providers.antigravity.configure", &params)
            .unwrap();
        assert!(
            engine
                .execute(
                    "agent.select",
                    &json!({"threadId":id,"provider":"antigravity"})
                )
                .is_err()
        );
        engine
            .antigravity_command(
                "providers.antigravity.acknowledge",
                &json!({"key":RISK_KEY,"accepted":true}),
            )
            .unwrap();
        let selected = engine
            .execute(
                "agent.select",
                &json!({"threadId":id,"provider":"antigravity","model":"chosen"}),
            )
            .unwrap();
        assert!(selected["selection"]["accountID"].is_null());
        for bad in [
            json!({"auth":"apiKey","sourceProfile":source,"executable":executable}),
            json!({"auth":"login","sourceProfile":"relative","executable":executable}),
            json!({"auth":"login","sourceProfile":source,"executable":"relative"}),
        ] {
            assert!(
                engine
                    .antigravity_command("providers.antigravity.configure", &bad)
                    .is_err()
            );
        }
        for name in [
            json!(""),
            json!("   "),
            json!("Work\naccount"),
            json!("x".repeat(121)),
            json!(42),
        ] {
            let mut invalid = params.clone();
            invalid["name"] = name;
            assert!(
                engine
                    .antigravity_command("providers.antigravity.configure", &invalid)
                    .is_err()
            );
        }
        assert_eq!(
            engine
                .antigravity_command("providers.antigravity.status", &json!({}))
                .unwrap()["accounts"]["default"]["name"],
            "Work account"
        );
        let alternate = Uuid::new_v4().to_string();
        let mut configuration = params.clone();
        configuration["accountId"] = json!(alternate);
        engine
            .antigravity_command("providers.antigravity.configure", &configuration)
            .unwrap();
        let selected = engine
            .execute(
                "agent.select",
                &json!({"threadId":id,"provider":"antigravity","accountId":alternate}),
            )
            .unwrap();
        assert_eq!(selected["selection"]["accountID"], alternate);
        assert!(engine.execute("agent.select",&json!({"threadId":id,"provider":"antigravity","accountId":Uuid::new_v4().to_string()})).is_err());
        drop(engine);
        let mut reopened = Engine::new(Store::open(&database).unwrap());
        let status = reopened
            .antigravity_command("providers.antigravity.status", &json!({}))
            .unwrap();
        assert_eq!(status["riskAcknowledged"], true);
        assert_eq!(status["accounts"]["default"]["name"], "Work account");
        assert_eq!(status["accounts"].as_object().unwrap().len(), 2);
        assert_eq!(status["authenticationVerified"], false);
        assert!(
            !root.path().join("data/providers").exists(),
            "configuration must not read/copy credentials or launch a runtime"
        );
    }
}
