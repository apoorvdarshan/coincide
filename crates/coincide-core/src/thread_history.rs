//! Transcript-only branches. These functions never mutate the source, touch
//! files, contact providers, or rewind a provider session/worktree.
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};
use uuid::Uuid;

pub struct HistoryOptions<'a> {
    pub new_thread_id: &'a str,
    /// Seconds since 2001-01-01, matching the persisted Swift date format.
    pub now: f64,
    /// The user/agent notice that opened the currently running turn, if any.
    pub running_turn_id: Option<&'a str>,
    /// Notices that open autonomous agent turns. Steered user messages do not.
    pub turn_openers: &'a [String],
}

#[derive(Debug)]
pub struct HistoryPlan {
    pub thread: Value,
    pub lineage: Value,
    /// Original transcript item IDs mapped to fresh IDs. Attachment IDs remain
    /// unchanged: they identify immutable stored files, not provider state.
    pub item_ids: BTreeMap<String, String>,
}

/// Copy the entire settled turn containing the selected item, or all settled
/// history when no item is selected. A missing running boundary is an error,
/// never permission to copy a possibly live transcript.
pub fn fork_through_turn(
    source: &Value,
    through_item_id: Option<&str>,
    options: HistoryOptions<'_>,
) -> Result<HistoryPlan> {
    let items = validated_items(source, &options)?;
    let limit = match options.running_turn_id {
        Some(id) => {
            item_index(items, id).context("Running turn boundary is not in the transcript")?
        }
        None => items.len(),
    };
    let openers = options
        .turn_openers
        .iter()
        .map(|id| Uuid::parse_str(id).context("Invalid agent turn opener"))
        .collect::<Result<HashSet<_>>>()?;
    let end = if let Some(selected) = through_item_id {
        let index = item_index(items, selected)?;
        ensure!(
            index < limit,
            "Wait for the selected turn to finish before branching"
        );
        (index + 1..limit)
            .find(|index| opens_turn(&items[*index], &openers))
            .unwrap_or(limit)
    } else {
        limit
    };
    ensure!(end > 0, "There is no settled conversation to branch");
    make_plan(source, &items[..end], None, options)
}

/// Create a separate branch before a selected user message, restoring that
/// message into its draft. This deliberately does not truncate the source.
pub fn edit_from_user(
    source: &Value,
    user_item_id: &str,
    options: HistoryOptions<'_>,
) -> Result<HistoryPlan> {
    let items = validated_items(source, &options)?;
    ensure!(
        options.running_turn_id.is_none(),
        "Stop the running turn before editing an earlier message"
    );
    let index = item_index(items, user_item_id)?;
    let item = &items[index];
    ensure!(item["kind"] == "user", "Select a user message to edit");
    ensure!(
        item["text"].is_string() || item["text"].is_null(),
        "User message text is malformed"
    );
    for key in ["context", "attachments", "rustImages"] {
        ensure!(
            item[key].is_array() || item[key].is_null(),
            "User message {key} metadata is malformed"
        );
    }
    make_plan(source, &items[..index], Some(item), options)
}

fn validated_items<'a>(source: &'a Value, options: &HistoryOptions<'_>) -> Result<&'a [Value]> {
    ensure!(source.is_object(), "Thread must be an object");
    let source_id = Uuid::parse_str(source["id"].as_str().context("Thread has no ID")?)?;
    let new_id = Uuid::parse_str(options.new_thread_id).context("Invalid new thread ID")?;
    ensure!(
        source_id != new_id,
        "A branch must have a different thread ID"
    );
    ensure!(options.now.is_finite(), "Branch timestamp must be finite");
    let items = source["items"]
        .as_array()
        .context("Thread transcript is malformed")?;
    let mut ids = HashSet::new();
    for item in items {
        ensure!(item.is_object(), "Transcript item must be an object");
        let id = Uuid::parse_str(item["id"].as_str().context("Transcript item has no ID")?)
            .context("Invalid transcript item ID")?;
        ensure!(ids.insert(id), "Transcript contains duplicate item IDs");
    }
    Ok(items)
}

fn item_index(items: &[Value], id: &str) -> Result<usize> {
    let id = Uuid::parse_str(id).context("Invalid transcript boundary ID")?;
    items
        .iter()
        .position(|item| item["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(id))
        .context("Selected item is no longer in the conversation")
}

fn opens_turn(item: &Value, openers: &HashSet<Uuid>) -> bool {
    (item["kind"] == "user" && item["steered"] != true)
        || item["id"]
            .as_str()
            .and_then(|id| Uuid::parse_str(id).ok())
            .is_some_and(|id| openers.contains(&id))
}

fn make_plan(
    source: &Value,
    selected: &[Value],
    edited: Option<&Value>,
    options: HistoryOptions<'_>,
) -> Result<HistoryPlan> {
    let item_ids = selected
        .iter()
        .map(|item| {
            (
                item["id"].as_str().expect("validated ID").to_owned(),
                Uuid::new_v4().to_string().to_uppercase(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let remapped_ids = item_ids
        .iter()
        .map(|(old, new)| (Uuid::parse_str(old).expect("validated ID"), new.clone()))
        .collect::<HashMap<_, _>>();
    let copied = selected
        .iter()
        .map(|item| {
            let mut copy = item.clone();
            let object = copy.as_object_mut().expect("validated item");
            object.insert(
                "id".into(),
                json!(item_ids[item["id"].as_str().expect("validated ID")]),
            );
            clear_runtime_fields(object);
            for key in ["approval", "questions"] {
                if let Some(value) = object.get_mut(key).and_then(Value::as_object_mut) {
                    clear_runtime_fields(value);
                }
            }
            for key in [
                "parentItemID",
                "replyToItemID",
                "userItemID",
                "turnOpenerID",
            ] {
                if let Some(reference) = object.get(key).and_then(Value::as_str).map(str::to_owned)
                {
                    let replacement = Uuid::parse_str(&reference)
                        .ok()
                        .and_then(|id| remapped_ids.get(&id))
                        .cloned();
                    if let Some(replacement) = replacement {
                        object.insert(key.into(), json!(replacement));
                    } else {
                        object.remove(key);
                    }
                }
            }
            if matches!(
                item["status"].as_str(),
                Some("running" | "waiting" | "pending" | "inProgress")
            ) {
                object.insert(
                    "status".into(),
                    json!(
                        if matches!(item["kind"].as_str(), Some("approval" | "question")) {
                            "declined"
                        } else {
                            "failed"
                        }
                    ),
                );
                object.insert("completedAt".into(), json!(options.now));
            }
            copy
        })
        .collect::<Vec<_>>();
    let lineage = json!({
        "parentThreadID":source["id"], "parentTitle":source["title"].as_str().unwrap_or("Untitled"),
        "parentItemID":selected.last().map(|item|item["id"].clone()),
        "forkItemID":copied.last().map(|item|item["id"].clone()), "forkedAt":options.now,
        "editedItemID":edited.map(|item|item["id"].clone()),
        "mode":if edited.is_some(){"edit-draft-branch"}else{"settled-turn-branch"},
        "providerRewound":false,"filesRewound":false,
    });
    let mut thread = source.clone();
    let object = thread.as_object_mut().expect("validated thread");
    clear_runtime_fields(object);
    for key in [
        "importedSession",
        "snoozedUntil",
        "rustQueueError",
        "rustHistory",
        "titleCheckTurns",
        "titleCheckedAt",
        "titleRefreshes",
        "titledByUser",
    ] {
        object.remove(key);
    }
    object.insert(
        "id".into(),
        json!(
            Uuid::parse_str(options.new_thread_id)?
                .to_string()
                .to_uppercase()
        ),
    );
    object.insert(
        "title".into(),
        json!(format!(
            "{} ({})",
            source["title"].as_str().unwrap_or("Untitled"),
            if edited.is_some() { "edit" } else { "fork" }
        )),
    );
    object.insert("items".into(), json!(copied));
    object.insert("sessions".into(), json!({}));
    object.insert("accountSessions".into(), json!({}));
    object.insert("rustMessageQueue".into(), json!([]));
    object.insert("isPinned".into(), json!(false));
    object.insert("isArchived".into(), json!(false));
    object.insert("createdAt".into(), json!(options.now));
    object.insert("updatedAt".into(), json!(options.now));
    object.insert(
        "draft".into(),
        json!(edited.and_then(|item| item["text"].as_str()).unwrap_or("")),
    );
    object.insert(
        "draftContext".into(),
        edited
            .and_then(|item| item.get("context"))
            .filter(|value| value.is_array())
            .cloned()
            .unwrap_or(json!([])),
    );
    object.insert(
        "rustDraftImages".into(),
        edited
            .and_then(|item| item.get("rustImages"))
            .filter(|value| value.is_array())
            .cloned()
            .unwrap_or(json!([])),
    );
    // Legacy attachment paths are retained as inert metadata. Only the existing
    // StoredImage validation/import flow may turn them into actual uploads.
    object.remove("rustLegacyDraftAttachments");
    if let Some(attachments) = edited
        .and_then(|item| item.get("attachments"))
        .filter(|value| value.is_array())
    {
        object.insert("rustLegacyDraftAttachments".into(), attachments.clone());
    }
    object.insert("rustHistory".into(), lineage.clone());
    Ok(HistoryPlan {
        thread,
        lineage,
        item_ids,
    })
}

fn clear_runtime_fields(object: &mut serde_json::Map<String, Value>) {
    for key in [
        "externalID",
        "externalId",
        "sessionID",
        "sessionId",
        "providerSessionID",
        "providerSessionId",
        "requestID",
        "requestId",
        "rpcID",
        "rpcId",
        "turnID",
        "turnId",
        "threadID",
        "threadId",
        "approvalID",
        "approvalId",
        "pendingRequest",
        "pendingRequests",
        "isStreaming",
        "runningTurnID",
        "runningTurnId",
        "activeTurnID",
        "activeTurnId",
    ] {
        object.remove(key);
    }
}
