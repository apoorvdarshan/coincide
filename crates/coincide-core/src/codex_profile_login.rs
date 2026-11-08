//! Explicit subscription enrollment. The normal provider transport owns the
//! child, bounded pipes, cancellation, reap and joins; auth-file/token bytes
//! never pass through Engine or the native panel. The device challenge is ephemeral.
use super::*;
use crate::codex_login_profiles::LaunchContext;

const LOGIN_DEADLINE: Duration = Duration::from_secs(300);
const CANCEL_DEADLINE: Duration = Duration::from_secs(2);

pub(crate) struct Operation {
    id: String,
    account: String,
    session: Session,
    state: &'static str,
    terminal: Option<&'static str>,
    url: Option<String>,
    user_code: Option<String>,
    message: String,
    cancelled: bool,
    cancel_acknowledged: bool,
    returned: bool,
}
impl Operation {
    pub(crate) fn start(profile: LaunchContext) -> Self {
        let account = profile.account().to_owned();
        let configuration = crate::provider_configuration::current();
        let session = Session::spawn_worker(move |commands, events| {
            let _configuration_scope = crate::provider_configuration::enter(configuration);
            // run returns only after Transport drops, reaps its owned child,
            // disconnects queues and joins all its pipe workers.
            match run(profile, commands, events) {
                Ok(cancelled) => {
                    let _ = events.send(Event::Frame(json!({
                        "state":if cancelled.is_some(){"cancelled"}else{"authenticated"},
                        "cancelAcknowledged":cancelled.unwrap_or(false)
                    })));
                    let _ = events.send(Event::Finished);
                }
                Err(error) => {
                    let _ = events.send(Event::Failed(error.to_string()));
                }
            }
        });
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            account,
            session,
            state: "starting",
            terminal: None,
            url: None,
            user_code: None,
            message: "Starting isolated Codex sign-in…".into(),
            cancelled: false,
            cancel_acknowledged: false,
            returned: false,
        }
    }
    pub(crate) fn account(&self) -> &str {
        &self.account
    }
    pub(crate) fn completion(&self) -> WorkerCompletion {
        self.session.worker_completion()
    }
    pub(crate) fn active(&self) -> bool {
        self.completion().status() != WorkerThreadStatus::Returned
    }
    pub(crate) fn matches(&self, id: &str, account: &str) -> bool {
        self.id == id && self.account == account
    }
    pub(crate) fn cancel(&mut self) {
        if !self.active() {
            return;
        }
        self.cancelled = true;
        self.state = "stopping";
        self.url = None;
        self.user_code = None;
        self.message = "Stopping sign-in and waiting for the owned Codex process…".into();
        self.session.stop();
    }
    pub(crate) fn poll(&mut self) -> bool {
        let before = self.status();
        for event in self.session.events.try_iter().take(16) {
            match event {
                Event::Frame(frame) => match frame["state"].as_str() {
                    Some("waiting") if !self.cancelled => {
                        self.state = "waiting";
                        self.url = frame["verificationUrl"].as_str().map(str::to_owned);
                        self.user_code = frame["userCode"].as_str().map(str::to_owned);
                        self.message = "Open the device sign-in page, sign in to your existing account and enter this one-time code. This profile has not been authenticated yet.".into();
                    }
                    Some("checking") if !self.cancelled => {
                        self.state = "checking";
                        self.url = None;
                        self.user_code = None;
                        self.message = "Sign-in returned; checking authentication and closing the owned process…".into();
                    }
                    Some("authenticated" | "cancelled") => {
                        self.terminal = Some(if self.cancelled {
                            "cancelled"
                        } else if frame["state"] == "authenticated" {
                            "authenticated"
                        } else {
                            "cancelled"
                        });
                        self.cancel_acknowledged = frame["cancelAcknowledged"] == true;
                    }
                    _ => {}
                },
                Event::Failed(error) => {
                    self.terminal = Some(if self.cancelled {
                        "cancelled"
                    } else {
                        "failed"
                    });
                    self.message = error;
                }
                _ => {}
            }
        }
        match self.completion().status() {
            WorkerThreadStatus::Returned => {
                self.returned = true;
                self.url = None;
                self.user_code = None;
                self.state = self.terminal.unwrap_or("failed");
                match self.state {
                    "authenticated" => self.message = "Codex confirmed a ChatGPT subscription in this isolated profile. Display identity is unverified; authentication is checked again before every turn.".into(),
                    "cancelled" => self.message = "Sign-in worker stopped. A browser sign-in that already completed may remain in this isolated profile; sending always checks authentication again.".into(),
                    _ if self.terminal.is_none() => self.message = "Sign-in ended without a verified authentication result.".into(),
                    _ => {}
                }
            }
            WorkerThreadStatus::Running if self.terminal.is_some() => {
                self.state = "finishing";
                self.url = None;
                self.user_code = None;
            }
            WorkerThreadStatus::Panicked | WorkerThreadStatus::Unclassified => {
                self.state = "failed";
                self.url = None;
                self.user_code = None;
                self.message =
                    "Sign-in worker cleanup could not be confirmed. New sign-in is blocked.".into();
            }
            _ => {}
        }
        before != self.status()
    }
    pub(crate) fn status(&self) -> Value {
        json!({"operationId":self.id,"accountId":self.account,"state":self.state,
            "verificationUrl":self.url,"userCode":self.user_code,"message":self.message,"cancelAcknowledged":self.cancel_acknowledged,
            "workerReturned":self.returned,
            "accountIdentityVerified":false})
    }
}

fn device_url(raw: &str) -> Result<String> {
    ensure!(raw.len() <= 8192, "Codex sign-in URL exceeds its limit");
    let url = url::Url::parse(raw).context("Codex returned an invalid sign-in URL")?;
    ensure!(
        url.scheme() == "https"
            && url.host_str() == Some("auth.openai.com")
            && url.port().is_none_or(|port| port == 443)
            && url.username().is_empty()
            && url.password().is_none()
            && url.fragment().is_none()
            && url.query().is_none()
            && url.path() == "/codex/device",
        "Codex returned an unsupported sign-in destination"
    );
    Ok(url.into())
}

fn run(
    profile: LaunchContext,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<Option<bool>> {
    if commands
        .try_iter()
        .any(|command| matches!(command, Control::Stop))
    {
        return Ok(Some(false));
    }
    profile.validate()?;
    let launch = Launch {
        executable: profile.executable().into(),
        cwd: profile.home().into(),
        session: None,
        prompt: String::new(),
        model: None,
        variant: None,
        full_access: false,
    };
    let mut transport = transport::Transport::spawn_codex_profile(&launch, &profile)?;
    transport.write(&request(1,"initialize",json!({"clientInfo":{"name":"coincide","title":"Coincide","version":env!("CARGO_PKG_VERSION")}})))?;
    let deadline = Instant::now() + LOGIN_DEADLINE;
    let mut stage = 0;
    let mut login_id: Option<String> = None;
    loop {
        if commands
            .try_iter()
            .any(|command| matches!(command, Control::Stop))
        {
            let acknowledged = if let Some(id) = &login_id {
                cancel(&mut transport, id)
            } else {
                false
            };
            return Ok(Some(acknowledged));
        }
        ensure!(
            Instant::now() < deadline,
            "Codex sign-in timed out; start a new sign-in explicitly"
        );
        let Some(frame) = transport.next()? else {
            continue;
        };
        if frame.get("id").is_some() && frame.get("error").is_some() {
            bail!("Codex rejected the sign-in request; check the configured CLI and try again");
        }
        match (stage, frame["id"].as_u64()) {
            (0, Some(1)) if frame["result"].is_object() => {
                profile.validate()?;
                transport.write(&json!({"method":"initialized"}))?;
                transport.write(&request(
                    2,
                    "account/login/start",
                    // Device login never binds the shared 1455 callback port.
                    // Classic upstream login may cancel an existing listener.
                    json!({"type":"chatgptDeviceCode"}),
                ))?;
                stage = 1;
            }
            (1, Some(2)) => {
                ensure!(
                    frame["result"]["type"] == "chatgptDeviceCode",
                    "Codex returned another sign-in method"
                );
                let id = frame["result"]["loginId"]
                    .as_str()
                    .context("Codex returned no sign-in identity")?;
                crate::codex_login_profiles::canonical_id(id)?;
                let url = device_url(
                    frame["result"]["verificationUrl"]
                        .as_str()
                        .context("Codex returned no sign-in page")?,
                )?;
                let code = frame["result"]["userCode"]
                    .as_str()
                    .context("Codex returned no device code")?;
                ensure!(
                    (4..=64).contains(&code.len())
                        && code
                            .bytes()
                            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'),
                    "Codex returned an invalid device code"
                );
                login_id = Some(id.into());
                events.send(Event::Frame(
                    json!({"state":"waiting","verificationUrl":url,"userCode":code}),
                ))?;
                stage = 2;
            }
            (3, Some(3)) => {
                profile.admit_account(&frame["result"])?;
                return Ok(None);
            }
            (_, Some(_)) => bail!("Codex returned an out-of-order sign-in response"),
            _ if frame["method"] == "account/login/completed" => {
                ensure!(
                    stage == 2 && frame["params"]["loginId"].as_str() == login_id.as_deref(),
                    "Codex returned another sign-in completion"
                );
                ensure!(
                    frame["params"]["success"] == true && frame["params"]["error"].is_null(),
                    "Codex sign-in was not completed; no turn was started"
                );
                profile.validate()?;
                transport.write(&request(3, "account/read", json!({"refreshToken":false})))?;
                events.send(Event::Frame(json!({"state":"checking"})))?;
                stage = 3;
            }
            _ if matches!(
                frame["method"].as_str(),
                Some("account/updated" | "account/rateLimits/updated")
            ) => {}
            _ if frame["method"]
                .as_str()
                .is_some_and(|method| method.starts_with("account/")) =>
            {
                bail!("Codex returned an unsupported account-context notification")
            }
            _ => {}
        }
    }
}

fn cancel(transport: &mut transport::Transport, id: &str) -> bool {
    if transport
        .write(&request(4, "account/login/cancel", json!({"loginId":id})))
        .is_err()
    {
        return false;
    }
    let deadline = Instant::now() + CANCEL_DEADLINE;
    while Instant::now() < deadline {
        match transport.next() {
            Ok(Some(frame)) if frame["id"] == 4 => {
                return matches!(
                    frame["result"]["status"].as_str(),
                    Some("canceled" | "notFound")
                );
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    false // Transport Drop still terminates/reaps the process and joins pipes.
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn login_success_and_join_receipt_are_published_in_the_same_observed_state() {
        let (release, wait) = mpsc::channel();
        let (published, notification) = mpsc::channel();
        let session = Session::fixture_worker(move |_, events| {
            events
                .send(Event::Frame(json!({"state":"authenticated"})))
                .unwrap();
            published.send(()).unwrap();
            wait.recv().unwrap();
        });
        let mut operation = Operation {
            id: uuid::Uuid::new_v4().to_string(),
            account: uuid::Uuid::new_v4().to_string(),
            session,
            state: "checking",
            terminal: None,
            url: None,
            user_code: None,
            message: String::new(),
            cancelled: false,
            cancel_acknowledged: false,
            returned: false,
        };
        notification.recv().unwrap();
        operation.poll();
        assert_eq!(operation.status()["state"], "finishing");
        assert_eq!(operation.status()["workerReturned"], false);
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while operation.completion().status() != WorkerThreadStatus::Returned {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        assert_eq!(operation.status()["workerReturned"], false);
        operation.poll();
        assert_eq!(operation.status()["state"], "authenticated");
        assert_eq!(operation.status()["workerReturned"], true);
    }
    #[test]
    fn device_login_url_stays_on_the_official_openai_device_page() {
        let good = "https://auth.openai.com/codex/device";
        assert!(device_url(good).is_ok());
        for bad in [
            good.replace("auth.openai.com", "auth.openai.com.invalid"),
            good.replace("https://", "http://"),
            good.replace("/codex/device", "/other"),
            format!("{good}?redirect_uri=https://example.invalid"),
            format!("{good}#fragment"),
        ] {
            assert!(device_url(&bad).is_err());
        }
    }
}
