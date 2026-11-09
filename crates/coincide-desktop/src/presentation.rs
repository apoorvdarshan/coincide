use super::*;
use gpui_kit::assets::IconName;
use std::collections::HashMap;

// Shared with the macOS Theme and TranscriptMetrics. Keep the composer and
// virtualized transcript rows aligned without constraining the scroll viewport.
pub(super) const CONTENT_WIDTH: f32 = 820.;
pub(super) const CONTENT_GUTTER: f32 = 24.;
pub(super) const RAIL_GUTTER: f32 = 34.;

pub(super) fn provider_name(provider: &str) -> &str {
    match provider {
        "codex" => "Codex",
        "claude" => "Claude",
        "cursor" => "Cursor",
        "grok" => "Grok",
        "opencode" => "OpenCode",
        "antigravity" => "Antigravity",
        "" => "Assistant",
        other => other,
    }
}

pub(super) struct WorkHeader {
    pub title: String,
    pub status: Option<&'static str>,
}

/// The label Swift shows while a tool is the live activity in a work group.
pub(super) fn group_category_label(category: &str) -> &'static str {
    match category {
        "command" => "Run command",
        "fileChange" => "Change file",
        "read" => "Read file",
        "search" => "Search code",
        "web" => "Search the web",
        "mcp" => "Call MCP tool",
        "task" => "Run subagent",
        "todo" => "Update the plan",
        _ => "Use tool",
    }
}

/// Swift's TranscriptLabels.summary(of:): "Ran 3 commands and read 2 files",
/// naming the two most significant kinds of work.
pub(super) fn group_summary(items: &[Value]) -> String {
    let tools = items
        .iter()
        .filter(|item| item["kind"] == "tool")
        .collect::<Vec<_>>();
    if tools.is_empty() {
        return if items.len() == 1 {
            "Thought".into()
        } else {
            format!("Thought {} times", items.len())
        };
    }
    let mut order = Vec::new();
    let mut counts = HashMap::<String, usize>::new();
    for tool in &tools {
        let category = category_label(tool);
        if !counts.contains_key(&category) {
            order.push(category.clone());
        }
        *counts.entry(category).or_default() += 1;
    }
    let mut ranked = order.into_iter().enumerate().collect::<Vec<_>>();
    ranked.sort_by_key(|(position, category)| (category_priority(category), *position));
    ranked.truncate(2);
    ranked.sort_by_key(|(position, _)| *position);
    let shown = ranked
        .iter()
        .map(|(_, category)| counts[category])
        .sum::<usize>();
    let mut parts = ranked
        .into_iter()
        .map(|(_, category)| category_phrase(&category, counts[&category]))
        .collect::<Vec<_>>();
    let remaining = tools.len().saturating_sub(shown);
    if remaining > 0 {
        parts.push(if remaining == 1 {
            "performed 1 other action".into()
        } else {
            format!("performed {remaining} other actions")
        });
    }
    let sentence = parts
        .into_iter()
        .enumerate()
        .map(|(index, part)| {
            if index == 0 {
                part
            } else {
                let mut chars = part.chars();
                chars
                    .next()
                    .map(|first| first.to_lowercase().collect::<String>() + chars.as_str())
                    .unwrap_or(part)
            }
        })
        .collect::<Vec<_>>();
    match sentence.len() {
        0 => "Used tools".into(),
        1 => sentence[0].clone(),
        2 => format!("{} and {}", sentence[0], sentence[1]),
        _ => format!("{}, {}, and {}", sentence[0], sentence[1], sentence[2]),
    }
}

fn category_label(item: &Value) -> String {
    item["category"].as_str().unwrap_or("other").to_owned()
}

fn category_priority(category: &str) -> u8 {
    match category {
        "command" | "fileChange" | "task" => 0,
        "other" => 2,
        _ => 1,
    }
}

fn category_phrase(category: &str, count: usize) -> String {
    let one = count == 1;
    match category {
        "command" => {
            if one {
                "Ran 1 command".into()
            } else {
                format!("Ran {count} commands")
            }
        }
        "fileChange" => {
            if one {
                "Changed 1 file".into()
            } else {
                format!("Changed {count} files")
            }
        }
        "read" => {
            if one {
                "Read 1 file".into()
            } else {
                format!("Read {count} files")
            }
        }
        "search" => {
            if one {
                "Searched code once".into()
            } else {
                format!("Searched code {count} times")
            }
        }
        "web" => {
            if one {
                "Searched the web once".into()
            } else {
                format!("Searched the web {count} times")
            }
        }
        "mcp" => {
            if one {
                "Called 1 MCP tool".into()
            } else {
                format!("Called {count} MCP tools")
            }
        }
        "task" => {
            if one {
                "Ran 1 subagent".into()
            } else {
                format!("Ran {count} subagents")
            }
        }
        "todo" => {
            if one {
                "Updated the plan".into()
            } else {
                format!("Updated the plan {count} times")
            }
        }
        _ => {
            if one {
                "Used 1 tool".into()
            } else {
                format!("Used {count} tools")
            }
        }
    }
}

/// The symbol for a group: its category when every tool shares one, otherwise
/// a generic tool, and the brain when it only contains reasoning.
pub(super) fn group_icon(items: &[Value]) -> IconName {
    let mut categories = items
        .iter()
        .filter(|item| item["kind"] == "tool")
        .map(|item| item["category"].as_str().unwrap_or("other"))
        .collect::<Vec<_>>();
    categories.sort_unstable();
    categories.dedup();
    if categories.is_empty() {
        return IconName::Brain;
    }
    if categories.len() == 1 {
        return icon_for_category(categories[0]);
    }
    IconName::Hammer
}

pub(super) fn icon_for_category(category: &str) -> IconName {
    match category {
        "command" => IconName::SquareTerminal,
        "fileChange" => IconName::PencilLine,
        "read" => IconName::FileText,
        "search" => IconName::Search,
        "web" => IconName::Globe,
        "mcp" => IconName::Puzzle,
        "task" => IconName::Users,
        "todo" => IconName::ListChecks,
        _ => IconName::Wrench,
    }
}

/// OpenCode's question tool call duplicates the form item; only the form row
/// should be drawn, as Swift's OpenCodeQuestions does.
pub(super) fn is_question_tool(item: &Value) -> bool {
    item["kind"] == "tool"
        && opencode_payload(item).is_some_and(|payload| {
            payload["type"] == "toolCall" && payload["name"].as_str() == Some("question")
        })
}

/// Raw OpenCode reasoning parts duplicate the normalized reasoning item. Old
/// rows did not carry metadata, so hide them while reading the transcript.
pub(super) fn is_duplicate_reasoning_tool(item: &Value) -> bool {
    item["kind"] == "tool"
        && item["provider"] == "opencode"
        && opencode_payload(item).is_some_and(|payload| payload["type"] == "reasoning")
}

fn opencode_payload(item: &Value) -> Option<Value> {
    serde_json::from_str::<Value>(item["text"].as_str()?).ok()
}

/// Reasoning rows stored before statuses were recorded are finished turns;
/// new reasoning rows carry `running`/`completed` explicitly.
pub(super) fn normalize_legacy_reasoning(item: &mut Value) {
    if item["kind"] == "reasoning" && item["status"].is_null() {
        item["status"] = json!("completed");
    }
}

/// Older OpenCode rows were stored as raw `toolCall` JSON without the display
/// fields Swift's tool cells expect. Derive the same header metadata at render
/// time so existing threads are fixed without rewriting their transcripts.
pub(super) fn normalize_opencode_tool(item: &mut Value) {
    if item["kind"] != "tool" || item["provider"] != "opencode" {
        return;
    }
    let Some(payload) = opencode_payload(item) else {
        return;
    };
    if payload["type"] != "toolCall" {
        return;
    }
    let name = payload["name"].as_str().unwrap_or_default();
    let category = match name {
        "shell" | "bash" => "command",
        "read" | "list" => "read",
        "grep" | "glob" | "search" => "search",
        "webfetch" | "websearch" => "web",
        "edit" | "write" | "patch" | "multiedit" => "fileChange",
        "task" => "task",
        "todowrite" | "todoread" => "todo",
        value if value.starts_with("mcp") => "mcp",
        _ => "other",
    };
    let input = &payload["input"];
    let (title, detail) = match name {
        "shell" | "bash" => (
            Some("Run command".to_owned()),
            input["command"].as_str().and_then(bounded_title),
        ),
        "read" => (
            Some("Read file".to_owned()),
            input["filePath"]
                .as_str()
                .or_else(|| input["path"].as_str())
                .and_then(bounded_title),
        ),
        "write" => (
            Some("Write file".to_owned()),
            input["filePath"]
                .as_str()
                .or_else(|| input["path"].as_str())
                .and_then(bounded_title),
        ),
        "edit" | "patch" | "multiedit" => (
            Some("Edit file".to_owned()),
            input["filePath"]
                .as_str()
                .or_else(|| input["path"].as_str())
                .and_then(bounded_title),
        ),
        "grep" | "glob" | "search" => (
            Some("Search".to_owned()),
            input["pattern"].as_str().and_then(bounded_title),
        ),
        "webfetch" | "websearch" => (
            Some("Web search".to_owned()),
            input["url"].as_str().and_then(bounded_title),
        ),
        "task" => (
            Some("Subagent".to_owned()),
            input["description"].as_str().and_then(bounded_title),
        ),
        "todowrite" | "todoread" => (Some("Update plan".to_owned()), None),
        "question" => (
            Some("Question".to_owned()),
            input["questions"]
                .as_array()
                .and_then(|questions| questions.first())
                .and_then(|question| question["question"].as_str())
                .and_then(bounded_title),
        ),
        value => (bounded_title(value), None),
    };
    if let Some(title) = title.filter(|title| !title.is_empty()) {
        if item.get("title").is_null_or_empty() {
            item["title"] = json!(title);
        }
    }
    if let Some(detail) = detail.filter(|detail| !detail.is_empty()) {
        if item.get("detail").is_null_or_empty() {
            item["detail"] = json!(detail);
        }
    }
    if item.get("category").is_none() {
        item["category"] = json!(category);
    }
    if item.get("status").is_none() {
        if let Some(status) = match payload["status"].as_str() {
            Some("running") => Some("running"),
            Some("completed") => Some("completed"),
            Some("failed") => Some("failed"),
            Some("cancelled" | "canceled" | "declined") => Some("declined"),
            _ => None,
        } {
            item["status"] = json!(status);
        }
    }
    if item.get("output").is_none() {
        let output = payload["content"]
            .as_array()
            .map(|content| {
                content
                    .iter()
                    .filter_map(|part| part["text"].as_str())
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .filter(|output| !output.trim().is_empty());
        if let Some(output) = output {
            item["output"] = json!(output);
        }
    }
}

fn bounded_title(source: &str) -> Option<String> {
    let mut chars = source.chars();
    let head: String = chars.by_ref().take(160).collect();
    let mut title = head.split_whitespace().collect::<Vec<_>>().join(" ");
    if title.is_empty() {
        return None;
    }
    if chars.next().is_some() {
        title.push('…');
    }
    Some(title)
}

trait NullOrEmpty {
    fn is_null_or_empty(&self) -> bool;
}
impl NullOrEmpty for Option<&Value> {
    fn is_null_or_empty(&self) -> bool {
        self.is_none_or(|value| {
            value.is_null() || value.as_str().is_some_and(|text| text.trim().is_empty())
        })
    }
}

// Read only explicit Swift-compatible item metadata. Live provider JSON stored
// in item.text is body content, never a substitute for these persisted fields.
pub(super) fn work_header(item: &Value) -> Option<WorkHeader> {
    let status = match item["status"].as_str() {
        Some("running") => Some("Running"),
        Some("completed") => Some("Completed"),
        Some("failed") => Some("Failed"),
        Some("declined") => Some("Declined"),
        Some("waiting") => Some("Waiting"),
        _ => None,
    };
    let title = match item["kind"].as_str()? {
        "reasoning" => match item["status"].as_str() {
            Some("running") => "Thinking".to_owned(),
            Some("completed") => "Thought".to_owned(),
            _ => "Reasoning".to_owned(),
        },
        "tool" => {
            let source = item["title"].as_str().unwrap_or_default();
            let mut chars = source.chars();
            let head: String = chars.by_ref().take(160).collect();
            let mut title = head.split_whitespace().collect::<Vec<_>>().join(" ");
            if !title.is_empty() {
                if chars.next().is_some() {
                    title.push('…');
                }
                title
            } else {
                match item["category"].as_str() {
                    Some("command") => "Command",
                    Some("fileChange") => "File change",
                    Some("read") => "Read file",
                    Some("search") => "Search",
                    Some("web") => "Web search",
                    Some("mcp") => "MCP tool",
                    Some("task") => "Subagent",
                    Some("todo") => "Plan update",
                    Some("other") => "Tool",
                    _ => "Tool activity",
                }
                .to_owned()
            }
        }
        _ => return None,
    };
    Some(WorkHeader { title, status })
}

impl Coincide {
    pub(super) fn provider_ink(&self, provider: &str) -> Rgba {
        let (light, dark) = match provider {
            "claude" => (0xC2603D, 0xE08A6B),
            "codex" => (0x0E8A6A, 0x3CC79A),
            "cursor" => (0x5A5FD6, 0x9A9EFF),
            "grok" => (0x6B7077, 0xA9AEB4),
            "opencode" => (0xB7700C, 0xE9B04E),
            "antigravity" => (0x2F6BDB, 0x6FA3FF),
            _ => return self.color(0xe4e9f2),
        };
        rgb(if self.appearance_dark { dark } else { light })
    }
}

#[cfg(test)]
mod work_header_tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn explicit_swift_statuses_are_displayed_without_aliasing_unknown_values() {
        for (saved, label) in [
            ("running", "Running"),
            ("completed", "Completed"),
            ("failed", "Failed"),
            ("declined", "Declined"),
            ("waiting", "Waiting"),
        ] {
            let item = json!({"kind":"tool","status":saved});
            assert_eq!(work_header(&item).unwrap().status, Some(label));
        }
        for saved in [
            Value::Null,
            json!("inProgress"),
            json!("Completed"),
            json!(true),
        ] {
            let item = json!({"kind":"tool","status":saved,"text":"{\"status\":\"completed\"}"});
            let header = work_header(&item).unwrap();
            assert_eq!(header.status, None);
            assert_eq!(header.title, "Tool activity");
        }
        let missing =
            json!({"kind":"tool","text":"{\"title\":\"Hidden\",\"status\":\"completed\"}"});
        let header = work_header(&missing).unwrap();
        assert_eq!(header.status, None);
        assert_eq!(header.title, "Tool activity");
    }

    #[::core::prelude::v1::test]
    fn reasoning_never_infers_running_or_completion_from_other_fields() {
        for (saved, title) in [
            (json!("running"), "Thinking"),
            (json!("completed"), "Thought"),
            (Value::Null, "Reasoning"),
            (json!("unknown"), "Reasoning"),
            (json!("failed"), "Reasoning"),
        ] {
            let item = json!({"kind":"reasoning","status":saved,"completedAt":30,"createdAt":0,"text":"completed"});
            assert_eq!(work_header(&item).unwrap().title, title);
        }
        assert!(work_header(&json!({"kind":"assistant","status":"running"})).is_none());
    }

    #[::core::prelude::v1::test]
    fn work_group_summary_matches_swift_wording() {
        let items = vec![
            json!({"kind":"tool","category":"command"}),
            json!({"kind":"tool","category":"command"}),
            json!({"kind":"tool","category":"read"}),
            json!({"kind":"tool","category":"search"}),
        ];
        assert_eq!(
            group_summary(&items),
            "Ran 2 commands, read 1 file, and performed 1 other action"
        );
        assert_eq!(
            group_summary(&[
                json!({"kind":"reasoning"}),
                json!({"kind":"reasoning"}),
                json!({"kind":"reasoning"}),
            ]),
            "Thought 3 times"
        );
        assert_eq!(
            group_summary(&[json!({"kind":"tool","category":"command"})]),
            "Ran 1 command"
        );
    }

    #[::core::prelude::v1::test]
    fn old_opencode_tool_rows_get_titles_and_reasoning_duplicates_are_hidden() {
        let mut shell = json!({"kind":"tool","provider":"opencode","text":json!({
            "type":"toolCall","name":"shell","status":"completed",
            "input":{"command":"  cargo   test -p coincide-core "},
            "content":[{"type":"text","text":"ok"}]
        }).to_string()});
        normalize_opencode_tool(&mut shell);
        assert_eq!(shell["title"], "Run command");
        assert_eq!(shell["detail"], "cargo test -p coincide-core");
        assert_eq!(shell["category"], "command");
        assert_eq!(shell["status"], "completed");
        assert_eq!(shell["output"], "ok");

        let duplicate = json!({"kind":"tool","provider":"opencode","text":json!({
            "type":"reasoning","text":"thought"
        }).to_string()});
        assert!(is_duplicate_reasoning_tool(&duplicate));
        assert!(!is_duplicate_reasoning_tool(
            &json!({"kind":"reasoning","provider":"opencode"})
        ));
        let other = json!({"kind":"tool","provider":"codex","text":json!({"type":"reasoning"}).to_string()});
        assert!(!is_duplicate_reasoning_tool(&other));
    }

    #[::core::prelude::v1::test]
    fn question_tool_calls_are_hidden_in_favor_of_the_form_row() {
        let question = json!({"kind":"tool","text":json!({"type":"toolCall","name":"question","input":{"questions":[]}}).to_string()});
        assert!(is_question_tool(&question));
        for item in [
            json!({"kind":"tool","text":json!({"type":"toolCall","name":"shell"}).to_string()}),
            json!({"kind":"tool","text":"not json"}),
            json!({"kind":"reasoning","text":json!({"type":"toolCall","name":"question"}).to_string()}),
        ] {
            assert!(!is_question_tool(&item));
        }
    }

    #[::core::prelude::v1::test]
    fn tool_title_is_unicode_bounded_and_blank_titles_use_explicit_category_only() {
        let item = json!({"kind":"tool","title":"  Read\n\t設定.rs  ","category":"command"});
        assert_eq!(work_header(&item).unwrap().title, "Read 設定.rs");
        let item = json!({"kind":"tool","title":"界🦀".repeat(100)});
        let header = work_header(&item).unwrap();
        assert_eq!(header.title, format!("{}…", "界🦀".repeat(80)));
        for (category, title) in [
            ("fileChange", "File change"),
            ("read", "Read file"),
            ("other", "Tool"),
            ("unknown", "Tool activity"),
        ] {
            let item = json!({"kind":"tool","title":" \t\n","category":category});
            assert_eq!(work_header(&item).unwrap().title, title);
        }
    }
}
