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
