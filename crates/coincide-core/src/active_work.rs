//! Display-only activity for an active provider run. Only counts cross the
//! status API. Prompts, commands, task output and provider IDs stay private.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default)]
pub struct Summary {
    pub commands: usize,
    pub subagents: usize,
    pub background: usize,
    pub tools: usize,
}

impl Summary {
    pub fn total(self) -> usize {
        self.commands + self.subagents + self.background + self.tools
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Command,
    Subagent,
    Background,
    Tool,
}

#[derive(Clone, Default)]
pub(crate) struct Work {
    tools: HashMap<String, Kind>,
    children: HashSet<String>,
    background: HashMap<String, (Option<String>, Kind)>,
    background_snapshot: bool,
}

impl Work {
    pub(crate) fn observe(&mut self, provider: &str, frame: &Value) {
        let method = frame["method"].as_str().unwrap_or_default();
        let params = &frame["params"];
        if provider == "claude" && method == "provider/backgroundWork" {
            self.observe_background(params);
            return;
        }
        if !matches!(method, "item/started" | "item/completed") {
            return;
        }
        let item = &params["item"];
        if provider == "codex" {
            self.observe_codex_children(item);
        }
        let Some(id) = nonempty(&item["id"]) else {
            return;
        };
        let status = item["status"].as_str();
        if method == "item/completed"
            || matches!(
                status,
                Some(
                    "completed" | "failed" | "declined" | "interrupted" | "cancelled" | "canceled"
                )
            )
        {
            self.tools.remove(id);
        } else if let Some(kind) = tool_kind(item) {
            self.tools.insert(id.to_owned(), kind);
        }
    }

    fn observe_codex_children(&mut self, item: &Value) {
        match item["type"].as_str() {
            Some("subAgentActivity") => {
                if let Some(id) = nonempty(&item["agentThreadId"]) {
                    match item["kind"].as_str() {
                        Some("started") => {
                            self.children.insert(id.to_owned());
                        }
                        Some("completed" | "interrupted") => {
                            self.children.remove(id);
                        }
                        _ => {}
                    }
                }
            }
            Some("collabAgentToolCall") => {
                for (id, state) in item["agentsStates"].as_object().into_iter().flatten() {
                    match state["status"].as_str() {
                        Some("pendingInit" | "running") => {
                            self.children.insert(id.clone());
                        }
                        Some("interrupted" | "completed" | "errored" | "shutdown" | "notFound") => {
                            self.children.remove(id);
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    fn observe_background(&mut self, params: &Value) {
        let subtype = params["subtype"].as_str();
        if subtype == Some("background_tasks_changed") {
            let Some(tasks) = params["tasks"].as_array() else {
                return;
            };
            self.background_snapshot = true;
            self.background = tasks
                .iter()
                .filter_map(|task| {
                    if task["ambient"] == true {
                        return None;
                    }
                    Some((
                        nonempty(&task["task_id"])?.to_owned(),
                        (None, background_kind(task)),
                    ))
                })
                .collect();
            return;
        }
        // A snapshot is authoritative. Its ordering relative to edge events
        // describing the same transition is unspecified.
        if self.background_snapshot {
            return;
        }
        let Some(id) = nonempty(&params["task_id"]) else {
            return;
        };
        let run_id = nonempty(&params["run_id"]);
        let stale = self.background.get(id).is_some_and(|(current, _)| {
            current
                .as_deref()
                .zip(run_id)
                .is_some_and(|(current, next)| next < current)
        });
        if stale {
            return;
        }
        match subtype {
            Some("task_started")
                if params["is_backgrounded"] == true
                    && params["ambient"] != true
                    && params["skip_transcript"] != true =>
            {
                self.background.insert(
                    id.to_owned(),
                    (run_id.map(str::to_owned), background_kind(params)),
                );
            }
            Some("task_notification")
                if matches!(
                    params["status"].as_str(),
                    Some("completed" | "failed" | "stopped")
                ) =>
            {
                self.background.remove(id);
            }
            _ => {}
        }
    }

    pub(crate) fn summary(&self) -> Summary {
        let mut result = Summary {
            subagents: self.children.len(),
            ..Summary::default()
        };
        for kind in self
            .tools
            .values()
            .chain(self.background.values().map(|(_, kind)| kind))
        {
            match kind {
                Kind::Command => result.commands += 1,
                Kind::Subagent => result.subagents += 1,
                Kind::Background => result.background += 1,
                Kind::Tool => result.tools += 1,
            }
        }
        result
    }
}

fn nonempty(value: &Value) -> Option<&str> {
    value.as_str().filter(|id| !id.is_empty())
}

fn background_kind(task: &Value) -> Kind {
    if task["task_type"] == "local_agent" || task["subagent_type"].is_string() {
        Kind::Subagent
    } else {
        Kind::Background
    }
}

fn tool_kind(item: &Value) -> Option<Kind> {
    match item["type"].as_str()? {
        "commandExecution" => Some(Kind::Command),
        "sleep" => Some(Kind::Background),
        // Child counts represent the delegated work. The collab call itself
        // can just be a status query, wait or message to those same children.
        "collabAgentToolCall" => None,
        "toolCall" | "dynamicToolCall" | "mcpToolCall" => Some(named_tool_kind(item)),
        "fileChange" | "webSearch" | "imageView" | "imageGeneration" | "contextCompaction" => {
            Some(Kind::Tool)
        }
        _ => None,
    }
}

fn named_tool_kind(item: &Value) -> Kind {
    let name = item["name"]
        .as_str()
        .or_else(|| item["tool"].as_str())
        .unwrap_or_default();
    if ["task", "agent", "spawn_agent"]
        .iter()
        .any(|tool| name.eq_ignore_ascii_case(tool))
    {
        Kind::Subagent
    } else if item["kind"] == "execute"
        || ["bash", "shell", "powershell", "exec_command", "run_command"]
            .iter()
            .any(|tool| name.eq_ignore_ascii_case(tool))
    {
        Kind::Command
    } else {
        Kind::Tool
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn item(work: &mut Work, provider: &str, method: &str, item: Value) {
        work.observe(provider, &json!({"method":method,"params":{"item":item}}));
    }

    #[test]
    fn normalized_calls_track_all_providers_by_item_id() {
        for provider in [
            "codex",
            "claude",
            "opencode",
            "lithos",
            "cursor",
            "grok",
            "antigravity",
            "acp-example",
        ] {
            let mut work = Work::default();
            let command =
                json!({"id":"one","type":"toolCall","kind":"execute","status":"in_progress"});
            item(&mut work, provider, "item/started", command.clone());
            item(&mut work, provider, "item/started", command);
            item(
                &mut work,
                provider,
                "item/started",
                json!({"id":"two","type":"toolCall","name":"Agent"}),
            );
            item(
                &mut work,
                provider,
                "item/started",
                json!({"id":"reply","type":"agentMessage"}),
            );
            assert_eq!(
                work.summary(),
                Summary {
                    commands: 1,
                    subagents: 1,
                    ..Summary::default()
                }
            );
            item(
                &mut work,
                provider,
                "item/completed",
                json!({"id":"two","type":"toolCall"}),
            );
            item(
                &mut work,
                provider,
                "item/started",
                json!({"id":"one","type":"toolCall","status":"canceled"}),
            );
            assert_eq!(work.summary().total(), 0);
        }
    }

    #[test]
    fn codex_children_remain_visible_after_spawn_completes() {
        let mut work = Work::default();
        item(
            &mut work,
            "codex",
            "item/completed",
            json!({
                "id":"spawn","type":"collabAgentToolCall","agentsStates":{"child":{"status":"running"}}
            }),
        );
        item(
            &mut work,
            "codex",
            "item/completed",
            json!({
                "id":"start","type":"subAgentActivity","kind":"started","agentThreadId":"child"
            }),
        );
        item(
            &mut work,
            "codex",
            "item/started",
            json!({"id":"sleep","type":"sleep"}),
        );
        assert_eq!(
            work.summary(),
            Summary {
                subagents: 1,
                background: 1,
                ..Summary::default()
            }
        );
        item(
            &mut work,
            "codex",
            "item/completed",
            json!({
                "id":"end","type":"subAgentActivity","kind":"completed","agentThreadId":"child"
            }),
        );
        item(
            &mut work,
            "codex",
            "item/completed",
            json!({"id":"sleep","type":"sleep"}),
        );
        assert_eq!(work.summary().total(), 0);
    }

    #[test]
    fn claude_background_snapshots_replace_state_and_ignore_ambient_tasks() {
        let mut work = Work::default();
        let frame = |params| json!({"method":"provider/backgroundWork","params":params});
        work.observe(
            "claude",
            &frame(json!({
                "subtype":"task_started","task_id":"old","run_id":"1","is_backgrounded":true
            })),
        );
        assert_eq!(work.summary().background, 1);
        work.observe(
            "claude",
            &frame(json!({
                "subtype":"background_tasks_changed","tasks":[
                    {"task_id":"child","task_type":"local_agent"},
                    {"task_id":"watcher","task_type":"local_bash","ambient":true}
                ]
            })),
        );
        assert_eq!(
            work.summary(),
            Summary {
                subagents: 1,
                ..Summary::default()
            }
        );
        work.observe(
            "claude",
            &frame(json!({
                "subtype":"task_started","task_id":"late","is_backgrounded":true
            })),
        );
        assert_eq!(work.summary().total(), 1);
        work.observe(
            "claude",
            &frame(json!({"subtype":"background_tasks_changed","tasks":[]})),
        );
        assert_eq!(work.summary().total(), 0);
    }
}
