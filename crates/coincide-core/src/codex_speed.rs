//! Private source-bound service-tier history. Null selection means Standard;
//! a prior requested/adopted nonstandard tier requires an explicit reset.
use anyhow::{Result, ensure};
use serde_json::Value;
#[derive(Default)]
pub(super) struct History {
    asked: bool,
}
impl History {
    pub(super) fn adopt(&mut self, source_thread: &str, result: &Value) -> Result<()> {
        ensure!(
            !source_thread.is_empty() && result["thread"]["id"].as_str() == Some(source_thread),
            "Codex service tier belongs to another source thread"
        );
        // Only the actual owned thread acknowledgement can retain a tier.
        // Missing/null is unknown, not evidence of a faster tier.
        if let Some(tier) = result["serviceTier"].as_str()
            && !tier.is_empty()
            && tier != "default"
        {
            self.asked = true;
        }
        Ok(())
    }
    pub(super) fn request<'a>(&mut self, selected: Option<&'a str>) -> Option<&'a str> {
        if let Some(tier) = selected {
            self.asked = true;
            Some(tier)
        } else if self.asked {
            Some("default")
        } else {
            None
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn null_omits_fresh_and_sticky_reset_survives_default_and_missing_ack() {
        let mut history = History::default();
        history
            .adopt("source", &json!({"thread":{"id":"source"}}))
            .unwrap();
        assert_eq!(history.request(None), None);
        assert_eq!(history.request(Some("priority")), Some("priority"));
        assert_eq!(history.request(None), Some("default"));
        history
            .adopt(
                "source",
                &json!({"thread":{"id":"source"},"serviceTier":"default"}),
            )
            .unwrap();
        assert_eq!(history.request(None), Some("default"));
        history
            .adopt("source", &json!({"thread":{"id":"source"}}))
            .unwrap();
        assert_eq!(history.request(None), Some("default"));
    }
    #[test]
    fn only_owned_ack_can_require_standard_reset() {
        let mut history = History::default();
        assert!(
            history
                .adopt(
                    "source",
                    &json!({"thread":{"id":"other"},"serviceTier":"priority"})
                )
                .is_err()
        );
        assert_eq!(history.request(None), None);
        history
            .adopt(
                "source",
                &json!({"thread":{"id":"source"},"serviceTier":"priority"}),
            )
            .unwrap();
        assert_eq!(history.request(None), Some("default"));
        for tier in [Value::Null, json!(""), json!("default"), json!(17)] {
            let mut fresh = History::default();
            fresh
                .adopt(
                    "source",
                    &json!({"thread":{"id":"source"},"serviceTier":tier}),
                )
                .unwrap();
            assert_eq!(fresh.request(None), None);
        }
    }
}
