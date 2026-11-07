//! Standalone local composer commands. Unknown slash text is ordinary content.
use serde_json::Value;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Command {
    Model,
    Plan,
    Build,
    UsageLimits,
    Provider(&'static str),
}
impl Command {
    pub fn mode(self) -> Option<&'static str> {
        match self {
            Self::Model | Self::UsageLimits | Self::Provider(_) => None,
            Self::Plan => Some("plan"),
            Self::Build => Some("build"),
        }
    }
    pub fn provider(self) -> Option<&'static str> {
        match self {
            Self::Provider(provider) => Some(provider),
            _ => None,
        }
    }
    pub fn changes_selection(self) -> bool {
        self.mode().is_some() || self.provider().is_some()
    }
}
pub(super) fn standalone(text: &str) -> Option<Command> {
    match text.trim().to_ascii_lowercase().as_str() {
        "/model" => Some(Command::Model),
        "/usage-limits" => Some(Command::UsageLimits),
        "/plan" => Some(Command::Plan),
        "/build" | "/default" => Some(Command::Build),
        "/codex" => Some(Command::Provider("codex")),
        "/claude" => Some(Command::Provider("claude")),
        "/cursor" => Some(Command::Provider("cursor")),
        "/grok" => Some(Command::Provider("grok")),
        "/opencode" => Some(Command::Provider("opencode")),
        "/antigravity" => Some(Command::Provider("antigravity")),
        _ => None,
    }
}
fn has_content(raw: &Value) -> bool {
    !raw.is_null() && !raw.as_array().is_some_and(Vec::is_empty)
}
/// Like Swift, attachments/references make even `/plan` literal message content.
/// Malformed non-null payloads are left to normal Send validation, never consumed.
pub(super) fn intercept<T>(
    thread: &Value,
    draft: &str,
    effect: impl FnOnce(Command) -> T,
) -> Option<T> {
    if has_content(&thread["rustDraftImages"]) || has_content(&thread["draftContext"]) {
        return None;
    }
    standalone(draft).map(effect)
}
#[derive(Clone)]
pub(super) struct Submission {
    pub thread: Value,
    pub draft: String,
    pub restore_request: Option<String>,
    /// Chosen from the suggestion list, which already removed the `/word`: the rest of the
    /// draft, images and references stay as they are instead of being cleared.
    pub keep_draft: bool,
}
impl Submission {
    pub fn suggested(thread: &Value, draft: &str) -> Self {
        Self {
            keep_draft: true,
            ..Self::new(thread, draft)
        }
    }
    pub fn new(thread: &Value, draft: &str) -> Self {
        Self {
            thread: Value::Object(
                [
                    "id",
                    "draft",
                    "selection",
                    "accessMode",
                    "interactionMode",
                    "rustDraftImages",
                    "draftContext",
                ]
                .into_iter()
                .map(|key| (key.into(), thread[key].clone()))
                .collect(),
            ),
            draft: draft.into(),
            restore_request: None,
            keep_draft: false,
        }
    }
    pub fn same_content(&self, thread: &Value, draft: &str) -> bool {
        thread["id"] == self.thread["id"]
            && draft == self.draft
            && thread["draft"].as_str() == Some(self.draft.as_str())
            && thread["rustDraftImages"] == self.thread["rustDraftImages"]
            && thread["draftContext"] == self.thread["draftContext"]
    }
    pub fn same_selection(&self, thread: &Value) -> bool {
        ["selection", "accessMode", "interactionMode"]
            .iter()
            .all(|key| thread[*key] == self.thread[*key])
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn swift_standalone_names_case_whitespace_and_default_alias() {
        for (raw, expected) in [
            (" /MODEL\n", Command::Model),
            ("\t/Plan ", Command::Plan),
            ("/build", Command::Build),
            ("/default", Command::Build),
            (" /USAGE-LIMITS\n", Command::UsageLimits),
            (" /CoDeX\n", Command::Provider("codex")),
            ("/claude", Command::Provider("claude")),
            ("/cursor", Command::Provider("cursor")),
            ("/grok", Command::Provider("grok")),
            ("/opencode", Command::Provider("opencode")),
            ("/antigravity", Command::Provider("antigravity")),
        ] {
            assert_eq!(standalone(raw), Some(expected));
        }
        for raw in [
            "/unknown",
            "/plan now",
            "text /plan",
            "/usr/bin",
            "/@plan",
            "//plan",
            "/model/x",
            "plan",
            "/plan\nmore",
            "/usage-limits now",
            "/usage-limits/x",
            "/codex extra text",
            "/claude\nmore",
            "/codex/model",
            "/claude-code",
        ] {
            assert_eq!(standalone(raw), None);
        }
    }
    #[test]
    fn rejection_is_still_intercepted_never_falls_through_to_send_or_queue() {
        let thread = json!({"id":"a","draft":"/plan"});
        let mut sends = 0;
        let mut controls = 0;
        let handled = intercept(&thread, "/plan", |_| {
            controls += 1;
            Err::<(), _>("locked")
        });
        if handled.is_none() {
            sends += 1;
        }
        assert_eq!(controls, 1);
        assert_eq!(sends, 0);
        assert_eq!(handled, Some(Err("locked")));
    }
    #[test]
    fn attachments_context_and_invalid_payloads_stay_literal_unconsumed() {
        for command in ["/model", "/usage-limits", "/codex", "/claude"] {
            for (field, payload) in [
                ("rustDraftImages", json!([{"id":"image"}])),
                ("draftContext", json!([{"kind":"quote"}])),
                ("draftContext", json!({"malformed":true})),
                ("rustDraftImages", json!(false)),
            ] {
                let mut thread = json!({"id":"a","draft":command});
                thread[field] = payload;
                let original = thread.clone();
                assert!(
                    intercept(&thread, command, |_| panic!(
                        "must not consume content as control"
                    ))
                    .is_none()
                );
                assert_eq!(thread, original);
            }
        }
        assert_eq!(
            intercept(
                &json!({"rustDraftImages":[],"draftContext":[]}),
                "/model",
                |c| c
            ),
            Some(Command::Model)
        );
    }
    #[test]
    fn ack_must_match_exact_current_thread_draft_and_attached_content() {
        let thread = json!({"id":"a","draft":"  /plan\n","selection":{"provider":"codex","modelID":"custom"},"accessMode":"approval","interactionMode":"build"});
        let pending = Submission::new(&thread, "  /plan\n");
        assert!(pending.same_content(&thread, "  /plan\n"));
        assert!(pending.same_selection(&thread));
        for (field, value) in [
            ("id", json!("b")),
            ("draft", json!("new draft")),
            ("rustDraftImages", json!([{}])),
            ("draftContext", json!([{}])),
        ] {
            let mut changed = thread.clone();
            changed[field] = value;
            assert!(!pending.same_content(&changed, "  /plan\n"));
        }
        assert!(!pending.same_content(&thread, "/plan"));
        let mut changed = thread;
        changed["interactionMode"] = json!("plan");
        assert!(!pending.same_selection(&changed));
    }
}
