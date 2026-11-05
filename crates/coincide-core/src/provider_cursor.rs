//! Cursor ACP with a private writable profile and in-memory authentication.
use super::{transport::*, *};
use std::collections::HashMap;
#[path = "provider_cursor_profile.rs"]
mod profile;
#[path = "provider_cursor_questions.rs"]
mod questions;

fn rpc(id: u64, method: &str, params: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})
}
enum Pending {
    Permission(Value),
    Questions(questions::Questions),
}
fn current_model(result: &Value) -> Option<&str> {
    result["configOptions"]
        .as_array()
        .and_then(|options| {
            options
                .iter()
                .find(|option| option["id"] == "model" || option["category"] == "model")
        })
        .and_then(|option| option["currentValue"].as_str())
        .or_else(|| result["models"]["currentModelId"].as_str())
}
fn listed_model(result: &Value, model: &str) -> bool {
    result["models"]["availableModels"]
        .as_array()
        .is_some_and(|models| models.iter().any(|entry| entry["modelId"] == model))
        || result["configOptions"].as_array().is_some_and(|options| {
            options.iter().any(|option| {
                (option["id"] == "model" || option["category"] == "model")
                    && option["options"].as_array().is_some_and(|options| {
                        options.iter().any(|entry| {
                            entry["value"] == model
                                || entry["options"].as_array().is_some_and(|group| {
                                    group.iter().any(|entry| entry["value"] == model)
                                })
                        })
                    })
            })
        })
}
fn error_report(text: &str) -> Option<&str> {
    if !text.starts_with("\n\n") {
        return None;
    }
    let body = text.trim();
    let first = body.lines().next()?;
    let account = matches!(
        first,
        "Please sign in to continue"
            | "Upgrade your plan to continue"
            | "Add a payment method to continue"
            | "Check your settings to continue"
            | "Something went wrong communicating with the server. Please try again."
    );
    let diagnostic = first.strip_prefix("Error: ").is_some_and(|message| {
        message.starts_with('[')
            || message
                .split_once("Error: ")
                .is_some_and(|(name, _)| name.chars().all(|c| c.is_ascii_alphabetic()))
    });
    (account || diagnostic).then_some(body)
}

pub(super) fn run(
    launch: Launch,
    images: Vec<ImageAttachment>,
    directory: Option<PathBuf>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    let directory =
        directory.context("Cursor requires a private per-thread profile configured by Coincide")?;
    let profile = profile::Profile::prepare(&directory, launch.session.as_deref())?;
    if launch.session.is_some() {
        event(
            events,
            "provider/notice",
            json!({"message":"Cursor resumes a private session copy with approval required. Original Cursor profile, permissions and model defaults remain unchanged."}),
        )?;
    }
    let target = launch
        .model
        .as_ref()
        .filter(|model| !matches!(model.as_str(), "default" | "cursor-default"))
        .cloned()
        .or_else(|| profile.default_model.clone());
    let mut args = vec!["--disable-project-configs".into()];
    if let Some(model) = &target {
        args.extend(["--model".into(), model.clone()]);
    }
    args.push("acp".into());
    let has_images = !images.is_empty();
    let mut prompt = Some(images::acp_content(&launch.prompt, &images));
    drop(images);
    let mut transport =
        Transport::spawn_with_environment(&launch, &args, &[], &profile.environment())?;
    // Cursor's variant picker exposes opaque variant IDs. Request its base-ID
    // model picker so the inherited profile model is compared without remapping.
    transport.write(&rpc(1,"initialize",json!({"protocolVersion":1,"clientInfo":{"name":"Coincide","version":env!("CARGO_PKG_VERSION")},"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false,"_meta":{"parameterizedModelPicker":true}}})))?;
    let mut stage = 1;
    let mut session = None;
    let started = Instant::now();
    let mut mapper = acp::Mapper::default();
    let mut pending = HashMap::<String, Pending>::new();
    let mut stopping = None;
    let mut completed = false;
    let mut held_error: Option<String> = None;
    loop {
        while let Ok(command) = commands.try_recv() {
            match command {
                Control::Stop if stopping.is_none() => {
                    if let Some(session) = &session {
                        let _=transport.write(&json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":session}}));
                    }
                    for (key, request) in pending.drain() {
                        let id: Value = serde_json::from_str(&key)?;
                        let result = match request {
                            Pending::Permission(_) => json!({"outcome":{"outcome":"cancelled"}}),
                            Pending::Questions(_) => json!({"outcome":{"outcome":"cancelled"}}),
                        };
                        let _ = transport.write(&json!({"jsonrpc":"2.0","id":id,"result":result}));
                    }
                    stopping = Some(Instant::now());
                }
                Control::Stop => {}
                Control::Reply { id, result } if stopping.is_none() => {
                    let key = id.to_string();
                    let answer = match pending.get(&key) {
                        Some(Pending::Permission(params)) => acp::permission_reply(params, &result),
                        Some(Pending::Questions(questions)) => questions.answer(&result),
                        None => Err(anyhow::anyhow!("Cursor request is no longer pending")),
                    };
                    match answer {
                        Ok(result) => {
                            transport.write(&json!({"jsonrpc":"2.0","id":id,"result":result}))?;
                            pending.remove(&key);
                        }
                        Err(error) => event(
                            events,
                            "provider/requestRejected",
                            json!({"id":id,"message":error.to_string()}),
                        )?,
                    }
                }
                Control::Reply { .. } => {}
            }
        }
        if (completed && (stopping.is_some() || transport.is_flushed()?))
            || stopping.is_some_and(|time: Instant| time.elapsed() >= Duration::from_secs(2))
        {
            events.send(Event::Finished)?;
            return Ok(());
        }
        ensure!(
            stage == 5 || started.elapsed() < Duration::from_secs(120),
            "Cursor startup timed out"
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
        raw(events, "cursor", &frame)?;
        if frame["method"] == "$/cancel_request" {
            let id = &frame["params"]["requestId"];
            if pending.remove(&id.to_string()).is_some() {
                transport.write(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32800,"message":"Request cancelled"}}))?;
                event(events, "provider/requestCancelled", json!({"id":id}))?;
            }
            continue;
        }
        if frame["method"].is_string() && frame.get("id").is_some() {
            let id = &frame["id"];
            let params = &frame["params"];
            ensure!(
                params["sessionId"]
                    .as_str()
                    .is_none_or(|id| Some(id) == session.as_deref()),
                "Cursor request belongs to an unexpected session"
            );
            if stage != 5 || stopping.is_some() {
                transport.write(
                    &json!({"jsonrpc":"2.0","id":id,"result":{"outcome":{"outcome":"cancelled"}}}),
                )?;
                continue;
            }
            ensure!(
                !pending.contains_key(&id.to_string()),
                "Cursor reused a pending request ID"
            );
            match frame["method"].as_str().unwrap_or("") {
                "session/request_permission"=>{
                    let options=params["options"].as_array().context("Cursor permission options missing")?;
                    let mut decisions=vec!["decline","cancel"];if options.iter().any(|option|option["kind"]=="allow_once"){decisions.insert(0,"accept");}
                    pending.insert(id.to_string(),Pending::Permission(params.clone()));
                    events.send(Event::Frame(json!({"id":id,"method":"item/commandExecution/requestApproval","params":{"availableDecisions":decisions,"toolCall":params["toolCall"],"providerFrame":frame}})))?;
                },
                "cursor/ask_question"=>match questions::Questions::parse(params) {
                    Ok(questions)=>{let mut normalized=questions.normalized.clone();normalized["providerFrame"]=frame.clone();pending.insert(id.to_string(),Pending::Questions(questions));events.send(Event::Frame(json!({"id":id,"method":"item/tool/requestUserInput","params":normalized})))?;},
                    Err(error)=>transport.write(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32602,"message":error.to_string()}}))?,
                },
                "cursor/create_plan"=>{
                    let text=params["plan"].as_str().or_else(||params["overview"].as_str()).unwrap_or("");
                    event(events,"item/completed",json!({"item":{"id":format!("cursor-plan-{id}"),"type":"plan","text":text},"providerFrame":frame}))?;
                    transport.write(&json!({"jsonrpc":"2.0","id":id,"result":{"outcome":{"outcome":"accepted"}}}))?;
                },
                "cursor/update_todos"|"cursor/generate_image"|"cursor/task"=>{
                    event(events,"provider/cursorExtension",json!({"providerFrame":frame}))?;
                    transport.write(&json!({"jsonrpc":"2.0","id":id,"result":{}}))?;
                },
                _=>transport.write(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Client capability is not supported"}}))?,
            }
            continue;
        }
        if frame["method"] == "session/update" {
            if stage == 5
                && stopping.is_none()
                && frame["params"]["sessionId"]
                    .as_str()
                    .is_none_or(|id| Some(id) == session.as_deref())
                && frame["params"]["_meta"]["isReplay"] != true
            {
                let update = &frame["params"]["update"];
                if update["sessionUpdate"] == "agent_message_chunk"
                    && let Some(report) = update["content"]["text"].as_str().and_then(error_report)
                {
                    held_error = Some(report.into());
                    continue;
                }
                if let Some(report) = held_error.take() {
                    delta(events, "cursor-provider-report", &report, false)?;
                }
                mapper.update(update, &frame, events)?;
            }
            continue;
        }
        if frame["id"].as_u64() != Some(stage) {
            continue;
        }
        if stopping.is_some() {
            events.send(Event::Finished)?;
            return Ok(());
        }
        if frame.get("error").is_some() {
            if frame["error"]["code"] == -32000 {
                bail!(
                    "Cursor authentication is unavailable or expired; configure a valid environment credential. No interactive login was started"
                );
            }
            bail!("Cursor rejected request: {}", frame["error"]);
        }
        let result = frame
            .get("result")
            .context("Cursor response has no result")?;
        match stage {
            1 => {
                ensure!(
                    result["protocolVersion"].as_u64() == Some(1),
                    "Cursor requires ACP protocol version 1"
                );
                ensure!(
                    !has_images
                        || result["agentCapabilities"]["promptCapabilities"]["image"] != false,
                    "Cursor reports no image support; no prompt was sent"
                );
                let mut params = json!({"cwd":launch.cwd,"mcpServers":[]});
                let method = if let Some(id) = &launch.session {
                    ensure!(
                        result["agentCapabilities"]["loadSession"] != false,
                        "Cursor cannot resume this stored session"
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
                        ensure!(
                            result["sessionId"].as_str().is_none_or(|id| id == previous),
                            "Cursor returned a different native session"
                        );
                        previous.clone()
                    }
                    None => result["sessionId"]
                        .as_str()
                        .filter(|id| !id.is_empty())
                        .context("Cursor returned no session ID")?
                        .to_owned(),
                };
                events.send(Event::Session(id.clone()))?;
                session = Some(id.clone());
                if let Some(target) = &target
                    && current_model(result) != Some(target)
                {
                    ensure!(
                        listed_model(result, target),
                        "Cursor did not confirm or advertise the requested model; no prompt was sent"
                    );
                    transport.write(&rpc(
                        3,
                        "session/set_config_option",
                        json!({"sessionId":id,"configId":"model","value":target}),
                    ))?;
                    stage = 3;
                } else {
                    transport.write(&rpc(
                        4,
                        "session/set_mode",
                        json!({"sessionId":id,"modeId":"agent"}),
                    ))?;
                    stage = 4;
                }
            }
            3 => {
                ensure!(
                    current_model(result).is_some_and(|model| Some(model) == target.as_deref()),
                    "Cursor did not apply the selected model"
                );
                transport.write(&rpc(
                    4,
                    "session/set_mode",
                    json!({"sessionId":session,"modeId":"agent"}),
                ))?;
                stage = 4;
            }
            4 => {
                transport.write(&rpc(5,"session/prompt",json!({"sessionId":session,"prompt":prompt.take().context("Cursor prompt was already sent")?})))?;
                stage = 5;
            }
            5 => {
                if let Some(error) = held_error {
                    bail!("Cursor turn failed: {error}");
                }
                let reason = result["stopReason"]
                    .as_str()
                    .context("Cursor prompt response has no completion reason")?;
                ensure!(
                    matches!(
                        reason,
                        "end_turn" | "max_tokens" | "max_turn_requests" | "refusal"
                    ),
                    "Cursor turn did not complete ({reason})"
                );
                completed = true;
            }
            _ => unreachable!(),
        }
    }
}
