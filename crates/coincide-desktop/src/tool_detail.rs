//! Swift's TranscriptToolCell and TranscriptToolDetail: a tool call's one-line
//! header (category symbol, title with code spans, duration, status) and its
//! expanded panel. Commands read "$ <command>" with shell coloring, file
//! changes color their diff, JSON is pretty-printed, ANSI codes are stripped
//! and long output keeps only its end. Coloring is ChatSyntaxHighlighter's
//! single forward scan for the grammars this panel uses.
use super::*;
use gpui_kit::assets::IconName;
use serde_json::Value;
use std::ops::Range;

/// Output beyond this is trimmed from the front; the end of a log matters most.
const OUTPUT_LIMIT: usize = 60_000;
/// Above this size text is shown plain to keep long outputs responsive.
const HIGHLIGHT_LIMIT: usize = 120_000;
const TRIMMED: &str = "… earlier output trimmed …";

pub(super) fn category(item: &Value) -> &str {
    item["category"].as_str().unwrap_or("other")
}

/// The SF Symbol each Swift ToolCategory draws, as its closest Lucide icon.
pub(super) fn icon(category: &str) -> IconName {
    match category {
        "command" => IconName::SquareTerminal,
        "fileChange" => IconName::PencilLine,
        "read" => IconName::FileText,
        "search" => IconName::Search,
        "web" => IconName::Globe,
        "mcp" => IconName::Puzzle,
        "task" => IconName::Users,
        "todo" => IconName::ListChecks,
        "reasoning" => IconName::Brain,
        _ => IconName::Wrench,
    }
}

fn trimmed<'a>(item: &'a Value, key: &str) -> Option<&'a str> {
    item[key]
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

/// Whether the call has anything to expand: a detail besides its title, or output.
pub(super) fn has_detail(item: &Value) -> bool {
    let detail = trimmed(item, "detail");
    detail.is_some_and(|detail| Some(detail) != item["title"].as_str())
        || item["output"]
            .as_str()
            .is_some_and(|text| !text.trim().is_empty())
        || item["text"]
            .as_str()
            .is_some_and(|text| !text.trim().is_empty())
}

/// "2m 13s" once a call that took at least a second has finished.
pub(super) fn duration_text(item: &Value) -> Option<String> {
    if item["status"] == "running" {
        return None;
    }
    let end = super::chat_turns::seconds(&item["completedAt"])?;
    let start = super::chat_turns::seconds(&item["createdAt"])?;
    let duration = end - start;
    (duration >= 1.).then(|| super::chat_turns::duration_label(duration))
}

/// A one-line label with its Markdown code spans unwrapped: the text to draw
/// and the byte ranges to draw in the code font.
pub(super) fn inline_code(label: &str) -> (String, Vec<Range<usize>>) {
    // Titles draw on one line; a command title is often a whole script.
    fn push(text: &mut String, part: &str) {
        text.extend(
            part.chars()
                .map(|c| if c.is_whitespace() { ' ' } else { c }),
        );
    }
    let mut text = String::with_capacity(label.len());
    let mut code = Vec::new();
    let mut rest = label;
    while let Some(open) = rest.find('`') {
        let Some(close) = rest[open + 1..].find('`').map(|close| open + 1 + close) else {
            break;
        };
        push(&mut text, &rest[..open]);
        let start = text.len();
        push(&mut text, &rest[open + 1..close]);
        if text.len() > start {
            code.push(start..text.len());
        }
        rest = &rest[close + 1..];
    }
    push(&mut text, rest);
    (text, code)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Token {
    Keyword,
    String,
    Comment,
    Number,
    Call,
    Property,
    Variable,
    /// The "$ " prompt, file-change output and diff headers.
    Secondary,
    Hunk,
    Addition,
    Deletion,
}

#[derive(Debug, Default, PartialEq)]
pub(super) struct Detail {
    pub text: String,
    pub spans: Vec<(Range<usize>, Token)>,
}

impl Detail {
    fn append(&mut self, text: &str) -> Range<usize> {
        let start = self.text.len();
        self.text.push_str(text);
        start..self.text.len()
    }
    fn separate(&mut self) {
        if !self.text.is_empty() {
            self.append("\n\n");
        }
    }
    fn structured(&mut self, text: &str) {
        let parsed = text
            .starts_with(['{', '['])
            .then(|| serde_json::from_str::<Value>(text).ok())
            .flatten();
        if let Some(value) = parsed {
            let pretty = serde_json::to_string_pretty(&value).unwrap_or_else(|_| text.into());
            let range = self.append(&pretty);
            self.highlight(range, Grammar::Json);
        } else if looks_like_diff(text) {
            let range = self.append(text);
            self.diff(range);
        } else {
            self.append(text);
        }
    }
    fn highlight(&mut self, range: Range<usize>, grammar: Grammar) {
        if range.len() > HIGHLIGHT_LIMIT {
            return;
        }
        let offset = range.start;
        let spans = scan(&self.text[range], grammar);
        self.spans.extend(
            spans
                .into_iter()
                .map(|(span, token)| (span.start + offset..span.end + offset, token)),
        );
    }
    /// Swift colors diff headers and hunks, and fills changed lines.
    fn diff(&mut self, range: Range<usize>) {
        if range.len() > HIGHLIGHT_LIMIT {
            return;
        }
        let mut start = range.start;
        for line in self.text[range.clone()].split('\n') {
            let end = start + line.trim_end_matches('\r').len();
            let token = if ["+++", "---", "diff", "inde"]
                .iter()
                .any(|prefix| line.starts_with(prefix))
            {
                Some(Token::Secondary)
            } else if line.starts_with("@@") {
                Some(Token::Hunk)
            } else if line.starts_with('+') {
                Some(Token::Addition)
            } else if line.starts_with('-') {
                Some(Token::Deletion)
            } else {
                None
            };
            if let Some(token) = token
                && end > start
            {
                self.spans.push((start..end, token));
            }
            start += line.len() + 1;
        }
    }
}

/// Line endings and NULs as the Markdown parser hands the code block back, so
/// highlight ranges stay on the text it draws.
fn normalized(text: &str) -> String {
    text.replace("\r\n", "\n")
        .replace('\r', "\n")
        .replace('\0', "\u{fffd}")
}

/// The expanded view of a tool call: the command, diff or input, then its output.
pub(super) fn render(item: &Value) -> Detail {
    let mut detail = Detail::default();
    let title = item["title"].as_str().map(str::trim);
    let input = trimmed(item, "detail").map(normalized);
    let input = input.as_deref();
    let result = item["output"]
        .as_str()
        .or_else(|| item["text"].as_str())
        .and_then(clean_output)
        .map(|result| normalized(&result));
    match category(item) {
        "command" => {
            let command = input
                .map(str::to_owned)
                .or_else(|| title.map(strip_ticks))
                .unwrap_or_default();
            if !command.is_empty() {
                let prompt = detail.append("$ ");
                detail.spans.push((prompt, Token::Secondary));
                let range = detail.append(&command);
                detail.highlight(range, Grammar::Shell);
            }
            if let Some(result) = result {
                detail.separate();
                // Rust-run calls keep the provider's own JSON as their body.
                if result.starts_with(['{', '[']) {
                    detail.structured(&result);
                } else {
                    detail.append(&result);
                }
            }
        }
        "fileChange" => {
            if let Some(input) = input.filter(|input| Some(*input) != title) {
                let range = detail.append(input);
                if looks_like_diff(input) {
                    detail.diff(range);
                }
            }
            if let Some(result) = result {
                detail.separate();
                let range = detail.append(&result);
                detail.spans.push((range, Token::Secondary));
            }
        }
        _ => {
            if let Some(input) = input.filter(|input| Some(*input) != title) {
                detail.structured(input);
            }
            if let Some(result) = result {
                detail.separate();
                detail.structured(&result);
            }
        }
    }
    detail
}

/// Text without ANSI escape sequences, trimmed, and cut to its last 60,000
/// characters behind a marker.
pub(super) fn clean_output(text: &str) -> Option<String> {
    let mut cleaned = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(escape) = rest.find('\u{1b}') {
        cleaned.push_str(&rest[..escape]);
        let tail = &rest[escape..];
        match ansi_length(tail) {
            Some(length) => rest = &tail[length..],
            None => {
                cleaned.push('\u{1b}');
                rest = &tail[1..];
            }
        }
    }
    cleaned.push_str(rest);
    let cleaned = cleaned.trim();
    if cleaned.is_empty() {
        return None;
    }
    let count = cleaned.chars().count();
    if count <= OUTPUT_LIMIT {
        return Some(cleaned.to_owned());
    }
    let (start, _) = cleaned
        .char_indices()
        .nth(count - OUTPUT_LIMIT)
        .unwrap_or((0, ' '));
    Some(format!("{TRIMMED}\n{}", &cleaned[start..]))
}

/// The length of a CSI sequence `ESC [ params intermediates final` at the
/// start of `text`, as Swift's `\e\[[0-9;?]*[ -/]*[@-~]`.
fn ansi_length(text: &str) -> Option<usize> {
    let bytes = text.as_bytes();
    if bytes.get(1) != Some(&b'[') {
        return None;
    }
    let mut index = 2;
    while bytes
        .get(index)
        .is_some_and(|b| b.is_ascii_digit() || *b == b';' || *b == b'?')
    {
        index += 1;
    }
    while bytes.get(index).is_some_and(|b| (b' '..=b'/').contains(b)) {
        index += 1;
    }
    bytes
        .get(index)
        .is_some_and(|b| (b'@'..=b'~').contains(b))
        .then_some(index + 1)
}

fn strip_ticks(title: &str) -> String {
    match (title.find('`'), title.rfind('`')) {
        (Some(open), Some(close)) if open < close => title[open + 1..close].to_owned(),
        _ => title.to_owned(),
    }
}

/// Whether text looks like a unified diff.
pub(super) fn looks_like_diff(text: &str) -> bool {
    let (mut hunks, mut changes) = (0, 0);
    for line in text.split('\n').take(400) {
        if line.starts_with("@@")
            || line.starts_with("+++ ")
            || line.starts_with("--- ")
            || line.starts_with("diff --git")
        {
            hunks += 1;
        } else if line.starts_with(['+', '-']) {
            changes += 1;
        }
    }
    hunks > 0 && changes > 0
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Grammar {
    Shell,
    Json,
}

const SHELL_KEYWORDS: &[&str] = &[
    "if",
    "then",
    "else",
    "elif",
    "fi",
    "for",
    "while",
    "until",
    "do",
    "done",
    "case",
    "esac",
    "in",
    "function",
    "return",
    "export",
    "local",
    "readonly",
    "set",
    "unset",
    "source",
    "alias",
    "exit",
    "FROM",
    "RUN",
    "CMD",
    "COPY",
    "ADD",
    "WORKDIR",
    "ENV",
    "ARG",
    "EXPOSE",
    "ENTRYPOINT",
    "USER",
    "VOLUME",
    "LABEL",
];

/// Swift's Scanner for the shell and JSON grammars, over UTF-8 bytes. Every
/// byte of a multi-byte character continues an identifier, so spans always
/// fall on character boundaries.
fn scan(text: &str, grammar: Grammar) -> Vec<(Range<usize>, Token)> {
    let bytes = text.as_bytes();
    let n = bytes.len();
    let ident_start = |b: u8| b.is_ascii_alphabetic() || b == b'_' || b > 0x7f;
    let ident_part = |b: u8| ident_start(b) || b.is_ascii_digit();
    let matches = |pattern: &[u8], at: usize| bytes[at..].starts_with(pattern);
    let skip_spaces = |mut at: usize| {
        while at < n && (bytes[at] == b' ' || bytes[at] == b'\t') {
            at += 1;
        }
        at
    };
    let command_position = |position: usize| {
        let mut cursor = position;
        while cursor > 0 && (bytes[cursor - 1] == b' ' || bytes[cursor - 1] == b'\t') {
            cursor -= 1;
        }
        if cursor == 0 {
            return true;
        }
        match bytes[cursor - 1] {
            b'\n' | b'|' | b';' | b'(' | b'&' => true,
            b'$' | b'%' => cursor == 1 || bytes[cursor - 2] == b'\n',
            _ => false,
        }
    };
    type Comments = (&'static [u8], Option<(&'static [u8], &'static [u8])>);
    let (line_comment, block_comment): Comments = match grammar {
        Grammar::Shell => (&b"#"[..], None),
        Grammar::Json => (&b"//"[..], Some((&b"/*"[..], &b"*/"[..]))),
    };
    let mut spans = Vec::new();
    let mut index = 0;
    while index < n {
        let start = index;
        let unit = bytes[index];
        let mut token = |token: Token, end: usize| {
            if end > start {
                spans.push((start..end, token));
            }
        };
        if let Some((open, close)) = block_comment
            && matches(open, index)
        {
            index += open.len();
            while index < n && !matches(close, index) {
                index += 1;
            }
            index = n.min(index + close.len());
            token(Token::Comment, index);
            continue;
        }
        if matches(line_comment, index) && (index == 0 || !ident_part(bytes[index - 1])) {
            while index < n && bytes[index] != b'\n' {
                index += 1;
            }
            token(Token::Comment, index);
            continue;
        }
        if grammar == Grammar::Shell && unit == b'$' {
            index += 1;
            if index < n && bytes[index] == b'{' {
                while index < n && bytes[index] != b'}' && bytes[index] != b'\n' {
                    index += 1;
                }
                if index < n && bytes[index] == b'}' {
                    index += 1;
                }
            } else {
                while index < n && ident_part(bytes[index]) {
                    index += 1;
                }
            }
            token(Token::Variable, index);
            continue;
        }
        if unit == b'"' || (grammar == Grammar::Shell && unit == b'\'') {
            index += 1;
            while index < n {
                let current = bytes[index];
                if current == b'\\' && (grammar != Grammar::Shell || unit != b'\'') {
                    index += 2;
                    continue;
                }
                if current == b'\n' {
                    break;
                }
                index += 1;
                if current == unit {
                    break;
                }
            }
            index = index.min(n);
            let next = skip_spaces(index);
            let key = grammar == Grammar::Json && next < n && bytes[next] == b':';
            token(if key { Token::Property } else { Token::String }, index);
            continue;
        }
        if unit.is_ascii_digit()
            || (unit == b'.' && index + 1 < n && bytes[index + 1].is_ascii_digit())
        {
            index += 1;
            while index < n && (ident_part(bytes[index]) || bytes[index] == b'.') {
                if bytes[index] == b'.' && index + 1 < n && !bytes[index + 1].is_ascii_digit() {
                    break;
                }
                index += 1;
            }
            token(Token::Number, index);
            continue;
        }
        if ident_start(unit) {
            while index < n && ident_part(bytes[index]) {
                index += 1;
            }
            let word = &text[start..index];
            let class = match grammar {
                Grammar::Shell if SHELL_KEYWORDS.contains(&word) => Some(Token::Keyword),
                Grammar::Shell if command_position(start) => Some(Token::Call),
                Grammar::Json if ["true", "false", "null"].contains(&word) => Some(Token::Keyword),
                _ => None,
            };
            if let Some(class) = class {
                token(class, index);
            }
            continue;
        }
        index += 1;
    }
    spans
}

/// ChatSyntaxHighlighter's Xcode-derived palette and the diff fills.
pub(super) fn token_style(token: Token, dark: bool) -> gpui_kit::HighlightStyle {
    let pick = |light: u32, dark_color: u32| -> gpui_kit::Hsla {
        gpui_kit::rgb(if dark { dark_color } else { light }).into()
    };
    let mut style = gpui_kit::HighlightStyle::default();
    match token {
        Token::Keyword => style.color = Some(pick(0x9B2393, 0xFC5FA3)),
        Token::String => style.color = Some(pick(0xC41A16, 0xFC6A5D)),
        Token::Comment => style.color = Some(pick(0x5D6C79, 0x7F8C98)),
        Token::Number => style.color = Some(pick(0x1C00CF, 0xD0BF69)),
        Token::Variable => style.color = Some(pick(0x0B4F79, 0x5DD8FF)),
        Token::Call => style.color = Some(pick(0x326D74, 0x67B7A4)),
        Token::Property => style.color = Some(pick(0x6C36A9, 0xA167E6)),
        Token::Secondary => style.color = Some(pick(0x6E6E73, 0x98989D)),
        Token::Hunk => style.color = Some(pick(0x007AFF, 0x0A84FF)),
        Token::Addition => style.background_color = Some(pick(0x34C759, 0x30D158).opacity(0.16)),
        Token::Deletion => style.background_color = Some(pick(0xFF3B30, 0xFF453A).opacity(0.16)),
    }
    style
}

/// A fenced code block that holds `text` verbatim: its fence is longer than
/// any backtick run inside, so no output line can close it.
pub(super) fn fenced(text: &str) -> String {
    let longest = text
        .split(|c| c != '`')
        .map(str::len)
        .max()
        .unwrap_or_default();
    let fence = "`".repeat(longest.max(2) + 1);
    format!("{fence}\n{text}\n{fence}")
}

impl super::Coincide {
    /// A tool call's row: TranscriptToolCell's one-line header and, while
    /// expanded, its detail panel capped at Swift's 320-point height.
    /// Swift's TranscriptGroupCell: consecutive tool/reasoning rows collapse
    /// into one line. While a member runs, the line names that activity;
    /// otherwise it summarizes the finished work.
    pub(super) fn group_row(
        &mut self,
        source: &str,
        item_id: &str,
        index: usize,
        items: &[Value],
        expanded: bool,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let running = items
            .iter()
            .rev()
            .find(|item| item["status"].as_str() == Some("running"));
        let title = if let Some(running) = running {
            if running["kind"] == "reasoning" {
                "Thinking".to_owned()
            } else {
                super::presentation::group_category_label(
                    running["category"].as_str().unwrap_or("other"),
                )
                .to_owned()
            }
        } else {
            super::presentation::group_summary(items)
        };
        let group_icon = if let Some(running) = running {
            if running["kind"] == "reasoning" {
                IconName::Brain
            } else {
                icon(running["category"].as_str().unwrap_or("other"))
            }
        } else {
            super::presentation::group_icon(items)
        };
        let failed = items
            .iter()
            .any(|item| item["kind"] == "tool" && item["status"] == "failed");
        let secondary = self.color(0xe4e9f2).opacity(0.6);
        let failure = rgb(if self.appearance_dark {
            0xFF453A
        } else {
            0xFF3B30
        });
        let toggle = {
            let source = source.to_owned();
            let anchor = item_id.to_owned();
            move |this: &mut Self, cx: &mut Context<Self>| {
                this.toggle_work_group(&source, &anchor, index, cx)
            }
        };
        let toggle_click = toggle.clone();
        div()
            .flex()
            .w_full()
            .px(px(super::presentation::CONTENT_GUTTER))
            .justify_center()
            .child(
                div()
                    .id(SharedString::from(format!(
                        "message-row-{source}-{item_id}"
                    )))
                    .flex()
                    .flex_col()
                    .w_full()
                    .min_w_0()
                    .max_w(px(super::presentation::CONTENT_WIDTH))
                    .pl(px(super::presentation::RAIL_GUTTER))
                    .mb(px(4.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .h(px(26.))
                            .min_w_0()
                            .w_full()
                            .text_color(secondary)
                            .text_size(px((self.conversation_font_size() - 1.).max(10.)))
                            .child(Icon::new(group_icon).xsmall().text_color(if failed {
                                Hsla::from(failure)
                            } else {
                                Hsla::from(secondary)
                            }))
                            .child(
                                div()
                                    .id(SharedString::from(format!(
                                        "group-title-{source}-{item_id}"
                                    )))
                                    .min_w_0()
                                    .flex_1()
                                    .truncate()
                                    .cursor_pointer()
                                    .on_click(
                                        cx.listener(move |this, _, _, cx| toggle_click(this, cx)),
                                    )
                                    .child(title),
                            )
                            .when(running.is_some(), |row| {
                                row.child(
                                    Icon::new(IconName::LoaderCircle)
                                        .xsmall()
                                        .text_color(Hsla::from(secondary)),
                                )
                            })
                            .child(
                                Button::new(SharedString::from(format!(
                                    "group-expand-{source}-{item_id}"
                                )))
                                .accessibility_label(if expanded {
                                    "Collapse work group"
                                } else {
                                    "Expand work group"
                                })
                                .icon(if expanded {
                                    IconName::ChevronDown
                                } else {
                                    IconName::ChevronRight
                                })
                                .ghost()
                                .compact()
                                .xsmall()
                                .on_click(cx.listener(move |this, _, _, cx| toggle(this, cx))),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// Swift's TranscriptQuestionCell: one work-log line for the request, with
    /// its answers underneath once resolved. The request itself is answered in
    /// the composer banner, never by dumping the provider payload here.
    pub(super) fn question_row(
        &mut self,
        source: &str,
        item_id: &str,
        item: &Value,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> AnyElement {
        let payload = serde_json::from_str::<Value>(item["text"].as_str().unwrap_or(""))
            .unwrap_or(Value::Null);
        let questions = payload["questions"].as_array().cloned().unwrap_or_default();
        let first = questions.first();
        // Swift's work row names the request by its title, else the first
        // question prompt; the banner heading uses the shorter header.
        let title = payload["title"]
            .as_str()
            .filter(|title| !title.trim().is_empty())
            .or_else(|| first.and_then(|question| question["question"].as_str()))
            .unwrap_or("Question")
            .to_owned();
        let external = item["externalID"].as_str().unwrap_or_default();
        let waiting = self.pending_requests.iter().any(|request| {
            request["requestId"].as_str() == Some(external)
                && request["method"] == "item/tool/requestUserInput"
        });
        let declined = item["status"].as_str() == Some("declined");
        let answered = item["answers"]
            .as_object()
            .is_some_and(|answers| !answers.is_empty());
        let secondary = self.color(0xe4e9f2).opacity(0.6);
        let tertiary = self.color(0xe4e9f2).opacity(0.42);
        let warning = rgb(if self.appearance_dark {
            0xFF9F0A
        } else {
            0xFF9500
        });
        let icon_color = if waiting {
            Hsla::from(warning)
        } else {
            Hsla::from(secondary)
        };
        let detail = if waiting {
            "Answer below"
        } else if declined {
            "Not answered"
        } else if answered {
            ""
        } else {
            "Resolved by the agent"
        };
        let status_icon = if waiting {
            Some((IconName::Clock, Hsla::from(warning)))
        } else if declined {
            Some((IconName::Ban, Hsla::from(warning)))
        } else {
            Some((IconName::Check, Hsla::from(tertiary)))
        };
        let mut answers = Vec::new();
        if let Some(saved) = item["answers"].as_object() {
            for question in &questions {
                let id = question["id"].as_str().unwrap_or_default();
                let values = saved
                    .get(id)
                    .and_then(|value| value.as_array().or_else(|| value["answers"].as_array()))
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(|value| value.as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                    .unwrap_or_default();
                if values.is_empty() {
                    continue;
                }
                let label = question["header"]
                    .as_str()
                    .filter(|header| !header.trim().is_empty())
                    .or_else(|| question["question"].as_str())
                    .unwrap_or("Answer");
                answers.push((label.to_owned(), values));
            }
        }
        div()
            .flex()
            .w_full()
            .px(px(super::presentation::CONTENT_GUTTER))
            .justify_center()
            .child(
                div()
                    .id(SharedString::from(format!(
                        "message-row-{source}-{item_id}"
                    )))
                    .flex()
                    .flex_col()
                    .w_full()
                    .min_w_0()
                    .max_w(px(super::presentation::CONTENT_WIDTH))
                    .pl(px(super::presentation::RAIL_GUTTER))
                    .mb(px(4.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .h(px(26.))
                            .min_w_0()
                            .w_full()
                            .text_size(px((self.conversation_font_size() - 1.).max(10.)))
                            .child(
                                Icon::new(IconName::MessageCircleQuestionMark)
                                    .xsmall()
                                    .text_color(icon_color),
                            )
                            .child(
                                div()
                                    .min_w_0()
                                    .flex_shrink_1()
                                    .truncate()
                                    .text_color(secondary)
                                    .child(title),
                            )
                            .when(!detail.is_empty(), |row| {
                                row.child(
                                    div()
                                        .flex_shrink_0()
                                        .text_xs()
                                        .text_color(tertiary)
                                        .child(detail),
                                )
                            })
                            .when_some(status_icon, |row, (icon, color)| {
                                row.child(Icon::new(icon).xsmall().text_color(color))
                            }),
                    )
                    .children(answers.into_iter().map(|(question, answer)| {
                        div()
                            .flex()
                            .gap_1()
                            .pl(px(22.))
                            .text_size(px((self.conversation_font_size() - 2.).max(10.)))
                            .child(
                                div()
                                    .flex_shrink_0()
                                    .text_color(tertiary)
                                    .child(format!("{question}  ")),
                            )
                            .child(
                                div()
                                    .min_w_0()
                                    .truncate()
                                    .text_color(secondary)
                                    .child(answer),
                            )
                    })),
            )
            .into_any_element()
    }

    pub(super) fn tool_row(
        &mut self,
        source: &str,
        item_id: &str,
        item: &Value,
        expanded: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let header = super::presentation::work_header(item);
        let title_source = header
            .as_ref()
            .map_or("Tool activity", |header| header.title.as_str());
        let (title, code) = inline_code(title_source);
        let status = item["status"].as_str().unwrap_or_default();
        let expandable = has_detail(item);
        let expanded = expandable && expanded;
        let reasoning = item["kind"] == "reasoning";
        let preview = if reasoning && !expanded {
            thought_preview(item["text"].as_str().unwrap_or(""))
        } else {
            String::new()
        };
        let secondary = self.color(0xe4e9f2).opacity(0.6);
        let tertiary = self.color(0xe4e9f2).opacity(0.42);
        let failure = rgb(if self.appearance_dark {
            0xFF453A
        } else {
            0xFF3B30
        });
        let warning = rgb(if self.appearance_dark {
            0xFF9F0A
        } else {
            0xFF9500
        });
        let code_background = self.color(0xe4e9f2).opacity(0.08).into();
        let title_text =
            code_span_text(&title, &code, secondary.into(), code_background, window, cx);
        let status_icon = match status {
            "running" => Some((IconName::LoaderCircle, Hsla::from(secondary))),
            "completed" => Some((IconName::Check, Hsla::from(tertiary))),
            "failed" => Some((IconName::X, Hsla::from(failure))),
            "declined" => Some((IconName::Ban, Hsla::from(warning))),
            "waiting" => Some((IconName::Clock, Hsla::from(warning))),
            _ => None,
        };
        let spoken = match header.as_ref().and_then(|header| header.status) {
            Some(status) => format!("{title}, {}", status.to_lowercase()),
            None => title.clone(),
        };
        let toggle = {
            let (source, item) = (source.to_owned(), item_id.to_owned());
            move |this: &mut Self, cx: &mut Context<Self>| {
                this.toggle_item_expanded(&source, &item, cx)
            }
        };
        let header_row = div()
            .flex()
            .items_center()
            .gap(px(6.))
            .h(px(26.))
            .min_w_0()
            .w_full()
            .text_size(px((self.conversation_font_size() - 1.).max(10.)))
            .child(
                Icon::new(icon(if item["kind"] == "reasoning" {
                    "reasoning"
                } else {
                    category(item)
                }))
                .xsmall()
                .text_color(if status == "failed" {
                    Hsla::from(failure)
                } else {
                    Hsla::from(secondary)
                }),
            )
            .child(
                div()
                    .id(SharedString::from(format!("tool-title-{source}-{item_id}")))
                    .min_w_0()
                    .when(reasoning, |title| title.flex_shrink_0())
                    .when(!reasoning, |title| title.flex_1())
                    .truncate()
                    .aria_label(SharedString::from(spoken.clone()))
                    .when(expandable, |title| {
                        let toggle = toggle.clone();
                        title
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| toggle(this, cx)))
                    })
                    .child(title_text),
            )
            .when(!preview.is_empty(), |row| {
                row.child(
                    div()
                        .min_w_0()
                        .flex_1()
                        .truncate()
                        .text_color(tertiary)
                        .child(format!("  {preview}")),
                )
            })
            .when_some(duration_text(item), |row, duration| {
                row.child(
                    div()
                        .flex_shrink_0()
                        .text_xs()
                        .text_color(tertiary)
                        .child(duration),
                )
            })
            .when_some(status_icon, |row, (icon, color)| {
                row.child(Icon::new(icon).xsmall().text_color(color))
            })
            .when(expandable, |row| {
                let id = SharedString::from(format!("expand-{source}-{item_id}"));
                row.child(
                    Button::new(id.clone())
                        .accessibility_id(id)
                        .accessibility_label(SharedString::from(format!(
                            "{spoken}, {}",
                            if expanded { "Collapse" } else { "Expand" }
                        )))
                        .icon(if expanded {
                            IconName::ChevronDown
                        } else {
                            IconName::ChevronRight
                        })
                        .ghost()
                        .compact()
                        .xsmall()
                        .on_click(cx.listener(move |this, _, _, cx| toggle(this, cx))),
                )
            });
        let panel = expanded.then(|| {
            let detail = render(item);
            let dark = self.appearance_dark;
            let highlights = detail
                .spans
                .iter()
                .map(|(range, token)| (range.clone(), token_style(*token, dark)))
                .collect::<Vec<_>>();
            let body = super::transcript::highlighted(
                source,
                &format!("{item_id}/tool-detail"),
                fenced(&detail.text),
                highlights,
                window,
                cx,
            );
            div()
                .id(SharedString::from(format!(
                    "tool-detail-{source}-{item_id}"
                )))
                .ml(px(26.))
                .mt_1()
                .mb(px(6.))
                .max_h(px(320.))
                .overflow_y_scroll()
                .text_size(px((self.conversation_font_size() - 2.).max(10.)))
                .child(super::transcript::preserve_selected_copy(
                    source,
                    &format!("{item_id}/tool-detail"),
                    body,
                ))
        });
        div()
            .flex()
            .w_full()
            .px(px(super::presentation::CONTENT_GUTTER))
            .justify_center()
            .child(
                div()
                    .id(SharedString::from(format!(
                        "message-row-{source}-{item_id}"
                    )))
                    .flex()
                    .flex_col()
                    .w_full()
                    .min_w_0()
                    .max_w(px(super::presentation::CONTENT_WIDTH))
                    .pl(px(super::presentation::RAIL_GUTTER))
                    .mb(px(4.))
                    .child(header_row)
                    .children(panel),
            )
            .into_any_element()
    }
}

/// Swift's collapsed reasoning line previews the first sentence in tertiary
/// text, like TranscriptLabels.thoughtPreview.
fn thought_preview(markdown: &str) -> String {
    let start = markdown.trim_start();
    let head: String = start.chars().take(200).collect();
    let trimmed = head.trim();
    let mut flat = trimmed
        .lines()
        .next()
        .unwrap_or_default()
        .trim()
        .trim_start_matches("**")
        .trim_end_matches("**")
        .to_owned();
    if flat.is_empty() {
        flat = trimmed
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(140)
            .collect();
    }
    if let Some(end) = flat.find(['.', '!', '?'])
        && end + 1 < flat.len()
    {
        flat.truncate(end + 1);
    }
    flat
}

/// `text` with its `code` byte ranges in the theme's code font on a faint
/// backing, as TranscriptText.inlineLabel draws Markdown code spans.
pub(super) fn code_span_text(
    text: &str,
    code: &[Range<usize>],
    color: Hsla,
    code_background: Hsla,
    window: &Window,
    cx: &App,
) -> StyledText {
    let base = window.text_style().font();
    let mono = Font {
        family: cx.theme().mono_font_family.clone(),
        ..base.clone()
    };
    let run = |len: usize, font: &Font, background: Option<Hsla>| TextRun {
        len,
        font: font.clone(),
        color,
        background_color: background,
        underline: None,
        strikethrough: None,
    };
    let mut runs = Vec::new();
    let mut cursor = 0;
    for range in code {
        if range.start > cursor {
            runs.push(run(range.start - cursor, &base, None));
        }
        runs.push(run(range.len(), &mono, Some(code_background)));
        cursor = range.end;
    }
    if cursor < text.len() {
        runs.push(run(text.len() - cursor, &base, None));
    }
    StyledText::new(text.to_owned()).with_runs(runs)
}

fn item_text_empty(item_id: &str, app: &super::Coincide) -> bool {
    app.selected
        .as_ref()
        .and_then(|thread| thread["items"].as_array())
        .and_then(|items| items.iter().find(|item| item["id"] == item_id))
        .is_none_or(|item| item["text"].as_str().unwrap_or_default().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn spans_of(detail: &Detail, token: Token) -> Vec<&str> {
        detail
            .spans
            .iter()
            .filter(|(_, kind)| *kind == token)
            .map(|(range, _)| &detail.text[range.clone()])
            .collect()
    }

    #[::core::prelude::v1::test]
    fn command_reads_as_a_prompt_with_shell_coloring_then_output() {
        let item = json!({"kind":"tool","category":"command","title":"Run `ls -la`",
            "detail":"FOO=1 git status | grep \"x\" # note","text":"\u{1b}[31mout\u{1b}[0m\n"});
        let detail = render(&item);
        assert_eq!(detail.text, "$ FOO=1 git status | grep \"x\" # note\n\nout");
        assert_eq!(spans_of(&detail, Token::Secondary), vec!["$ "]);
        assert_eq!(spans_of(&detail, Token::Call), vec!["FOO", "grep"]);
        assert_eq!(spans_of(&detail, Token::String), vec!["\"x\""]);
        assert_eq!(spans_of(&detail, Token::Comment), vec!["# note"]);
        assert_eq!(spans_of(&detail, Token::Number), vec!["1"]);

        let title_only = json!({"category":"command","title":"Run `cargo test`"});
        assert_eq!(render(&title_only).text, "$ cargo test");
        let crlf = json!({"category":"command","detail":"a\r\nb","text":"x\ry\u{0}"});
        assert_eq!(render(&crlf).text, "$ a\nb\n\nx\ny\u{fffd}");
        let rust_run = json!({"category":"command","title":"printf ok",
            "text":"{\"type\":\"commandExecution\",\"aggregatedOutput\":\"ok\"}"});
        let detail = render(&rust_run);
        assert!(detail.text.starts_with("$ printf ok\n\n{\n"));
        assert!(spans_of(&detail, Token::Property).contains(&"\"type\""));
    }

    #[::core::prelude::v1::test]
    fn file_changes_color_their_diff_and_dim_the_result() {
        let diff = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n context";
        let item = json!({"category":"fileChange","title":"Edit x","detail":diff,"text":"Applied"});
        let detail = render(&item);
        assert_eq!(detail.text, format!("{diff}\n\nApplied"));
        assert_eq!(
            spans_of(&detail, Token::Secondary),
            vec!["--- a/x", "+++ b/x", "Applied"]
        );
        assert_eq!(spans_of(&detail, Token::Hunk), vec!["@@ -1 +1 @@"]);
        assert_eq!(spans_of(&detail, Token::Deletion), vec!["-old"]);
        assert_eq!(spans_of(&detail, Token::Addition), vec!["+new"]);
        let same = json!({"category":"fileChange","title":"Edit x","detail":" Edit x "});
        assert!(render(&same).text.is_empty());
        assert!(!has_detail(&same));
    }

    #[::core::prelude::v1::test]
    fn other_tools_pretty_print_json_input_and_output() {
        let item = json!({"category":"mcp","title":"Search","detail":"{\"n\":2,\"ok\":true,\"q\":\"日本\"}",
            "text":"[1, null]"});
        let detail = render(&item);
        assert_eq!(
            detail.text,
            "{\n  \"n\": 2,\n  \"ok\": true,\n  \"q\": \"日本\"\n}\n\n[\n  1,\n  null\n]"
        );
        assert_eq!(
            spans_of(&detail, Token::Property),
            vec!["\"n\"", "\"ok\"", "\"q\""]
        );
        assert_eq!(spans_of(&detail, Token::String), vec!["\"日本\""]);
        assert_eq!(spans_of(&detail, Token::Keyword), vec!["true", "null"]);
        assert_eq!(spans_of(&detail, Token::Number), vec!["2", "1"]);
        let plain = json!({"text":"{not json"});
        assert_eq!(render(&plain).text, "{not json");
        assert!(render(&plain).spans.is_empty());
    }

    #[::core::prelude::v1::test]
    fn output_is_cleaned_and_keeps_its_last_sixty_thousand_characters() {
        assert_eq!(clean_output(" \n\t "), None);
        assert_eq!(
            clean_output("a\u{1b}[1;32mb\u{1b}[?25lc\u{1b}x"),
            Some("abc\u{1b}x".into())
        );
        let long = format!("{}{}", "界".repeat(10), "z".repeat(OUTPUT_LIMIT));
        let cleaned = clean_output(&long).unwrap();
        assert_eq!(cleaned, format!("{TRIMMED}\n{}", "z".repeat(OUTPUT_LIMIT)));
        let exact = "界".repeat(OUTPUT_LIMIT);
        assert_eq!(clean_output(&exact).as_deref(), Some(exact.as_str()));
    }

    #[::core::prelude::v1::test]
    fn titles_unwrap_code_spans_on_one_line() {
        let (text, code) = inline_code("Run `ls\n-la` in `設定`");
        assert_eq!(text, "Run ls -la in 設定");
        assert_eq!(
            code.iter().map(|r| &text[r.clone()]).collect::<Vec<_>>(),
            ["ls -la", "設定"]
        );
        assert_eq!(inline_code("odd ` tick"), ("odd ` tick".into(), vec![]));
        assert_eq!(inline_code("``"), ("".into(), vec![]));
    }

    #[::core::prelude::v1::test]
    fn duration_needs_a_finished_call_of_at_least_a_second() {
        let done = json!({"status":"completed","createdAt":10.0,"completedAt":143.0});
        assert_eq!(duration_text(&done).as_deref(), Some("2m 13s"));
        let quick = json!({"createdAt":10.0,"completedAt":10.5});
        assert_eq!(duration_text(&quick), None);
        let running = json!({"status":"running","createdAt":10.0,"completedAt":143.0});
        assert_eq!(duration_text(&running), None);
        assert_eq!(duration_text(&json!({"createdAt":1.0})), None);
    }

    #[::core::prelude::v1::test]
    fn expandable_only_with_detail_or_output() {
        assert!(!has_detail(&json!({"title":"Read x","text":"  \n"})));
        assert!(has_detail(&json!({"title":"Read x","detail":"more"})));
        assert!(has_detail(&json!({"text":"output"})));
    }

    #[::core::prelude::v1::test]
    fn shell_scan_handles_variables_quotes_and_multibyte_text() {
        let spans = scan("echo ${HOME} 'it\\' $x && rm 設定.rs", Grammar::Shell);
        let text = "echo ${HOME} 'it\\' $x && rm 設定.rs";
        let words = spans
            .iter()
            .map(|(range, token)| (&text[range.clone()], *token))
            .collect::<Vec<_>>();
        assert_eq!(
            words,
            vec![
                ("echo", Token::Call),
                ("${HOME}", Token::Variable),
                ("'it\\'", Token::String),
                ("$x", Token::Variable),
                ("rm", Token::Call),
            ]
        );
        assert!(scan("\"unterminated \\", Grammar::Shell)[0].0.end <= 15);
        assert_eq!(scan("if true; then", Grammar::Shell).len(), 2);
    }

    #[::core::prelude::v1::test]
    fn diffs_need_a_header_and_a_change() {
        assert!(looks_like_diff("@@ -1 +1 @@\n-a\n+b"));
        assert!(!looks_like_diff("- a list\n- of items"));
        assert!(!looks_like_diff("@@ only a header"));
    }

    #[::core::prelude::v1::test]
    fn fences_outgrow_backtick_runs_in_the_text() {
        assert_eq!(fenced("plain"), "```\nplain\n```");
        assert_eq!(fenced("a ```` b"), "`````\na ```` b\n`````");
    }
}
