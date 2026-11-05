//! ACP v1 core transport. No filesystem or terminal capabilities are advertised.
//! Provider-specific login, discovery and extensions remain separate integrations.
use super::{transport::*, *};
use std::collections::HashMap;

fn rpc(id: u64, method: &str, params: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})
}

fn selected_option<'a>(options: &'a [Value], kind: &str) -> Option<&'a Value> {
    options
        .iter()
        .find(|option| option["kind"] == kind && option["optionId"].is_string())
}

fn permission_reply(params: &Value, answer: &Value) -> Result<Value> {
    let options = params["options"]
        .as_array()
        .context("ACP permission options missing")?;
    let decision = answer["decision"]
        .as_str()
        .context("ACP permission decision missing")?;
    let option = match decision {
        "accept" => Some(
            selected_option(options, "allow_once")
                .context("ACP did not offer permission for one use")?,
        ),
        "decline" => selected_option(options, "reject_once"),
        "cancel" => None,
        _ => bail!("Expected accept, decline or cancel"),
    };
    Ok(if let Some(option) = option {
        json!({"outcome":{"outcome":"selected","optionId":option["optionId"]}})
    } else {
        json!({"outcome":{"outcome":"cancelled"}})
    })
}

struct Mapper {
    run_id: String,
    message_number: u64,
    tools: HashMap<String, Value>,
}
impl Default for Mapper {
    fn default() -> Self {
        Self {
            run_id: uuid::Uuid::new_v4().to_string(),
            message_number: 0,
            tools: HashMap::new(),
        }
    }
}
impl Mapper {
    fn update(&mut self, update: &Value, frame: &Value, events: &Sender<Event>) -> Result<()> {
        let text = update["content"]["text"].as_str().unwrap_or("");
        let id = update["messageId"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| format!("acp-message-{}-{}", self.run_id, self.message_number));
        match update["sessionUpdate"].as_str() {
            Some("agent_message_chunk") => delta(events, &id, text, false)?,
            Some("agent_message") => event(
                events,
                "item/completed",
                json!({"item":{"type":"agentMessage","id":id,"text":text},"providerFrame":frame}),
            )?,
            Some("agent_thought_chunk" | "agent_thought") => {
                delta(events, &format!("{id}-thought"), text, true)?
            }
            Some("tool_call" | "tool_call_update") => {
                if let Some(id) = update["toolCallId"].as_str() {
                    if !self.tools.contains_key(id) {
                        self.message_number += 1;
                    }
                    let tool = self
                        .tools
                        .entry(id.into())
                        .or_insert_with(|| json!({"type":"toolCall","id":id}));
                    // Updates are partial; retain title, input, locations and future fields.
                    if let Some(fields) = update.as_object() {
                        for (key, value) in fields {
                            tool[key] = value.clone();
                        }
                    }
                    let completed = matches!(tool["status"].as_str(), Some("completed" | "failed"));
                    event(
                        events,
                        if completed {
                            "item/completed"
                        } else {
                            "item/started"
                        },
                        json!({"item":tool,"providerFrame":frame}),
                    )?;
                }
            }
            _ => {}
        }
        Ok(())
    }
}

pub(super) fn run(
    launch: Launch,
    arguments: Vec<String>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    let mut transport = Transport::spawn(&launch, &arguments, &[])?;
    transport.write(&rpc(
        1,
        "initialize",
        json!({"protocolVersion":1,
        "clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},
        "clientInfo":{"name":"Coincide","version":env!("CARGO_PKG_VERSION")}}),
    ))?;
    let mut stage = 1;
    let mut session_id: Option<String> = None;
    let mut pending = HashMap::<String, Value>::new();
    let mut mapper = Mapper::default();
    let started = Instant::now();
    let mut stopping: Option<Instant> = None;
    let mut completed = false;
    loop {
        while let Ok(command) = commands.try_recv() {
            match command {
                Control::Stop if stopping.is_none() => {
                    if let Some(id) = &session_id {
                        let _ = transport.write(&json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":id}}));
                    }
                    stopping = Some(Instant::now());
                }
                Control::Stop => {}
                Control::Reply { id, result } if stopping.is_none() => {
                    if let Some(params) = pending.get(&id.to_string()) {
                        match permission_reply(params, &result) {
                            Ok(result) => {
                                transport
                                    .write(&json!({"jsonrpc":"2.0","id":id,"result":result}))?;
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
            stage >= 4 || started.elapsed() < Duration::from_secs(120),
            "ACP startup timed out"
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
        raw(events, "acp", &frame)?;
        if frame.get("method").is_some() && frame.get("id").is_some() {
            let id = &frame["id"];
            if frame["method"] == "session/request_permission" && stopping.is_none() {
                let params = &frame["params"];
                ensure!(
                    session_id.as_deref() == params["sessionId"].as_str(),
                    "ACP permission request for an unexpected session"
                );
                let options = params["options"]
                    .as_array()
                    .context("ACP permission options missing")?;
                let mut decisions = vec!["decline", "cancel"];
                if selected_option(options, "allow_once").is_some() {
                    decisions.insert(0, "accept");
                }
                ensure!(
                    !pending.contains_key(&id.to_string()),
                    "ACP reused a pending request ID"
                );
                pending.insert(id.to_string(), params.clone());
                events.send(Event::Frame(json!({"id":id,"method":"item/commandExecution/requestApproval","params":{
                    "toolCall":params["toolCall"],"availableDecisions":decisions,"providerFrame":frame
                }})))?;
            } else {
                transport.write(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Client capability is not supported"}}))?;
            }
            continue;
        }
        if frame["method"] == "session/update" {
            // session/load can replay history before returning. It is already in the
            // durable thread and must never be appended a second time.
            if stage == 4
                && stopping.is_none()
                && frame["params"]["sessionId"].as_str() == session_id.as_deref()
                && frame["params"]["_meta"]["isReplay"] != true
                && frame["params"]["update"]["_meta"]["isReplay"] != true
            {
                mapper.update(&frame["params"]["update"], &frame, events)?;
            }
            continue;
        }
        if frame["id"].as_u64() != Some(stage) {
            continue;
        }
        if frame.get("error").is_some() {
            if stopping.is_some() {
                events.send(Event::Finished)?;
                return Ok(());
            }
            bail!("ACP rejected request: {}", frame["error"]);
        }
        let result = frame.get("result").context("ACP response has no result")?;
        if stopping.is_some() {
            events.send(Event::Finished)?;
            return Ok(());
        }
        match stage {
            1 => {
                ensure!(
                    result["protocolVersion"].as_u64() == Some(1),
                    "This adapter requires ACP protocol version 1"
                );
                let mut params = json!({"cwd":launch.cwd,"mcpServers":[]});
                let method = if let Some(id) = &launch.session {
                    ensure!(
                        result["agentCapabilities"]["loadSession"] == true,
                        "ACP server cannot resume this stored session"
                    );
                    params["sessionId"] = json!(id);
                    "session/load"
                } else {
                    "session/new"
                };
                transport.write(&rpc(2, method, params))?;
                stage = 2;
            }
            2 => {
                let id = match &launch.session {
                    Some(previous) => {
                        if let Some(returned) = result["sessionId"].as_str() {
                            ensure!(
                                returned == previous,
                                "ACP returned a different session than requested"
                            );
                        }
                        previous.clone()
                    }
                    None => result["sessionId"]
                        .as_str()
                        .filter(|id| !id.is_empty())
                        .context("ACP returned no session ID")?
                        .to_owned(),
                };
                events.send(Event::Session(id.clone()))?;
                session_id = Some(id.clone());
                if let Some(model) = &launch.model {
                    let available = result["models"]["availableModels"].as_array();
                    ensure!(
                        available
                            .is_some_and(|models| models.iter().any(|m| m["modelId"] == *model)),
                        "ACP server did not advertise the requested model"
                    );
                    if result["models"]["currentModelId"] != *model {
                        transport.write(&rpc(
                            3,
                            "session/set_model",
                            json!({"sessionId":id,"modelId":model}),
                        ))?;
                        stage = 3;
                        continue;
                    }
                }
                transport.write(&rpc(
                    4,
                    "session/prompt",
                    json!({"sessionId":id,"prompt":[{"type":"text","text":launch.prompt}]}),
                ))?;
                stage = 4;
            }
            3 => {
                transport.write(&rpc(
                    4,
                    "session/prompt",
                    json!({"sessionId":session_id,"prompt":[{"type":"text","text":launch.prompt}]}),
                ))?;
                stage = 4;
            }
            4 => {
                ensure!(
                    result["stopReason"].is_string(),
                    "ACP prompt response has no stop reason; asynchronous ACP v2 is not supported by this adapter"
                );
                completed = true;
            }
            _ => unreachable!(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn acceptance_requires_once_option_and_never_selects_always() {
        let options = json!({"options":[{"optionId":"always","kind":"allow_always"},{"optionId":"once","kind":"allow_once"}]});
        assert_eq!(
            permission_reply(&options, &json!({"decision":"accept"})).unwrap()["outcome"]["optionId"],
            "once"
        );
        let permanent = json!({"options":[{"optionId":"always","kind":"allow_always"}]});
        assert!(permission_reply(&permanent, &json!({"decision":"accept"})).is_err());
        assert_eq!(
            permission_reply(&permanent, &json!({"decision":"decline"})).unwrap()["outcome"]["outcome"],
            "cancelled"
        );
    }
}
