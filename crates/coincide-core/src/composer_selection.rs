//! Pure, static runtime selection contract. No provider discovery or credential access.
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
            "effort":{"supported":false,"reason":"This runtime does not apply reasoning effort."},
            "speed":{"supported":false,"reason":"This runtime does not apply speed selections."},
            "accessModes":["approval"],"interactionModes":["build"]})
    }).collect::<Vec<_>>();
    json!({"provenance":"static_runtime_contract","authenticationChecked":false,"modelsDiscovered":false,
        "providers":providers,"locked":false,"lockReason":null})
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

fn validate_mode(value: &Value, supported: &str) -> Result<()> {
    ensure!(
        value.is_null() || value.as_str() == Some(supported),
        "This runtime supports {supported} mode only"
    );
    Ok(())
}

/// Reject unsupported stored metadata before any edit/send can silently discard it.
/// Named Antigravity account configuration is validated separately by the engine.
pub fn validate_thread(thread: &Value) -> Result<()> {
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
    ensure!(
        thread["selection"]["effort"].is_null() && thread["selection"]["speed"].is_null(),
        "Reasoning effort/speed is unsupported; selection was not changed"
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
    validate_mode(&thread["accessMode"], "approval")?;
    validate_mode(&thread["interactionMode"], "build")?;
    Ok(())
}

/// Full target selection, not an arbitrary JSON patch. No storage mutation occurs here.
pub fn select(params: &Value, current: &Value) -> Result<Value> {
    ensure!(
        current["rustBotContext"].is_null(),
        "Bot selection is fixed for this conversation; create a new bot conversation"
    );
    validate_thread(current)?;
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
        )),
        "Selection request contains unsupported options"
    );
    ensure!(
        params["effort"].is_null() && params["speed"].is_null(),
        "Reasoning effort/speed is unsupported"
    );
    for (key, supported) in [("accessMode", "approval"), ("interactionMode", "build")] {
        if let Some(value) = fields.get(key) {
            ensure!(
                value.as_str() == Some(supported),
                "This runtime supports {supported} mode only"
            );
        }
    }
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
    let mut selection = current["selection"].clone();
    selection["provider"] = json!(provider);
    selection["modelID"] = json!(model);
    if default_account(account) {
        selection.as_object_mut().unwrap().remove("accountID");
    } else {
        selection["accountID"] = account.clone();
    }
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
