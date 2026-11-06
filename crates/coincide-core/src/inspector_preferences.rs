//! Swift InspectorFollow/UIState presentation data. No serialized field grants
//! access to a provider, filesystem, native browser, terminal or PR context.
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use uuid::Uuid;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Panel {
    Diff,
    PullRequests,
    Preview,
    Terminal,
    Schedules,
}
impl Panel {
    pub fn parse(value: &Value) -> Option<Self> {
        match value.as_str()? {
            "diff" => Some(Self::Diff),
            "pullRequests" => Some(Self::PullRequests),
            "preview" => Some(Self::Preview),
            "terminal" => Some(Self::Terminal),
            "schedules" => Some(Self::Schedules),
            _ => None,
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            Self::Diff => "diff",
            Self::PullRequests => "pullRequests",
            Self::Preview => "preview",
            Self::Terminal => "terminal",
            Self::Schedules => "schedules",
        }
    }
    pub fn window_wide(self) -> bool {
        self == Self::Schedules
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
    None,
    Show(Panel),
    Close,
}
pub fn follow(current: Option<Panel>, saved: Option<Panel>, terminal_on_right: bool) -> Change {
    if current.is_some_and(Panel::window_wide) {
        return Change::None;
    }
    let saved = saved
        .filter(|panel| !panel.window_wide() && (*panel != Panel::Terminal || terminal_on_right));
    match saved {
        Some(saved) if current == Some(saved) => Change::None,
        Some(saved) => Change::Show(saved),
        None if current.is_some() => Change::Close,
        None => Change::None,
    }
}
pub fn validate(document: &Value) -> Result<()> {
    ensure!(document.is_object(), "Saved window state is not an object");
    ensure!(
        serde_json::to_vec(document)?.len() <= 2 * 1024 * 1024,
        "Saved window state exceeds safe inspector limit"
    );
    ensure!(
        document.get("threadPanels").is_none_or(Value::is_object),
        "Saved inspector mapping is malformed"
    );
    ensure!(
        document["threadPanels"]
            .as_object()
            .is_none_or(|map| map.len() <= 4096),
        "Saved inspector mapping exceeds safe limit"
    );
    Ok(())
}
pub fn thread_key(document: &Value, thread: &str) -> Result<Option<String>> {
    validate(document)?;
    let thread = Uuid::parse_str(thread).context("Invalid inspector conversation identity")?;
    let Some(map) = document["threadPanels"].as_object() else {
        return Ok(None);
    };
    let mut found = map
        .keys()
        .filter(|key| Uuid::parse_str(key).ok() == Some(thread));
    let key = found.next().cloned();
    ensure!(
        found.next().is_none(),
        "Saved inspector conversation identity is ambiguous"
    );
    Ok(key)
}
pub fn saved(document: &Value, thread: &str) -> Result<Option<Panel>> {
    validate(document)?;
    if document.get("threadPanels").is_some() {
        return Ok(thread_key(document, thread)?
            .and_then(|key| Panel::parse(&document["threadPanels"][key]))
            .filter(|panel| !panel.window_wide()));
    }
    // Swift migrates the former window-wide panel only for its actual selected
    // conversation. Missing maps and explicitly empty maps are distinct.
    let selected = document["selectedThreadID"]
        .as_str()
        .and_then(|id| Uuid::parse_str(id).ok());
    let thread = Uuid::parse_str(thread)?;
    if document["isInspectorOpen"] == true && selected == Some(thread) {
        return Ok(
            Some(Panel::parse(&document["inspectorPanel"]).unwrap_or(Panel::Diff))
                .filter(|panel| !panel.window_wide()),
        );
    }
    Ok(None)
}
pub(crate) fn updated(document: &Value, thread: &str, panel: Option<Panel>) -> Result<Value> {
    validate(document)?;
    if panel.is_some_and(Panel::window_wide) {
        return Ok(document.clone());
    }
    let canonical = Uuid::parse_str(thread)?.to_string().to_uppercase();
    let key = thread_key(document, thread)?.unwrap_or(canonical);
    let mut next = document.clone();
    migrate_legacy(&mut next);
    if next.get("threadPanels").is_none() {
        next["threadPanels"] = json!({});
    }
    let map = next["threadPanels"].as_object_mut().unwrap();
    if let Some(panel) = panel {
        map.insert(key, json!(panel.key()));
    } else {
        map.remove(&key);
    }
    validate(&next)?;
    Ok(next)
}

/// Freeze an earlier window-wide choice before selectedThreadID changes. An
/// explicitly present map, even an unsupported future shape, remains untouched.
pub(crate) fn migrate_legacy(next: &mut Value) {
    if next.get("threadPanels").is_some() || next["isInspectorOpen"] != true {
        return;
    }
    if let Some(selected) = next["selectedThreadID"]
        .as_str()
        .and_then(|id| Uuid::parse_str(id).ok())
    {
        let panel = Panel::parse(&next["inspectorPanel"]).unwrap_or(Panel::Diff);
        let mut map = serde_json::Map::new();
        map.insert(selected.to_string().to_uppercase(), json!(panel.key()));
        next["threadPanels"] = Value::Object(map);
    }
}
