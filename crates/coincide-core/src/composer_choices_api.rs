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
        if key != account_key(&source["selection"])? {
            provider_switch_api::remember_source(target, source)?;
        }
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
        // A locally opened new composer can seed future conversations until
        // its first turn. Settings edits in established chats stay local.
        ensure!(
            explicit
                .get("rememberComposerChoice")
                .is_none_or(Value::is_boolean),
            "rememberComposerChoice must be boolean"
        );
        let id = source["id"].as_str();
        let selection_changed = source["selection"] != target["selection"];
        let settings = if explicit["rememberComposerChoice"] == true
            && id.is_some()
            && id == self.new_composer.as_deref()
            && id == self.active_thread()
            && source["items"].as_array().is_some_and(Vec::is_empty)
            && (selection_changed
                || (source["botID"].is_null() && source["accessMode"] != target["accessMode"]))
        {
            let mut settings = self
                .store
                .document("settings.json")?
                .unwrap_or_else(|| json!({}));
            ensure!(
                settings.is_object(),
                "Saved settings are unsupported; composer choice retained"
            );
            if let Some(bot) = source["botID"].as_str() {
                if settings["rustBotComposerDefaults"].is_null() {
                    settings["rustBotComposerDefaults"] = json!({});
                }
                let defaults = settings["rustBotComposerDefaults"]
                    .as_object_mut()
                    .context("Invalid saved bot composer defaults")?;
                let entry = defaults.entry(bot).or_insert_with(|| json!({}));
                let configured = &source["rustBotContext"]["selection"];
                if entry["configuredSelection"] != *configured || !entry["selections"].is_object() {
                    *entry = json!({"configuredSelection":configured,"selections":{}});
                }
                entry["selection"] = target["selection"].clone();
                entry["selections"][required(&target["selection"], "provider")?] =
                    target["selection"].clone();
                return self.store.save_composer_choice(target, Some(&settings));
            }
            if selection_changed {
                let previous_default = settings["defaultSelection"].clone();
                if settings["rustDefaultProviderSelections"].is_null() {
                    settings["rustDefaultProviderSelections"] = json!({});
                }
                let choices = settings["rustDefaultProviderSelections"]
                    .as_object_mut()
                    .context("Invalid saved default provider selections")?;
                if let Some(provider) = previous_default["provider"].as_str() {
                    choices
                        .entry(provider.to_owned())
                        .or_insert(previous_default);
                }
                choices.insert(
                    required(&target["selection"], "provider")?.to_owned(),
                    target["selection"].clone(),
                );
                settings["defaultSelection"] = target["selection"].clone();
            }
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
