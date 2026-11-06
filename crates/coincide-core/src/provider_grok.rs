//! Grok Build's ACP v1 flavor, following the Swift GrokFlavor/XAI adapter.
//! Authentication reuses the configured credential source; it never signs up,
//! selects a different billing method, or starts an interactive fallback.
use super::*;
use std::collections::HashSet;

pub(super) fn run(
    launch: Launch,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    acp::run_grok(launch, images, commands, events)
}

pub(super) fn arguments() -> Vec<String> {
    ["--permission-mode", "default", "agent", "stdio"]
        .map(str::to_owned)
        .to_vec()
}

pub(super) fn configured_authentication() -> &'static str {
    authentication_for_api_key(
        crate::provider_configuration::effective_var("XAI_API_KEY")
            .is_some_and(|key| key.to_str().is_some_and(|key| !key.trim().is_empty())),
    )
}

fn authentication_for_api_key(has_key: bool) -> &'static str {
    if has_key {
        "xai.api_key"
    } else {
        "cached_token"
    }
}

pub(super) fn authentication_method(initialized: &Value, configured: &str) -> Option<String> {
    let methods = initialized["authMethods"].as_array();
    if methods.is_none_or(Vec::is_empty) {
        return Some(configured.into());
    }
    methods?
        .iter()
        .find(|method| {
            method["id"]
                .as_str()
                .or_else(|| method["methodId"].as_str())
                == Some(configured)
                && (method["type"].is_null() || method["type"] == "agent")
        })
        .map(|_| configured.into())
}

pub(super) fn method(name: &str) -> Option<&str> {
    name.strip_prefix('_').unwrap_or(name).strip_prefix("x.ai/")
}

pub(super) fn unwrap_params(params: &Value) -> &Value {
    if params.get("method").is_some() {
        params.get("params").unwrap_or(params)
    } else {
        params
    }
}

pub(super) fn foreground_update(params: &Value, prompt_id: &str) -> bool {
    params["_meta"]["promptId"]
        .as_str()
        .is_none_or(|id| id == prompt_id)
}

/// Some versions notify completion before (or instead of) answering prompt RPC.
/// Background wake identities and other sessions never finish the active turn.
pub(super) fn completion(frame: &Value, session_id: &str, prompt_id: &str) -> Result<bool> {
    let params = &frame["params"];
    if params["sessionId"]
        .as_str()
        .is_some_and(|id| id != session_id)
    {
        return Ok(false);
    }
    let (id, reason, detail) = match method(frame["method"].as_str().unwrap_or("")) {
        Some("session/prompt_complete") => (
            params["promptId"].as_str(),
            params["stopReason"].as_str(),
            params["agentResult"].as_str(),
        ),
        Some("session_notification" | "session/update")
            if params["update"]["sessionUpdate"] == "turn_completed" =>
        {
            let update = &params["update"];
            let id = update["prompt_id"]
                .as_str()
                .or_else(|| update["promptId"].as_str());
            if id.is_none() {
                return Ok(false);
            }
            (
                id,
                update["stop_reason"]
                    .as_str()
                    .or_else(|| update["stopReason"].as_str()),
                update["agent_result"].as_str(),
            )
        }
        _ => return Ok(false),
    };
    if id.is_some_and(|id| id != prompt_id) {
        return Ok(false);
    }
    validate_stop_reason(reason.unwrap_or("end_turn"), detail)?;
    Ok(true)
}

pub(super) fn validate_stop_reason(reason: &str, detail: Option<&str>) -> Result<()> {
    match reason {
        "rate_limit" => bail!("Grok usage limit reached. Try again later."),
        "error" => bail!("Grok turn failed: {}", detail.unwrap_or("provider error")),
        "cancelled" => bail!("Grok interrupted the turn before completion"),
        "end_turn" | "max_tokens" | "max_turn_requests" | "refusal" => Ok(()),
        _ => bail!("Grok returned an unknown stop reason: {reason}"),
    }
}

pub(super) struct Question {
    id: String,
    text: String,
    options: Vec<Value>,
    multiple: bool,
}

pub(super) fn questions(params: &Value) -> Result<Vec<Question>> {
    let params = unwrap_params(params);
    let values = params["questions"]
        .as_array()
        .context("Grok questions are missing")?;
    ensure!(
        !values.is_empty() && values.len() <= 20,
        "Grok supplied an invalid number of questions"
    );
    let mut seen = HashSet::new();
    let mut texts = HashSet::new();
    let mut result = Vec::new();
    for (index, value) in values.iter().enumerate() {
        let text = value["question"]
            .as_str()
            .filter(|text| !text.trim().is_empty())
            .context("Grok question text is missing")?;
        // The reply is keyed by question text; duplicate text cannot be answered unambiguously.
        ensure!(
            texts.insert(text.to_owned()),
            "Grok repeated a question text"
        );
        let base = value["id"]
            .as_str()
            .filter(|id| !id.trim().is_empty())
            .unwrap_or(text);
        let mut id = base.to_owned();
        if !seen.insert(id.clone()) {
            id = format!("{base}#{index}");
            ensure!(
                seen.insert(id.clone()),
                "Grok repeated a question identifier"
            );
        }
        let options = value["options"]
            .as_array()
            .map(|options| {
                options
                    .iter()
                    .filter(|option| {
                        option["label"]
                            .as_str()
                            .is_some_and(|label| !label.trim().is_empty())
                    })
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        result.push(Question {
            id,
            text: text.into(),
            options,
            multiple: value["multiSelect"] == true,
        });
    }
    Ok(result)
}

pub(super) fn question_params(questions: &[Question], frame: &Value) -> Value {
    json!({"providerFrame":frame,"questions":questions.iter().map(|question| json!({
        "id":question.id,"question":question.text,"options":question.options,"multiSelect":question.multiple
    })).collect::<Vec<_>>()})
}

pub(super) fn answer(questions: &[Question], reply: &Value) -> Result<Value> {
    if reply["decision"] == "cancel" {
        return Ok(json!({"outcome":"cancelled"}));
    }
    let answers = reply["answers"]
        .as_object()
        .context("Grok question answers are missing")?;
    let mut selections = serde_json::Map::new();
    let mut annotations = serde_json::Map::new();
    for question in questions {
        let values = answers
            .get(&question.id)
            .and_then(|value| value["answers"].as_array())
            .context("Every Grok question requires answers")?;
        let values = values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .context("Grok answers must contain text")
            })
            .collect::<Result<Vec<_>>>()?;
        ensure!(!values.is_empty(), "Every Grok question requires an answer");
        let chosen = values
            .iter()
            .filter_map(|value| {
                question
                    .options
                    .iter()
                    .find(|option| option["label"].as_str() == Some(*value))
            })
            .collect::<Vec<_>>();
        ensure!(
            question.multiple || chosen.len() <= 1,
            "Grok question allows only one selected option"
        );
        let notes = values
            .iter()
            .filter(|value| {
                !question
                    .options
                    .iter()
                    .any(|option| option["label"].as_str() == Some(**value))
            })
            .copied()
            .collect::<Vec<_>>();
        let labels = if chosen.is_empty() {
            vec![json!("Other")]
        } else {
            chosen
                .iter()
                .map(|option| option["label"].clone())
                .collect()
        };
        selections.insert(question.text.clone(), json!(labels));
        let mut annotation = json!({});
        if !question.multiple
            && let Some(preview) = chosen.iter().find_map(|option| option["preview"].as_str())
        {
            annotation["preview"] = json!(preview);
        }
        if !notes.is_empty() {
            annotation["notes"] = json!(notes.join("\n"));
        }
        if annotation
            .as_object()
            .is_some_and(|object| !object.is_empty())
        {
            annotations.insert(question.text.clone(), annotation);
        }
    }
    let mut result = json!({"outcome":"accepted","answers":selections});
    if !annotations.is_empty() {
        result["annotations"] = json!(annotations);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn configured_authentication_never_falls_back_to_another_billing_method() {
        assert_eq!(authentication_for_api_key(false), "cached_token");
        assert_eq!(authentication_for_api_key(true), "xai.api_key");
        assert!(
            authentication_method(
                &json!({"authMethods":[{"id":"xai.api_key"}]}),
                "cached_token"
            )
            .is_none()
        );
        assert!(
            authentication_method(
                &json!({"authMethods":[{"id":"cached_token","type":"terminal"}]}),
                "cached_token"
            )
            .is_none()
        );
        assert_eq!(
            authentication_method(&json!({}), "cached_token").as_deref(),
            Some("cached_token")
        );
    }
    #[test]
    fn completion_requires_foreground_identity_and_preserves_failures() {
        for params in [
            json!({"sessionId":"other","promptId":"active","stopReason":"end_turn"}),
            json!({"sessionId":"session","promptId":"task-completed-background","stopReason":"end_turn"}),
        ] {
            assert!(
                !completion(
                    &json!({"method":"_x.ai/session/prompt_complete","params":params}),
                    "session",
                    "active"
                )
                .unwrap()
            );
        }
        assert!(!completion(&json!({"method":"x.ai/session_notification","params":{"sessionId":"session","update":{"sessionUpdate":"turn_completed"}}}), "session", "active").unwrap());
        assert!(completion(&json!({"method":"x.ai/session/prompt_complete","params":{"sessionId":"session","promptId":"active","stopReason":"cancelled"}}), "session", "active").is_err());
    }

    #[test]
    fn questions_preserve_typed_notes_and_option_previews() {
        let questions=questions(&json!({"questions":[{"id":"q","question":"Which?","options":[{"label":"A","preview":"plan A"}]}]})).unwrap();
        let result = answer(
            &questions,
            &json!({"answers":{"q":{"answers":["A","and keep the file"]}}}),
        )
        .unwrap();
        assert_eq!(
            result,
            json!({"outcome":"accepted","answers":{"Which?":["A"]},"annotations":{"Which?":{"preview":"plan A","notes":"and keep the file"}}})
        );
        let result = answer(&questions, &json!({"answers":{"q":{"answers":["custom"]}}})).unwrap();
        assert_eq!(result["answers"]["Which?"], json!(["Other"]));
    }
}
