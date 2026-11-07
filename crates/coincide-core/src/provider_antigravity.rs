//! Antigravity ACP 1.x, using a private OAuth profile and immutable runtime copy.
use super::{transport::*, *};
use std::collections::HashMap;
#[path = "provider_antigravity_files.rs"]
mod files;
#[path = "provider_antigravity_profile.rs"]
mod profile;
pub(super) const AUTH_FAILURE: &str = "Antigravity Google sign-in is unavailable or expired; sign in through the dedicated setup flow. No interactive login was started";

enum Pending {
    Permission(Value),
    Write(Value),
    Question(Value),
}
fn rpc(id: u64, method: &str, params: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})
}
fn option<'a>(result: &'a Value, category: &str) -> Option<&'a Value> {
    result["configOptions"]
        .as_array()?
        .iter()
        .find(|v| v["category"] == category || v["id"] == category)
}
fn offers(option: &Value, value: &str) -> bool {
    option["options"].as_array().is_some_and(|opts| {
        opts.iter().any(|v| {
            v["value"] == value
                || v["options"]
                    .as_array()
                    .is_some_and(|group| group.iter().any(|v| v["value"] == value))
        })
    })
}
fn question(params: &Value) -> Result<Option<Value>> {
    let id = params["toolCall"]["toolCallId"].as_str().unwrap_or("");
    if !id.starts_with("interaction_") {
        return Ok(None);
    }
    let options = params["options"]
        .as_array()
        .context("Antigravity question has no options")?;
    ensure!(
        !options.is_empty() && options.len() <= 100,
        "Antigravity question options are unsupported"
    );
    let mut ids = std::collections::HashSet::new();
    let mut labels = std::collections::HashSet::new();
    let mut normalized = Vec::new();
    for option in options {
        let value = option["optionId"]
            .as_str()
            .filter(|s| !s.is_empty())
            .context("Antigravity answer ID missing")?;
        ensure!(ids.insert(value), "Antigravity repeated an answer ID");
        let label = option["name"]
            .as_str()
            .filter(|s| !s.is_empty())
            .unwrap_or(value);
        let label = if labels.insert(label.to_owned()) {
            label.to_owned()
        } else {
            format!("{label} ({value})")
        };
        normalized.push(json!({"label":label,"value":value}));
    }
    Ok(Some(
        json!({"questions":[{"id":id,"question":params["toolCall"]["title"].as_str().unwrap_or("Choose an option"),"multiSelect":false,"allowsFreeText":false,"options":normalized}]}),
    ))
}
fn answer_question(question: &Value, reply: &Value) -> Result<Value> {
    if reply["decision"] == "cancel" {
        return Ok(json!({"outcome":{"outcome":"cancelled"}}));
    }
    let q = &question["questions"][0];
    let id = q["id"]
        .as_str()
        .context("Antigravity question ID missing")?;
    let values = reply["answers"][id]["answers"]
        .as_array()
        .context("Antigravity question requires an answer")?;
    ensure!(
        values.len() == 1,
        "Antigravity question requires one option"
    );
    let answer = values[0]
        .as_str()
        .context("Antigravity answer must be text")?;
    let options = q["options"]
        .as_array()
        .context("Antigravity options missing")?;
    let option = options
        .iter()
        .find(|v| v["value"] == answer)
        .or_else(|| options.iter().find(|v| v["label"] == answer))
        .context("Antigravity answer must match an offered option")?;
    Ok(json!({"outcome":{"outcome":"selected","optionId":option["value"]}}))
}
pub(super) fn run(
    launch: Launch,
    images: Vec<ImageAttachment>,
    directory: Option<PathBuf>,
    source: Option<PathBuf>,
    acknowledged: bool,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    // Completion is a lifecycle boundary: the child must be reaped, its private
    // extraction files removed and the profile lock released before the engine
    // can start another turn on this same profile. Errors follow the same order:
    // Session emits Failed only after this function unwinds its owned resources.
    run_owned(
        launch,
        images,
        directory,
        source,
        acknowledged,
        commands,
        events,
    )?;
    events.send(Event::Finished)?;
    Ok(())
}

fn run_owned(
    mut launch: Launch,
    images: Vec<ImageAttachment>,
    directory: Option<PathBuf>,
    source: Option<PathBuf>,
    acknowledged: bool,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    ensure!(
        acknowledged,
        "Antigravity requires explicit account-risk acknowledgement in this Rust app before launch"
    );
    ensure!(
        cfg!(unix),
        "Antigravity private browser suppression is not supported on this platform yet"
    );
    launch.cwd = launch.cwd.canonicalize()?;
    let files = files::Files::new(&launch.cwd)?;
    let auth_method = if crate::provider_configuration::native_key_profile("antigravity") {
        "gemini-api-key"
    } else {
        "oauth-personal"
    };
    let profile = profile::Profile::prepare(
        &directory.context("Antigravity requires a private profile")?,
        source.as_deref(),
        launch.session.as_deref(),
    )?;
    let runtime_source = launch.executable.clone();
    launch.executable = profile.runtime(&runtime_source)?;
    let _runtime_configuration = crate::api::provider_configuration::antigravity_runtime_copy(
        &runtime_source,
        &launch.executable,
    )?;
    let removed = profile::removed_environment();
    let removed = removed.iter().map(String::as_str).collect::<Vec<_>>();
    let mut transport =
        Transport::spawn_antigravity(&launch, &removed, &profile.environment(&launch.executable))?;
    let has_images = !images.is_empty();
    ensure!(
        images.iter().all(|image| matches!(
            image.mime_type(),
            "image/png" | "image/jpeg" | "image/webp" | "image/bmp"
        )),
        "Antigravity does not support this image type; no prompt was sent"
    );
    let mut prompt = Some(images::acp_content(&launch.prompt, &images));
    drop(images);
    transport.write(&rpc(1,"initialize",json!({"protocolVersion":1,"clientInfo":{"name":"Coincide","version":env!("CARGO_PKG_VERSION")},"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":false}})))?;
    let mut stage = 1;
    let mut initialized = json!({});
    let mut setup = json!({});
    let mut session = None;
    let mut pending = HashMap::new();
    let mut mapper = acp::Mapper::default();
    let started = Instant::now();
    let mut stopping = None;
    let mut completed = false;
    loop {
        while let Ok(command) = commands.try_recv() {
            match command {
                Control::Stop if stopping.is_none() => {
                    if let Some(id) = &session {
                        let _=transport.write(&json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":id}}));
                    }
                    stopping = Some(Instant::now());
                }
                Control::Stop => {}
                Control::Reply { id, result } if stopping.is_none() => {
                    let key = id.to_string();
                    if let Some(Pending::Write(params)) = pending.get(&key) {
                        let result = if result["decision"] == "accept" {
                            files.write(params)
                        } else {
                            Err(anyhow::anyhow!("File write was not approved"))
                        };
                        let response = match result {
                            Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
                            Err(error) => {
                                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":error.to_string()}})
                            }
                        };
                        transport.write(&response)?;
                        pending.remove(&key);
                        continue;
                    }
                    let response = match pending.get(&key) {
                        Some(Pending::Permission(params)) => acp::permission_reply(params, &result),
                        Some(Pending::Question(question)) => answer_question(question, &result),
                        Some(Pending::Write(_)) => unreachable!(),
                        None => Err(anyhow::anyhow!("Antigravity request is no longer pending")),
                    };
                    match response {
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
            || stopping.is_some_and(|t: Instant| t.elapsed() >= Duration::from_secs(2))
        {
            return Ok(());
        }
        ensure!(
            stage == 6 || started.elapsed() < Duration::from_secs(180),
            "Antigravity startup timed out"
        );
        let frame = match transport.next() {
            Ok(Some(f)) => f,
            Ok(None) => continue,
            Err(_) if stopping.is_some() => {
                return Ok(());
            }
            Err(e) => return Err(e),
        };
        // Authentication/errors can contain tokens or complete OAuth URLs. Never
        // include them in persisted raw frames or surfaced error messages.
        if stage != 2 && frame.get("error").is_none() {
            raw(events, "antigravity", &frame)?;
        }
        if frame["method"].is_string() && frame.get("id").is_some() {
            let id = &frame["id"];
            let params = &frame["params"];
            ensure!(
                params["sessionId"]
                    .as_str()
                    .is_none_or(|v| Some(v) == session.as_deref()),
                "Antigravity request belongs to another session"
            );
            if stage != 6 || stopping.is_some() {
                transport.write(
                    &json!({"jsonrpc":"2.0","id":id,"result":{"outcome":{"outcome":"cancelled"}}}),
                )?;
                continue;
            }
            ensure!(
                !pending.contains_key(&id.to_string()),
                "Antigravity repeated a pending request ID"
            );
            if frame["method"] == "fs/read_text_file" {
                let response = match files.read(params) {
                    Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
                    Err(error) => {
                        json!({"jsonrpc":"2.0","id":id,"error":{"code":-32602,"message":error.to_string()}})
                    }
                };
                transport.write(&response)?;
                continue;
            }
            if frame["method"] == "fs/write_text_file" {
                match files.validate_write(params) {
                    Ok(())=>{pending.insert(id.to_string(),Pending::Write(params.clone()));events.send(Event::Frame(json!({"id":id,"method":"item/commandExecution/requestApproval","params":{"availableDecisions":["accept","decline","cancel"],"toolCall":{"title":"Write workspace file","rawInput":params},"providerFrame":frame}})))?;},
                    Err(error)=>transport.write(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32602,"message":error.to_string()}}))?,
                }
                continue;
            }
            if frame["method"] == "session/request_permission" {
                if let Some(mut question) = question(params)? {
                    question["providerFrame"] = frame.clone();
                    pending.insert(id.to_string(), Pending::Question(question.clone()));
                    events.send(Event::Frame(
                        json!({"id":id,"method":"item/tool/requestUserInput","params":question}),
                    ))?;
                } else {
                    let options = params["options"]
                        .as_array()
                        .context("Antigravity permission options missing")?;
                    let mut decisions = vec!["decline", "cancel"];
                    if options.iter().any(|v| v["kind"] == "allow_once") {
                        decisions.insert(0, "accept");
                    }
                    pending.insert(id.to_string(), Pending::Permission(params.clone()));
                    events.send(Event::Frame(json!({"id":id,"method":"item/commandExecution/requestApproval","params":{"toolCall":params["toolCall"],"availableDecisions":decisions,"providerFrame":frame}})))?;
                }
            } else {
                transport.write(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Client capability is not connected"}}))?;
            }
            continue;
        }
        if frame["method"] == "session/update" {
            if stage == 6
                && stopping.is_none()
                && frame["params"]["sessionId"].as_str() == session.as_deref()
                && frame["params"]["_meta"]["isReplay"] != true
            {
                mapper.update(&frame["params"]["update"], &frame, events)?;
            }
            continue;
        }
        if frame["id"].as_u64() != Some(stage) {
            continue;
        }
        if stopping.is_some() {
            return Ok(());
        }
        if let Some(error) = frame.get("error") {
            if error["message"]
                .as_str()
                .is_some_and(|s| s.contains("SUBSCRIPTION_REQUIRED"))
            {
                bail!("Antigravity requires an eligible subscription for this account");
            }
            if stage == 2 || error["code"] == -32000 {
                bail!("{AUTH_FAILURE}");
            }
            bail!(
                "Antigravity rejected the request at stage {stage}; no replacement session was created"
            );
        }
        let result = frame
            .get("result")
            .context("Antigravity response has no result")?;
        match stage {
            1 => {
                ensure!(
                    result["protocolVersion"] == 1,
                    "Antigravity requires ACP protocol version 1"
                );
                ensure!(
                    !has_images
                        || result["agentCapabilities"]["promptCapabilities"]["image"] != false,
                    "Antigravity reports no image support"
                );
                ensure!(
                    result["authMethods"]
                        .as_array()
                        .is_some_and(|methods| methods.iter().any(|m| m["id"] == auth_method)),
                    "Antigravity did not offer the selected account authentication method"
                );
                initialized = result.clone();
                transport.write(&rpc(2, "authenticate", json!({"methodId":auth_method})))?;
                stage = 2;
            }
            2 => {
                let mut params = json!({"cwd":launch.cwd,"mcpServers":[]});
                let method = if let Some(id) = &launch.session {
                    params["sessionId"] = json!(id);
                    if initialized["agentCapabilities"]["sessionCapabilities"]
                        .get("resume")
                        .is_some()
                    {
                        "session/resume"
                    } else {
                        ensure!(
                            initialized["agentCapabilities"]["loadSession"] == true,
                            "Antigravity cannot resume this native session"
                        );
                        "session/load"
                    }
                } else {
                    "session/new"
                };
                transport.write(&rpc(3, method, params))?;
                stage = 3;
            }
            3 => {
                let id = if let Some(previous) = &launch.session {
                    ensure!(
                        result["sessionId"].as_str().is_none_or(|v| v == previous),
                        "Antigravity resumed a different native session"
                    );
                    previous.clone()
                } else {
                    result["sessionId"]
                        .as_str()
                        .context("Antigravity returned no native session")?
                        .to_owned()
                };
                uuid::Uuid::parse_str(&id).context("Antigravity native session ID is invalid")?;
                events.send(Event::Session(id.clone()))?;
                session = Some(id);
                setup = result.clone();
                let target = launch
                    .model
                    .as_deref()
                    .filter(|m| !matches!(*m, "default" | "antigravity-default"));
                if let Some(model) = target {
                    if let Some(option) = option(result, "model") {
                        ensure!(
                            offers(option, model),
                            "Antigravity did not advertise the selected model"
                        );
                        transport.write(&rpc(
                            4,
                            "session/set_config_option",
                            json!({"sessionId":session,"configId":option["id"],"value":model}),
                        ))?;
                    } else {
                        ensure!(
                            result["models"]["availableModels"]
                                .as_array()
                                .is_some_and(|models| models.iter().any(|v| v["modelId"] == model)),
                            "Antigravity did not advertise the selected model"
                        );
                        transport.write(&rpc(
                            4,
                            "session/set_model",
                            json!({"sessionId":session,"modelId":model}),
                        ))?;
                    }
                    stage = 4;
                } else {
                    set_safe_mode(&mut transport, &session, &setup)?;
                    stage = 5;
                }
            }
            4 => {
                if let Some(option) = option(result, "model") {
                    ensure!(
                        option["currentValue"].as_str() == launch.model.as_deref(),
                        "Antigravity did not confirm the selected model"
                    );
                }
                set_safe_mode(&mut transport, &session, &setup)?;
                stage = 5;
            }
            5 => {
                if let Some(option) = option(result, "mode") {
                    ensure!(
                        option["currentValue"] == "default",
                        "Antigravity did not confirm approval mode"
                    );
                }
                transport.write(&rpc(6,"session/prompt",json!({"sessionId":session,"prompt":prompt.take().context("Antigravity prompt was already sent")?})))?;
                stage = 6;
            }
            6 => {
                ensure!(
                    matches!(
                        result["stopReason"].as_str(),
                        Some("end_turn" | "max_tokens" | "max_turn_requests" | "refusal")
                    ),
                    "Antigravity turn did not complete"
                );
                completed = true;
            }
            _ => unreachable!(),
        }
    }
}
fn set_safe_mode(transport: &mut Transport, session: &Option<String>, setup: &Value) -> Result<()> {
    if let Some(option) = option(setup, "mode") {
        ensure!(
            offers(option, "default"),
            "Antigravity did not advertise approval mode"
        );
        transport.write(&rpc(
            5,
            "session/set_config_option",
            json!({"sessionId":session,"configId":option["id"],"value":"default"}),
        ))?;
    } else {
        ensure!(
            setup["modes"]["availableModes"]
                .as_array()
                .is_some_and(|modes| modes.iter().any(|v| v["id"] == "default")),
            "Antigravity did not advertise approval mode"
        );
        transport.write(&rpc(
            5,
            "session/set_mode",
            json!({"sessionId":session,"modeId":"default"}),
        ))?;
    }
    Ok(())
}
