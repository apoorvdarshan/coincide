//! Codex's async questions are completed message items, not pending RPCs.
//! Keep their provider identity and choices without borrowing the composer.
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

const OPEN: &str = "<send_user_message_question_reply>";
const CLOSE: &str = "</send_user_message_question_reply>";

/// Convert a provider-reported async question only after it is complete.
/// Invalid or oversized metadata leaves the original message visible.
pub(crate) fn observe(
    thread: &mut Value,
    item: &Value,
    native_session: &str,
    selection: &Value,
    transcript_start: usize,
) -> bool {
    if item["type"] != "agentMessage"
        || item["delivery"] != "async"
        || native_session.is_empty()
        || native_session.len() > 512
    {
        return false;
    }
    let Some(id) = item["id"].as_str().filter(|id| !id.is_empty()) else {
        return false;
    };
    let Some(questions) = item["questions"]
        .as_array()
        .filter(|questions| !questions.is_empty() && questions.len() <= 16)
    else {
        return false;
    };
    let mut converted = Vec::with_capacity(questions.len());
    for (index, question) in questions.iter().enumerate() {
        let Some(title) = question["title"]
            .as_str()
            .filter(|title| !title.trim().is_empty() && title.len() <= 16 * 1024)
        else {
            return false;
        };
        let options = match question.get("options") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(options)) if options.len() <= 32 => {
                let mut result = Vec::with_capacity(options.len());
                for option in options {
                    let Some(label) = option
                        .as_str()
                        .filter(|label| !label.trim().is_empty() && label.len() <= 4096)
                    else {
                        return false;
                    };
                    result.push(json!({"label": label}));
                }
                result
            }
            _ => return false,
        };
        converted.push(json!({
            "id": json!(["request_user_input_async", id, index]).to_string(),
            "question": title,
            "options": options,
            "allowsFreeText": true,
        }));
    }
    let Some(items) = thread["items"].as_array() else {
        return false;
    };
    if !items
        .iter()
        .skip(transcript_start)
        .any(|row| row["externalID"] == id)
    {
        return false;
    }
    let mut existing = thread["rustAsyncQuestions"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    if existing.iter().any(|q| q["requestId"] == id) {
        return false;
    }
    while existing.len() >= 64 {
        let Some(removable) = existing.iter().position(|question| {
            question["status"] == "dismissed"
                || (question["status"] == "submitted"
                    && thread["rustMessageQueue"].as_array().is_none_or(|rows| {
                        rows.iter()
                            .find(|row| row["id"] == question["queueID"])
                            .is_none_or(|row| row["state"] == "completed")
                    }))
        }) else {
            return false;
        };
        existing.remove(removable);
    }
    let params = json!({"questions": converted});
    let request = json!({
        "requestId": id,
        "method": "item/tool/requestUserInput",
        "provider": "codex",
        "params": params,
        "rustAsync": true,
        "nativeSession": native_session,
        "accountID": selection["accountID"],
        "status": "pending",
    });
    existing.push(request);
    thread["rustAsyncQuestions"] = Value::Array(existing);
    let row = thread["items"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .skip(transcript_start)
        .rev()
        .find(|row| row["externalID"] == id)
        .unwrap();
    row["kind"] = json!("question");
    row["text"] = json!(params.to_string());
    row["rustAsync"] = json!(true);
    row["status"] = json!("pending");
    true
}

/// The card survives a finished turn or app restart; the synchronous RPC
/// requests are supplied separately by the running provider.
pub fn pending(thread: &Value) -> Vec<Value> {
    thread["rustAsyncQuestions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|request| request["rustAsync"] == true && request["status"] == "pending")
        .cloned()
        .collect()
}

/// Removing an unsent or failed reply restores the question, so the user can
/// explicitly choose a different answer. Uncertain in-flight replies stay closed.
pub(crate) fn restore_removed_reply(thread: &mut Value, queue_id: &str) {
    let Some(request) = thread["rustAsyncQuestions"]
        .as_array_mut()
        .and_then(|requests| {
            requests
                .iter_mut()
                .find(|request| request["queueID"] == queue_id && request["status"] == "submitted")
        })
    else {
        return;
    };
    let id = request["requestId"].as_str().unwrap_or("").to_owned();
    request["status"] = json!("pending");
    request.as_object_mut().unwrap().remove("queueID");
    if let Some(row) = thread["items"].as_array_mut().and_then(|items| {
        items.iter_mut().rev().find(|row| {
            row["kind"] == "question" && row["rustAsync"] == true && row["externalID"] == id
        })
    }) {
        row["status"] = json!("pending");
        row.as_object_mut().unwrap().remove("answers");
    }
}

/// Use the same contextual reply envelope and identity as Codex's native UI.
pub(crate) fn reply(request: &Value, answers: &Value) -> Result<String> {
    let questions = request["params"]["questions"]
        .as_array()
        .context("Question is unavailable")?;
    let answers = answers.as_object().context("Answers are unavailable")?;
    ensure!(
        questions.len() == answers.len() && !questions.is_empty(),
        "Answer every question"
    );
    let mut replies = Vec::with_capacity(questions.len());
    let mut fallback = Vec::with_capacity(questions.len());
    let mut oversized_id = false;
    for question in questions {
        let id = question["id"]
            .as_str()
            .context("Question has no identity")?;
        let title = question["question"]
            .as_str()
            .context("Question has no title")?;
        let values = answers
            .get(id)
            .and_then(|a| a["answers"].as_array())
            .context("Answer every question")?;
        ensure!(values.len() == 1, "Provide one answer for each question");
        let answer = values[0]
            .as_str()
            .filter(|s| !s.trim().is_empty() && s.len() <= 65536)
            .context("Answer must be nonempty and fit within 64 KiB")?;
        let mut end = title.len().min(512);
        while !title.is_char_boundary(end) {
            end -= 1;
        }
        let title = title[..end].replace(['\n', '\r'], " ");
        oversized_id |= id.len() > 512;
        fallback.push(format!("> {title}\n\n{answer}"));
        replies.push(json!({"questionItemId":id,"question":title,"answer":answer}));
    }
    if oversized_id {
        return Ok(fallback.join("\n\n"));
    }
    Ok(format!("{OPEN}\n{}\n{CLOSE}", Value::Array(replies)))
}

/// Hide protocol framing in the chat and queue; the actual sent payload is unchanged.
pub fn display_reply(text: &str) -> Option<String> {
    let body = text.strip_prefix(OPEN)?.strip_suffix(CLOSE)?.trim();
    let rows: Vec<Value> = serde_json::from_str(body).ok()?;
    if rows.is_empty() {
        return None;
    }
    let answers = rows
        .iter()
        .map(|row| row["answer"].as_str())
        .collect::<Option<Vec<_>>>()?;
    Some(answers.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_questions_are_structured_and_replies_match_codex() {
        let mut thread = json!({"items":[{"id":"row","kind":"assistant","externalID":"call-1","text":"fallback"}]});
        let item = json!({"type":"agentMessage","delivery":"async","id":"call-1","questions":[
            {"title":"Choose one","options":["First","Second"]},{"title":"Explain","options":null}
        ]});
        assert!(observe(
            &mut thread,
            &item,
            "session-1",
            &json!({"accountID":"a"}),
            0
        ));
        assert!(!observe(
            &mut thread,
            &item,
            "session-1",
            &json!({"accountID":"a"}),
            0
        ));
        let request = &pending(&thread)[0];
        assert_eq!(
            request["params"]["questions"][0]["options"][0]["label"],
            "First"
        );
        assert_eq!(thread["items"][0]["kind"], "question");
        let id0 = request["params"]["questions"][0]["id"].as_str().unwrap();
        let id1 = request["params"]["questions"][1]["id"].as_str().unwrap();
        let answer = reply(
            request,
            &json!({id0:{"answers":["Second"]}, id1:{"answers":["My answer"]}}),
        )
        .unwrap();
        assert_eq!(display_reply(&answer).unwrap(), "Second\nMy answer");
        assert!(answer.contains("request_user_input_async"));
        assert!(reply(request, &json!({id0:{"answers":["Second"]}})).is_err());
    }

    #[test]
    fn malformed_or_regular_messages_remain_untouched() {
        let original = json!({"items":[{"externalID":"x","kind":"assistant","text":"original"}]});
        for item in [
            json!({"type":"agentMessage","id":"x","questions":[{"title":"Q"}]}),
            json!({"type":"agentMessage","delivery":"async","id":"x","questions":[{"title":"Q","options":[1]}]}),
        ] {
            let mut thread = original.clone();
            assert!(!observe(&mut thread, &item, "session", &json!({}), 0));
            assert_eq!(thread, original);
        }
        assert!(
            display_reply(
                "<send_user_message_question_reply>not json</send_user_message_question_reply>"
            )
            .is_none()
        );
    }

    #[test]
    fn oversized_question_identity_uses_the_codex_plain_text_fallback() {
        let id = "x".repeat(513);
        let request = json!({"params":{"questions":[{"id":id,"question":"Choose\nnow"}]}});
        let answers = json!({id:{"answers":["Yes"]}});
        assert_eq!(reply(&request, &answers).unwrap(), "> Choose now\n\nYes");
    }

    #[test]
    fn old_resolved_questions_do_not_prevent_future_questions() {
        let requests = (0..64)
            .map(|n| json!({"requestId":format!("old-{n}"),"status":"dismissed"}))
            .collect::<Vec<_>>();
        let mut thread = json!({"items":[{"externalID":"new","kind":"assistant"}],"rustAsyncQuestions":requests});
        let item = json!({"type":"agentMessage","id":"new","delivery":"async","questions":[{"title":"Next"}]});
        assert!(observe(&mut thread, &item, "session", &json!({}), 0));
        assert_eq!(thread["rustAsyncQuestions"].as_array().unwrap().len(), 64);
        assert_eq!(pending(&thread)[0]["requestId"], "new");
        for request in thread["rustAsyncQuestions"].as_array_mut().unwrap() {
            request["status"] = json!("pending");
        }
        thread["items"]
            .as_array_mut()
            .unwrap()
            .push(json!({"externalID":"another","kind":"assistant"}));
        let before = thread.clone();
        let another = json!({"type":"agentMessage","id":"another","delivery":"async","questions":[{"title":"Next"}]});
        assert!(!observe(&mut thread, &another, "session", &json!({}), 0));
        assert_eq!(thread, before);
    }
}
