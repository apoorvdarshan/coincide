//! Pending text survives every unsuccessful save; only explicit retry replays failures.
use serde_json::{Value, json};
use std::collections::HashMap;

/// The editor owns its draft while a submission is awaiting acknowledgement.
/// The saved snapshot may be the submitted text or an older, partially typed
/// version, so it must not replace the editor's current successor.
#[derive(Default)]
pub(super) struct SubmittedDrafts {
    entries: Vec<SubmittedDraft>,
}

pub(super) struct SubmittedDraft {
    sequence: u64,
    thread: String,
    successor: String,
    edited: bool,
}

impl SubmittedDrafts {
    pub(super) fn begin(&mut self, sequence: u64, thread: &str, _draft: &str) {
        // A newer submission has consumed the previous visible successor.
        for entry in self
            .entries
            .iter_mut()
            .filter(|entry| entry.thread == thread)
        {
            entry.successor.clear();
            entry.edited = true;
        }
        self.entries.push(SubmittedDraft {
            sequence,
            thread: thread.into(),
            successor: String::new(),
            edited: false,
        });
    }

    pub(super) fn changed(&mut self, thread: &str, draft: &str) {
        for entry in self
            .entries
            .iter_mut()
            .filter(|entry| entry.thread == thread)
        {
            entry.successor = draft.into();
            entry.edited = true;
        }
    }

    pub(super) fn project(&self, thread: &mut Value) {
        let id = thread["id"].as_str().unwrap_or("");
        if let Some(entry) = self.entries.iter().rev().find(|entry| entry.thread == id) {
            thread["draft"] = json!(entry.successor);
        }
    }

    pub(super) fn finish(&mut self, sequence: u64) -> Option<SubmittedDraft> {
        let index = self
            .entries
            .iter()
            .position(|entry| entry.sequence == sequence)?;
        Some(self.entries.remove(index))
    }
}

impl SubmittedDraft {
    /// A provider can clear its saved input after the user has started a new
    /// draft, including one whose text happens to match the submitted text.
    pub(super) fn successor_to_save(&self) -> Option<(&str, &str)> {
        (self.edited && !self.successor.is_empty()).then_some((&self.thread, &self.successor))
    }
}

pub(super) struct PendingDraft {
    pub text: String,
    pub retry: bool,
    /// Set only after a save actually failed. Drafts waiting for their next
    /// boundary (blur, thread switch, quit) are not failures and stay silent.
    pub failed: bool,
}

pub(super) fn save_one(
    drafts: &mut HashMap<String, PendingDraft>,
    id: &str,
    save: impl FnOnce(&str, &str) -> Result<(), (bool, String)>,
) -> Option<String> {
    let pending = drafts.get(id).filter(|draft| draft.retry)?;
    match save(id, &pending.text) {
        Ok(()) => {
            drafts.remove(id);
            None
        }
        Err((definitely_not_written, error)) => {
            // Only a busy try_lock proves dispatch did not run.
            let draft = drafts.get_mut(id).unwrap();
            draft.retry = definitely_not_written;
            draft.failed = true;
            Some(error)
        }
    }
}

pub(super) fn retry_failed(drafts: &mut HashMap<String, PendingDraft>) {
    for draft in drafts.values_mut() {
        draft.retry = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn submitted_draft_snapshots_never_replace_newer_editor_text() {
        let mut submissions = SubmittedDrafts::default();
        submissions.begin(1, "a", "sent");
        let mut stale = json!({"id":"a","draft":"sent"});
        submissions.project(&mut stale);
        assert_eq!(stale["draft"], "");
        let mut earlier_snapshot = json!({"id":"a","draft":"se"});
        submissions.project(&mut earlier_snapshot);
        assert_eq!(earlier_snapshot["draft"], "");
        submissions.changed("a", "new message");
        let mut stale = json!({"id":"a","draft":"sent"});
        submissions.project(&mut stale);
        assert_eq!(stale["draft"], "new message");
        let mut other = json!({"id":"b","draft":"sent"});
        submissions.project(&mut other);
        assert_eq!(other["draft"], "sent");
        submissions.changed("a", "sent");
        let mut retyped = json!({"id":"a","draft":"sent"});
        submissions.project(&mut retyped);
        assert_eq!(retyped["draft"], "sent");
        let finished = submissions.finish(1).unwrap();
        assert_eq!(finished.successor_to_save(), Some(("a", "sent")));
        let mut after_completion = json!({"id":"a","draft":"stored later"});
        submissions.project(&mut after_completion);
        assert_eq!(after_completion["draft"], "stored later");
    }

    #[test]
    fn a_later_submission_cannot_restore_an_earlier_one() {
        let mut submissions = SubmittedDrafts::default();
        submissions.begin(1, "a", "first");
        submissions.changed("a", "second");
        submissions.begin(2, "a", "second");
        let mut old = json!({"id":"a","draft":"first"});
        submissions.project(&mut old);
        assert_eq!(old["draft"], "");
        assert!(submissions.finish(1).unwrap().successor_to_save().is_none());
    }
    #[test]
    fn saving_one_thread_does_not_allow_close_with_another_failed_draft() {
        let mut drafts = HashMap::from([
            (
                "saved".into(),
                PendingDraft {
                    text: "one".into(),
                    retry: true,
                    failed: false,
                },
            ),
            (
                "failed".into(),
                PendingDraft {
                    text: "two\n".into(),
                    retry: false,
                    failed: true,
                },
            ),
        ]);
        save_one(&mut drafts, "saved", |_, _| Ok(()));
        save_one(&mut drafts, "failed", |_, _| {
            panic!("explicit retry required")
        });
        assert!(!drafts.is_empty());
        assert_eq!(drafts["failed"].text, "two\n");
    }
    #[test]
    fn close_requires_all_drafts_saved_and_uncertain_failure_needs_explicit_retry() {
        let original = "  café 中文 👩🏽‍💻\n\n";
        let mut drafts = HashMap::from([(
            "thread".into(),
            PendingDraft {
                text: original.into(),
                retry: true,
                failed: false,
            },
        )]);
        save_one(&mut drafts, "thread", |_, text| {
            assert_eq!(text, original);
            Err((true, "busy".into()))
        });
        assert!(!drafts.is_empty());
        assert!(drafts["thread"].retry);
        assert_eq!(drafts["thread"].text, original);
        save_one(&mut drafts, "thread", |_, text| {
            assert_eq!(text, original);
            Err((false, "uncertain".into()))
        });
        assert!(!drafts.is_empty());
        assert!(!drafts["thread"].retry);
        for _ in 0..3 {
            save_one(&mut drafts, "thread", |_, _| {
                panic!("must not replay uncertain save")
            });
        }
        assert_eq!(drafts["thread"].text, original);
        retry_failed(&mut drafts);
        save_one(&mut drafts, "thread", |_, text| {
            assert_eq!(text, original);
            Ok(())
        });
        assert!(
            drafts.is_empty(),
            "close may proceed only after confirmed save"
        );
    }
}
