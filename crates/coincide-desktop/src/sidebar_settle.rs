//! Swift's ThreadInbox.settle: Settle hides idle conversations until new
//! activity arrives, Unsettle shows them again, and one Undo covers the batch.
use super::*;

/// A conversation's settled marker before and after a settle change.
pub(super) type SettleChange = (String, Option<Value>, Option<Value>);

/// The markers a settle change writes. Settle skips conversations that are
/// still working or waiting on the user, as Swift does, and marks the rest
/// settled now; Unsettle clears the markers that exist.
fn settle_changes(
    document: &Value,
    ids: &[String],
    settled: bool,
    now: f64,
    idle: impl Fn(&str) -> bool,
) -> Vec<SettleChange> {
    ids.iter()
        .filter(|id| !settled || idle(id))
        .map(|id| {
            (
                id.clone(),
                document["settledThreads"].get(id).cloned(),
                settled.then(|| json!(now)),
            )
        })
        .filter(|(_, before, after)| before.is_some() || after.is_some())
        .collect()
}

/// Whether Undo still restores exactly what the change replaced: every marker
/// is as it left it, and nothing it would unsettle has started working since.
fn undo_applies(
    document: &Value,
    changes: &[SettleChange],
    running: impl Fn(&str) -> bool,
) -> bool {
    changes.iter().all(|(id, before, after)| {
        document["settledThreads"].get(id) == after.as_ref() && (before.is_none() || !running(id))
    })
}

impl Coincide {
    /// Idle as Swift's Settle requires: not running, with no approval or
    /// question waiting.
    pub(super) fn sidebar_thread_idle(&self, id: &str) -> bool {
        !self.running.iter().any(|running| running == id)
            && call(&self.engine, "agent.pending", json!({"threadId":id}))
                .is_ok_and(|rows| rows.as_array().is_some_and(Vec::is_empty))
    }
    pub(super) fn settle_threads(&mut self, ids: &[String], settled: bool, cx: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        let changes = settle_changes(
            &self.sidebar_preferences.document,
            ids,
            settled,
            coincide_core::store::swift_timestamp(),
            |id| self.sidebar_thread_idle(id),
        );
        if changes.is_empty() {
            if settled {
                self.status = if ids.len() == 1 {
                    "Finish this conversation's work and approvals before settling it.".into()
                } else {
                    "Finish these conversations' work and approvals before settling them.".into()
                };
            }
            cx.notify();
            return;
        }
        let values = changes
            .iter()
            .map(|(id, _, after)| (id.clone(), after.clone()))
            .collect::<Vec<_>>();
        self.sidebar_thread_markers("settledThreads", &values, cx);
        if changes.iter().all(|(id, _, after)| {
            self.sidebar_preferences.document["settledThreads"].get(id) == after.as_ref()
        }) {
            self.sidebar_settle_undo = Some(changes);
        }
    }
    pub(super) fn undo_settle(&mut self, cx: &mut Context<Self>) {
        let Some(changes) = self.sidebar_settle_undo.take() else {
            return;
        };
        if undo_applies(&self.sidebar_preferences.document, &changes, |id| {
            self.running.iter().any(|running| running == id)
        }) {
            let values = changes
                .into_iter()
                .map(|(id, before, _)| (id, before))
                .collect::<Vec<_>>();
            self.sidebar_thread_markers("settledThreads", &values, cx);
        } else {
            self.status = "Conversation state changed; settle Undo was not applied.".into();
            cx.notify();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn settle_skips_busy_threads_and_unsettle_clears_only_existing_markers() {
        let document = json!({"settledThreads":{"a":5.0},"future":true});
        let ids = ["a".to_owned(), "b".to_owned(), "busy".to_owned()];
        let settle = settle_changes(&document, &ids, true, 9., |id| id != "busy");
        assert_eq!(
            settle,
            [
                ("a".to_owned(), Some(json!(5.0)), Some(json!(9.0))),
                ("b".to_owned(), None, Some(json!(9.0))),
            ]
        );
        let unsettle = settle_changes(&document, &ids, false, 9., |_| false);
        assert_eq!(unsettle, [("a".to_owned(), Some(json!(5.0)), None)]);
    }
    #[::core::prelude::v1::test]
    fn undo_refuses_a_batch_changed_since_or_one_that_would_unsettle_new_work() {
        let changes = vec![
            ("a".to_owned(), None, Some(json!(9.0))),
            ("b".to_owned(), Some(json!(1.0)), Some(json!(9.0))),
        ];
        let current = json!({"settledThreads":{"a":9.0,"b":9.0}});
        assert!(undo_applies(&current, &changes, |_| false));
        assert!(
            !undo_applies(&current, &changes, |id| id == "b"),
            "restoring b's older marker would hide its new work"
        );
        assert!(
            undo_applies(&current, &changes, |id| id == "a"),
            "removing a's marker shows its work"
        );
        let edited = json!({"settledThreads":{"a":9.0,"b":12.0}});
        assert!(!undo_applies(&edited, &changes, |_| false));
    }
}
