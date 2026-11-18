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
    observation: Option<provider_configuration::Stamp>,
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
            "opencode" | "lithos" => {
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
pub fn native_command_scope(thread: &Value) -> Value {
    json!([
        &thread["selection"]["provider"],
        &thread["selection"]["accountID"],
        &thread["projectID"],
        &thread["projectPath"],
        &thread["worktreePath"],
        &thread["botID"],
        &thread["rustBotContext"],
    ])
}

impl Engine {
    pub(super) fn composer_command_directory(&self, thread: &Value) -> Result<PathBuf> {
        let has_no_project = thread["projectID"].as_str().is_none_or(|id| {
            id.is_empty() || Uuid::parse_str(id).is_ok_and(|project| project.is_nil())
        });
        let directory = if has_no_project
            && ["worktreePath", "botID"]
                .iter()
                .all(|field| thread[*field].as_str().is_none_or(str::is_empty))
        {
            crate::terminal::launch::home()
        } else {
            self.working_directory(thread)?
        };
        directory
            .canonicalize()
            .context("Provider command working directory is unavailable")
    }
    /// Capture the selected provider's executable, account and folder under the
    /// Engine lock; the child process itself runs after that lock is released.
    pub fn prepare_native_command_discovery(
        &self,
        id: &str,
    ) -> Result<Option<NativeCommandDiscovery>> {
        self.prepare_native_command_discovery_for_scope(id, None)
    }

    pub fn prepare_native_command_discovery_for_scope(
        &self,
        id: &str,
        expected: Option<&Value>,
    ) -> Result<Option<NativeCommandDiscovery>> {
        ensure!(
            self.active_thread() == Some(id),
            "Conversation is no longer active"
        );
        let thread = self.store.thread_selection_snapshot(id)?;
        ensure!(
            expected.is_none_or(|expected| native_command_scope(&thread) == *expected),
            "Conversation command scope changed"
        );
        let provider = text(&thread["selection"], "provider");
        if !matches!(
            provider.as_str(),
            "codex" | "opencode" | "lithos" | "claude"
        ) {
            return Ok(None);
        }
        self.require_provider_enabled(&provider)?;
        let cwd = self.composer_command_directory(&thread)?;
        // A metadata snapshot can identify an account but cannot authorize the
        // read-only provider child. Capture an owned launch separately and
        // retain the metadata stamp for the later comparison.
        let observation = self
            .provider_metadata_configuration_for_thread(&thread)?
            .as_ref()
            .map(|configuration| configuration.stamp().clone());
        let configuration = self.provider_launch_configuration_for_thread(&thread)?;
        let scope = provider_configuration::enter(configuration.clone());
        let profile = if provider == "codex" {
            self.codex_login_context(&thread)?
        } else {
            None
        };
        let executable = if let Some(profile) = &profile {
            profile.executable().to_path_buf()
        } else if matches!(provider.as_str(), "opencode" | "lithos" | "claude") {
            let env_name = if matches!(provider.as_str(), "opencode" | "lithos") {
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
                .unwrap_or_else(|| {
                    PathBuf::from(if provider == "lithos" {
                        "opencode"
                    } else {
                        &provider
                    })
                });
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
            observation,
        }))
    }
    /// Never attach a late result to a different account, project or provider.
    pub fn accept_native_command_discovery(
        &mut self,
        receipt: NativeCommandReceipt,
    ) -> Result<Vec<crate::composer_suggestions::ProviderCommand>> {
        let request = receipt.request;
        let thread = self.store.thread_selection_snapshot(&request.thread)?;
        ensure!(
            thread["selection"] == request.selection
                && self.composer_command_directory(&thread)? == request.cwd,
            "Conversation changed while reading provider commands"
        );
        let current = self.provider_metadata_configuration_for_thread(&thread)?;
        if let Some(configuration) = &request.configuration {
            configuration.validate_launch()?;
        }
        ensure!(
            current.as_ref().map(|value| value.stamp()) == request.observation.as_ref(),
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
                    && !receipt.commands.iter().any(|new| {
                        new.kind == item.kind && new.name.eq_ignore_ascii_case(&item.name)
                    })
            })
            .cloned()
            .collect::<Vec<_>>();
        commands.extend(receipt.commands);
        self.composer_commands.record(
            &request.thread,
            &request.provider,
            account,
            Some(&request.cwd),
            commands.clone(),
        );
        self.revision += 1;
        Ok(commands)
    }

    pub fn native_reported_composer_commands(
        &self,
        id: &str,
        expected: &Value,
    ) -> Result<Vec<crate::composer_suggestions::ProviderCommand>> {
        let thread = self.store.thread_selection_snapshot(id)?;
        ensure!(
            native_command_scope(&thread) == *expected,
            "Conversation command scope changed"
        );
        Ok(self.commands_for_thread(id, &thread).0.to_vec())
    }
    fn commands_for_thread(
        &self,
        id: &str,
        thread: &Value,
    ) -> (
        &[crate::composer_suggestions::ProviderCommand],
        &'static str,
    ) {
        let folder = self.composer_command_directory(thread).ok();
        self.composer_commands.lookup(
            id,
            thread["selection"]["provider"].as_str().unwrap_or_default(),
            &thread["selection"]["accountID"],
            folder.as_deref(),
        )
    }
    pub(super) fn reported_composer_commands(&self, p: &Value) -> Result<Value> {
        let object = p.as_object().context("Command lookup must be an object")?;
        ensure!(
            object.keys().all(|key| key == "threadId"),
            "Unknown command lookup field"
        );
        let id = required(p, "threadId")?;
        Uuid::parse_str(id).context("Invalid thread ID")?;
        let thread = self.store.thread_selection_snapshot(id)?;
        let provider = text(&thread["selection"], "provider");
        let (commands, source) = self.commands_for_thread(id, &thread);
        Ok(json!({"threadId":id,"provider":provider,"commands":commands,"source":source}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn a_discovery_worker_must_match_the_account_and_folder_it_was_started_for() {
        let (root, mut engine, binary) = provider_configuration::tests::fixture();
        provider_configuration::tests::save(&mut engine, "codex", &binary, "synthetic");
        let thread = engine
            .execute("threads.create", &json!({"cwd":root.path()}))
            .unwrap();
        let id = text(&thread, "id");
        engine.set_active_thread(Some(id.clone())).unwrap();
        let actual = native_command_scope(&engine.store.thread(&id).unwrap());
        assert!(
            engine
                .prepare_native_command_discovery_for_scope(&id, Some(&actual))
                .unwrap()
                .is_some()
        );
        for index in [1, 4] {
            let mut stale = actual.clone();
            stale[index] = json!("different");
            assert!(
                engine
                    .prepare_native_command_discovery_for_scope(&id, Some(&stale))
                    .is_err()
            );
            assert!(
                engine
                    .native_reported_composer_commands(&id, &stale)
                    .is_err()
            );
        }
    }

    #[test]
    fn projectless_codex_resolves_global_commands_without_a_project() {
        let (_root, mut engine, binary) = provider_configuration::tests::fixture();
        provider_configuration::tests::save(&mut engine, "codex", &binary, "synthetic");
        let thread = engine.execute("threads.create", &json!({})).unwrap();
        let id = text(&thread, "id");
        engine.set_active_thread(Some(id.clone())).unwrap();
        let request = engine
            .prepare_native_command_discovery(&id)
            .unwrap()
            .unwrap();
        assert_eq!(
            request.cwd,
            crate::terminal::launch::home().canonicalize().unwrap()
        );
        let command = crate::composer_suggestions::ProviderCommand {
            name: "global-skill".into(),
            description: None,
            argument_hint: None,
            aliases: Vec::new(),
            kind: crate::composer_suggestions::CommandKind::Skill,
            is_built_in: false,
            is_slash_command: false,
        };
        engine
            .accept_native_command_discovery(NativeCommandReceipt {
                request,
                commands: vec![command],
            })
            .unwrap();
        assert_eq!(
            engine
                .reported_composer_commands(&json!({"threadId":id}))
                .unwrap()["commands"][0]["name"],
            "global-skill"
        );
    }

    #[cfg(unix)]
    #[test]
    fn named_account_commands_use_an_owned_launch_and_keep_their_scope() {
        use std::os::unix::fs::PermissionsExt;
        let (root, mut engine, binary) = provider_configuration::tests::fixture();
        std::fs::write(&binary, r##"#!/usr/bin/env python3
import json,os,sys
assert os.environ.get('CLAUDE_CONFIG_DIR')
request=json.loads(sys.stdin.readline())
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{'commands':[{'name':'account-skill','builtin':False}]}}}),flush=True)
"##).unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        provider_configuration::tests::save(&mut engine, "claude", &binary, "synthetic");
        let account = engine
            .create_native_login_account("claude", "Named")
            .unwrap();
        let auth = account.home.join(".credentials.json");
        std::fs::write(&auth, b"synthetic credential fixture").unwrap();
        std::fs::set_permissions(&auth, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mut thread = engine
            .execute("threads.create", &json!({"cwd":root.path()}))
            .unwrap();
        thread["selection"]["provider"] = json!("claude");
        thread["worktreePath"] = json!(root.path());
        engine.store.save(&thread).unwrap();
        let id = text(&thread, "id");
        engine.set_active_thread(Some(id.clone())).unwrap();
        engine
            .select_native_provider_account(&thread, Some(&account.id))
            .unwrap();
        let request = engine
            .prepare_native_command_discovery(&id)
            .unwrap()
            .unwrap();
        assert!(
            request
                .configuration
                .as_ref()
                .unwrap()
                .validate_launch()
                .is_ok()
        );
        let receipt = request.read(|| true).unwrap();
        engine.accept_native_command_discovery(receipt).unwrap();
        let commands = engine
            .execute("composer.commands", &json!({"threadId":id}))
            .unwrap();
        assert!(
            commands["commands"]
                .as_array()
                .unwrap()
                .iter()
                .any(|command| command["name"] == "account-skill")
        );
        let receipt = engine
            .prepare_native_command_discovery(&id)
            .unwrap()
            .unwrap()
            .read(|| true)
            .unwrap();
        std::fs::write(&auth, b"changed synthetic credential fixture").unwrap();
        assert!(engine.accept_native_command_discovery(receipt).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn codex_skills_are_discovered_without_a_turn_and_rejected_after_scope_changes() {
        use std::os::unix::fs::PermissionsExt;
        let (root, mut engine, binary) = provider_configuration::tests::fixture();
        let skills_file = root.path().join("synthetic-skills.json");
        std::fs::write(
            &skills_file,
            json!([
                {"name":"plugin:review","description":"Review","enabled":true},
                {"name":"hidden","description":"Hidden","enabled":false}
            ])
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            &binary,
            r##"#!/usr/bin/env python3
import json,sys
def read():return json.loads(sys.stdin.readline())
def write(v):print(json.dumps(v),flush=True)
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']=='skills/list' and r['params']['forceReload'] is True
cwd=r['params']['cwds'][0]
skills=json.load(open(cwd+'/synthetic-skills.json'))
write({'id':r['id'],'result':{'data':[{'cwd':cwd,'skills':skills}]}})
"##,
        )
        .unwrap();
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
        assert_eq!(commands["commands"].as_array().unwrap().len(), 2);
        assert_eq!(commands["commands"][0]["name"], "plugin:review");
        assert_eq!(commands["commands"][0]["isSlashCommand"], false);
        assert_eq!(commands["commands"][1]["name"], "compact");
        assert_eq!(commands["commands"][1]["isSlashCommand"], true);

        // Installing or removing a skill in this workspace must change the
        // next provider-reported list without restarting Coincide.
        std::fs::write(
            &skills_file,
            json!([
                {"name":"new-plugin:custom-skill","enabled":true}
            ])
            .to_string(),
        )
        .unwrap();
        let receipt = engine
            .prepare_native_command_discovery(&id)
            .unwrap()
            .unwrap()
            .read(|| true)
            .unwrap();
        engine.accept_native_command_discovery(receipt).unwrap();
        let refreshed = engine
            .execute("composer.commands", &json!({"threadId":id}))
            .unwrap();
        assert_eq!(refreshed["commands"].as_array().unwrap().len(), 2);
        assert!(
            refreshed["commands"]
                .as_array()
                .unwrap()
                .iter()
                .any(|entry| entry["name"] == "new-plugin:custom-skill")
        );
        assert!(
            refreshed["commands"]
                .as_array()
                .unwrap()
                .iter()
                .any(|entry| entry["name"] == "compact")
        );

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
        let folder = engine.composer_command_directory(&thread).unwrap();
        engine.composer_commands.record(
            &id,
            &provider,
            &Value::Null,
            Some(&folder),
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
        let thread = engine.store.thread(&id).unwrap();
        assert_eq!(thread["items"], items);
        let folder = engine.composer_command_directory(&thread).unwrap();
        let (commands, source) =
            engine
                .composer_commands
                .lookup(&id, "claude", &Value::Null, Some(&folder));
        assert_eq!((commands.len(), source), (1, "session"));
        assert_eq!(commands[0].name, "review");
        assert_eq!(
            engine
                .composer_commands
                .lookup(&id, "codex", &Value::Null, Some(&folder))
                .1,
            "none"
        );
    }

    #[test]
    fn early_acp_commands_are_bound_only_after_the_session_is_acknowledged() {
        let directory = tempfile::tempdir().unwrap();
        let mut engine =
            Engine::fixture(Store::open(&directory.path().join("state.sqlite")).unwrap());
        let thread = engine
            .execute("threads.create", &json!({"cwd":directory.path()}))
            .unwrap();
        let id = text(&thread, "id");
        let mut thread = engine.store.thread(&id).unwrap();
        thread["selection"] = json!({"provider":"cursor","modelID":"default"});
        engine.store.save(&thread).unwrap();
        let mut session = Session::fixture_worker(|commands, _| {
            let _ = commands.recv();
        });
        let (sender, receiver) = mpsc::channel();
        session.events = receiver;
        engine.insert_running(
            id.clone(),
            Running {
                configuration: None,
                resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
                usage_context: None,
                session,
                provider: "cursor".into(),
                transcript_start: 0,
                pending: HashMap::new(),
                schedule_claim: None,
                queue_claim: None,
                cancelled: false,
                events: VecDeque::new(),
                persistence_error: None,
            },
        );
        let report = |session: &str, name: &str| {
            Event::Frame(
                json!({"method":"provider/event","params":{"provider":"cursor","providerFrame":{"method":"session/update","params":{"sessionId":session,"update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":name}]}}}}}),
            )
        };
        sender.send(report("another-session", "wrong")).unwrap();
        sender
            .send(report("owned-session", "plugin-command"))
            .unwrap();
        engine.poll();
        let folder = directory.path().canonicalize().unwrap();
        assert!(
            engine
                .composer_commands
                .lookup(&id, "cursor", &Value::Null, Some(&folder))
                .0
                .is_empty()
        );
        sender.send(Event::Session("owned-session".into())).unwrap();
        engine.poll();
        assert_eq!(
            engine
                .composer_commands
                .lookup(&id, "cursor", &Value::Null, Some(&folder))
                .0[0]
                .name,
            "plugin-command"
        );
        sender
            .send(report("another-session", "wrong-again"))
            .unwrap();
        engine.poll();
        assert_eq!(
            engine
                .composer_commands
                .lookup(&id, "cursor", &Value::Null, Some(&folder))
                .0[0]
                .name,
            "plugin-command"
        );
    }
}
