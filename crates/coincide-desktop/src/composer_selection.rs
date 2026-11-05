//! Capability-aware, explicit selection drafts. Reading this view never starts
//! a provider or discovers/authenticates models. Apply is the only mutation.
use super::*;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
struct SelectionDraft {
    original: Value,
    access: Value,
    interaction: Value,
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
        Ok(
            json!({"threadId":thread["id"],"provider":self.provider,"model":model,"accountId":self.account,
            "effort":self.original["effort"],"speed":self.original["speed"],
            "accessMode":if self.access.is_null(){json!("approval")}else{self.access.clone()},
            "interactionMode":if self.interaction.is_null(){json!("build")}else{self.interaction.clone()}}),
        )
    }
}
#[derive(Default)]
pub(super) struct ComposerSelection {
    drafts: HashMap<String, SelectionDraft>,
    bound: Option<String>,
    context: Option<(String, Value, bool)>,
    capabilities: Value,
    accounts: Value,
    error: String,
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
impl Coincide {
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
            .child(div().flex().flex_wrap().items_center().gap_2()
                .child(Button::new("selection-model-default").label("Provider default").when(!draft.use_custom,|button|button.primary()).disabled(disabled || !default_supported)
                    .on_click(cx.listener(|this,_,_,cx|this.edit_selection(|draft|draft.use_custom=false,cx))))
                .child(Button::new("selection-model-custom").label("Custom model ID").when(draft.use_custom,|button|button.primary()).disabled(disabled || provider.is_none_or(|p|p["customModel"]["supported"] != true))
                    .on_click(cx.listener(|this,_,_,cx|this.edit_selection(|draft|draft.use_custom=true,cx))))
                .child(div().flex_1().min_w_0().child(Input::new(&self.model_input))))
            .child(div().text_xs().child(if draft.use_custom { "Custom model ID is unverified. No model discovery or authentication check has run." } else { "The provider resolves its default model when used. Authentication and availability have not been checked." }))
            .child(div().text_xs().child(format!("{effort_reason} {speed_reason} Saved values are never silently removed.")))
            .child(div().flex().flex_wrap().gap_2()
                .child(Button::new("selection-apply").label("Apply selection").disabled(disabled || !known_provider)
                    .on_click(cx.listener(|this,_,_,cx|this.apply_selection_draft(cx))))
                .child(Button::new("selection-refresh").label("Refresh capabilities").on_click(cx.listener(|this,_,_,cx|this.refresh_selection_capabilities(cx))))
                .child(Button::new("selection-reload").label("Discard selection edits").on_click(cx.listener(|this,_,window,cx|this.reload_selection_draft(window,cx))))
                .child(Button::new("provider-antigravity-setup").accessibility_id("provider-antigravity-setup").label("Antigravity accounts")
                    .on_click(cx.listener(|this,_,window,cx|{
                        this.bots_open=false;this.notifications_open=false;this.transcription_open=false;this.credentials_open=false;
                        this.open_antigravity_settings(window,cx);this.sync_transcription_binding(cx);
                    }))))
            .child(div().text_xs().child("Access: approval · Interaction: build. Changing a provider keeps the draft model and account until you explicitly choose replacements."));
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
        pane.into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn thread(selection: Value) -> Value {
        json!({"id":"t","selection":selection,"draft":"untouched"})
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
        for model in ["", "-flag", "a\nb", &"x".repeat(513)] {
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
}
