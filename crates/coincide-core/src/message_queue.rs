//! Persisted outgoing text queue. A dispatch claim is saved before starting a
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
    pub state: State,
    pub created_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
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
    let messages: Vec<Message> = serde_json::from_value(thread["rustMessageQueue"].clone())
        .context("Invalid saved message queue")?;
    ensure!(messages.len() <= 32, "Saved message queue is too large");
    Ok(messages)
}
pub fn write(thread: &mut Value, messages: &[Message]) -> Result<()> {
    thread["rustMessageQueue"] = serde_json::to_value(messages)?;
    Ok(())
}
pub fn add(thread: &mut Value, text: &str) -> Result<Message> {
    ensure!(
        !text.trim().is_empty() && text.len() <= 256 * 1024,
        "Queued text must be nonempty and fit within 256 KiB"
    );
    ensure!(
        thread["rustDraftImages"]
            .as_array()
            .is_none_or(Vec::is_empty),
        "Image queueing is not connected yet; send or remove the draft images first"
    );
    let mut messages = read(thread)?;
    // Retain recent terminal entries where space permits; never evict pending work.
    while messages.len() >= 32 {
        let removable = messages.iter().position(|m| {
            matches!(
                m.state,
                State::Completed | State::Failed | State::Interrupted
            )
        });
        ensure!(
            removable.is_some(),
            "At most 32 messages can be queued per thread"
        );
        messages.remove(removable.unwrap());
    }
    ensure!(
        messages.iter().map(|m| m.text.len()).sum::<usize>() + text.len() <= 512 * 1024,
        "Queued text exceeds 512 KiB"
    );
    let message = Message {
        id: Uuid::new_v4().to_string(),
        text: text.into(),
        selection: thread["selection"].clone(),
        state: State::Pending,
        created_at: crate::store::swift_timestamp(),
        error: None,
    };
    messages.push(message.clone());
    write(thread, &messages)?;
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
}
