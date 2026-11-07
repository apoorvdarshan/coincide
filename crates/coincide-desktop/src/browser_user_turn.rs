//! An agent's "Your turn" request in one thread's browser, as Swift's
//! `UserTurnGate`: one open request per thread, shown with Done and Not Now. A
//! newer request supersedes it; it otherwise ends with the user's answer, its
//! timeout, or cancellation when the browser shuts down.
use coincide_core::browser_protocol::{USER_TURN_MAXIMUM_TIMEOUT, clean_user_turn_message};
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Done,
    Declined,
    Timeout,
    Superseded,
    Cancelled,
}

impl Outcome {
    /// The `result` the agent receives, Swift's raw values.
    pub fn id(self) -> &'static str {
        match self {
            Self::Done => "done",
            Self::Declined => "declined",
            Self::Timeout => "timeout",
            Self::Superseded => "superseded",
            Self::Cancelled => "cancelled",
        }
    }
}

struct Request {
    operation: String,
    message: String,
    deadline: Instant,
}

/// A finished request: the engine operation to answer, its thread, and why.
#[derive(Debug, PartialEq, Eq)]
pub struct Finished {
    pub operation: String,
    pub thread: String,
    pub outcome: Outcome,
}

#[derive(Default)]
pub struct UserTurns {
    open: HashMap<String, Request>,
}

impl UserTurns {
    /// Shows `message` in `thread`'s browser until answered or `timeout`
    /// seconds pass. Returns the request it replaced, if any.
    pub fn ask(
        &mut self,
        operation: String,
        thread: &str,
        message: &str,
        timeout: f64,
        now: Instant,
    ) -> Option<Finished> {
        let seconds = if timeout.is_finite() {
            timeout.clamp(1., USER_TURN_MAXIMUM_TIMEOUT)
        } else {
            USER_TURN_MAXIMUM_TIMEOUT
        };
        let replaced = self.open.insert(
            thread.to_owned(),
            Request {
                operation,
                message: clean_user_turn_message(message),
                deadline: now + Duration::from_secs_f64(seconds),
            },
        );
        replaced.map(|request| Finished {
            operation: request.operation,
            thread: thread.to_owned(),
            outcome: Outcome::Superseded,
        })
    }

    /// The message the thread's browser shows, while a request is open.
    pub fn message(&self, thread: &str) -> Option<&str> {
        self.open
            .get(thread)
            .map(|request| request.message.as_str())
    }

    /// The user's answer, or the end of the request for another reason.
    pub fn finish(&mut self, thread: &str, outcome: Outcome) -> Option<Finished> {
        self.open.remove(thread).map(|request| Finished {
            operation: request.operation,
            thread: thread.to_owned(),
            outcome,
        })
    }

    /// Requests whose time ran out by `now`.
    pub fn expire(&mut self, now: Instant) -> Vec<Finished> {
        let expired = self
            .open
            .iter()
            .filter(|(_, request)| request.deadline <= now)
            .map(|(thread, _)| thread.clone())
            .collect::<Vec<_>>();
        expired
            .into_iter()
            .filter_map(|thread| self.finish(&thread, Outcome::Timeout))
            .collect()
    }

    /// Ends every request, as when the browser shuts down.
    pub fn cancel_all(&mut self) -> Vec<Finished> {
        let threads = self.open.keys().cloned().collect::<Vec<_>>();
        threads
            .into_iter()
            .filter_map(|thread| self.finish(&thread, Outcome::Cancelled))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_request_per_thread_and_a_new_one_supersedes_it() {
        let now = Instant::now();
        let mut turns = UserTurns::default();
        assert_eq!(turns.ask("a".into(), "t1", "Sign in", 300., now), None);
        assert_eq!(turns.ask("b".into(), "t2", "", 300., now), None);
        assert_eq!(turns.message("t1"), Some("Sign in"));
        assert_eq!(
            turns.message("t2"),
            Some("The agent needs you to continue in the browser.")
        );
        assert_eq!(
            turns.ask("c".into(), "t1", "Approve the payment", 300., now),
            Some(Finished {
                operation: "a".into(),
                thread: "t1".into(),
                outcome: Outcome::Superseded
            })
        );
        assert_eq!(turns.message("t1"), Some("Approve the payment"));
        assert_eq!(
            turns
                .finish("t1", Outcome::Done)
                .map(|f| (f.operation, f.outcome)),
            Some(("c".into(), Outcome::Done))
        );
        assert_eq!(turns.message("t1"), None);
        assert_eq!(turns.finish("t1", Outcome::Declined), None);
    }

    #[test]
    fn requests_time_out_and_cancel_with_swift_results() {
        let now = Instant::now();
        let mut turns = UserTurns::default();
        turns.ask("a".into(), "t1", "x", 1., now);
        turns.ask("b".into(), "t2", "x", 10., now);
        turns.ask("c".into(), "t3", "x", f64::NAN, now);
        assert!(turns.expire(now + Duration::from_millis(500)).is_empty());
        let expired = turns.expire(now + Duration::from_secs(2));
        assert_eq!(expired.len(), 1);
        assert_eq!(
            (expired[0].operation.as_str(), expired[0].outcome),
            ("a", Outcome::Timeout)
        );
        assert!(
            turns
                .expire(now + Duration::from_secs(899))
                .iter()
                .all(|f| f.thread == "t2")
        );
        let mut cancelled = turns.cancel_all();
        cancelled.sort_by(|a, b| a.operation.cmp(&b.operation));
        assert_eq!(
            cancelled
                .iter()
                .map(|f| (f.operation.as_str(), f.outcome.id()))
                .collect::<Vec<_>>(),
            vec![("c", "cancelled")]
        );
        assert_eq!(Outcome::Declined.id(), "declined");
    }
}
