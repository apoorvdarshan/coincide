use super::*;

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
    let title = match name {
        "shell" | "bash" => input["command"].as_str().and_then(bounded_title),
        "read" | "write" | "edit" | "patch" | "multiedit" => input["filePath"]
            .as_str()
            .or_else(|| input["path"].as_str())
            .and_then(bounded_title),
        "grep" | "glob" | "search" => input["pattern"].as_str().and_then(bounded_title),
        "webfetch" => input["url"].as_str().and_then(bounded_title),
        "task" => input["description"].as_str().and_then(bounded_title),
        "question" => input["questions"]
            .as_array()
            .and_then(|questions| questions.first())
            .and_then(|question| question["question"].as_str())
            .and_then(bounded_title)
            .or_else(|| Some("Question".into())),
        _ => bounded_title(name),
    };
    if let Some(title) = title.filter(|title| !title.is_empty()) {
        if item.get("title").is_null_or_empty() {
            item["title"] = json!(title);
        }
        if item.get("detail").is_null_or_empty() {
            item["detail"] = json!(title);
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
    fn old_opencode_tool_rows_get_titles_and_reasoning_duplicates_are_hidden() {
        let mut shell = json!({"kind":"tool","provider":"opencode","text":json!({
            "type":"toolCall","name":"shell","status":"completed",
            "input":{"command":"  cargo   test -p coincide-core "},
            "content":[{"type":"text","text":"ok"}]
        }).to_string()});
        normalize_opencode_tool(&mut shell);
        assert_eq!(shell["title"], "cargo test -p coincide-core");
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
