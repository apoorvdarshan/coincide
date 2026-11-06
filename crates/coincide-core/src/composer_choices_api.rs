//! Swift-compatible desired options are per provider/account. They are metadata,
//! never model authority; execution still requires the exact private catalog.
use super::*;

pub(super) fn account_key(selection: &Value) -> Result<String> {
    let provider = required(selection, "provider")?;
    let account = if crate::composer_selection::default_account(&selection["accountID"]) {
        "default"
    } else {
        required(selection, "accountID")?
    };
    Ok(format!("{provider}/{account}"))
}

pub(super) fn seed_preferences(target: &mut Value, source: &Value) -> Result<()> {
    let key = account_key(&source["selection"])?;
    if target["modelPreferences"].is_null() {
        if source["selection"]["effort"].is_null() && source["selection"]["speed"].is_null() {
            return Ok(());
        }
        target["modelPreferences"] = json!({});
    }
    ensure!(
        target["modelPreferences"].is_object(),
        "Saved account preferences are unsupported; choices retained"
    );
    if target["modelPreferences"].get(&key).is_none() {
        target["modelPreferences"][&key] =
            json!({"effort":source["selection"]["effort"],"speed":source["selection"]["speed"]});
    }
    Ok(())
}

impl Engine {
    pub(super) fn save_composer_choice(
        &mut self,
        source: &Value,
        target: &mut Value,
        explicit: &Value,
    ) -> Result<()> {
        seed_preferences(target, source)?;
        let key = account_key(&target["selection"])?;
        for option in ["effort", "speed"] {
            if explicit.get(option).is_some() {
                if target["modelPreferences"].is_null() {
                    target["modelPreferences"] = json!({});
                }
                ensure!(
                    target["modelPreferences"].is_object(),
                    "Invalid saved account preferences"
                );
                if target["modelPreferences"].get(&key).is_none() {
                    target["modelPreferences"][&key] = json!({});
                }
                ensure!(
                    target["modelPreferences"][&key].is_object(),
                    "Invalid saved account option preference"
                );
                target["modelPreferences"][&key][option] = target["selection"][option].clone();
            }
        }
        // Swift changes the global selection/access default only on an actual
        // user composer change. Existing threads and project overrides retain
        // their own saved choices; Plan is not a global default.
        ensure!(
            explicit
                .get("rememberComposerChoice")
                .is_none_or(Value::is_boolean),
            "rememberComposerChoice must be boolean"
        );
        let settings = if explicit["rememberComposerChoice"] == true
            && (source["selection"] != target["selection"]
                || source["accessMode"] != target["accessMode"])
        {
            let mut settings = self
                .store
                .document("settings.json")?
                .unwrap_or_else(|| json!({}));
            ensure!(
                settings.is_object(),
                "Saved settings are unsupported; composer choice retained"
            );
            settings["defaultSelection"] = target["selection"].clone();
            settings["defaultAccessMode"] = target["accessMode"]
                .as_str()
                .map(|mode| json!(mode))
                .unwrap_or_else(|| json!("approval"));
            Some(settings)
        } else {
            None
        };
        self.store.save_composer_choice(target, settings.as_ref())
    }
}
