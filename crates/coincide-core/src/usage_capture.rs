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
    early_usage: Vec<(SourceId, Value)>,
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
        let Some(id) = SourceId::parse(id) else {
            return false;
        };
        if self.thread.is_none() || self.finished {
            return false;
        }
        if let Some(existing) = &self.turn {
            return existing == &id;
        }
        self.turn = Some(id.clone());
        self.raw = self
            .early_usage
            .iter()
            .rev()
            .find(|(turn, _)| turn == &id)
            .map(|(_, raw)| raw.clone());
        self.early_usage.clear();
        true
    }
    pub(crate) fn identity(&self) -> Option<(&str, &str)> {
        Some((&self.thread.as_ref()?.0, &self.turn.as_ref()?.0))
    }
    pub(crate) fn owns_thread(&self, params: &Value) -> bool {
        self.thread.is_some() && SourceId::parse(&params["threadId"]) == self.thread
    }
    pub(crate) fn matches_completion(&self, params: &Value) -> bool {
        !self.finished
            && self.thread.is_some()
            && self.turn.is_some()
            && SourceId::parse(&params["threadId"]) == self.thread
            && SourceId::parse(&params["turn"]["id"]) == self.turn
    }
    /// False means bounded early-usage storage overflow; callers fail closed.
    pub(crate) fn update(&mut self, params: &Value) -> bool {
        if self.finished || !self.owns_thread(params) {
            return true;
        }
        let Some(turn) = SourceId::parse(&params["turnId"]) else {
            return true;
        };
        let raw = &params["tokenUsage"];
        if !raw.is_object() || !raw["last"].is_object() || raw.to_string().len() > 16_384 {
            return true;
        }
        if let Some(current) = &self.turn {
            if current == &turn {
                self.raw = Some(raw.clone());
            }
        } else if let Some((_, existing)) = self.early_usage.iter_mut().find(|(id, _)| id == &turn)
        {
            *existing = raw.clone();
        } else {
            if self.early_usage.len() >= 8 {
                return false;
            }
            self.early_usage.push((turn, raw.clone()));
        }
        true
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
    pub(crate) fn matches(&self, thread: &Value) -> bool {
        self.thread["threadID"] == thread["id"]
            && self.thread["projectID"] == thread["projectID"]
            && self.thread["selection"] == thread["selection"]
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
