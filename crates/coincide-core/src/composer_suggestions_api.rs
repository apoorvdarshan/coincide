//! Read-only `composer.commands`: what the thread's agent reported for `/` and `$`
//! completions. It never launches an agent, so nothing shows before one has run.
use super::*;
impl Engine {
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
        let folder = self.working_directory(&thread).ok();
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
