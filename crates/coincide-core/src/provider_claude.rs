//! Claude Code's bidirectional stream-json protocol. Permissions are per request.
use super::{transport::*, *};
use std::collections::HashMap;

const NESTED_ENV: &[&str] = &[
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_BRIDGE_SESSION_ID",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_SESSION_ATTENDED",
    "CLAUDE_CODE_EXECPATH",
    "CLAUDE_PID",
    "CLAUDE_EFFORT",
];

fn response(id: &Value, result: Value) -> Value {
    json!({"type":"control_response","response":{"subtype":"success","request_id":id,"response":result}})
}

fn control_error(id: &Value, message: &str) -> Value {
    json!({"type":"control_response","response":{"subtype":"error","request_id":id,"error":message}})
}

/// Claude Code's words before the user's note on a rejected tool call.
const REJECTION_NOTE_PREFIX: &str = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\n";

/// Never forward user-provided protocol objects or persistent permission updates.
fn permission_reply(request: &Value, answer: &Value) -> Result<Value> {
    let decision = answer["decision"].as_str();
    let mut allowed = decision == Some("accept");
    let mut input = request["input"].clone();
    if request["tool_name"] == "AskUserQuestion" {
        allowed = false;
        let mut answers = serde_json::Map::new();
        if let Some(questions) = request["input"]["questions"].as_array() {
            for question in questions {
                if let Some(key) = question["question"].as_str()
                    && let Some(values) = answer["answers"][key]["answers"].as_array()
                {
                    let values = values
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>();
                    if !values.is_empty() {
                        answers.insert(key.into(), json!(values.join(", ")));
                    }
                }
            }
        }
        if !answers.is_empty() {
            allowed = true;
            input["answers"] = Value::Object(answers);
        }
    } else {
        ensure!(
            matches!(decision, Some("accept" | "decline" | "cancel")),
            "Expected accept, decline or cancel"
        );
    }
    // Claude Code's own framing of "No, and tell Claude what to do instead":
    // a bare note as the tool result would read like output the tool produced.
    let note = answer["text"]
        .as_str()
        .map(str::trim)
        .filter(|note| !note.is_empty());
    let message = note.map_or_else(
        || "The user declined this request.".to_owned(),
        |note| format!("{REJECTION_NOTE_PREFIX}{note}"),
    );
    let mut result = if allowed {
        json!({"behavior":"allow","updatedInput":input,"decisionClassification":"user_temporary"})
    } else {
        json!({"behavior":"deny","message":message,"decisionClassification":"user_reject"})
    };
    if decision == Some("cancel") {
        result["interrupt"] = json!(true);
    }
    if let Some(id) = request.get("tool_use_id") {
        result["toolUseID"] = id.clone();
    }
    Ok(result)
}

#[derive(Default)]
struct Mapper {
    message: String,
    blocks: HashMap<u64, (String, bool)>,
    thinking: HashMap<String, String>,
    emitted_reply: bool,
    tools: HashMap<String, Value>,
}

impl Mapper {
    fn map(&mut self, frame: &Value, events: &Sender<Event>) -> Result<()> {
        if frame["parent_tool_use_id"].is_string() {
            return Ok(());
        }
        match frame["type"].as_str() {
            Some("stream_event") => {
                let event = &frame["event"];
                match event["type"].as_str() {
                    Some("message_start") => {
                        self.message = event["message"]["id"]
                            .as_str()
                            .or_else(|| frame["api_message_id"].as_str())
                            .map(str::to_owned)
                            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                        self.blocks.clear();
                    }
                    Some("content_block_start") => {
                        let block = &event["content_block"];
                        if let Some(index) = event["index"].as_u64() {
                            let reasoning = block["type"] == "thinking";
                            if reasoning || block["type"] == "text" {
                                let id = format!("{}:{index}", self.message);
                                let text = block[if reasoning { "thinking" } else { "text" }]
                                    .as_str()
                                    .unwrap_or("");
                                self.text(events, &id, text, reasoning)?;
                                self.blocks.insert(index, (id, reasoning));
                            }
                        }
                    }
                    Some("content_block_delta") => {
                        if let Some((id, reasoning)) = event["index"]
                            .as_u64()
                            .and_then(|i| self.blocks.get(&i))
                            .cloned()
                        {
                            let text = event["delta"][if reasoning { "thinking" } else { "text" }]
                                .as_str()
                                .unwrap_or("");
                            self.text(events, &id, text, reasoning)?;
                        }
                    }
                    Some("content_block_stop") => {
                        if let Some(index) = event["index"].as_u64() {
                            self.blocks.remove(&index);
                        }
                    }
                    _ => {}
                }
            }
            Some("assistant") => {
                if let Some(error) = frame["error"].as_str() {
                    ensure!(
                        error == "max_output_tokens",
                        "Claude assistant error: {error}"
                    );
                }
                let message = &frame["message"];
                let message_id = message["id"]
                    .as_str()
                    .or_else(|| frame["uuid"].as_str())
                    .unwrap_or(&self.message);
                if let Some(content) = message["content"].as_array() {
                    for (index, block) in content.iter().enumerate() {
                        let id = format!("{message_id}:{index}");
                        match block["type"].as_str() {
                            Some("text") => {
                                let text = block["text"].as_str().unwrap_or("");
                                self.emitted_reply |= !text.is_empty();
                                event(
                                    events,
                                    "item/completed",
                                    json!({"item":{"type":"agentMessage","id":id,"text":text},"providerFrame":frame}),
                                )?;
                            }
                            Some("thinking") => {
                                let text = block["thinking"].as_str().unwrap_or("");
                                let previous =
                                    self.thinking.get(&id).map(String::as_str).unwrap_or("");
                                if let Some(suffix) = text.strip_prefix(previous) {
                                    delta(events, &id, suffix, true)?;
                                }
                                self.thinking.insert(id, text.into());
                            }
                            Some("tool_use" | "server_tool_use" | "mcp_tool_use") => {
                                let item = json!({"type":"toolCall","id":block["id"],"name":block["name"],"input":block["input"],"status":"inProgress"});
                                if let Some(id) = block["id"].as_str() {
                                    self.tools.insert(id.into(), item.clone());
                                }
                                event(
                                    events,
                                    "item/started",
                                    json!({"item":item,"providerFrame":frame}),
                                )?;
                            }
                            _ => {}
                        }
                    }
                }
            }
            Some("user") => {
                if let Some(content) = frame["message"]["content"].as_array() {
                    for block in content {
                        if block["type"] == "tool_result" {
                            let mut item = block["tool_use_id"]
                                .as_str()
                                .and_then(|id| self.tools.remove(id))
                                .unwrap_or_else(
                                    || json!({"type":"toolCall","id":block["tool_use_id"]}),
                                );
                            item["output"] = block["content"].clone();
                            item["isError"] = block["is_error"].clone();
                            item["status"] = json!(if block["is_error"] == true {
                                "failed"
                            } else {
                                "completed"
                            });
                            event(
                                events,
                                "item/completed",
                                json!({"item":item,"providerFrame":frame}),
                            )?;
                        }
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn text(
        &mut self,
        events: &Sender<Event>,
        id: &str,
        text: &str,
        reasoning: bool,
    ) -> Result<()> {
        if reasoning {
            self.thinking.entry(id.into()).or_default().push_str(text);
        } else {
            self.emitted_reply |= !text.is_empty();
        }
        delta(events, id, text, reasoning)
    }
}

pub(super) fn run(
    launch: Launch,
    images: Vec<ImageAttachment>,
    instructions: Option<String>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    let mut content = Some(images::claude_content(&launch.prompt, &images));
    let permission_mode = if launch.full_access {
        "bypassPermissions"
    } else {
        "default"
    };
    drop(images);
    let mut arguments = [
        "--output-format",
        "stream-json",
        "--verbose",
        "--input-format",
        "stream-json",
        "--include-partial-messages",
        "--permission-prompt-tool",
        "stdio",
        "--permission-mode",
        permission_mode,
        "--setting-sources=user,project,local",
    ]
    .map(str::to_owned)
    .to_vec();
    if let Some(instructions) = instructions {
        arguments.extend(["--append-system-prompt".into(), instructions]);
    }
    if let Some(model) = &launch.model {
        arguments.extend(["--model".into(), model.clone()]);
    }
    let initial_session = launch
        .session
        .clone()
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    arguments.extend([
        if launch.session.is_some() {
            "--resume"
        } else {
            "--session-id"
        }
        .into(),
        initial_session.clone(),
    ]);
    let mut transport = Transport::spawn(&launch, &arguments, NESTED_ENV)?;
    let initialize_id = "coincide-initialize";
    transport.write(&json!({"type":"control_request","request_id":initialize_id,"request":{"subtype":"initialize"}}))?;
    let mut initialized = false;
    let mut reported_session = None;
    let mut pending = HashMap::<String, Value>::new();
    let mut mapper = Mapper::default();
    let result_item_id = format!("claude-result:{}", uuid::Uuid::new_v4());
    let started = Instant::now();
    let mut stopping: Option<Instant> = None;
    let mut completed = false;
    loop {
        while let Ok(command) = commands.try_recv() {
            match command {
                Control::Stop if stopping.is_none() => {
                    stopping = Some(Instant::now());
                    let _ = transport.write(&json!({"type":"control_request","request_id":"coincide-interrupt","request":{"subtype":"interrupt","cancel_queued":true}}));
                }
                Control::Stop => {}
                Control::Reply { id, result } if stopping.is_none() => {
                    if let Some(request) = pending.get(&id.to_string()) {
                        match permission_reply(request, &result) {
                            Ok(response_body) => {
                                transport.write(&response(&id, response_body))?;
                                pending.remove(&id.to_string());
                            }
                            Err(error) => event(
                                events,
                                "provider/requestRejected",
                                json!({"id":id,"message":error.to_string()}),
                            )?,
                        }
                    } else {
                        event(
                            events,
                            "provider/requestRejected",
                            json!({"id":id,"message":"Request is no longer pending"}),
                        )?;
                    }
                }
                Control::Reply { .. } => {}
                Control::Steer { reply, .. } => {
                    let _ = reply.send(Err(
                        "This provider does not support active-turn steering".into()
                    ));
                }
            }
        }
        if completed {
            if stopping.is_some() || transport.is_flushed()? {
                events.send(Event::Finished)?;
                return Ok(());
            }
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        if stopping.is_some_and(|at| at.elapsed() >= Duration::from_secs(2)) {
            events.send(Event::Finished)?;
            return Ok(());
        }
        ensure!(
            initialized || started.elapsed() < Duration::from_secs(120),
            "Claude startup timed out"
        );
        let frame = match transport.next() {
            Ok(Some(frame)) => frame,
            Ok(None) => continue,
            Err(_) if stopping.is_some() => {
                events.send(Event::Finished)?;
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        raw(events, "claude", &frame)?;
        if let Some(id) = frame["session_id"].as_str() {
            ensure!(
                id == initial_session,
                "Claude returned a different session than requested"
            );
            if reported_session.as_deref() != Some(id) {
                events.send(Event::Session(id.into()))?;
                reported_session = Some(id.to_owned());
            }
        }
        match frame["type"].as_str() {
            Some("control_response") if frame["response"]["request_id"] == initialize_id => {
                ensure!(
                    !initialized,
                    "Claude sent duplicate initialization response"
                );
                ensure!(
                    frame["response"]["subtype"] == "success",
                    "Claude initialization failed: {}",
                    frame["response"]["error"]
                );
                initialized = true;
                if stopping.is_none() {
                    let content = content.take().context("Claude prompt was already sent")?;
                    transport.write(&json!({"type":"user","message":{"role":"user","content":content},"parent_tool_use_id":null,"uuid":uuid::Uuid::new_v4().to_string(),"origin":{"kind":"human"}}))?;
                }
            }
            Some("control_request") => {
                let id = &frame["request_id"];
                ensure!(id.is_string(), "Claude callback has no request ID");
                if stopping.is_some() {
                    transport.write(&control_error(id, "Session is stopping"))?;
                    continue;
                }
                let request = &frame["request"];
                if request["subtype"] == "can_use_tool" {
                    let questions = request["tool_name"] == "AskUserQuestion";
                    let method = if questions {
                        "item/tool/requestUserInput"
                    } else {
                        "item/commandExecution/requestApproval"
                    };
                    let mut params = json!({"toolName":request["tool_name"],"input":request["input"],"toolCallId":request["tool_use_id"],"availableDecisions":["accept","decline","cancel"],"providerFrame":frame});
                    if questions {
                        let values = request["input"]["questions"]
                            .as_array()
                            .map(|questions| {
                                questions
                                    .iter()
                                    .filter_map(|q| {
                                        q.as_object()?;
                                        let mut q = q.clone();
                                        q["id"] = q["question"].clone();
                                        Some(q)
                                    })
                                    .collect::<Vec<_>>()
                            })
                            .unwrap_or_default();
                        if values.is_empty()
                            || values
                                .iter()
                                .any(|q| q["id"].as_str().is_none_or(|id| id.trim().is_empty()))
                        {
                            transport.write(&response(
                                id,
                                json!({"behavior":"deny","message":"No valid questions were supplied.","decisionClassification":"user_reject"}),
                            ))?;
                            continue;
                        }
                        params["questions"] = json!(values);
                        params.as_object_mut().unwrap().remove("availableDecisions");
                    }
                    ensure!(
                        !pending.contains_key(&id.to_string()),
                        "Claude reused a pending request ID"
                    );
                    pending.insert(id.to_string(), request.clone());
                    events.send(Event::Frame(
                        json!({"id":id,"method":method,"params":params}),
                    ))?;
                } else if request["subtype"] == "elicitation" {
                    // Unsupported MCP forms must settle explicitly instead of inventing consent.
                    transport.write(&response(id, json!({"action":"decline"})))?;
                } else {
                    transport.write(&control_error(id, "Unsupported Coincide control request"))?;
                }
            }
            Some("control_cancel_request") => {
                pending.remove(&frame["request_id"].to_string());
                event(
                    events,
                    "provider/requestCancelled",
                    json!({"id":frame["request_id"]}),
                )?;
            }
            Some("result") => {
                ensure!(
                    initialized,
                    "Claude returned a result before initialization"
                );
                if stopping.is_none() {
                    ensure!(
                        frame["is_error"] != true && frame["subtype"] == "success",
                        "Claude turn failed: {}",
                        frame["errors"]
                    );
                    ensure!(
                        frame["terminal_reason"].is_null()
                            || frame["terminal_reason"] == "completed",
                        "Claude turn ended: {}",
                        frame["terminal_reason"]
                    );
                    if !mapper.emitted_reply
                        && let Some(text) = frame["result"].as_str()
                    {
                        delta(events, &result_item_id, text, false)?;
                    }
                }
                completed = true;
            }
            _ => mapper.map(&frame, events)?,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn approval_preserves_tool_input_but_never_accepts_permission_updates() {
        let original = json!({"tool_name":"Write","tool_use_id":"tool-1","input":{"file_path":"a","content":"b","future":42}});
        let result = permission_reply(
            &original,
            &json!({"decision":"accept","updatedPermissions":["everything"]}),
        )
        .unwrap();
        assert_eq!(result["updatedInput"], original["input"]);
        assert_eq!(result["toolUseID"], "tool-1");
        assert_eq!(result["decisionClassification"], "user_temporary");
        assert!(result.get("updatedPermissions").is_none());
        assert!(permission_reply(&original, &json!({"decision":"acceptForSession"})).is_err());
    }
    #[test]
    fn denial_notes_use_claude_framing_and_never_reach_allowed_calls() {
        let request =
            json!({"tool_name":"Bash","tool_use_id":"tool-2","input":{"command":"rm -rf x"}});
        let denied = permission_reply(
            &request,
            &json!({"decision":"decline","text":"  use trash instead \n"}),
        )
        .unwrap();
        assert_eq!(denied["behavior"], "deny");
        assert_eq!(
            denied["message"],
            format!("{REJECTION_NOTE_PREFIX}use trash instead")
        );
        assert!(denied.get("interrupt").is_none());
        let stopped =
            permission_reply(&request, &json!({"decision":"cancel","text":"stop"})).unwrap();
        assert_eq!(stopped["message"], format!("{REJECTION_NOTE_PREFIX}stop"));
        assert_eq!(stopped["interrupt"], true);
        let blank = permission_reply(&request, &json!({"decision":"decline","text":" "})).unwrap();
        assert_eq!(blank["message"], "The user declined this request.");
        let allowed =
            permission_reply(&request, &json!({"decision":"accept","text":"ignored"})).unwrap();
        assert_eq!(allowed["behavior"], "allow");
        assert!(allowed.get("message").is_none());
    }
    #[test]
    fn questions_require_actual_answers_not_generic_approval() {
        let request = json!({"tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which?"}],"future":42}});
        assert_eq!(
            permission_reply(&request, &json!({"decision":"accept"})).unwrap()["behavior"],
            "deny"
        );
        let reply = permission_reply(
            &request,
            &json!({"answers":{"Which?":{"answers":[" A ","B"]},"invented":{"answers":["no"]}}}),
        )
        .unwrap();
        assert_eq!(reply["updatedInput"]["answers"], json!({"Which?":"A, B"}));
        assert_eq!(reply["updatedInput"]["future"], 42);
    }
}
