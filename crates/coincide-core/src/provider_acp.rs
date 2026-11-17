//! ACP v1 core transport. No filesystem or terminal capabilities are advertised.
//! Provider-specific login, discovery and extensions remain separate integrations.
use super::{transport::*, *};
use std::collections::HashMap;

fn rpc(id: u64, method: &str, params: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})
}

fn requires_sign_in(frame: &Value) -> bool {
    let error = &frame["error"];
    // Some agents also use -32000 for generic failures, including failed
    // session restores. The code alone does not establish a sign-in problem.
    error["code"].as_i64() == Some(-32000)
        && error["message"].as_str().is_some_and(|message| {
            message
                .trim()
                .trim_end_matches('.')
                .eq_ignore_ascii_case("authentication required")
        })
}

fn selected_option<'a>(options: &'a [Value], kind: &str) -> Option<&'a Value> {
    options
        .iter()
        .find(|option| option["kind"] == kind && option["optionId"].is_string())
}

fn model_option(result: &Value) -> Option<&Value> {
    let options = result["configOptions"].as_array()?;
    options
        .iter()
        .find(|option| option["id"] == "model" && option["type"] == "select")
        .or_else(|| {
            options.iter().find(|option| {
                option["category"] == "model"
                    && option["type"] == "select"
                    && option["id"].is_string()
            })
        })
}
fn option_has_value(option: &Value, target: &str) -> bool {
    option["options"].as_array().is_some_and(|options| {
        options.iter().any(|row| {
            row["value"] == target
                || row["options"]
                    .as_array()
                    .is_some_and(|group| group.iter().any(|item| item["value"] == target))
        })
    })
}
fn model_entries(result: &Value) -> Vec<Value> {
    let mut rows = vec![
        json!({"id":"default","displayName":"Provider default", "reportedEfforts":[],
        "reportedDefaultEffort":null,"reportedSpeeds":[],"supportsImages":null}),
    ];
    let mut add = |value: &Value, id_key: &str| {
        let Some(id) = value[id_key].as_str().filter(|id| *id != "default") else {
            return;
        };
        if crate::composer_selection::validate_model(id).is_err()
            || rows.iter().any(|row| row["id"] == id)
        {
            return;
        }
        let name = value["name"]
            .as_str()
            .or_else(|| value["label"].as_str())
            .unwrap_or(id);
        if name.len() > 512 || name.chars().any(char::is_control) {
            return;
        }
        rows.push(json!({"id":id,"displayName":name,"reportedEfforts":[],
            "reportedDefaultEffort":null,"reportedSpeeds":[],"supportsImages":null}));
    };
    if let Some(option) = model_option(result) {
        for item in option["options"]
            .as_array()
            .into_iter()
            .flatten()
            .take(1000)
        {
            if let Some(group) = item["options"].as_array() {
                for item in group.iter().take(1000) {
                    add(item, "value");
                }
            } else {
                add(item, "value");
            }
        }
    }
    for item in result["models"]["availableModels"]
        .as_array()
        .into_iter()
        .flatten()
        .take(1000)
    {
        add(item, "modelId");
    }
    rows.truncate(1000);
    rows
}

/// Start a bounded ACP session solely to read its advertised model options.
/// No prompt, permission, filesystem or terminal action is sent.
pub(super) fn model_catalog(
    executable: &std::path::Path,
    cwd: &std::path::Path,
    arguments: &[String],
    is_fx: bool,
    cancelled: &impl Fn() -> bool,
) -> Result<Vec<Value>> {
    let launch = Launch {
        executable: executable.into(),
        cwd: cwd.into(),
        session: None,
        prompt: String::new(),
        model: None,
        variant: None,
        full_access: false,
    };
    let mut transport = CatalogTransport::spawn(&launch, arguments, &[], &[], None)?;
    let deadline = Instant::now() + Duration::from_secs(15);
    transport.write(rpc(
        1,
        "initialize",
        json!({"protocolVersion":1,
        "clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},
        "clientInfo":{"name":"Coincide","version":env!("CARGO_PKG_VERSION")}}),
    ))?;
    let mut stage = 1;
    loop {
        ensure!(
            cancelled() && Instant::now() < deadline,
            "ACP model discovery timed out or was cancelled"
        );
        let Some(frame) = transport.next()? else {
            continue;
        };
        if frame.get("id").is_some() && frame.get("method").is_some() {
            bail!("ACP requested an interactive action during model discovery");
        }
        if frame["id"].as_u64() != Some(stage) {
            continue;
        }
        if requires_sign_in(&frame) {
            bail!("{}", crate::acp_registry::SIGN_IN_REQUIRED);
        }
        ensure!(
            frame.get("error").is_none(),
            "The agent could not provide its models"
        );
        let result = frame
            .get("result")
            .context("ACP model discovery response missing")?;
        if stage == 1 {
            ensure!(
                result["protocolVersion"] == 1,
                "ACP agent does not support protocol version 1"
            );
            let mut params = json!({"cwd":cwd,"mcpServers":[]});
            if is_fx {
                params["_meta"] = json!({"fx":{"profileMcpServers":true}});
            }
            transport.write(rpc(2, "session/new", params))?;
            stage = 2;
        } else {
            ensure!(
                result["sessionId"]
                    .as_str()
                    .is_some_and(|id| !id.is_empty()),
                "ACP session ID missing"
            );
            return Ok(model_entries(result));
        }
    }
}

// These updates are produced by the live prompt, after session/replay checks.
// Command catalogs and other session metadata do not acknowledge a prompt.
pub(super) fn prompt_activity(update: &Value) -> bool {
    matches!(
        update["sessionUpdate"].as_str(),
        Some(
            "agent_message_chunk"
                | "agent_message"
                | "agent_thought_chunk"
                | "agent_thought"
                | "tool_call"
                | "tool_call_update"
        )
    )
}

pub(super) fn permission_reply(params: &Value, answer: &Value) -> Result<Value> {
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

pub(super) struct Mapper {
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
    pub(super) fn update(
        &mut self,
        update: &Value,
        frame: &Value,
        events: &Sender<Event>,
    ) -> Result<()> {
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
#[derive(Clone, Copy)]
enum Flavor {
    Standard,
    Grok,
    Registered { fx: bool },
}

pub(super) fn run_grok(
    launch: Launch,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    run_flavored(
        launch,
        grok::arguments(),
        images,
        commands,
        events,
        Flavor::Grok,
    )
}

pub(super) fn run(
    launch: Launch,
    arguments: Vec<String>,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    run_flavored(
        launch,
        arguments,
        images,
        commands,
        events,
        Flavor::Standard,
    )
}

pub(super) fn run_registered(
    launch: Launch,
    arguments: Vec<String>,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
    is_fx: bool,
) -> Result<()> {
    run_flavored(
        launch,
        arguments,
        images,
        commands,
        events,
        Flavor::Registered { fx: is_fx },
    )
}

fn run_flavored(
    launch: Launch,
    arguments: Vec<String>,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
    flavor: Flavor,
) -> Result<()> {
    let is_grok = matches!(flavor, Flavor::Grok);
    let persist_only_resumable = matches!(flavor, Flavor::Registered { .. });
    let is_fx = matches!(flavor, Flavor::Registered { fx: true });
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
    let mut model_config = None::<String>;
    let mut initial_fx_session = None::<Value>;
    let prompt_id = uuid::Uuid::new_v4().to_string();
    let mut mapper = Mapper::default();
    let mut accepted = false;
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
        if !(frame["error"]["code"] == -32000 || is_grok && stage == 5) {
            if stage == 1 && frame["id"] == 1 && frame["result"].get("authMethods").is_some() {
                let mut diagnostic = frame.clone();
                if let Some(result) = diagnostic["result"].as_object_mut() {
                    result.remove("authMethods");
                }
                raw(events, if is_grok { "grok" } else { "acp" }, &diagnostic)?;
            } else {
                raw(events, if is_grok { "grok" } else { "acp" }, &frame)?;
            }
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
                if launch.full_access
                    && let Some(option) = selected_option(options, "allow_once")
                {
                    transport.write(&json!({"jsonrpc":"2.0","id":id,
                        "result":{"outcome":{"outcome":"selected","optionId":option["optionId"]}}}))?;
                    continue;
                }
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
                if !accepted && prompt_activity(&frame["params"]["update"]) {
                    events.send(Event::TurnAccepted)?;
                    accepted = true;
                }
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
            if requires_sign_in(&frame) {
                bail!("{}", crate::acp_registry::SIGN_IN_REQUIRED);
            }
            if frame["error"]["code"] == -32000 {
                let message = frame["error"]["message"]
                    .as_str()
                    .unwrap_or("The agent rejected the request");
                bail!(
                    "ACP rejected request: {}",
                    json!({"code":-32000,"message":message})
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
                let can_resume = result["agentCapabilities"]["loadSession"] == true;
                if persist_only_resumable {
                    event(
                        events,
                        "provider/acpSessionPersistence",
                        json!({"canResume":can_resume}),
                    )?;
                }
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
                if is_fx {
                    params["_meta"] = json!({"fx":{"profileMcpServers":true}});
                }
                let method = if let Some(id) = &launch.session {
                    ensure!(can_resume, "ACP server cannot resume this stored session");
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
            2 | 6 => {
                let id = if stage == 6 {
                    ensure!(
                        result["configOptions"]
                            .as_array()
                            .is_some_and(|options| options
                                .iter()
                                .any(|option| option["id"] == "mode"
                                    && option["currentValue"] == "ask")),
                        "fx did not confirm supervised mode; no prompt was sent"
                    );
                    session_id.clone().context("fx session ID missing")?
                } else {
                    match &launch.session {
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
                    }
                };
                if stage == 2 {
                    events.send(Event::Session(id.clone()))?;
                    session_id = Some(id.clone());
                    if is_fx {
                        let mode = result["configOptions"]
                            .as_array()
                            .and_then(|options| {
                                options.iter().find(|option| {
                                    option["id"] == "mode" && option["type"] == "select"
                                })
                            })
                            .context("fx did not report a supervised mode; no prompt was sent")?;
                        ensure!(
                            option_has_value(mode, "ask"),
                            "fx did not offer supervised mode; no prompt was sent"
                        );
                        initial_fx_session = Some(result.clone());
                        transport.write(&rpc(
                            6,
                            "session/set_config_option",
                            json!({"sessionId":id,"configId":"mode","value":"ask"}),
                        ))?;
                        stage = 6;
                        continue;
                    }
                }
                let model_result = if stage == 6 && model_option(result).is_none() {
                    initial_fx_session
                        .as_ref()
                        .context("fx session options missing")?
                } else {
                    result
                };
                if let Some(model) = launch
                    .model
                    .as_ref()
                    .filter(|model| !is_grok || !matches!(model.as_str(), "default" | "grok-build"))
                {
                    let options = model_entries(model_result);
                    ensure!(
                        is_grok || options.iter().any(|row| row["id"] == *model),
                        "ACP server did not advertise the requested model"
                    );
                    let option = model_option(model_result);
                    let current = option
                        .and_then(|option| option["currentValue"].as_str())
                        .or_else(|| model_result["models"]["currentModelId"].as_str());
                    if current != Some(model) {
                        let (method, params) = if let Some(option) = option {
                            let config_id = option["id"]
                                .as_str()
                                .context("ACP model option ID missing")?;
                            model_config = Some(config_id.to_owned());
                            (
                                "session/set_config_option",
                                json!({"sessionId":id,"configId":config_id,"value":model}),
                            )
                        } else {
                            ("session/set_model", json!({"sessionId":id,"modelId":model}))
                        };
                        transport.write(&rpc(3, method, params))?;
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
                if let Some(config_id) = model_config.take() {
                    ensure!(
                        result["configOptions"]
                            .as_array()
                            .is_some_and(|options| options
                                .iter()
                                .any(|option| option["id"] == config_id
                                    && option["currentValue"].as_str() == launch.model.as_deref())),
                        "ACP agent did not confirm the selected model; no prompt was sent"
                    );
                }
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
    fn session_metadata_does_not_acknowledge_a_prompt() {
        for kind in [
            "available_commands_update",
            "current_mode_update",
            "config_option_update",
        ] {
            assert!(!prompt_activity(&json!({"sessionUpdate":kind})));
        }
        for kind in ["agent_message_chunk", "agent_thought_chunk", "tool_call"] {
            assert!(prompt_activity(&json!({"sessionUpdate":kind})));
        }
    }
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
