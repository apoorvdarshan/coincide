//! Read-only `composer.commands`: what the thread's agent reported for `/` and `$`
//! completions. Optional native discovery is read-only and never starts a turn.
use super::*;
pub struct NativeCommandDiscovery {
    thread: String,
    provider: String,
    selection: Value,
    cwd: PathBuf,
    executable: PathBuf,
    profile: Option<crate::codex_login_profiles::LaunchContext>,
    configuration: Option<provider_configuration::LaunchConfiguration>,
}
pub struct NativeCommandReceipt {
    request: NativeCommandDiscovery,
    commands: Vec<crate::composer_suggestions::ProviderCommand>,
}
impl NativeCommandDiscovery {
    pub fn read(self, allowed: impl Fn() -> bool) -> Result<NativeCommandReceipt> {
        let scope = provider_configuration::enter(self.configuration.clone());
        let commands = match self.provider.as_str() {
            "codex" => crate::agent::codex_metadata::skills(
                &self.executable,
                &self.cwd,
                self.profile.as_ref(),
                &allowed,
            )?,
            "opencode" => {
                crate::agent::opencode_command_metadata(&self.executable, &self.cwd, &allowed)?
            }
            "claude" => {
                crate::agent::claude_command_metadata(&self.executable, &self.cwd, &allowed)?
            }
            _ => anyhow::bail!("Provider command discovery is unavailable"),
        };
        drop(scope);
        Ok(NativeCommandReceipt {
            request: self,
            commands,
        })
    }
}
impl Engine {
    /// Capture the selected provider's executable, account and folder under the
    /// Engine lock; the child process itself runs after that lock is released.
    pub fn prepare_native_command_discovery(
        &self,
        id: &str,
    ) -> Result<Option<NativeCommandDiscovery>> {
        ensure!(
            self.active_thread() == Some(id),
            "Conversation is no longer active"
        );
        let thread = self.store.thread(id)?;
        let provider = text(&thread["selection"], "provider");
        if !matches!(provider.as_str(), "codex" | "opencode" | "claude") {
            return Ok(None);
        }
        self.require_provider_enabled(&provider)?;
        let cwd = self.working_directory(&thread)?.canonicalize()?;
        let configuration = self.provider_metadata_configuration_for_thread(&thread)?;
        let scope = provider_configuration::enter(configuration.clone());
        let profile = if provider == "codex" {
            self.codex_login_context(&thread)?
        } else {
            None
        };
        let executable = if let Some(profile) = &profile {
            profile.executable().to_path_buf()
        } else if matches!(provider.as_str(), "opencode" | "claude") {
            let env_name = if provider == "opencode" {
                "COINCIDE_OPENCODE_EXECUTABLE"
            } else {
                "COINCIDE_CLAUDE_EXECUTABLE"
            };
            let fallback = std::env::var_os(env_name)
                .map(PathBuf::from)
                .or_else(|| {
                    self.provider_discovery.as_ref()?["providers"]
                        .as_array()?
                        .iter()
                        .find(|row| row["provider"] == provider)?["executable"]
                        .as_str()
                        .map(PathBuf::from)
                })
                .unwrap_or_else(|| PathBuf::from(&provider));
            provider_configuration::current_executable(fallback)
        } else {
            self.composer_codex_executable()?
        };
        drop(scope);
        Ok(Some(NativeCommandDiscovery {
            thread: id.into(),
            provider,
            selection: thread["selection"].clone(),
            cwd,
            executable,
            profile,
            configuration,
        }))
    }
    /// Never attach a late result to a different account, project or provider.
    pub fn accept_native_command_discovery(&mut self, receipt: NativeCommandReceipt) -> Result<()> {
        let request = receipt.request;
        let thread = self.store.thread(&request.thread)?;
        ensure!(
            thread["selection"] == request.selection
                && self.working_directory(&thread)?.canonicalize()? == request.cwd,
            "Conversation changed while reading provider commands"
        );
        let current = self.provider_metadata_configuration_for_thread(&thread)?;
        ensure!(
            current.as_ref().map(|value| value.stamp())
                == request.configuration.as_ref().map(|value| value.stamp()),
            "Provider settings changed while reading commands"
        );
        let account = &thread["selection"]["accountID"];
        let (previous, _) = self.composer_commands.lookup(
            &request.thread,
            &request.provider,
            account,
            Some(&request.cwd),
        );
        let mut commands = previous
            .iter()
            .filter(|item| {
                request.provider == "codex"
                    && item.kind != crate::composer_suggestions::CommandKind::Skill
            })
            .cloned()
            .collect::<Vec<_>>();
        commands.extend(receipt.commands);
        self.composer_commands.record(
            &request.thread,
            &request.provider,
            account,
            Some(&request.cwd),
            commands,
        );
        self.revision += 1;
        Ok(())
    }
    pub(super) fn reported_composer_commands(&self, p: &Value) -> Result<Value> {
        let object = p.as_object().context("Command lookup must be an object")?;
        ensure!(
            object.keys().all(|key| key == "threadId"),
            "Unknown command lookup field"
        );
        let id = required(p, "threadId")?;
        Uuid::parse_str(id).context("Invalid thread ID")?;
        let thread = self.store.thread(id)?;
        let provider = text(&thread["selection"], "provider");
        let folder = self
            .working_directory(&thread)
            .ok()
            .and_then(|path| path.canonicalize().ok());
        let (commands, source) = self.composer_commands.lookup(
            id,
            &provider,
            &thread["selection"]["accountID"],
            folder.as_deref(),
        );
        Ok(json!({"threadId":id,"provider":provider,"commands":commands,"source":source}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[cfg(unix)]
    #[test]
    fn codex_skills_are_discovered_without_a_turn_and_rejected_after_scope_changes() {
        use std::os::unix::fs::PermissionsExt;
        let (root, mut engine, binary) = provider_configuration::tests::fixture();
        std::fs::write(&binary, r##"#!/usr/bin/env python3
import json,sys
def read():return json.loads(sys.stdin.readline())
def write(v):print(json.dumps(v),flush=True)
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']=='skills/list'
cwd=r['params']['cwds'][0]
write({'id':r['id'],'result':{'data':[{'cwd':cwd,'skills':[{'name':'plugin:review','description':'Review','enabled':True},{'name':'hidden','description':'Hidden','enabled':False}]}]}})
"##).unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        provider_configuration::tests::save(&mut engine, "codex", &binary, "synthetic");
        let thread = engine
            .execute("threads.create", &json!({"cwd":root.path()}))
            .unwrap();
        let id = text(&thread, "id");
        engine.set_active_thread(Some(id.clone())).unwrap();
        let request = engine
            .prepare_native_command_discovery(&id)
            .unwrap()
            .unwrap();
        let receipt = request.read(|| true).unwrap();
        engine.accept_native_command_discovery(receipt).unwrap();
        let commands = engine
            .execute("composer.commands", &json!({"threadId":id}))
            .unwrap();
        assert_eq!(commands["commands"].as_array().unwrap().len(), 1);
        assert_eq!(commands["commands"][0]["name"], "plugin:review");
        assert_eq!(commands["commands"][0]["isSlashCommand"], false);

        let request = engine
            .prepare_native_command_discovery(&id)
            .unwrap()
            .unwrap();
        let receipt = request.read(|| true).unwrap();
        let mut changed = engine.store.thread(&id).unwrap();
        changed["selection"]["provider"] = json!("claude");
        engine.store.save(&changed).unwrap();
        assert!(engine.accept_native_command_discovery(receipt).is_err());
        let commands = engine
            .execute("composer.commands", &json!({"threadId":id}))
            .unwrap();
        assert!(commands["commands"].as_array().unwrap().is_empty());
    }

    #[test]
    fn lookup_is_read_only_scoped_to_the_thread_agent_and_rejects_extra_fields() {
        let directory = tempfile::tempdir().unwrap();
        let mut engine =
            Engine::fixture(Store::open(&directory.path().join("state.sqlite")).unwrap());
        let thread = engine
            .execute("threads.create", &json!({"title":"Commands"}))
            .unwrap();
        let id = thread["id"].as_str().unwrap().to_owned();
        let provider = thread["selection"]["provider"].as_str().unwrap().to_owned();
        let lookup = |engine: &mut Engine| {
            engine
                .execute("composer.commands", &json!({"threadId":id}))
                .unwrap()
        };
        let empty = lookup(&mut engine);
        assert_eq!(empty["commands"], json!([]));
        assert_eq!(empty["source"], "none");
        assert_eq!(empty["provider"], json!(provider));
        engine.composer_commands.record(
            &id,
            &provider,
            &Value::Null,
            None,
            crate::composer_suggestions::ProviderCommand::from_acp(&[json!({"name":"web"})]),
        );
        let reported = lookup(&mut engine);
        assert_eq!(reported["source"], "session");
        assert_eq!(
            reported["commands"],
            json!([{"name":"web","kind":"command","isBuiltIn":false,"isSlashCommand":true}])
        );
        assert!(
            engine
                .execute("composer.commands", &json!({"threadId":id,"provider":"x"}))
                .is_err()
        );
        assert!(
            engine
                .execute("composer.commands", &json!({"threadId":"not-a-thread"}))
                .is_err()
        );
        let capabilities = engine.execute("app.capabilities", &json!({})).unwrap();
        assert!(
            capabilities
                .as_array()
                .unwrap()
                .contains(&json!("composer.commands"))
        );
    }

    #[test]
    fn a_running_session_report_is_recorded_for_its_own_thread_and_agent() {
        let directory = tempfile::tempdir().unwrap();
        let mut engine =
            Engine::fixture(Store::open(&directory.path().join("state.sqlite")).unwrap());
        let id = engine.execute("threads.create", &json!({})).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        // Replace only the public event receiver; no actual provider executable exists.
        let mut session = Session::start(Launch {
            executable: PathBuf::from("/nonexistent-coincide-commands-fixture"),
            cwd: std::env::temp_dir(),
            session: None,
            prompt: String::new(),
            model: None,
            variant: None,
            full_access: false,
        });
        let (sender, receiver) = mpsc::channel();
        session.events = receiver;
        engine.runs.insert(
            id.clone(),
            Running {
                configuration: None,
                resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
                usage_context: None,
                session,
                provider: "claude".into(),
                transcript_start: 0,
                pending: HashMap::new(),
                schedule_claim: None,
                queue_claim: None,
                cancelled: false,
                events: VecDeque::new(),
                persistence_error: None,
            },
        );
        let items = engine.store.thread(&id).unwrap()["items"].clone();
        sender
            .send(Event::Frame(json!({"method":"provider/event","params":{"provider":"claude","providerFrame":{"type":"control_response","response":{"request_id":"coincide-initialize","subtype":"success","response":{"commands":[{"name":"review","description":"Review a PR"}]}}}}})))
            .unwrap();
        engine.poll();
        // The report adds nothing to the transcript.
        assert_eq!(engine.store.thread(&id).unwrap()["items"], items);
        let (commands, source) = engine
            .composer_commands
            .lookup(&id, "claude", &Value::Null, None);
        assert_eq!((commands.len(), source), (1, "session"));
        assert_eq!(commands[0].name, "review");
        assert_eq!(
            engine
                .composer_commands
                .lookup(&id, "codex", &Value::Null, None)
                .1,
            "none"
        );
    }
}
