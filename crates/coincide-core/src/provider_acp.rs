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

enum PendingRequest {
    Permission(Value),
    Questions(Vec<grok::Question>),
}

pub(super) fn run_grok(
    launch: Launch,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    run_flavored(launch, grok::arguments(), images, commands, events, true)
}

pub(super) fn run(
    launch: Launch,
    arguments: Vec<String>,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    run_flavored(launch, arguments, images, commands, events, false)
}

fn run_flavored(
    launch: Launch,
    arguments: Vec<String>,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
    is_grok: bool,
) -> Result<()> {
    let has_images = !images.is_empty();
    let mut prompt = Some(images::acp_content(&launch.prompt, &images));
    drop(images);
    let mut transport = Transport::spawn(&launch, &arguments, &[])?;
    let mut initialize = json!({"protocolVersion":1,
        "clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},
        "clientInfo":{"name":"Coincide","version":env!("CARGO_PKG_VERSION")}});
    if is_grok {
        initialize["_meta"] = json!({"clientType":"extension"});
    }
    transport.write(&rpc(1, "initialize", initialize))?;
    let mut stage = 1;
    let mut session_id: Option<String> = None;
    let mut pending = HashMap::<String, PendingRequest>::new();
    let mut auth_method = None;
    let mut authentication_attempted = false;
    let mut session_request = None;
    let prompt_id = uuid::Uuid::new_v4().to_string();
    let mut mapper = Mapper::default();
    let started = Instant::now();
    let mut stopping: Option<Instant> = None;
    let mut completed = false;
    loop {
        while let Ok(command) = commands.try_recv() {
            match command {
                Control::Stop if stopping.is_none() => {
                    if is_grok {
                        // Grok schedules background wake-ups; ending its process tree is
                        // the only cancellation that prevents an old turn from continuing.
                        events.send(Event::Finished)?;
                        return Ok(());
                    }
                    if let Some(id) = &session_id {
                        let _ = transport.write(&json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":id}}));
                    }
                    stopping = Some(Instant::now());
                }
                Control::Stop => {}
                Control::Reply { id, result } if stopping.is_none() => {
                    if let Some(params) = pending.get(&id.to_string()) {
                        let response = match params {
                            PendingRequest::Permission(params) => permission_reply(params, &result),
                            PendingRequest::Questions(questions) => {
                                grok::answer(questions, &result)
                            }
                        };
                        match response {
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
            stage == 4 || started.elapsed() < Duration::from_secs(120),
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
        // Authentication responses can contain credential material; never persist them.
        if !is_grok || (stage != 5 && frame["error"]["code"] != -32000) {
            raw(events, if is_grok { "grok" } else { "acp" }, &frame)?;
        }
        if is_grok
            && stage == 4
            && stopping.is_none()
            && grok::completion(&frame, session_id.as_deref().unwrap_or(""), &prompt_id)?
        {
            completed = true;
            continue;
        }
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
                pending.insert(id.to_string(), PendingRequest::Permission(params.clone()));
                events.send(Event::Frame(json!({"id":id,"method":"item/commandExecution/requestApproval","params":{
                    "toolCall":params["toolCall"],"availableDecisions":decisions,"providerFrame":frame
                }})))?;
            } else if is_grok
                && stage == 4
                && stopping.is_none()
                && matches!(
                    grok::method(frame["method"].as_str().unwrap_or("")),
                    Some("ask_user_question" | "exit_plan_mode")
                )
            {
                let params = grok::unwrap_params(&frame["params"]);
                ensure!(
                    params["sessionId"]
                        .as_str()
                        .is_none_or(|id| Some(id) == session_id.as_deref()),
                    "Grok request belongs to another session"
                );
                ensure!(
                    !pending.contains_key(&id.to_string()),
                    "Grok reused a pending request ID"
                );
                if grok::method(frame["method"].as_str().unwrap_or("")) == Some("ask_user_question")
                {
                    match grok::questions(params) {
                        Ok(questions) => {
                            let normalized = grok::question_params(&questions, &frame);
                            pending.insert(id.to_string(), PendingRequest::Questions(questions));
                            events.send(Event::Frame(json!({"id":id,"method":"item/tool/requestUserInput","params":normalized})))?;
                        }
                        Err(error) => transport.write(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32602,"message":error.to_string()}}))?,
                    }
                } else {
                    if let Some(plan) = params["planContent"].as_str() {
                        event(
                            events,
                            "item/completed",
                            json!({"item":{"id":format!("grok-plan-{prompt_id}"),"type":"plan","text":plan},"providerFrame":frame}),
                        )?;
                    }
                    // Capturing a plan is not consent to implement it.
                    transport.write(&json!({"jsonrpc":"2.0","id":id,"result":{"outcome":"abandoned","feedback":"The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."}}))?;
                }
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
                && (!is_grok || grok::foreground_update(&frame["params"], &prompt_id))
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
            if is_grok
                && stage == 2
                && frame["error"]["code"] == -32000
                && !authentication_attempted
            {
                let method = auth_method.as_ref().context("Grok requires a configured non-interactive authentication method; sign in with its CLI first")?;
                authentication_attempted = true;
                transport.write(&rpc(5, "authenticate", json!({"methodId":method})))?;
                stage = 5;
                continue;
            }
            if is_grok && (stage == 5 || frame["error"]["code"] == -32000) {
                bail!(
                    "Grok authentication failed; sign in with the configured Grok CLI account first"
                );
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
                ensure!(
                    !has_images
                        || is_grok
                        || result["agentCapabilities"]["promptCapabilities"]["image"] == true,
                    "ACP server does not advertise image prompt support; no prompt was sent"
                );
                if is_grok {
                    auth_method =
                        grok::authentication_method(result, grok::configured_authentication());
                }
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
                let request = rpc(2, method, params);
                transport.write(&request)?;
                session_request = Some(request);
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
                if let Some(model) = launch
                    .model
                    .as_ref()
                    .filter(|model| !is_grok || !matches!(model.as_str(), "default" | "grok-build"))
                {
                    let available = result["models"]["availableModels"].as_array();
                    ensure!(
                        is_grok
                            || available.is_some_and(|models| models
                                .iter()
                                .any(|m| m["modelId"] == *model)),
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
                    prompt_params(
                        json!(id),
                        prompt.take().context("ACP prompt was already sent")?,
                        is_grok,
                        &prompt_id,
                    ),
                ))?;
                stage = 4;
            }
            3 => {
                transport.write(&rpc(
                    4,
                    "session/prompt",
                    prompt_params(
                        json!(session_id),
                        prompt.take().context("ACP prompt was already sent")?,
                        is_grok,
                        &prompt_id,
                    ),
                ))?;
                stage = 4;
            }
            4 => {
                ensure!(
                    result["stopReason"].is_string(),
                    "ACP prompt response has no stop reason; asynchronous ACP v2 is not supported by this adapter"
                );
                if is_grok {
                    grok::validate_stop_reason(
                        result["stopReason"].as_str().unwrap_or(""),
                        result["agentResult"].as_str(),
                    )?;
                }
                completed = true;
            }
            5 => {
                transport.write(
                    session_request
                        .as_ref()
                        .context("Grok authentication lost its session request")?,
                )?;
                stage = 2;
            }
            _ => unreachable!(),
        }
    }
}

fn prompt_params(session_id: Value, prompt: Value, is_grok: bool, prompt_id: &str) -> Value {
    let mut params = json!({"sessionId":session_id,"prompt":prompt});
    if is_grok {
        params["_meta"] = json!({"promptId":prompt_id,"requestId":prompt_id});
    }
    params
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
