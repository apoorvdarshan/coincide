//! Capability-aware, explicit selection drafts. Reading this view never starts
//! a provider or discovers/authenticates models. Apply is the only mutation.
use super::*;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
struct SelectionDraft {
    original: Value,
    access: Value,
    interaction: Value,
    proposed_access: Value,
    proposed_interaction: Value,
    provider: String,
    account: Value,
    custom: String,
    use_custom: bool,
}
impl SelectionDraft {
    fn from_thread(thread: &Value) -> Self {
        let selection = &thread["selection"];
        let model = selection["modelID"].as_str().unwrap_or("default");
        Self {
            original: selection.clone(),
            access: thread["accessMode"].clone(),
            interaction: thread["interactionMode"].clone(),
            proposed_access: mode_or_default(&thread["accessMode"], "approval"),
            proposed_interaction: mode_or_default(&thread["interactionMode"], "build"),
            provider: text(selection, "provider"),
            account: selection["accountID"].clone(),
            custom: if model == "default" {
                String::new()
            } else {
                model.into()
            },
            use_custom: model != "default",
        }
    }
    fn params(&self, thread: &Value) -> Result<Value> {
        anyhow::ensure!(
            thread["selection"] == self.original
                && thread["accessMode"] == self.access
                && thread["interactionMode"] == self.interaction,
            "Saved selection changed; reload the selection draft before applying"
        );
        if self.use_custom {
            anyhow::ensure!(
                self.custom.len() <= 512 && !self.custom.chars().any(char::is_control),
                "Custom model ID must be at most 512 bytes without control characters"
            );
        }
        let model = if self.use_custom {
            self.custom.trim()
        } else {
            "default"
        };
        anyhow::ensure!(
            !model.is_empty()
                && !model.starts_with('-')
                && model.len() <= 512
                && !model.chars().any(char::is_control),
            "Custom model ID must be nonempty, at most 512 bytes, contain no control characters and not start with a hyphen"
        );
        anyhow::ensure!(
            self.proposed_interaction != "plan" || model != "default",
            "Plan needs an explicit model ID; choose a custom or provider-reported model first"
        );
        Ok(
            json!({"threadId":thread["id"],"provider":self.provider,"model":model,"accountId":self.account,
            "effort":self.original["effort"],"speed":self.original["speed"],
            "accessMode":self.proposed_access,
            "interactionMode":self.proposed_interaction}),
        )
    }
}
fn mode_or_default(raw: &Value, default: &str) -> Value {
    if raw.is_null() {
        json!(default)
    } else {
        raw.clone()
    }
}
fn advertised_mode(provider: &Value, key: &str, mode: &str) -> bool {
    let known = match key {
        "accessModes" => matches!(mode, "approval" | "fullAccess"),
        "interactionModes" => matches!(mode, "build" | "plan"),
        _ => false,
    };
    known
        && provider[key]
            .as_array()
            .is_some_and(|rows| rows.iter().any(|row| row == mode))
}
fn mode_problem(draft: &SelectionDraft, provider: Option<&Value>) -> Option<String> {
    let Some(provider) = provider else {
        return Some("Mode capabilities are unavailable. Proposed choices are retained.".into());
    };
    for (key, value, label) in [
        ("accessModes", &draft.proposed_access, "access"),
        (
            "interactionModes",
            &draft.proposed_interaction,
            "interaction",
        ),
    ] {
        if !value
            .as_str()
            .is_some_and(|mode| advertised_mode(provider, key, mode))
        {
            return Some(format!(
                "Proposed {label} mode {value} is unsupported by this provider. It has been retained; choose a supported mode explicitly."
            ));
        }
    }
    if draft.proposed_interaction == "plan"
        && (!draft.use_custom || draft.custom.trim() == "default" || draft.custom.trim().is_empty())
    {
        return Some(
            "Plan needs an explicit model ID; choose a custom or provider-reported model first."
                .into(),
        );
    }
    None
}
#[derive(Default)]
pub(super) struct ComposerSelection {
    drafts: HashMap<String, SelectionDraft>,
    bound: Option<String>,
    context: Option<(String, Value, bool)>,
    capabilities: Value,
    accounts: Value,
    error: String,
    catalog: Value,
    catalog_request: Option<CatalogRequest>,
    catalog_last_poll: Option<Instant>,
    expanded: bool,
}
#[derive(Clone, Debug)]
struct CatalogRequest {
    request_id: String,
    provider: String,
    account_id: String,
}
fn default_account_id(raw: &Value) -> Option<&str> {
    match raw {
        Value::Null => Some("default"),
        Value::String(id) if id.is_empty() || id == "default" => Some("default"),
        Value::String(id) => Some(id),
        _ => None,
    }
}
fn catalog_response_matches(value: &Value, request: &CatalogRequest) -> bool {
    value["requestId"].as_str() == Some(request.request_id.as_str())
        && value["provider"].as_str() == Some(request.provider.as_str())
        && value["accountID"].as_str() == Some(request.account_id.as_str())
        && matches!(
            value["state"].as_str(),
            Some("loading" | "ready" | "failed" | "unsupported")
        )
}
fn capability_lock(capabilities: &Value, running: bool) -> Option<String> {
    if running {
        return Some("Selection is locked while this conversation is running.".into());
    }
    if capabilities["locked"] == true {
        return Some(
            capabilities["lockReason"]
                .as_str()
                .unwrap_or("Selection is locked.")
                .into(),
        );
    }
    if capabilities["provenance"] != "static_runtime_contract"
        || !capabilities["providers"].is_array()
        || capabilities["locked"].as_bool().is_none()
    {
        return Some("Selection capabilities are unavailable. Refresh to retry.".into());
    }
    None
}
fn account_label(account: &Value) -> String {
    match account {
        Value::Null => "Default account (no stored ID)".into(),
        Value::String(id) if id.is_empty() => "Default account (empty stored ID)".into(),
        Value::String(id) if id == "default" => "Default account (stored ID: default)".into(),
        Value::String(id) => format!("Account ID: {id}"),
        other => format!("Unsupported stored account: {other}"),
    }
}
fn account_problem(provider: &Value, account: &Value, configured: &Value) -> Option<String> {
    let id = match account {
        Value::Null => "default",
        Value::String(id) if id.is_empty() || id == "default" => "default",
        Value::String(id) => id,
        _ => {
            return Some(
                "The stored account ID has an unsupported type; it has been retained.".into(),
            );
        }
    };
    match provider["accountPolicy"].as_str() {
        Some("default_only") if id != "default" => Some("This provider supports only the default account. Choose Use default account to replace the retained account ID.".into()),
        Some("default_only") => None,
        Some("configured_antigravity") if !configured.is_object() => Some("Configured account metadata is unavailable. Refresh capabilities or open Antigravity accounts.".into()),
        Some("configured_antigravity") if configured.get(id).is_none() => Some(format!("Account '{id}' is not configured. Choose a configured account or open Antigravity accounts.")),
        Some("configured_antigravity") => None,
        _ => Some("Account support is not described by current capabilities.".into()),
    }
}
impl Coincide {
    /// Existing provider setup explicitly applied a saved selection. Rebase only
    /// that thread; unrelated selection drafts and the message draft survive.
    pub(super) fn accept_saved_provider_selection(&mut self, mut thread: Value) {
        self.preserve_pending_draft(&mut thread);
        self.selection_ui
            .drafts
            .insert(text(&thread, "id"), SelectionDraft::from_thread(&thread));
        self.selected = Some(thread);
        self.selection_ui.context = None;
        self.selection_ui.bound = None;
    }
    pub(super) fn sync_composer_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let context = self.selected.as_ref().map(|thread| {
            let id = text(thread, "id");
            let running = self.running.contains(&id);
            (id, json!({"selection":thread["selection"],"accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"]}), running)
        });
        if self.selection_ui.context == context {
            return;
        }
        self.selection_ui.context = context.clone();
        let Some((id, _selection, _)) = context else {
            self.selection_ui.bound = None;
            self.selection_ui.capabilities = Value::Null;
            return;
        };
        let draft = self
            .selection_ui
            .drafts
            .entry(id.clone())
            .or_insert_with(|| SelectionDraft::from_thread(self.selected.as_ref().unwrap()));
        if self.selection_ui.bound.as_ref() != Some(&id) {
            self.selection_ui.bound = Some(id.clone());
            self.model_input.update(cx, |input, cx| {
                input.set_value(draft.custom.clone(), window, cx)
            });
        }
        self.refresh_selection_capabilities(cx);
    }
    fn refresh_selection_capabilities(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        match call(
            &self.engine,
            "agent.selection.capabilities",
            json!({"threadId":id}),
        ) {
            Ok(capabilities) => {
                self.selection_ui.capabilities = capabilities;
                self.selection_ui.error.clear();
            }
            Err(error) => {
                self.selection_ui.capabilities = Value::Null;
                self.selection_ui.error = format!("Capabilities unavailable: {error}");
            }
        }
        // This endpoint reads configured account metadata only, not vaults or auth.
        self.selection_ui.accounts = call(&self.engine, "providers.antigravity.status", json!({}))
            .map(|status| status["accounts"].clone())
            .unwrap_or(Value::Null);
        cx.notify();
    }
    pub(super) fn selection_model_changed(&mut self, cx: &mut Context<Self>) {
        if let Some(draft) = self
            .selection_ui
            .bound
            .as_ref()
            .and_then(|id| self.selection_ui.drafts.get_mut(id))
        {
            draft.custom = self.model_input.read(cx).value().to_string();
        }
        cx.notify();
    }
    fn edit_selection(&mut self, edit: impl FnOnce(&mut SelectionDraft), cx: &mut Context<Self>) {
        if let Some(draft) = self
            .selection_ui
            .bound
            .as_ref()
            .and_then(|id| self.selection_ui.drafts.get_mut(id))
        {
            edit(draft);
        }
        cx.notify();
    }
    fn reload_selection_draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(thread) = &self.selected {
            let draft = SelectionDraft::from_thread(thread);
            self.model_input.update(cx, |input, cx| {
                input.set_value(draft.custom.clone(), window, cx)
            });
            self.selection_ui.drafts.insert(text(thread, "id"), draft);
        }
        self.refresh_selection_capabilities(cx);
    }
    fn apply_selection_draft(&mut self, cx: &mut Context<Self>) {
        let result = (|| -> Result<Value> {
            let thread = self
                .selected
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Select a conversation first"))?;
            if let Some(reason) = capability_lock(
                &self.selection_ui.capabilities,
                self.running.contains(&text(thread, "id")),
            ) {
                anyhow::bail!(reason);
            }
            let draft = self
                .selection_ui
                .drafts
                .get(&text(thread, "id"))
                .ok_or_else(|| anyhow::anyhow!("Selection draft unavailable"))?;
            let provider = self.selection_ui.capabilities["providers"]
                .as_array()
                .and_then(|rows| rows.iter().find(|row| row["provider"] == draft.provider));
            if let Some(reason) = mode_problem(draft, provider) {
                anyhow::bail!(reason);
            }
            let params = draft.params(thread)?;
            call(&self.engine, "agent.select", params)
        })();
        match result {
            Ok(mut thread) => {
                self.preserve_pending_draft(&mut thread);
                let id = text(&thread, "id");
                let mut saved = SelectionDraft::from_thread(&thread);
                if let Some(previous) = self.selection_ui.drafts.get(&id) {
                    saved.custom = previous.custom.clone();
                }
                self.selection_ui.drafts.insert(id, saved);
                self.selected = Some(thread);
                self.selection_ui.context = None;
                self.status = "Selection saved. Custom model availability is checked by the provider when used.".into();
            }
            Err(error) => self.status = format!("Selection was not changed: {error}"),
        }
        cx.notify();
    }
    fn refresh_model_catalog(&mut self, cx: &mut Context<Self>) {
        if self.selection_ui.catalog_request.is_some() {
            return;
        }
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        if capability_lock(
            &self.selection_ui.capabilities,
            self.running.contains(&text(thread, "id")),
        )
        .is_some()
        {
            return;
        }
        let Some(draft) = self.selection_ui.drafts.get(&text(thread, "id")) else {
            return;
        };
        let Some(provider) = self.selection_ui.capabilities["providers"]
            .as_array()
            .and_then(|providers| providers.iter().find(|p| p["provider"] == draft.provider))
        else {
            return;
        };
        if provider["modelDiscovery"]["supported"] != true
            || account_problem(provider, &draft.account, &self.selection_ui.accounts).is_some()
        {
            return;
        }
        let provider = draft.provider.clone();
        let account_id = default_account_id(&draft.account)
            .unwrap_or("default")
            .to_owned();
        match call(
            &self.engine,
            "agent.models.refresh",
            json!({"provider":provider,"accountId":draft.account}),
        ) {
            Ok(value) => {
                let request = CatalogRequest {
                    request_id: text(&value, "requestId"),
                    provider,
                    account_id,
                };
                if request.request_id.is_empty() || !catalog_response_matches(&value, &request) {
                    self.selection_ui.catalog = json!({"provider":request.provider,"accountID":request.account_id,"state":"failed","error":"Invalid catalog refresh response"});
                } else {
                    self.selection_ui.catalog = value;
                    self.selection_ui.catalog_request = Some(request);
                    self.selection_ui.catalog_last_poll = None;
                }
            }
            Err(error) => {
                self.selection_ui.catalog = json!({"provider":provider,"accountID":account_id,"state":"failed","error":format!("Catalog refresh failed: {error}")})
            }
        }
        cx.notify();
    }
    pub(super) fn poll_selection_catalog(&mut self, cx: &mut Context<Self>) {
        let Some(request) = self.selection_ui.catalog_request.clone() else {
            return;
        };
        if self
            .selection_ui
            .catalog_last_poll
            .is_some_and(|last| last.elapsed() < Duration::from_millis(200))
        {
            return;
        }
        self.selection_ui.catalog_last_poll = Some(Instant::now());
        match call(
            &self.engine,
            "agent.models.status",
            json!({"requestId":request.request_id}),
        ) {
            Ok(value) if catalog_response_matches(&value, &request) => {
                let done = value["state"] != "loading";
                self.selection_ui.catalog = value;
                if done {
                    self.selection_ui.catalog_request = None;
                }
            }
            Ok(_) => {
                self.selection_ui.catalog = json!({"provider":request.provider,"accountID":request.account_id,"state":"failed","error":"Catalog scope or response changed; refresh explicitly to retry"});
                self.selection_ui.catalog_request = None;
            }
            Err(error) if engine_busy(&error) => return,
            Err(error) => {
                self.selection_ui.catalog = json!({"provider":request.provider,"accountID":request.account_id,"state":"failed","error":format!("Catalog status unavailable: {error}")});
                self.selection_ui.catalog_request = None;
            }
        }
        cx.notify();
    }
    fn select_catalog_model(
        &mut self,
        thread_id: &str,
        request_id: &str,
        model: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(thread) = self
            .selected
            .as_ref()
            .filter(|thread| thread["id"] == thread_id)
        else {
            return;
        };
        if capability_lock(
            &self.selection_ui.capabilities,
            self.running.iter().any(|id| id == thread_id),
        )
        .is_some()
        {
            return;
        }
        let Some(draft) = self.selection_ui.drafts.get(thread_id) else {
            return;
        };
        let catalog = &self.selection_ui.catalog;
        if draft.original != thread["selection"]
            || catalog["state"] != "ready"
            || catalog["provenance"] != "provider_model_list"
            || catalog["requestId"].as_str() != Some(request_id)
            || catalog["provider"].as_str() != Some(draft.provider.as_str())
            || catalog["accountID"].as_str() != default_account_id(&draft.account)
            || !catalog["models"]
                .as_array()
                .is_some_and(|rows| rows.iter().any(|row| row["id"] == model))
        {
            return;
        }
        self.edit_selection(
            |draft| {
                draft.custom = model.clone();
                draft.use_custom = true;
            },
            cx,
        );
        self.model_input
            .update(cx, |input, cx| input.set_value(model, window, cx));
    }
    pub(super) fn composer_selection_pane(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(thread) = &self.selected else {
            return div().into_any_element();
        };
        let Some(draft) = self.selection_ui.drafts.get(&text(thread, "id")) else {
            return div().child("Loading selection…").into_any_element();
        };
        let lock = capability_lock(
            &self.selection_ui.capabilities,
            self.running.contains(&text(thread, "id")),
        );
        let conflict = thread["selection"] != draft.original
            || thread["accessMode"] != draft.access
            || thread["interactionMode"] != draft.interaction;
        let disabled = lock.is_some() || conflict;
        let saved = &thread["selection"];
        let model = if saved["modelID"] == "default" {
            "Provider default".to_owned()
        } else {
            text(saved, "modelID")
        };
        let pending = draft.proposed_access != mode_or_default(&draft.access, "approval")
            || draft.proposed_interaction != mode_or_default(&draft.interaction, "build")
            || draft.provider != text(&draft.original, "provider")
            || draft.account != draft.original["accountID"]
            || (if draft.use_custom {
                draft.custom.trim()
            } else {
                "default"
            }) != draft.original["modelID"].as_str().unwrap_or("default");
        let saved_provider = text(saved, "provider");
        let account = if default_account_id(&saved["accountID"]) == Some("default") {
            "Default account".to_owned()
        } else {
            account_label(&saved["accountID"])
        };
        let access = mode_or_default(&thread["accessMode"], "approval");
        let interaction = mode_or_default(&thread["interactionMode"], "build");
        let access_label = match access.as_str() {
            Some("approval") => "Approval required".to_owned(),
            Some("fullAccess") => "Full access (no app approvals)".to_owned(),
            _ => format!("Unsupported access {access}"),
        };
        let interaction_label = match interaction.as_str() {
            Some("build") => "Build".to_owned(),
            Some("plan") => "Plan".to_owned(),
            _ => format!("Unsupported interaction {interaction}"),
        };
        let summary = format!(
            "{} · {interaction_label} · {access_label} · {model} · {account}",
            presentation::provider_name(&saved_provider)
        );
        let label = if self.selection_ui.expanded {
            "Hide selection options"
        } else if pending {
            "Selection · edits pending"
        } else {
            "Selection options"
        };
        let header = div()
            .mb_2()
            .flex()
            .items_center()
            .gap_2()
            .min_w_0()
            .child(div().flex_1().min_w_0().truncate().text_sm().child(summary))
            .child(
                Button::new("selection-disclosure")
                    .label(label)
                    .compact()
                    .tooltip(
                        lock.clone()
                            .unwrap_or_else(|| "Edit provider, model, account and modes".into()),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.selection_ui.expanded = !this.selection_ui.expanded;
                        cx.notify();
                    })),
            );
        if !self.selection_ui.expanded {
            return header.into_any_element();
        }
        let mut providers = div().flex().flex_wrap().gap_2();
        for provider in self.selection_ui.capabilities["providers"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let id = text(provider, "provider");
            let selected = id == draft.provider;
            providers = providers.child(
                Button::new(SharedString::from(format!("selection-provider-{id}")))
                    .label(text(provider, "displayName"))
                    .when(selected, |button| button.primary())
                    .disabled(disabled)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.edit_selection(|draft| draft.provider = id.clone(), cx)
                    })),
            );
        }
        let provider = self.selection_ui.capabilities["providers"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["provider"] == draft.provider));
        let known_provider = provider.is_some();
        let draft_mode_problem = mode_problem(draft, provider);
        let mut modes = div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().text_sm().child(format!(
                "Proposed access: {} · interaction: {}",
                draft.proposed_access, draft.proposed_interaction
            )));
        for (key, choices) in [
            (
                "accessModes",
                vec![
                    ("approval", "Approval required"),
                    ("fullAccess", "Full access (no app approvals)"),
                ],
            ),
            (
                "interactionModes",
                vec![("build", "Build"), ("plan", "Plan")],
            ),
        ] {
            let mut row = div().flex().flex_wrap().gap_2();
            for (mode, label) in choices {
                if !provider.is_some_and(|provider| advertised_mode(provider, key, mode)) {
                    continue;
                }
                let selected = if key == "accessModes" {
                    draft.proposed_access == mode
                } else {
                    draft.proposed_interaction == mode
                };
                row = row.child(
                    Button::new(SharedString::from(format!("selection-mode-{key}-{mode}")))
                        .label(label)
                        .when(selected, |button| button.primary())
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.edit_selection(
                                |draft| {
                                    if key == "accessModes" {
                                        draft.proposed_access = json!(mode);
                                    } else {
                                        draft.proposed_interaction = json!(mode);
                                    }
                                },
                                cx,
                            )
                        })),
                );
            }
            modes = modes.child(row);
        }
        if draft.proposed_access == "fullAccess" {
            modes = modes.child(div().text_xs().child("Full access lets Codex run without app approval prompts. Choose it only for a conversation you trust."));
        }
        if draft.proposed_interaction == "plan" {
            modes = modes.child(div().text_xs().child("Plan needs an explicit model ID and is available for ordinary Codex conversations. It does not send a message when selected."));
        }
        let draft_account_problem = provider.and_then(|provider| {
            account_problem(provider, &draft.account, &self.selection_ui.accounts)
        });
        let default_supported = provider.is_some_and(|p| {
            p["models"]
                .as_array()
                .is_some_and(|models| models.iter().any(|model| model["id"] == "default"))
        });
        let effort_reason = provider
            .and_then(|p| p["effort"]["reason"].as_str())
            .unwrap_or("Reasoning effort support is unavailable.");
        let speed_reason = provider
            .and_then(|p| p["speed"]["reason"].as_str())
            .unwrap_or("Speed support is unavailable.");
        let mut accounts = div()
            .flex()
            .flex_wrap()
            .gap_2()
            .child(div().text_sm().child(account_label(&draft.account)));
        accounts = accounts.child(
            Button::new("selection-account-default")
                .label("Use default account")
                .disabled(disabled || !known_provider)
                .on_click(cx.listener(|this, _, _, cx| {
                    this.edit_selection(|draft| draft.account = Value::Null, cx)
                })),
        );
        if provider.is_some_and(|provider| provider["accountPolicy"] == "configured_antigravity") {
            for (id, account) in self.selection_ui.accounts.as_object().into_iter().flatten() {
                let id = id.clone();
                let name = account["name"]
                    .as_str()
                    .filter(|name| !name.is_empty())
                    .unwrap_or(&id)
                    .to_owned();
                accounts = accounts.child(
                    Button::new(SharedString::from(format!("selection-account-{id}")))
                        .label(name)
                        .when(draft.account.as_str() == Some(id.as_str()), |button| {
                            button.primary()
                        })
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.edit_selection(|draft| draft.account = json!(id), cx)
                        })),
                );
            }
        }
        let mut pane = div().flex().flex_col().gap_2().mb_2().child(providers)
            .child(div().text_sm().child(format!("Saved: {} · {} · {}",text(&thread["selection"],"provider"),text(&thread["selection"],"modelID"),account_label(&thread["selection"]["accountID"]))))
            .child(accounts)
            .child(modes)
            .child(div().flex().flex_wrap().items_center().gap_2()
                .child(Button::new("selection-model-default").label("Provider default").when(!draft.use_custom,|button|button.primary()).disabled(disabled || !default_supported)
                    .on_click(cx.listener(|this,_,_,cx|this.edit_selection(|draft|draft.use_custom=false,cx))))
                .child(Button::new("selection-model-custom").label("Custom model ID").when(draft.use_custom,|button|button.primary()).disabled(disabled || provider.is_none_or(|p|p["customModel"]["supported"] != true))
                    .on_click(cx.listener(|this,_,_,cx|this.edit_selection(|draft|draft.use_custom=true,cx))))
                .child(div().flex_1().min_w_0().child(Input::new(&self.model_input))))
            .child(div().text_xs().child(if draft.use_custom { "Custom IDs are unverified unless listed in the provider-reported catalog below. Model access and authentication are not verified." } else { "The provider resolves its default model when used. Authentication and availability have not been checked." }))
            .child(div().text_xs().child(format!("{effort_reason} {speed_reason} Saved values are never silently removed.")))
            .child(div().text_xs().child(format!("Stored effort: {} · speed: {} · access: {} · interaction: {}",draft.original["effort"],draft.original["speed"],draft.access,draft.interaction)))
            .child(div().flex().flex_wrap().gap_2()
                .child(Button::new("selection-apply").label("Apply selection").disabled(disabled || !known_provider || draft_account_problem.is_some() || draft_mode_problem.is_some())
                    .on_click(cx.listener(|this,_,_,cx|this.apply_selection_draft(cx))))
                .child(Button::new("selection-refresh").label("Refresh capabilities").on_click(cx.listener(|this,_,_,cx|this.refresh_selection_capabilities(cx))))
                .child(Button::new("selection-reload").label("Discard selection edits").on_click(cx.listener(|this,_,window,cx|this.reload_selection_draft(window,cx))))
                .child(Button::new("provider-antigravity-setup").accessibility_id("provider-antigravity-setup").label("Antigravity accounts")
                    .on_click(cx.listener(|this,_,window,cx|{
                        this.bots_open=false;this.notifications_open=false;this.transcription_open=false;this.credentials_open=false;
                        this.open_antigravity_settings(window,cx);this.sync_transcription_binding(cx);
                    }))))
            .child(div().text_xs().child("Changing a provider keeps the draft model, account and modes until you explicitly choose replacements."));
        if let Some(reason) = draft_mode_problem {
            pane = pane.child(div().text_sm().child(reason));
        }
        if let Some(reason) = draft_account_problem {
            pane = pane.child(div().text_sm().child(reason));
        }
        if let Some(reason) = lock {
            pane = pane.child(div().text_sm().child(reason));
        }
        if conflict {
            pane=pane.child(div().text_sm().child("Saved selection changed. Your selection draft is retained; discard selection edits to reload before applying."));
        }
        if !known_provider {
            pane = pane.child(div().text_sm().child(format!(
                "Provider '{}' is not described by current capabilities.",
                draft.provider
            )));
        }
        if !self.selection_ui.error.is_empty() {
            pane = pane.child(div().text_sm().child(self.selection_ui.error.clone()));
        }
        let discovery_supported =
            provider.is_some_and(|provider| provider["modelDiscovery"]["supported"] == true);
        let discovery_reason = provider
            .and_then(|provider| provider["modelDiscovery"]["reason"].as_str())
            .unwrap_or("Model discovery is unavailable for this provider.")
            .to_owned();
        pane = pane.child(
            Button::new("selection-model-refresh")
                .label("Refresh provider model catalog")
                .disabled(
                    disabled
                        || !discovery_supported
                        || self.selection_ui.catalog_request.is_some()
                        || provider.is_some_and(|provider| {
                            account_problem(provider, &draft.account, &self.selection_ui.accounts)
                                .is_some()
                        }),
                )
                .on_click(cx.listener(|this, _, _, cx| this.refresh_model_catalog(cx))),
        );
        pane=pane.child(div().text_xs().child(if discovery_supported {"Refresh retrieves provider-reported models without sending a message or changing your selection.".to_owned()}else{discovery_reason}));
        let catalog = &self.selection_ui.catalog;
        let same_scope = catalog["provider"].as_str() == Some(draft.provider.as_str())
            && catalog["accountID"].as_str() == default_account_id(&draft.account);
        if !same_scope && self.selection_ui.catalog_request.is_some() {
            pane = pane.child(
                div()
                    .text_sm()
                    .child("A previously requested provider catalog is still loading."),
            );
        }
        if same_scope
            && matches!(catalog["state"].as_str(), Some("failed" | "unsupported"))
            && !catalog["error"].is_null()
        {
            pane = pane.child(div().text_sm().child(text(catalog, "error")));
        } else if same_scope && catalog["state"] == "loading" {
            pane = pane.child(div().text_sm().child("Loading provider model catalog…"));
        } else if same_scope && catalog["state"] == "ready" {
            pane=pane.child(div().text_xs().child("Provider-reported catalog. Authentication and actual model access are not verified. Reported effort/speed metadata does not enable runtime options."));
            let mut models = div()
                .id("selection-discovered-models")
                .max_h(px(160.))
                .overflow_y_scroll()
                .flex()
                .flex_col()
                .gap_1();
            if let Some(rows) = catalog["models"].as_array() {
                for model in rows.iter().take(200) {
                    let id = text(model, "id");
                    if id.is_empty() {
                        continue;
                    }
                    let name = text(model, "displayName");
                    let target = text(thread, "id");
                    let request_id = text(catalog, "requestId");
                    models = models.child(
                        Button::new(SharedString::from(format!("selection-catalog-model-{id}")))
                            .label(format!("{name} · {id}"))
                            .disabled(disabled)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.select_catalog_model(
                                    &target,
                                    &request_id,
                                    id.clone(),
                                    window,
                                    cx,
                                )
                            })),
                    );
                }
                if rows.is_empty() {
                    models = models.child(div().child("The provider reported no models."));
                }
                if rows.len() > 200 {
                    models =
                        models.child(div().child(
                            "Showing the first 200 models. Custom model IDs remain available.",
                        ));
                }
            }
            pane = pane.child(models);
        }
        div()
            .flex()
            .flex_col()
            .gap_2()
            .min_w_0()
            .child(header)
            .child(
                div()
                    .id("selection-advanced-scroll")
                    .max_h(px(120.))
                    .overflow_y_scroll()
                    .min_w_0()
                    .child(pane),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn thread(selection: Value) -> Value {
        json!({"id":"t","selection":selection,"draft":"untouched"})
    }
    fn modes(provider: &str, expanded: bool) -> Value {
        json!({"provider":provider,"accessModes":if expanded{json!(["approval","fullAccess"])}else{json!(["approval"])},"interactionModes":if expanded{json!(["build","plan"])}else{json!(["build"])}})
    }
    #[::core::prelude::v1::test]
    fn proposed_mode_targets_do_not_replace_saved_stale_baselines() {
        let mut thread = thread(json!({"provider":"codex","modelID":"explicit-model"}));
        thread["accessMode"] = json!("approval");
        thread["interactionMode"] = json!("build");
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.proposed_access = json!("fullAccess");
        draft.proposed_interaction = json!("plan");
        assert_eq!(draft.access, "approval");
        assert_eq!(draft.interaction, "build");
        let params = draft.params(&thread).unwrap();
        assert_eq!(params["accessMode"], "fullAccess");
        assert_eq!(params["interactionMode"], "plan");
        assert!(mode_problem(&draft, Some(&modes("codex", true))).is_none());
        assert_eq!(thread["draft"], "untouched");
    }
    #[::core::prelude::v1::test]
    fn changed_saved_mode_rejects_even_when_it_matches_proposed_target() {
        let mut thread = thread(json!({"provider":"codex","modelID":"specific"}));
        thread["accessMode"] = json!("approval");
        thread["interactionMode"] = json!("build");
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.proposed_access = json!("fullAccess");
        draft.proposed_interaction = json!("plan");
        thread["accessMode"] = json!("fullAccess");
        assert!(draft.params(&thread).is_err());
        thread["accessMode"] = json!("approval");
        thread["interactionMode"] = json!("plan");
        assert!(draft.params(&thread).is_err());
        assert_eq!(draft.proposed_interaction, "plan");
    }
    #[::core::prelude::v1::test]
    fn expanded_modes_remain_unavailable_until_actual_capabilities_advertise_them() {
        let thread = thread(json!({"provider":"codex","modelID":"specific"}));
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.proposed_access = json!("fullAccess");
        for provider in [
            Value::Null,
            json!({"provider":"codex"}),
            modes("codex", false),
        ] {
            assert!(!advertised_mode(&provider, "accessModes", "fullAccess"));
            assert!(mode_problem(&draft, Some(&provider)).is_some());
            assert_eq!(draft.proposed_access, "fullAccess");
        }
        assert!(mode_problem(&draft, None).is_some());
        assert!(!advertised_mode(
            &json!({"accessModes":["future"]}),
            "accessModes",
            "future"
        ));
        assert!(mode_problem(&draft, Some(&modes("codex", true))).is_none());
    }
    #[::core::prelude::v1::test]
    fn provider_switch_retains_modes_and_account_until_explicit_replacement() {
        let thread =
            thread(json!({"provider":"codex","modelID":"specific","accountID":"raw-account"}));
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.proposed_access = json!("fullAccess");
        draft.proposed_interaction = json!("plan");
        draft.provider = "claude".into();
        assert!(mode_problem(&draft, Some(&modes("claude", false))).is_some());
        assert_eq!(draft.proposed_access, "fullAccess");
        assert_eq!(draft.proposed_interaction, "plan");
        assert_eq!(draft.custom, "specific");
        assert_eq!(draft.account, "raw-account");
        draft.proposed_access = json!("approval");
        draft.proposed_interaction = json!("build");
        assert!(mode_problem(&draft, Some(&modes("claude", false))).is_none());
        assert_eq!(draft.params(&thread).unwrap()["accountId"], "raw-account");
    }
    #[::core::prelude::v1::test]
    fn plan_requires_explicit_model_and_never_substitutes_a_default() {
        let thread = thread(json!({"provider":"codex","modelID":"default"}));
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.proposed_interaction = json!("plan");
        let provider = modes("codex", true);
        assert!(draft.params(&thread).is_err());
        assert!(mode_problem(&draft, Some(&provider)).is_some());
        draft.use_custom = true;
        for model in ["", "default", " default "] {
            draft.custom = model.into();
            assert!(draft.params(&thread).is_err());
            assert!(mode_problem(&draft, Some(&provider)).is_some());
        }
        draft.custom = "explicit-model".into();
        assert_eq!(draft.params(&thread).unwrap()["model"], "explicit-model");
        assert!(mode_problem(&draft, Some(&provider)).is_none());
    }
    #[::core::prelude::v1::test]
    fn unknown_saved_modes_and_locks_are_preserved_without_downgrade() {
        let mut thread = thread(json!({"provider":"codex","modelID":"specific"}));
        thread["accessMode"] = json!({"future":"mode"});
        thread["interactionMode"] = json!("future");
        let before = thread.clone();
        let draft = SelectionDraft::from_thread(&thread);
        assert_eq!(draft.proposed_access, thread["accessMode"]);
        assert_eq!(draft.proposed_interaction, "future");
        assert!(mode_problem(&draft, Some(&modes("codex", true))).is_some());
        assert_eq!(thread, before);
        let caps = json!({"provenance":"static_runtime_contract","locked":true,"lockReason":"Bot/import lock","providers":[modes("codex",true)]});
        assert_eq!(
            capability_lock(&caps, false).as_deref(),
            Some("Bot/import lock")
        );
        assert!(capability_lock(&caps, true).is_some());
        let baseline = SelectionDraft::from_thread(
            &json!({"selection":{"provider":"codex","modelID":"default"}}),
        );
        assert!(baseline.access.is_null());
        assert!(baseline.interaction.is_null());
        assert_eq!(baseline.proposed_access, "approval");
        assert_eq!(baseline.proposed_interaction, "build");
    }
    #[::core::prelude::v1::test]
    fn custom_model_and_raw_account_survive_provider_choice_and_default_toggle() {
        let thread =
            thread(json!({"provider":"antigravity","accountID":"acct-α","modelID":"my-model"}));
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.provider = "claude".into();
        draft.use_custom = false;
        let params = draft.params(&thread).unwrap();
        assert_eq!(params["accountId"], "acct-α");
        assert_eq!(params["model"], "default");
        draft.use_custom = true;
        assert_eq!(draft.params(&thread).unwrap()["model"], "my-model");
        assert_eq!(thread["draft"], "untouched");
    }
    #[::core::prelude::v1::test]
    fn stale_saved_selection_never_overwrites_draft_or_dispatches() {
        let mut thread = thread(json!({"provider":"codex","modelID":"default"}));
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.custom = "draft".into();
        draft.use_custom = true;
        thread["selection"]["modelID"] = json!("external");
        assert!(draft.params(&thread).is_err());
        assert_eq!(draft.custom, "draft");
        thread["selection"] = draft.original.clone();
        thread["accessMode"] = json!("full");
        assert!(draft.params(&thread).is_err());
    }
    #[::core::prelude::v1::test]
    fn preserves_existing_options_and_rejects_invalid_custom_models() {
        let mut thread =
            thread(json!({"provider":"codex","modelID":"m","effort":"high","speed":"fast"}));
        thread["accessMode"] = json!("approval");
        thread["interactionMode"] = json!("build");
        let mut draft = SelectionDraft::from_thread(&thread);
        let params = draft.params(&thread).unwrap();
        assert_eq!(params["effort"], "high");
        assert_eq!(params["speed"], "fast");
        assert_eq!(params["accessMode"], "approval");
        assert_eq!(params["interactionMode"], "build");
        for model in ["", "-flag", "a\nb", "\nmodel", "model\t", &"x".repeat(513)] {
            draft.custom = model.into();
            assert!(draft.params(&thread).is_err());
        }
    }
    #[::core::prelude::v1::test]
    fn unavailable_and_locked_capabilities_fail_closed() {
        assert!(capability_lock(&Value::Null, false).is_some());
        let mut caps =
            json!({"provenance":"static_runtime_contract","providers":[],"locked":false});
        assert!(capability_lock(&caps, false).is_none());
        assert!(capability_lock(&caps, true).is_some());
        caps["locked"] = json!(true);
        caps["lockReason"] = json!("Imported conversation");
        assert_eq!(
            capability_lock(&caps, false).as_deref(),
            Some("Imported conversation")
        );
    }
    #[::core::prelude::v1::test]
    fn default_aliases_remain_distinguishable_until_explicit_choice() {
        for account in [Value::Null, json!(""), json!("default"), json!("custom")] {
            let thread =
                thread(json!({"provider":"codex","modelID":"default","accountID":account}));
            let draft = SelectionDraft::from_thread(&thread);
            assert_eq!(draft.params(&thread).unwrap()["accountId"], account);
            assert!(!account_label(&account).is_empty());
        }
    }
    #[::core::prelude::v1::test]
    fn account_compatibility_requires_explicit_replacement_without_auth_claims() {
        let default_only = json!({"accountPolicy":"default_only"});
        let configured = json!({"accountPolicy":"configured_antigravity"});
        assert!(account_problem(&default_only, &json!("other"), &Value::Null).is_some());
        for alias in [Value::Null, json!(""), json!("default")] {
            assert!(account_problem(&default_only, &alias, &Value::Null).is_none());
        }
        assert!(
            account_problem(&configured, &json!("a"), &json!({"a":{"name":"Account A"}})).is_none()
        );
        assert!(account_problem(&configured, &json!("a"), &json!({})).is_some());
        assert!(account_problem(&configured, &Value::Null, &Value::Null).is_some());
    }
    #[::core::prelude::v1::test]
    fn catalog_results_are_scoped_and_metadata_never_changes_selection() {
        let request = CatalogRequest {
            request_id: "request".into(),
            provider: "codex".into(),
            account_id: "default".into(),
        };
        let mut result = json!({"requestId":"request","provider":"codex","accountID":"default","state":"ready","models":[{"id":"reported","reportedEfforts":["high"]}]});
        assert!(catalog_response_matches(&result, &request));
        result["accountID"] = json!("other");
        assert!(!catalog_response_matches(&result, &request));
        result["accountID"] = json!("default");
        result["provider"] = json!("claude");
        assert!(!catalog_response_matches(&result, &request));
        result["provider"] = json!("codex");
        result["requestId"] = json!("old");
        assert!(!catalog_response_matches(&result, &request));
        let thread = thread(json!({"provider":"codex","modelID":"default"}));
        assert_eq!(
            SelectionDraft::from_thread(&thread)
                .params(&thread)
                .unwrap()["model"],
            "default"
        );
    }
}
