//! Capability-aware, explicit selection drafts. Reading this view never starts
//! a provider or discovers/authenticates models. Explicit Apply and acknowledged
//! standalone mode commands use the same validated selection endpoint.
use super::*;
use anyhow::Context as _;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
struct SelectionDraft {
    original: Value,
    access: Value,
    interaction: Value,
    proposed_access: Value,
    proposed_interaction: Value,
    proposed_effort: Value,
    proposed_speed: Value,
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
            proposed_effort: selection["effort"].clone(),
            proposed_speed: selection["speed"].clone(),
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
    fn has_edits(&self) -> bool {
        self.proposed_effort != self.original["effort"]
            || self.proposed_speed != self.original["speed"]
            || self.proposed_access != mode_or_default(&self.access, "approval")
            || self.proposed_interaction != mode_or_default(&self.interaction, "build")
            || self.provider != text(&self.original, "provider")
            || self.account != self.original["accountID"]
            || (if self.use_custom {
                self.custom.trim()
            } else {
                "default"
            }) != self.original["modelID"].as_str().unwrap_or("default")
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
            "effort":self.proposed_effort,"speed":self.proposed_speed,
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
fn saved_effort_scope(draft: &SelectionDraft, thread: &Value) -> bool {
    draft.original == thread["selection"]
        && draft.access == thread["accessMode"]
        && draft.interaction == thread["interactionMode"]
        && draft.provider == text(&thread["selection"], "provider")
        && draft.account == thread["selection"]["accountID"]
        && (if draft.use_custom {
            draft.custom.as_str()
        } else {
            "default"
        }) == thread["selection"]["modelID"].as_str().unwrap_or("default")
}
fn effort_choices(
    draft: &SelectionDraft,
    thread: &Value,
    provider: Option<&Value>,
) -> Result<Vec<String>> {
    anyhow::ensure!(
        saved_effort_scope(draft, thread),
        "Apply the provider/account/model first, then refresh capabilities before choosing effort. Existing effort was retained"
    );
    let provider = provider.context("Effort capabilities are unavailable")?;
    let capability = &provider["effort"];
    anyhow::ensure!(
        draft.provider == "codex"
            && provider["provider"] == "codex"
            && capability["supported"] == true
            && capability["provenance"] == "provider_model_list"
            && capability["requiresExplicitModel"] == true,
        "{}",
        capability["reason"]
            .as_str()
            .unwrap_or("Refresh the current model catalog to choose effort")
    );
    anyhow::ensure!(
        draft.use_custom && !draft.custom.is_empty() && draft.custom != "default",
        "Choose an explicit Codex model before effort options"
    );
    let values = capability["choices"]
        .as_array()
        .context("Effort choices are invalid; refresh capabilities")?;
    anyhow::ensure!(values.len() <= 64, "Effort choices exceed their bound");
    let mut choices = Vec::new();
    for value in values {
        let value = value
            .as_str()
            .context("Effort choices are invalid; refresh capabilities")?;
        anyhow::ensure!(
            !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control),
            "Effort choice is invalid; refresh capabilities"
        );
        if !choices.iter().any(|choice| choice == value) {
            choices.push(value.to_owned());
        }
    }
    Ok(choices)
}
fn exact_astra_model(draft: &SelectionDraft) -> bool {
    draft.provider == "codex"
        && draft.use_custom
        && matches!(draft.custom.as_str(), "gpt-6-astra" | "openai.gpt-6-astra")
}
fn effort_default_label(
    draft: &SelectionDraft,
    thread: &Value,
    provider: Option<&Value>,
) -> String {
    if !exact_astra_model(draft) {
        return "Provider default".into();
    }
    let proven = provider.is_some_and(|provider| {
        provider["provider"] == "codex"
            && provider["effort"]["effectiveDefault"] == "medium"
            && provider["effort"]["effectiveDefaultProvenance"] == "app_policy+provider_model_list"
            && provider["effort"]["appDefaultRequired"] == true
            && provider["effort"]["appDefaultAvailable"] == true
            && effort_choices(draft, thread, Some(provider))
                .is_ok_and(|choices| choices.iter().any(|choice| choice == "medium"))
    });
    if proven {
        "Model/app default: Medium".into()
    } else {
        "Model/app default — refresh catalog required".into()
    }
}
fn automatic_default_replacement_context(
    draft: &SelectionDraft,
    thread: &Value,
    capabilities: &Value,
    running: bool,
) -> bool {
    !running
        && capabilities["provenance"] == "static_runtime_contract"
        && capabilities["providers"].is_array()
        && capabilities["locked"] == true
        && capabilities["canReplaceUnprovedAutomaticDefault"] == true
        && thread["rustBotContext"].is_null()
        && thread["botID"].is_null()
        && thread["selection"]["provider"] == "codex"
        && matches!(
            thread["selection"]["modelID"].as_str(),
            Some("gpt-6-astra" | "openai.gpt-6-astra")
        )
        && default_account_id(&thread["selection"]["accountID"]) == Some("default")
        && thread["selection"]["effort"].is_null()
        && thread["selection"]["speed"].is_null()
        && draft.original == thread["selection"]
        && draft.access == thread["accessMode"]
        && draft.interaction == thread["interactionMode"]
        && draft.account == draft.original["accountID"]
        && draft.proposed_effort == draft.original["effort"]
        && draft.proposed_speed == draft.original["speed"]
        && draft.proposed_access == mode_or_default(&draft.access, "approval")
        && draft.proposed_interaction == mode_or_default(&draft.interaction, "build")
}
fn automatic_default_replacement_target(
    draft: &SelectionDraft,
    thread: &Value,
    capabilities: &Value,
    running: bool,
) -> bool {
    automatic_default_replacement_context(draft, thread, capabilities, running)
        && (draft.provider != text(&thread["selection"], "provider")
            || (if draft.use_custom {
                draft.custom.trim()
            } else {
                "default"
            }) != thread["selection"]["modelID"].as_str().unwrap_or("default"))
}
fn effort_problem(
    draft: &SelectionDraft,
    thread: &Value,
    provider: Option<&Value>,
) -> Option<String> {
    if draft.proposed_effort.is_null() {
        return None;
    }
    match effort_choices(draft,thread,provider) {
        Ok(choices) if draft.proposed_effort.as_str().is_some_and(|value|choices.iter().any(|choice|choice==value))=>None,
        Ok(_)=>Some("Proposed effort is not supported by the current saved model; choose a reported choice or explicitly clear it".into()),
        Err(error)=>Some(error.to_string()),
    }
}
#[derive(Clone, Debug, PartialEq)]
struct SpeedChoice {
    id: String,
    name: String,
    detail: Option<String>,
}
fn speed_choices(
    draft: &SelectionDraft,
    thread: &Value,
    provider: Option<&Value>,
) -> Result<Vec<SpeedChoice>> {
    anyhow::ensure!(
        saved_effort_scope(draft, thread),
        "Apply or discard provider/account/model edits, then refresh capabilities before choosing speed. Existing speed was retained"
    );
    let provider = provider.context("Speed capabilities are unavailable")?;
    let capability = &provider["speed"];
    anyhow::ensure!(
        draft.provider == "codex"
            && provider["provider"] == "codex"
            && capability["supported"] == true
            && capability["provenance"] == "provider_model_list"
            && capability["requiresExplicitModel"] == true
            && capability.get("standard").is_some_and(Value::is_null),
        "{}",
        capability["reason"]
            .as_str()
            .unwrap_or("Refresh the current model catalog to choose speed")
    );
    anyhow::ensure!(
        draft.use_custom && !draft.custom.is_empty() && draft.custom != "default",
        "Choose an explicit Codex model before speed options"
    );
    let rows = capability["choices"]
        .as_array()
        .context("Speed choices are invalid; refresh capabilities")?;
    anyhow::ensure!(rows.len() <= 32, "Speed choices exceed their bound");
    let mut choices: Vec<SpeedChoice> = Vec::new();
    for row in rows {
        let id = row["id"].as_str().context("Speed choice ID is invalid")?;
        let name = row["name"]
            .as_str()
            .context("Speed choice name is invalid")?;
        anyhow::ensure!(
            !id.is_empty()
                && id != "default"
                && id.len() <= 128
                && id.trim() == id
                && !id.chars().any(char::is_control)
                && !name.is_empty()
                && name.len() <= 256
                && !name.chars().any(char::is_control),
            "Speed choice is invalid; refresh capabilities"
        );
        let detail = match &row["detail"] {
            Value::Null => None,
            Value::String(value) if value.len() <= 2048 && !value.chars().any(char::is_control) => {
                Some(value.clone())
            }
            _ => anyhow::bail!("Speed detail is invalid; refresh capabilities"),
        };
        if !choices.iter().any(|choice| choice.id == id) {
            choices.push(SpeedChoice {
                id: id.into(),
                name: name.into(),
                detail,
            });
        }
    }
    Ok(choices)
}
fn speed_problem(
    draft: &SelectionDraft,
    thread: &Value,
    provider: Option<&Value>,
) -> Option<String> {
    if draft.proposed_speed.is_null() {
        return None;
    }
    match speed_choices(draft,thread,provider) {
        Ok(choices) if draft.proposed_speed.as_str().is_some_and(|id|choices.iter().any(|choice|choice.id==id))=>None,
        Ok(_)=>Some("Proposed speed is unsupported by the current saved model; choose a reported tier or explicitly clear it".into()),
        Err(error)=>Some(error.to_string()),
    }
}
fn validate_speed_choice(
    draft: &SelectionDraft,
    thread: &Value,
    capabilities: &Value,
    running: bool,
    expected_id: &str,
    expected_selection: &Value,
    value: &Value,
) -> Result<()> {
    anyhow::ensure!(
        thread["id"].as_str() == Some(expected_id) && thread["selection"] == *expected_selection,
        "Speed choice belongs to a previous selection; pending values retained"
    );
    if let Some(reason) = capability_lock(capabilities, running) {
        anyhow::bail!(reason);
    }
    let provider = capabilities["providers"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["provider"] == draft.provider));
    let choices = speed_choices(draft, thread, provider)?;
    anyhow::ensure!(
        value.is_null()
            || value
                .as_str()
                .is_some_and(|id| choices.iter().any(|choice| choice.id == id)),
        "Speed choice is unknown or stale; pending values retained"
    );
    Ok(())
}
#[derive(Clone, Copy)]
enum SpeedRepair {
    Speed,
    Both,
}
fn speed_repair_params(
    draft: &SelectionDraft,
    thread: &Value,
    capabilities: &Value,
    running: bool,
    repair: SpeedRepair,
) -> Result<Value> {
    let flag = match repair {
        SpeedRepair::Speed => "repairSpeedClearAvailable",
        SpeedRepair::Both => "repairOptionsClearAvailable",
    };
    anyhow::ensure!(
        !running
            && capabilities["provenance"] == "static_runtime_contract"
            && capabilities[flag] == true
            && capabilities["locked"].as_bool().is_some(),
        "Clearing saved options is unavailable in the current conversation state"
    );
    anyhow::ensure!(
        saved_effort_scope(draft, thread)
            && !thread["selection"]["speed"].is_null()
            && draft.proposed_access == mode_or_default(&draft.access, "approval")
            && draft.proposed_interaction == mode_or_default(&draft.interaction, "build"),
        "Apply or discard other selection edits before clearing saved options"
    );
    match repair {
        SpeedRepair::Speed => {
            anyhow::ensure!(
                draft.proposed_effort == draft.original["effort"],
                "Discard pending effort edits before clearing only saved speed"
            );
            Ok(json!({"threadId":thread["id"],"speed":null}))
        }
        SpeedRepair::Both => {
            anyhow::ensure!(
                !thread["selection"]["effort"].is_null(),
                "Combined clear requires both saved options"
            );
            Ok(json!({"threadId":thread["id"],"effort":null,"speed":null}))
        }
    }
}
fn repair_clear_params(
    draft: &SelectionDraft,
    thread: &Value,
    capabilities: &Value,
    running: bool,
) -> Result<Value> {
    anyhow::ensure!(
        !running
            && capabilities["provenance"] == "static_runtime_contract"
            && capabilities["repairClearAvailable"] == true
            && capabilities["locked"].as_bool().is_some(),
        "Clearing saved effort is not available in the current conversation state"
    );
    anyhow::ensure!(
        !thread["selection"]["effort"].is_null()
            && draft.proposed_speed == draft.original["speed"]
            && saved_effort_scope(draft, thread)
            && draft.proposed_access == mode_or_default(&draft.access, "approval")
            && draft.proposed_interaction == mode_or_default(&draft.interaction, "build"),
        "Apply or discard other selection edits before clearing saved effort"
    );
    Ok(json!({"threadId":thread["id"],"effort":null}))
}
fn selection_response(
    engine: &mut coincide_core::api::Engine,
    method: &str,
    params: Value,
) -> Result<Value> {
    let response = engine.dispatch(json!({"method":method,"params":params}));
    if let Some(error) = response.get("error") {
        anyhow::bail!(
            "{}",
            error["message"]
                .as_str()
                .unwrap_or("Selection request failed")
        );
    }
    Ok(response["result"].clone())
}
fn command_params(
    thread: &Value,
    command: crate::composer_commands::Command,
    capabilities: &Value,
    running: bool,
) -> Result<Option<Value>> {
    if let Some(reason) = capability_lock(capabilities, running) {
        anyhow::bail!(reason);
    }
    // Swift /model opens its picker, rather than applying/validating a mode.
    // Preserve the authoritative capability/active/origin locks above; merely
    // showing existing choices must not invent another mode-change gate.
    if command == crate::composer_commands::Command::Model {
        return Ok(None);
    }
    let mut draft = SelectionDraft::from_thread(thread);
    if let Some(mode) = command.mode() {
        draft.proposed_interaction = json!(mode);
    }
    let provider = capabilities["providers"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["provider"] == draft.provider));
    if let Some(reason) = mode_problem(&draft, provider) {
        anyhow::bail!(reason);
    }
    command.mode().map(|_| draft.params(thread)).transpose()
}
/// Invoked under one Engine try-lock. Only existing validated selection/draft
/// endpoints are used, never Send/queue. Every rejection remains intercepted.
fn command_transaction(
    submission: &crate::composer_commands::Submission,
    command: crate::composer_commands::Command,
    running: bool,
    mut invoke: impl FnMut(&str, Value) -> Result<Value>,
) -> Result<Value> {
    let id = &submission.thread["id"];
    let current = invoke("threads.read", json!({"threadId":id,"itemLimit":0}))?;
    anyhow::ensure!(
        submission.same_content(&current, &submission.draft) && submission.same_selection(&current),
        "Saved composer changed; command draft retained. Reload or save the current draft before retrying"
    );
    let capabilities = invoke("agent.selection.capabilities", json!({"threadId":id}))?;
    let params = command_params(&current, command, &capabilities, running)?;
    let ack = if let Some(params) = params {
        invoke("agent.select", params)?
    } else {
        current
    };
    anyhow::ensure!(
        submission.same_content(&ack, &submission.draft),
        "Selection acknowledgement no longer matches this command's draft/content; draft retained"
    );
    if let Some(mode) = command.mode() {
        anyhow::ensure!(
            ack["interactionMode"] == mode,
            "Selection did not acknowledge the requested mode; draft retained"
        );
    }
    let before_clear = invoke("threads.read", json!({"threadId":id,"itemLimit":0}))?;
    anyhow::ensure!(
        submission.same_content(&before_clear, &submission.draft)
            && ["selection", "accessMode", "interactionMode"]
                .iter()
                .all(|key| before_clear[*key] == ack[*key]),
        "Composer changed after acknowledgement; draft retained"
    );
    // No UI callback/await or other controller can interleave the Engine lock.
    // This clears only text, never consumes images or references.
    let cleared = invoke("threads.patch", json!({"threadId":id,"patch":{"draft":""}}))
        .map_err(|error| anyhow::anyhow!("{}: {error}", if command.mode().is_some() {
            "Mode was saved, but command draft clearing failed; draft retained"
        } else { "Model controls were validated, but command draft clearing failed; draft retained" }))?;
    anyhow::ensure!(
        cleared["id"] == *id && cleared["draft"] == "",
        "Draft clear was not acknowledged; local draft retained"
    );
    Ok(cleared)
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
    pub(super) fn perform_composer_command(
        &mut self,
        command: crate::composer_commands::Command,
        submission: crate::composer_commands::Submission,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<Value> {
            let id = text(&submission.thread, "id");
            anyhow::ensure!(
                !self.attachment_import_threads.contains(&id),
                "Wait for image imports to finish; command draft retained"
            );
            if command.mode().is_some() {
                anyhow::ensure!(
                    !self
                        .selection_ui
                        .drafts
                        .get(&id)
                        .is_some_and(SelectionDraft::has_edits),
                    "Apply or discard pending selection edits before a mode command; command draft retained"
                );
            }
            anyhow::ensure!(
                self.pending_drafts
                    .get(&id)
                    .is_none_or(|pending| pending.text == submission.draft),
                "A newer pending draft exists; command draft retained"
            );
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(
                !engine.admissions_frozen(),
                "App is closing; command draft retained"
            );
            anyhow::ensure!(
                engine.active_thread() == Some(id.as_str()),
                "Active conversation changed; command draft retained"
            );
            command_transaction(
                &submission,
                command,
                self.running.contains(&id),
                |method, params| {
                    let response = engine.dispatch(json!({"method":method,"params":params}));
                    if let Some(error) = response.get("error") {
                        anyhow::bail!("{}", error["message"].as_str().unwrap_or("Command failed"));
                    }
                    Ok(response["result"].clone())
                },
            )
        })();
        match result {
            Ok(thread) => {
                let current = self.composer.read(cx).value().to_string();
                if self
                    .selected
                    .as_ref()
                    .is_some_and(|thread| submission.same_content(thread, &current))
                {
                    let id = text(&submission.thread, "id");
                    if self
                        .pending_drafts
                        .get(&id)
                        .is_some_and(|pending| pending.text == submission.draft)
                    {
                        self.pending_drafts.remove(&id);
                    }
                    if command.mode().is_some() {
                        self.accept_saved_provider_selection(thread);
                    } else {
                        self.selected = Some(thread);
                    }
                    self.composer
                        .update(cx, |input, cx| input.set_value("", window, cx));
                    if command == crate::composer_commands::Command::Model {
                        self.selection_ui.expanded = true;
                    }
                    self.status = match command {
                        crate::composer_commands::Command::Model => {
                            "Model controls opened. Choose and Apply a selection explicitly."
                        }
                        crate::composer_commands::Command::Plan => {
                            "Plan mode saved. No message was sent."
                        }
                        crate::composer_commands::Command::Build => {
                            "Build mode saved. No message was sent."
                        }
                    }
                    .into();
                } else {
                    self.status="Command acknowledged; newer conversation/draft retained. No message was sent.".into();
                }
            }
            Err(error) => self.status = format!("Command was not sent; draft retained: {error}"),
        }
        cx.notify();
    }
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
        let expected=self.selected.as_ref().map(|thread| json!({"selection":thread["selection"],"accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"]}));
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            let current = engine.store.thread(&id)?;
            anyhow::ensure!(
                expected
                    == Some(
                        json!({"selection":current["selection"],"accessMode":current["accessMode"],"interactionMode":current["interactionMode"]})
                    ),
                "Saved selection changed; reload before refreshing capabilities"
            );
            selection_response(
                &mut engine,
                "agent.selection.capabilities",
                json!({"threadId":id}),
            )
        })();
        match result {
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
    fn choose_effort(
        &mut self,
        expected_id: &str,
        expected_selection: &Value,
        value: Value,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<()> {
            let thread = self
                .selected
                .as_ref()
                .context("Select a conversation first")?;
            let id = text(thread, "id");
            anyhow::ensure!(
                id == expected_id && thread["selection"] == *expected_selection,
                "Effort choice belongs to a previous selection; pending values retained"
            );
            if let Some(reason) =
                capability_lock(&self.selection_ui.capabilities, self.running.contains(&id))
            {
                anyhow::bail!(reason);
            }
            let draft = self
                .selection_ui
                .drafts
                .get(&id)
                .context("Selection draft unavailable")?;
            let provider = self.selection_ui.capabilities["providers"]
                .as_array()
                .and_then(|rows| rows.iter().find(|row| row["provider"] == draft.provider));
            let choices = effort_choices(draft, thread, provider)?;
            anyhow::ensure!(
                value.is_null()
                    || value
                        .as_str()
                        .is_some_and(|value| choices.iter().any(|choice| choice == value)),
                "Effort choice is unknown or stale; pending values retained"
            );
            Ok(())
        })();
        match result {
            Ok(()) => self.edit_selection(|draft| draft.proposed_effort = value, cx),
            Err(error) => {
                self.status = format!("Effort was not changed: {error}");
                cx.notify();
            }
        }
    }
    fn choose_speed(
        &mut self,
        expected_id: &str,
        expected_selection: &Value,
        value: Value,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<()> {
            let thread = self
                .selected
                .as_ref()
                .context("Select a conversation first")?;
            let id = text(thread, "id");
            let draft = self
                .selection_ui
                .drafts
                .get(&id)
                .context("Selection draft unavailable")?;
            validate_speed_choice(
                draft,
                thread,
                &self.selection_ui.capabilities,
                self.running.contains(&id),
                expected_id,
                expected_selection,
                &value,
            )?;
            Ok(())
        })();
        match result {
            Ok(()) => self.edit_selection(|draft| draft.proposed_speed = value, cx),
            Err(error) => {
                self.status = format!("Speed was not changed: {error}");
                cx.notify();
            }
        }
    }
    fn clear_saved_effort(
        &mut self,
        expected_id: &str,
        expected_selection: &Value,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<Value> {
            let thread = self
                .selected
                .as_ref()
                .context("Select a conversation first")?;
            let id = text(thread, "id");
            anyhow::ensure!(
                id == expected_id && thread["selection"] == *expected_selection,
                "Effort repair belongs to a previous selection; current draft retained"
            );
            let draft = self
                .selection_ui
                .drafts
                .get(&id)
                .context("Selection draft unavailable")?;
            anyhow::ensure!(
                saved_effort_scope(draft, thread),
                "Saved selection changed; pending choices were retained"
            );
            let mut engine = try_state(&self.engine)?;
            let current = engine.store.thread(&id)?;
            let capabilities = selection_response(
                &mut engine,
                "agent.selection.capabilities",
                json!({"threadId":id}),
            )?;
            let params =
                repair_clear_params(draft, &current, &capabilities, self.running.contains(&id))?;
            selection_response(&mut engine, "agent.select", params)
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
                self.status="Saved effort explicitly cleared. Other selection fields, message draft and references were retained. No message was sent.".into();
                if self
                    .selected
                    .as_ref()
                    .is_some_and(|thread| exact_astra_model(&SelectionDraft::from_thread(thread)))
                {
                    self.status.push_str(" Model/app default applies only with fresh catalog proof; refresh capabilities before sending.");
                }
            }
            Err(error) => self.status = format!("Saved effort was not cleared: {error}"),
        }
        cx.notify();
    }
    fn clear_saved_speed_options(
        &mut self,
        expected_id: &str,
        expected_selection: &Value,
        repair: SpeedRepair,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<Value> {
            let thread = self
                .selected
                .as_ref()
                .context("Select a conversation first")?;
            let id = text(thread, "id");
            anyhow::ensure!(
                id == expected_id && thread["selection"] == *expected_selection,
                "Option repair belongs to a previous selection; current draft retained"
            );
            let draft = self
                .selection_ui
                .drafts
                .get(&id)
                .context("Selection draft unavailable")?;
            anyhow::ensure!(
                saved_effort_scope(draft, thread),
                "Saved selection changed; pending choices were retained"
            );
            let mut engine = try_state(&self.engine)?;
            let current = engine.store.thread(&id)?;
            let capabilities = selection_response(
                &mut engine,
                "agent.selection.capabilities",
                json!({"threadId":id}),
            )?;
            let params = speed_repair_params(
                draft,
                &current,
                &capabilities,
                self.running.contains(&id),
                repair,
            )?;
            selection_response(&mut engine, "agent.select", params)
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
                self.status=match repair {SpeedRepair::Speed=>"Saved speed explicitly cleared to Standard. Other selection fields, message draft and references were retained. No message was sent.",SpeedRepair::Both=>"Saved effort and speed explicitly cleared. Other selection fields, message draft and references were retained. No message was sent."}.into();
                if matches!(repair, SpeedRepair::Both)
                    && self.selected.as_ref().is_some_and(|thread| {
                        exact_astra_model(&SelectionDraft::from_thread(thread))
                    })
                {
                    self.status.push_str(" Model/app default applies only with fresh catalog proof; refresh capabilities before sending.");
                }
            }
            Err(error) => self.status = format!("Saved options were not cleared: {error}"),
        }
        cx.notify();
    }
    fn apply_selection_draft(&mut self, cx: &mut Context<Self>) {
        let result = (|| -> Result<Value> {
            let thread = self
                .selected
                .as_ref()
                .context("Select a conversation first")?;
            let id = text(thread, "id");
            let draft = self
                .selection_ui
                .drafts
                .get(&id)
                .context("Selection draft unavailable")?;
            let mut engine = try_state(&self.engine)?;
            let current = engine.store.thread(&id)?;
            let params = draft.params(&current)?;
            let capabilities = selection_response(
                &mut engine,
                "agent.selection.capabilities",
                json!({"threadId":id}),
            )?;
            if let Some(reason) = capability_lock(&capabilities, self.running.contains(&id))
                && !automatic_default_replacement_target(
                    draft,
                    &current,
                    &capabilities,
                    self.running.contains(&id),
                )
            {
                anyhow::bail!(reason);
            }
            let provider = capabilities["providers"]
                .as_array()
                .and_then(|rows| rows.iter().find(|row| row["provider"] == draft.provider));
            if let Some(reason) = mode_problem(draft, provider) {
                anyhow::bail!(reason);
            }
            if let Some(reason) = effort_problem(draft, &current, provider) {
                anyhow::bail!(reason);
            }
            if let Some(reason) = speed_problem(draft, &current, provider) {
                anyhow::bail!(reason);
            }
            selection_response(&mut engine, "agent.select", params)
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
            Err(error) => {
                self.selection_ui.context = None;
                self.status = format!("Selection was not changed: {error}");
            }
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
        let Some(draft) = self.selection_ui.drafts.get(&text(thread, "id")) else {
            return;
        };
        if capability_lock(
            &self.selection_ui.capabilities,
            self.running.contains(&text(thread, "id")),
        )
        .is_some()
            && !automatic_default_replacement_context(
                draft,
                thread,
                &self.selection_ui.capabilities,
                self.running.contains(&text(thread, "id")),
            )
        {
            return;
        }
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
        let response = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            let id = text(thread, "id");
            let current = engine.store.thread(&id)?;
            draft.params(&current)?;
            let caps = selection_response(
                &mut engine,
                "agent.selection.capabilities",
                json!({"threadId":id}),
            )?;
            if let Some(reason) = capability_lock(&caps, self.running.contains(&id))
                && !automatic_default_replacement_context(
                    draft,
                    &current,
                    &caps,
                    self.running.contains(&id),
                )
            {
                anyhow::bail!(reason);
            }
            selection_response(
                &mut engine,
                "agent.models.refresh",
                json!({"provider":provider,"accountId":draft.account}),
            )
        })();
        match response {
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
                    // Starting a new job revokes the prior private proof. Do not
                    // keep displaying its effective default as currently proved.
                    self.selection_ui.capabilities = Value::Null;
                    self.selection_ui.context = None;
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
        let Some(draft) = self.selection_ui.drafts.get(thread_id) else {
            return;
        };
        if capability_lock(
            &self.selection_ui.capabilities,
            self.running.iter().any(|id| id == thread_id),
        )
        .is_some()
            && !automatic_default_replacement_context(
                draft,
                thread,
                &self.selection_ui.capabilities,
                self.running.iter().any(|id| id == thread_id),
            )
        {
            return;
        }
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
        let replacement_context = automatic_default_replacement_context(
            draft,
            thread,
            &self.selection_ui.capabilities,
            self.running.contains(&text(thread, "id")),
        );
        let model_disabled = disabled && !replacement_context;
        let apply_disabled = disabled
            && !automatic_default_replacement_target(
                draft,
                thread,
                &self.selection_ui.capabilities,
                self.running.contains(&text(thread, "id")),
            );
        let saved = &thread["selection"];
        let model = if saved["modelID"] == "default" {
            "Provider default".to_owned()
        } else {
            text(saved, "modelID")
        };
        let pending = draft.has_edits();
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
                    .disabled(model_disabled)
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
        let draft_effort_problem = effort_problem(draft, thread, provider);
        let proposed_effort_label = if draft.proposed_effort.is_null() {
            effort_default_label(draft, thread, provider)
        } else {
            draft
                .proposed_effort
                .as_str()
                .unwrap_or("Unsupported stored choice (retained)")
                .to_owned()
        };
        let mut effort_panel = div().flex().flex_col().gap_1().child(
            div()
                .text_sm()
                .child(format!("Proposed effort: {proposed_effort_label}")),
        );
        match effort_choices(draft, thread, provider) {
            Ok(choices) => {
                let source_id = text(thread, "id");
                let source_selection = thread["selection"].clone();
                let default_id = source_id.clone();
                let default_selection = source_selection.clone();
                let mut row = div().flex().flex_wrap().gap_2().child(
                    Button::new("selection-effort-default")
                        .label(if exact_astra_model(draft) {
                            "Model/app default effort (clear explicit choice)"
                        } else {
                            "Provider default effort (clear explicit choice)"
                        })
                        .when(draft.proposed_effort.is_null(), |button| button.primary())
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.choose_effort(&default_id, &default_selection, Value::Null, cx)
                        })),
                );
                for choice in choices {
                    let source_id = source_id.clone();
                    let source_selection = source_selection.clone();
                    row = row.child(
                        Button::new(SharedString::from(format!("selection-effort-{choice}")))
                            .label(choice.clone())
                            .when(
                                draft.proposed_effort.as_str() == Some(choice.as_str()),
                                |button| button.primary(),
                            )
                            .disabled(disabled)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.choose_effort(&source_id, &source_selection, json!(choice), cx)
                            })),
                    );
                }
                effort_panel = effort_panel.child(row);
                if let Some(default) =
                    provider.and_then(|p| p["effort"]["reportedDefault"].as_str())
                {
                    effort_panel = effort_panel.child(div().text_xs().child(if exact_astra_model(draft) {
                        format!("Provider-reported default: {default}. Model/app default is shown separately; stored null is retained.")
                    } else {format!("Provider-reported default: {default}. No effort is selected automatically.")}));
                }
            }
            Err(error) => {
                effort_panel = effort_panel.child(div().text_xs().child(error.to_string()))
            }
        }
        if exact_astra_model(draft) {
            effort_panel=effort_panel.child(div().text_xs().child("Clearing explicit effort selects this model's app default. It requires a fresh catalog proof; Send remains unavailable when that default cannot be proved."));
        }
        if self.selection_ui.capabilities["repairClearAvailable"] == true {
            let repair_problem = repair_clear_params(
                draft,
                thread,
                &self.selection_ui.capabilities,
                self.running.contains(&text(thread, "id")),
            )
            .err();
            let source_id = text(thread, "id");
            let source_selection = thread["selection"].clone();
            effort_panel=effort_panel.child(Button::new("selection-effort-repair-clear").label("Clear saved effort only")
                .disabled(repair_problem.is_some()).on_click(cx.listener(move|this,_,_,cx|this.clear_saved_effort(&source_id,&source_selection,cx))))
                .child(div().text_xs().child(repair_problem.map(|e|e.to_string()).unwrap_or_else(||"Clears only the saved effort. Other choices are checked separately. No message is sent.".into())));
        }
        let draft_speed_problem = speed_problem(draft, thread, provider);
        let speed_label = if draft.proposed_speed.is_null() {
            "Standard".to_owned()
        } else {
            draft
                .proposed_speed
                .as_str()
                .unwrap_or("Unsupported stored choice (retained)")
                .to_owned()
        };
        let mut speed_panel = div().flex().flex_col().gap_1().child(
            div()
                .text_sm()
                .child(format!("Proposed speed: {speed_label}")),
        );
        match speed_choices(draft, thread, provider) {
            Ok(choices) => {
                let source_id = text(thread, "id");
                let source_selection = thread["selection"].clone();
                let default_id = source_id.clone();
                let default_selection = source_selection.clone();
                speed_panel = speed_panel.child(
                    Button::new("selection-speed-standard")
                        .label("Standard speed (clear explicit tier)")
                        .when(draft.proposed_speed.is_null(), |button| button.primary())
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.choose_speed(&default_id, &default_selection, Value::Null, cx)
                        })),
                );
                for choice in choices {
                    let id = choice.id.clone();
                    let source_id = source_id.clone();
                    let source_selection = source_selection.clone();
                    speed_panel = speed_panel.child(
                        Button::new(SharedString::from(format!("selection-speed-{id}")))
                            .label(choice.name)
                            .when(
                                draft.proposed_speed.as_str() == Some(id.as_str()),
                                |button| button.primary(),
                            )
                            .disabled(disabled)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.choose_speed(&source_id, &source_selection, json!(id), cx)
                            })),
                    );
                    if let Some(detail) = choice.detail {
                        speed_panel = speed_panel.child(div().text_xs().child(detail));
                    }
                }
                speed_panel = speed_panel.child(div().text_xs().child("These are provider-reported service tiers. Apply changes the selection without sending a message. Standard explicitly clears a retained faster tier when needed."));
            }
            Err(error) => speed_panel = speed_panel.child(div().text_xs().child(error.to_string())),
        }
        for (repair, flag, button_id, label, explanation) in [
            (
                SpeedRepair::Speed,
                "repairSpeedClearAvailable",
                "selection-speed-repair-clear",
                "Clear saved speed only",
                "Clears only saved speed to Standard; effort and other choices are retained. No message is sent.",
            ),
            (
                SpeedRepair::Both,
                "repairOptionsClearAvailable",
                "selection-options-repair-clear",
                "Clear saved effort and speed only",
                "Explicitly clears both saved effort and speed. Other selection fields, draft and references are retained. No message is sent.",
            ),
        ] {
            if self.selection_ui.capabilities[flag] == true {
                let problem = speed_repair_params(
                    draft,
                    thread,
                    &self.selection_ui.capabilities,
                    self.running.contains(&text(thread, "id")),
                    repair,
                )
                .err();
                let source_id = text(thread, "id");
                let source_selection = thread["selection"].clone();
                speed_panel = speed_panel
                    .child(
                        Button::new(button_id)
                            .label(label)
                            .disabled(problem.is_some())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.clear_saved_speed_options(
                                    &source_id,
                                    &source_selection,
                                    repair,
                                    cx,
                                )
                            })),
                    )
                    .child(
                        div().text_xs().child(
                            problem
                                .map(|error| error.to_string())
                                .unwrap_or_else(|| explanation.into()),
                        ),
                    );
            }
        }
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
            .child(effort_panel)
            .child(speed_panel)
            .child(div().flex().flex_wrap().items_center().gap_2()
                .child(Button::new("selection-model-default").label("Provider default").when(!draft.use_custom,|button|button.primary()).disabled(model_disabled || !default_supported)
                    .on_click(cx.listener(|this,_,_,cx|this.edit_selection(|draft|draft.use_custom=false,cx))))
                .child(Button::new("selection-model-custom").label("Custom model ID").when(draft.use_custom,|button|button.primary()).disabled(model_disabled || provider.is_none_or(|p|p["customModel"]["supported"] != true))
                    .on_click(cx.listener(|this,_,_,cx|this.edit_selection(|draft|draft.use_custom=true,cx))))
                .child(div().flex_1().min_w_0().child(Input::new(&self.model_input))))
            .child(div().text_xs().child(if draft.use_custom { "Custom IDs are unverified unless listed in the provider-reported catalog below. Model access and authentication are not verified." } else { "The provider resolves its default model when used. Authentication and availability have not been checked." }))
            .child(div().text_xs().child(format!("Stored effort: {} · speed: {} · access: {} · interaction: {}",draft.original["effort"],draft.original["speed"],draft.access,draft.interaction)))
            .child(div().flex().flex_wrap().gap_2()
                .child(Button::new("selection-apply").label("Apply selection").disabled(apply_disabled || !known_provider || draft_account_problem.is_some() || draft_mode_problem.is_some() || draft_effort_problem.is_some() || draft_speed_problem.is_some())
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
        if let Some(reason) = draft_speed_problem {
            pane = pane.child(div().text_sm().child(reason));
        }
        if replacement_context {
            pane=pane.child(div().text_sm().child("The current model's app default is unproved. Refresh its catalog, or explicitly choose another provider/model and Apply. Modes, effort, speed and Send remain locked; the replacement is validated normally."));
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
                    model_disabled
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
            pane=pane.child(div().text_xs().child("Provider-reported catalog. Authentication and actual model access are not verified. Effort and speed choices require refreshed capabilities for the exact saved model."));
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
                            .disabled(model_disabled)
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
            // The outer composer accessory viewport already supplies a bounded,
            // persistent scrollbar. A second capped viewport hides controls
            // behind an independent scroll position without an accessible thumb.
            .child(div().min_w_0().child(pane))
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
    fn command_thread(command: &str) -> Value {
        json!({"id":"thread","draft":command,"selection":{"provider":"codex","modelID":"explicit-model","accountID":null,"effort":null,"speed":null},"accessMode":"fullAccess","interactionMode":"build"})
    }
    fn command_capabilities(provider: &str, locked: bool) -> Value {
        json!({"provenance":"static_runtime_contract","locked":locked,"lockReason":"synthetic selection lock","providers":[modes(provider,provider=="codex")]})
    }
    fn fake_command(
        command: crate::composer_commands::Command,
        mut stored: Value,
        capabilities: Value,
        fault: &str,
    ) -> (Result<Value>, Value, Vec<String>) {
        let submission =
            crate::composer_commands::Submission::new(&stored, stored["draft"].as_str().unwrap());
        let mut calls = Vec::new();
        let mut reads = 0;
        let result = command_transaction(&submission, command, false, |method, params| {
            calls.push(method.to_owned());
            match method {
                "threads.read" => {
                    reads += 1;
                    if reads == 2 && fault == "late-content" {
                        stored["draftContext"] = json!([{"kind":"quote","text":"new reference"}]);
                    }
                    Ok(stored.clone())
                }
                "agent.selection.capabilities" => Ok(capabilities.clone()),
                "agent.select" => {
                    assert_eq!(params["provider"], stored["selection"]["provider"]);
                    assert_eq!(params["model"], stored["selection"]["modelID"]);
                    for (param, field) in [
                        ("accountId", "accountID"),
                        ("effort", "effort"),
                        ("speed", "speed"),
                    ] {
                        assert_eq!(params[param], stored["selection"][field]);
                    }
                    assert_eq!(params["accessMode"], stored["accessMode"]);
                    if fault == "select" {
                        anyhow::bail!("synthetic selection failure");
                    }
                    stored["interactionMode"] = params["interactionMode"].clone();
                    if fault == "late-draft" {
                        stored["draft"] = json!("newer draft");
                    }
                    Ok(stored.clone())
                }
                "threads.patch" => {
                    assert_eq!(params["patch"], json!({"draft":""}));
                    if fault == "clear" {
                        anyhow::bail!("synthetic persistence failure");
                    }
                    stored["draft"] = json!("");
                    Ok(stored.clone())
                }
                _ => panic!("control command must never send, queue or discover providers"),
            }
        });
        (result, stored, calls)
    }
    #[::core::prelude::v1::test]
    fn standalone_mode_uses_saved_tuple_and_clears_only_after_selector_ack() {
        let original = command_thread("  /plan\n");
        let (result, stored, calls) = fake_command(
            crate::composer_commands::Command::Plan,
            original.clone(),
            command_capabilities("codex", false),
            "",
        );
        assert!(result.is_ok());
        assert_eq!(stored["draft"], "");
        assert_eq!(stored["interactionMode"], "plan");
        assert_eq!(stored["selection"], original["selection"]);
        assert_eq!(stored["accessMode"], "fullAccess");
        assert_eq!(
            calls,
            vec![
                "threads.read",
                "agent.selection.capabilities",
                "agent.select",
                "threads.read",
                "threads.patch"
            ]
        );
    }
    #[::core::prelude::v1::test]
    fn model_command_opens_controls_without_selecting_a_model_or_provider() {
        let original = command_thread("/model");
        let (result, stored, calls) = fake_command(
            crate::composer_commands::Command::Model,
            original.clone(),
            command_capabilities("codex", false),
            "",
        );
        assert!(result.is_ok());
        assert_eq!(stored["selection"], original["selection"]);
        assert_eq!(stored["interactionMode"], "build");
        assert_eq!(stored["draft"], "");
        assert!(!calls.iter().any(|method| method == "agent.select"));
    }
    #[::core::prelude::v1::test]
    fn locks_unsupported_provider_and_default_plan_never_select_clear_send_or_queue() {
        for case in ["locked", "provider", "default"] {
            let mut original = command_thread("/plan");
            let mut caps = command_capabilities("codex", case == "locked");
            if case == "provider" {
                original["selection"]["provider"] = json!("claude");
                caps = command_capabilities("claude", false);
            }
            if case == "default" {
                original["selection"]["modelID"] = json!("default");
            }
            let (result, stored, calls) = fake_command(
                crate::composer_commands::Command::Plan,
                original.clone(),
                caps,
                "",
            );
            assert!(result.is_err());
            assert_eq!(stored, original);
            assert_eq!(calls, vec!["threads.read", "agent.selection.capabilities"]);
        }
        assert!(
            command_params(
                &command_thread("/build"),
                crate::composer_commands::Command::Build,
                &command_capabilities("codex", false),
                true
            )
            .is_err()
        );
    }
    #[::core::prelude::v1::test]
    fn selection_failure_or_clear_failure_retains_exact_command_draft() {
        for fault in ["select", "clear"] {
            let original = command_thread(" \t/plan\n");
            let (result, stored, _) = fake_command(
                crate::composer_commands::Command::Plan,
                original.clone(),
                command_capabilities("codex", false),
                fault,
            );
            assert!(result.is_err());
            assert_eq!(stored["draft"], original["draft"]);
        }
    }
    #[::core::prelude::v1::test]
    fn late_draft_or_reference_change_is_not_cleared_after_selection_ack() {
        for fault in ["late-draft", "late-content"] {
            let original = command_thread("/plan");
            let (result, stored, calls) = fake_command(
                crate::composer_commands::Command::Plan,
                original.clone(),
                command_capabilities("codex", false),
                fault,
            );
            assert!(result.is_err());
            assert!(!calls.iter().any(|method| method == "threads.patch"));
            assert_eq!(
                stored["draft"],
                if fault == "late-draft" {
                    json!("newer draft")
                } else {
                    original["draft"].clone()
                }
            );
        }
    }
    #[::core::prelude::v1::test]
    fn model_opens_picker_without_revalidating_mode_but_keeps_authoritative_locks() {
        let mut original = command_thread("/model");
        original["interactionMode"] = json!("unsupported-current-mode");
        original["accessMode"] = json!("unsupported-current-access");
        let (result, stored, calls) = fake_command(
            crate::composer_commands::Command::Model,
            original.clone(),
            command_capabilities("codex", false),
            "",
        );
        assert!(result.is_ok());
        assert_eq!(stored["interactionMode"], original["interactionMode"]);
        assert_eq!(stored["accessMode"], original["accessMode"]);
        assert!(!calls.iter().any(|method| method == "agent.select"));
        let (result, stored, calls) = fake_command(
            crate::composer_commands::Command::Model,
            original.clone(),
            command_capabilities("codex", true),
            "",
        );
        assert!(result.is_err());
        assert_eq!(stored, original);
        assert_eq!(calls, vec!["threads.read", "agent.selection.capabilities"]);
        assert!(
            command_params(
                &original,
                crate::composer_commands::Command::Model,
                &command_capabilities("codex", false),
                true
            )
            .is_err()
        );
    }
    fn effort_provider() -> Value {
        json!({"provider":"codex","effort":{"supported":true,"choices":["low","high"],"reportedDefault":"low","requiresExplicitModel":true,"provenance":"provider_model_list"}})
    }
    #[::core::prelude::v1::test]
    fn effort_draft_preserves_raw_saved_value_for_mode_changes_and_explicit_clear() {
        let mut thread = command_thread("message draft");
        thread["selection"]["effort"] = json!("high");
        thread["draftContext"] = json!([{"kind":"quote","text":"exact reference"}]);
        thread["rustDraftImages"] = json!([{"id":"image"}]);
        let original = thread.clone();
        let mut draft = SelectionDraft::from_thread(&thread);
        assert_eq!(draft.proposed_effort, "high");
        assert!(!draft.has_edits());
        draft.proposed_interaction = json!("plan");
        let params = draft.params(&thread).unwrap();
        assert_eq!(params["effort"], "high");
        assert_eq!(params["model"], thread["selection"]["modelID"]);
        assert_eq!(params["accessMode"], thread["accessMode"]);
        draft.proposed_effort = Value::Null;
        assert!(draft.has_edits());
        assert!(
            draft
                .params(&thread)
                .unwrap()
                .get("effort")
                .unwrap()
                .is_null()
        );
        assert_eq!(thread, original);
        let mut unknown = thread.clone();
        unknown["selection"]["effort"] = json!({"unrecognized":"retained"});
        assert_eq!(
            SelectionDraft::from_thread(&unknown)
                .params(&unknown)
                .unwrap()["effort"],
            unknown["selection"]["effort"]
        );
    }
    #[::core::prelude::v1::test]
    fn effort_choices_bind_exact_saved_provider_account_model_and_reject_stale_snapshot() {
        let thread = command_thread("draft");
        let draft = SelectionDraft::from_thread(&thread);
        let provider = effort_provider();
        assert_eq!(
            effort_choices(&draft, &thread, Some(&provider)).unwrap(),
            vec!["low", "high"]
        );
        let mut proposed = draft.clone();
        proposed.custom = "different-model".into();
        assert!(effort_choices(&proposed, &thread, Some(&provider)).is_err());
        let mut proposed = draft.clone();
        proposed.account = json!("default");
        assert!(effort_choices(&proposed, &thread, Some(&provider)).is_err());
        let mut proposed = draft.clone();
        proposed.provider = "claude".into();
        assert!(effort_choices(&proposed, &thread, Some(&provider)).is_err());
        let mut changed = thread.clone();
        changed["selection"]["effort"] = json!("high");
        assert!(effort_choices(&draft, &changed, Some(&provider)).is_err());
        assert!(draft.params(&changed).is_err());
        assert!(draft.proposed_effort.is_null());
        let mut default_thread = thread.clone();
        default_thread["selection"]["modelID"] = json!("default");
        assert!(
            effort_choices(
                &SelectionDraft::from_thread(&default_thread),
                &default_thread,
                Some(&provider)
            )
            .is_err()
        );
    }
    #[::core::prelude::v1::test]
    fn unsupported_unknown_or_catalog_only_effort_metadata_never_enables_a_choice() {
        let thread = command_thread("draft");
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.proposed_effort = json!("invented");
        assert!(effort_problem(&draft, &thread, Some(&effort_provider())).is_some());
        for field in [
            "supported",
            "provenance",
            "requiresExplicitModel",
            "choices",
        ] {
            let mut provider = effort_provider();
            provider["effort"].as_object_mut().unwrap().remove(field);
            provider["reportedEfforts"] = json!(["invented"]);
            assert!(effort_choices(&draft, &thread, Some(&provider)).is_err());
        }
        let mut provider = effort_provider();
        provider["effort"]["choices"] = json!(["high", false]);
        assert!(effort_choices(&draft, &thread, Some(&provider)).is_err());
        assert_eq!(draft.proposed_effort, "invented");
    }
    #[::core::prelude::v1::test]
    fn reported_default_is_metadata_not_an_implicit_effort_selection() {
        let thread = command_thread("draft");
        let draft = SelectionDraft::from_thread(&thread);
        let provider = effort_provider();
        assert_eq!(provider["effort"]["reportedDefault"], "low");
        assert!(effort_choices(&draft, &thread, Some(&provider)).is_ok());
        assert!(draft.proposed_effort.is_null());
        assert!(draft.params(&thread).unwrap()["effort"].is_null());
    }
    #[::core::prelude::v1::test]
    fn effort_repair_is_minimal_and_available_only_for_explicit_clear_without_other_edits() {
        let mut thread = command_thread("exact draft");
        thread["selection"]["effort"] = json!("high");
        thread["selection"]["accountID"] = json!("default");
        let original = thread.clone();
        let draft = SelectionDraft::from_thread(&thread);
        let caps = json!({"provenance":"static_runtime_contract","locked":true,"repairClearAvailable":true});
        assert_eq!(
            repair_clear_params(&draft, &thread, &caps, false).unwrap(),
            json!({"threadId":"thread","effort":null})
        );
        assert_eq!(thread, original);
        assert!(repair_clear_params(&draft, &thread, &caps, true).is_err());
        for field in ["repairClearAvailable", "provenance", "locked"] {
            let mut bad = caps.clone();
            bad.as_object_mut().unwrap().remove(field);
            assert!(repair_clear_params(&draft, &thread, &bad, false).is_err());
        }
        let mut changed = draft.clone();
        changed.custom = "another-model".into();
        assert!(repair_clear_params(&changed, &thread, &caps, false).is_err());
        let mut changed = draft.clone();
        changed.proposed_interaction = json!("plan");
        assert!(repair_clear_params(&changed, &thread, &caps, false).is_err());
        let mut changed = draft.clone();
        changed.account = Value::Null;
        assert!(repair_clear_params(&changed, &thread, &caps, false).is_err());
        let mut changed_thread = thread.clone();
        changed_thread["selection"]["effort"] = Value::Null;
        assert!(repair_clear_params(&draft, &changed_thread, &caps, false).is_err());
    }
    fn speed_provider() -> Value {
        json!({"provider":"codex","speed":{"supported":true,"requiresExplicitModel":true,"provenance":"provider_model_list","standard":null,"choices":[{"id":"priority","name":"Fast","detail":"Provider-reported detail"},{"id":"ultrafast","name":"Ultra","detail":null}]}})
    }
    #[::core::prelude::v1::test]
    fn speed_draft_roundtrips_exact_raw_values_and_preserves_effort_on_mode_changes() {
        for raw in [Value::Null, json!("priority"), json!({"future":true})] {
            let mut thread = command_thread("exact café\n");
            thread["selection"]["speed"] = raw.clone();
            thread["selection"]["effort"] = json!("high");
            let mut draft = SelectionDraft::from_thread(&thread);
            assert!(!draft.has_edits());
            draft.proposed_interaction = json!("plan");
            let params = draft.params(&thread).unwrap();
            assert_eq!(params["speed"], raw);
            assert_eq!(params["effort"], "high");
            assert_eq!(thread["draft"], "exact café\n");
            draft.proposed_speed = Value::Null;
            assert_eq!(draft.params(&thread).unwrap()["speed"], Value::Null);
        }
        let thread = command_thread("draft");
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.proposed_speed = json!("priority");
        assert!(draft.has_edits());
        assert_eq!(draft.params(&thread).unwrap()["speed"], "priority");
    }
    #[::core::prelude::v1::test]
    fn speed_choices_require_exact_saved_scope_and_reject_stale_modes_or_selection() {
        let thread = command_thread("draft");
        let draft = SelectionDraft::from_thread(&thread);
        let provider = speed_provider();
        assert_eq!(
            speed_choices(&draft, &thread, Some(&provider)).unwrap()[0].id,
            "priority"
        );
        let caps = json!({"provenance":"static_runtime_contract","locked":false,"providers":[provider.clone()]});
        assert!(
            validate_speed_choice(
                &draft,
                &thread,
                &caps,
                false,
                "thread",
                &thread["selection"],
                &json!("priority")
            )
            .is_ok()
        );
        assert!(
            validate_speed_choice(
                &draft,
                &thread,
                &caps,
                false,
                "old-thread",
                &thread["selection"],
                &json!("priority")
            )
            .is_err()
        );
        assert!(
            validate_speed_choice(
                &draft,
                &thread,
                &caps,
                false,
                "thread",
                &json!({}),
                &json!("priority")
            )
            .is_err()
        );
        assert!(
            validate_speed_choice(
                &draft,
                &thread,
                &caps,
                true,
                "thread",
                &thread["selection"],
                &json!("priority")
            )
            .is_err()
        );
        assert!(
            validate_speed_choice(
                &draft,
                &thread,
                &caps,
                false,
                "thread",
                &thread["selection"],
                &json!("invented")
            )
            .is_err()
        );
        for field in ["provider", "account", "model"] {
            let mut changed = draft.clone();
            match field {
                "provider" => changed.provider = "claude".into(),
                "account" => changed.account = json!("default"),
                _ => changed.custom = "other".into(),
            };
            assert!(speed_choices(&changed, &thread, Some(&provider)).is_err());
        }
        for field in ["accessMode", "interactionMode"] {
            let mut changed = thread.clone();
            changed[field] = json!("changed");
            assert!(speed_choices(&draft, &changed, Some(&provider)).is_err());
        }
        let mut stale = thread.clone();
        stale["selection"]["speed"] = json!("priority");
        assert!(speed_choices(&draft, &stale, Some(&provider)).is_err());
        assert!(draft.params(&stale).is_err());
        let mut default = thread.clone();
        default["selection"]["modelID"] = json!("default");
        assert!(
            speed_choices(
                &SelectionDraft::from_thread(&default),
                &default,
                Some(&provider)
            )
            .is_err()
        );
    }
    #[::core::prelude::v1::test]
    fn raw_reported_speeds_or_malformed_capabilities_never_enable_speed_choices() {
        let thread = command_thread("draft");
        let draft = SelectionDraft::from_thread(&thread);
        for field in [
            "supported",
            "provenance",
            "requiresExplicitModel",
            "standard",
            "choices",
        ] {
            let mut provider = speed_provider();
            provider["speed"].as_object_mut().unwrap().remove(field);
            provider["reportedSpeeds"] = json!([{"id":"invented"}]);
            assert!(speed_choices(&draft, &thread, Some(&provider)).is_err());
        }
        for choices in [
            json!([{"id":"default","name":"Standard"}]),
            json!([{"id":"priority","name":false}]),
            json!([{"id":"priority","name":"Fast","detail":false}]),
            json!([{"id":" priority ","name":"Fast"}]),
        ] {
            let mut provider = speed_provider();
            provider["speed"]["choices"] = choices;
            assert!(speed_choices(&draft, &thread, Some(&provider)).is_err());
        }
        let mut provider = speed_provider();
        provider["provider"] = json!("claude");
        assert!(speed_choices(&draft, &thread, Some(&provider)).is_err());
    }
    #[::core::prelude::v1::test]
    fn speed_problem_accepts_only_reported_tiers_or_explicit_standard_without_automatic_choice() {
        let thread = command_thread("draft");
        let mut draft = SelectionDraft::from_thread(&thread);
        let provider = speed_provider();
        assert!(speed_choices(&draft, &thread, Some(&provider)).is_ok());
        assert!(draft.proposed_speed.is_null());
        draft.proposed_speed = json!("priority");
        assert!(speed_problem(&draft, &thread, Some(&provider)).is_none());
        for raw in [json!("default"), json!("fast"), json!(false)] {
            draft.proposed_speed = raw;
            assert!(speed_problem(&draft, &thread, Some(&provider)).is_some());
        }
        draft.proposed_speed = Value::Null;
        assert!(speed_problem(&draft, &thread, None).is_none());
    }
    #[::core::prelude::v1::test]
    fn speed_only_repair_is_minimal_locked_safe_and_does_not_discard_pending_effort() {
        let mut thread = command_thread("draft");
        thread["selection"]["speed"] = json!("priority");
        let original = thread.clone();
        let draft = SelectionDraft::from_thread(&thread);
        let caps = json!({"provenance":"static_runtime_contract","locked":true,"repairSpeedClearAvailable":true});
        assert_eq!(
            speed_repair_params(&draft, &thread, &caps, false, SpeedRepair::Speed).unwrap(),
            json!({"threadId":"thread","speed":null})
        );
        assert_eq!(thread, original);
        assert!(speed_repair_params(&draft, &thread, &caps, true, SpeedRepair::Speed).is_err());
        for field in ["provenance", "locked", "repairSpeedClearAvailable"] {
            let mut bad = caps.clone();
            bad.as_object_mut().unwrap().remove(field);
            assert!(speed_repair_params(&draft, &thread, &bad, false, SpeedRepair::Speed).is_err());
        }
        let mut pending = draft.clone();
        pending.proposed_effort = json!("high");
        assert!(speed_repair_params(&pending, &thread, &caps, false, SpeedRepair::Speed).is_err());
        let mut pending = draft.clone();
        pending.proposed_interaction = json!("plan");
        assert!(speed_repair_params(&pending, &thread, &caps, false, SpeedRepair::Speed).is_err());
    }
    #[::core::prelude::v1::test]
    fn combined_repair_requires_its_own_flag_and_both_saved_options_and_preserves_other_drafts() {
        let mut thread = command_thread("exact draft");
        thread["selection"]["speed"] = json!("priority");
        thread["selection"]["effort"] = json!("high");
        thread["draftContext"] = json!([{"future":true}]);
        thread["rustDraftImages"] = json!([{"future":true}]);
        let original = thread.clone();
        let draft = SelectionDraft::from_thread(&thread);
        let caps = json!({"provenance":"static_runtime_contract","locked":true,"repairOptionsClearAvailable":true});
        assert_eq!(
            speed_repair_params(&draft, &thread, &caps, false, SpeedRepair::Both).unwrap(),
            json!({"threadId":"thread","effort":null,"speed":null})
        );
        assert_eq!(thread, original);
        assert!(speed_repair_params(&draft, &thread, &caps, false, SpeedRepair::Speed).is_err());
        assert!(repair_clear_params(&draft, &thread, &caps, false).is_err());
        let mut pending = draft.clone();
        pending.custom = "different".into();
        assert!(speed_repair_params(&pending, &thread, &caps, false, SpeedRepair::Both).is_err());
        let mut pending = draft.clone();
        pending.proposed_access = json!("approval");
        assert!(speed_repair_params(&pending, &thread, &caps, false, SpeedRepair::Both).is_err());
        let mut missing = thread.clone();
        missing["selection"]["effort"] = Value::Null;
        assert!(
            speed_repair_params(
                &SelectionDraft::from_thread(&missing),
                &missing,
                &caps,
                false,
                SpeedRepair::Both
            )
            .is_err()
        );
        let effort_caps = json!({"provenance":"static_runtime_contract","locked":true,"repairClearAvailable":true});
        let mut pending = draft.clone();
        pending.proposed_speed = Value::Null;
        assert!(repair_clear_params(&pending, &thread, &effort_caps, false).is_err());
    }
    fn astra_thread() -> Value {
        let mut thread = command_thread("exact draft");
        thread["selection"]["modelID"] = json!("gpt-6-astra");
        thread
    }
    fn astra_provider() -> Value {
        json!({"provider":"codex","effort":{"supported":true,"requiresExplicitModel":true,"provenance":"provider_model_list","choices":["low","medium","high"],"reportedDefault":"low","effectiveDefault":"medium","effectiveDefaultProvenance":"app_policy+provider_model_list","appDefaultRequired":true,"appDefaultAvailable":true}})
    }
    fn replacement_caps() -> Value {
        json!({"provenance":"static_runtime_contract","locked":true,"canReplaceUnprovedAutomaticDefault":true,"providers":[modes("codex",true),modes("claude",false)]})
    }
    #[::core::prelude::v1::test]
    fn astra_default_label_needs_exact_current_proof_and_keeps_reported_default_separate() {
        let thread = astra_thread();
        let draft = SelectionDraft::from_thread(&thread);
        let provider = astra_provider();
        assert_eq!(
            effort_default_label(&draft, &thread, Some(&provider)),
            "Model/app default: Medium"
        );
        assert_eq!(provider["effort"]["reportedDefault"], "low");
        assert!(draft.proposed_effort.is_null());
        assert!(draft.params(&thread).unwrap()["effort"].is_null());
        for field in [
            "effectiveDefault",
            "effectiveDefaultProvenance",
            "appDefaultRequired",
            "appDefaultAvailable",
            "supported",
            "provenance",
        ] {
            let mut bad = provider.clone();
            bad["effort"].as_object_mut().unwrap().remove(field);
            let label = effort_default_label(&draft, &thread, Some(&bad));
            assert!(label.contains("refresh catalog required"));
            assert!(!label.contains("Medium"));
            assert!(!label.contains("Provider default"));
        }
        let mut bad = provider.clone();
        bad["effort"]["choices"] = json!(["low", "high"]);
        assert!(
            effort_default_label(&draft, &thread, Some(&bad)).contains("refresh catalog required")
        );
        let mut stale = thread.clone();
        stale["selection"]["speed"] = json!("priority");
        assert!(
            effort_default_label(&draft, &stale, Some(&provider))
                .contains("refresh catalog required")
        );
    }
    #[::core::prelude::v1::test]
    fn non_astra_and_explicit_effort_keep_existing_semantics_and_raw_values() {
        let thread = command_thread("draft");
        let draft = SelectionDraft::from_thread(&thread);
        assert_eq!(
            effort_default_label(&draft, &thread, None),
            "Provider default"
        );
        for id in ["gpt-6-astra-v2", "GPT-6-Astra", "default", "gpt-6-sol"] {
            let mut thread = thread.clone();
            thread["selection"]["modelID"] = json!(id);
            let draft = SelectionDraft::from_thread(&thread);
            assert_eq!(
                effort_default_label(&draft, &thread, Some(&astra_provider())),
                "Provider default"
            );
        }
        let mut thread = astra_thread();
        thread["selection"]["modelID"] = json!("openai.gpt-6-astra");
        thread["selection"]["effort"] = json!("high");
        let draft = SelectionDraft::from_thread(&thread);
        assert!(exact_astra_model(&draft));
        assert_eq!(draft.params(&thread).unwrap()["effort"], "high");
        assert_eq!(draft.proposed_effort, "high");
    }
    #[::core::prelude::v1::test]
    fn automatic_default_exit_requires_explicit_provider_or_model_change_only() {
        let thread = astra_thread();
        let original = thread.clone();
        let draft = SelectionDraft::from_thread(&thread);
        let caps = replacement_caps();
        assert!(automatic_default_replacement_context(
            &draft, &thread, &caps, false
        ));
        assert!(!automatic_default_replacement_target(
            &draft, &thread, &caps, false
        ));
        let mut provider = draft.clone();
        provider.provider = "claude".into();
        assert!(automatic_default_replacement_target(
            &provider, &thread, &caps, false
        ));
        let mut model = draft.clone();
        model.custom = "another-explicit-model".into();
        assert!(automatic_default_replacement_target(
            &model, &thread, &caps, false
        ));
        let params = model.params(&thread).unwrap();
        assert_eq!(params["model"], "another-explicit-model");
        assert!(params["effort"].is_null());
        assert!(params["speed"].is_null());
        assert_eq!(params["interactionMode"], "build");
        assert_eq!(thread, original);
        let mut same = draft.clone();
        same.custom = " gpt-6-astra ".into();
        assert!(!automatic_default_replacement_target(
            &same, &thread, &caps, false
        ));
        for kind in ["effort", "speed", "account", "access", "interaction"] {
            let mut bad = model.clone();
            match kind {
                "effort" => bad.proposed_effort = json!("high"),
                "speed" => bad.proposed_speed = json!("priority"),
                "account" => bad.account = json!("default"),
                "access" => bad.proposed_access = json!("approval"),
                _ => bad.proposed_interaction = json!("plan"),
            };
            assert!(
                !automatic_default_replacement_target(&bad, &thread, &caps, false),
                "{kind}"
            );
        }
    }
    #[::core::prelude::v1::test]
    fn automatic_default_exit_flag_never_overrides_running_origin_stale_or_unavailable_caps() {
        let thread = astra_thread();
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.custom = "replacement".into();
        let caps = replacement_caps();
        assert!(!automatic_default_replacement_target(
            &draft, &thread, &caps, true
        ));
        for key in [
            "provenance",
            "locked",
            "providers",
            "canReplaceUnprovedAutomaticDefault",
        ] {
            let mut bad = caps.clone();
            bad.as_object_mut().unwrap().remove(key);
            assert!(!automatic_default_replacement_target(
                &draft, &thread, &bad, false
            ));
        }
        for (key, value) in [
            ("botID", json!("bot")),
            ("rustBotContext", json!({})),
            ("accessMode", json!("approval")),
            ("interactionMode", json!("plan")),
        ] {
            let mut bad = thread.clone();
            bad[key] = value;
            assert!(!automatic_default_replacement_target(
                &draft, &bad, &caps, false
            ));
        }
        for (field, value) in [
            ("accountID", json!("named")),
            ("effort", json!("high")),
            ("speed", json!("priority")),
            ("provider", json!("claude")),
            ("modelID", json!("other")),
        ] {
            let mut bad = thread.clone();
            bad["selection"][field] = value;
            assert!(!automatic_default_replacement_target(
                &draft, &bad, &caps, false
            ));
        }
        assert!(capability_lock(&caps, false).is_some()); // Send and ordinary controls retain their lock.
        assert!(
            validate_speed_choice(
                &draft,
                &thread,
                &caps,
                false,
                "thread",
                &thread["selection"],
                &Value::Null
            )
            .is_err()
        );
    }
}
