//! Narrow Engine-owned profile registry/selection. No login or credential import.
use super::*;
use crate::codex_login_profiles as profiles;
impl Engine {
    pub(super) fn codex_login_profile_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        let fields = p
            .as_object()
            .context("Codex profile request must be an object")?;
        match method {
            "providers.codex.profiles.status" => {
                ensure!(
                    fields.is_empty(),
                    "Codex profile status takes no parameters"
                );
                let configuration = profiles::configuration(&self.store)?;
                let accounts = configuration["accounts"].as_object().unwrap().iter().map(|(id, _)| {
                    let account = profiles::account(&configuration, id)?;
                    Ok(json!({"id":id,"name":account["name"],"auth":"login","authenticationChecked":false,"accountIdentityVerified":false}))
                }).collect::<Result<Vec<_>>>()?;
                Ok(
                    json!({"accounts":accounts,"namedResumeSupported":true,"namedResumeScope":"successful_saved_turn_owned_worker_join_and_private_journal","crossRestartResumeSupported":cfg!(any(unix,windows)),"nativeResume":self.named_resume.durable_status(),"enrollmentConnected":true,"uiMounted":self.ui_available}),
                )
            }
            "providers.codex.profiles.create" => {
                ensure!(
                    fields.keys().all(|key| key == "name"),
                    "Unsupported Codex profile field"
                );
                let name = required(p, "name")?.trim();
                ensure!(
                    !name.is_empty() && name.len() <= 120 && !name.chars().any(char::is_control),
                    "Invalid Codex profile name"
                );
                let mut configuration = profiles::configuration(&self.store)?;
                ensure!(
                    configuration["accounts"].as_object().unwrap().len() < 32,
                    "Too many Codex profiles"
                );
                let id = Uuid::new_v4().to_string();
                profiles::managed_home(&self.store.data_directory()?, &id, true)?;
                configuration["accounts"][&id] = json!({"name":name,"auth":"login"});
                self.store
                    .save_document(profiles::DOCUMENT, &configuration)?;
                self.revision += 1;
                Ok(
                    json!({"id":id,"name":name,"auth":"login","authenticationChecked":false,"accountIdentityVerified":false,"enrollmentConnected":true}),
                )
            }
            "providers.codex.profiles.select" => {
                ensure!(
                    fields.keys().all(|key| matches!(
                        key.as_str(),
                        "threadId" | "accountId" | "expectedSelection"
                    )),
                    "Unsupported Codex profile selection field"
                );
                let id = required(p, "threadId")?;
                let uuid = Uuid::parse_str(id)?;
                ensure!(
                    self.active_thread().and_then(|id| Uuid::parse_str(id).ok()) == Some(uuid),
                    "Codex profile target is no longer selected"
                );
                ensure!(
                    !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id),
                    "Stop the current turn and wait for persistence before changing profile"
                );
                ensure!(
                    !self.store.is_imported(id)?,
                    "Fork an imported thread before selecting a profile"
                );
                let mut thread = self.store.thread(id)?;
                ensure!(
                    p.get("expectedSelection") == thread.get("selection"),
                    "Selection changed; reload before choosing a Codex profile"
                );
                profiles::validate_thread(&thread)?;
                crate::composer_selection::validate_thread_with_proof(
                    &profiles::validation_view(&thread),
                    None,
                )?;
                let account = p
                    .get("accountId")
                    .context("Missing Codex profile accountId")?;
                ensure!(
                    account.is_null() || account.is_string(),
                    "Codex profile accountId must be text or null"
                );
                if crate::composer_selection::default_account(account) {
                    thread["selection"]
                        .as_object_mut()
                        .unwrap()
                        .remove("accountID");
                } else {
                    let account = account.as_str().unwrap();
                    profiles::account(&profiles::configuration(&self.store)?, account)?;
                    profiles::LaunchContext::capture(
                        &self.store.data_directory()?,
                        account,
                        &self.composer_codex_executable()?,
                    )?;
                    thread["selection"]["accountID"] = json!(account);
                }
                self.store.save(&thread)?;
                self.revision += 1;
                Ok(thread)
            }
            _ => bail!("Unknown Codex profile operation"),
        }
    }
    pub(super) fn codex_login_context(
        &self,
        thread: &Value,
    ) -> Result<Option<profiles::LaunchContext>> {
        if thread["selection"]["provider"] != "codex"
            || crate::composer_selection::default_account(&thread["selection"]["accountID"])
        {
            return Ok(None);
        }
        let id = required(thread, "id")?;
        ensure!(
            !self.store.is_imported(id)?,
            "Imported Codex profile execution is unavailable"
        );
        profiles::validate_model_thread(thread)?;
        let account = required(&thread["selection"], "accountID")?;
        profiles::account(&profiles::configuration(&self.store)?, account)?;
        ensure!(
            self.codex_profile_login
                .as_ref()
                .is_none_or(|operation| !operation.active() || operation.account() != account),
            "Finish or cancel this profile's sign-in before sending"
        );
        Ok(Some(profiles::LaunchContext::capture(
            &self.store.data_directory()?,
            account,
            &self.composer_codex_executable()?,
        )?))
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    fn fixture() -> (tempfile::TempDir, Engine, String) {
        let dir = tempfile::tempdir().unwrap();
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let thread = engine.execute("threads.create", &json!({})).unwrap();
        let id = text(&thread, "id");
        engine
            .execute(
                "agent.select",
                &json!({"threadId":id,"provider":"codex","model":"default"}),
            )
            .unwrap();
        engine.set_active_thread(Some(id.clone())).unwrap();
        engine.provider_discovery = Some(
            json!({"providers":[{"provider":"codex","executable":std::env::current_exe().unwrap()}]}),
        );
        (dir, engine, id)
    }
    #[test]
    fn profile_selection_is_optimistic_thread_scoped_and_never_default_fallback() {
        let (_dir, mut engine, id) = fixture();
        let account = engine
            .execute(
                "providers.codex.profiles.create",
                &json!({"name":"Synthetic profile"}),
            )
            .unwrap();
        let baseline = engine.store.thread(&id).unwrap();
        let select = json!({"threadId":id,"accountId":account["id"],"expectedSelection":baseline["selection"]});
        assert!(engine.execute("providers.codex.profiles.select", &json!({"threadId":id,"accountId":Uuid::new_v4(),"expectedSelection":baseline["selection"]})).is_err());
        let selected = engine
            .execute("providers.codex.profiles.select", &select)
            .unwrap();
        assert_eq!(selected["selection"]["accountID"], account["id"]);
        assert!(
            engine
                .execute("providers.codex.profiles.select", &select)
                .is_err()
        );
        engine.set_active_thread(None).unwrap();
        assert!(engine.execute("providers.codex.profiles.select", &json!({"threadId":id,"accountId":"default","expectedSelection":selected["selection"]})).is_err());
        engine.set_active_thread(Some(id.clone())).unwrap();
        let restored = engine.execute("providers.codex.profiles.select", &json!({"threadId":id,"accountId":"default","expectedSelection":selected["selection"]})).unwrap();
        assert!(restored["selection"]["accountID"].is_null());
        engine.freeze_admissions();
        assert!(
            engine
                .execute(
                    "providers.codex.profiles.create",
                    &json!({"name":"Refused"})
                )
                .is_err()
        );
    }
    #[test]
    fn deleted_profiles_and_unsupported_options_cannot_spawn_or_consume_the_draft() {
        let (_dir, mut engine, id) = fixture();
        let profile = engine
            .execute(
                "providers.codex.profiles.create",
                &json!({"name":"Synthetic"}),
            )
            .unwrap();
        let baseline = engine.store.thread(&id).unwrap();
        let mut thread = engine.execute("providers.codex.profiles.select", &json!({"threadId":id,"accountId":profile["id"],"expectedSelection":baseline["selection"]})).unwrap();
        thread["draft"] = json!("retain synthetic draft");
        thread["future"] = json!({"keep":true});
        for (key, value) in [
            ("modelID", json!("explicit-model")),
            ("effort", json!("high")),
            ("speed", json!("priority")),
        ] {
            let mut unsupported = thread.clone();
            unsupported["selection"][key] = value;
            engine.store.save(&unsupported).unwrap();
            assert!(
                engine
                    .execute("agent.send", &json!({"threadId":id,"text":"refused"}))
                    .is_err()
            );
            assert_eq!(engine.store.thread(&id).unwrap(), unsupported);
            assert!(engine.runs.is_empty());
        }
        for (key, value) in [
            ("accessMode", json!("fullAccess")),
            ("interactionMode", json!("plan")),
            ("rustBotContext", json!({})),
        ] {
            let mut unsupported = thread.clone();
            unsupported[key] = value;
            engine.store.save(&unsupported).unwrap();
            assert!(
                engine
                    .execute("agent.send", &json!({"threadId":id,"text":"refused"}))
                    .is_err()
            );
            assert_eq!(engine.store.thread(&id).unwrap(), unsupported);
            assert!(engine.runs.is_empty());
        }
        engine.store.save(&thread).unwrap();
        assert!(
            engine
                .send_turn(&json!({"threadId":id,"text":"refused scheduled"}), true)
                .is_err()
        );
        engine
            .store
            .save_document(profiles::DOCUMENT, &json!({"version":1,"accounts":{}}))
            .unwrap();
        assert!(
            engine
                .execute(
                    "agent.send",
                    &json!({"threadId":id,"text":"refused removed profile"})
                )
                .is_err()
        );
        assert_eq!(engine.store.thread(&id).unwrap(), thread);
        assert!(engine.runs.is_empty());
    }
    #[test]
    fn profile_configuration_preserves_unknown_json_and_refuses_malformed_state() {
        let (_dir, mut engine, _id) = fixture();
        engine
            .store
            .save_document(
                profiles::DOCUMENT,
                &json!({"version":1,"accounts":{},"future":{"keep":[1,2]}}),
            )
            .unwrap();
        engine
            .execute(
                "providers.codex.profiles.create",
                &json!({"name":"Synthetic"}),
            )
            .unwrap();
        assert_eq!(
            engine
                .store
                .local_document(profiles::DOCUMENT)
                .unwrap()
                .unwrap()["future"],
            json!({"keep":[1,2]})
        );
        engine
            .store
            .save_document(profiles::DOCUMENT, &json!([]))
            .unwrap();
        assert!(
            engine
                .execute(
                    "providers.codex.profiles.create",
                    &json!({"name":"Refused"})
                )
                .is_err()
        );
        assert_eq!(
            engine.store.local_document(profiles::DOCUMENT).unwrap(),
            Some(json!([]))
        );
    }
}
