//! Session-only sidebar activity, as the macOS ThreadActivity reports it: how
//! each turn ended and how many approvals a running thread waits on. Nothing
//! here is persisted, and a relaunch never replays an earlier session's turns.
use super::*;

/// Results kept for readers that poll `app.status`; older ones are dropped.
const RECENT_LIMIT: usize = 64;

#[derive(Default)]
pub(super) struct TurnResults {
    serial: u64,
    recent: VecDeque<(u64, String, &'static str)>,
}
impl TurnResults {
    /// `outcome` is "completed", "failed" or "interrupted".
    pub(super) fn record(&mut self, thread: &str, outcome: &'static str) {
        self.serial += 1;
        self.recent
            .push_back((self.serial, thread.to_owned(), outcome));
        while self.recent.len() > RECENT_LIMIT {
            self.recent.pop_front();
        }
    }
    /// Readers remember `serial` and act only on newer entries.
    pub(super) fn status(&self) -> Value {
        json!({"serial":self.serial,"recent":self.recent.iter().map(|(serial,thread,outcome)|json!({"serial":serial,"threadId":thread,"outcome":outcome})).collect::<Vec<_>>()})
    }
}

/// Approvals only: questions waiting for an answer don't count, as in Swift.
fn approvals(pending: &HashMap<String, Value>) -> usize {
    pending
        .values()
        .filter(|frame| frame["method"] != "item/tool/requestUserInput")
        .count()
}

impl Engine {
    pub(super) fn record_turn_result(&mut self, id: &str, failure: bool) {
        let Some(run) = self.runs.get(id) else {
            return;
        };
        let outcome = if run.cancelled {
            "interrupted"
        } else if failure || run.persistence_error.is_some() {
            "failed"
        } else {
            "completed"
        };
        self.turn_results.record(id, outcome);
    }
    pub(super) fn pending_approvals(&self) -> Value {
        Value::Object(
            self.runs
                .iter()
                .map(|(id, run)| (id.clone(), approvals(&run.pending)))
                .filter(|(_, count)| *count > 0)
                .map(|(id, count)| (id, json!(count)))
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn results_are_bounded_and_ordered_and_questions_are_not_approvals() {
        let mut results = TurnResults::default();
        for index in 0..70 {
            results.record(&format!("thread-{index}"), "completed");
        }
        results.record("last", "failed");
        let status = results.status();
        assert_eq!(status["serial"], 71);
        let recent = status["recent"].as_array().unwrap();
        assert_eq!(recent.len(), RECENT_LIMIT);
        assert_eq!(recent[0]["serial"], 8);
        assert_eq!(recent.last().unwrap()["threadId"], "last");
        assert_eq!(recent.last().unwrap()["outcome"], "failed");
        let pending = HashMap::from([
            (
                "1".into(),
                json!({"method":"item/commandExecution/requestApproval"}),
            ),
            (
                "2".into(),
                json!({"method":"item/fileChange/requestApproval"}),
            ),
            ("3".into(), json!({"method":"item/tool/requestUserInput"})),
        ]);
        assert_eq!(approvals(&pending), 2);
        assert_eq!(approvals(&HashMap::new()), 0);
    }

    fn run(engine: &mut Engine, id: &str) -> std::sync::mpsc::Sender<Event> {
        // Replace only the event receiver; no provider executable exists.
        let mut session = Session::start(Launch {
            executable: PathBuf::from("/nonexistent-coincide-thread-activity-fixture"),
            cwd: std::env::temp_dir(),
            session: None,
            prompt: String::new(),
            model: None,
            variant: None,
        });
        let (sender, receiver) = std::sync::mpsc::channel();
        session.events = receiver;
        let transcript_start = engine.store.thread(id).unwrap()["items"]
            .as_array()
            .unwrap()
            .len();
        engine.runs.insert(
            id.into(),
            Running {
                configuration: None,
                resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
                usage_context: None,
                session,
                provider: "codex".into(),
                transcript_start,
                pending: HashMap::new(),
                schedule_claim: None,
                queue_claim: None,
                cancelled: false,
                events: VecDeque::new(),
                persistence_error: None,
            },
        );
        sender
    }

    #[test]
    fn status_reports_waiting_approvals_and_each_finished_turn_once() {
        let directory = tempfile::tempdir().unwrap();
        let mut engine =
            Engine::fixture(Store::open(&directory.path().join("data.sqlite")).unwrap());
        let mut thread = || {
            text(
                &engine
                    .store
                    .new_thread("00000000-0000-0000-0000-000000000000")
                    .unwrap(),
                "id",
            )
        };
        let (done, failed, stopped) = (thread(), thread(), thread());
        let senders = [&done, &failed, &stopped].map(|id| run(&mut engine, id));
        senders[0]
            .send(Event::Frame(
                json!({"id":1,"method":"item/commandExecution/requestApproval","params":{}}),
            ))
            .unwrap();
        senders[0]
            .send(Event::Frame(
                json!({"id":2,"method":"item/tool/requestUserInput","params":{"questions":[]}}),
            ))
            .unwrap();
        engine.poll();
        let status = engine.execute("app.status", &json!({})).unwrap();
        assert_eq!(status["pendingApprovals"], json!({done.clone(): 1}));
        assert_eq!(status["turnResults"], json!({"serial":0,"recent":[]}));
        engine.runs.get_mut(&stopped).unwrap().cancelled = true;
        senders[0].send(Event::Finished).unwrap();
        senders[1]
            .send(Event::Failed("Synthetic failure".into()))
            .unwrap();
        senders[2].send(Event::Finished).unwrap();
        engine.poll();
        let status = engine.execute("app.status", &json!({})).unwrap();
        assert_eq!(status["pendingApprovals"], json!({}));
        assert_eq!(status["turnResults"]["serial"], 3);
        let mut outcomes = status["turnResults"]["recent"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| (text(entry, "threadId"), text(entry, "outcome")))
            .collect::<Vec<_>>();
        outcomes.sort();
        let mut expected = vec![
            (done, "completed".to_owned()),
            (failed, "failed".to_owned()),
            (stopped, "interrupted".to_owned()),
        ];
        expected.sort();
        assert_eq!(outcomes, expected);
        engine.poll();
        assert_eq!(
            engine.execute("app.status", &json!({})).unwrap()["turnResults"]["serial"],
            3
        );
    }
}
