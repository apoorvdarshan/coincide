//! Persisted outgoing text, image and reference queue. A dispatch claim is saved before starting a
//! provider; uncertain claims are never replayed automatically after a restart.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub text: String,
    pub selection: Value,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub context: Value,
    #[serde(default, rename = "rustImages", skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<crate::attachments::StoredImage>,
    pub state: State,
    pub created_at: f64,
    /// The user dismissed an in-flight row. Its claim remains durable until
    /// the provider acknowledges or finishes so it cannot be dispatched twice.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub dismissed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// A question reply must never migrate to a different native session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_question_session: Option<String>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Pending,
    Dispatching,
    Completed,
    Failed,
    Interrupted,
}

pub fn read(thread: &Value) -> Result<Vec<Message>> {
    if thread["rustMessageQueue"].is_null() {
        return Ok(Vec::new());
    }
    ensure!(
        serde_json::to_vec(&thread["rustMessageQueue"])?.len() <= 2 * 1024 * 1024,
        "Saved message queue exceeds 2 MiB"
    );
    let messages: Vec<Message> = serde_json::from_value(thread["rustMessageQueue"].clone())
        .context("Invalid saved message queue")?;
    ensure!(messages.len() <= 32, "Saved message queue is too large");
    Ok(messages)
}

/// A consistent desktop queue view, whether the saved thread was read on the
/// UI thread or decoded by the background conversation reader.
pub fn native_snapshot(thread: &Value, enabled: bool) -> Result<Value> {
    let messages = read(thread)?
        .into_iter()
        .filter(|message| !message.dismissed)
        .collect::<Vec<_>>();
    let error = if messages
        .iter()
        .any(|message| message.state != State::Completed)
    {
        thread["rustQueueError"].clone()
    } else {
        Value::Null
    };
    Ok(serde_json::json!({
        "messages": messages,
        "rawQueue": thread["rustMessageQueue"],
        "error": error,
        "enabled": enabled,
    }))
}

pub fn write(thread: &mut Value, messages: &[Message]) -> Result<()> {
    thread["rustMessageQueue"] = serde_json::to_value(messages)?;
    Ok(())
}
pub fn add(thread: &mut Value, text: &str) -> Result<Message> {
    ensure!(
        thread["rustDraftImages"]
            .as_array()
            .is_none_or(Vec::is_empty),
        "Attach images through the native composer follow-up"
    );
    add_payload(thread, text, Value::Null, Vec::new())
}
/// Payload is data only. Execution always validates the exact owned claim and
/// prepares stored images inside the selected data directory before launch.
pub(crate) fn add_payload(
    thread: &mut Value,
    text: &str,
    context: Value,
    images: Vec<crate::attachments::StoredImage>,
) -> Result<Message> {
    add_payload_with_id(thread, Uuid::new_v4(), text, context, images)
}

pub(crate) fn add_payload_with_id(
    thread: &mut Value,
    id: Uuid,
    text: &str,
    context: Value,
    images: Vec<crate::attachments::StoredImage>,
) -> Result<Message> {
    crate::composer_context::validate(&context)?;
    ensure!(
        text.len() <= 256 * 1024
            && (!text.trim().is_empty()
                || crate::composer_context::has_context(&context)
                || !images.is_empty()),
        "Queued message must contain text, images or context and fit within 256 KiB"
    );
    ensure!(
        images.len() <= 20
            && images
                .iter()
                .try_fold(0u64, |n, image| n.checked_add(image.byte_len))
                .is_some_and(|n| n <= 20 * 1024 * 1024),
        "Queued images exceed safe limits"
    );
    let mut messages = read(thread)?;
    let id = id.to_string();
    ensure!(
        messages.iter().all(|message| message.id != id),
        "This message already has a queue entry"
    );
    let mut rows = thread["rustMessageQueue"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    while messages.len() >= 32 {
        let removable = messages
            .iter()
            .position(|m| {
                matches!(
                    m.state,
                    State::Completed | State::Failed | State::Interrupted
                )
            })
            .context("At most 32 messages can be queued per thread")?;
        messages.remove(removable);
        rows.remove(removable);
    }
    ensure!(
        messages.iter().map(|m| m.text.len()).sum::<usize>() + text.len() <= 512 * 1024,
        "Queued text exceeds 512 KiB"
    );
    let message = Message {
        id,
        text: text.into(),
        selection: thread["selection"].clone(),
        context,
        images,
        state: State::Pending,
        created_at: crate::store::swift_timestamp(),
        dismissed: false,
        error: None,
        codex_question_session: None,
    };
    rows.push(serde_json::to_value(&message)?);
    ensure!(
        serde_json::to_vec(&rows)?.len() <= 2 * 1024 * 1024,
        "Queued payloads exceed 2 MiB"
    );
    thread["rustMessageQueue"] = Value::Array(rows);
    Ok(message)
}
pub fn finish(thread: &mut Value, id: &str, state: State, error: Option<&str>) -> Result<()> {
    let messages = read(thread)?;
    let matches = messages
        .iter()
        .enumerate()
        .filter(|(_, message)| message.id == id)
        .collect::<Vec<_>>();
    ensure!(
        matches.len() == 1,
        "Message queue claim is missing or ambiguous"
    );
    let (index, message) = matches[0];
    ensure!(
        message.state == State::Dispatching,
        "Message queue claim is not active"
    );
    let row = thread["rustMessageQueue"]
        .as_array_mut()
        .context("Invalid saved message queue")?
        .get_mut(index)
        .context("Message queue claim is missing")?;
    row["state"] = serde_json::to_value(state)?;
    if let Some(error) = error {
        row["error"] = Value::String(error.chars().take(1024).collect());
    } else if let Some(row) = row.as_object_mut() {
        row.remove("error");
    }
    if state == State::Completed
        && let Some(item) = thread
            .get_mut("items")
            .and_then(Value::as_array_mut)
            .and_then(|items| {
                items
                    .iter_mut()
                    .rev()
                    .find(|item| item["rustQueueMessageID"] == id)
            })
        && let Some(item) = item.as_object_mut()
    {
        item.remove("rustAwaitingQueueDelivery");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn rejects_empty_oversized_and_image_drafts_without_mutation() {
        let mut thread = json!({"selection":{"provider":"claude"},"rustDraftImages":[]});
        for text in [String::new(), " ".into(), "x".repeat(1024 * 1024 + 1)] {
            let before = thread.clone();
            assert!(add(&mut thread, &text).is_err());
            assert_eq!(thread, before);
        }
        thread["rustDraftImages"] = json!([{"id":"kept"}]);
        let before = thread.clone();
        assert!(add(&mut thread, "hello").is_err());
        assert_eq!(thread, before);
    }
    #[test]
    fn pending_messages_are_never_evicted_and_claims_settle_once() {
        let mut thread = json!({"selection":{"provider":"claude"}});
        for i in 0..32 {
            add(&mut thread, &format!("message {i}")).unwrap();
        }
        let before = thread.clone();
        assert!(add(&mut thread, "overflow").is_err());
        assert_eq!(thread, before);
        let mut entries = read(&thread).unwrap();
        entries[0].state = State::Dispatching;
        let id = entries[0].id.clone();
        write(&mut thread, &entries).unwrap();
        finish(&mut thread, &id, State::Completed, None).unwrap();
        assert!(finish(&mut thread, &id, State::Completed, None).is_err());
        add(&mut thread, "new").unwrap();
        let entries = read(&thread).unwrap();
        assert_eq!(entries.len(), 32);
        assert_eq!(entries[0].text, "message 1");
        assert_eq!(entries.last().unwrap().text, "new");
    }
}

#[cfg(test)]
mod raw_finish_tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn finishing_a_claim_changes_only_its_known_state_and_error_fields() {
        let mut thread = json!({"selection":{"provider":"codex"},"future":9});
        let first = add(&mut thread, "first").unwrap();
        add(&mut thread, "second").unwrap();
        thread["rustMessageQueue"][0]["state"] = json!("dispatching");
        thread["rustMessageQueue"][0]["future"] = json!({"keep":7});
        thread["rustMessageQueue"][1]["future"] = json!({"keep":8});
        let mut expected = thread.clone();
        expected["rustMessageQueue"][0]["state"] = json!("completed");
        finish(&mut thread, &first.id, State::Completed, None).unwrap();
        assert_eq!(thread, expected);
    }
    #[test]
    fn only_an_accepted_claim_releases_its_transcript_opener() {
        let mut thread = json!({"selection":{"provider":"codex"}});
        let first = add(&mut thread, "first").unwrap();
        let next = add(&mut thread, "next").unwrap();
        thread["items"] = json!([
            {"id":"older","text":"first"},
            {"id":"one","rustQueueMessageID":first.id,"rustAwaitingQueueDelivery":true},
            {"id":"two","rustQueueMessageID":next.id,"rustAwaitingQueueDelivery":true}
        ]);
        thread["rustMessageQueue"][0]["state"] = json!("dispatching");
        finish(&mut thread, &first.id, State::Completed, None).unwrap();
        assert!(
            thread["items"][1]
                .get("rustAwaitingQueueDelivery")
                .is_none()
        );
        assert_eq!(thread["items"][2]["rustAwaitingQueueDelivery"], true);
        thread["rustMessageQueue"][1]["state"] = json!("dispatching");
        finish(&mut thread, &next.id, State::Interrupted, None).unwrap();
        assert_eq!(thread["items"][2]["rustAwaitingQueueDelivery"], true);
        assert_eq!(thread["items"][0], json!({"id":"older","text":"first"}));
    }

    #[test]
    fn native_message_keeps_its_identity_and_cannot_be_enqueued_twice() {
        let id = Uuid::new_v4();
        let mut thread = json!({"selection":{"provider":"codex"}});
        let row = add_payload_with_id(&mut thread, id, "hello", Value::Null, vec![]).unwrap();
        assert_eq!(row.id, id.to_string());
        let before = thread.clone();
        assert!(add_payload_with_id(&mut thread, id, "hello", Value::Null, vec![]).is_err());
        assert_eq!(thread, before);
    }

    #[test]
    fn adding_payload_preserves_neighbor_unknowns_and_rejects_invalid_context_atomically() {
        let mut thread = json!({"selection":{"provider":"codex"}});
        add(&mut thread, "existing").unwrap();
        thread["rustMessageQueue"][0]["future"] = json!({"keep":9});
        let original = thread["rustMessageQueue"][0].clone();
        let context = json!([{"id":Uuid::new_v4(),"kind":"quote","text":"Only context, no text","future":{"keep":7}}]);
        add_payload(&mut thread, "", context.clone(), Vec::new()).unwrap();
        assert_eq!(thread["rustMessageQueue"][0], original);
        assert_eq!(thread["rustMessageQueue"][1]["context"], context);
        let before = thread.clone();
        assert!(
            add_payload(
                &mut thread,
                "",
                json!([{"kind":"future","opaque":true}]),
                Vec::new()
            )
            .is_err()
        );
        assert_eq!(thread, before);
    }
}
