use anyhow::{Context, Result, bail};
use coincide_core::{api::Engine, control, store::Store};
use serde_json::{Value, json};
use std::{
    io::Read,
    sync::{Arc, Mutex},
};
fn main() -> Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let cmd = args.first().map(String::as_str).unwrap_or("help");
    let data = control::data_directory()?;
    if cmd == "serve" {
        let engine = Arc::new(Mutex::new(Engine::new(Store::open(
            &data.join("coincide.sqlite"),
        )?)));
        let _server = control::serve(data.join("control.sock"), engine.clone())?;
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
        "threads" => (
            "threads.list",
            json!({"query":args.get(1).map(String::as_str).unwrap_or(""),"includeArchived":true}),
        ),
        "open" => ("threads.open", json!({"threadId":argument(1)?})),
        "read" => (
            "threads.read",
            json!({"threadId":argument(1)?,"itemLimit":100}),
        ),
        "new" => ("threads.create", json!({"cwd":argument(1)?})),
        "fork" => ("threads.fork", json!({"threadId":argument(1)?})),
        "send" => (
            "agent.send",
            json!({"threadId":argument(1)?,"text":argument(2)?}),
        ),
        "stop" => ("agent.stop", json!({"threadId":argument(1)?})),
        "provider" => (
            "agent.select",
            json!({"threadId":argument(1)?,"provider":argument(2)?,"model":args.get(3)}),
        ),
        "pending" => ("agent.pending", json!({"threadId":argument(1)?})),
        "answer" => (
            "agent.answer",
            json!({"threadId":argument(1)?,"requestId":argument(2)?,"answers":serde_json::from_str::<Value>(&argument(3)?)?}),
        ),
        "browser" => {
            let thread = argument(1)?;
            let mut params: Value = serde_json::from_str(&argument(2)?)?;
            anyhow::ensure!(params.is_object(), "Browser action must be a JSON object");
            params["threadId"] = json!(thread);
            let socket = data.join("control.sock");
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
                    started.elapsed() < std::time::Duration::from_secs(35),
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
            let mut body = String::new();
            std::io::stdin()
                .take(4 * 1024 * 1024 + 1)
                .read_to_string(&mut body)?;
            let request: Value = serde_json::from_str(&body)?;
            return output(control::request(&data.join("control.sock"), &request)?);
        }
        "help" => {
            println!(
                "Coincide Rust preview CLI (JSON output)\nstatus | capabilities | projects | threads [search] | read ID | open ID | quit\nnew DIRECTORY | fork ID | send ID TEXT | stop ID | draft ID TEXT\nprovider ID codex|claude [MODEL] | pending ID | answer ID REQUEST_ID ANSWERS_JSON\nbrowser ID ACTION_JSON (for example: '{{\"action\":\"read\"}}')\narchive ID | restore ID | approve ID REQUEST_ID | decline ID REQUEST_ID\napi  Read a JSON request from stdin\nserve  Run the engine without a GUI\nCOINCIDE_RUST_DATA_DIR selects an isolated instance."
            );
            return Ok(());
        }
        _ => bail!("Unknown command; use coincide-rs help"),
    };
    output(control::request(
        &data.join("control.sock"),
        &json!({"id":1,"method":method,"params":params}),
    )?)
}
fn output(response: Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&response)?);
    if response.get("error").is_some() {
        std::process::exit(1);
    }
    Ok(())
}
