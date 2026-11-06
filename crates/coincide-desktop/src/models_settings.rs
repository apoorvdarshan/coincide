//! Model picker preferences use Swift's persisted schema. Catalog rows are
//! display metadata only: this pane never selects a model or grants authority.
use super::*;
use std::collections::BTreeMap;

pub(super) struct ModelsSettings {
    search: Entity<InputState>,
    custom: Entity<InputState>,
    provider: Option<String>,
    custom_provider: String,
    message: String,
}
impl ModelsSettings {
    pub(super) fn focus_provider(&mut self, provider: Option<String>) {
        if let Some(provider) = &provider {
            self.custom_provider = provider.clone();
        }
        self.provider = provider;
    }
    pub(super) fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            search: cx.new(|cx| InputState::new(window, cx).placeholder("Filter models")),
            custom: cx.new(|cx| InputState::new(window, cx).placeholder("Custom model ID")),
            provider: None,
            custom_provider: "codex".into(),
            message: String::new(),
        }
    }
    pub(super) fn subscriptions(&self, cx: &mut Context<Coincide>) -> Vec<Subscription> {
        [&self.search, &self.custom]
            .into_iter()
            .map(|input| {
                cx.subscribe(input, |_, _, event, cx| {
                    if matches!(event, InputEvent::Change) {
                        cx.notify();
                    }
                })
            })
            .collect()
    }
}
#[derive(Clone, Debug, PartialEq)]
pub(super) struct ModelRow {
    pub provider: String,
    pub model: String,
    pub name: String,
    pub custom: bool,
    pub favorite: bool,
    pub hidden: bool,
}
pub(super) fn providers() -> Vec<(String, String)> {
    coincide_core::provider_catalog::provider_catalog()
        .iter()
        .map(|p| {
            (
                serde_json::to_value(p.id)
                    .unwrap()
                    .as_str()
                    .unwrap()
                    .to_owned(),
                p.display_name.to_owned(),
            )
        })
        .collect()
}
pub(super) fn provider_value<'a>(settings: &'a Value, provider: &str) -> &'a Value {
    let entries = &settings["providers"];
    if let Some(rows) = entries.as_array() {
        rows.chunks_exact(2)
            .find(|pair| pair[0] == provider)
            .map(|pair| &pair[1])
            .unwrap_or(&Value::Null)
    } else {
        &entries[provider]
    }
}
pub(super) fn replace_provider(entries: &mut Value, provider: &str, value: Value) -> Result<()> {
    if let Some(rows) = entries.as_array_mut() {
        anyhow::ensure!(
            rows.len() % 2 == 0 && rows.chunks_exact(2).all(|p| p[0].is_string()),
            "Saved provider settings are malformed"
        );
        let indices = rows
            .chunks_exact(2)
            .enumerate()
            .filter(|(_, p)| p[0] == provider)
            .map(|(i, _)| i * 2 + 1)
            .collect::<Vec<_>>();
        anyhow::ensure!(indices.len() <= 1, "Duplicate saved provider settings");
        if let Some(index) = indices.first() {
            rows[*index] = value;
        } else {
            rows.push(json!(provider));
            rows.push(value);
        }
    } else {
        anyhow::ensure!(entries.is_object(), "Saved provider settings are malformed");
        entries[provider] = value;
    }
    Ok(())
}
fn reference(provider: &str, model: &str) -> Value {
    json!({"provider":provider,"modelID":model})
}
fn matches_reference(value: &Value, provider: &str, model: &str) -> bool {
    value["provider"] == provider && value["modelID"] == model
}
fn marked(settings: &Value, key: &str, provider: &str, model: &str) -> bool {
    settings[key]
        .as_array()
        .is_some_and(|rows| rows.iter().any(|r| matches_reference(r, provider, model)))
}
/// Rendering is bounded; a supplied catalog never authorizes an action.
pub(super) fn model_rows(
    settings: &Value,
    catalogs: &[Value],
    provider: Option<&str>,
    query: &str,
) -> Vec<ModelRow> {
    let query = query.trim().to_lowercase();
    let mut result = Vec::new();
    for (id, _) in providers() {
        if provider.is_some_and(|p| p != id) || provider_value(settings, &id)["isEnabled"] == false
        {
            continue;
        }
        let mut models =
            BTreeMap::from([("default".to_owned(), ("Provider default".to_owned(), false))]);
        for catalog in catalogs
            .iter()
            .take(32)
            .filter(|c| c["provider"] == id && c["state"] == "ready")
        {
            for row in catalog["models"]
                .as_array()
                .into_iter()
                .flatten()
                .take(1000)
            {
                if let Some(model) = row["id"]
                    .as_str()
                    .filter(|m| coincide_core::composer_selection::validate_model(m).is_ok())
                {
                    let name = row["displayName"].as_str().unwrap_or(model).to_owned();
                    models.insert(model.to_owned(), (name, false));
                }
            }
        }
        for model in provider_value(settings, &id)["customModels"]
            .as_array()
            .into_iter()
            .flatten()
            .take(1000)
            .filter_map(Value::as_str)
        {
            if coincide_core::composer_selection::validate_model(model).is_ok() {
                models
                    .entry(model.to_owned())
                    .and_modify(|r| r.1 = true)
                    .or_insert((model.to_owned(), true));
            }
        }
        // Saved preferences remain manageable even before discovery has run.
        for key in ["favoriteModels", "hiddenModels"] {
            for saved in settings[key]
                .as_array()
                .into_iter()
                .flatten()
                .take(1000)
                .filter(|r| r["provider"] == id)
            {
                if let Some(model) = saved["modelID"]
                    .as_str()
                    .filter(|m| coincide_core::composer_selection::validate_model(m).is_ok())
                {
                    models
                        .entry(model.to_owned())
                        .or_insert((model.to_owned(), false));
                }
            }
        }
        for (model, (name, custom)) in models {
            if !query.is_empty()
                && !name.to_lowercase().contains(&query)
                && !model.to_lowercase().contains(&query)
            {
                continue;
            }
            result.push(ModelRow {
                favorite: marked(settings, "favoriteModels", &id, &model),
                hidden: marked(settings, "hiddenModels", &id, &model),
                provider: id.clone(),
                model,
                name,
                custom,
            });
        }
    }
    result
}
#[derive(Clone, Copy)]
enum Change<'a> {
    Favorite(&'a str, &'a str, bool),
    Hidden(&'a str, &'a str, bool),
    Custom(&'a str, &'a str, bool),
}
fn preference_patch(settings: &Value, change: Change<'_>) -> Result<Value> {
    anyhow::ensure!(settings.is_object(), "Saved settings are malformed");
    let (provider, model) = match change {
        Change::Favorite(p, m, _) | Change::Hidden(p, m, _) | Change::Custom(p, m, _) => (p, m),
    };
    anyhow::ensure!(
        providers().iter().any(|(id, _)| id == provider),
        "Unknown provider"
    );
    coincide_core::composer_selection::validate_model(model)?;
    let mut patch = json!({});
    match change {
        Change::Favorite(_, _, enabled) | Change::Hidden(_, _, enabled) => {
            let key = if matches!(change, Change::Favorite(..)) {
                "favoriteModels"
            } else {
                "hiddenModels"
            };
            for field in ["favoriteModels", "hiddenModels"] {
                anyhow::ensure!(
                    settings[field].is_null() || settings[field].is_array(),
                    "Saved model preferences are malformed"
                );
                let mut rows = settings[field].as_array().cloned().unwrap_or_default();
                // Starring unhides; hiding unstars, matching Swift.
                if field == key || enabled {
                    rows.retain(|r| !matches_reference(r, provider, model));
                }
                if field == key && enabled {
                    rows.push(reference(provider, model));
                }
                patch[field] = json!(rows);
            }
        }
        Change::Custom(_, _, add) => {
            anyhow::ensure!(model != "default", "Provider default is already available");
            let mut entries = if settings["providers"].is_null() {
                json!({})
            } else {
                settings["providers"].clone()
            };
            let mut target = provider_value(settings, provider).clone();
            if target.is_null() {
                target = json!({});
            }
            anyhow::ensure!(target.is_object(), "Saved provider settings are malformed");
            let value = &target["customModels"];
            anyhow::ensure!(
                value.is_null() || value.is_array(),
                "Saved custom models are malformed"
            );
            let mut rows = value.as_array().cloned().unwrap_or_default();
            rows.retain(|r| r.as_str() != Some(model));
            if add {
                anyhow::ensure!(
                    rows.len() < 1000,
                    "Remove a custom model before adding another"
                );
                rows.push(json!(model));
            }
            target["customModels"] = json!(rows);
            replace_provider(&mut entries, provider, target)?;
            patch["providers"] = entries;
        }
    }
    Ok(patch)
}
fn save(engine: &SharedEngine, change: Change<'_>) -> Result<Value> {
    let mut owner = try_state(engine)?;
    anyhow::ensure!(!owner.admissions_frozen(), "App is closing");
    let response = owner.dispatch(json!({"method":"settings.read","params":{}}));
    anyhow::ensure!(
        response.get("error").is_none(),
        "Settings could not be read"
    );
    let patch = preference_patch(&response["result"], change)?;
    let response = owner.dispatch(json!({"method":"settings.patch","params":{"patch":patch}}));
    if let Some(error) = response.get("error") {
        anyhow::bail!(
            "{}",
            error["message"]
                .as_str()
                .unwrap_or("Model preferences were not saved")
        );
    }
    Ok(response["result"].clone())
}
impl Coincide {
    fn change_model_preference(
        &mut self,
        change: Change<'_>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match save(&self.engine, change) {
            Ok(settings) => {
                self.models_settings.message = "Saved".into();
                self.accept_settings(settings, window, cx);
            }
            Err(error) => {
                self.models_settings.message = error.to_string();
                cx.notify();
            }
        }
    }
    pub(super) fn models_settings_panel(
        &self,
        catalogs: &[Value],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = &self.models_settings;
        let query = state.search.read(cx).value().to_string();
        let rows = model_rows(&self.settings, catalogs, state.provider.as_deref(), &query);
        let mut filters = div().flex().flex_wrap().gap_1().child(
            Button::new("models-all")
                .label("All Providers")
                .when(state.provider.is_none(), |b| b.primary())
                .on_click(cx.listener(|this, _, _, cx| {
                    this.models_settings.provider = None;
                    cx.notify();
                })),
        );
        for (id, name) in providers() {
            let selected = state.provider.as_deref() == Some(&id);
            filters = filters.child(
                Button::new(SharedString::from(format!("models-filter-{id}")))
                    .label(name)
                    .when(selected, |b| b.primary())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.models_settings.provider = Some(id.clone());
                        cx.notify();
                    })),
            );
        }
        let count = rows.len();
        let mut list = div()
            .id("models-settings-list")
            .max_h(px(420.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        let mut last = String::new();
        for row in rows {
            if row.provider != last {
                list = list.child(
                    div()
                        .text_lg()
                        .child(presentation::provider_name(&row.provider).to_owned()),
                );
                last = row.provider.clone();
            }
            let favorite = row.favorite;
            let hidden = row.hidden;
            let (p, m) = (row.provider.clone(), row.model.clone());
            let (hp, hm) = (p.clone(), m.clone());
            let mut line = div()
                .flex()
                .flex_wrap()
                .items_center()
                .gap_2()
                .child(div().flex_1().child(format!(
                    "{} · {}{}{}",
                    row.name,
                    row.model,
                    if row.custom { " · Custom" } else { "" },
                    if hidden { " · Hidden" } else { "" }
                )))
                .child(
                    Button::new(SharedString::from(format!("models-star-{p}-{m}")))
                        .label(if favorite {
                            "Remove Favorite"
                        } else {
                            "Favorite"
                        })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.change_model_preference(
                                Change::Favorite(&p, &m, !favorite),
                                window,
                                cx,
                            )
                        })),
                )
                .child(
                    Button::new(SharedString::from(format!("models-hide-{hp}-{hm}")))
                        .label(if hidden {
                            "Show in Picker"
                        } else {
                            "Hide from Picker"
                        })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.change_model_preference(
                                Change::Hidden(&hp, &hm, !hidden),
                                window,
                                cx,
                            )
                        })),
                );
            if row.custom {
                let (p, m) = (row.provider, row.model);
                line = line.child(
                    Button::new(SharedString::from(format!("models-remove-{p}-{m}")))
                        .label("Remove Custom Model")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.change_model_preference(Change::Custom(&p, &m, false), window, cx)
                        })),
                );
            }
            list = list.child(line);
        }
        if count == 0 {
            list = list.child("No matching models. Try another filter or provider.");
        }
        let mut custom = div().flex().flex_wrap().gap_1();
        for (id, name) in providers() {
            let selected = state.custom_provider == id;
            custom = custom.child(
                Button::new(SharedString::from(format!("models-custom-{id}")))
                    .label(name)
                    .when(selected, |b| b.primary())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.models_settings.custom_provider = id.clone();
                        cx.notify();
                    })),
            );
        }
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().text_lg().child("Models"))
            .child("Favorite or hide models in the picker, and add custom model IDs.")
            .child(filters)
            .child(Input::new(&state.search))
            .child(list)
            .child(format!("{count} models"))
            .child(div().text_lg().child("Add Custom Model"))
            .child(custom)
            .child(Input::new(&state.custom))
            .child(
                Button::new("models-add-custom")
                    .label("Add Custom Model")
                    .disabled(state.custom.read(cx).value().trim().is_empty())
                    .on_click(cx.listener(|this, _, window, cx| {
                        let provider = this.models_settings.custom_provider.clone();
                        let model = this
                            .models_settings
                            .custom
                            .read(cx)
                            .value()
                            .trim()
                            .to_owned();
                        this.change_model_preference(
                            Change::Custom(&provider, &model, true),
                            window,
                            cx,
                        );
                    })),
            )
            .child(state.message.clone())
            .into_any_element()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn favorites_and_hidden_are_exclusive_and_preserve_foreign_rows() {
        let settings = json!({"favoriteModels":[{"provider":"codex","modelID":"x","opaque":7},{"provider":"future","modelID":"z"}],"hiddenModels":[{"provider":"codex","modelID":"x"}],"defaultSelection":{"provider":"codex","modelID":"fixed","accountID":"named"}});
        let patch = preference_patch(&settings, Change::Favorite("codex", "x", true)).unwrap();
        assert_eq!(
            patch["favoriteModels"],
            json!([{"provider":"future","modelID":"z"},{"provider":"codex","modelID":"x"}])
        );
        assert_eq!(patch["hiddenModels"], json!([]));
        assert!(patch.get("defaultSelection").is_none());
        let hidden = preference_patch(&settings, Change::Hidden("codex", "x", true)).unwrap();
        assert_eq!(
            hidden["favoriteModels"],
            json!([{"provider":"future","modelID":"z"}])
        );
    }
    #[::core::prelude::v1::test]
    fn custom_models_preserve_provider_metadata_and_reject_malformed_storage() {
        let settings = json!({"providers":{"codex":{"customModels":["first"],"executablePath":"kept","opaque":{"a":1}},"claude":{"isEnabled":false}}});
        let patch = preference_patch(&settings, Change::Custom("codex", "second", true)).unwrap();
        assert_eq!(
            patch["providers"]["codex"]["customModels"],
            json!(["first", "second"])
        );
        assert_eq!(patch["providers"]["codex"]["opaque"], json!({"a":1}));
        assert_eq!(
            patch["providers"]["claude"],
            settings["providers"]["claude"]
        );
        assert!(
            preference_patch(
                &json!({"providers":["odd"]}),
                Change::Custom("codex", "x", true)
            )
            .is_err()
        );
        assert!(preference_patch(&settings, Change::Custom("codex", "--bad", true)).is_err());
        assert!(
            preference_patch(
                &json!({"hiddenModels":{}}),
                Change::Favorite("codex", "x", true)
            )
            .is_err()
        );
    }
    #[::core::prelude::v1::test]
    fn swift_alternating_provider_map_roundtrips_unknown_entries() {
        let settings = json!({"providers":["future",{"opaque":7},"codex",{"customModels":["old"],"executablePath":"kept"}]});
        let patch = preference_patch(&settings, Change::Custom("codex", "new", true)).unwrap();
        assert_eq!(
            patch["providers"],
            json!(["future",{"opaque":7},"codex",{"customModels":["old","new"],"executablePath":"kept"}])
        );
        assert!(
            model_rows(&settings, &[], Some("codex"), "old")
                .iter()
                .any(|r| r.custom)
        );
    }
    #[::core::prelude::v1::test]
    fn rows_filter_group_deduplicate_and_do_not_treat_loading_or_preferences_as_proof() {
        let settings = json!({"providers":{"codex":{"customModels":["Exact-ID"]},"claude":{"isEnabled":false}},"favoriteModels":[{"provider":"codex","modelID":"Exact-ID"}],"hiddenModels":[{"provider":"codex","modelID":"old"}]});
        let catalogs = [
            json!({"provider":"codex","state":"ready","models":[{"id":"Exact-ID","displayName":"Readable"}]}),
            json!({"provider":"codex","state":"loading","models":[{"id":"not-observed"}]}),
        ];
        let rows = model_rows(&settings, &catalogs, Some("codex"), "readABLE");
        assert_eq!(rows.len(), 1);
        assert!(rows[0].favorite && rows[0].custom);
        let all = model_rows(&settings, &catalogs, None, "");
        assert!(
            !all.iter()
                .any(|r| r.provider == "claude" || r.model == "not-observed")
        );
        assert!(all.iter().any(|r| r.model == "old" && r.hidden));
        assert_eq!(all.iter().filter(|r| r.model == "Exact-ID").count(), 1);
    }
}
