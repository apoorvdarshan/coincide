//! Capability-aware, explicit selection drafts. Reading this view never starts
//! a provider or discovers/authenticates models. Explicit Apply and acknowledged
//! standalone mode commands use the same validated selection endpoint.
use super::*;
#[path = "composer_native_accounts.rs"]
mod native_accounts;
use std::collections::HashMap;
#[path = "composer_selection_cache.rs"]
mod capability_cache;
#[path = "codex_profile_models.rs"]
mod named_models;
#[cfg(test)]
#[path = "composer_provider_commands_tests.rs"]
mod provider_command_tests;

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
        (draft.provider == "codex"
            && provider["provider"] == "codex"
            && capability["supported"] == true
            && capability["provenance"] == "provider_model_list"
            && capability["requiresExplicitModel"] == true)
            || (draft.provider == "opencode"
                && provider["provider"] == "opencode"
                && capability["supported"] == true
                && capability["provenance"] == "provider_model_list"
                && capability["requiresExplicitModel"] == true
                && capability["choices"].is_array()),
        "{}",
        capability["reason"]
            .as_str()
            .unwrap_or("Refresh the current model catalog to choose effort")
    );
    anyhow::ensure!(
        draft.use_custom && !draft.custom.is_empty() && draft.custom != "default",
        "Choose an explicit model before effort options"
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
    mut params: Value,
) -> Result<Value> {
    if matches!(
        method,
        "agent.select"
            | "providers.codex.profiles.models.select"
            | "providers.codex.profiles.select"
    ) {
        params["rememberComposerChoice"] = json!(true);
    }
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
    if command.provider().is_none() {
        if let Some(reason) = capability_lock(capabilities, running) {
            anyhow::bail!(reason);
        }
    } else {
        anyhow::ensure!(!running, "Stop the current turn before changing provider");
    }
    if let Some(target) = command.provider() {
        anyhow::ensure!(
            thread["selection"]["provider"] != target,
            "This conversation already uses {target}; command draft retained"
        );
        let provider = capabilities["providers"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["provider"] == target))
            .context(
                "This provider is unavailable in the current runtime; command draft retained",
            )?;
        anyhow::ensure!(
            matches!(
                provider["accountPolicy"].as_str(),
                Some("default_only" | "configured_codex_profile")
            ),
            "Automatic switching is unavailable for this account type; draft retained"
        );
        // Engine derives and validates the remembered account/model atomically.
        // The desktop must not replace that preference with its cached catalog.
        return Ok(None);
    }
    // Swift /model and /usage-limits open controls, rather than changing a mode.
    // Preserve the authoritative capability/active/origin locks above; merely
    // showing existing choices must not invent another mode-change gate.
    if matches!(
        command,
        crate::composer_commands::Command::Model | crate::composer_commands::Command::UsageLimits
    ) {
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
fn expected_restore_account(thread: &Value, provider: &str) -> Value {
    if thread["selection"]["provider"] == provider
        && provider == "codex"
        && !coincide_core::composer_selection::default_account(&thread["selection"]["accountID"])
    {
        return thread["selection"]["accountID"].clone();
    }
    let session = thread["sessions"]
        .as_object()
        .and_then(|rows| rows.get(provider))
        .or_else(|| {
            thread["sessions"]
                .as_array()?
                .as_chunks::<2>()
                .0
                .iter()
                .find(|pair| pair[0] == provider)
                .map(|pair| &pair[1])
        });
    session
        .and_then(|session| session.get("accountID"))
        .or_else(|| thread["rustProviderSelections"][provider].get("accountID"))
        .cloned()
        .unwrap_or(Value::Null)
}

fn restore_account_id(value: &Value) -> Option<&str> {
    default_account_id(value)
}
fn restore_receipt_scope(
    response: &Value,
    current: &Value,
    provider: &str,
    explicit: Option<&Value>,
    request: Option<&str>,
) -> Result<Value> {
    let expected = explicit
        .cloned()
        .unwrap_or_else(|| expected_restore_account(current, provider));
    let expected = restore_account_id(&expected).context("Invalid source account identity")?;
    let actual = restore_account_id(&response["accountID"]).unwrap_or("default");
    if let Some(request) = request {
        anyhow::ensure!(
            response["requestId"] == request,
            "Account restoration request was superseded; draft retained"
        );
    }
    if response.get("requestedAccountID").is_some() {
        anyhow::ensure!(
            provider == "codex"
                && restore_account_id(&response["requestedAccountID"]) == Some(expected)
                && response["explicitAccount"] == json!(explicit.is_some())
                && response["fallback"] == json!(actual != expected),
            "Account restoration request scope changed; draft retained"
        );
        if actual != expected {
            anyhow::ensure!(
                explicit.is_none()
                    && (response["candidateAccountIDs"]
                        .as_array()
                        .is_some_and(|accounts| accounts
                            .iter()
                            .any(|account| restore_account_id(account) == Some(actual)))
                        || (actual == "default"
                            && response["fallbackReason"] == "no_authenticated_account_ready")),
                "Account fallback was not part of this provider action; draft retained"
            );
        }
    } else if response["pending"] == true || response["accountRestored"] == true {
        anyhow::ensure!(
            actual == expected,
            "Account acknowledgement belongs to another account; draft retained"
        );
    }
    if response["pending"] == true {
        anyhow::ensure!(
            provider == "codex"
                && response["provider"] == provider
                && response["authenticationChecked"] == false
                && response["requestId"]
                    .as_str()
                    .is_some_and(|id| !id.is_empty()),
            "Invalid pending account observation acknowledgement"
        );
    } else {
        let model = response["model"]
            .as_str()
            .context("Missing restored model acknowledgement")?;
        if response["selectionUnchanged"] == true {
            anyhow::ensure!(
                explicit.is_none()
                    && provider == "codex"
                    && actual == expected
                    && current["selection"]["provider"] == "codex"
                    && restore_account_id(&current["selection"]["accountID"]) == Some(actual)
                    && response["authenticationChecked"] == true
                    && response["executionReady"].is_boolean()
                    && response["restored"] == false
                    && response["accountRestored"] == false
                    && response["provenance"] == "selected_account_catalog"
                    && response["thread"]["selection"] == current["selection"]
                    && response["model"] == current["selection"]["modelID"],
                "Saved account warmup changed its exact selection"
            );
            return Ok(if actual == "default" {
                Value::Null
            } else {
                json!(actual)
            });
        }
        let named = actual != "default";
        let authenticated = response["authenticationChecked"] == true;
        anyhow::ensure!(
            (authenticated
                && provider == "codex"
                && response["restored"] == true
                && model != "default"
                && response["accountRestored"] == json!(named)
                && response["provenance"]
                    == if named {
                        "latest_authenticated_named_catalog"
                    } else {
                        "latest_authenticated_default_catalog"
                    })
                || (!authenticated
                    && !named
                    && response["accountRestored"] == false
                    && ((response["restored"] == true
                        && response["provenance"] == "latest_default_catalog"
                        && model != "default")
                        || (response["restored"] == false
                            && response["provenance"] == "provider_default"
                            && model == "default"))),
            "Provider selection omitted its exact catalog acknowledgement; draft retained"
        );
    }
    Ok(if actual == "default" {
        Value::Null
    } else {
        json!(actual)
    })
}

/// Invoked under one Engine try-lock. Only existing validated selection/draft
/// endpoints and already-reported limits status are used, never Send/queue or
/// provider refresh. Every rejection remains intercepted.
fn command_transaction(
    submission: &crate::composer_commands::Submission,
    command: crate::composer_commands::Command,
    running: bool,
    reported: Option<&crate::codex_limits_view::Observation>,
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
    if command == crate::composer_commands::Command::UsageLimits {
        anyhow::ensure!(
            current["selection"]["provider"] == "codex"
                && default_account_id(&current["selection"]["accountID"]) == Some("default"),
            "Only already-reported default Codex runtime limits are connected here; named-profile and other-agent limits are unavailable"
        );
        let reported = reported.context("No reported limit windows are available. Open Usage and limits and explicitly Refresh Codex limits first")?;
        anyhow::ensure!(
            crate::codex_limits_mount::has_reported_windows(reported),
            "No reported limit windows are available"
        );
        // Status revalidates the exact existing observation and executable
        // context. It does not refresh, start a provider or read credentials.
        let value = invoke(
            "usage.codexLimits.status",
            json!({"requestId":reported.request_id}),
        )?;
        let fresh = crate::codex_limits_view::decode(&value).map_err(|_| {
            anyhow::anyhow!(
                "Reported limits are unavailable or their context changed; command draft retained"
            )
        })?;
        anyhow::ensure!(
            fresh.request_id == reported.request_id
                && fresh.generation == reported.generation
                && crate::codex_limits_mount::has_reported_windows(&fresh),
            "Reported limit windows are no longer current; command draft retained"
        );
    }
    let mut acknowledged_model = None;
    let mut acknowledged_account = Value::Null;
    let ack = if let Some(provider) = command.provider() {
        let mut params = json!({"threadId":id,"provider":provider,"expected":submission.thread});
        if let Some(request) = &submission.restore_request {
            params["restoreRequestId"] = json!(request);
        }
        let response = invoke("agent.provider.select", params)?;
        acknowledged_account = restore_receipt_scope(
            &response,
            &current,
            provider,
            None,
            submission.restore_request.as_deref(),
        )?;
        if response["pending"] == true {
            return Ok(response);
        }
        let model = response["model"]
            .as_str()
            .context("Provider omitted its model acknowledgement")?;
        acknowledged_model = Some(model.to_owned());
        response["thread"].clone()
    } else if let Some(params) = params {
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
    if let Some(provider) = command.provider() {
        anyhow::ensure!(
            ack["selection"]["provider"] == provider
                && ack["selection"]["modelID"].as_str() == acknowledged_model.as_deref()
                && (if acknowledged_account.is_null() {
                    default_account_id(&ack["selection"]["accountID"]) == Some("default")
                } else {
                    ack["selection"]["accountID"] == acknowledged_account
                })
                && ack["accessMode"] == submission.thread["accessMode"]
                && ack["interactionMode"] == submission.thread["interactionMode"],
            "Selection did not acknowledge the requested provider/model and preserved modes; draft retained"
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
    if submission.keep_draft {
        return Ok(before_clear);
    }
    // No UI callback/await or other controller can interleave the Engine lock.
    // This clears only text, never consumes images or references.
    let cleared = invoke("threads.patch", json!({"threadId":id,"patch":{"draft":""}}))
        .map_err(|error| anyhow::anyhow!("{}: {error}", if command.changes_selection() {
            "Selection was saved, but command draft clearing failed; draft retained"
        } else if command == crate::composer_commands::Command::UsageLimits { "Reported limits were validated, but command draft clearing failed; draft retained" } else { "Model controls were validated, but command draft clearing failed; draft retained" }))?;
    anyhow::ensure!(
        cleared["id"] == *id && cleared["draft"] == "",
        "Draft clear was not acknowledged; local draft retained"
    );
    Ok(cleared)
}
fn engine_command_transaction(
    engine: &mut coincide_core::api::Engine,
    submission: &crate::composer_commands::Submission,
    command: crate::composer_commands::Command,
    running: bool,
    reported: Option<&crate::codex_limits_view::Observation>,
) -> Result<Value> {
    let id = text(&submission.thread, "id");
    anyhow::ensure!(
        !engine.admissions_frozen(),
        "App is closing; command draft retained"
    );
    anyhow::ensure!(
        engine.active_thread() == Some(id.as_str()),
        "Active conversation changed; command draft retained"
    );
    command_transaction(
        submission,
        command,
        running,
        reported,
        |method, mut params| {
            if method == "agent.select" {
                params["rememberComposerChoice"] = json!(true);
            }
            let response = engine.dispatch(json!({"method":method,"params":params}));
            if let Some(error) = response.get("error") {
                anyhow::bail!("{}", error["message"].as_str().unwrap_or("Command failed"));
            }
            Ok(response["result"].clone())
        },
    )
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum PickerFacet {
    #[default]
    Model,
    Effort,
    Speed,
    Access,
    Mode,
}
#[derive(Default)]
pub(super) struct ComposerSelection {
    drafts: HashMap<String, SelectionDraft>,
    goal_yield_attempts: std::collections::HashSet<String>,
    bound: Option<String>,
    context: Option<(String, Value, bool)>,
    capability_cache: capability_cache::CapabilityCache,
    capabilities: Value,
    accounts: Value,
    codex_accounts: Value,
    native_accounts: Vec<coincide_core::provider_configuration::NativeProviderAccount>,
    native_revision: u64,
    pending_native_account: Option<native_accounts::PendingChoice>,
    error: String,
    pub(super) catalog: Value,
    catalog_request: Option<CatalogRequest>,
    catalog_last_poll: Option<Instant>,
    /// Disk cache is display-only; each app session still needs a live read.
    catalog_attempted: std::collections::HashSet<(String, String)>,
    capability_pending: bool,
    pending_provider: Option<(
        crate::composer_commands::Command,
        crate::composer_commands::Submission,
    )>,
    pending_provider_picker: Option<PickerRestore>,
    automatic_profile_context: Option<Value>,
    automatic_profile_quiet: Option<(Value, Instant)>,
    pub(super) expanded: bool,
    pub(super) facet: PickerFacet,
    favorites_only: bool,
    /// The agent tab the picker lists; nil while searching across every agent.
    tab_provider: Option<String>,
    /// Where the footer chip was clicked, in window coordinates.
    popover_anchor: Option<Point<Pixels>>,
}
#[derive(Clone)]
struct PickerRestore {
    provider: String,
    account: Option<Value>,
    observation_only: bool,
    source: crate::composer_commands::Submission,
    ui_draft: String,
}
impl ComposerSelection {
    pub(super) fn close_capability_reads(&mut self) {
        self.capability_cache.request_shutdown();
    }
    pub(super) fn capability_read_shutdown_status(
        &mut self,
    ) -> crate::worker_owner::ShutdownStatus {
        self.capability_cache.shutdown_status()
    }
}
#[derive(Clone, Debug)]
struct CatalogRequest {
    request_id: String,
    provider: String,
    account_id: String,
    thread_id: Option<String>,
}
fn default_account_id(raw: &Value) -> Option<&str> {
    match raw {
        Value::Null => Some("default"),
        Value::String(id) if id.is_empty() || id == "default" => Some("default"),
        Value::String(id) => Some(id),
        _ => None,
    }
}
/// Account IDs are provider-scoped. Browsing another provider must not query
/// it with the active provider's account, and returning to the original tab
/// should restore that provider's original account.
fn picker_account(draft: &SelectionDraft, provider: &str) -> Value {
    if provider == draft.provider {
        draft.account.clone()
    } else if draft.original["provider"] == provider {
        draft.original["accountID"].clone()
    } else {
        Value::Null
    }
}
fn catalog_response_matches(value: &Value, request: &CatalogRequest) -> bool {
    value["requestId"].as_str() == Some(request.request_id.as_str())
        && value["provider"].as_str() == Some(request.provider.as_str())
        && value["accountID"].as_str() == Some(request.account_id.as_str())
        && request
            .thread_id
            .as_ref()
            .is_none_or(|id| value["threadId"] == *id)
        && (request.thread_id.is_some() || value["threadId"].is_null())
        && matches!(
            value["state"].as_str(),
            Some("loading" | "ready" | "failed" | "unsupported")
        )
}
/// A selection change made while a turn runs is kept for the next one.
pub(super) const STAGED_SELECTION: &str = "Selection staged for the next turn";

fn capability_lock(capabilities: &Value, running: bool) -> Option<String> {
    // Swift leaves the composer's controls enabled during a turn: a change made
    // now belongs to the next one, and a provider that cannot take it says so.
    if running
        && capabilities["provenance"] == "static_runtime_contract"
        && capabilities["providers"].is_array()
        && capabilities["locked"] == true
        && capabilities["lockReason"] == "Stop the current turn before changing provider"
    {
        // The editor can stage a change for the next turn. Core still owns the
        // running selection and validates the staged change before applying it.
        return None;
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
#[cfg(test)]
fn current_submission_blocked(
    context: Option<&(String, Value, bool)>,
    capabilities: &Value,
    thread: &Value,
    running: bool,
) -> bool {
    // Running conversations use the separate queue/steering admission paths.
    // Only a matching trusted response controls this presentation; the Engine
    // still validates every actual submission against its current private proof.
    !running
        && context.is_some_and(|(id, saved, was_running)| {
            !was_running
                && thread["id"].as_str() == Some(id.as_str())
                && *saved
                    == json!({"selection":thread["selection"],"accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"]})
        })
        && capabilities["provenance"] == "static_runtime_contract"
        && capabilities["locked"] == true
}
fn refreshed_selection_view(previous: &Value, current: &Value) -> Result<Value> {
    anyhow::ensure!(
        previous["id"].as_str().is_some() && previous["id"] == current["id"],
        "Selection reload returned another conversation; local draft retained"
    );
    let mut refreshed = previous.clone();
    // A selection reload must not replace the independently edited composer,
    // attachment/context state or the already loaded transcript window.
    for key in ["selection", "accessMode", "interactionMode"] {
        refreshed[key] = current[key].clone();
    }
    Ok(refreshed)
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

fn picker_view_scope(thread: &Value) -> Value {
    json!({"id":thread["id"],"selection":thread["selection"],
        "accessMode":thread.get("accessMode"),"accessPresent":thread.get("accessMode").is_some(),
        "interactionMode":thread.get("interactionMode"),"interactionPresent":thread.get("interactionMode").is_some(),
        "projectID":thread["projectID"],"worktreePath":thread["worktreePath"]})
}
fn model_marked(settings: &Value, key: &str, provider: &str, model: &str) -> bool {
    settings[key].as_array().is_some_and(|rows| {
        rows.iter()
            .any(|row| row["provider"] == provider && row["modelID"] == model)
    })
}
fn compact_context(tokens: u64) -> String {
    if tokens >= 1_000_000 {
        let millions = tokens as f64 / 1_000_000.;
        if (millions - millions.round()).abs() < 0.05 {
            format!("{}M", millions.round() as u64)
        } else {
            format!("{millions:.1}M")
        }
    } else if tokens >= 1_000 {
        format!("{}K", (tokens as f64 / 1_000.).round() as u64)
    } else {
        tokens.to_string()
    }
}
fn filtered_picker_models<'a>(
    settings: &Value,
    catalog: &'a Value,
    provider: &str,
    selected: &str,
    query: &str,
    favorites_only: bool,
) -> Vec<&'a Value> {
    let query = query.to_lowercase();
    let words = query.split_whitespace().collect::<Vec<_>>();
    let mut rows = catalog["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|row| {
            let id = row["id"].as_str().unwrap_or_default();
            if id.is_empty()
                || (model_marked(settings, "hiddenModels", provider, id) && id != selected)
                || (favorites_only && !model_marked(settings, "favoriteModels", provider, id))
            {
                return false;
            }
            let label = format!("{} {}", id, row["displayName"].as_str().unwrap_or_default())
                .to_lowercase();
            words.iter().all(|word| label.contains(word))
        })
        .collect::<Vec<_>>();
    rows.sort_by_key(|row| {
        !model_marked(
            settings,
            "favoriteModels",
            provider,
            row["id"].as_str().unwrap_or_default(),
        )
    });
    rows.truncate(200);
    rows
}
fn reported_picker_model_label(thread: &Value, catalog: &Value) -> Option<String> {
    let selection = &thread["selection"];
    if catalog["state"] != "ready"
        || catalog["provider"] != selection["provider"]
        || restore_account_id(&catalog["accountID"]) != restore_account_id(&selection["accountID"])
        || (!coincide_core::composer_selection::default_account(&selection["accountID"])
            && catalog["threadId"] != thread["id"])
        || (catalog["threadId"].is_string() && catalog["threadId"] != thread["id"])
    {
        return None;
    }
    let row = catalog["models"]
        .as_array()?
        .iter()
        .find(|row| row["id"] == selection["modelID"])?;
    row["displayName"]
        .as_str()
        .filter(|name| !name.is_empty())
        .map(|_| footer_value(&row["displayName"], ""))
}
pub(super) fn effort_picker_title(value: &Value) -> String {
    let raw = footer_value(value, "Auto");
    match raw.as_str() {
        "none" | "off" => "Off".into(),
        "auto" => "Auto".into(),
        "minimal" => "Minimal".into(),
        "low" => "Low".into(),
        "medium" => "Medium".into(),
        "high" => "High".into(),
        "xhigh" | "extra-high" | "extra_high" => "Extra High".into(),
        "max" | "maximum" => "Max".into(),
        _ => {
            let mut chars = raw.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or(raw)
        }
    }
}
struct FooterSummary {
    saved: String,
    annotation: Option<String>,
    accessible: String,
}
// A compact presentation of stored values, not a capability/authentication or
// effective-runtime verdict. Bound imported labels without serializing objects.
fn footer_value(value: &Value, absent: &str) -> String {
    match value {
        Value::Null => absent.into(),
        Value::String(value) if !value.is_empty() => {
            let mut chars = value
                .chars()
                .map(|ch| if ch.is_control() { ' ' } else { ch });
            let mut label = chars.by_ref().take(512).collect::<String>();
            if chars.next().is_some() {
                label.push('…');
            }
            label
        }
        Value::String(_) => "Unsupported empty value".into(),
        Value::Bool(_) => "Unsupported boolean value".into(),
        Value::Number(_) => "Unsupported numeric value".into(),
        Value::Array(_) => "Unsupported array value".into(),
        Value::Object(_) => "Unsupported object value".into(),
    }
}
fn footer_summary(
    thread: &Value,
    pending: bool,
    conflict: bool,
    expanded: bool,
    lock: Option<&str>,
) -> FooterSummary {
    let saved = &thread["selection"];
    let provider = footer_value(&saved["provider"], "Unknown provider");
    let model = if saved["modelID"] == "default" {
        "Provider default".into()
    } else {
        footer_value(&saved["modelID"], "Model not stored")
    };
    let account = match default_account_id(&saved["accountID"]) {
        Some("default") => "Default account".into(),
        _ => format!(
            "Account {}",
            footer_value(&saved["accountID"], "Default account")
        ),
    };
    let access = match thread["accessMode"].as_str() {
        Some("approval") | None
            if thread["accessMode"].is_null() || thread["accessMode"] == "approval" =>
        {
            "Approval".into()
        }
        Some("fullAccess") => "Full access".into(),
        _ => format!("Access {}", footer_value(&thread["accessMode"], "Approval")),
    };
    let interaction = match thread["interactionMode"].as_str() {
        Some("build") | None
            if thread["interactionMode"].is_null() || thread["interactionMode"] == "build" =>
        {
            "Build".into()
        }
        Some("plan") => "Plan".into(),
        _ => format!(
            "Interaction {}",
            footer_value(&thread["interactionMode"], "Build")
        ),
    };
    let saved = format!(
        "{} · {model} · Effort {} · Speed {} · {access} · {interaction} · {account}",
        presentation::provider_name(&provider),
        footer_value(&saved["effort"], "automatic"),
        footer_value(&saved["speed"], "default")
    );
    let mut annotation = match (pending, conflict) {
        (true, true) => Some("Edits pending · saved selection changed".into()),
        (true, false) => Some("Edits pending".into()),
        (false, true) => Some("Saved selection changed".into()),
        (false, false) => None,
    };
    // Swift dims the chips while a turn runs; it does not add a visible
    // "Locked: …" sentence under the composer. Keep the reason in the
    // accessibility label only.
    let lock_reason = lock.map(|lock| {
        format!(
            "Locked: {}",
            footer_value(&json!(lock), "Selection is locked")
        )
    });
    let action = if expanded {
        "Hide selection options"
    } else {
        "Edit selection options"
    };
    let mut accessible = format!("{action}. Saved: {saved}.");
    if let Some(annotation) = &annotation {
        accessible.push_str(&format!(" {annotation}."));
    }
    if let Some(lock) = &lock_reason {
        accessible.push_str(&format!(" {lock}."));
    }
    if pending {
        accessible.push_str(" Pending edits are not applied.");
    }
    FooterSummary {
        saved,
        annotation,
        accessible,
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
        Some("selected_native_account") if id=="default" || provider["selectedNativeAccountID"]==id=>None,
        Some("selected_native_account")=>Some("Choose this account from the native account list; imported account IDs cannot grant access.".into()),
        Some("default_only") if id != "default" => Some("This provider supports only the default account. Choose Use default account to replace the retained account ID.".into()),
        Some("default_only") => None,
        Some("configured_antigravity") if !configured.is_object() => Some("Configured account metadata is unavailable. Refresh capabilities or open Antigravity accounts.".into()),
        Some("configured_antigravity") if configured.get(id).is_none() => Some(format!("Account '{id}' is not configured. Choose a configured account or open Antigravity accounts.")),
        Some("configured_antigravity") => None,
        _ => Some("Account support is not described by current capabilities.".into()),
    }
}
/// Whether a capability read may prefetch the saved provider's catalog so the
/// composer's chip can show display names. This must never run while the picker
/// is open: replacing the catalog there swaps the agent tab being browsed back
/// to the thread's saved provider, so an OpenCode model could not be chosen on
/// a Codex thread.
fn prefetches_saved_catalog(
    picker_open: bool,
    request_pending: bool,
    catalog_provider: Option<&str>,
    saved_provider: &str,
    discovery_supported: bool,
    attempted_in_session: bool,
) -> bool {
    !picker_open
        && !request_pending
        && (!attempted_in_session || catalog_provider != Some(saved_provider))
        && discovery_supported
}

#[derive(Debug, PartialEq, Eq)]
enum SendCatalogAction {
    Proceed,
    Wait,
    Refresh,
    Unavailable,
}
fn observed_discovery(capabilities: &Value, supported: Option<bool>) -> Option<bool> {
    supported.or_else(|| (!capabilities.is_null()).then_some(false))
}
fn named_catalog_needs_observation(named: &Value, pending: bool, observed: bool) -> bool {
    named["nativeApiKey"] != true
        && named["nativeAccount"] != true
        && named["refreshAllowed"] == true
        && named["accountCatalogReady"] != true
        && (pending || !observed)
}
fn send_catalog_action(
    selection: &Value,
    running: bool,
    attempted: bool,
    pending: bool,
    discovery: Option<bool>,
) -> SendCatalogAction {
    let astra_default = selection["effort"].is_null()
        && matches!(
            selection["modelID"].as_str(),
            Some("gpt-6-astra" | "openai.gpt-6-astra")
        );
    if running
        || selection["provider"] != "codex"
        || (selection["effort"].is_null() && selection["speed"].is_null() && !astra_default)
    {
        return SendCatalogAction::Proceed;
    }
    if pending {
        return SendCatalogAction::Wait;
    }
    if attempted {
        return SendCatalogAction::Proceed;
    }
    match discovery {
        None => SendCatalogAction::Wait,
        Some(true) => SendCatalogAction::Refresh,
        Some(false) => SendCatalogAction::Unavailable,
    }
}
/// Swift's collapse priority: mode, follow-up, access, speed, effort, model.
fn footer_compaction(widths: [f32; 6], available: f32) -> [bool; 6] {
    let mut result = [false; 6];
    let mut total = widths.iter().sum::<f32>()
        + widths.iter().filter(|w| **w > 0.).count().saturating_sub(1) as f32 * 2.;
    for i in [5, 4, 3, 2, 1, 0] {
        if total <= available {
            break;
        }
        if widths[i] > 28. {
            total -= widths[i] - 28.;
            result[i] = true;
        }
    }
    result
}

impl Coincide {
    pub(super) fn selection_change_pending(&self) -> bool {
        self.selection_ui.pending_native_account.is_some()
            || self.selection_ui.pending_provider.is_some()
            || self
                .selection_ui
                .pending_provider_picker
                .as_ref()
                .is_some_and(|pending| !pending.observation_only)
    }
    /// An idle Codex turn with an explicit saved option needs one live model
    /// read after launch. A click made during that read is kept and retried
    /// after it completes, instead of failing against a display-only cache.
    pub(super) fn wait_for_send_catalog(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(thread) = self.selected.as_ref() else {
            return false;
        };
        let selection = &thread["selection"];
        let id = text(thread, "id");
        if self.running.contains(&id) || selection["provider"] != "codex" {
            return false;
        }
        if self.selection_ui.capability_pending {
            return true;
        }
        if named_models::named_thread(thread) {
            let named = &self.selection_ui.capabilities["namedModels"];
            if named.is_null() {
                // Wait only while capabilities have not arrived. A completed
                // response without named metadata cannot become ready by
                // waiting forever; let normal admission report the failure.
                return self.selection_ui.capabilities.is_null();
            }
            if named_catalog_needs_observation(
                named,
                self.selection_ui.pending_provider_picker.is_some(),
                self.selection_ui.automatic_profile_context.is_some(),
            ) {
                self.observe_saved_profile_once(cx);
                return true;
            }
            return false;
        }
        let key = ("codex".to_owned(), "default".to_owned());
        let provider = self.selection_ui.capabilities["providers"]
            .as_array()
            .and_then(|providers| providers.iter().find(|row| row["provider"] == "codex"));
        if provider.is_some_and(|provider| {
            account_problem(
                provider,
                &selection["accountID"],
                &self.selection_ui.accounts,
            )
            .is_some()
        }) {
            return false;
        }
        let discovery = observed_discovery(
            &self.selection_ui.capabilities,
            provider.and_then(|provider| provider["modelDiscovery"]["supported"].as_bool()),
        );
        match send_catalog_action(
            selection,
            false,
            self.selection_ui.catalog_attempted.contains(&key),
            self.selection_ui.catalog_request.is_some(),
            discovery,
        ) {
            SendCatalogAction::Proceed => return false,
            SendCatalogAction::Wait => return true,
            SendCatalogAction::Unavailable => {
                self.selection_ui.catalog_attempted.insert(key);
                return false;
            }
            SendCatalogAction::Refresh => {}
        }
        self.refresh_model_catalog(Some("codex".into()), cx);
        self.selection_ui.catalog_request.is_some()
            || !self.selection_ui.catalog_attempted.contains(&key)
    }
    fn switch_provider_from_history(
        &mut self,
        provider: String,
        retry: Option<PickerRestore>,
        cx: &mut Context<Self>,
    ) {
        let account = retry.as_ref().and_then(|pending| pending.account.clone());
        self.switch_provider_account(provider, account, retry, cx);
    }
    pub(super) fn switch_codex_account_from_picker(
        &mut self,
        account: Value,
        cx: &mut Context<Self>,
    ) {
        self.selection_ui.pending_provider = None;
        self.switch_provider_account("codex".into(), Some(account), None, cx);
    }
    fn switch_provider_account(
        &mut self,
        provider: String,
        account: Option<Value>,
        retry: Option<PickerRestore>,
        cx: &mut Context<Self>,
    ) {
        let retry_on_busy = retry.clone();
        let result = (|| -> Result<(Value, PickerRestore)> {
            let selected = self
                .selected
                .as_ref()
                .context("Select a conversation first")?;
            let id = text(selected, "id");
            anyhow::ensure!(
                !self.running.contains(&id) && !self.attachment_imports.contains(&id),
                "Finish the current turn or attachment import before switching provider"
            );
            let ui_draft = self.committed_composer_draft(cx);
            let mut engine = try_state(&self.engine)?;
            let current = selection_response(
                &mut engine,
                "threads.read",
                json!({"threadId":id,"itemLimit":0}),
            )?;
            let mut pending = if let Some(pending) = retry {
                anyhow::ensure!(
                    pending.source.thread["id"] == selected["id"]
                        && pending.source.same_selection(selected)
                        && (pending.observation_only
                            || (pending.ui_draft == ui_draft
                                && pending.source.same_content(&current, &pending.source.draft))),
                    "Composer changed; provider restoration cancelled"
                );
                pending
            } else {
                anyhow::ensure!(
                    selected["selection"] == current["selection"]
                        && selected["accessMode"] == current["accessMode"]
                        && selected["interactionMode"] == current["interactionMode"],
                    "Saved selection changed; reload before switching provider"
                );
                PickerRestore {
                    provider: provider.clone(),
                    account: account.clone(),
                    observation_only: account.is_none()
                        && provider == "codex"
                        && current["selection"]["provider"] == "codex"
                        && !coincide_core::composer_selection::default_account(
                            &current["selection"]["accountID"],
                        ),
                    source: crate::composer_commands::Submission::new(
                        &current,
                        current["draft"].as_str().unwrap_or(""),
                    ),
                    ui_draft,
                }
            };
            let mut params =
                json!({"threadId":id,"provider":provider,"expected":pending.source.thread});
            if let Some(request) = &pending.source.restore_request {
                params["restoreRequestId"] = json!(request);
            }
            if let Some(account) = &pending.account {
                params["accountId"] = account.clone();
            }
            if pending.observation_only {
                params["restoreCurrent"] = json!(true);
            }
            let response = selection_response(&mut engine, "agent.provider.select", params)?;
            let acknowledged_account = restore_receipt_scope(
                &response,
                &current,
                &provider,
                pending.account.as_ref(),
                pending.source.restore_request.as_deref(),
            )?;
            if response["pending"] == true {
                pending.source.restore_request = Some(
                    response["requestId"]
                        .as_str()
                        .context("Missing restoration request")?
                        .to_owned(),
                );
            } else {
                let ack = &response["thread"];
                anyhow::ensure!(
                    (pending.observation_only
                        || pending.source.same_content(ack, &pending.source.draft))
                        && ack["id"] == current["id"]
                        && ack["selection"]["provider"] == provider
                        && ack["selection"]["modelID"] == response["model"]
                        && restore_account_id(&ack["selection"]["accountID"])
                            == restore_account_id(&acknowledged_account)
                        && ack["accessMode"] == current["accessMode"]
                        && ack["interactionMode"] == current["interactionMode"],
                    "Provider acknowledgement changed account, draft, content or modes"
                );
            }
            Ok((response, pending))
        })();
        match result {
            Ok((response, pending)) if response["pending"] == true => {
                self.selection_ui.pending_provider_picker = Some(pending);
                self.status =
                    "Checking the previous account's models. Your draft is retained.".into();
            }
            Ok((response, _)) => {
                self.selection_ui.pending_provider_picker = None;
                if response["selectionUnchanged"] == true {
                    self.selection_ui.context = None;
                    self.selection_ui.capability_cache.invalidate();
                    self.status = if response["executionReady"]==false {"The saved model or options are unavailable. Choose an available model; your message draft is retained."}else{"Account is ready."}.into();
                } else {
                    self.accept_saved_provider_selection(response["thread"].clone());
                    self.status="Previous provider account and available model selected. No message was sent.".into();
                }
                if let Some(catalog) = response.get("catalog") {
                    let request = CatalogRequest {
                        request_id: text(catalog, "requestId"),
                        provider: "codex".into(),
                        account_id: text(catalog, "accountID"),
                        thread_id: catalog["threadId"].as_str().map(str::to_owned),
                    };
                    if catalog_response_matches(catalog, &request)
                        && request.account_id
                            == restore_account_id(&response["thread"]["selection"]["accountID"])
                                .unwrap_or("")
                    {
                        self.selection_ui.catalog = catalog.clone();
                        self.selection_ui.catalog_request = None;
                    }
                }
            }
            Err(error) if engine_busy(&error) => {
                self.selection_ui.pending_provider_picker = retry_on_busy;
                if self.selection_ui.pending_provider_picker.is_none() {
                    self.selection_ui.automatic_profile_context = None;
                }
                return;
            }
            Err(error) => {
                self.selection_ui.pending_provider_picker = None;
                self.selection_ui.context = None;
                self.selection_ui.capability_cache.invalidate();
                if let Ok(mut engine) = try_state(&self.engine) {
                    let _ =
                        selection_response(&mut engine, "agent.provider.cancelRestore", json!({}));
                }
                self.status = format!("Provider was not changed; draft retained: {error}");
            }
        }
        cx.notify();
    }

    pub(super) fn perform_composer_command(
        &mut self,
        command: crate::composer_commands::Command,
        submission: crate::composer_commands::Submission,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let reported = if command == crate::composer_commands::Command::UsageLimits {
            self.codex_limits.reported_observation()
        } else {
            None
        };
        let result = (|| -> Result<Value> {
            let id = text(&submission.thread, "id");
            anyhow::ensure!(
                !self.attachment_imports.contains(&id),
                "Wait for image imports to finish; command draft retained"
            );
            if command.changes_selection() {
                anyhow::ensure!(
                    !self
                        .selection_ui
                        .drafts
                        .get(&id)
                        .is_some_and(SelectionDraft::has_edits),
                    "Apply or discard pending selection edits before a selection command; command draft retained"
                );
            }
            anyhow::ensure!(
                self.pending_drafts
                    .get(&id)
                    .is_none_or(|pending| pending.text == submission.draft),
                "A newer pending draft exists; command draft retained"
            );
            let mut engine = try_state(&self.engine)?;
            if !submission.keep_draft {
                // This transaction may consume the command text. Invalidate
                // any older debounce while holding the same Engine lock.
                self.draft_saver.invalidate();
            }
            engine_command_transaction(
                &mut engine,
                &submission,
                command,
                self.running.contains(&id),
                reported.as_ref(),
            )
        })();
        match result {
            Ok(response) if response["pending"] == true => {
                let mut submission = submission;
                submission.restore_request = response["requestId"].as_str().map(str::to_owned);
                self.selection_ui.pending_provider = Some((command, submission));
                self.status = "Checking the remembered account's model catalog. Your draft is retained; no message was sent.".into();
            }
            Ok(thread) => {
                self.selection_ui.pending_provider = None;
                let provider_message = if !default_account_id(&thread["selection"]["accountID"])
                    .is_some_and(|account| account == "default")
                {
                    format!(
                        "Previous account and model {} restored from its authenticated catalog. No message was sent.",
                        text(&thread["selection"], "modelID")
                    )
                } else if thread["selection"]["modelID"] == "default" {
                    "Provider selection saved with Provider default. Authentication was not checked. No message was sent.".to_owned()
                } else {
                    format!(
                        "Provider selection saved with previously selected catalog model {}. Authentication was not checked. No message was sent.",
                        text(&thread["selection"], "modelID")
                    )
                };
                let current = self.committed_composer_draft(cx);
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
                    if command.changes_selection() {
                        self.accept_saved_provider_selection(thread);
                    } else {
                        self.selected = Some(thread);
                    }
                    if !submission.keep_draft {
                        self.composer
                            .update(cx, |input, cx| input.set_value("", window, cx));
                    }
                    if command == crate::composer_commands::Command::Model {
                        self.selection_ui.expanded = true;
                    } else if command == crate::composer_commands::Command::UsageLimits {
                        self.open_settings_panel(window, cx);
                        self.settings_section = crate::settings::SettingsSection::Usage;
                        self.settings_search
                            .update(cx, |input, cx| input.set_value("", window, cx));
                    }
                    self.status = match command {
                        crate::composer_commands::Command::Model => {
                            "Model controls opened. Choose and Apply a selection explicitly."
                        }
                        crate::composer_commands::Command::UsageLimits => {
                            "Reported default Codex runtime limits opened. Account identity is unverified. No refresh or message was sent."
                        }
                        crate::composer_commands::Command::Plan => {
                            "Plan mode saved. No message was sent."
                        }
                        crate::composer_commands::Command::Build => {
                            "Build mode saved. No message was sent."
                        }
                        crate::composer_commands::Command::Provider(_) => {
                            &provider_message
                        }
                    }
                    .into();
                } else {
                    self.status="Command acknowledged; newer conversation/draft retained. No message was sent.".into();
                }
            }
            Err(error) if engine_busy(&error) => {
                self.selection_ui.pending_provider = Some((command, submission));
                return;
            }
            Err(error) => {
                self.selection_ui.pending_provider = None;
                self.status = format!("Command was not sent; draft retained: {error}");
            }
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
    fn observe_saved_profile_once(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let named = &self.selection_ui.capabilities["namedModels"];
        if (named["nativeApiKey"] == true || named["nativeAccount"] == true)
            || !named_models::named_thread(thread)
            || named["threadId"] != thread["id"]
            || named["accountID"] != thread["selection"]["accountID"]
            || named["refreshAllowed"] != true
            || named["accountCatalogReady"] == true
            || self.running.contains(&text(thread, "id"))
            || self.selection_ui.pending_provider.is_some()
            || self.selection_ui.pending_provider_picker.is_some()
            || self.selection_ui.catalog_request.is_some()
        {
            return;
        }
        let context = json!({"id":thread["id"],"selection":thread["selection"],"accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"],"projectID":thread["projectID"],"worktreePath":thread["worktreePath"],"selectionGeneration":named["selectionGeneration"],"readinessGeneration":named["readinessGeneration"]});
        if self.selection_ui.automatic_profile_context.as_ref() == Some(&context) {
            return;
        }
        match &self.selection_ui.automatic_profile_quiet {
            Some((previous, since))
                if previous == &context && since.elapsed() >= Duration::from_millis(300) => {}
            Some((previous, _)) if previous == &context => return,
            _ => {
                self.selection_ui.automatic_profile_quiet = Some((context, Instant::now()));
                return;
            }
        }
        self.selection_ui.automatic_profile_context = Some(context);
        self.switch_provider_from_history("codex".into(), None, cx);
    }

    pub(super) fn sync_composer_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(pending) = self.selection_ui.pending_native_account.take() {
            if self
                .selected
                .as_ref()
                .is_some_and(|thread| picker_view_scope(thread) == pending.scope)
            {
                self.select_native_account_from_picker(pending.account, cx);
            } else {
                self.status="Account selection cancelled because the conversation changed. Your draft is retained.".into();
            }
        }
        if let Some(pending) = self.selection_ui.pending_provider_picker.take() {
            self.switch_provider_from_history(pending.provider.clone(), Some(pending), cx);
        }
        if let Some((command, submission)) = self.selection_ui.pending_provider.take() {
            let current = self.committed_composer_draft(cx);
            if self.selected.as_ref().is_some_and(|thread| {
                submission.same_content(thread, &current) && submission.same_selection(thread)
            }) {
                self.perform_composer_command(command, submission, window, cx);
            } else {
                if let Ok(mut engine) = try_state(&self.engine) {
                    let _ =
                        selection_response(&mut engine, "agent.provider.cancelRestore", json!({}));
                }
                self.status = "Provider restoration cancelled because the composer changed. Your draft was retained.".into();
            }
        }
        self.observe_saved_profile_once(cx);
        let context = self.selected.as_ref().map(|thread| {
            let id = text(thread, "id");
            let running = self.running.contains(&id);
            (id, json!({"selection":thread["selection"],"accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"]}), running)
        });
        if self.selection_ui.context != context {
            self.selection_ui.context = context.clone();
            self.selection_ui.capability_cache.invalidate();
        }
        let Some((id, selection, running)) = context else {
            self.selection_ui.bound = None;
            self.selection_ui.capabilities = Value::Null;
            return;
        };
        let native_revision = self
            .provider_configuration_panel
            .read(cx)
            .account_revision();
        if native_revision != self.selection_ui.native_revision {
            self.selection_ui.native_revision = native_revision;
            self.selection_ui.capability_cache.invalidate();
        }
        if self
            .selection_ui
            .capability_cache
            .is_current(&(id.clone(), selection, running))
        {
            return;
        }
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
        self.observe_saved_profile_once(cx);
    }
    pub(super) fn refresh_provider_preferences(&mut self, cx: &mut Context<Self>) {
        self.selection_ui.capability_cache.invalidate();
        self.refresh_selection_capabilities(cx);
    }
    fn refresh_selection_capabilities(&mut self, cx: &mut Context<Self>) {
        let native_revision = self
            .provider_configuration_panel
            .read(cx)
            .account_revision();
        if native_revision != self.selection_ui.native_revision {
            self.selection_ui.native_revision = native_revision;
            self.selection_ui.capability_cache.invalidate();
        }
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let id = text(thread, "id");
        let scope = (
            id.clone(),
            capability_cache::selection_envelope(thread),
            self.running.contains(&id),
        );
        self.selection_ui.context = Some(scope.clone());
        let result = self
            .selection_ui
            .capability_cache
            .read(&self.engine, &scope);
        self.selection_ui.capability_pending = matches!(result, capability_cache::Read::Pending(_));
        let (capabilities, error, read_accounts) = match result {
            capability_cache::Read::Cached => return,
            capability_cache::Read::Pending(reason) => (
                capability_cache::closed_capabilities(&scope, reason),
                reason.into(),
                false,
            ),
            capability_cache::Read::Ready(Ok(capabilities)) => (capabilities, String::new(), true),
            capability_cache::Read::Ready(Err(error)) => {
                let reason = format!("Capabilities unavailable: {error}");
                (
                    capability_cache::closed_capabilities(&scope, &reason),
                    reason,
                    false,
                )
            }
        };
        // This metadata-only endpoint runs once after an authoritative read,
        // never on every frame while a busy Engine handoff is pending.
        let accounts = if read_accounts {
            call(&self.engine, "providers.antigravity.status", json!({}))
                .map(|status| status["accounts"].clone())
                .unwrap_or(Value::Null)
        } else {
            Value::Null
        };
        let codex_accounts = if read_accounts {
            call(&self.engine, "providers.codex.profiles.status", json!({}))
                .map(|status| status["accounts"].clone())
                .unwrap_or(Value::Null)
        } else {
            Value::Null
        };
        let native_accounts = if read_accounts {
            try_state(&self.engine)
                .and_then(|engine| {
                    engine.native_provider_accounts(&text(&thread["selection"], "provider"))
                })
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let changed = self.selection_ui.capabilities != capabilities
            || self.selection_ui.error != error
            || self.selection_ui.accounts != accounts
            || self.selection_ui.codex_accounts != codex_accounts
            || self.selection_ui.native_accounts != native_accounts;
        self.selection_ui.capabilities = capabilities;
        self.selection_ui.error = error;
        self.selection_ui.accounts = accounts;
        self.selection_ui.codex_accounts = codex_accounts;
        self.selection_ui.native_accounts = native_accounts;
        // The composer's chip and picker show provider display names, so read
        // each provider's catalog once per window session. Refresh re-reads it.
        // This keeps the picker's own tab: while the picker is open it lists the
        // agent the reader is browsing, and switching it back to the thread's
        // saved provider here is what made an OpenCode model impossible to pick
        // on a Codex thread.
        let provider = text(&thread["selection"], "provider");
        let discovery_supported = self.selection_ui.capabilities["providers"]
            .as_array()
            .is_some_and(|rows| {
                rows.iter().any(|row| {
                    row["provider"] == provider && row["modelDiscovery"]["supported"] == true
                })
            });
        let account = default_account_id(&thread["selection"]["accountID"]).unwrap_or("default");
        let attempted = self
            .selection_ui
            .catalog_attempted
            .contains(&(provider.clone(), account.to_owned()));
        if !named_models::named_thread(thread)
            && prefetches_saved_catalog(
                self.selection_ui.expanded,
                self.selection_ui.catalog_request.is_some(),
                self.selection_ui.catalog["provider"].as_str(),
                &provider,
                discovery_supported,
                attempted,
            )
        {
            self.refresh_model_catalog(Some(provider), cx);
        }
        // A pending handoff uses the existing tick/next actual UI update.
        // Repeated lock contention must not create a notify/render retry loop.
        if changed {
            cx.notify();
        }
    }
    pub(super) fn invalidate_native_conversation_view(&mut self) {
        self.selection_ui.capability_cache.invalidate();
        self.selection_ui.context = None;
        self.selection_ui.automatic_profile_context = None;
        self.selection_ui.automatic_profile_quiet = None;
        self.selection_ui.pending_provider = None;
        self.selection_ui.pending_provider_picker = None;
        self.selection_ui.expanded = false;
    }
    pub(super) fn retry_selected_account_readiness(&mut self) {
        if self
            .selected
            .as_ref()
            .is_some_and(named_models::named_thread)
        {
            self.selection_ui.capability_cache.invalidate();
            self.selection_ui.automatic_profile_context = None;
            self.selection_ui.automatic_profile_quiet = None;
        }
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
        let result = (|| -> Result<Value> {
            let previous = self
                .selected
                .as_ref()
                .context("Select a conversation first")?;
            let current = call(
                &self.engine,
                "threads.read",
                json!({"threadId":previous["id"],"itemLimit":0}),
            )?;
            refreshed_selection_view(previous, &current)
        })();
        match result {
            Ok(thread) => {
                let draft = SelectionDraft::from_thread(&thread);
                self.model_input.update(cx, |input, cx| {
                    input.set_value(draft.custom.clone(), window, cx)
                });
                self.selection_ui.drafts.insert(text(&thread, "id"), draft);
                self.selected = Some(thread);
                self.selection_ui.context = None;
                self.refresh_selection_capabilities(cx);
            }
            Err(error) => {
                self.status = format!("Selection was not reloaded: {error}");
                cx.notify();
            }
        }
    }
    /// Swift's Shift-Tab: flip the open conversation between Plan and Build.
    pub(super) fn toggle_plan_mode(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let provider = text(&thread["selection"], "provider");
        let offers_plan = self.selection_ui.capabilities["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|row| row["provider"] == provider.as_str())
            .and_then(|row| row["interactionModes"].as_array())
            .is_some_and(|modes| modes.iter().any(|mode| mode == "plan"));
        if !offers_plan {
            self.status = "This agent has no Plan mode.".into();
            cx.notify();
            return;
        }
        let plan = thread["interactionMode"] == "plan";
        self.edit_selection_immediately(
            |draft| draft.proposed_interaction = json!(if plan { "build" } else { "plan" }),
            cx,
        );
        let _ = window;
    }

    fn edit_selection_immediately(
        &mut self,
        edit: impl FnOnce(&mut SelectionDraft),
        cx: &mut Context<Self>,
    ) {
        let pending = self
            .selected
            .as_ref()
            .and_then(|thread| self.selection_ui.drafts.get(&text(thread, "id")))
            .is_some_and(SelectionDraft::has_edits);
        if pending {
            self.status =
                "Finish or discard the pending model choice before changing another option.".into();
            cx.notify();
            return;
        }
        self.edit_selection(edit, cx);
        self.apply_selection_draft(cx);
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
            Ok(()) => self.edit_selection_immediately(|draft| draft.proposed_effort = value, cx),
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
            Ok(()) => self.edit_selection_immediately(|draft| draft.proposed_speed = value, cx),
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
            if self.running.contains(&id) {
                // Queue it: the draft stays as it is and the turn's end applies
                // it, instead of writing a selection the agent is still using.
                let staged = draft.has_edits();
                engine.defer_goal_for_staged_selection(&current, staged)?;
                self.selection_ui.goal_yield_attempts.remove(&id);
                anyhow::bail!(STAGED_SELECTION);
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
            Err(error) if error.to_string() == STAGED_SELECTION => {
                self.selection_ui.context = None;
                self.status = "This change applies when the current turn ends.".into();
            }
            Err(error) => {
                self.selection_ui.context = None;
                self.status = format!("Selection was not changed: {error}");
            }
        }
        cx.notify();
    }
    /// Apply the selection the user changed during a turn now that it ended.
    /// This is the queue: the controls never go dead, and the change lands at
    /// the first moment the provider can take it.
    pub(super) fn flush_staged_selection(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        if self.running.contains(&id) {
            return;
        }
        let staged = self
            .selection_ui
            .drafts
            .get(&id)
            .is_some_and(SelectionDraft::has_edits);
        if !staged {
            return;
        }
        self.apply_selection_draft(cx);
        // The turn ended on its own; the saved-selection note is not news.
        if self.status.starts_with("Selection saved") {
            self.status.clear();
        }
    }
    pub(super) fn flush_yielded_goal_selection(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        if self.selection_ui.goal_yield_attempts.insert(id) {
            self.flush_staged_selection(cx);
        }
    }
    /// Show the last catalog at once and only read again when there is none.
    /// Opening the picker never turns a ready list back into "Loading models…".
    fn ensure_picker_catalog(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let Some(draft) = self.selection_ui.drafts.get(&text(thread, "id")) else {
            return;
        };
        let provider = self
            .selection_ui
            .tab_provider
            .clone()
            .unwrap_or_else(|| draft.provider.clone());
        let catalog = &self.selection_ui.catalog;
        let account = picker_account(draft, &provider);
        let account = default_account_id(&account).unwrap_or("default");
        if self
            .selection_ui
            .catalog_attempted
            .contains(&(provider.clone(), account.to_owned()))
            && catalog["provider"] == provider.as_str()
            && catalog["state"] == "ready"
            && catalog["accountID"].as_str() == default_account_id(&draft.account)
        {
            return;
        }
        self.refresh_model_catalog(None, cx);
    }
    fn refresh_model_catalog(&mut self, provider_override: Option<String>, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let Some(draft) = self.selection_ui.drafts.get(&text(thread, "id")) else {
            return;
        };
        // Discovery is read-only, so it stays available for an imported or
        // locked thread whose selection cannot change. An explicit provider is
        // used for the background read behind the composer's chip, which must
        // not move the picker away from the agent tab being browsed.
        let tab_provider = provider_override
            .or_else(|| self.selection_ui.tab_provider.clone())
            .unwrap_or_else(|| draft.provider.clone());
        if let Some(pending) = self.selection_ui.catalog_request.as_ref() {
            if pending.provider == tab_provider {
                return;
            }
            // The reader moved to another agent while this provider's first
            // read was still running. Abandon the old poll instead of dropping
            // the new tab's request, which left OpenCode's list permanently
            // empty on a Codex thread. The abandoned job is never reported as
            // this provider's catalog: every status read carries its request ID.
            self.selection_ui.catalog_request = None;
            self.selection_ui.catalog_last_poll = None;
        }
        let Some(provider) = self.selection_ui.capabilities["providers"]
            .as_array()
            .and_then(|providers| providers.iter().find(|p| p["provider"] == tab_provider))
        else {
            return;
        };
        let target_account = picker_account(draft, &tab_provider);
        if provider["modelDiscovery"]["supported"] != true
            || account_problem(provider, &target_account, &self.selection_ui.accounts).is_some()
        {
            return;
        }
        let provider = tab_provider;
        let account_id = default_account_id(&target_account)
            .unwrap_or("default")
            .to_owned();
        if self.selection_ui.catalog["state"] != "ready"
            || self.selection_ui.catalog["provider"] != provider.as_str()
        {
            if let Some(cached) = self.cached_catalog(&provider, &target_account) {
                self.selection_ui.catalog = cached;
            }
        }
        let response = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            let id = text(thread, "id");
            let current = engine.store.thread(&id)?;
            draft.params(&current)?;
            selection_response(
                &mut engine,
                "agent.models.refresh",
                json!({"provider":provider,"accountId":target_account}),
            )
        })();
        match response {
            Ok(value) => {
                self.selection_ui
                    .catalog_attempted
                    .insert((provider.clone(), account_id.clone()));
                let request = CatalogRequest {
                    request_id: text(&value, "requestId"),
                    provider,
                    account_id,
                    thread_id: None,
                };
                if request.request_id.is_empty() || !catalog_response_matches(&value, &request) {
                    self.selection_ui.catalog = json!({"provider":request.provider,"accountID":request.account_id,"state":"failed","error":"Invalid catalog refresh response"});
                } else {
                    let keeps_ready_list = self.selection_ui.catalog["state"] == "ready"
                        && self.selection_ui.catalog["provider"] == request.provider.as_str();
                    let background_opencode = keeps_ready_list && request.provider == "opencode";
                    if !keeps_ready_list {
                        self.selection_ui.catalog = value;
                    }
                    self.selection_ui.catalog_request = Some(request);
                    self.selection_ui.catalog_last_poll = None;
                    // Starting a new job revokes the prior private proof. Do not
                    // keep displaying its effective default as currently proved.
                    // OpenCode variants need no proof, so its cached list stays
                    // usable while the background read finishes.
                    if !background_opencode {
                        self.selection_ui.capabilities = Value::Null;
                        self.selection_ui.context = None;
                    }
                }
            }
            Err(error) if engine_busy(&error) => {
                self.selection_ui.capability_cache.invalidate();
                self.selection_ui.context = None;
                return;
            }
            Err(error) => {
                self.selection_ui
                    .catalog_attempted
                    .insert((provider.clone(), account_id.clone()));
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
        let (method, params) = if let Some(thread) = &request.thread_id {
            (
                "providers.codex.profiles.models.status",
                json!({"requestId":request.request_id,"threadId":thread,"accountId":request.account_id}),
            )
        } else {
            (
                "agent.models.status",
                json!({"requestId":request.request_id}),
            )
        };
        match call(&self.engine, method, params) {
            Ok(value) if catalog_response_matches(&value, &request) => {
                let done = value["state"] != "loading";
                self.selection_ui.catalog = value;
                if done {
                    self.selection_ui.catalog_request = None;
                    // Capability rows contain live proof, not the disk cache.
                    // Re-read them when any provider's discovery completes.
                    self.selection_ui.capability_cache.invalidate();
                    self.selection_ui.context = None;
                    if self.selection_ui.catalog["state"] == "ready"
                        && let Ok(directory) = coincide_core::control::data_directory()
                    {
                        let _ = std::fs::create_dir_all(&directory);
                        let _ = std::fs::write(
                            directory.join("model-catalog-cache.json"),
                            self.selection_ui.catalog.to_string(),
                        );
                        if let Some(provider) = self.selection_ui.catalog["provider"].as_str() {
                            let _ = std::fs::write(
                                directory.join(format!("model-catalog-cache-{provider}.json")),
                                self.selection_ui.catalog.to_string(),
                            );
                        }
                    }
                    if request.thread_id.is_some() {
                        self.selection_ui.context = None;
                    }
                    // Reasoning choices for OpenCode are part of the catalog.
                    if self.selection_ui.catalog["provider"] == "opencode" {
                        self.selection_ui.capability_cache.invalidate();
                        self.refresh_selection_capabilities(cx);
                    }
                    // A tab opened while another agent's read was in flight
                    // waits here instead of staying on an empty list.
                    let browsed = self.selection_ui.tab_provider.clone();
                    if self.selection_ui.expanded
                        && self.selection_ui.catalog_request.is_none()
                        && browsed.as_deref() != self.selection_ui.catalog["provider"].as_str()
                    {
                        self.refresh_model_catalog(browsed, cx);
                    }
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
    /// Chooses a discovered model the way Swift's picker does: one click saves
    /// the provider and model, closes the popover, and leaves effort at the
    /// provider's default until the reasoning chips choose one.
    fn choose_picker_model(
        &mut self,
        thread_id: &str,
        provider: &str,
        model: &str,
        request_id: &str,
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
        let target_account = picker_account(draft, provider);
        if draft.original != thread["selection"]
            || catalog["state"] != "ready"
            || catalog["provenance"] != "provider_model_list"
            || catalog["requestId"].as_str() != Some(request_id)
            || catalog["provider"].as_str() != Some(provider)
            || catalog["accountID"].as_str() != default_account_id(&target_account)
            || !catalog["models"]
                .as_array()
                .is_some_and(|rows| rows.iter().any(|row| row["id"] == model))
        {
            return;
        }
        let chosen_provider = provider.to_owned();
        let chosen_model = model.to_owned();
        let Some(draft) = self.selection_ui.drafts.get_mut(thread_id) else {
            return;
        };
        draft.provider = chosen_provider.clone();
        draft.account = target_account;
        draft.custom = chosen_model.clone();
        draft.use_custom = true;
        draft.proposed_effort = Value::Null;
        draft.proposed_speed = Value::Null;
        self.model_input.update(cx, |input, cx| {
            input.set_value(chosen_model.clone(), window, cx)
        });
        self.apply_selection_draft(cx);
        let applied = self.selected.as_ref().is_some_and(|thread| {
            thread["id"] == thread_id
                && thread["selection"]["provider"] == chosen_provider.as_str()
                && thread["selection"]["modelID"] == chosen_model.as_str()
        });
        let staged = self.running.iter().any(|id| id == thread_id)
            && self
                .selection_ui
                .drafts
                .get(thread_id)
                .is_some_and(|draft| {
                    draft.provider == chosen_provider
                        && draft.custom == chosen_model
                        && draft.has_edits()
                });
        if applied || staged {
            self.selection_ui.expanded = false;
            self.selection_ui.tab_provider = None;
        }
        cx.notify();
    }
    /// Stars or unstars a model from the picker, like Swift's hover star.
    fn toggle_picker_favorite(
        &mut self,
        provider: &str,
        model: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let favorite = model_marked(&self.settings, "favoriteModels", provider, model);
        match models_settings::save(
            &self.engine,
            &[models_settings::Change::Favorite(
                provider, model, !favorite,
            )],
        ) {
            Ok(settings) => self.accept_settings(settings, window, cx),
            Err(error) => {
                self.status = format!("Favorite was not saved: {error}");
                cx.notify();
            }
        }
    }
    pub(super) fn composer_selection_footer(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(thread) = &self.selected else {
            return div().into_any_element();
        };
        let draft = self.selection_ui.drafts.get(&text(thread, "id"));
        let conflict = draft.is_some_and(|draft| {
            thread["selection"] != draft.original
                || thread["accessMode"] != draft.access
                || thread["interactionMode"] != draft.interaction
        });
        let lock = capability_lock(
            &self.selection_ui.capabilities,
            self.running.contains(&text(thread, "id")),
        );
        let summary = footer_summary(
            thread,
            draft.is_some_and(SelectionDraft::has_edits),
            conflict,
            self.selection_ui.expanded,
            lock.as_deref(),
        );
        let selection = &thread["selection"];
        let model = if selection["modelID"] == "default" {
            "Provider default".to_owned()
        } else {
            reported_picker_model_label(thread, &self.selection_ui.catalog)
                .unwrap_or_else(|| footer_value(&selection["modelID"], "Choose model"))
        };
        let effort = if selection["effort"].is_null() {
            self.selection_ui.capabilities["providers"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|provider| provider["provider"] == selection["provider"])
                .and_then(|provider| provider["effort"]["reportedDefault"].as_str())
                .map(|default| effort_picker_title(&json!(default)))
                .unwrap_or_else(|| effort_picker_title(&selection["effort"]))
        } else {
            effort_picker_title(&selection["effort"])
        };
        let speed = self.selection_ui.capabilities["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|provider| provider["provider"] == selection["provider"])
            .and_then(|provider| provider["speed"]["choices"].as_array())
            .and_then(|choices| {
                choices
                    .iter()
                    .find(|choice| choice["id"] == selection["speed"])
            })
            .and_then(|choice| choice["name"].as_str())
            .map(str::to_owned)
            .unwrap_or_else(|| footer_value(&selection["speed"], "Standard"));
        let access = if thread["accessMode"] == "fullAccess" {
            "Full access"
        } else {
            "Ask for approval"
        };
        let mode = if thread["interactionMode"] == "plan" {
            "Plan"
        } else {
            "Build"
        };
        let speed_supported = self.selection_ui.capabilities["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|provider| provider["provider"] == selection["provider"])
            .is_some_and(|provider| {
                provider["speed"]["supported"] == true
                    && provider["speed"]["choices"]
                        .as_array()
                        .is_some_and(|choices| !choices.is_empty())
            });
        let available = self.composer_available_width(window);
        let measure = |label: &str| {
            let run = TextRun {
                len: label.len(),
                font: font("system-ui"),
                color: self.color(0xe4e9f2).into(),
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            f32::from(
                window
                    .text_system()
                    .shape_line(label.into(), px(13.), &[run], None)
                    .width,
            )
        };
        let follow = coincide_core::composer_follow_up::selected(thread, &self.settings);
        let widths = [
            (measure(&model) + 35.).min(240.),
            measure(&effort) + 36.,
            if speed_supported {
                measure(&speed) + 36.
            } else {
                0.
            },
            measure(access) + 36.,
            measure(follow.label()) + 36.,
            measure(mode) + 28.,
        ];
        // Attach, voice, send and optional usage/context meters keep their space.
        let trailing = 76.
            + self.composer_meter_width(cx)
            + if coincide_core::voice::Settings::decode(&self.settings).enabled {
                30.
            } else {
                0.
            }
            + if self.running.contains(&text(thread, "id")) {
                30.
            } else {
                0.
            };
        let compact = footer_compaction(widths, (available - trailing).max(0.));
        let mut controls = div().flex().items_center().gap(px(2.));

        let facets = [
            (
                PickerFacet::Model,
                "selection-disclosure",
                model,
                summary.accessible.clone(),
            ),
            (
                PickerFacet::Effort,
                "selection-effort-disclosure",
                effort,
                "Reasoning effort".into(),
            ),
            (
                PickerFacet::Speed,
                "selection-speed-disclosure",
                speed,
                "Response speed".into(),
            ),
            (
                PickerFacet::Access,
                "selection-access-disclosure",
                access.into(),
                "Permissions".into(),
            ),
            (
                PickerFacet::Mode,
                "selection-mode-disclosure",
                mode.into(),
                "Build or Plan".into(),
            ),
        ];
        for (facet, id, label, help) in facets
            .into_iter()
            .filter(|(facet, ..)| *facet != PickerFacet::Speed || speed_supported)
        {
            let small = compact[match facet {
                PickerFacet::Model => 0,
                PickerFacet::Effort => 1,
                PickerFacet::Speed => 2,
                PickerFacet::Access => 3,
                PickerFacet::Mode => 5,
            }];
            controls = controls.child(
                Button::new(id)
                    .when(facet != PickerFacet::Model && !small, |button| {
                        button.label(label.clone())
                    })
                    .accessibility_label(help.clone())
                    .tooltip(help)
                    .h(px(28.))
                    .rounded(px(8.))
                    .when(facet == PickerFacet::Model, |button| {
                        if small {
                            button.w(px(28.)).p_0().child(chat_layout::provider_label(
                                &text(selection, "provider"),
                                String::new(),
                            ))
                        } else {
                            button.max_w(px(240.)).child(chat_layout::provider_label(
                                &text(selection, "provider"),
                                label.clone(),
                            ))
                        }
                    })
                    .when(small && facet != PickerFacet::Model, |button| {
                        button.w(px(28.)).p_0()
                    })
                    .when(facet != PickerFacet::Mode && !small, |button| {
                        button.dropdown_caret(true)
                    })
                    .when(facet != PickerFacet::Model, |button| {
                        button.icon(match facet {
                            PickerFacet::Effort => gpui_kit::assets::IconName::Brain,
                            PickerFacet::Speed => gpui_kit::assets::IconName::Zap,
                            PickerFacet::Access => {
                                if access == "Full access" {
                                    gpui_kit::assets::IconName::LockOpen
                                } else {
                                    gpui_kit::assets::IconName::Lock
                                }
                            }
                            PickerFacet::Mode if mode == "Plan" => {
                                gpui_kit::assets::IconName::PencilRuler
                            }
                            _ => gpui_kit::assets::IconName::Hammer,
                        })
                    })
                    .ghost()
                    .compact()
                    .when(
                        self.selection_ui.expanded && self.selection_ui.facet == facet,
                        |button| button.bg(self.color(0x202a3b)),
                    )
                    .on_click(
                        cx.listener(move |this, event: &gpui_kit::ClickEvent, _, cx| {
                            let was_open =
                                this.selection_ui.expanded && this.selection_ui.facet == facet;
                            this.selection_ui.expanded = !was_open;
                            this.selection_ui.facet = facet;
                            this.selection_ui.popover_anchor = Some(event.position());
                            if !was_open {
                                this.selection_ui.tab_provider = this
                                    .selected
                                    .as_ref()
                                    .map(|thread| text(&thread["selection"], "provider"))
                                    .filter(|provider| !provider.is_empty());
                                if facet == PickerFacet::Model {
                                    this.ensure_picker_catalog(cx);
                                }
                            }
                            cx.notify();
                        }),
                    ),
            );
            if facet == PickerFacet::Access {
                controls = controls.child(self.follow_up_button(compact[4], cx));
            }
        }
        div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_1()
            .child(controls)
            .when_some(summary.annotation, |view, annotation| {
                view.child(div().text_xs().truncate().child(annotation))
            })
            .into_any_element()
    }
    /// Thread › Choose Agent and Model…, Reasoning Effort…, Access… and Plan
    /// Mode open the composer's own picker on that facet.
    pub(super) fn open_composer_picker(&mut self, facet: PickerFacet, cx: &mut Context<Self>) {
        if self.selected.is_none() {
            return;
        }
        self.selection_ui.expanded = true;
        self.selection_ui.facet = facet;
        self.selection_ui.popover_anchor = None;
        self.follow_up_picker = false;
        self.selection_ui.tab_provider = self
            .selected
            .as_ref()
            .map(|thread| text(&thread["selection"], "provider"))
            .filter(|provider| !provider.is_empty());
        if facet == PickerFacet::Model {
            self.ensure_picker_catalog(cx);
        }
        cx.notify();
    }
    /// The saved conversation's selection capabilities, as last read; no engine call.
    pub(super) fn escape_dismisses_popover(
        &mut self,
        event: &gpui_kit::KeyDownEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        if event.keystroke.key != "escape" {
            return false;
        }
        if self.selection_ui.expanded || self.follow_up_picker {
            self.selection_ui.expanded = false;
            self.follow_up_picker = false;
            cx.notify();
            return true;
        }
        false
    }
    pub(super) fn composer_selection_capabilities(&self) -> &Value {
        &self.selection_ui.capabilities
    }
    pub(super) fn composer_selection_expanded(&self) -> bool {
        self.selection_ui.expanded
    }
    /// Swift's start of an empty thread: the serif headline just above the
    /// composer, with the agent and model the thread will use.
    pub(super) fn chat_welcome(&self, cx: &mut Context<Self>) -> AnyElement {
        let _ = cx;
        let Some(thread) = &self.selected else {
            return div().into_any_element();
        };
        let project_id = &thread["projectID"];
        let project = self
            .projects
            .iter()
            .find(|project| &project["id"] == project_id);
        let chats = project
            .is_some_and(|project| project["isChats"] == true || project["isBots"] == true)
            || project_id.is_null()
            || project_id.as_str() == Some("00000000-0000-0000-0000-000000000000");
        let headline = if chats {
            "What can I help with?".to_owned()
        } else if let Some(name) = project.and_then(|project| project["name"].as_str()) {
            format!("What should we build in {name}?")
        } else {
            "What should we build?".to_owned()
        };
        let provider = text(&thread["selection"], "provider");
        let model = reported_picker_model_label(thread, &self.selection_ui.catalog)
            .unwrap_or_else(|| text(&thread["selection"], "modelID"));
        let using = if model.is_empty() || model == "default" {
            format!(
                "Using {}",
                models_settings::provider_display_name(&provider)
            )
        } else {
            format!(
                "Using {} · {model}",
                models_settings::provider_display_name(&provider)
            )
        };
        div()
            .flex()
            .flex_col()
            .flex_1()
            .min_h_0()
            .justify_center()
            .items_center()
            .gap_2()
            .px(px(24.))
            .pb_5()
            .child(
                div()
                    .font_family(crate::settings::reply_font())
                    .text_3xl()
                    .text_center()
                    .child(headline),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(self.color(0xe4e9f2).opacity(0.6))
                    .child(using),
            )
            .into_any_element()
    }
    fn model_picker_filter_bar(&self, cx: &mut Context<Self>) -> AnyElement {
        let _ = cx;
        div()
            .flex()
            .items_center()
            .gap_2()
            .px_2()
            .child(
                Input::new(&self.model_picker_search)
                    .prefix(gpui_kit::assets::IconName::Search)
                    .w_full(),
            )
            .into_any_element()
    }
    /// One row in a compact picker menu, with a check, an optional icon and
    /// an optional description, matching Swift's popup rows.
    /// A neutral selection fill that does not borrow the provider accent.
    fn picker_selection_bg(&self) -> Rgba {
        if self.appearance_dark {
            rgb(0x2b2b2b)
        } else {
            rgb(0xebebeb)
        }
    }
    pub(super) fn picker_menu_row(
        &self,
        id: String,
        title: String,
        detail: Option<String>,
        icon: Option<gpui_kit::assets::IconName>,
        selected: bool,
        disabled: bool,
        action: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tall = detail.is_some();
        Button::new(SharedString::from(id))
            .w_full()
            .h(px(if tall { 48. } else { 34. }))
            .rounded(px(8.))
            .ghost()
            .when(selected, |button| button.bg(self.picker_selection_bg()))
            .disabled(disabled)
            .on_click(cx.listener(move |this, _, window, cx| action(this, window, cx)))
            .child(
                div()
                    .w_full()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .w(px(16.))
                            .flex_shrink_0()
                            .flex()
                            .justify_center()
                            .when(selected, |slot| {
                                slot.child(Icon::new(gpui_kit::assets::IconName::Check).xsmall())
                            }),
                    )
                    .when_some(icon, |row, icon| row.child(Icon::new(icon).xsmall()))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().text_sm().truncate().child(title))
                            .when_some(detail, |column, detail| {
                                column.child(
                                    div()
                                        .truncate()
                                        .text_xs()
                                        .text_color(self.color(0xe4e9f2).opacity(0.55))
                                        .child(detail),
                                )
                            }),
                    ),
            )
            .into_any_element()
    }
    /// One model row: a check for the saved choice, its agent's logo when the
    /// list mixes agents, its name, context size and favorite star.
    fn picker_model_row(
        &self,
        row: &Value,
        provider: &str,
        current_model: &str,
        thread_id: &str,
        request_id: &str,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = text(row, "id");
        let name = text(row, "displayName");
        let selected = current_model == id;
        let favorite = model_marked(&self.settings, "favoriteModels", provider, &id);
        let context = row["contextWindow"]
            .as_u64()
            .map(compact_context)
            .unwrap_or_default();
        let mixes = self.selection_ui.favorites_only
            || !self.model_picker_search.read(cx).value().trim().is_empty();
        let chosen_provider = provider.to_owned();
        let chosen_model = id.clone();
        let source_thread = thread_id.to_owned();
        let source_request = request_id.to_owned();
        let star_provider = provider.to_owned();
        let star_model = id.clone();
        let mut row_view = div()
            .id(SharedString::from(format!(
                "selection-catalog-model-{provider}-{id}"
            )))
            .h(px(30.))
            .px_2()
            .rounded(px(7.))
            .flex()
            .items_center()
            .gap_2()
            .when(selected, |row| row.bg(self.picker_selection_bg()))
            .hover(|row| row.bg(self.color(0x111722)))
            .when(disabled, |row| row.opacity(0.55))
            .on_click(cx.listener(move |this, _, window, cx| {
                this.choose_picker_model(
                    &source_thread,
                    &chosen_provider,
                    &chosen_model,
                    &source_request,
                    window,
                    cx,
                )
            }))
            .child(
                div()
                    .w(px(12.))
                    .flex_shrink_0()
                    .flex()
                    .justify_center()
                    .when(selected, |slot| {
                        slot.child(Icon::new(gpui_kit::assets::IconName::Check).xsmall())
                    }),
            );
        if mixes && let Some(image) = chat_layout::provider_logo(provider) {
            row_view = row_view.child(
                img(image)
                    .w(px(14.))
                    .h(px(14.))
                    .rounded(px(3.))
                    .bg(rgb(0x2b2b2b)),
            );
        }
        row_view
            .child(div().flex_1().min_w_0().truncate().text_sm().child(name))
            .child(
                div()
                    .flex_shrink_0()
                    .text_xs()
                    .text_color(self.color(0xe4e9f2).opacity(0.5))
                    .child(context),
            )
            .child(
                Button::new(SharedString::from(format!(
                    "selection-favorite-{provider}-{id}"
                )))
                .icon(match favorite {
                    true => gpui_kit::assets::IconName::StarFill,
                    false => gpui_kit::assets::IconName::Star,
                })
                .accessibility_label(match favorite {
                    true => "Remove from Favorites",
                    false => "Add to Favorites",
                })
                .tooltip(match favorite {
                    true => "Remove from Favorites",
                    false => "Add to Favorites",
                })
                .xsmall()
                .ghost()
                .h(px(24.))
                .w(px(24.))
                .p_0()
                .opacity(if favorite { 1.0 } else { 0.35 })
                .on_click(cx.listener(move |this, _, window, cx| {
                    cx.stop_propagation();
                    this.toggle_picker_favorite(&star_provider, &star_model, window, cx);
                })),
            )
            .into_any_element()
    }
    fn visible_picker_models<'a>(
        &self,
        catalog: &'a Value,
        thread: &Value,
        cx: &App,
    ) -> Vec<&'a Value> {
        filtered_picker_models(
            &self.settings,
            catalog,
            thread["selection"]["provider"].as_str().unwrap_or_default(),
            thread["selection"]["modelID"].as_str().unwrap_or_default(),
            &self.model_picker_search.read(cx).value(),
            self.selection_ui.favorites_only,
        )
    }
    fn composer_provider_tabs(&self, thread: &Value, cx: &mut Context<Self>) -> AnyElement {
        let source = Arc::new(picker_view_scope(thread));
        let saved_provider = text(&thread["selection"], "provider");
        let shown = self
            .selection_ui
            .tab_provider
            .clone()
            .unwrap_or_else(|| saved_provider.clone());
        let mut tabs = div().flex().items_center().gap_1().flex_wrap();
        let favorites = self.selection_ui.favorites_only;
        tabs = tabs.child(
            Button::new("picker-tab-favorites")
                .icon(match favorites {
                    true => gpui_kit::assets::IconName::StarFill,
                    false => gpui_kit::assets::IconName::Star,
                })
                .accessibility_label("Favorites")
                .tooltip("Favorites")
                .compact()
                .ghost()
                .h(px(30.))
                .w(px(38.))
                .rounded(px(7.))
                .when(favorites, |button| button.bg(self.picker_selection_bg()))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.selection_ui.favorites_only = true;
                    this.selection_ui.facet = PickerFacet::Model;
                    cx.notify();
                })),
        );
        for provider in self.selection_ui.capabilities["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|provider| provider["enabled"] != false)
        {
            let id = text(provider, "provider");
            let label = text(provider, "displayName");
            let source = source.clone();
            let selected = shown == id && !favorites;
            tabs = tabs.child(
                Button::new(SharedString::from(format!("selection-provider-{id}")))
                    .accessibility_label(label.clone())
                    .tooltip(label)
                    .compact()
                    .ghost()
                    .h(px(30.))
                    .w(px(38.))
                    .rounded(px(7.))
                    .when(selected, |button| button.bg(self.picker_selection_bg()))
                    .when_some(chat_layout::provider_logo(&id), |button, image| {
                        button.child(
                            img(image)
                                .w(px(18.))
                                .h(px(18.))
                                .rounded(px(4.))
                                .bg(rgb(0x2b2b2b)),
                        )
                    })
                    .when(chat_layout::provider_logo(&id).is_none(), |button| {
                        button.icon(gpui_kit::assets::IconName::Cpu)
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if !this
                            .selected
                            .as_ref()
                            .is_some_and(|thread| picker_view_scope(thread) == *source)
                        {
                            this.status =
                                "The conversation changed. Open the model picker again.".into();
                            cx.notify();
                            return;
                        }
                        this.selection_ui.tab_provider = Some(id.clone());
                        this.selection_ui.favorites_only = false;
                        this.selection_ui.facet = PickerFacet::Model;
                        this.ensure_picker_catalog(cx);
                        cx.notify();
                    })),
            );
        }
        tabs.into_any_element()
    }
    fn composer_codex_accounts(&self, thread: &Value, cx: &mut Context<Self>) -> AnyElement {
        if thread["selection"]["provider"] != "codex" {
            return div().into_any_element();
        }
        let native_current = self
            .selection_ui
            .native_accounts
            .iter()
            .any(|row| thread["selection"]["accountID"] == row.id);
        let mut accounts = if native_current {
            Vec::new()
        } else {
            vec![(Value::Null, "Default account".to_owned())]
        };
        for row in self
            .selection_ui
            .codex_accounts
            .as_array()
            .into_iter()
            .flatten()
        {
            if let Some(id) = row["id"].as_str() {
                accounts.push((
                    json!(id),
                    row["name"].as_str().unwrap_or("Account").to_owned(),
                ));
            }
        }
        let source = Arc::new(picker_view_scope(thread));
        let mut chips = div().flex().flex_wrap().gap_1();
        for (account, label) in accounts {
            let source = source.clone();
            let id = restore_account_id(&account).unwrap_or("default").to_owned();
            let selected = restore_account_id(&thread["selection"]["accountID"])
                == restore_account_id(&account);
            chips = chips.child(
                Button::new(SharedString::from(format!("picker-codex-account-{id}")))
                    .label(label)
                    .compact()
                    .ghost()
                    .when(selected, |button| button.primary())
                    .disabled(self.running.contains(&text(thread, "id")))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if !this
                            .selected
                            .as_ref()
                            .is_some_and(|thread| picker_view_scope(thread) == *source)
                        {
                            this.status =
                                "The conversation changed. Open the model picker again.".into();
                            cx.notify();
                            return;
                        }
                        if selected {
                            return;
                        }
                        this.selection_ui.pending_provider = None;
                        this.switch_codex_account_from_picker(account.clone(), cx);
                    })),
            );
        }
        chips.into_any_element()
    }
    /// The last ready catalog for one provider, used to show its models
    /// immediately when switching tabs instead of waiting for a cold read.
    fn cached_catalog(&self, provider: &str, account: &Value) -> Option<Value> {
        let directory = coincide_core::control::data_directory().ok()?;
        let text =
            std::fs::read_to_string(directory.join(format!("model-catalog-cache-{provider}.json")))
                .ok()?;
        let cached = serde_json::from_str::<Value>(&text).ok()?;
        (cached["state"] == "ready"
            && cached["provider"] == provider
            && cached["accountID"].as_str()? == default_account_id(account)?)
        .then_some(cached)
    }
    /// Swift's picker opens as a popover above the control that was clicked,
    /// never as a panel inside the composer. The whole window behind it closes
    /// it, and an outside click is consumed rather than reaching the chat.
    pub(super) fn composer_popover(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.follow_up_picker {
            return Some(self.composer_popover_shell(window, 340., self.follow_up_menu(cx), cx));
        }
        if !self.selection_ui.expanded {
            return None;
        }
        let width = if self.selection_ui.facet == PickerFacet::Model {
            420.
        } else {
            340.
        };
        Some(self.composer_popover_shell(window, width, self.composer_selection_pane(cx), cx))
    }
    fn composer_popover_shell(
        &self,
        window: &Window,
        width: f32,
        content: AnyElement,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let width = width
            .min(f32::from(window.viewport_size().width) - 24.)
            .max(160.);
        let height = (f32::from(window.viewport_size().height) - 24.).clamp(160., 540.);
        let anchor = self
            .selection_ui
            .popover_anchor
            .or(self.follow_up_anchor)
            .unwrap_or_else(|| {
                let size = window.viewport_size();
                point(size.width / 2. - px(width / 2.), size.height - px(96.))
            });
        // The dismiss layer stops above the composer: with it covering the
        // whole window, the first click on another chip only closed the open
        // popover, so switching facets took two clicks.
        let composer_state = self.composer.read(cx);
        let text_height = crate::chat_layout::composer_height(
            composer_state.display_map().wrap_row_count(),
            composer_state.line_height().map(f32::from).unwrap_or(20.),
            self.composer_available_height(window),
        );
        let clearance = text_height + 150.;
        div()
            .absolute()
            .inset_0()
            .child(
                div()
                    .absolute()
                    .top_0()
                    .left_0()
                    .right_0()
                    .bottom(px(clearance))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, _, _, cx| {
                            if this.selection_ui.expanded || this.follow_up_picker {
                                this.selection_ui.expanded = false;
                                this.follow_up_picker = false;
                                cx.notify();
                            }
                        }),
                    ),
            )
            .child(
                anchored()
                    .position(anchor)
                    .anchor(Anchor::BottomLeft)
                    .offset(point(px(-24.), px(-14.)))
                    .snap_to_window()
                    .child(
                        div()
                            .id("composer-popover-card")
                            .w(px(width))
                            .max_h(px(height))
                            .overflow_y_scroll()
                            .rounded(px(14.))
                            .bg(self.color(0x181d28))
                            .border_1()
                            .border_color(self.color(0x29303d))
                            .on_mouse_down(MouseButton::Left, |_, _, cx| {
                                cx.stop_propagation();
                            })
                            .child(content),
                    ),
            )
            .into_any_element()
    }
    pub(super) fn composer_selection_pane(&self, cx: &mut Context<Self>) -> AnyElement {
        if !self.selection_ui.expanded {
            return div().into_any_element();
        }
        let Some(thread) = &self.selected else {
            return div().into_any_element();
        };
        if named_models::named_thread(thread)
            && self
                .selection_ui
                .tab_provider
                .as_deref()
                .is_none_or(|provider| provider == "codex")
        {
            let pane = self.named_profile_model_pane(thread, cx);
            return if self.selection_ui.facet == PickerFacet::Model {
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(self.composer_provider_tabs(thread, cx))
                    .child(self.composer_codex_accounts(thread, cx))
                    .child(self.composer_native_accounts(thread, cx))
                    .child(self.model_picker_filter_bar(cx))
                    .child(pane)
                    .into_any_element()
            } else {
                pane
            };
        }
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
        let disabled = lock.is_some()
            || conflict
            || (self.selection_ui.facet != PickerFacet::Model && draft.has_edits());
        let replacement_context = automatic_default_replacement_context(
            draft,
            thread,
            &self.selection_ui.capabilities,
            self.running.contains(&text(thread, "id")),
        );
        let model_disabled = disabled && !replacement_context;
        let providers = self.composer_provider_tabs(thread, cx);
        let provider = self.selection_ui.capabilities["providers"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["provider"] == draft.provider));
        let known_provider = provider.is_some();
        let draft_mode_problem = mode_problem(draft, provider);
        let draft_account_problem = provider.and_then(|provider| {
            account_problem(provider, &draft.account, &self.selection_ui.accounts)
        });
        let draft_speed_problem = speed_problem(draft, thread, provider);
        if self.selection_ui.facet != PickerFacet::Model {
            let source_id = text(thread, "id");
            let source_selection = thread["selection"].clone();
            let mut menu = div().flex().flex_col().gap_1().p_2().child(
                div()
                    .px_1()
                    .pb_1()
                    .text_xs()
                    .text_color(self.color(0xe4e9f2).opacity(0.6))
                    .child(match self.selection_ui.facet {
                        PickerFacet::Effort => "Reasoning",
                        PickerFacet::Speed => "Speed",
                        PickerFacet::Access => "Access",
                        PickerFacet::Mode => "Mode",
                        PickerFacet::Model => "",
                    }),
            );
            match self.selection_ui.facet {
                PickerFacet::Effort => match effort_choices(draft, thread, provider) {
                    Ok(choices) => {
                        let id = source_id.clone();
                        let selection = source_selection.clone();
                        menu = menu.child(self.picker_menu_row(
                            "picker-effort-default".into(),
                            "Provider default".into(),
                            None,
                            None,
                            draft.proposed_effort.is_null(),
                            disabled,
                            move |this, _, cx| {
                                this.choose_effort(&id, &selection, Value::Null, cx);
                                this.selection_ui.expanded = false;
                            },
                            cx,
                        ));
                        for choice in choices {
                            let id = source_id.clone();
                            let selection = source_selection.clone();
                            let label = effort_picker_title(&json!(choice));
                            let value = json!(choice);
                            let selected = draft.proposed_effort.as_str() == Some(choice.as_str());
                            menu = menu.child(self.picker_menu_row(
                                format!("picker-effort-{choice}"),
                                label,
                                None,
                                None,
                                selected,
                                disabled,
                                move |this, _, cx| {
                                    this.choose_effort(&id, &selection, value.clone(), cx);
                                    this.selection_ui.expanded = false;
                                },
                                cx,
                            ));
                        }
                    }
                    Err(_) => {
                        menu = menu.child(
                            div()
                                .px_1()
                                .text_xs()
                                .text_color(self.color(0xe4e9f2).opacity(0.6))
                                .child(if self.selection_ui.catalog_request.is_some() {
                                    "Loading options…"
                                } else {
                                    "No options available."
                                }),
                        );
                    }
                },
                PickerFacet::Speed => match speed_choices(draft, thread, provider) {
                    Ok(choices) => {
                        let id = source_id.clone();
                        let selection = source_selection.clone();
                        menu = menu.child(self.picker_menu_row(
                            "picker-speed-standard".into(),
                            "Standard".into(),
                            None,
                            None,
                            draft.proposed_speed.is_null(),
                            disabled,
                            move |this, _, cx| {
                                this.choose_speed(&id, &selection, Value::Null, cx);
                                this.selection_ui.expanded = false;
                            },
                            cx,
                        ));
                        for choice in choices {
                            let id = source_id.clone();
                            let selection = source_selection.clone();
                            let selected =
                                draft.proposed_speed.as_str() == Some(choice.id.as_str());
                            let value = json!(choice.id.clone());
                            menu = menu.child(self.picker_menu_row(
                                format!("picker-speed-{}", choice.id),
                                choice.name.clone(),
                                choice.detail.clone(),
                                None,
                                selected,
                                disabled,
                                move |this, _, cx| {
                                    this.choose_speed(&id, &selection, value.clone(), cx);
                                    this.selection_ui.expanded = false;
                                },
                                cx,
                            ));
                        }
                    }
                    Err(_) => {
                        menu = menu.child(
                            div()
                                .px_1()
                                .text_xs()
                                .text_color(self.color(0xe4e9f2).opacity(0.6))
                                .child(if self.selection_ui.catalog_request.is_some() {
                                    "Loading options…"
                                } else {
                                    "No options available."
                                }),
                        );
                    }
                },
                PickerFacet::Access => {
                    for (mode, title, detail, icon) in [
                        (
                            "approval",
                            "Ask for approval",
                            "Asks before running commands and changing files.",
                            gpui_kit::assets::IconName::Lock,
                        ),
                        (
                            "fullAccess",
                            "Full access",
                            "Runs commands and edits files without asking.",
                            gpui_kit::assets::IconName::LockOpen,
                        ),
                    ] {
                        let available = provider
                            .is_some_and(|provider| advertised_mode(provider, "accessModes", mode));
                        menu = menu.child(self.picker_menu_row(
                            format!("picker-access-{mode}"),
                            title.into(),
                            Some(detail.into()),
                            Some(icon),
                            draft.proposed_access == mode,
                            disabled || !available,
                            move |this, _, cx| {
                                this.edit_selection_immediately(
                                    |draft| draft.proposed_access = json!(mode),
                                    cx,
                                );
                                this.selection_ui.expanded = false;
                            },
                            cx,
                        ));
                    }
                }
                PickerFacet::Mode => {
                    for (mode, title, detail, icon) in [
                        (
                            "build",
                            "Build",
                            "Makes changes in the project.",
                            gpui_kit::assets::IconName::Hammer,
                        ),
                        (
                            "plan",
                            "Plan",
                            "Researches and proposes changes without editing.",
                            gpui_kit::assets::IconName::PencilRuler,
                        ),
                    ] {
                        let available = provider.is_some_and(|provider| {
                            advertised_mode(provider, "interactionModes", mode)
                        });
                        menu = menu.child(self.picker_menu_row(
                            format!("picker-mode-{mode}"),
                            title.into(),
                            Some(detail.into()),
                            Some(icon),
                            draft.proposed_interaction == mode,
                            disabled || !available,
                            move |this, _, cx| {
                                this.edit_selection_immediately(
                                    |draft| draft.proposed_interaction = json!(mode),
                                    cx,
                                );
                                this.selection_ui.expanded = false;
                            },
                            cx,
                        ));
                    }
                }
                PickerFacet::Model => {}
            }
            return menu.into_any_element();
        }
        // Swift's picker: search, agent tabs, the chosen agent's models with
        // their context sizes, then reasoning chips and refresh/settings.
        let tab_provider = self
            .selection_ui
            .tab_provider
            .clone()
            .unwrap_or_else(|| draft.provider.clone());
        let query = self.model_picker_search.read(cx).value();
        let current_model = if draft.provider == tab_provider {
            draft.custom.clone()
        } else {
            String::new()
        };
        let catalog = &self.selection_ui.catalog;
        let target_account = picker_account(draft, &tab_provider);
        let same_scope = catalog["provider"].as_str() == Some(tab_provider.as_str())
            && catalog["accountID"].as_str() == default_account_id(&target_account);
        let state = if same_scope {
            catalog["state"].as_str().unwrap_or("")
        } else {
            ""
        };
        let thread_id = text(thread, "id");
        let request_id = text(catalog, "requestId");
        let mut list = div()
            .id("selection-model-list")
            .max_h(px(264.))
            .overflow_y_scroll()
            .flex()
            .flex_col();
        let mut shown = 0usize;
        if state == "ready" {
            for row in filtered_picker_models(
                &self.settings,
                catalog,
                &tab_provider,
                &current_model,
                &query,
                self.selection_ui.favorites_only,
            ) {
                if text(row, "id").is_empty() {
                    continue;
                }
                shown += 1;
                list = list.child(self.picker_model_row(
                    row,
                    &tab_provider,
                    &current_model,
                    &thread_id,
                    &request_id,
                    model_disabled,
                    cx,
                ));
            }
        }
        let discovery_reason = self.selection_ui.capabilities["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|provider| provider["provider"] == tab_provider)
            .and_then(|provider| provider["modelDiscovery"]["reason"].as_str())
            .unwrap_or("Models have not been read yet.");
        let empty = match state {
            "loading" => "Loading models…".to_owned(),
            "unsupported" | "failed" => "Models unavailable.".to_owned(),
            "ready" if shown == 0 && !query.trim().is_empty() => "No models match.".to_owned(),
            "ready" if self.selection_ui.favorites_only => {
                "No favorites yet. Star a model to keep it here.".to_owned()
            }
            "ready" => "No models yet.".to_owned(),
            _ => discovery_reason.to_owned(),
        };
        if shown == 0 {
            list = list.child(
                div()
                    .px_2()
                    .py_3()
                    .text_xs()
                    .text_color(self.color(0xe4e9f2).opacity(0.6))
                    .child(empty),
            );
        }
        let mut reasoning = div().flex().items_center().gap_1();
        let mut shows_reasoning = false;
        if tab_provider == "opencode"
            && draft.provider == "opencode"
            && !draft.has_edits()
            && state == "ready"
            && let Some(row) = catalog["models"].as_array().and_then(|rows| {
                rows.iter()
                    .find(|row| row["id"] == thread["selection"]["modelID"])
            })
        {
            let efforts = row["reportedEfforts"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>();
            if !efforts.is_empty() {
                shows_reasoning = true;
                reasoning = reasoning.child(
                    div()
                        .w(px(76.))
                        .flex_shrink_0()
                        .text_xs()
                        .text_color(self.color(0xe4e9f2).opacity(0.6))
                        .child("Reasoning"),
                );
                let source_id = thread_id.clone();
                let source_selection = thread["selection"].clone();
                for effort in efforts {
                    let selected = thread["selection"]["effort"].as_str() == Some(effort.as_str())
                        || (thread["selection"]["effort"].is_null()
                            && row["reportedDefaultEffort"].as_str() == Some(effort.as_str()));
                    let value = effort.clone();
                    let id = source_id.clone();
                    let selection = source_selection.clone();
                    reasoning = reasoning.child(
                        Button::new(SharedString::from(format!("picker-effort-{effort}")))
                            .label(effort_picker_title(&json!(effort)))
                            .compact()
                            .ghost()
                            .h(px(24.))
                            .rounded(px(12.))
                            .when(selected, |button| button.primary())
                            .disabled(model_disabled)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.choose_effort(&id, &selection, json!(value), cx)
                            })),
                    );
                }
            }
        }
        let mut accounts = div().flex().flex_wrap().items_center().gap_2();
        if draft.provider == "antigravity" {
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
                        .compact()
                        .ghost()
                        .when(draft.account.as_str() == Some(id.as_str()), |button| {
                            button.primary()
                        })
                        .disabled(model_disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.edit_selection(|draft| draft.account = json!(id), cx)
                        })),
                );
            }
        }
        let footer = div()
            .flex()
            .items_center()
            .justify_between()
            .gap_2()
            .child(
                Button::new("selection-refresh-models")
                    .label("Refresh")
                    .icon(gpui_kit::assets::IconName::RotateCw)
                    .compact()
                    .ghost()
                    .disabled(self.selection_ui.catalog_request.is_some())
                    .on_click(cx.listener(|this, _, _, cx| this.refresh_model_catalog(None, cx))),
            )
            .child(
                Button::new("picker-agent-settings")
                    .label("Agent Settings…")
                    .icon(gpui_kit::assets::IconName::Settings)
                    .compact()
                    .ghost()
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.selection_ui.expanded = false;
                        this.open_settings_panel(window, cx);
                        this.navigate_settings_section(
                            settings::SettingsSection::Models,
                            window,
                            cx,
                        );
                    })),
            );
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_2()
            .min_w_0()
            .mb_2()
            .child(providers)
            .when(draft.provider == "antigravity", |pane| pane.child(accounts))
            .child(self.model_picker_filter_bar(cx))
            .child(list)
            .when(shows_reasoning, |pane| {
                pane.child(div().h(px(1.)).w_full().bg(self.color(0x29303d)))
                    .child(reasoning)
            })
            .child(div().h(px(1.)).w_full().bg(self.color(0x29303d)))
            .child(footer);
        if let Some(reason) = draft_mode_problem.clone() {
            pane = pane.child(div().text_sm().child(reason));
        }
        if let Some(reason) = draft_account_problem.clone() {
            pane = pane.child(div().text_sm().child(reason));
        }
        if let Some(reason) = draft_speed_problem.clone() {
            pane = pane.child(div().text_sm().child(reason));
        }
        if replacement_context {
            pane = pane.child(div().text_sm().child("The current model's app default is unproved. Refresh its catalog, or explicitly choose another provider/model and Apply. Modes, effort, speed and Send remain locked; the replacement is validated normally."));
        }
        if let Some(reason) = lock.filter(|reason| !reason.to_ascii_lowercase().contains("catalog"))
        {
            pane = pane.child(div().text_sm().child(reason));
        }
        if conflict {
            pane = pane.child(div().text_sm().child("Saved selection changed. Your selection draft is retained; discard selection edits to reload before applying."));
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
        div()
            .flex()
            .flex_col()
            .min_w_0()
            .p_3()
            .child(div().min_w_0().child(pane))
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    #[::core::prelude::v1::test]
    fn footer_labels_collapse_in_swifts_order_without_spending_space_on_absent_speed() {
        let widths = [180., 75., 0., 110., 80., 65.];
        assert_eq!(super::footer_compaction(widths, 600.), [false; 6]);
        assert_eq!(
            super::footer_compaction(widths, 485.),
            [false, false, false, false, false, true]
        );
        assert_eq!(
            super::footer_compaction(widths, 350.),
            [false, false, false, true, true, true]
        );
        assert_eq!(
            super::footer_compaction(widths, 140.),
            [true, true, false, true, true, true]
        );
    }

    use super::*;
    #[::core::prelude::v1::test]
    fn sending_waits_for_one_live_catalog_without_blocking_other_providers_or_running_turns() {
        let codex = json!({"provider":"codex", "modelID":"synthetic", "effort":"high"});
        assert_eq!(observed_discovery(&Value::Null, None), None);
        assert_eq!(
            observed_discovery(&json!({"providers":[]}), None),
            Some(false)
        );
        assert_eq!(
            observed_discovery(&json!({"providers":[]}), Some(true)),
            Some(true)
        );
        let named = json!({"refreshAllowed":true,"accountCatalogReady":false});
        assert!(named_catalog_needs_observation(&named, false, false));
        assert!(!named_catalog_needs_observation(&named, false, true));
        assert!(!named_catalog_needs_observation(
            &json!({"nativeApiKey":true,"refreshAllowed":true}),
            false,
            false
        ));
        assert!(!named_catalog_needs_observation(
            &json!({"nativeAccount":true,"refreshAllowed":true}),
            false,
            false
        ));
        assert_eq!(
            send_catalog_action(&codex, false, false, false, None),
            SendCatalogAction::Wait
        );
        assert_eq!(
            send_catalog_action(&codex, false, false, false, Some(true)),
            SendCatalogAction::Refresh
        );
        assert_eq!(
            send_catalog_action(&codex, false, true, true, Some(true)),
            SendCatalogAction::Wait
        );
        assert_eq!(
            send_catalog_action(&codex, false, true, false, Some(true)),
            SendCatalogAction::Proceed
        );
        assert_eq!(
            send_catalog_action(&codex, false, false, false, Some(false)),
            SendCatalogAction::Unavailable
        );
        assert_eq!(
            send_catalog_action(&codex, true, false, true, Some(true)),
            SendCatalogAction::Proceed
        );
        for provider in ["claude", "opencode", "cursor", "grok", "antigravity"] {
            let selection = json!({"provider":provider,"modelID":"model","effort":"high"});
            assert_eq!(
                send_catalog_action(&selection, false, false, true, None),
                SendCatalogAction::Proceed
            );
        }
        assert_eq!(
            send_catalog_action(
                &json!({"provider":"codex","modelID":"gpt-6-astra"}),
                false,
                false,
                false,
                Some(true)
            ),
            SendCatalogAction::Refresh
        );
    }
    #[::core::prelude::v1::test]
    fn capability_reads_never_replace_the_agent_tab_the_picker_shows() {
        // Browsing OpenCode's models on a Codex thread: the open picker owns
        // the catalog, so a capability read must not prefetch Codex's list.
        assert!(!prefetches_saved_catalog(
            true,
            false,
            Some("opencode"),
            "codex",
            true,
            true
        ));
        assert!(!prefetches_saved_catalog(
            false,
            true,
            Some("opencode"),
            "codex",
            true,
            true
        ));
        assert!(prefetches_saved_catalog(
            false,
            false,
            Some("opencode"),
            "codex",
            true,
            true
        ));
        assert!(!prefetches_saved_catalog(
            false,
            false,
            Some("codex"),
            "codex",
            true,
            true
        ));
        assert!(!prefetches_saved_catalog(
            false,
            false,
            Some("opencode"),
            "grok",
            false,
            false
        ));
        assert!(
            prefetches_saved_catalog(false, false, Some("codex"), "codex", true, false),
            "a disk cache does not replace the first live read after restart"
        );
        assert!(
            !prefetches_saved_catalog(false, true, Some("codex"), "codex", true, false),
            "a live read already in flight is not started again"
        );
    }
    #[::core::prelude::v1::test]
    fn picker_preferences_filter_without_inventing_catalog_rows_or_changing_selection() {
        let settings = json!({"favoriteModels":[{"provider":"codex","modelID":"b"},{"provider":"codex","modelID":"not-reported"}],"hiddenModels":[{"provider":"codex","modelID":"a"},{"provider":"claude","modelID":"c"}]});
        let catalog = json!({"models":[{"id":"a","displayName":"Alpha","opaque":{"retained":true}},{"id":"b","displayName":"Beta"},{"id":"c","displayName":"Gamma"}]});
        let before = catalog.clone();
        let all = filtered_picker_models(&settings, &catalog, "codex", "a", "", false);
        assert_eq!(
            all.iter()
                .map(|row| row["id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["b", "a", "c"]
        );
        assert_eq!(all[1]["opaque"], json!({"retained":true}));
        let favorites = filtered_picker_models(&settings, &catalog, "codex", "c", "BE ta", true);
        assert_eq!(
            favorites
                .iter()
                .map(|row| row["id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["b"]
        );
        assert!(
            filtered_picker_models(&settings, &catalog, "codex", "c", "alpha", false).is_empty()
        );
        assert_eq!(catalog, before);
    }
    #[::core::prelude::v1::test]
    fn picker_display_name_never_borrows_another_account_or_thread_catalog() {
        let thread = json!({"id":"A","selection":{"provider":"codex","accountID":"named-a","modelID":"reported-id"}});
        let mut catalog = json!({"state":"ready","provider":"codex","accountID":"named-a","threadId":"A","models":[{"id":"reported-id","displayName":"Friendly name"}]});
        assert_eq!(
            reported_picker_model_label(&thread, &catalog).as_deref(),
            Some("Friendly name")
        );
        catalog["accountID"] = json!("named-b");
        assert_eq!(reported_picker_model_label(&thread, &catalog), None);
        catalog["accountID"] = json!("named-a");
        catalog["threadId"] = json!("B");
        assert_eq!(reported_picker_model_label(&thread, &catalog), None);
        catalog["threadId"] = json!("A");
        catalog["state"] = json!("loading");
        assert_eq!(reported_picker_model_label(&thread, &catalog), None);
    }
    #[::core::prelude::v1::test]
    fn picker_catalog_accounts_follow_the_target_provider() {
        let thread = json!({"id":"A","selection":{"provider":"codex","accountID":"private-account","modelID":"model"},"accessMode":"approval","interactionMode":"build"});
        let mut draft = SelectionDraft::from_thread(&thread);
        assert_eq!(picker_account(&draft, "codex"), "private-account");
        assert_eq!(picker_account(&draft, "claude"), Value::Null);
        draft.provider = "claude".into();
        draft.account = Value::Null;
        assert_eq!(picker_account(&draft, "claude"), Value::Null);
        assert_eq!(picker_account(&draft, "codex"), "private-account");
        assert_eq!(picker_account(&draft, "opencode"), Value::Null);
    }
    #[::core::prelude::v1::test]
    fn effort_labels_follow_the_swift_menu_without_changing_saved_values() {
        for (raw, label) in [
            (Value::Null, "Auto"),
            (json!("xhigh"), "Extra High"),
            (json!("ultra"), "Ultra"),
            (json!("off"), "Off"),
            (json!("max"), "Max"),
        ] {
            assert_eq!(effort_picker_title(&raw), label);
        }
    }

    #[::core::prelude::v1::test]
    fn footer_reports_saved_values_while_proposed_choices_remain_pending() {
        let thread = json!({"id":"t","selection":{"provider":"codex","modelID":"saved-model","effort":"high","speed":"priority","accountID":"named-account"},"accessMode":"approval","interactionMode":"build"});
        let before = thread.clone();
        let mut draft = SelectionDraft::from_thread(&thread);
        draft.provider = "claude".into();
        draft.custom = "proposed-model".into();
        draft.proposed_effort = json!("xhigh");
        draft.proposed_speed = json!("flex");
        draft.proposed_access = json!("fullAccess");
        draft.proposed_interaction = json!("plan");
        let summary = footer_summary(&thread, draft.has_edits(), false, false, None);
        assert!(
            summary
                .saved
                .contains("Codex · saved-model · Effort high · Speed priority · Approval · Build")
        );
        assert!(summary.saved.contains("Account named-account"));
        for proposed in [
            "Claude",
            "proposed-model",
            "xhigh",
            "flex",
            "Full access",
            "Plan",
        ] {
            assert!(!summary.saved.contains(proposed));
        }
        assert_eq!(summary.annotation.as_deref(), Some("Edits pending"));
        assert!(summary.accessible.contains("Pending edits are not applied"));
        assert_eq!(thread, before);
    }
    #[::core::prelude::v1::test]
    fn footer_unset_values_do_not_invent_effective_effort_or_speed() {
        let thread = json!({"selection":{"provider":"codex","modelID":"gpt-6-astra","effort":null,"speed":null,"accountID":null},"accessMode":null,"interactionMode":null});
        let summary = footer_summary(&thread, false, false, true, None);
        assert!(
            summary
                .saved
                .contains("Effort automatic · Speed default · Approval · Build · Default account")
        );
        assert!(!summary.saved.contains("Medium"));
        assert!(!summary.saved.contains("priority"));
        assert!(
            summary
                .accessible
                .starts_with("Hide selection options. Saved:")
        );
        assert!(!summary.accessible.contains("authentication"));
        assert!(summary.annotation.is_none());
    }
    #[::core::prelude::v1::test]
    fn footer_unknown_stored_shapes_are_explicit_and_labels_are_bounded() {
        let thread = json!({"selection":{"provider":"future-provider","modelID":"future-model","effort":4,"speed":{"future":"priority"},"accountID":[]},"accessMode":"future-access","interactionMode":"future-mode"});
        let summary = footer_summary(
            &thread,
            true,
            true,
            false,
            Some("Refresh capabilities before editing"),
        );
        assert!(summary.saved.contains("future-provider · future-model"));
        assert!(
            summary
                .saved
                .contains("Effort Unsupported numeric value · Speed Unsupported object value")
        );
        assert!(
            summary
                .saved
                .contains("Access future-access · Interaction future-mode")
        );
        assert!(summary.saved.contains("Account Unsupported array value"));
        assert_eq!(
            summary.annotation.as_deref(),
            Some("Edits pending · saved selection changed")
        );
        assert!(
            summary
                .accessible
                .contains("Locked: Refresh capabilities before editing")
        );
        let label = footer_value(&json!(format!("{}\nend", "é".repeat(600))), "not set");
        assert!(label.chars().count() <= 513);
        assert!(label.ends_with('…'));
        assert!(!label.chars().any(char::is_control));
    }
    #[::core::prelude::v1::test]
    fn selection_reload_uses_authoritative_fields_without_replacing_local_content() {
        let previous = json!({"id":"thread","selection":{"provider":"codex","speed":null},"accessMode":"approval","interactionMode":"build","draft":"exact unsaved café\n","draftContext":[{"quote":"keep"}],"rustDraftImages":[{"id":"keep-image"}],"items":[{"body":"loaded transcript"}],"opaque":{"keep":true}});
        let current = json!({"id":"thread","selection":{"provider":"codex","speed":"priority","effort":"high","future":{"keep":7}},"accessMode":"approval","interactionMode":"plan","draft":"older persisted value","items":[]});
        let refreshed = refreshed_selection_view(&previous, &current).unwrap();
        for key in ["selection", "accessMode", "interactionMode"] {
            assert_eq!(refreshed[key], current[key]);
        }
        for key in [
            "draft",
            "draftContext",
            "rustDraftImages",
            "items",
            "opaque",
        ] {
            assert_eq!(refreshed[key], previous[key]);
        }
        let draft = SelectionDraft::from_thread(&refreshed);
        assert_eq!(draft.original, current["selection"]);
        assert_eq!(draft.proposed_speed, "priority");
        assert_eq!(draft.proposed_interaction, "plan");
        let mut other = current;
        other["id"] = json!("another");
        assert!(refreshed_selection_view(&previous, &other).is_err());
        assert_eq!(previous["selection"]["speed"], Value::Null);
    }
    #[::core::prelude::v1::test]
    fn submission_lock_uses_only_current_trusted_context_and_preserves_queue() {
        let thread = json!({"id":"current","selection":{"provider":"codex","modelID":"gpt-6-astra"},"accessMode":"approval","interactionMode":"build"});
        let context = (
            "current".into(),
            json!({"selection":thread["selection"],"accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"]}),
            false,
        );
        let caps = json!({"provenance":"static_runtime_contract","locked":true});
        assert!(current_submission_blocked(
            Some(&context),
            &caps,
            &thread,
            false
        ));
        assert!(!current_submission_blocked(
            Some(&context),
            &caps,
            &thread,
            true
        ));
        assert!(!current_submission_blocked(None, &caps, &thread, false));
        assert!(!current_submission_blocked(
            Some(&context),
            &json!({"locked":true}),
            &thread,
            false
        ));
        assert!(!current_submission_blocked(
            Some(&context),
            &json!({"provenance":"static_runtime_contract","locked":false}),
            &thread,
            false
        ));
        for (key, value) in [
            ("id", json!("another")),
            ("selection", json!({"provider":"claude"})),
            ("interactionMode", json!("plan")),
        ] {
            let mut changed = thread.clone();
            changed[key] = value;
            assert!(!current_submission_blocked(
                Some(&context),
                &caps,
                &changed,
                false
            ));
        }
    }
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
        assert_eq!(
            capability_lock(&caps, true).as_deref(),
            Some("Bot/import lock"),
            "a real lock still locks; running no longer does"
        );
        let open = json!({"provenance":"static_runtime_contract","locked":false,"providers":[modes("codex",true)]});
        assert!(
            capability_lock(&open, true).is_none(),
            "a running turn leaves the composer's controls usable"
        );
        let active = json!({"provenance":"static_runtime_contract","locked":true,"lockReason":"Stop the current turn before changing provider","providers":[modes("codex",true)]});
        assert!(capability_lock(&active, true).is_none());
        assert!(capability_lock(&active, false).is_some());
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
        assert!(
            capability_lock(&caps, true).is_none(),
            "running is not a lock; a change belongs to the next turn"
        );
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
            thread_id: None,
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
        let submission = if fault == "suggested" {
            crate::composer_commands::Submission::suggested(
                &stored,
                stored["draft"].as_str().unwrap(),
            )
        } else {
            crate::composer_commands::Submission::new(&stored, stored["draft"].as_str().unwrap())
        };
        let mut calls = Vec::new();
        let mut reads = 0;
        let result = command_transaction(&submission, command, false, None, |method, params| {
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
    fn suggested_command_keeps_the_rest_of_the_draft_and_its_attachments() {
        let mut original = command_thread("fix the login ");
        original["rustDraftImages"] = json!([{"id":"image"}]);
        original["draftContext"] = json!([{"kind":"quote","text":"reference"}]);
        for command in [
            crate::composer_commands::Command::Plan,
            crate::composer_commands::Command::Model,
        ] {
            let (result, stored, calls) = fake_command(
                command,
                original.clone(),
                command_capabilities("codex", false),
                "suggested",
            );
            let thread = result.unwrap();
            assert_eq!(thread["draft"], "fix the login ");
            assert_eq!(stored["draft"], "fix the login ");
            assert_eq!(stored["rustDraftImages"], original["rustDraftImages"]);
            assert_eq!(stored["draftContext"], original["draftContext"]);
            assert_eq!(
                stored["interactionMode"],
                if command == crate::composer_commands::Command::Plan {
                    "plan"
                } else {
                    "build"
                }
            );
            assert!(!calls.iter().any(|method| method == "threads.patch"));
        }
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
            .is_ok(),
            "a mode change during a turn is staged, not refused"
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
            .is_ok(),
            "a model chosen during a turn belongs to the next one"
        );
    }
    fn reported_limits() -> Value {
        json!({"requestId":"reported","provider":"codex","accountScope":"default_runtime_account_identity_unknown","accountIdentityVerified":false,"state":"ready","generation":7,"observedAtEpochMs":1234,"error":null,
            "snapshot":{"provenance":"codex_app_server_account_rate_limits","accountScope":"default_runtime_account_identity_unknown","accountIdentityVerified":false,"main":{"id":"codex","displayName":null,"plan":null,"windows":[{"position":"primary","usedPercent":25,"remainingPercent":null,"durationMinutes":null,"resetsAtEpochSeconds":null}],"credits":null,"notes":[]},"modelBuckets":[]}})
    }
    fn fake_usage_command(
        mut stored: Value,
        reported: Option<crate::codex_limits_view::Observation>,
        response: Value,
        fault: &str,
    ) -> (Result<Value>, Value, Vec<String>) {
        let submission =
            crate::composer_commands::Submission::new(&stored, stored["draft"].as_str().unwrap());
        let mut calls = Vec::new();
        let mut reads = 0;
        let result = command_transaction(
            &submission,
            crate::composer_commands::Command::UsageLimits,
            fault == "running",
            reported.as_ref(),
            |method, params| {
                calls.push(method.to_owned());
                match method {
                    "threads.read" => {
                        reads += 1;
                        if reads == 1 && fault == "stale-account" {
                            stored["selection"]["accountID"] = json!("other");
                        }
                        if reads == 2 && fault == "late-draft" {
                            stored["draft"] = json!("newer café draft");
                        }
                        if reads == 2 && fault == "late-context" {
                            stored["draftContext"] =
                                json!([{"kind":"quote","text":"new reference"}]);
                        }
                        Ok(stored.clone())
                    }
                    "agent.selection.capabilities" => {
                        Ok(command_capabilities("codex", fault == "locked"))
                    }
                    "usage.codexLimits.status" => {
                        assert_eq!(params, json!({"requestId":"reported"}));
                        if fault == "status" {
                            anyhow::bail!("synthetic revoked limits context");
                        }
                        Ok(response.clone())
                    }
                    "threads.patch" => {
                        assert_eq!(params, json!({"threadId":"thread","patch":{"draft":""}}));
                        if fault == "clear" {
                            anyhow::bail!("synthetic draft persistence failure");
                        }
                        stored["draft"] = json!("");
                        Ok(stored.clone())
                    }
                    _ => panic!(
                        "Usage opener must never select, refresh, authenticate, send or queue"
                    ),
                }
            },
        );
        (result, stored, calls)
    }
    #[::core::prelude::v1::test]
    fn usage_limits_reads_only_current_reported_status_then_clears_exact_draft() {
        let mut original = command_thread("  /usage-limits\n");
        original["selection"]["futureOption"] = json!({"retain":[true,"中文"]});
        original["sessions"] = json!({"codex":{"sessionID":"opaque"}});
        original["futureThread"] = json!([true, 42]);
        let observation = crate::codex_limits_view::decode(&reported_limits()).unwrap();
        let (result, stored, calls) =
            fake_usage_command(original.clone(), Some(observation), reported_limits(), "");
        assert!(result.is_ok());
        let mut expected = original;
        expected["draft"] = json!("");
        assert_eq!(stored, expected);
        assert_eq!(
            calls,
            vec![
                "threads.read",
                "agent.selection.capabilities",
                "usage.codexLimits.status",
                "threads.read",
                "threads.patch"
            ]
        );
    }
    #[::core::prelude::v1::test]
    fn usage_limits_missing_scoped_stale_and_credits_only_reports_never_clear_or_send() {
        for case in [
            "missing",
            "provider",
            "named-account",
            "invalid-account",
            "request",
            "generation",
            "loading",
            "failed",
            "scope",
            "identity",
            "credits-only",
            "locked",
            "running",
            "status",
        ] {
            let mut original = command_thread("\t/usage-limits ");
            let mut response = reported_limits();
            let mut observation = Some(crate::codex_limits_view::decode(&response).unwrap());
            match case {
                "missing" => observation = None,
                "provider" => original["selection"]["provider"] = json!("claude"),
                "named-account" => original["selection"]["accountID"] = json!("named-profile"),
                "invalid-account" => original["selection"]["accountID"] = json!(false),
                "request" => response["requestId"] = json!("superseded"),
                "generation" => response["generation"] = json!(8),
                "loading" => {
                    response["state"] = json!("loading");
                    response["snapshot"] = Value::Null;
                }
                "failed" => {
                    response["state"] = json!("failed");
                    response["snapshot"] = Value::Null;
                    response["error"] = json!("cancelled");
                }
                "scope" => response["accountScope"] = json!("named-account"),
                "identity" => response["accountIdentityVerified"] = json!(true),
                "credits-only" => {
                    response["snapshot"]["main"]["windows"] = json!([]);
                    response["snapshot"]["main"]["credits"] =
                        json!({"hasCredits":true,"unlimited":false,"balance":"3"});
                }
                _ => {}
            }
            let (result, stored, calls) =
                fake_usage_command(original.clone(), observation, response, case);
            if case == "running" {
                // A running turn no longer refuses the command: the report is
                // read-only and clearing the draft is allowed mid-turn.
                assert_eq!(calls.last().map(String::as_str), Some("threads.patch"));
                continue;
            }
            assert!(result.is_err(), "{case}");
            assert_eq!(stored, original, "{case}");
            assert!(!calls.iter().any(|call| call == "threads.patch"), "{case}");
        }
    }
    #[::core::prelude::v1::test]
    fn usage_limits_late_draft_context_or_clear_failure_preserves_actual_content() {
        for fault in ["late-draft", "late-context", "stale-account", "clear"] {
            let original = command_thread(" /usage-limits\n");
            let observation = crate::codex_limits_view::decode(&reported_limits()).unwrap();
            let (result, stored, calls) = fake_usage_command(
                original.clone(),
                Some(observation),
                reported_limits(),
                fault,
            );
            assert!(result.is_err());
            if fault == "late-draft" {
                assert_eq!(stored["draft"], "newer café draft");
            } else {
                assert_eq!(stored["draft"], original["draft"]);
            }
            if fault == "late-context" {
                assert_eq!(
                    stored["draftContext"],
                    json!([{"kind":"quote","text":"new reference"}])
                )
            }
            if fault != "clear" {
                assert!(!calls.iter().any(|call| call == "threads.patch"));
            }
        }
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
            .is_ok(),
            "a running turn stages the change instead of refusing it"
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
