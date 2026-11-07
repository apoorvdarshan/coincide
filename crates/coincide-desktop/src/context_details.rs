//! Read-only context snapshots. No path lookup, file read, network or provider
//! authority: details and clipboard text come only from already attached data.
use anyhow::{Context, Result, ensure};
use serde_json::Value;
use uuid::Uuid;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    Draft,
    Message(String),
}
#[derive(Clone, Debug)]
pub struct Selection {
    pub thread: String,
    pub source: Source,
    pub card: String,
    expected: Value,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Details {
    pub title: String,
    pub subtitle: Option<String>,
    pub comment: Option<String>,
    pub body: String,
    pub copy: String,
    pub code: bool,
    pub file_path_only: bool,
}
impl Selection {
    pub fn open(
        thread: &Value,
        source: Source,
        card: String,
        expected: Value,
    ) -> Result<(Self, Details)> {
        let id = thread["id"]
            .as_str()
            .filter(|id| !id.is_empty())
            .context("No conversation selected")?;
        let selection = Self {
            thread: id.into(),
            source,
            card,
            expected,
        };
        let details = selection
            .current(Some(thread))?
            .context("The context source changed; open the card again")?;
        Ok((selection, details))
    }
    pub fn current(&self, thread: Option<&Value>) -> Result<Option<Details>> {
        let Some(thread) = thread.filter(|thread| thread["id"] == self.thread) else {
            return Ok(None);
        };
        let (source, raw) = match &self.source {
            Source::Draft => {
                let source = thread.get("draftContext").unwrap_or(&Value::Null);
                (source, source)
            }
            Source::Message(id) => {
                let Some(items) = thread["items"].as_array() else {
                    return Ok(None);
                };
                let mut matches = items.iter().filter(|item| {
                    item["id"]
                        .as_str()
                        .is_some_and(|stored| same_id(stored, id))
                });
                let Some(item) = matches.next() else {
                    return Ok(None);
                };
                if matches.next().is_some() {
                    return Ok(None);
                }
                (item, item.get("context").unwrap_or(&Value::Null))
            }
        };
        if source != &self.expected {
            return Ok(None);
        }
        coincide_core::composer_context::validate(raw)?;
        let id = Uuid::parse_str(&self.card)?;
        let mut matches = raw
            .as_array()
            .context("Attached context is unavailable")?
            .iter()
            .filter(|row| row["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(id));
        let Some(card) = matches.next() else {
            return Ok(None);
        };
        ensure!(matches.next().is_none(), "Context identity is ambiguous");
        Ok(Some(details(card)?))
    }
}
fn same_id(left: &str, right: &str) -> bool {
    match (Uuid::parse_str(left), Uuid::parse_str(right)) {
        (Ok(a), Ok(b)) => a == b,
        _ => left == right,
    }
}
fn first_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("")
        .chars()
        .take(160)
        .collect()
}
fn filename(path: &str) -> &str {
    path.rsplit(['/', '\\'])
        .find(|part| !part.is_empty())
        .unwrap_or(path)
}
fn range(card: &Value) -> String {
    match (card["lineStart"].as_u64(), card["lineEnd"].as_u64()) {
        (Some(start), Some(end)) if start == end => format!("line {start}"),
        (Some(start), Some(end)) => format!("lines {start}–{end}"),
        _ => String::new(),
    }
}
pub fn details(card: &Value) -> Result<Details> {
    coincide_core::composer_context::validate(&Value::Array(vec![card.clone()]))?;
    let read = |key: &str| card[key].as_str().unwrap_or("").to_owned();
    let kind = card["kind"].as_str().context("Context kind is missing")?;
    let (mut title, mut subtitle, mut comment, body, code, file_path_only) = match kind {
        "quote" => {
            let title = card["provider"]
                .as_str()
                .map(|provider| {
                    format!(
                        "Replying to {}",
                        match provider {
                            "claude" => "Claude",
                            "codex" => "Codex",
                            "cursor" => "Cursor",
                            "grok" => "Grok",
                            "opencode" => "OpenCode",
                            "antigravity" => "Antigravity",
                            other => other,
                        }
                    )
                })
                .unwrap_or_else(|| "Quote".into());
            (title, None, None, read("text"), false, false)
        }
        "terminal" => {
            let location = range(card);
            let title = if location.is_empty() {
                read("terminal")
            } else {
                format!("{}, {location}", read("terminal"))
            };
            (
                title,
                card["directory"].as_str().map(str::to_owned),
                None,
                read("text"),
                true,
                false,
            )
        }
        "diff-comment" => {
            let path = read("path");
            let title = format!(
                "{} {}{}",
                filename(&path),
                range(card),
                if card["isBeforeChange"] == true {
                    " (before)"
                } else {
                    ""
                }
            );
            (
                title,
                Some(path),
                Some(read("comment")),
                read("diff"),
                true,
                false,
            )
        }
        "window-text" => (
            format!("Window text from {}", read("app")),
            card["title"].as_str().map(str::to_owned),
            None,
            read("text"),
            false,
            false,
        ),
        "file" => {
            let path = read("path");
            (filename(&path).to_owned(), None, None, path, false, true)
        }
        _ => anyhow::bail!("This saved context kind is unsupported; its original data is retained"),
    };
    // Validation preserves all future fields in the saved card. Only the known
    // bounded presentation fields are projected; nothing is silently rewritten.
    if title.is_empty() {
        title = "Attached reference".into();
    }
    subtitle = subtitle.filter(|value| !value.is_empty());
    comment = comment.filter(|value| !value.is_empty());
    let copy = if let Some(comment) = &comment {
        format!("{comment}\n\n{body}")
    } else {
        body.clone()
    };
    Ok(Details {
        title,
        subtitle,
        comment,
        body,
        copy,
        code,
        file_path_only,
    })
}
pub fn preview(card: &Value) -> String {
    match card["kind"].as_str() {
        Some("window-text") => card["title"]
            .as_str()
            .map(first_line)
            .unwrap_or_else(|| first_line(card["text"].as_str().unwrap_or(""))),
        Some("diff-comment") => first_line(card["comment"].as_str().unwrap_or("")),
        _ => ["text", "path"]
            .iter()
            .find_map(|key| card[*key].as_str())
            .map(first_line)
            .unwrap_or_else(|| "Saved data retained".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn card(kind: &str) -> Value {
        json!({"id":Uuid::new_v4(),"kind":kind})
    }
    #[::core::prelude::v1::test]
    fn full_unicode_window_text_respects_byte_limit_without_preview_truncation() {
        let text = format!("{}ab", "中".repeat(10666));
        assert_eq!(text.len(), 32000);
        let mut row = card("window-text");
        row["app"] = json!("Fixture App");
        row["title"] = json!("Fixture window");
        row["text"] = json!(text);
        row["future"] = json!({"preserve":7});
        let before = row.clone();
        let result = details(&row).unwrap();
        assert_eq!(result.title, "Window text from Fixture App");
        assert_eq!(result.body, text);
        assert_eq!(result.copy, text);
        assert_eq!(result.subtitle.as_deref(), Some("Fixture window"));
        assert_eq!(preview(&row), "Fixture window");
        assert_eq!(row, before);
        row["text"] = json!(format!("{text}x"));
        assert!(details(&row).is_err());
    }
    #[::core::prelude::v1::test]
    fn quote_terminal_and_diff_details_keep_all_whitespace_subtitles_and_comments() {
        let mut quote = card("quote");
        quote["provider"] = json!("codex");
        quote["text"] = json!("  quoted text\nsecond line\n ");
        let result = details(&quote).unwrap();
        assert_eq!(result.title, "Replying to Codex");
        assert_eq!(result.copy, quote["text"].as_str().unwrap());
        assert!(!result.code);
        let mut terminal = card("terminal");
        terminal["terminal"] = json!("Shell 2");
        terminal["directory"] = json!("/private/fixture");
        terminal["lineStart"] = json!(12);
        terminal["lineEnd"] = json!(14);
        terminal["text"] = json!("x".repeat(64000));
        let result = details(&terminal).unwrap();
        assert_eq!(result.title, "Shell 2, lines 12–14");
        assert_eq!(result.body.len(), 64000);
        assert_eq!(result.subtitle.as_deref(), Some("/private/fixture"));
        assert!(result.code);
        let mut diff = card("diff-comment");
        diff["path"] = json!("/fixture/src/main.rs");
        diff["lineStart"] = json!(4);
        diff["lineEnd"] = json!(4);
        diff["isBeforeChange"] = json!(true);
        diff["diff"] = json!("-old\n+new\n");
        diff["comment"] = json!("  fixture note  ");
        let result = details(&diff).unwrap();
        assert_eq!(result.title, "main.rs line 4 (before)");
        assert_eq!(result.subtitle.as_deref(), Some("/fixture/src/main.rs"));
        assert_eq!(result.copy, "  fixture note  \n\n-old\n+new\n");
    }
    #[::core::prelude::v1::test]
    fn draft_selection_invalidates_on_thread_card_or_any_source_change() {
        let mut row = card("quote");
        row["text"] = json!("private fixture quote");
        let raw = json!([row]);
        let thread = json!({"id":"thread-one","draftContext":raw,"items":[]});
        let (selection, _) = Selection::open(
            &thread,
            Source::Draft,
            row["id"].as_str().unwrap().into(),
            raw.clone(),
        )
        .unwrap();
        assert!(selection.current(Some(&thread)).unwrap().is_some());
        let mut changed = thread.clone();
        changed["id"] = json!("thread-two");
        assert!(selection.current(Some(&changed)).unwrap().is_none());
        changed = thread.clone();
        changed["draftContext"][0]["future"] = json!(1);
        assert!(selection.current(Some(&changed)).unwrap().is_none());
        changed = thread.clone();
        changed["draftContext"] = json!([]);
        assert!(selection.current(Some(&changed)).unwrap().is_none());
        assert!(selection.current(None).unwrap().is_none());
        assert!(
            Selection::open(
                &changed,
                Source::Draft,
                row["id"].as_str().unwrap().into(),
                raw
            )
            .is_err()
        );
    }
    #[::core::prelude::v1::test]
    fn sent_card_pins_exact_item_source_and_never_falls_back_to_draft_or_another_item() {
        let mut row = card("window-text");
        row["app"] = json!("Fixture App");
        row["text"] = json!("Fixture text");
        let item = json!({"id":"item-one","text":"Original message","context":[row]});
        let thread = json!({"id":"thread-one","draftContext":[row],"items":[item]});
        let (selection, _) = Selection::open(
            &thread,
            Source::Message("item-one".into()),
            row["id"].as_str().unwrap().into(),
            item.clone(),
        )
        .unwrap();
        let mut changed = thread.clone();
        changed["items"][0]["text"] = json!("Replaced message");
        assert!(selection.current(Some(&changed)).unwrap().is_none());
        changed = thread.clone();
        changed["items"][0]["id"] = json!("item-two");
        assert!(selection.current(Some(&changed)).unwrap().is_none());
        changed = thread.clone();
        changed["items"] = json!([item, item]);
        assert!(selection.current(Some(&changed)).unwrap().is_none());
    }
    #[::core::prelude::v1::test]
    fn ambiguous_unsupported_or_malformed_context_has_no_detail_or_copy_authority() {
        let mut row = card("quote");
        row["text"] = json!("Fixture quote");
        let raw = json!([row, row]);
        let thread = json!({"id":"thread","draftContext":raw});
        assert!(
            Selection::open(
                &thread,
                Source::Draft,
                row["id"].as_str().unwrap().into(),
                raw
            )
            .is_err()
        );
        let future = json!({"id":Uuid::new_v4(),"kind":"future","opaque":{"keep":true}});
        let before = future.clone();
        assert!(details(&future).is_err());
        assert_eq!(future, before);
        assert!(details(&json!({"kind":"quote","text":"missing identity"})).is_err());
    }
    #[::core::prelude::v1::test]
    fn file_details_are_only_literal_paths_without_disk_lookup_or_uri_interpretation() {
        let mut row = card("file");
        row["path"] = json!("/nonexistent-private-fixture/notes.txt");
        let result = details(&row).unwrap();
        assert_eq!(result.title, "notes.txt");
        assert_eq!(result.body, "/nonexistent-private-fixture/notes.txt");
        assert_eq!(result.copy, result.body);
        assert!(result.file_path_only);
    }
}
