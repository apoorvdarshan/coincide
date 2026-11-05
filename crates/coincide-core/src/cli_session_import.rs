//! Pure bounded Codex rollout preview. Original bytes are retained verbatim.
//! This intentionally creates no executable session or store entry. The caller must
//! capture source bytes and keep imported conversations read-only until explicitly forked.
use anyhow::{bail, ensure, Result};
use serde_json::Value;
use std::collections::HashSet;
use uuid::Uuid;

pub const MAX_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_RECORDS: usize = 100_000;
pub const MAX_TEXT: usize = 100_000;
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedMessage {
    pub role: String,
    pub text: String,
    pub external_id: Option<String>,
    pub timestamp: Option<String>,
}
#[derive(Debug)]
pub struct SessionPreview {
    original: Vec<u8>,
    pub session_id: Uuid,
    pub directory: String,
    pub model: Option<String>,
    pub messages: Vec<ImportedMessage>,
    pub omitted_records: usize,
    pub shortened_text: bool,
}
impl SessionPreview {
    pub fn original(&self) -> &[u8] {
        &self.original
    }
    /// Coordinator must re-read with bounded, no-symlink IO before saving a preview.
    pub fn matches_source(&self, bytes: &[u8]) -> bool {
        self.original == bytes
    }
}

pub fn preview_codex(bytes: &[u8]) -> Result<SessionPreview> {
    ensure!(bytes.len() <= MAX_BYTES, "session too large");
    let mut records = Vec::new();
    let mut omitted = 0;
    for (index, line) in bytes.split(|b| *b == b'\n').enumerate() {
        ensure!(
            index < MAX_RECORDS || line.is_empty() && index == MAX_RECORDS,
            "too many records"
        );
        ensure!(line.len() <= MAX_RECORD_BYTES, "record too large");
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        match serde_json::from_slice::<Value>(line) {
            Ok(record) if record.is_object() => records.push(record),
            _ => omitted += 1,
        }
    }
    ensure!(
        !records.iter().any(|r| r.get("sessionId").is_some()),
        "Claude/mixed sessions are unsupported"
    );
    let mut identity = None;
    let mut directory = None;
    for record in &records {
        if record["type"] != "session_meta" {
            continue;
        }
        let payload = &record["payload"];
        let id = payload["id"]
            .as_str()
            .or_else(|| payload["session_id"].as_str())
            .ok_or_else(|| anyhow::anyhow!("missing session id"))?;
        let id = Uuid::parse_str(id)?;
        ensure!(
            identity.is_none_or(|old| old == id),
            "mixed session identities"
        );
        identity = Some(id);
        let cwd = payload["cwd"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("missing working directory"))?;
        ensure!(
            cwd.starts_with('/') && !cwd.contains('\0'),
            "unsupported working directory"
        );
        directory = Some(cwd.to_owned());
    }
    let Some(session_id) = identity else {
        bail!("not a Codex rollout")
    };
    let mut preview = SessionPreview {
        original: bytes.to_vec(),
        session_id,
        directory: directory.unwrap(),
        model: None,
        messages: Vec::new(),
        omitted_records: omitted,
        shortened_text: false,
    };
    let mut seen = HashSet::new();
    // Only pair adjacent logical messages from opposite encodings. Repeated text
    // within one encoding is a real turn, not a global deduplication key.
    let mut previous: Option<(String, String, bool)> = None;
    for record in records {
        let p = &record["payload"];
        let (role, text, external_id) = match (record["type"].as_str(), p["type"].as_str()) {
            (Some("session_meta"), _) => continue,
            (Some("turn_context"), _) => {
                if let Some(model) = p["model"].as_str() {
                    preview.model = Some(model.to_owned());
                }
                continue;
            }
            (Some("event_msg"), Some("thread_rolled_back")) => {
                let count = p["num_turns"]
                    .as_u64()
                    .ok_or_else(|| anyhow::anyhow!("invalid rollback"))?;
                if count > 0 {
                    let starts: Vec<usize> = preview
                        .messages
                        .iter()
                        .enumerate()
                        .filter_map(|(i, m)| (m.role == "user").then_some(i))
                        .collect();
                    if !starts.is_empty() {
                        let index = starts
                            .len()
                            .saturating_sub(usize::try_from(count).unwrap_or(usize::MAX));
                        preview.messages.truncate(starts[index]);
                    }
                }
                seen = preview
                    .messages
                    .iter()
                    .filter_map(|m| m.external_id.clone())
                    .collect();
                previous = None;
                continue;
            }
            (Some("response_item"), Some("message")) => {
                let Some(role @ ("user" | "assistant")) = p["role"].as_str() else {
                    preview.omitted_records += 1;
                    continue;
                };
                let id = p["id"].as_str().map(str::to_owned);
                if let Some(id) = &id {
                    if !seen.insert(id.clone()) {
                        continue;
                    }
                }
                let Some(blocks) = p["content"].as_array() else {
                    preview.omitted_records += 1;
                    continue;
                };
                let mut texts = Vec::new();
                for block in blocks {
                    if let Some(text) = block["text"].as_str() {
                        texts.push(text)
                    } else {
                        preview.omitted_records += 1;
                    }
                }
                (role.to_owned(), texts.join("\n"), id)
            }
            (Some("event_msg"), Some(kind @ ("user_message" | "agent_message"))) => {
                let Some(text) = p["message"].as_str() else {
                    preview.omitted_records += 1;
                    continue;
                };
                (
                    if kind == "user_message" {
                        "user"
                    } else {
                        "assistant"
                    }
                    .to_owned(),
                    text.to_owned(),
                    None,
                )
            }
            _ => {
                preview.omitted_records += 1;
                continue;
            }
        };
        if text.is_empty() {
            continue;
        }
        let is_event = record["type"] == "event_msg";
        if previous
            .as_ref()
            .is_some_and(|(old_role, old_text, old_event)| {
                old_role == &role && old_text == &text && *old_event != is_event
            })
        {
            if !is_event {
                if let Some(last) = preview.messages.last_mut() {
                    last.external_id = external_id;
                }
            }
            previous = None;
            continue;
        }
        previous = Some((role.clone(), text.clone(), is_event));
        let shortened = text.chars().count() > MAX_TEXT;
        preview.shortened_text |= shortened;
        preview.messages.push(ImportedMessage {
            role,
            text: if shortened {
                text.chars().take(MAX_TEXT).collect::<String>() + "\n…"
            } else {
                text
            },
            external_id,
            timestamp: record["timestamp"].as_str().map(str::to_owned),
        });
    }
    ensure!(!preview.messages.is_empty(), "no supported messages");
    Ok(preview)
}
