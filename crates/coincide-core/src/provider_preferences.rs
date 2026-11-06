//! Persisted provider visibility is a runtime admission preference, not merely
//! a model-picker filter. Both Swift dictionary encodings retain their meaning.
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

pub fn enabled(settings: &Value, provider: &str) -> Result<bool> {
    ensure!(
        crate::provider_catalog::provider_catalog()
            .iter()
            .any(|entry| serde_json::to_value(entry.id)
                .ok()
                .as_ref()
                .and_then(Value::as_str)
                == Some(provider)),
        "Unknown provider"
    );
    let entries = &settings["providers"];
    let entry = if entries.is_null() {
        &Value::Null
    } else if let Some(object) = entries.as_object() {
        object.get(provider).unwrap_or(&Value::Null)
    } else {
        let rows = entries
            .as_array()
            .context("Saved provider preferences are malformed")?;
        let (pairs, remainder) = rows.as_chunks::<2>();
        ensure!(
            remainder.is_empty() && pairs.iter().all(|pair| pair[0].is_string()),
            "Saved provider preferences are malformed"
        );
        let mut matches = pairs.iter().filter(|pair| pair[0] == provider);
        let first = matches.next().map(|pair| &pair[1]).unwrap_or(&Value::Null);
        ensure!(
            matches.next().is_none(),
            "Duplicate saved provider preferences"
        );
        first
    };
    ensure!(
        entry.is_null() || entry.is_object(),
        "Saved provider preferences are malformed"
    );
    match entry.get("isEnabled") {
        None | Some(Value::Null) => Ok(true),
        Some(Value::Bool(enabled)) => Ok(*enabled),
        _ => anyhow::bail!("Saved provider preference must be true or false"),
    }
}

impl crate::api::Engine {
    pub(super) fn require_provider_enabled(&self, provider: &str) -> Result<()> {
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        ensure!(
            enabled(&settings, provider)?,
            "This provider is disabled in Settings"
        );
        Ok(())
    }

    pub(super) fn apply_provider_preferences(&self, capabilities: &mut Value) -> Result<()> {
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        if let Some(providers) = capabilities["providers"].as_array_mut() {
            for row in providers {
                let provider = row["provider"]
                    .as_str()
                    .context("Invalid provider capability")?;
                if !enabled(&settings, provider)? {
                    row["enabled"] = json!(false);
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::enabled;
    use crate::{api::Engine, store::Store};
    use serde_json::json;

    #[test]
    fn reads_both_swift_encodings_without_mutating_unknown_provider_data() {
        for settings in [
            json!({"providers":{"future":{"opaque":3},"codex":{"isEnabled":false,"opaque":4}}}),
            json!({"providers":["future",{"opaque":3},"codex",{"isEnabled":false,"opaque":4}]}),
        ] {
            let before = settings.clone();
            assert!(!enabled(&settings, "codex").unwrap());
            assert!(enabled(&settings, "claude").unwrap());
            assert_eq!(settings, before);
        }
    }

    #[test]
    fn malformed_or_duplicate_known_preferences_fail_closed() {
        for settings in [
            json!({"providers":["codex"]}),
            json!({"providers":["codex",{},"codex",{"isEnabled":true}]}),
            json!({"providers":{"codex":{"isEnabled":"yes"}}}),
            json!({"providers":{"codex":false}}),
        ] {
            assert!(enabled(&settings, "codex").is_err());
        }
    }

    #[test]
    fn disabled_send_refuses_before_validation_or_transcript_mutation() {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        engine
            .store
            .save_document(
                "settings.json",
                &json!({"providers":{"codex":{"isEnabled":false}}}),
            )
            .unwrap();
        let created = engine.dispatch(json!({"method":"threads.create","params":{}}));
        let id = created["result"]["id"].as_str().unwrap().to_owned();
        let mut thread = engine.store.thread(&id).unwrap();
        // Invalid syntax guarantees this fixture cannot launch a real provider
        // even if the admission guard regresses.
        thread["selection"] =
            json!({"provider":"codex","accountID":"default","modelID":"invalid\nmodel"});
        thread["draft"] = json!("Preserve exact unsent text");
        engine.store.save(&thread).unwrap();
        let reply = engine
            .dispatch(json!({"method":"agent.send","params":{"threadId":id,"text":"No launch"}}));
        assert!(
            reply["error"]["message"]
                .as_str()
                .unwrap()
                .contains("disabled")
        );
        assert_eq!(engine.store.thread(&id).unwrap(), thread);
        assert!(
            engine.dispatch(json!({"method":"app.status","params":{}}))["result"]["running"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn disabled_catalog_and_selection_are_reported_without_process_launch() {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        engine
            .store
            .save_document(
                "settings.json",
                &json!({"providers":{"cursor":{"isEnabled":false}}}),
            )
            .unwrap();
        // Cursor's generic catalog is unsupported: this remains process-free
        // even if the new preference guard is accidentally removed.
        let refresh = engine
            .dispatch(json!({"method":"agent.models.refresh","params":{"provider":"cursor"}}));
        assert!(
            refresh["error"]["message"]
                .as_str()
                .unwrap()
                .contains("disabled")
        );
        let created = engine.dispatch(json!({"method":"threads.create","params":{}}));
        let id = created["result"]["id"].as_str().unwrap().to_owned();
        let mut thread = engine.store.thread(&id).unwrap();
        thread["selection"] =
            json!({"provider":"cursor","accountID":"default","modelID":"default"});
        engine.store.save(&thread).unwrap();
        let caps = engine
            .dispatch(json!({"method":"agent.selection.capabilities","params":{"threadId":id}}));
        assert_eq!(caps["result"]["locked"], true);
        assert!(
            caps["result"]["lockReason"]
                .as_str()
                .unwrap()
                .contains("disabled")
        );
    }
}
