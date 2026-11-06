//! Pending text survives every unsuccessful save; only explicit retry replays failures.
use std::collections::HashMap;

pub(super) struct PendingDraft {
    pub text: String,
    pub retry: bool,
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
            drafts.get_mut(id).unwrap().retry = definitely_not_written;
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
    fn saving_one_thread_does_not_allow_close_with_another_failed_draft() {
        let mut drafts = HashMap::from([
            (
                "saved".into(),
                PendingDraft {
                    text: "one".into(),
                    retry: true,
                },
            ),
            (
                "failed".into(),
                PendingDraft {
                    text: "two\n".into(),
                    retry: false,
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
