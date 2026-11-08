//! OpenCode 2 HTTP/SSE adapter. Each turn owns its authenticated loopback server.
//! Existing account homes are reused; no global model or permission config is edited.
use super::{
    transport::{delta, event, isolate_environment, raw},
    *,
};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fmt,
    sync::{Arc, Mutex},
};
#[path = "provider_opencode_forms.rs"]
mod forms;
#[path = "provider_opencode_http.rs"]
mod http;
use http::{Http, segment};

#[derive(Debug)]
struct Stopped;
impl fmt::Display for Stopped {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "OpenCode turn stopped")
    }
}
impl std::error::Error for Stopped {}
#[derive(Debug)]
struct OperationTimedOut;
impl fmt::Display for OperationTimedOut {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "OpenCode operation timed out")
    }
}
impl std::error::Error for OperationTimedOut {}

struct Runtime<'a> {
    cancelled: Option<&'a dyn Fn() -> bool>,
    commands: Receiver<Control>,
    queued: VecDeque<Control>,
    events: &'a Sender<Event>,
    aborted_requests: Vec<thread::JoinHandle<()>>,
    owned_workers: Vec<thread::JoinHandle<()>>,
    #[cfg(test)]
    request_join_entered: Option<Sender<()>>,
}
impl Runtime<'_> {
    fn wait<T>(&mut self, receiver: Receiver<Result<T>>, limit: Duration) -> Result<T> {
        let deadline = Instant::now() + limit;
        loop {
            if self.cancelled.is_some_and(|allowed| !allowed()) {
                return Err(Stopped.into());
            }
            while let Ok(command) = self.commands.try_recv() {
                match command {
                    Control::Stop => return Err(Stopped.into()),
                    other => self.queued.push_back(other),
                }
            }
            if Instant::now() >= deadline {
                return Err(OperationTimedOut.into());
            }
            match receiver.recv_timeout(Duration::from_millis(10)) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => bail!("OpenCode worker disconnected"),
            }
        }
    }
    fn request(
        &mut self,
        http: &Http,
        method: &str,
        path: String,
        body: Option<Value>,
    ) -> Result<Value> {
        let http = http.clone();
        let method = method.to_owned();
        self.request_with_worker(Duration::from_secs(16), move || {
            http.request(&method, &path, body, Duration::from_secs(15))
        })
    }
    fn catalog(&mut self, http: &Http, path: &'static str, directory: &str) -> Result<Value> {
        let http = http.clone();
        let directory = directory.to_owned();
        self.request_with_worker(Duration::from_secs(11), move || {
            http.catalog(path, &directory, Duration::from_secs(10))
        })
    }
    /// Request result/Stop is semantic completion, not actual worker exit.
    /// Success joins here; aborted requests remain owned until Runtime Drop,
    /// after Server/OwnedChild has promptly terminated its process. All joins
    /// are on the background provider thread; UI/Engine remain nonblocking.
    /// SSE/stdout/stderr workers are separately retained until Runtime Drop.
    fn request_with_worker<T: Send + 'static>(
        &mut self,
        limit: Duration,
        work: impl FnOnce() -> Result<T> + Send + 'static,
    ) -> Result<T> {
        ensure!(
            self.aborted_requests.is_empty(),
            "OpenCode aborted HTTP request remains owned; stop this turn before further requests"
        );
        let (sender, receiver) = mpsc::sync_channel(1);
        let worker = thread::Builder::new()
            .name("coincide-opencode-request".into())
            .spawn(move || {
                let _ = sender.send(work());
            })
            .context("OpenCode HTTP request worker could not start")?;
        let result = self.wait(receiver, limit);
        if result
            .as_ref()
            .is_err_and(|error| error.is::<Stopped>() || error.is::<OperationTimedOut>())
        {
            // At most one aborted handle: no additional HTTP work is admitted
            // while ownership is retained. Let Server teardown run FIRST.
            self.aborted_requests.push(worker);
            return result;
        }
        // HTTP's deadline/result delivery does not prove thread/TLS exit.
        // Joined Returned is thread ownership, not a successful request.
        ensure!(
            self.join_request_worker(worker).is_ok(),
            "OpenCode HTTP request worker panicked"
        );
        result
    }
    fn join_request_worker(&mut self, worker: thread::JoinHandle<()>) -> thread::Result<()> {
        // Private test signal is at the actual owned-join entry, not an elapsed
        // absence assertion. Reverting to a detached request never enters it.
        #[cfg(test)]
        if let Some(observed) = self.request_join_entered.as_ref() {
            let _ = observed.send(());
        }
        worker.join()
    }
    fn spawn_owned(
        &mut self,
        name: &'static str,
        work: impl FnOnce() + Send + 'static,
    ) -> Result<()> {
        ensure!(
            self.owned_workers.len() < 3,
            "OpenCode I/O worker capacity reached"
        );
        let worker = thread::Builder::new()
            .name(name.into())
            .spawn(work)
            .context("OpenCode I/O worker could not start")?;
        self.owned_workers.push(worker);
        Ok(())
    }
    fn next_command(&mut self) -> Option<Control> {
        self.queued
            .pop_front()
            .or_else(|| self.commands.try_recv().ok())
    }
}

impl Drop for Runtime<'_> {
    fn drop(&mut self) {
        let mut panicked = false;
        for worker in std::mem::take(&mut self.aborted_requests) {
            panicked |= self.join_request_worker(worker).is_err();
        }
        for worker in std::mem::take(&mut self.owned_workers) {
            panicked |= self.join_request_worker(worker).is_err();
        }
        // A child panic cannot be silently converted into successful
        // provider teardown. During an existing unwind the parent is already
        // Panicked; avoid a double-panic process abort after all joins finish.
        assert!(
            !panicked || thread::panicking(),
            "OpenCode owned worker panicked during teardown"
        );
    }
}

#[path = "provider_opencode_metadata.rs"]
mod metadata;
pub(super) fn installation_metadata(
    executable: &std::path::Path,
    allowed: &impl Fn() -> bool,
) -> Result<(Vec<Value>, Option<String>)> {
    metadata::read(executable, allowed)
}

struct Server {
    child: OwnedChild,
    http: Http,
    cleanup: Option<(String, String)>,
}
impl Server {
    fn start(launch: &Launch, runtime: &mut Runtime<'_>) -> Result<Self> {
        let password = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let mut command = Command::new(&launch.executable);
        command
            .args(["serve", "--hostname=127.0.0.1", "--port=0"])
            .current_dir(&launch.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        crate::provider_configuration::apply_to_child(&mut command, false)?;
        isolate_environment(&mut command);
        command
            .env_remove("OPENCODE_SERVER_PASSWORD")
            .env("OPENCODE_PASSWORD", &password);
        let mut child = OwnedChild::spawn(&mut command)?;
        let output = child
            .0
            .stdout
            .take()
            .context("OpenCode stdout unavailable")?;
        let error = child
            .0
            .stderr
            .take()
            .context("OpenCode stderr unavailable")?;
        // Drain diagnostics without ever copying inherited credentials into a transcript.
        runtime.spawn_owned("coincide-opencode-stderr", move || {
            let _ = std::io::copy(&mut BufReader::new(error), &mut std::io::sink());
        })?;
        let (sender, receiver) = mpsc::sync_channel(1);
        runtime.spawn_owned("coincide-opencode-stdout", move || {
            let mut reader = BufReader::new(output);
            loop {
                let mut bytes = Vec::new();
                match std::io::Read::by_ref(&mut reader)
                    .take(8193)
                    .read_until(b'\n', &mut bytes)
                {
                    Ok(0) => {
                        let _ = sender.send(Err(anyhow::anyhow!(
                            "OpenCode exited before announcing a loopback server"
                        )));
                        return;
                    }
                    Ok(_) if bytes.len() <= 8192 => {}
                    _ => {
                        let _ = sender.send(Err(anyhow::anyhow!(
                            "OpenCode startup output exceeded its bound"
                        )));
                        return;
                    }
                }
                if let Some(url) = http::listening_url(&String::from_utf8_lossy(&bytes)) {
                    if sender.send(Ok(url)).is_ok() {
                        // Diagnostics after startup may contain arbitrarily long
                        // lines; drain them without allocating or closing stdout.
                        let _ = std::io::copy(&mut reader, &mut std::io::sink());
                    }
                    return;
                }
            }
        })?;
        let url = runtime.wait(receiver, Duration::from_secs(30))?;
        let http = Http::new(url, &password);
        let info = runtime.request(&http, "GET", "/api/info".into(), None)?;
        ensure!(
            info["version"].is_string() && info["pid"].as_u64() == Some(child.0.id() as u64),
            "The listening endpoint is not this OpenCode 2 server"
        );
        Ok(Self {
            child,
            http,
            cleanup: None,
        })
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        if let Some((session, prompt)) = &self.cleanup {
            // Withdraw queued work before stopping its execution so reopening the
            // persistent session cannot unexpectedly run a cancelled prompt.
            let root = format!("/api/session/{}", segment(session));
            let _ = self.http.request(
                "DELETE",
                &format!("{root}/inbox/{}", segment(prompt)),
                None,
                Duration::from_millis(500),
            );
            let _ = self.http.request(
                "POST",
                &format!("{root}/interrupt"),
                None,
                Duration::from_millis(500),
            );
        }
        #[cfg(unix)]
        unsafe {
            libc::kill(self.child.0.id() as i32, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_millis(150);
        while Instant::now() < deadline {
            if super::metadata_capture::exited(&self.child)
                .ok()
                .flatten()
                .is_some()
            {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        // OwnedChild kills/reaps its process group if graceful termination failed.
    }
}

enum PendingKind {
    Permission,
    Form(forms::Form),
}
struct Pending {
    session: String,
    native_id: String,
    kind: PendingKind,
}
struct Mapper {
    session: String,
    prompt: String,
    delivered: bool,
    started: bool,
    children: HashSet<String>,
    pending: HashMap<String, Pending>,
    tools: HashMap<String, Value>,
}
impl Mapper {
    fn owns(&self, id: &str) -> bool {
        id == self.session || self.children.contains(id)
    }
    fn handle(
        &mut self,
        frame: &Value,
        events: &Sender<Event>,
        declined: &mut Vec<(String, String)>,
    ) -> Result<bool> {
        let kind = frame["type"].as_str().unwrap_or("");
        let data = &frame["data"];
        let session = data["sessionID"].as_str().unwrap_or("");
        if kind == "session.created" {
            if data["parentID"].as_str().is_some_and(|id| self.owns(id)) && !session.is_empty() {
                self.children.insert(session.into());
            }
            return Ok(false);
        }
        if kind == "permission.asked" && self.owns(session) {
            let id = data["id"]
                .as_str()
                .context("OpenCode permission has no ID")?;
            let key = format!("opencode:permission:{session}:{id}");
            if !self.pending.contains_key(&key) {
                self.pending.insert(
                    key.clone(),
                    Pending {
                        session: session.into(),
                        native_id: id.into(),
                        kind: PendingKind::Permission,
                    },
                );
                events.send(Event::Frame(json!({"id":key,"method":"item/commandExecution/requestApproval","params":{"availableDecisions":["accept","decline","cancel"],"toolCall":data,"providerFrame":frame}})))?;
            }
            return Ok(false);
        }
        if kind == "form.created" {
            let form = &data["form"];
            let session = form["sessionID"].as_str().unwrap_or("");
            if self.owns(session) {
                let id = form["id"].as_str().context("OpenCode form has no ID")?;
                let key = format!("opencode:form:{session}:{id}");
                if !self.pending.contains_key(&key) {
                    match forms::Form::parse(form) {
                        Ok(parsed) => {
                            let params =
                                json!({"questions":parsed.questions,"providerFrame":frame});
                            self.pending.insert(
                                key.clone(),
                                Pending {
                                    session: session.into(),
                                    native_id: id.into(),
                                    kind: PendingKind::Form(parsed),
                                },
                            );
                            events.send(Event::Frame(json!({"id":key,"method":"item/tool/requestUserInput","params":params})))?;
                        }
                        Err(_) => declined.push((session.into(), id.into())),
                    }
                }
            }
            return Ok(false);
        }
        if matches!(
            kind,
            "permission.replied" | "form.replied" | "form.cancelled"
        ) {
            // Only settle a known request for its own session, never an unrelated
            // client's colliding request ID on the server-wide event stream.
            let id = if kind == "permission.replied" {
                data["requestID"].as_str()
            } else {
                data["id"].as_str()
            };
            let keys = self
                .pending
                .iter()
                .filter(|(_, pending)| {
                    Some(pending.native_id.as_str()) == id && pending.session == session
                })
                .map(|(key, _)| key.clone())
                .collect::<Vec<_>>();
            for key in keys {
                self.pending.remove(&key);
                event(events, "provider/requestCancelled", json!({"id":key}))?;
            }
            return Ok(false);
        }
        if session != self.session {
            return Ok(false);
        }
        match kind {
            "session.inbox.delivered" => {
                if data["inboxID"] == self.prompt {
                    self.delivered = true;
                }
            }
            "session.execution.started" => self.started = true,
            "session.execution.succeeded" if self.delivered || self.started => return Ok(true),
            "session.execution.interrupted" if self.delivered || self.started => {
                bail!("OpenCode interrupted the turn before completion")
            }
            "session.execution.failed" if self.delivered || self.started => bail!(
                "OpenCode turn failed: {}",
                data["error"]["message"]
                    .as_str()
                    .unwrap_or("provider error")
            ),
            "session.deleted" => bail!("OpenCode session was deleted during the turn"),
            "session.text.delta"
            | "session.reasoning.delta"
            | "session.text.ended"
            | "session.reasoning.ended" => {
                if let (Some(message), Some(ordinal)) = (
                    data["assistantMessageID"].as_str(),
                    data["ordinal"].as_u64(),
                ) {
                    let reasoning = kind.contains("reasoning");
                    let id = format!(
                        "{message}:{}:{ordinal}",
                        if reasoning { "reasoning" } else { "text" }
                    );
                    if kind.ends_with("delta") {
                        delta(events, &id, data["delta"].as_str().unwrap_or(""), reasoning)?;
                    } else {
                        event(
                            events,
                            "item/completed",
                            json!({"item":{"id":id,"type":if reasoning {"reasoning"}else{"agentMessage"},"text":data["text"].as_str().unwrap_or("")},"providerFrame":frame}),
                        )?;
                    }
                }
            }
            "session.tool.input.started"
            | "session.tool.called"
            | "session.tool.progress"
            | "session.tool.success"
            | "session.tool.failed" => {
                if let Some(id) = data["id"].as_str() {
                    let tool = self
                        .tools
                        .entry(id.into())
                        .or_insert_with(|| json!({"id":id,"type":"toolCall"}));
                    if let Some(values) = data.as_object() {
                        for (key, value) in values {
                            tool[key] = value.clone();
                        }
                    }
                    let completed = kind.ends_with("success") || kind.ends_with("failed");
                    tool["status"] = json!(if kind.ends_with("failed") {
                        "failed"
                    } else if completed {
                        "completed"
                    } else {
                        "running"
                    });
                    if let Some(child) = data["metadata"]["sessionID"].as_str() {
                        self.children.insert(child.into());
                    }
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
        Ok(false)
    }
}

fn model(value: Option<&str>, variant: Option<&str>) -> Result<Option<Value>> {
    let Some(value) = value.filter(|value| !value.is_empty() && *value != "default") else {
        return Ok(None);
    };
    let (provider, id) = value
        .split_once('/')
        .filter(|(provider, id)| !provider.is_empty() && !id.is_empty())
        .context("OpenCode model must use provider/model format")?;
    let mut model = json!({"providerID":provider,"id":id});
    if let Some(variant) = variant.filter(|variant| !variant.is_empty()) {
        model["variant"] = json!(variant);
    }
    Ok(Some(model))
}
fn permissions(full_access: bool) -> Value {
    let effect = if full_access { "allow" } else { "ask" };
    json!([{"action":"shell","resource":"*","effect":effect},{"action":"edit","resource":"*","effect":effect},{"action":"external_directory","resource":"*","effect":effect}])
}

pub(super) fn run(
    launch: Launch,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    let result = run_inner(launch, images, commands, events);
    match result {
        Err(error) if error.is::<Stopped>() => {
            events.send(Event::Finished)?;
            Ok(())
        }
        result => result,
    }
}
fn run_inner(
    launch: Launch,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    let model = model(launch.model.as_deref(), launch.variant.as_deref())?;
    // Declaration order is ownership-critical: Server (or its local child on
    // startup error) is destroyed BEFORE Runtime joins aborted HTTP workers.
    let mut runtime = Runtime {
        cancelled: None,
        commands,
        queued: VecDeque::new(),
        events,
        aborted_requests: Vec::new(),
        owned_workers: Vec::new(),
        #[cfg(test)]
        request_join_entered: None,
    };
    let mut server = Server::start(&launch, &mut runtime)?;
    let (stream_tx, stream_rx) = mpsc::sync_channel(64);
    let heartbeat = Arc::new(Mutex::new(Instant::now()));
    let http = server.http.clone();
    let clock = heartbeat.clone();
    // stream_rx is declared after Server: disconnect bounded sends first,
    // terminate/reap the owned server next, then join all I/O (including TLS).
    // A blocked HTTP read that does not unblock keeps ownership Running.
    runtime.spawn_owned("coincide-opencode-sse", move || {
        http.stream(stream_tx, clock)
    })?;
    let connected = Instant::now();
    loop {
        while let Ok(command) = runtime.commands.try_recv() {
            match command {
                Control::Stop => return Err(Stopped.into()),
                other => runtime.queued.push_back(other),
            }
        }
        ensure!(
            connected.elapsed() < Duration::from_secs(10),
            "OpenCode event stream did not connect"
        );
        match stream_rx.recv_timeout(Duration::from_millis(10)) {
            Ok(Ok(frame)) if frame["type"] == "server.connected" => break,
            Ok(Ok(_)) => {}
            Ok(Err(error)) => return Err(error),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => bail!("OpenCode stream disconnected"),
        }
    }
    let session = if let Some(id) = &launch.session {
        let root = format!("/api/session/{}", segment(id));
        let session = runtime.request(&server.http, "GET", root.clone(), None)?;
        ensure!(
            session["data"]["id"].as_str() == Some(id),
            "OpenCode did not return the requested native session; no replacement was created"
        );
        let directory = session["data"]["location"]["directory"]
            .as_str()
            .context("OpenCode session directory is missing")?;
        ensure!(
            std::fs::canonicalize(directory)? == std::fs::canonicalize(&launch.cwd)?,
            "OpenCode session belongs to a different directory; no session was moved"
        );
        let active = runtime.request(&server.http, "GET", "/api/session/active".into(), None)?;
        ensure!(
            active["data"]
                .as_object()
                .is_some_and(|data| !data.contains_key(id)),
            "OpenCode session is already active or its state is unknown"
        );
        for kind in ["permission", "form"] {
            let pending = runtime.request(&server.http, "GET", format!("{root}/{kind}"), None)?;
            ensure!(
                pending["data"].as_array().is_some_and(Vec::is_empty),
                "OpenCode session has pending requests from another run; resolve them in its existing client first"
            );
        }
        runtime.request(
            &server.http,
            "PATCH",
            root.clone(),
            Some(json!({"permissions":permissions(launch.full_access)})),
        )?;
        if session["data"]["agent"] != "build" {
            runtime.request(
                &server.http,
                "POST",
                format!("{root}/agent"),
                Some(json!({"agent":"build"})),
            )?;
        }
        if let Some(model) = &model {
            runtime.request(
                &server.http,
                "POST",
                format!("{root}/model"),
                Some(json!({"model":model})),
            )?;
        }
        id.clone()
    } else {
        let mut body = json!({"location":{"directory":launch.cwd},"agent":"build","permissions":permissions(launch.full_access)});
        if let Some(model) = model {
            body["model"] = model;
        }
        let response = runtime.request(&server.http, "POST", "/api/session".into(), Some(body))?;
        response["data"]["id"]
            .as_str()
            .filter(|id| !id.is_empty())
            .context("OpenCode did not create a native session")?
            .to_owned()
    };
    events.send(Event::Session(session.clone()))?;
    let prompt = format!("msg_coincide_{}", uuid::Uuid::new_v4().simple());
    let mut text = launch.prompt;
    let mut files = Vec::new();
    for image in &images {
        let path = image.path();
        let uri = url::Url::from_file_path(path)
            .map_err(|_| anyhow::anyhow!("OpenCode image path is not a local file"))?;
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .context("OpenCode image filename is not UTF-8")?;
        if !text.is_empty() {
            text.push_str("\n\n");
        }
        text.push_str(&format!(
            "[Attached image {name:?} is saved at: {}]",
            path.display()
        ));
        files.push(json!({"uri":uri.as_str(),"name":name}));
    }
    let mut body = json!({"id":prompt,"text":text});
    if !files.is_empty() {
        body["files"] = json!(files);
    }
    server.cleanup = Some((session.clone(), prompt.clone()));
    let root = format!("/api/session/{}", segment(&session));
    let mut mapper = Mapper {
        session: session.clone(),
        prompt,
        delivered: false,
        started: false,
        children: HashSet::new(),
        pending: HashMap::new(),
        tools: HashMap::new(),
    };
    runtime.request(&server.http, "POST", format!("{root}/prompt"), Some(body))?;
    loop {
        while let Some(command) = runtime.next_command() {
            match command {
                Control::Stop => return Err(Stopped.into()),
                Control::Reply { id, result } => {
                    let key = id.as_str().unwrap_or("");
                    let response = (|| -> Result<(String, String, Option<Value>)> {
                        let pending = mapper
                            .pending
                            .get(key)
                            .context("OpenCode request is no longer pending")?;
                        let root = format!("/api/session/{}", segment(&pending.session));
                        let request = segment(&pending.native_id);
                        match &pending.kind {
                            PendingKind::Permission => {
                                let body = match result["decision"].as_str() {
                                    Some("accept") => json!({"decision":"once"}),
                                    Some("decline") => {
                                        json!({"decision":"reject","message":"The user declined this request. Do not retry it; continue without it or ask how to proceed."})
                                    }
                                    Some("cancel") => json!({"decision":"reject"}),
                                    _ => bail!("Expected accept, decline or cancel"),
                                };
                                Ok((
                                    "POST".into(),
                                    format!("{root}/permission/{request}/reply"),
                                    Some(body),
                                ))
                            }
                            PendingKind::Form(form) => {
                                if result["decision"] == "cancel" {
                                    Ok(("DELETE".into(), format!("{root}/form/{request}"), None))
                                } else {
                                    Ok((
                                        "POST".into(),
                                        format!("{root}/form/{request}/reply"),
                                        Some(form.answer(&result)?),
                                    ))
                                }
                            }
                        }
                    })();
                    match response {
                        Ok((method, path, body)) => {
                            match runtime.request(&server.http, &method, path, body) {
                                Ok(_) => {
                                    mapper.pending.remove(key);
                                }
                                Err(error) if error.is::<Stopped>() => return Err(error),
                                Err(error) => event(
                                    events,
                                    "provider/requestRejected",
                                    json!({"id":id,"message":error.to_string()}),
                                )?,
                            }
                        }
                        Err(error) => event(
                            events,
                            "provider/requestRejected",
                            json!({"id":id,"message":error.to_string()}),
                        )?,
                    }
                }
            }
        }
        ensure!(
            heartbeat
                .lock()
                .map_err(|_| anyhow::anyhow!("OpenCode stream clock failed"))?
                .elapsed()
                < Duration::from_secs(45),
            "OpenCode event stream went silent; turn completion is unknown"
        );
        let frame = match stream_rx.recv_timeout(Duration::from_millis(10)) {
            Ok(result) => result?,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(_) => bail!("OpenCode event stream disconnected"),
        };
        raw(runtime.events, "opencode", &frame)?;
        let mut declined = Vec::new();
        if mapper.handle(&frame, events, &mut declined)? {
            server.cleanup = None;
            events.send(Event::Finished)?;
            return Ok(());
        }
        for (session, id) in declined {
            runtime.request(
                &server.http,
                "DELETE",
                format!("/api/session/{}/form/{}", segment(&session), segment(&id)),
                None,
            )?;
            event(
                events,
                "provider/notice",
                json!({"message":"OpenCode sent an unsupported form; it was cancelled without submitting answers."}),
            )?;
        }
    }
}

#[cfg(test)]
#[path = "provider_opencode_request_tests.rs"]
mod request_owner_tests;

#[cfg(test)]
mod model_reference_tests {
    use super::model;
    use serde_json::json;
    #[test]
    fn reasoning_variant_is_carried_in_the_model_reference() {
        assert_eq!(
            model(Some("opencode/deepseek-v4.1-flash"), Some("max")).unwrap(),
            Some(json!({"providerID":"opencode","id":"deepseek-v4.1-flash","variant":"max"}))
        );
        assert_eq!(
            model(Some("opencode/deepseek-v4.1-flash"), None).unwrap(),
            Some(json!({"providerID":"opencode","id":"deepseek-v4.1-flash"}))
        );
        assert!(model(Some("default"), Some("high")).unwrap().is_none());
        assert!(model(Some("no-slash"), Some("high")).is_err());
    }
    #[test]
    fn full_access_turns_permission_prompts_into_allows() {
        for action in ["shell", "edit", "external_directory"] {
            let allowed = super::permissions(true);
            let row = allowed
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["action"] == action)
                .unwrap();
            assert_eq!(row["effect"], "allow");
            let asked = super::permissions(false);
            let row = asked
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["action"] == action)
                .unwrap();
            assert_eq!(row["effect"], "ask");
        }
    }
}
