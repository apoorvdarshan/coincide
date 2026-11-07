use anyhow::{Context, Result, bail};
use coincide_core::{api::Engine, control, store::Store};
use serde_json::{Value, json};
use std::{
    io::Read,
    path::PathBuf,
    sync::{Arc, Mutex},
};
fn main() -> Result<()> {
    let mut invocation =
        Invocation::parse(std::env::args().skip(1).collect()).unwrap_or_else(|error| {
            eprintln!("{error}");
            std::process::exit(2);
        });
    if invocation.send_stdin {
        invocation.args[2] = read_send_message(&mut std::io::stdin()).unwrap_or_else(|error| {
            eprintln!("{error}");
            std::process::exit(2);
        });
    }
    let mut args = invocation.args.clone();
    let cmd = args[0].clone();
    let cmd = cmd.as_str();
    if cmd == "help" {
        return help();
    }
    let raw_request = if cmd == "api" {
        Some(
            read_api_request(&mut std::io::stdin()).unwrap_or_else(|error| {
                eprintln!("{error}");
                std::process::exit(2);
            }),
        )
    } else {
        None
    };
    if cmd == "serve" {
        let data = control::data_directory()?;
        let socket = invocation
            .socket
            .clone()
            .unwrap_or_else(|| data.join("control.sock"));
        let engine = Arc::new(Mutex::new(Engine::new(Store::open(
            &data.join("coincide.sqlite"),
        )?)));
        let _server = control::serve(socket, engine.clone())?;
        loop {
            if engine
                .lock()
                .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
                .shutdown
            {
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
        return Ok(());
    }
    // Client overrides are explicit Rust-protocol endpoints. Never consult
    // the Swift socket environment or resolve unrelated default data here.
    let socket = match &invocation.socket {
        Some(path) => path.clone(),
        None => control::data_directory()?.join("control.sock"),
    };
    if cmd == "new" {
        let mut params = invocation
            .payload
            .context("Missing prepared new-thread options")?;
        if let Some(project) = &invocation.project {
            let response = control::request(
                &socket,
                &json!({"id":1,"method":"projects.list","params":{}}),
            )?;
            if response.get("error").is_some() {
                return output(response);
            }
            params["projectId"] = json!(project_id(project, &response["result"])?);
        }
        return output(control::request(
            &socket,
            &json!({"id":1,"method":"threads.create","params":params}),
        )?);
    }
    if matches!(
        cmd,
        "open"
            | "read"
            | "fork"
            | "send"
            | "stop"
            | "provider"
            | "pending"
            | "questions"
            | "answer"
            | "browser"
            | "draft"
            | "archive"
            | "restore"
            | "approve"
            | "decline"
            | "attach"
            | "detach"
            | "git-status"
            | "git-diff"
            | "files"
            | "file"
            | "wait"
    ) || (cmd == "status" && args.len() > 1)
    {
        args[1] = resolve_reference(
            &socket,
            &args[1],
            std::env::var("COINCIDE_THREAD_ID").ok().as_deref(),
        )?;
    }
    if cmd == "threads" {
        let mut threads = request_result(
            &socket,
            "threads.list",
            json!({"query":args.get(1).map(String::as_str).unwrap_or(""),"includeArchived":!invocation.active}),
        )?;
        let project = if invocation.chats {
            Some("00000000-0000-0000-0000-000000000000".to_owned())
        } else if let Some(name) = &invocation.project {
            Some(project_id(
                name,
                &request_result(&socket, "projects.list", json!({}))?,
            )?)
        } else {
            None
        };
        let status = if invocation.running {
            request_result(&socket, "app.status", json!({}))?
        } else {
            json!({})
        };
        let running = if invocation.running {
            Some(
                status["running"]
                    .as_array()
                    .context("Invalid running thread list")?,
            )
        } else {
            None
        };
        threads
            .as_array_mut()
            .context("Invalid thread list")?
            .retain(|thread| {
                project
                    .as_ref()
                    .is_none_or(|id| thread["project_id"].as_str() == Some(id.as_str()))
                    && running.is_none_or(|ids| ids.iter().any(|id| id == &thread["id"]))
            });
        return emit_result(threads);
    }
    if cmd == "read" {
        let mut params = json!({"threadId":args[1],"itemLimit":invocation.count});
        if let Some(offset) = invocation.offset {
            params["itemOffset"] = json!(offset);
        }
        return output(control::request(
            &socket,
            &json!({"id":1,"method":"threads.read","params":params}),
        )?);
    }
    if cmd == "questions" {
        let response = control::request(
            &socket,
            &json!({"id":1,"method":"agent.pending","params":{"threadId":args[1]}}),
        )?;
        if response.get("error").is_some() {
            return output(response);
        }
        let questions = response["result"]
            .as_array()
            .context("Invalid pending request list")?
            .iter()
            .filter(|request| request["method"] == "item/tool/requestUserInput")
            .cloned()
            .collect::<Vec<_>>();
        return emit_result(json!(questions));
    }
    if cmd == "wait" {
        return wait_for_thread(&socket, &args[1], invocation.timeout);
    }
    if cmd == "send" && invocation.wait {
        request_result(
            &socket,
            "agent.send",
            json!({"threadId":args[1],"text":args[2]}),
        )?;
        return wait_for_thread(&socket, &args[1], invocation.timeout);
    }
    if cmd == "status" && args.len() > 1 {
        let transcript = request_result(
            &socket,
            "threads.read",
            json!({"threadId":args[1],"itemLimit":100}),
        )?;
        let pending = request_result(&socket, "agent.pending", json!({"threadId":args[1]}))?;
        let status = request_result(&socket, "app.status", json!({}))?;
        let running = status["running"]
            .as_array()
            .context("Invalid running thread list")?
            .iter()
            .any(|id| id == &args[1]);
        return emit_result(
            json!({"threadID":args[1],"running":running,"pending":pending,"transcript":transcript}),
        );
    }
    let argument = |n: usize| {
        args.get(n)
            .cloned()
            .with_context(|| format!("Missing argument {n}"))
    };
    let (method, params) = match cmd {
        "quit" => ("app.quit", json!({})),
        "status" => ("app.status", json!({})),
        "capabilities" => ("app.capabilities", json!({})),
        "projects" => ("projects.list", json!({})),
        "agents" | "providers" => ("providers.list", json!({})),
        "attach" => {
            return operation(
                &socket,
                "attachments.add",
                json!({"threadId":argument(1)?,"path":argument(2)?}),
                "workspace.result",
            );
        }
        "detach" => (
            "attachments.remove",
            json!({"threadId":argument(1)?,"attachmentId":argument(2)?}),
        ),
        "git-status" | "git-diff" | "files" | "file" => {
            let mut params = json!({"threadId":argument(1)?});
            let method = match cmd {
                "git-status" => "git.status",
                "git-diff" => {
                    params["path"] = json!(args.get(2));
                    "git.diff"
                }
                "files" => {
                    params["query"] = json!(args.get(2));
                    "files.list"
                }
                _ => {
                    params["path"] = json!(argument(2)?);
                    params["lineOffset"] = json!(invocation.file_offset.unwrap_or(0));
                    "files.read"
                }
            };
            return operation(&socket, method, params, "workspace.result");
        }
        "threads" => (
            "threads.list",
            json!({"query":args.get(1).map(String::as_str).unwrap_or(""),"includeArchived":true}),
        ),
        "open" => ("threads.open", json!({"threadId":argument(1)?})),
        "read" => (
            "threads.read",
            json!({"threadId":argument(1)?,"itemLimit":100}),
        ),
        "fork" => ("threads.fork", json!({"threadId":argument(1)?})),
        "send" => (
            "agent.send",
            json!({"threadId":argument(1)?,"text":argument(2)?}),
        ),
        "stop" => ("agent.stop", json!({"threadId":argument(1)?})),
        "provider" => {
            let mut params = json!({"threadId":argument(1)?,"provider":argument(2)?});
            if let Some(model) = args.get(3) {
                params["model"] = json!(model);
            }
            ("agent.select", params)
        }
        "pending" => ("agent.pending", json!({"threadId":argument(1)?})),
        "answer" => (
            "agent.answer",
            json!({"threadId":argument(1)?,"requestId":argument(2)?,"answers":invocation.payload.clone().context("Missing prepared answers")?}),
        ),
        "browser" => {
            let thread = argument(1)?;
            let mut params = invocation
                .payload
                .clone()
                .context("Missing prepared browser action")?;
            params["threadId"] = json!(thread);
            let response = control::request(
                &socket,
                &json!({"id":1,"method":"browser.request","params":params}),
            )?;
            if response.get("error").is_some() {
                return output(response);
            }
            let operation = response["result"]["operationId"]
                .as_str()
                .context("Missing browser operation ID")?;
            // ask-user waits for the person; other actions answer within 30s.
            let limit = serde_json::from_value::<coincide_core::browser_protocol::BrowserAction>(
                params.clone(),
            )
            .map_or(std::time::Duration::from_secs(30), |action| {
                action.result_timeout()
            }) + std::time::Duration::from_secs(5);
            let started = std::time::Instant::now();
            loop {
                let response = control::request(
                    &socket,
                    &json!({"id":1,"method":"browser.result","params":{"threadId":thread,"operationId":operation}}),
                )?;
                if response.get("error").is_some() {
                    return output(response);
                }
                if response["result"]["ready"] == true {
                    let result = &response["result"]["result"];
                    if let Some(error) = result.get("error") {
                        return output(json!({"id":1,"error":{"message":error}}));
                    }
                    return output(json!({"id":1,"result":result}));
                }
                anyhow::ensure!(
                    started.elapsed() < limit,
                    "Browser result timed out; verify page state before retrying"
                );
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
        "draft" => (
            "threads.patch",
            json!({"threadId":argument(1)?,"patch":{"draft":argument(2)?}}),
        ),
        "archive" => (
            "threads.patch",
            json!({"threadId":argument(1)?,"patch":{"isArchived":true}}),
        ),
        "restore" => (
            "threads.patch",
            json!({"threadId":argument(1)?,"patch":{"isArchived":false}}),
        ),
        "approve" | "decline" => (
            "agent.respond",
            json!({"threadId":argument(1)?,"requestId":argument(2)?,"decision":if cmd=="approve"{"accept"}else{"decline"}}),
        ),
        "api" => {
            return output(control::request(
                &socket,
                raw_request
                    .as_ref()
                    .context("Missing prepared API request")?,
            )?);
        }
        _ => bail!("Unknown command; use coincide-rs help"),
    };
    output(control::request(
        &socket,
        &json!({"id":1,"method":method,"params":params}),
    )?)
}
fn help() -> Result<()> {
    println!(
        "Coincide Rust preview CLI (JSON output; --json accepted)\nGlobal: --json | --socket PATH | --socket=PATH (Rust protocol only); help aliases -h/--help\nstatus | capabilities | projects | agents | providers | threads [search] | read ID | open ID | quit\nagents (providers alias): catalog/discovery metadata; account authentication is not checked.\nnew [DIRECTORY | --chat | --project ID|NAME|PATH] [--agent PROVIDER_ID] [--model MODEL_ID] [--effort E] [--access full|approval] [--plan] [--title TITLE]\nnew creates an unsent thread only; MESSAGE/stdin, --wait, --open and queue delivery are unsupported.\nfork ID | send ID MESSAGE... | send ID - (UTF-8 stdin) | stop ID | draft ID TEXT\nattach ID ABSOLUTE_IMAGE_PATH | detach ID ATTACHMENT_ID\nprovider ID codex|claude [MODEL] | pending ID | answer ID REQUEST_ID ANSWERS_JSON\nbrowser ID ACTION_JSON (for example: '{{\"action\":\"read\"}}')\ngit-status ID | git-diff ID [PATH] | files ID [QUERY] | file ID PATH [LINE_OFFSET]\narchive ID | restore ID (alias unarchive) | approve ID REQUEST_ID | decline ID REQUEST_ID (alias deny)\nquestions ID  List authoritative pending user questions; opaque request IDs and fields are preserved\ndeny ID REQUEST_ID | deny ID --item REQUEST_ID (explicit Core request ID required)\napi  Read a JSON request from stdin\nserve  Run the engine without a GUI\nThread references: exact ID, unique ID prefix (4+ characters), exact title, or this (COINCIDE_THREAD_ID).\nthreads [search] [--project ID|NAME|PATH | --chats] [--running] [--active | --archived]\nread THREAD [--count 0..1000 | --count=N] [--offset N | --offset=N] | status [THREAD]\nwait THREAD [--timeout SECONDS] | send THREAD TEXT --wait [--timeout SECONDS]\nExit codes: 0 success/settled, 1 error, 2 usage, 3 needs input, 4 wait timed out.\nWait done means the turn settled; inspect the transcript for provider errors.\nCOINCIDE_RUST_DATA_DIR selects an isolated instance; default remains its control.sock.\nAn explicit --socket is used for all requests; COINCIDE_CONTROL_SOCKET is not inherited.\nUse -- before message words that start with options. Busy/alternate follow-up delivery is not connected."
    );
    Ok(())
}

fn operation(
    socket: &std::path::Path,
    method: &str,
    params: Value,
    result_method: &str,
) -> Result<()> {
    let thread = params["threadId"].clone();
    let reply = control::request(socket, &json!({"id":1,"method":method,"params":params}))?;
    if reply.get("error").is_some() {
        return output(reply);
    }
    let id = reply["result"]["operationId"]
        .as_str()
        .context("Missing operation ID")?;
    let started = std::time::Instant::now();
    loop {
        let reply = control::request(
            socket,
            &json!({"id":1,"method":result_method,"params":{"threadId":thread,"operationId":id}}),
        )?;
        if reply.get("error").is_some() {
            return output(reply);
        }
        if reply["result"]["ready"] == true {
            let result = &reply["result"]["result"];
            return output(if let Some(error) = result.get("error") {
                json!({"id":1,"error":{"message":error}})
            } else {
                json!({"id":1,"result":result})
            });
        }
        anyhow::ensure!(
            started.elapsed()
                < std::time::Duration::from_secs(if method == "attachments.add" {
                    125
                } else {
                    35
                }),
            "Operation timed out"
        );
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}
fn output(response: Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&response)?);
    if response.get("error").is_some() {
        std::process::exit(1);
    }
    Ok(())
}

#[derive(Debug)]
struct Invocation {
    args: Vec<String>,
    project: Option<String>,
    chats: bool,
    running: bool,
    active: bool,
    count: u64,
    offset: Option<u64>,
    wait: bool,
    timeout: std::time::Duration,
    payload: Option<Value>,
    file_offset: Option<u64>,
    socket: Option<PathBuf>,
    send_stdin: bool,
}
impl Invocation {
    fn parse(raw: Vec<String>) -> Result<Self> {
        let (raw, socket) = global_options(raw)?;
        let command = match raw.first().map(String::as_str).unwrap_or("help") {
            "-h" | "--help" => "help",
            "unarchive" => "restore",
            "deny" => "decline",
            command => command,
        };
        let (minimum, maximum) = match command {
            "help" | "serve" | "quit" | "capabilities" | "projects" | "agents" | "providers"
            | "api" => (0, 0),
            "status" | "threads" | "new" => (0, 1),
            "read" | "open" | "fork" | "stop" | "pending" | "questions" | "archive" | "restore"
            | "wait" | "git-status" => (1, 1),
            "git-diff" | "files" => (1, 2),
            "send" => (2, usize::MAX),
            "attach" | "detach" | "draft" | "approve" | "decline" | "browser" => (2, 2),
            "provider" => (2, 3),
            "answer" => (3, 3),
            "file" => (2, 3),
            _ => bail!("Unknown command; use coincide-rs help"),
        };
        let mut parsed = Self {
            args: vec![command.to_owned()],
            project: None,
            chats: false,
            running: false,
            active: false,
            count: 100,
            offset: None,
            wait: false,
            timeout: std::time::Duration::from_secs(1800),
            payload: None,
            file_offset: None,
            socket,
            send_stdin: false,
        };
        let mut args = raw.iter().skip(1);
        let mut literal = false;
        let mut seen = std::collections::HashSet::new();
        let mut request_id = None;
        let mut creation = json!({});
        while let Some(arg) = args.next() {
            if !literal && arg == "--" {
                literal = true;
                continue;
            }
            if !literal && arg.starts_with('-') && !(command == "send" && arg == "-") {
                let (option, inline) = arg
                    .split_once('=')
                    .filter(|(name, _)| {
                        matches!(
                            (command, *name),
                            ("read", "--count" | "--offset")
                                | ("decline", "--item")
                                | (
                                    "new",
                                    "--project"
                                        | "--agent"
                                        | "--model"
                                        | "--effort"
                                        | "--access"
                                        | "--title"
                                )
                        )
                    })
                    .map_or((arg.as_str(), None), |(name, value)| (name, Some(value)));
                anyhow::ensure!(seen.insert(option.to_owned()), "Duplicate option {option}");
                let value =
                    |args: &mut std::iter::Skip<std::slice::Iter<'_, String>>| -> Result<String> {
                        if let Some(value) = inline {
                            anyhow::ensure!(!value.is_empty(), "Missing value for {option}");
                            return Ok(value.to_owned());
                        }
                        args.next()
                            .filter(|v| !v.starts_with("--"))
                            .cloned()
                            .with_context(|| format!("Missing value for {option}"))
                    };
                match (command, option) {
                    ("threads" | "new", "--project") => parsed.project = Some(value(&mut args)?),
                    ("new", "--chat") => parsed.chats = true,
                    ("new", "--agent") => {
                        creation["selection"]["provider"] = json!(value(&mut args)?)
                    }
                    ("new", "--model") => {
                        creation["selection"]["modelID"] = json!(value(&mut args)?)
                    }
                    ("new", "--effort") => {
                        creation["selection"]["effort"] = json!(value(&mut args)?)
                    }
                    ("new", "--plan") => creation["interactionMode"] = json!("plan"),
                    ("new", "--title") => creation["title"] = json!(value(&mut args)?),
                    ("new", "--access") => {
                        creation["accessMode"] = json!(match value(&mut args)?.as_str() {
                            "full" | "fullAccess" => "fullAccess",
                            "approval" | "ask" => "approval",
                            _ => bail!("--access must be full, fullAccess, approval or ask"),
                        });
                    }
                    ("threads", "--chats") => parsed.chats = true,
                    ("threads", "--running") => parsed.running = true,
                    ("threads", "--active") => parsed.active = true,
                    ("threads", "--archived") => {}
                    ("read", "--count") => {
                        parsed.count = value(&mut args)?
                            .parse()
                            .context("Count must be an integer")?;
                        anyhow::ensure!(parsed.count <= 1000, "Count must be at most 1000");
                    }
                    ("read", "--offset") => {
                        parsed.offset = Some(
                            value(&mut args)?
                                .parse()
                                .context("Offset must be an integer")?,
                        )
                    }
                    ("decline", "--item") => request_id = Some(value(&mut args)?),
                    ("send", "--wait") => parsed.wait = true,
                    ("send" | "wait", "--timeout") => {
                        let seconds: f64 = value(&mut args)?
                            .parse()
                            .context("Timeout must be seconds")?;
                        anyhow::ensure!(
                            seconds.is_finite() && seconds > 0.0 && seconds <= 86400.0,
                            "Timeout must be greater than zero and at most 86400 seconds"
                        );
                        parsed.timeout = std::time::Duration::from_secs_f64(seconds.max(0.001));
                    }
                    _ => bail!("Unknown option {arg} for {command}"),
                }
            } else {
                parsed.args.push(arg.clone());
            }
        }
        if let Some(request_id) = request_id {
            anyhow::ensure!(
                parsed.args.len() == 2,
                "Use a positional request ID or --item, not both"
            );
            parsed.args.push(request_id);
        }
        let count = parsed.args.len() - 1;
        anyhow::ensure!(
            (minimum..=maximum).contains(&count),
            "Wrong argument count for {command}"
        );
        anyhow::ensure!(
            !(parsed.chats && parsed.project.is_some()),
            if command == "new" {
                "Use --chat or --project, not both"
            } else {
                "Use --chats or --project, not both"
            }
        );
        if command == "new" {
            anyhow::ensure!(
                parsed.args.len() == 1 || !(parsed.chats || parsed.project.is_some()),
                "DIRECTORY cannot be combined with --chat or --project; new does not send messages"
            );
            if let Some(cwd) = parsed.args.get(1) {
                creation["cwd"] = json!(cwd);
            }
            parsed.payload = Some(creation);
        }
        anyhow::ensure!(
            !(parsed.active && seen.contains("--archived")),
            "Use --active or --archived, not both"
        );
        anyhow::ensure!(
            !(command == "send" && seen.contains("--timeout") && !parsed.wait),
            "--timeout needs --wait on send"
        );
        if command == "send" {
            let words = &parsed.args[2..];
            parsed.send_stdin = words.len() == 1 && words[0] == "-";
            if !parsed.send_stdin {
                let length = words
                    .iter()
                    .try_fold(words.len() - 1, |total, word| total.checked_add(word.len()))
                    .context("Send message is too large")?;
                anyhow::ensure!(length <= MAX_SEND_MESSAGE, "Send message exceeds 1 MiB");
                let message = words.join(" ");
                validate_send_message(&message)?;
                parsed.args.truncate(2);
                parsed.args.push(message);
            }
        }
        if command == "file" {
            parsed.file_offset = parsed
                .args
                .get(3)
                .map(|offset| {
                    offset
                        .parse::<u64>()
                        .context("File offset must be an integer")
                })
                .transpose()?;
        }
        if matches!(command, "browser" | "answer") {
            let index = if command == "browser" { 2 } else { 3 };
            let payload: Value =
                serde_json::from_str(&parsed.args[index]).context("Invalid command JSON")?;
            if command == "browser" {
                anyhow::ensure!(payload.is_object(), "Browser action must be a JSON object");
            }
            parsed.payload = Some(payload);
        }
        Ok(parsed)
    }
}

/// Global flags are recognized anywhere before the literal delimiter. Socket
/// selection is explicit; ambient COINCIDE_CONTROL_SOCKET is never consulted.
fn global_options(raw: Vec<String>) -> Result<(Vec<String>, Option<PathBuf>)> {
    let mut words = Vec::new();
    let mut socket = None;
    let mut json = false;
    let mut args = raw.into_iter();
    while let Some(arg) = args.next() {
        if arg == "--" {
            words.push(arg);
            words.extend(args);
            break;
        }
        if arg == "--json" {
            anyhow::ensure!(!json, "Duplicate option --json");
            json = true;
        } else if arg == "--socket" || arg.starts_with("--socket=") {
            anyhow::ensure!(socket.is_none(), "Duplicate option --socket");
            let path = if let Some(path) = arg.strip_prefix("--socket=") {
                path.to_owned()
            } else {
                args.next()
                    .filter(|value| !value.starts_with("--"))
                    .context("Missing value for --socket")?
            };
            anyhow::ensure!(
                !path.is_empty() && !path.chars().any(char::is_control),
                "Invalid --socket path"
            );
            socket = Some(PathBuf::from(path));
        } else {
            words.push(arg);
        }
    }
    Ok((words, socket))
}
const MAX_SEND_MESSAGE: usize = 1024 * 1024;
fn validate_send_message(message: &str) -> Result<()> {
    anyhow::ensure!(
        message.len() <= MAX_SEND_MESSAGE,
        "Send message exceeds 1 MiB"
    );
    Ok(())
}
fn read_send_message(input: &mut impl Read) -> Result<String> {
    let mut body = String::new();
    input
        .take(MAX_SEND_MESSAGE as u64 + 1)
        .read_to_string(&mut body)
        .context("Send stdin must be UTF-8")?;
    validate_send_message(&body)?;
    Ok(body)
}

fn read_api_request(input: &mut impl Read) -> Result<Value> {
    let mut body = String::new();
    input.take(4 * 1024 * 1024 + 1).read_to_string(&mut body)?;
    anyhow::ensure!(body.len() <= 4 * 1024 * 1024, "API request exceeds 4 MiB");
    serde_json::from_str(&body).context("Invalid API request JSON")
}

fn request_result(socket: &std::path::Path, method: &str, params: Value) -> Result<Value> {
    let response = control::request(socket, &json!({"id":1,"method":method,"params":params}))?;
    if let Some(error) = response.get("error") {
        bail!("{method}: {}", error["message"]);
    }
    response
        .get("result")
        .cloned()
        .context("Control response has no result")
}
fn resolve_reference(
    socket: &std::path::Path,
    name: &str,
    current: Option<&str>,
) -> Result<String> {
    let target = if name == "this" {
        let current =
            current.context("this requires COINCIDE_THREAD_ID from the launching thread")?;
        uuid::Uuid::parse_str(current).context("COINCIDE_THREAD_ID must be a UUID")?;
        current
    } else {
        name
    };
    if let Ok(requested) = uuid::Uuid::parse_str(target) {
        // Resolve only a scalar ID: exact-ID operations must not depend on the
        // size of the full library or a thread's transcript/metadata document.
        let result = request_result(socket, "threads.resolve_id", json!({"threadId":target}))?;
        let fields = result
            .as_object()
            .context("Invalid resolved thread ID response")?;
        anyhow::ensure!(fields.len() == 1, "Invalid resolved thread ID response");
        let stored = fields
            .get("threadId")
            .and_then(Value::as_str)
            .context("Missing resolved thread ID")?;
        anyhow::ensure!(
            uuid::Uuid::parse_str(stored).context("Invalid resolved thread ID")? == requested,
            "Resolved thread ID does not match requested UUID"
        );
        return Ok(stored.to_owned());
    }
    let threads = request_result(socket, "threads.list", json!({"includeArchived":true}))?;
    resolve_named_thread(target, &threads)
}
fn resolve_named_thread(target: &str, threads: &Value) -> Result<String> {
    let entries = threads.as_array().context("Invalid thread list")?;
    let prefix = target.len() >= 4 && target.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-');
    let by_id: Vec<_> = entries
        .iter()
        .filter(|thread| {
            prefix
                && thread["id"].as_str().is_some_and(|id| {
                    id.to_ascii_lowercase()
                        .starts_with(&target.to_ascii_lowercase())
                })
        })
        .collect();
    let matches: Vec<_> = if by_id.is_empty() {
        entries
            .iter()
            .filter(|thread| thread["title"].as_str() == Some(target))
            .collect()
    } else {
        by_id
    };
    anyhow::ensure!(
        matches.len() == 1,
        "Thread reference is missing or ambiguous; use its exact ID"
    );
    Ok(matches[0]["id"]
        .as_str()
        .context("Thread has no ID")?
        .to_owned())
}
fn project_id(name: &str, projects: &Value) -> Result<String> {
    let matches: Vec<_> = projects
        .as_array()
        .context("Invalid project list")?
        .iter()
        .filter(|project| {
            project["id"]
                .as_str()
                .is_some_and(|id| id.eq_ignore_ascii_case(name))
                || project["name"].as_str() == Some(name)
                || project["path"].as_str() == Some(name)
        })
        .collect();
    anyhow::ensure!(
        matches.len() == 1,
        "Project reference is missing or ambiguous; use its exact ID"
    );
    Ok(matches[0]["id"]
        .as_str()
        .context("Project has no ID")?
        .to_owned())
}
fn emit_result(value: Value) -> Result<()> {
    output(json!({"id":1,"result":value}))
}
fn wait_for_thread(
    socket: &std::path::Path,
    thread: &str,
    timeout: std::time::Duration,
) -> Result<()> {
    let started = std::time::Instant::now();
    loop {
        request_result(
            socket,
            "threads.read",
            json!({"threadId":thread,"itemLimit":100}),
        )?;
        let pending = request_result(socket, "agent.pending", json!({"threadId":thread}))?;
        let status = request_result(socket, "app.status", json!({}))?;
        let pending = pending.as_array().context("Invalid pending request list")?;
        let running = status["running"]
            .as_array()
            .context("Invalid running thread list")?
            .iter()
            .any(|id| id.as_str() == Some(thread));
        let (state, code) = if !pending.is_empty() {
            ("needsInput", 3)
        } else if !running {
            ("done", 0)
        } else if started.elapsed() >= timeout {
            ("timedOut", 4)
        } else {
            std::thread::sleep(
                std::time::Duration::from_millis(100)
                    .min(timeout.saturating_sub(started.elapsed())),
            );
            continue;
        };
        // Each control request can advance the engine. Fetch the transcript
        // after the terminal-state observation so the emitted reply includes
        // completion/input that arrived during pending/status polling.
        let transcript = request_result(
            socket,
            "threads.read",
            json!({"threadId":thread,"itemLimit":100}),
        )?;
        emit_result(
            json!({"threadID":thread,"state":state,"transcript":transcript,"pending":pending,"running":running}),
        )?;
        if code != 0 {
            std::process::exit(code);
        }
        return Ok(());
    }
}
