//! Model picker preferences use Swift's persisted schema. Catalog rows are
//! display metadata only: this pane never selects a model or grants authority.
use super::*;
use gpui_kit::component::tooltip::Tooltip;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum ModelSort {
    #[default]
    Provider,
    Name,
}
pub(super) struct ModelsSettings {
    search: Entity<InputState>,
    custom: Entity<InputState>,
    provider: Option<String>,
    custom_provider: String,
    message: String,
    sort: ModelSort,
    /// Selected rows by (provider, model ID); a platform-modifier click adds.
    selected: BTreeSet<(String, String)>,
    adding: bool,
    add_error: Option<String>,
    /// The first visit asks every enabled provider for its models, as Swift's
    /// settings do on open; later visits wait for Reload Models.
    pub(super) loaded: bool,
}
impl ModelsSettings {
    pub(super) fn focus_provider(&mut self, provider: Option<String>) {
        if let Some(provider) = &provider {
            self.custom_provider = provider.clone();
        }
        self.provider = provider;
        self.selected.clear();
    }
    pub(super) fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            search: cx.new(|cx| InputState::new(window, cx).placeholder("Filter models")),
            custom: cx.new(|cx| InputState::new(window, cx).placeholder("model-id")),
            provider: None,
            custom_provider: "codex".into(),
            message: String::new(),
            sort: ModelSort::default(),
            selected: BTreeSet::new(),
            adding: false,
            add_error: None,
            loaded: false,
        }
    }
    pub(super) fn subscriptions(
        &self,
        window: &mut Window,
        cx: &mut Context<Coincide>,
    ) -> Vec<Subscription> {
        let custom = self.custom.clone();
        [&self.search, &self.custom]
            .into_iter()
            .map(|input| {
                let custom = custom.clone();
                cx.subscribe_in(
                    input,
                    window,
                    move |this, changed, event, window, cx| match event {
                        InputEvent::Change => {
                            if *changed == custom {
                                this.models_settings.add_error = None;
                            }
                            cx.notify();
                        }
                        InputEvent::PressEnter { .. } if *changed == custom => {
                            this.add_custom_model(window, cx);
                        }
                        _ => {}
                    },
                )
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
    /// The model new threads start with.
    pub default: bool,
    /// Reasoning efforts and faster speeds the provider reported, in its order.
    pub efforts: Vec<String>,
    pub speeds: Vec<String>,
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
/// Swift's `ProviderKind.displayName`, such as "Claude Code".
pub(super) fn provider_display_name(provider: &str) -> String {
    providers()
        .into_iter()
        .find(|(id, _)| id == provider)
        .map_or_else(|| provider.to_owned(), |(_, name)| name)
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
        let mut models = BTreeMap::from([(
            "default".to_owned(),
            ("Provider default".to_owned(), false, Vec::new(), Vec::new()),
        )]);
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
                    let strings = |key: &str, field: Option<&str>| {
                        row[key]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .take(64)
                            .filter_map(|value| match field {
                                Some(field) => value[field].as_str(),
                                None => value.as_str(),
                            })
                            .map(str::to_owned)
                            .collect::<Vec<_>>()
                    };
                    models.insert(
                        model.to_owned(),
                        (
                            name,
                            false,
                            strings("reportedEfforts", None),
                            strings("reportedSpeeds", Some("name")),
                        ),
                    );
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
                    .or_insert((model.to_owned(), true, Vec::new(), Vec::new()));
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
                    models.entry(model.to_owned()).or_insert((
                        model.to_owned(),
                        false,
                        Vec::new(),
                        Vec::new(),
                    ));
                }
            }
        }
        let default = default_selection(settings);
        for (model, (name, custom, efforts, speeds)) in models {
            if !query.is_empty()
                && !name.to_lowercase().contains(&query)
                && !model.to_lowercase().contains(&query)
            {
                continue;
            }
            result.push(ModelRow {
                favorite: marked(settings, "favoriteModels", &id, &model),
                hidden: marked(settings, "hiddenModels", &id, &model),
                default: matches_reference(&default, &id, &model),
                provider: id.clone(),
                model,
                name,
                custom,
                efforts,
                speeds,
            });
        }
    }
    result
}
/// Swift's default when nothing was saved yet.
pub(super) fn default_selection(settings: &Value) -> Value {
    let saved = &settings["defaultSelection"];
    if saved["provider"].is_string() && saved["modelID"].is_string() {
        saved.clone()
    } else {
        json!({"provider":"claude","modelID":"default"})
    }
}
/// Swift's `SettingsFormat.effort`.
pub(super) fn effort_label(effort: &str) -> String {
    match effort.to_lowercase().as_str() {
        "none" => "None".into(),
        "auto" => "Auto".into(),
        "minimal" => "Minimal".into(),
        "low" => "Low".into(),
        "medium" => "Medium".into(),
        "high" => "High".into(),
        "xhigh" | "extra-high" | "extra_high" => "Extra High".into(),
        "max" | "maximum" => "Max".into(),
        _ => {
            let mut chars = effort.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        }
    }
}
/// Efforts are listed in increasing order, so a range reads well.
fn effort_range(efforts: &[String]) -> String {
    match efforts {
        [] => "–".into(),
        [one] => effort_label(one),
        [first, .., last] => format!("{} – {}", effort_label(first), effort_label(last)),
    }
}
pub(super) fn sort_rows(rows: &mut [ModelRow], sort: ModelSort) {
    let order = |provider: &str| providers().iter().position(|(id, _)| id == provider);
    match sort {
        // Rows are already grouped in catalog order, then by model ID.
        ModelSort::Provider => rows.sort_by_key(|row| order(&row.provider)),
        ModelSort::Name => rows.sort_by(|a, b| {
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then_with(|| order(&a.provider).cmp(&order(&b.provider)))
        }),
    }
}
/// The new default selection: the model's effort is kept when it accepts it,
/// as Swift's `setDefaultModel` does. Account and speed start over.
pub(super) fn default_model_patch(settings: &Value, row: &ModelRow) -> Value {
    let current = default_selection(settings);
    let mut selection = json!({"provider":row.provider,"modelID":row.model});
    if let Some(effort) = current["effort"]
        .as_str()
        .filter(|effort| row.efforts.iter().any(|e| e == effort))
    {
        selection["effort"] = json!(effort);
    }
    json!({"defaultSelection":selection})
}
/// Why a custom model can't be added, with Swift's messages; `None` adds it.
pub(super) fn custom_model_problem(
    settings: &Value,
    catalogs: &[Value],
    provider: &str,
    raw: &str,
) -> Option<String> {
    let id = raw.trim();
    if id.is_empty() {
        return Some("Enter a model ID.".into());
    }
    if id.chars().any(char::is_whitespace) {
        return Some("Model IDs can’t contain spaces.".into());
    }
    if id.chars().count() > 256 {
        return Some("Model IDs must be 256 characters or fewer.".into());
    }
    if coincide_core::composer_selection::validate_model(id).is_err() {
        return Some("Model IDs can’t start with “-” or contain control characters.".into());
    }
    let offered = id == "default"
        || catalogs
            .iter()
            .filter(|c| c["provider"] == provider && c["state"] == "ready")
            .flat_map(|c| c["models"].as_array().into_iter().flatten())
            .any(|row| row["id"] == id);
    if offered {
        return Some(format!(
            "{} already offers that model.",
            provider_display_name(provider)
        ));
    }
    let custom = provider_value(settings, provider)["customModels"]
        .as_array()
        .is_some_and(|rows| rows.iter().any(|row| row == id));
    custom.then(|| "That custom model is already added.".into())
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
/// Several changes as one patch, each applied to the result of the last.
fn bulk_patch(settings: &Value, changes: &[Change<'_>]) -> Result<Value> {
    let mut current = settings.clone();
    let mut merged = json!({});
    for change in changes {
        let patch = preference_patch(&current, *change)?;
        for (key, value) in patch.as_object().into_iter().flatten() {
            current[key] = value.clone();
            merged[key] = value.clone();
        }
    }
    Ok(merged)
}
fn save(engine: &SharedEngine, changes: &[Change<'_>]) -> Result<Value> {
    let mut owner = try_state(engine)?;
    anyhow::ensure!(!owner.admissions_frozen(), "App is closing");
    // Native editing merges the current raw document under the same owner lock;
    // public JSON responses deliberately omit legacy environment values.
    let current = owner
        .store
        .document("settings.json")?
        .unwrap_or_else(|| json!({}));
    let patch = bulk_patch(&current, changes)?;
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
fn provider_id(key: &str) -> Option<coincide_core::provider_catalog::ProviderId> {
    coincide_core::provider_catalog::PROVIDERS
        .iter()
        .map(|descriptor| descriptor.id)
        .find(|id| settings_navigation::provider_key(*id) == key)
}
impl Coincide {
    fn change_model_preference(
        &mut self,
        changes: &[Change<'_>],
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match save(&self.engine, changes) {
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
    /// Every catalog this window has: each provider's last check (Reload
    /// Models, or Providers › Check All Again) and the composer's.
    pub(super) fn model_catalogs(&self, cx: &App) -> Vec<Value> {
        let mut catalogs = self.provider_configuration_panel.read(cx).catalogs();
        catalogs.push(self.selection_ui.catalog.clone());
        catalogs
    }
    /// Ask every enabled provider for its models again (Swift's Reload Models).
    pub(super) fn reload_models(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let providers = coincide_core::provider_catalog::PROVIDERS
            .iter()
            .map(|descriptor| settings_navigation::provider_key(descriptor.id))
            .filter(|id| provider_value(&self.settings, id)["isEnabled"] != false)
            .map(str::to_owned)
            .collect::<Vec<_>>();
        self.models_settings.loaded = true;
        self.provider_configuration_panel
            .update(cx, |panel, cx| panel.check_all(&providers, window, cx));
    }
    pub(super) fn set_default_model(
        &mut self,
        row: &ModelRow,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let patch = default_model_patch(&self.settings, row);
        match call(&self.engine, "settings.patch", json!({"patch":patch})) {
            Ok(settings) => {
                self.models_settings.message = format!(
                    "New threads start with {} · {}.",
                    provider_display_name(&row.provider),
                    row.name
                );
                self.accept_settings(settings, window, cx);
            }
            Err(error) => {
                self.models_settings.message = format!("The default model was not saved: {error}");
                cx.notify();
            }
        }
    }
    fn add_custom_model(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let provider = self.models_settings.custom_provider.clone();
        let raw = self.models_settings.custom.read(cx).value().to_string();
        let catalogs = self.model_catalogs(cx);
        if let Some(problem) = custom_model_problem(&self.settings, &catalogs, &provider, &raw) {
            self.models_settings.add_error = Some(problem);
            cx.notify();
            return;
        }
        let model = raw.trim().to_owned();
        self.change_model_preference(&[Change::Custom(&provider, &model, true)], window, cx);
        if self.models_settings.message == "Saved" {
            self.models_settings.adding = false;
            self.models_settings
                .custom
                .update(cx, |input, cx| input.set_value("", window, cx));
        }
    }
    fn click_model_row(&mut self, key: (String, String), add: bool, cx: &mut Context<Self>) {
        let selected = &mut self.models_settings.selected;
        if add {
            if !selected.remove(&key) {
                selected.insert(key);
            }
        } else {
            selected.clear();
            selected.insert(key);
        }
        cx.notify();
    }
    pub(super) fn models_settings_panel(
        &self,
        catalogs: &[Value],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = &self.models_settings;
        let query = state.search.read(cx).value().to_string();
        let mut rows = model_rows(&self.settings, catalogs, state.provider.as_deref(), &query);
        sort_rows(&mut rows, state.sort);
        let checking = self.provider_configuration_panel.read(cx).checking_all();
        let border = self.color(0x29303d);
        let muted = self.color(0x98a6ba).opacity(0.75);
        let in_provider_page = matches!(
            self.settings_section,
            settings::SettingsSection::Provider(_)
        );
        let mut filters = div().flex().flex_wrap().items_center().gap_1().child(
            Button::new("models-all")
                .label("All Providers")
                .when(state.provider.is_none(), |b| b.primary())
                .on_click(cx.listener(|this, _, _, cx| {
                    this.models_settings.provider = None;
                    this.models_settings.selected.clear();
                    cx.notify();
                })),
        );
        for (id, name) in providers() {
            if provider_value(&self.settings, &id)["isEnabled"] == false {
                continue;
            }
            let selected = state.provider.as_deref() == Some(&id);
            filters = filters.child(
                Button::new(SharedString::from(format!("models-filter-{id}")))
                    .label(name)
                    .when(selected, |b| b.primary())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.models_settings.provider = Some(id.clone());
                        this.models_settings.selected.clear();
                        cx.notify();
                    })),
            );
        }
        let toolbar = div()
            .flex()
            .flex_wrap()
            .items_center()
            .gap_2()
            .child(div().w(px(260.)).child(Input::new(&state.search)))
            .child(div().text_sm().child("Sort by"))
            .children(
                [
                    (ModelSort::Provider, "Provider"),
                    (ModelSort::Name, "Model"),
                ]
                .map(|(sort, label)| {
                    Button::new(SharedString::from(format!("models-sort-{label}")))
                        .label(label)
                        .compact()
                        .when(state.sort == sort, |b| b.primary())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.models_settings.sort = sort;
                            cx.notify();
                        }))
                }),
            )
            .child(div().flex_1())
            .child(
                Button::new("models-reload")
                    .label(if checking {
                        "Reloading Models…"
                    } else {
                        "Reload Models"
                    })
                    .tooltip("Ask every provider for its models again")
                    .disabled(checking)
                    .on_click(cx.listener(|this, _, window, cx| this.reload_models(window, cx))),
            );
        let count = rows.len();
        let column =
            |text: SharedString, width: f32| div().w(px(width)).flex_none().truncate().child(text);
        let mut list = div()
            .id("models-settings-list")
            .max_h(px(420.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .border_1()
            .border_color(border)
            .rounded_md()
            .child(
                div()
                    .flex()
                    .gap_2()
                    .px_2()
                    .py_1()
                    .border_b_1()
                    .border_color(border)
                    .text_sm()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(div().flex_1().min_w_0().child("Model"))
                    .child(column("Provider".into(), 130.))
                    .child(column("Reasoning".into(), 140.))
                    .child(column("Speed".into(), 90.)),
            );
        let accent = self.color(0x98b1d4);
        for row in &rows {
            let key = (row.provider.clone(), row.model.clone());
            let selected = state.selected.contains(&key);
            let mut name = div()
                .flex_1()
                .min_w_0()
                .flex()
                .items_center()
                .gap_1p5()
                .child(
                    div()
                        .truncate()
                        .when(row.hidden, |name| name.text_color(muted))
                        .child(row.name.clone()),
                );
            if row.favorite {
                name = name.child(div().text_xs().text_color(accent).child("★"));
            }
            for (shown, tag) in [
                (row.default, "Default"),
                (row.custom, "Custom"),
                (row.hidden, "Hidden"),
            ] {
                if shown {
                    name = name.child(
                        div()
                            .px_1()
                            .rounded_sm()
                            .border_1()
                            .border_color(border)
                            .text_xs()
                            .text_color(if tag == "Default" {
                                self.color(0xe4e9f2)
                            } else {
                                muted
                            })
                            .child(tag),
                    );
                }
            }
            let provider = provider_display_name(&row.provider);
            let provider_cell = div()
                .w(px(130.))
                .flex_none()
                .flex()
                .items_center()
                .gap_1()
                .child(div().truncate().child(provider))
                .when(row.provider == "antigravity", |cell| {
                    cell.child(
                        div()
                            .id(SharedString::from(format!("models-risk-{}", row.model)))
                            .text_xs()
                            .text_color(rgb(0xF5A524))
                            .child("⚠")
                            .tooltip(|window, cx| {
                                Tooltip::new("Using Antigravity through Coincide may break Google’s terms. Details are in Settings › Antigravity.").build(window, cx)
                            }),
                    )
                });
            let model_id = row.model.clone();
            list = list.child(
                div()
                    .id(SharedString::from(format!(
                        "models-row-{}-{}",
                        row.provider, row.model
                    )))
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .py_1()
                    .border_b_1()
                    .border_color(border)
                    .when(selected, |line| line.bg(accent.opacity(0.22)))
                    .when(!selected, |line| {
                        line.hover(|line| line.bg(accent.opacity(0.08)))
                    })
                    .child(name)
                    .child(provider_cell)
                    .child(column(effort_range(&row.efforts).into(), 140.).text_color(muted))
                    .child(
                        column(
                            if row.speeds.is_empty() {
                                "–".into()
                            } else {
                                row.speeds.join(", ").into()
                            },
                            90.,
                        )
                        .text_color(muted),
                    )
                    .tooltip(move |window, cx| {
                        Tooltip::new(format!("Model ID: {model_id}")).build(window, cx)
                    })
                    .on_click(cx.listener(move |this, event: &ClickEvent, _, cx| {
                        let modifiers = event.modifiers();
                        this.click_model_row(
                            key.clone(),
                            modifiers.platform || modifiers.control || modifiers.shift,
                            cx,
                        )
                    })),
            );
        }
        if count == 0 {
            let filtered = !query.trim().is_empty();
            list = list.child(
                div()
                    .p_6()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap_2()
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(if filtered {
                        "No Matching Models"
                    } else {
                        "No Models Yet"
                    }))
                    .child(div().text_sm().text_color(muted).child(if filtered {
                        "Try a different filter or provider."
                    } else {
                        "Providers list their models once they’re installed and signed in."
                    }))
                    .when(!filtered, |empty| {
                        empty.child(
                            Button::new("models-set-up-providers")
                                .label("Set Up Providers")
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.navigate_settings_section(
                                        settings::SettingsSection::Accounts,
                                        window,
                                        cx,
                                    )
                                })),
                        )
                    }),
            );
        }
        let chosen = rows
            .iter()
            .filter(|row| {
                state
                    .selected
                    .contains(&(row.provider.clone(), row.model.clone()))
            })
            .cloned()
            .collect::<Vec<_>>();
        let mut actions = div().flex().flex_wrap().items_center().gap_2();
        if !chosen.is_empty() {
            let favorites = chosen.iter().all(|row| row.favorite);
            let hidden = chosen.iter().all(|row| row.hidden);
            let keys = chosen
                .iter()
                .map(|row| (row.provider.clone(), row.model.clone()))
                .collect::<Vec<_>>();
            if let [row] = chosen.as_slice() {
                let default_row = row.clone();
                let copy = row.model.clone();
                actions = actions
                    .child(
                        Button::new("models-use-default")
                            .label("Use for New Threads")
                            .disabled(row.default)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.set_default_model(&default_row, window, cx)
                            })),
                    )
                    .child(
                        Button::new("models-copy-id")
                            .label("Copy Model ID")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()));
                                this.models_settings.message = "Copied the model ID.".into();
                                cx.notify();
                            })),
                    );
            }
            let (star_keys, hide_keys) = (keys.clone(), keys.clone());
            actions = actions
                .child(
                    Button::new("models-favorite")
                        .label(if favorites {
                            "Remove from Favorites"
                        } else {
                            "Add to Favorites"
                        })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            let changes = star_keys
                                .iter()
                                .map(|(p, m)| Change::Favorite(p, m, !favorites))
                                .collect::<Vec<_>>();
                            this.change_model_preference(&changes, window, cx)
                        })),
                )
                .child(
                    Button::new("models-hide")
                        .label(if hidden {
                            "Show in Model Picker"
                        } else {
                            "Hide from Model Picker"
                        })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            let changes = hide_keys
                                .iter()
                                .map(|(p, m)| Change::Hidden(p, m, !hidden))
                                .collect::<Vec<_>>();
                            this.change_model_preference(&changes, window, cx)
                        })),
                );
            if let [row] = chosen.as_slice()
                && !in_provider_page
                && let Some(id) = provider_id(&row.provider)
            {
                actions = actions.child(
                    Button::new("models-provider-settings")
                        .label(format!(
                            "Show {} Settings",
                            provider_display_name(&row.provider)
                        ))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.navigate_settings_section(
                                settings::SettingsSection::Provider(id),
                                window,
                                cx,
                            )
                        })),
                );
            }
            if chosen.iter().all(|row| row.custom) {
                let remove = keys;
                actions = actions.child(
                    Button::new("models-remove-custom")
                        .label(if chosen.len() == 1 {
                            "Remove Custom Model"
                        } else {
                            "Remove Custom Models"
                        })
                        .danger()
                        .on_click(cx.listener(move |this, _, window, cx| {
                            let changes = remove
                                .iter()
                                .map(|(p, m)| Change::Custom(p, m, false))
                                .collect::<Vec<_>>();
                            this.change_model_preference(&changes, window, cx);
                            this.models_settings.selected.clear();
                        })),
                );
            }
        }
        let mut form = div().flex().flex_col().gap_2();
        if state.adding {
            let mut custom = div().flex().flex_wrap().gap_1();
            for (id, name) in providers() {
                let selected = state.custom_provider == id;
                custom = custom.child(
                    Button::new(SharedString::from(format!("models-custom-{id}")))
                        .label(name)
                        .when(selected, |b| b.primary())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.models_settings.custom_provider = id.clone();
                            this.models_settings.add_error = None;
                            cx.notify();
                        })),
                );
            }
            form = form
                .p_4()
                .border_1()
                .border_color(border)
                .rounded_lg()
                .child(div().font_weight(FontWeight::SEMIBOLD).child("Add Custom Model"))
                .child(div().text_sm().text_color(muted).child(
                    "Use the ID the provider’s CLI accepts. It appears in the model picker even if the CLI doesn’t list it.",
                ))
                .child(div().text_sm().child("Provider"))
                .child(custom)
                .child(Input::new(&state.custom))
                .when_some(state.add_error.clone(), |form, error| {
                    form.child(div().text_xs().text_color(rgb(0xE5484D)).child(error))
                })
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(div().flex_1())
                        .child(Button::new("models-add-cancel").label("Cancel").on_click(
                            cx.listener(|this, _, _, cx| {
                                this.models_settings.adding = false;
                                this.models_settings.add_error = None;
                                cx.notify();
                            }),
                        ))
                        .child(
                            Button::new("models-add-custom")
                                .label("Add")
                                .primary()
                                .disabled(state.custom.read(cx).value().trim().is_empty())
                                .on_click(cx.listener(|this, _, window, cx| this.add_custom_model(window, cx))),
                        ),
                );
        }
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().text_lg().child("Models"))
            .child(div().text_sm().text_color(muted).child(
                "Models your providers offer, plus custom model IDs you add. Select a model to use it for new threads, star it, or hide it from the model picker. Command- or Control-click selects several.",
            ))
            .when(!in_provider_page, |pane| pane.child(filters))
            .child(toolbar)
            .child(list)
            .child(form)
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .child(
                        Button::new("models-add-open")
                            .label("Add Custom Model…")
                            .disabled(state.adding)
                            .on_click(cx.listener(|this, _, _, cx| {
                                let provider = this.models_settings.provider.clone();
                                let state = &mut this.models_settings;
                                if let Some(provider) = provider {
                                    state.custom_provider = provider;
                                }
                                state.adding = true;
                                state.add_error = None;
                                cx.notify();
                            })),
                    )
                    .child(div().text_sm().text_color(muted).child(if count == 1 {
                        "1 model".to_owned()
                    } else {
                        format!("{count} models")
                    }))
                    .child(div().flex_1())
                    .child(actions),
            )
            .child(div().text_sm().child(state.message.clone()))
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
    #[::core::prelude::v1::test]
    fn custom_model_validation_matches_swift_messages() {
        let settings = json!({"providers":{"codex":{"customModels":["mine"]}}});
        let catalogs = [json!({"provider":"codex","state":"ready","models":[{"id":"offered"}]})];
        let problem = |raw: &str| custom_model_problem(&settings, &catalogs, "codex", raw);
        assert_eq!(problem("  ").as_deref(), Some("Enter a model ID."));
        assert_eq!(
            problem("a b").as_deref(),
            Some("Model IDs can’t contain spaces.")
        );
        assert_eq!(
            problem(&"x".repeat(257)).as_deref(),
            Some("Model IDs must be 256 characters or fewer.")
        );
        assert!(problem("-flag").is_some());
        assert_eq!(
            problem(" offered ").as_deref(),
            Some("Codex already offers that model.")
        );
        assert_eq!(
            problem("mine").as_deref(),
            Some("That custom model is already added.")
        );
        assert_eq!(problem(" new-model "), None);
        assert!(custom_model_problem(&settings, &catalogs, "claude", "offered").is_none());
    }
    #[::core::prelude::v1::test]
    fn default_model_keeps_an_accepted_effort_and_marks_the_row() {
        let settings = json!({"defaultSelection":{"provider":"codex","modelID":"old","effort":"high","accountID":"named"}});
        let catalogs = [json!({"provider":"codex","state":"ready","models":[
            {"id":"old","reportedEfforts":["low","high"]},
            {"id":"new","displayName":"New","reportedEfforts":["low","high"],"reportedSpeeds":[{"id":"priority","name":"Fast"}]},
            {"id":"plain"}]})];
        let rows = model_rows(&settings, &catalogs, Some("codex"), "");
        let row = |id: &str| rows.iter().find(|row| row.model == id).unwrap().clone();
        assert!(row("old").default && !row("new").default);
        assert_eq!(row("new").speeds, vec!["Fast"]);
        assert_eq!(effort_range(&row("new").efforts), "Low – High");
        assert_eq!(effort_range(&row("plain").efforts), "–");
        assert_eq!(
            default_model_patch(&settings, &row("new")),
            json!({"defaultSelection":{"provider":"codex","modelID":"new","effort":"high"}})
        );
        assert_eq!(
            default_model_patch(&settings, &row("plain")),
            json!({"defaultSelection":{"provider":"codex","modelID":"plain"}})
        );
        // Nothing saved: Swift's Claude default is the one marked.
        let rows = model_rows(&json!({}), &[], Some("claude"), "");
        assert!(rows.iter().any(|row| row.model == "default" && row.default));
    }
    #[::core::prelude::v1::test]
    fn sorting_and_bulk_changes_apply_to_every_selected_model() {
        let settings = json!({"providers":{"codex":{"customModels":["b-model","A-model"]},"claude":{"customModels":["c-model"]}}});
        let mut rows = model_rows(&settings, &[], None, "model");
        sort_rows(&mut rows, ModelSort::Name);
        assert_eq!(
            rows.iter()
                .map(|row| row.model.as_str())
                .collect::<Vec<_>>(),
            vec!["A-model", "b-model", "c-model"]
        );
        sort_rows(&mut rows, ModelSort::Provider);
        assert_eq!(rows[0].provider, "claude");
        let patch = bulk_patch(
            &settings,
            &[
                Change::Favorite("codex", "A-model", true),
                Change::Favorite("claude", "c-model", true),
                Change::Custom("codex", "b-model", false),
            ],
        )
        .unwrap();
        assert_eq!(
            patch["favoriteModels"],
            json!([{"provider":"codex","modelID":"A-model"},{"provider":"claude","modelID":"c-model"}])
        );
        assert_eq!(
            patch["providers"]["codex"]["customModels"],
            json!(["A-model"])
        );
    }
}
