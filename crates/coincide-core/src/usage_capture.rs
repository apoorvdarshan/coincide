//! Codex associated-turn latest-request snapshots. Neither cumulative thread
//! totals nor context snapshots are additive turn totals or billing estimates.
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq)]
struct SourceId(String);
impl SourceId {
    fn parse(value: &Value) -> Option<Self> {
        let value = value.as_str()?;
        (!value.is_empty() && value.len() <= 512 && !value.chars().any(char::is_control))
            .then(|| Self(value.into()))
    }
}
#[derive(Default)]
pub(crate) struct Capture {
    thread: Option<SourceId>,
    turn: Option<SourceId>,
    raw: Option<Value>,
    finished: bool,
}
#[derive(Debug)]
pub(crate) struct Snapshot {
    thread: SourceId,
    turn: SourceId,
    raw: Value,
    outcome: String,
}
impl Capture {
    pub(crate) fn bind_thread(&mut self, id: &str) -> bool {
        if self.thread.is_some() {
            return false;
        }
        self.thread = SourceId::parse(&json!(id));
        self.thread.is_some()
    }
    pub(crate) fn bind_turn(&mut self, id: &Value) -> bool {
        if self.thread.is_none() || self.turn.is_some() || self.finished {
            return false;
        }
        self.turn = SourceId::parse(id);
        self.turn.is_some()
    }
    pub(crate) fn matches_completion(&self, params: &Value) -> bool {
        !self.finished
            && self.thread.is_some()
            && self.turn.is_some()
            && SourceId::parse(&params["threadId"]) == self.thread
            && SourceId::parse(&params["turn"]["id"]) == self.turn
    }
    pub(crate) fn update(&mut self, params: &Value) {
        if self.finished
            || self.thread.is_none()
            || self.turn.is_none()
            || SourceId::parse(&params["threadId"]) != self.thread
            || SourceId::parse(&params["turnId"]) != self.turn
        {
            return;
        }
        let raw = &params["tokenUsage"];
        if raw.is_object() && raw["last"].is_object() && raw.to_string().len() <= 16_384 {
            self.raw = Some(raw.clone());
        }
    }
    pub(crate) fn complete(&mut self, params: &Value) -> Option<Snapshot> {
        if !self.matches_completion(params) {
            return None;
        }
        let outcome = match params["turn"]["status"].as_str()? {
            "completed" => "completed",
            "interrupted" => "interrupted",
            "failed" => "failed",
            _ => return None,
        };
        self.finished = true;
        Some(Snapshot {
            thread: self.thread.clone()?,
            turn: self.turn.clone()?,
            raw: self.raw.take()?,
            outcome: outcome.into(),
        })
    }
}

pub(crate) struct TurnContext {
    id: Uuid,
    thread: Value,
    started: String,
}
pub(crate) struct Record(pub(crate) Value);
impl TurnContext {
    pub(crate) fn new(thread: &Value) -> Self {
        // Frozen metadata only; no prompt, response, file path or transcript copy.
        Self {
            id: Uuid::new_v4(),
            thread: json!({"threadID":thread["id"],"projectID":thread["projectID"],"selection":thread["selection"]}),
            started: chrono::Utc::now().to_rfc3339(),
        }
    }
    pub(crate) fn finish(self, snapshot: Snapshot) -> Record {
        let mut usage = json!({});
        for (source, target) in [
            ("totalTokens", "inputTokens"),
            ("outputTokens", "outputTokens"),
            ("cachedInputTokens", "cachedInputTokens"),
        ] {
            if let Some(value) = snapshot.raw["last"][source].as_u64() {
                usage[target] = json!(value);
            }
        }
        if let Some(value) = snapshot.raw["modelContextWindow"].as_u64() {
            usage["contextWindow"] = json!(value);
        }
        Record(
            json!({"id":self.id,"threadID":self.thread["threadID"],"projectID":self.thread["projectID"],"provider":"codex","accountID":self.thread["selection"]["accountID"],"modelID":self.thread["selection"]["modelID"],"startedAt":self.started,"finishedAt":chrono::Utc::now().to_rfc3339(),"outcome":snapshot.outcome,"usage":usage,"provenance":{"kind":"codex_app_server_snapshot","scope":"last_request","sourceThreadId":snapshot.thread.0,"sourceTurnId":snapshot.turn.0,"rawTokenUsage":snapshot.raw}}),
        )
    }
}

pub(crate) fn append_history(old: Option<&Value>, record: &Value) -> Result<Value> {
    let mut next = old.cloned().unwrap_or_else(|| json!([]));
    // Validate all existing UUIDs/objects and bounds while retaining every byte
    // of semantic JSON (including unknown fields) in the working overlay.
    crate::organization::Records::parse(&serde_json::to_vec(&next)?)?;
    let id = Uuid::parse_str(record["id"].as_str().unwrap_or(""))?;
    let rows = next.as_array_mut().expect("validated array");
    if let Some(existing) = rows
        .iter()
        .find(|row| row["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(id))
    {
        ensure!(existing == record, "Conflicting usage record identity");
    } else {
        ensure!(
            rows.len() < crate::organization::RECORD_LIMIT,
            "Usage history capacity reached"
        );
        rows.push(record.clone());
    }
    ensure!(
        serde_json::to_vec(&next)?.len() <= crate::organization::DOCUMENT_LIMIT,
        "Usage history exceeds limit"
    );
    Ok(next)
}

#[cfg(test)]
#[path = "usage_capture_tests.rs"]
mod tests;
