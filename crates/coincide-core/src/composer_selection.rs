//! Strict selection syntax and private-proof validation; no discovery or credential access.
use crate::{agent::Provider, provider_catalog};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

pub fn capabilities() -> Value {
    let providers = provider_catalog::provider_catalog().iter().map(|entry| {
        let id = serde_json::to_value(entry.id).expect("provider ID is serializable");
        json!({"provider":id,"displayName":entry.display_name,
            "accountPolicy":if id == "antigravity" {"configured_antigravity"} else {"default_only"},
            "models":[{"id":"default","displayName":"Provider default","availability":"provider_resolved"}],
            "customModel":{"supported":true,"availability":"unverified"},
            "modelDiscovery":{"supported":crate::model_catalog::supported(id.as_str().unwrap_or("")),
                "reason":if crate::model_catalog::supported(id.as_str().unwrap_or("")) {Value::Null} else {json!("Read-only model discovery is not implemented for this provider/platform")}},
            "steering":{"supported":id=="codex","textOnly":true,"requiresActiveTurn":true,"requiresBuildMode":true,"reason":if id=="codex" {Value::Null}else{json!("Active-turn steering is implemented only for Codex")}},
            "effort":{"supported":false,"reason":if id=="codex" {"Choose an explicit Codex model and refresh its catalog for supported effort choices."}else{"Reasoning effort is not connected for this provider."}},
            "speed":{"supported":false,"reason":if id=="codex" {"Choose an explicit Codex model and refresh its catalog for supported speed choices."}else{"Speed is not connected for this provider."}},
            "accessModes":if id=="codex"{json!(["approval","fullAccess"])}else{json!(["approval"])},"interactionModes":if id=="codex"{json!(["build","plan"])}else{json!(["build"])},
            "modesOrdinaryThreadsOnly":id=="codex",
            "planModelRequirement":if id=="codex"{json!("explicit_model_required")}else{Value::Null}})
    }).collect::<Vec<_>>();
    json!({"provenance":"static_runtime_contract","authenticationChecked":false,"modelsDiscovered":false,
        "providers":providers,"locked":false,"lockReason":null,"repairClearAvailable":false,"repairSpeedClearAvailable":false,"repairOptionsClearAvailable":false,"canReplaceUnprovedAutomaticDefault":false})
}

pub fn default_account(value: &Value) -> bool {
    value.is_null() || matches!(value.as_str(), Some("" | "default"))
}

pub fn validate_model(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 512
            && !value.chars().any(char::is_control)
            && !value.starts_with('-'),
        "Model ID must be nonempty, at most 512 bytes, without control characters or a leading '-'"
    );
    Ok(())
}

/// Reject unsupported stored metadata before any edit/send can silently discard it.
/// Named Antigravity account configuration is validated separately by the engine.
pub fn validate_selection(value: &Value) -> Result<()> {
    let thread = json!({"selection":value});
    let selection = thread["selection"]
        .as_object()
        .context("Invalid provider selection")?;
    ensure!(
        selection.keys().all(|key| matches!(
            key.as_str(),
            "provider" | "modelID" | "accountID" | "effort" | "speed"
        )),
        "Selection contains unsupported options; selection was not changed"
    );
    let provider = thread["selection"]["provider"]
        .as_str()
        .context("Provider must be text")?;
    Provider::from_name(provider)?;
    validate_model(
        thread["selection"]["modelID"]
            .as_str()
            .context("Model ID must be text")?,
    )?;
    let speed = &thread["selection"]["speed"];
    ensure!(
        speed.is_null()
            || (provider == "codex"
                && speed.as_str().is_some_and(|value| !value.is_empty()
                    && value.len() <= 128
                    && value.trim() == value
                    && !value.chars().any(char::is_control))),
        "Speed is supported only for an explicit Codex model with advertised choices"
    );
    let effort = &thread["selection"]["effort"];
    ensure!(
        effort.is_null()
            || (provider == "codex"
                && effort.as_str().is_some_and(|value| !value.is_empty()
                    && value.len() <= 128
                    && value.trim() == value
                    && !value.chars().any(char::is_control))),
        "Effort is supported only for an explicit Codex model with advertised choices"
    );
    let account = &thread["selection"]["accountID"];
    ensure!(
        account.is_null() || account.is_string(),
        "Account ID must be text or null"
    );
    ensure!(
        provider == "antigravity" || default_account(account),
        "Alternate provider accounts are not connected yet"
    );
    Ok(())
}
pub fn validate_thread(thread: &Value) -> Result<()> {
    validate_thread_with_proof(thread, None)
}
pub(crate) fn validate_thread_base(thread: &Value) -> Result<()> {
    crate::composer_policy::Policy::parse_with_effort_proof(
        thread,
        crate::composer_policy::Origin::Ordinary,
        None,
    )?
    .preflight_base()
}
pub(crate) fn validate_thread_with_proof(
    thread: &Value,
    proof: Option<&crate::model_catalog::CodexEffortProof>,
) -> Result<()> {
    crate::composer_policy::Policy::parse_with_effort_proof(
        thread,
        crate::composer_policy::Origin::Ordinary,
        proof,
    )?
    .preflight()
}
pub fn apply_modes(params: &Value, thread: &mut Value) -> Result<()> {
    apply_modes_with_proof(params, thread, None)
}
pub(crate) fn apply_modes_with_proof(
    params: &Value,
    thread: &mut Value,
    proof: Option<&crate::model_catalog::CodexEffortProof>,
) -> Result<()> {
    for key in ["accessMode", "interactionMode"] {
        if let Some(value) = params.get(key) {
            ensure!(value.is_string(), "Mode choices must be explicit text");
            thread[key] = value.clone();
        }
    }
    validate_thread_with_proof(thread, proof)
}

/// Validate a persisted project/defaults composer envelope without dropping
/// unknown options or substituting an unsupported account/model/mode.
pub(crate) fn validate_defaults_with_proof(
    value: &Value,
    proof: Option<&crate::model_catalog::CodexEffortProof>,
) -> Result<Value> {
    let fields = value
        .as_object()
        .context("Composer defaults must be an object")?;
    ensure!(
        fields
            .keys()
            .all(|key| matches!(key.as_str(), "selection" | "accessMode" | "interactionMode")),
        "Composer defaults contain unsupported options"
    );
    let mut defaults = value.clone();
    if defaults["accessMode"].is_null() {
        defaults["accessMode"] = json!("approval");
    }
    if defaults["interactionMode"].is_null() {
        defaults["interactionMode"] = json!("build");
    }
    validate_thread_with_proof(&defaults, proof)?;
    Ok(defaults)
}

/// Full target selection, not an arbitrary JSON patch. No storage mutation occurs here.
pub fn select(params: &Value, current: &Value) -> Result<Value> {
    select_with_proofs(params, current, None, None)
}
pub(crate) fn select_with_proofs(
    params: &Value,
    current: &Value,
    current_proof: Option<&crate::model_catalog::CodexEffortProof>,
    target_proof: Option<&crate::model_catalog::CodexEffortProof>,
) -> Result<Value> {
    ensure!(
        current["rustBotContext"].is_null(),
        "Bot selection is fixed for this conversation; create a new bot conversation"
    );
    crate::composer_policy::Policy::parse_with_effort_proof(
        current,
        crate::composer_policy::Origin::Ordinary,
        current_proof,
    )?
    .preflight_base()?;
    let fields = params
        .as_object()
        .context("Selection request must be an object")?;
    ensure!(
        fields.keys().all(|key| matches!(
            key.as_str(),
            "threadId"
                | "provider"
                | "model"
                | "accountId"
                | "effort"
                | "speed"
                | "accessMode"
                | "interactionMode"
                | "rememberComposerChoice"
        )),
        "Selection request contains unsupported options"
    );
    let provider = params["provider"]
        .as_str()
        .context("Provider must be text")?;
    Provider::from_name(provider)?;
    let model = match fields.get("model") {
        None => "default",
        Some(value) => value.as_str().context("Model must be text")?,
    };
    validate_model(model)?;
    let account = &params["accountId"];
    ensure!(
        account.is_null() || account.is_string(),
        "Account ID must be text or null"
    );
    ensure!(
        provider == "antigravity" || default_account(account),
        "Alternate provider accounts are not connected yet"
    );
    ensure!(
        current["selection"]["effort"].is_null() || fields.contains_key("effort"),
        "Choose effort explicitly; an existing effort cannot be silently cleared"
    );
    ensure!(
        current["selection"]["speed"].is_null() || fields.contains_key("speed"),
        "Choose speed explicitly; an existing speed cannot be silently cleared"
    );
    let mut selection = current["selection"].clone();
    if params["effort"].is_null() {
        if !current["selection"]["effort"].is_null() {
            selection.as_object_mut().unwrap().remove("effort");
        }
    } else {
        selection["effort"] = params["effort"].clone();
    }

    if params["speed"].is_null() {
        if !current["selection"]["speed"].is_null() {
            selection.as_object_mut().unwrap().remove("speed");
        }
    } else {
        selection["speed"] = params["speed"].clone();
    }

    selection["provider"] = json!(provider);
    selection["modelID"] = json!(model);
    if default_account(account) {
        selection.as_object_mut().unwrap().remove("accountID");
    } else {
        selection["accountID"] = account.clone();
    }
    let mut candidate = current.clone();
    candidate["selection"] = selection.clone();
    apply_modes_with_proof(params, &mut candidate, target_proof)?;
    Ok(selection)
}

/// Exact model forwarded to Launch: only the documented provider-default sentinel
/// omits a model override. An explicit custom ID is never silently substituted.
pub fn launch_model(selection: &Value) -> Result<Option<String>> {
    let model = selection["modelID"]
        .as_str()
        .context("Model ID must be text")?;
    validate_model(model)?;
    Ok((model != "default").then(|| model.to_owned()))
}

/// Adapter-only copy: older stored selections may spell the default account as
/// null, empty text or "default". Preserve the stored object/snapshot exactly;
/// resolve only those aliases before provider-specific account validation.
pub fn launch_selection(selection: &Value) -> Result<Value> {
    let mut selection = selection
        .as_object()
        .context("Invalid provider selection")?
        .clone();
    if selection.get("accountID").is_none_or(default_account) {
        selection.remove("accountID");
    }
    Ok(Value::Object(selection))
}

/// Explicit ordinary-thread repair: remove only saved effort, preserving every
/// other field and mode. This never authorizes a new effort or provider change.
pub(crate) fn repair_clear_effort(params: &Value, current: &Value) -> Result<Value> {
    repair_clear_option(params, current, "effort")
}
pub(crate) fn repair_clear_speed(params: &Value, current: &Value) -> Result<Value> {
    repair_clear_option(params, current, "speed")
}
/// Separate explicit exit when both saved options require revoked proof.
/// Neither single-option repair is allowed to remove the other option.
pub(crate) fn repair_clear_options(params: &Value, current: &Value) -> Result<Value> {
    ensure!(
        !current["selection"]["effort"].is_null() && !current["selection"]["speed"].is_null(),
        "Combined repair requires both saved effort and speed"
    );
    ensure!(
        params.get("effort").is_some_and(Value::is_null)
            && params.get("speed").is_some_and(Value::is_null),
        "Combined repair requires explicit effort: null and speed: null"
    );
    // Both removals were explicitly requested. Reuse the exact existing repair
    // validation for every remaining field, including bot/mode/unknown gates.
    let mut remaining = current.clone();
    remaining["selection"]
        .as_object_mut()
        .context("Invalid saved selection")?
        .remove("speed");
    let mut remaining_params = params.clone();
    remaining_params
        .as_object_mut()
        .context("Selection request must be an object")?
        .remove("speed");
    repair_clear_effort(&remaining_params, &remaining)
}
fn repair_clear_option(params: &Value, current: &Value, option: &str) -> Result<Value> {
    ensure!(
        current["rustBotContext"].is_null() && current["botID"].is_null(),
        "Bot selection is fixed; options cannot be repaired"
    );
    ensure!(
        !current["selection"][option].is_null() && params.get(option).is_some_and(Value::is_null),
        "Explicit null is required to clear the saved option"
    );
    let fields = params
        .as_object()
        .context("Selection request must be an object")?;
    ensure!(
        fields.keys().all(|key| matches!(
            key.as_str(),
            "threadId"
                | "provider"
                | "model"
                | "accountId"
                | "effort"
                | "speed"
                | "accessMode"
                | "interactionMode"
                | "rememberComposerChoice"
        )),
        "Selection request contains unsupported options"
    );
    for (parameter, field) in [
        ("provider", "provider"),
        ("model", "modelID"),
        ("accountId", "accountID"),
        (
            if option == "effort" {
                "speed"
            } else {
                "effort"
            },
            if option == "effort" {
                "speed"
            } else {
                "effort"
            },
        ),
    ] {
        if let Some(value) = fields.get(parameter) {
            ensure!(
                value == &current["selection"][field],
                "Option repair cannot change other selection fields"
            );
        }
    }
    for mode in ["accessMode", "interactionMode"] {
        if let Some(value) = fields.get(mode) {
            ensure!(
                value == &current[mode],
                "Option repair cannot change access or interaction mode"
            );
        }
    }
    let mut repaired = current.clone();
    repaired["selection"]
        .as_object_mut()
        .context("Invalid saved selection")?
        .remove(option);
    validate_thread_base(&repaired)?;
    Ok(repaired["selection"].clone())
}
