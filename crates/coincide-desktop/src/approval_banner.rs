//! Swift's ComposerApprovalBanner content for a pending provider request: a
//! heading per category, the agent, a title with code spans and its detail,
//! and the choices with each provider's own wording. Denials come first and
//! the plain "allow" last, where the primary button sits. The Rust engine
//! answers only accept, decline and cancel; persistent or session-wide grants
//! ("Allow Always") are deliberately never offered (coincide-core refuses
//! them), so those provider options are not shown.
use super::*;
use gpui_kit::assets::IconName;
use serde_json::Value;
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Kind {
    Cancel,
    Deny,
    AllowOnce,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Choice {
    pub decision: &'static str,
    pub label: String,
    pub kind: Kind,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Approval {
    pub heading: &'static str,
    pub title: String,
    pub detail: String,
    pub choices: Vec<Choice>,
    /// The reply field's placeholder, for agents that read a note with the choice.
    pub reply: Option<&'static str>,
}

/// The heading Swift shows for a category.
pub(super) fn heading(category: &str) -> &'static str {
    match category {
        "command" => "Command approval",
        "fileChange" => "File change approval",
        "read" | "search" => "File read approval",
        "web" => "Web access approval",
        "mcp" => "Tool approval",
        _ => "Approval needed",
    }
}

fn string(value: &Value) -> Option<&str> {
    value
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

/// Swift's summary of a command for a title: its first line, cut at 80 characters.
pub(super) fn summary(command: &str) -> String {
    let mut lines = command.trim().lines();
    let first = lines.next().unwrap_or_default().trim();
    let mut cut = lines.next().is_some();
    let mut line = first.to_owned();
    if first.chars().count() > 80 {
        line = first.chars().take(79).collect();
        cut = true;
    }
    if cut { format!("{line}…") } else { line }
}

fn pretty(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        Value::Object(object) if object.is_empty() => None,
        _ => serde_json::to_string_pretty(value).ok(),
    }
}

/// Claude Code's tool category, as ClaudeTools.category(for:).
fn claude_category(name: &str) -> &'static str {
    if name.starts_with("mcp__") {
        return "mcp";
    }
    let name = name.to_lowercase().replace(['_', '-', ' '], "");
    match name.as_str() {
        "bash" | "powershell" | "bashoutput" | "monitor" | "taskstop" | "killshell"
        | "killbash" => "command",
        "edit" | "multiedit" | "write" | "notebookedit" => "fileChange",
        "read" | "notebookread" | "ls" => "read",
        "grep" | "glob" | "lsp" => "search",
        "webfetch" | "websearch" => "web",
        "task" | "agent" | "sendmessage" => "task",
        "todowrite" | "taskcreate" | "taskupdate" | "tasklist" | "taskget" => "todo",
        _ => "other",
    }
}

/// The title and detail ClaudeTools.info gives the tool calls Claude asks about.
fn claude_info(name: &str, input: &Value, display: Option<&str>) -> (String, Option<String>) {
    let path = string(&input["file_path"])
        .or_else(|| string(&input["notebook_path"]))
        .or_else(|| string(&input["path"]));
    let text = |key: &str| string(&input[key]).map(str::to_owned);
    let normalized = name.to_lowercase().replace(['_', '-', ' '], "");
    match normalized.as_str() {
        "bash" | "powershell" => match text("command") {
            None => ("Run command".into(), None),
            Some(command) if input["run_in_background"] == true => (
                format!("Run `{}` in the background", summary(&command)),
                Some(command),
            ),
            Some(command) => (format!("Run `{}`", summary(&command)), Some(command)),
        },
        "edit" | "multiedit" => {
            let title = path.map_or("Edit file".into(), |path| format!("Edit {path}"));
            let edits = if normalized == "edit" {
                vec![input.clone()]
            } else {
                input["edits"].as_array().cloned().unwrap_or_default()
            };
            let hunks = edits
                .iter()
                .filter_map(|edit| {
                    Some((edit["old_string"].as_str()?, edit["new_string"].as_str()?))
                })
                .map(|(old, new)| {
                    old.lines()
                        .map(|line| format!("-{line}"))
                        .chain(new.lines().map(|line| format!("+{line}")))
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .collect::<Vec<_>>();
            let detail = (!hunks.is_empty()).then(|| {
                let path = path.unwrap_or("file");
                format!("--- a/{path}\n+++ b/{path}\n{}", hunks.join("\n"))
            });
            (title, detail)
        }
        "write" => (
            path.map_or("Write file".into(), |path| format!("Write {path}")),
            input["content"].as_str().map(|content| {
                let path = path.unwrap_or("file");
                let added = content
                    .lines()
                    .map(|line| format!("+{line}"))
                    .collect::<Vec<_>>()
                    .join("\n");
                format!("--- /dev/null\n+++ b/{path}\n{added}")
            }),
        ),
        "notebookedit" => (
            path.map_or("Edit notebook".into(), |path| {
                format!("Edit notebook {path}")
            }),
            text("new_source"),
        ),
        "read" | "notebookread" => (
            path.map_or("Read file".into(), |path| format!("Read {path}")),
            None,
        ),
        "ls" => (
            path.map_or("List files".into(), |path| format!("List {path}")),
            None,
        ),
        "grep" => {
            let pattern = text("pattern").unwrap_or_default();
            (
                path.map_or(format!("Search for `{pattern}`"), |path| {
                    format!("Search for `{pattern}` in {path}")
                }),
                pretty(input),
            )
        }
        "glob" => {
            let pattern = text("pattern").unwrap_or_default();
            (
                path.map_or(format!("Find files matching `{pattern}`"), |path| {
                    format!("Find files matching `{pattern}` in {path}")
                }),
                None,
            )
        }
        "webfetch" => (
            text("url").map_or("Fetch a web page".into(), |url| format!("Fetch {url}")),
            text("prompt"),
        ),
        "websearch" => (
            text("query").map_or("Search the web".into(), |query| {
                format!("Search the web for “{query}”")
            }),
            None,
        ),
        "task" | "agent" => {
            let kind = text("subagent_type").filter(|kind| kind != "general-purpose");
            let label = kind.unwrap_or_else(|| "Agent".into());
            (
                text("description").map_or(label.clone(), |description| {
                    format!("{label}: {description}")
                }),
                text("prompt"),
            )
        }
        _ => {
            let title = if let Some(rest) = name.strip_prefix("mcp__") {
                let (server, tool) = rest.split_once("__").unwrap_or((rest, rest));
                let server = server.strip_prefix("claude_ai_").unwrap_or(server);
                format!("{server}: {}", display.unwrap_or(tool))
            } else {
                display.unwrap_or(name).to_owned()
            };
            (title, pretty(input))
        }
    }
}

/// ACP's tool kinds and common tool names, as ACPToolCallState's category.
fn acp_category(tool: &Value) -> &'static str {
    match tool["kind"].as_str().unwrap_or_default() {
        "execute" => return "command",
        "edit" | "delete" | "move" => return "fileChange",
        "read" => return "read",
        "search" => return "search",
        "fetch" => return "web",
        _ => {}
    }
    let name = tool["toolName"]
        .as_str()
        .or_else(|| tool["permission"].as_str())
        .unwrap_or_default()
        .to_lowercase()
        .replace('-', "_");
    match name.as_str() {
        "bash"
        | "shell"
        | "terminal"
        | "run_terminal_cmd"
        | "run_terminal_command"
        | "exec"
        | "run_command" => "command",
        "edit" | "write" | "write_file" | "search_replace" | "str_replace" | "multi_edit"
        | "apply_patch" | "delete_file" => "fileChange",
        "read" | "read_file" | "view" | "list_dir" | "ls" => "read",
        "grep" | "glob" | "find" | "rg" | "search" | "codebase_search" | "file_search" => "search",
        "web_search" | "web_fetch" | "fetch" | "x_search" | "webfetch" => "web",
        _ => "other",
    }
}

/// What each provider calls the three choices the engine can send. ACP agents
/// name their own options; Swift's Grok and Antigravity flavors relabel them.
fn label(provider: &str, decision: &str, params: &Value) -> String {
    let acp_name = |kind: &str| {
        params["providerFrame"]["params"]["options"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|option| option["kind"] == kind)
            .and_then(|option| string(&option["name"]))
            .map(str::to_owned)
    };
    let fixed = match (provider, decision) {
        ("grok", "accept") => "Approve",
        ("grok", "decline") => "Decline",
        ("antigravity", "accept") => "Allow once",
        ("antigravity" | "claude" | "codex" | "opencode", "decline") => "Deny",
        ("grok" | "antigravity" | "cursor", "cancel") => "Cancel",
        ("claude" | "codex" | "opencode", "accept") => "Allow",
        (_, "cancel") => "Deny and stop",
        ("cursor", "accept") => return acp_name("allow_once").unwrap_or_else(|| "Allow".into()),
        ("cursor", _) => return acp_name("reject_once").unwrap_or_else(|| "Deny".into()),
        (_, "accept") => "Allow",
        _ => "Deny",
    };
    fixed.into()
}

pub(super) fn approval(provider: &str, method: &str, params: &Value) -> Approval {
    let tool = &params["toolCall"];
    let (category, title, detail) = if provider == "claude" || params.get("toolName").is_some() {
        let name = params["toolName"].as_str().unwrap_or_default();
        let request = &params["providerFrame"]["request"];
        let (title, info) = claude_info(name, &params["input"], string(&request["display_name"]));
        let reason = string(&request["decision_reason"]).filter(|reason| *reason != title);
        let blocked =
            string(&request["blocked_path"]).map(|path| format!("Needs access to {path}"));
        let detail = [reason.map(str::to_owned), blocked, info]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join("\n\n");
        (claude_category(name), title, detail)
    } else if tool.is_object() {
        let category = acp_category(tool);
        let raw = &tool["rawInput"];
        let command = string(&raw["command"]).map(str::to_owned).or_else(|| {
            raw["command"].as_array().map(|parts| {
                parts
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(" ")
            })
        });
        let title = string(&tool["title"])
            .map(str::to_owned)
            .or_else(|| {
                command
                    .as_ref()
                    .map(|command| format!("Run `{}`", summary(command)))
            })
            .or_else(|| {
                let action = string(&tool["permission"])?;
                let patterns = tool["patterns"]
                    .as_array()
                    .map(|patterns| {
                        patterns
                            .iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                    .unwrap_or_default();
                Some(format!("{action} {patterns}").trim().to_owned())
            })
            .unwrap_or_else(|| heading(category).into());
        let detail = command
            .or_else(|| pretty(raw))
            .or_else(|| pretty(&tool["metadata"]))
            .filter(|detail| *detail != title)
            .unwrap_or_default();
        (category, title, detail)
    } else if method == "item/fileChange/requestApproval" {
        let title = string(&params["grantRoot"]).map_or("Edit files".into(), |root| {
            format!("Allow writing to {root}")
        });
        let detail = string(&params["reason"]).unwrap_or_default().to_owned();
        ("fileChange", title, detail)
    } else {
        let command = params["command"].as_str().map(str::to_owned).or_else(|| {
            params["command"].as_array().map(|parts| {
                parts
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(" ")
            })
        });
        let command = command.unwrap_or_default();
        let title = if let Some(host) = string(&params["networkApprovalContext"]["host"]) {
            format!("Allow network access to {host}")
        } else if params["kind"] == "writeStdin" {
            format!("Send input to `{}`", summary(&command))
        } else if command.trim().is_empty() {
            "Run command".into()
        } else {
            format!("Run `{}`", summary(&command))
        };
        let detail = [Some(command.trim()), string(&params["reason"])]
            .into_iter()
            .flatten()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        ("command", title, detail)
    };

    let offered = params["availableDecisions"].as_array();
    let mut choices = [
        ("accept", Kind::AllowOnce),
        ("decline", Kind::Deny),
        ("cancel", Kind::Cancel),
    ]
    .into_iter()
    .filter(|(decision, _)| {
        offered.is_none_or(|offered| offered.iter().any(|value| value == decision))
    })
    .map(|(decision, kind)| Choice {
        decision,
        label: label(provider, decision, params),
        kind,
    })
    .collect::<Vec<_>>();
    choices.sort_by_key(|choice| choice.kind);
    Approval {
        heading: heading(category),
        title,
        detail,
        choices,
        reply: (provider == "claude").then_some("Tell Claude what to do instead (optional)"),
    }
}

/// The reply field of each live approval that takes one, keyed by thread and
/// request. Return in it picks the primary choice, as in Swift.
#[derive(Default)]
pub(super) struct Replies {
    inputs: HashMap<(String, String), (Entity<InputState>, Subscription)>,
}

impl super::Coincide {
    /// The approvals the agent waits on, oldest first by the transcript item
    /// each request created (the engine keeps requests unordered).
    fn pending_approvals(&self) -> Vec<&Value> {
        let items = self
            .selected
            .as_ref()
            .and_then(|thread| thread["items"].as_array());
        let position = |request: &Value| {
            items.and_then(|items| {
                items
                    .iter()
                    .rposition(|item| item["externalID"] == request["requestId"])
            })
        };
        let mut approvals = self
            .pending_requests
            .iter()
            .filter(|request| request["method"] != "item/tool/requestUserInput")
            .collect::<Vec<_>>();
        approvals.sort_by_key(|request| (position(request), text(request, "requestId")));
        approvals
    }

    fn approval_provider(&self, request: &Value) -> String {
        request["provider"]
            .as_str()
            .or_else(|| {
                self.selected
                    .as_ref()
                    .and_then(|thread| thread["selection"]["provider"].as_str())
            })
            .unwrap_or_default()
            .to_owned()
    }

    /// Keeps one reply field per live approval that reads a note.
    pub(super) fn sync_approval_replies(
        &mut self,
        thread: &str,
        requests: &[Value],
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let live = requests
            .iter()
            .map(|request| text(request, "requestId"))
            .collect::<std::collections::HashSet<_>>();
        self.approval_replies
            .inputs
            .retain(|(owner, id), _| owner != thread || live.contains(id));
        for request in requests {
            if request["method"] == "item/tool/requestUserInput" {
                continue;
            }
            let provider = self.approval_provider(request);
            let approval = approval(
                &provider,
                request["method"].as_str().unwrap_or_default(),
                &request["params"],
            );
            let Some(placeholder) = approval.reply else {
                continue;
            };
            let request_id = text(request, "requestId");
            let key = (thread.to_owned(), request_id.clone());
            if self.approval_replies.inputs.contains_key(&key) {
                continue;
            }
            let primary = approval
                .choices
                .iter()
                .rfind(|choice| choice.kind == Kind::AllowOnce)
                .or(approval.choices.last())
                .map(|choice| choice.decision);
            let input = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
            let subscription = cx.subscribe_in(&input, window, move |this, _, event, _, cx| {
                if let InputEvent::PressEnter {
                    secondary: false,
                    shift: false,
                } = event
                    && let Some(decision) = primary
                {
                    this.respond_approval(&request_id, decision, cx);
                }
            });
            self.approval_replies
                .inputs
                .insert(key, (input, subscription));
        }
    }

    /// Answers an approval with the choice and, when it reads one, the note.
    pub(super) fn respond_approval(
        &mut self,
        request_id: &str,
        decision: &str,
        cx: &mut Context<Self>,
    ) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let mut params = json!({"threadId":thread,"requestId":request_id,"decision":decision});
        if let Some((input, _)) = self
            .approval_replies
            .inputs
            .get(&(thread.clone(), request_id.to_owned()))
        {
            let note = input.read(cx).value().to_string();
            if !note.trim().is_empty() {
                params["text"] = json!(note);
            }
        }
        self.finish_pending(&thread, request_id, "agent.respond", params, cx);
        self.approval_replies
            .inputs
            .retain(|(owner, id), _| owner != &thread || id != request_id);
    }

    /// ComposerApprovalBanner: the latest approval, how many more wait, and
    /// the provider's choices with the primary one at the trailing edge.
    pub(super) fn approval_banner(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let thread = self.selected.as_ref().map(|v| text(v, "id"))?;
        let approvals = self.pending_approvals();
        let request = *approvals.last()?;
        let others = approvals.len() - 1;
        let request_id = text(request, "requestId");
        let provider = self.approval_provider(request);
        let approval = approval(
            &provider,
            request["method"].as_str().unwrap_or_default(),
            &request["params"],
        );
        let dark = self.appearance_dark;
        let orange = rgb(if dark { 0xFF9F0A } else { 0xFF9500 });
        let secondary = self.color(0xe4e9f2).opacity(0.6);
        let agent = super::presentation::provider_name(&provider).to_owned();
        let (title, code) = super::tool_detail::inline_code(&approval.title);
        let summary = super::tool_detail::code_span_text(
            &title,
            &code,
            self.color(0xe4e9f2).into(),
            self.color(0xe4e9f2).opacity(0.08).into(),
            window,
            cx,
        );
        let detail = approval.detail.trim();
        let show_detail = !detail.is_empty() && detail != approval.title;
        let reply = self
            .approval_replies
            .inputs
            .get(&(thread.clone(), request_id.clone()))
            .map(|(input, _)| input.clone());
        let buttons = approval.choices.iter().map(|choice| {
            let (id, decision) = (request_id.clone(), choice.decision);
            Button::new(SharedString::from(format!(
                "decision-{request_id}-{}",
                choice.decision
            )))
            .label(choice.label.clone())
            .small()
            .when(choice.kind == Kind::AllowOnce, |button| button.primary())
            .on_click(cx.listener(move |this, _, _, cx| this.respond_approval(&id, decision, cx)))
        });
        Some(
            div()
                .id("approval-banner")
                .w_full()
                .flex()
                .justify_center()
                .px(px(super::presentation::CONTENT_GUTTER))
                .pt_2()
                .child(
                    div()
                        .id("approval-banner-card")
                        .w_full()
                        .max_w(px(super::presentation::CONTENT_WIDTH))
                        .flex()
                        .items_start()
                        .gap_2()
                        .pl(px(12.))
                        .pr(px(10.))
                        .py(px(8.))
                        .rounded(px(14.))
                        .bg(Hsla::from(orange).opacity(0.1))
                        .border_1()
                        .border_color(Hsla::from(orange).opacity(0.3))
                        .aria_label(SharedString::from(format!(
                            "{}, {agent}, {title}",
                            approval.heading
                        )))
                        .child(
                            div()
                                .pt(px(1.))
                                .text_color(orange)
                                .child(Icon::new(IconName::ShieldAlert).small()),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .flex_1()
                                .min_w_0()
                                .gap_1()
                                .child(
                                    div()
                                        .flex()
                                        .items_center()
                                        .gap(px(6.))
                                        .text_xs()
                                        .child(
                                            div()
                                                .font_semibold()
                                                .text_color(orange)
                                                .child(approval.heading),
                                        )
                                        .child(div().text_color(secondary).child(agent.clone()))
                                        .child(div().flex_1())
                                        .when(others > 0, |row| {
                                            row.child(
                                                div()
                                                    .text_color(secondary)
                                                    .child(format!("{others} more waiting")),
                                            )
                                        }),
                                )
                                .child(
                                    div()
                                        .text_sm()
                                        .font_medium()
                                        .min_w_0()
                                        .line_clamp(2)
                                        .child(summary),
                                )
                                .when(show_detail, |column| {
                                    column.child(
                                        div()
                                            .id(SharedString::from(format!(
                                                "approval-detail-{request_id}"
                                            )))
                                            .text_xs()
                                            .font_family(cx.theme().mono_font_family.clone())
                                            .text_color(secondary)
                                            .min_w_0()
                                            .line_clamp(6)
                                            .child(detail.to_owned()),
                                    )
                                })
                                .when_some(reply, |column, input| {
                                    column.child(div().mt_1().child(Input::new(&input).small()))
                                })
                                .child(
                                    div()
                                        .mt_1()
                                        .flex()
                                        .flex_wrap()
                                        .justify_end()
                                        .gap(px(6.))
                                        .children(buttons),
                                ),
                        ),
                )
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn labels(approval: &Approval) -> Vec<(&str, &str)> {
        approval
            .choices
            .iter()
            .map(|choice| (choice.decision, choice.label.as_str()))
            .collect()
    }

    #[::core::prelude::v1::test]
    fn claude_command_reads_like_swift_with_denials_first_and_a_reply_field() {
        let params = json!({"toolName":"Bash","input":{"command":"cargo test\n--all"},
            "availableDecisions":["accept","decline","cancel"],
            "providerFrame":{"request":{"decision_reason":"Runs tests","blocked_path":"/tmp/x"}}});
        let approval = approval("claude", "item/commandExecution/requestApproval", &params);
        assert_eq!(approval.heading, "Command approval");
        assert_eq!(approval.title, "Run `cargo test…`");
        assert_eq!(
            approval.detail,
            "Runs tests\n\nNeeds access to /tmp/x\n\ncargo test\n--all"
        );
        assert_eq!(
            labels(&approval),
            [
                ("cancel", "Deny and stop"),
                ("decline", "Deny"),
                ("accept", "Allow")
            ]
        );
        assert_eq!(
            approval.reply,
            Some("Tell Claude what to do instead (optional)")
        );
    }

    #[::core::prelude::v1::test]
    fn claude_file_tools_and_mcp_get_their_categories_and_titles() {
        let edit = json!({"toolName":"Edit","input":{"file_path":"src/a.rs","old_string":"a","new_string":"b"}});
        let approval = approval("claude", "", &edit);
        assert_eq!(approval.heading, "File change approval");
        assert_eq!(approval.title, "Edit src/a.rs");
        assert_eq!(approval.detail, "--- a/src/a.rs\n+++ b/src/a.rs\n-a\n+b");
        let mcp = json!({"toolName":"mcp__claude_ai_Docs__search","input":{"q":1}});
        let approval = super::approval("claude", "", &mcp);
        assert_eq!(approval.heading, "Tool approval");
        assert_eq!(approval.title, "Docs: search");
        assert_eq!(approval.detail, "{\n  \"q\": 1\n}");
        let web = json!({"toolName":"WebFetch","input":{"url":"https://example.com"}});
        assert_eq!(
            super::approval("claude", "", &web).heading,
            "Web access approval"
        );
        let read = json!({"toolName":"Grep","input":{"pattern":"x"}});
        assert_eq!(
            super::approval("claude", "", &read).heading,
            "File read approval"
        );
    }

    #[::core::prelude::v1::test]
    fn codex_command_and_file_change_requests() {
        let params = json!({"command":"git push","reason":"Needs network","availableDecisions":["accept","acceptForSession","decline"]});
        let approval = approval("codex", "item/commandExecution/requestApproval", &params);
        assert_eq!(approval.title, "Run `git push`");
        assert_eq!(approval.detail, "git push\nNeeds network");
        assert_eq!(
            labels(&approval),
            [("decline", "Deny"), ("accept", "Allow")]
        );
        assert_eq!(approval.reply, None);
        let network = json!({"command":"curl x","networkApprovalContext":{"host":"example.com"}});
        assert_eq!(
            super::approval("codex", "item/commandExecution/requestApproval", &network).title,
            "Allow network access to example.com"
        );
        let files = json!({"grantRoot":"/repo","reason":"Write output"});
        let approval = super::approval("codex", "item/fileChange/requestApproval", &files);
        assert_eq!(approval.heading, "File change approval");
        assert_eq!(approval.title, "Allow writing to /repo");
        assert_eq!(approval.detail, "Write output");
        assert_eq!(
            approval.choices.len(),
            3,
            "no list means all three are offered"
        );
    }

    #[::core::prelude::v1::test]
    fn acp_agents_keep_their_option_names_and_flavor_labels() {
        let params = json!({"toolCall":{"kind":"execute","title":"Run `ls`","rawInput":{"command":"ls -la"}},
            "availableDecisions":["accept","decline","cancel"],
            "providerFrame":{"params":{"options":[
                {"optionId":"a","kind":"allow_once","name":"Run it"},
                {"optionId":"b","kind":"allow_always","name":"Always"},
                {"optionId":"c","kind":"reject_once","name":"Skip"}]}}});
        let cursor = approval("cursor", "", &params);
        assert_eq!(cursor.heading, "Command approval");
        assert_eq!(cursor.title, "Run `ls`");
        assert_eq!(cursor.detail, "ls -la");
        assert_eq!(
            labels(&cursor),
            [
                ("cancel", "Cancel"),
                ("decline", "Skip"),
                ("accept", "Run it")
            ]
        );
        assert_eq!(
            labels(&approval("grok", "", &params)),
            [
                ("cancel", "Cancel"),
                ("decline", "Decline"),
                ("accept", "Approve")
            ]
        );
        assert_eq!(
            labels(&approval("antigravity", "", &params)),
            [
                ("cancel", "Cancel"),
                ("decline", "Deny"),
                ("accept", "Allow once")
            ]
        );
        let without = json!({"toolCall":{"kind":"edit"},"availableDecisions":["decline","cancel"]});
        let approval = approval("cursor", "", &without);
        assert_eq!(approval.title, "File change approval");
        assert_eq!(
            labels(&approval),
            [("cancel", "Cancel"), ("decline", "Deny")]
        );
    }

    #[::core::prelude::v1::test]
    fn opencode_permission_names_its_action() {
        let params = json!({"toolCall":{"permission":"bash","patterns":["git status","ls"]},
            "availableDecisions":["accept","decline","cancel"]});
        let approval = approval("opencode", "", &params);
        assert_eq!(approval.heading, "Command approval");
        assert_eq!(approval.title, "bash git status, ls");
        assert_eq!(
            labels(&approval),
            [
                ("cancel", "Deny and stop"),
                ("decline", "Deny"),
                ("accept", "Allow")
            ]
        );
    }

    #[::core::prelude::v1::test]
    fn command_summaries_cut_long_and_multiline_commands() {
        assert_eq!(summary("  ls  "), "ls");
        assert_eq!(summary("a\nb"), "a…");
        assert_eq!(summary(&"界".repeat(90)), format!("{}…", "界".repeat(79)));
    }
}
