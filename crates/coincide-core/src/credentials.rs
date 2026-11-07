//! Trusted native boundary. Never expose this module's sink or CLI output through
//! agent JSON APIs. Approval must originate in native UI, not page content.
use serde_json::Value;
#[cfg(windows)]
#[path = "credentials_windows.rs"]
mod windows_capture;
#[cfg(unix)]
use std::{
    io::Read,
    process::{Command, Stdio},
};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Manager {
    Bitwarden,
    OnePassword,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    Unavailable,
    Locked,
    InvalidResponse,
    InvalidOrigin,
    ApprovalRequired,
    StalePage,
    NotFound,
    FillFailed,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ready,
    Locked,
    NeedsSetup,
    UnlocksOnUse,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Login {
    pub id: String,
    pub title: String,
    pub username: String,
}
/// Intentionally neither Debug nor Serialize. Only a trusted sink sees secrets.
pub struct Secret {
    username: String,
    password: String,
    totp: Option<String>,
}
impl Secret {
    pub fn username(&self) -> &str {
        &self.username
    }
    pub fn password(&self) -> &str {
        &self.password
    }
    pub fn totp(&self) -> Option<&str> {
        self.totp.as_deref()
    }
}
/// A sink must atomically check the current page binding before writing, bypass
/// page-visible logging, and return success only after confirming the fill.
pub trait PrivateFillSink {
    fn fill(&mut self, binding: &PageBinding, secret: &Secret) -> Result<(), Failure>;
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageBinding {
    pub tab: String,
    pub navigation: u64,
    origin: String,
}
impl PageBinding {
    pub fn new(tab: String, navigation: u64, page: &str) -> Result<Self, Failure> {
        Ok(Self {
            tab,
            navigation,
            origin: origin(page)?,
        })
    }
    pub fn origin(&self) -> &str {
        &self.origin
    }
}
fn origin(page: &str) -> Result<String, Failure> {
    let url = Url::parse(page).map_err(|_| Failure::InvalidOrigin)?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(Failure::InvalidOrigin);
    }
    Ok(url.origin().ascii_serialization())
}
/// Runner injection permits synthetic fixtures; no fixture may query live vaults.
pub trait VaultCommand {
    fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure>;
    /// `input` goes to the command's stdin, never its arguments: process lists
    /// show arguments to other processes, and an edited item holds its secrets.
    fn run_with_input(&self, _args: &[&str], _input: &[u8]) -> Result<Vec<u8>, Failure> {
        Err(Failure::Unavailable)
    }
}
impl<T: VaultCommand + ?Sized> VaultCommand for std::sync::Arc<T> {
    fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
        (**self).run(args)
    }
    fn run_with_input(&self, args: &[&str], input: &[u8]) -> Result<Vec<u8>, Failure> {
        (**self).run_with_input(args, input)
    }
}
/// Uses an explicitly selected absolute executable, never a shell. Session comes
/// from BW_SESSION inherited from the authorized app; this adapter never unlocks,
/// logs in, locks, or changes a vault. Call on a background worker.
pub struct CliCommand {
    executable: PathBuf,
}
impl CliCommand {
    pub fn new(executable: PathBuf) -> Result<Self, Failure> {
        if !executable.is_absolute()
            || !executable.is_file()
            || (cfg!(windows)
                && !executable.extension().is_some_and(|extension| {
                    extension
                        .to_str()
                        .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
                }))
        {
            return Err(Failure::Unavailable);
        }
        Ok(Self { executable })
    }
}
impl VaultCommand for CliCommand {
    fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
        self.capture(args, Duration::from_secs(30))
    }
    fn run_with_input(&self, args: &[&str], input: &[u8]) -> Result<Vec<u8>, Failure> {
        self.capture_with_input(args, Some(input), Duration::from_secs(30))
    }
}
impl CliCommand {
    #[cfg(windows)]
    fn capture(&self, args: &[&str], timeout: Duration) -> Result<Vec<u8>, Failure> {
        windows_capture::capture(self, args, None, timeout)
    }
    #[cfg(windows)]
    fn capture_with_input(
        &self,
        args: &[&str],
        input: Option<&[u8]>,
        timeout: Duration,
    ) -> Result<Vec<u8>, Failure> {
        windows_capture::capture(self, args, input, timeout)
    }
    #[cfg(not(any(unix, windows)))]
    fn capture(&self, _args: &[&str], _timeout: Duration) -> Result<Vec<u8>, Failure> {
        // Other hosts need an owned, bounded subprocess transport first.
        Err(Failure::Unavailable)
    }
    #[cfg(not(any(unix, windows)))]
    fn capture_with_input(
        &self,
        _args: &[&str],
        _input: Option<&[u8]>,
        _timeout: Duration,
    ) -> Result<Vec<u8>, Failure> {
        Err(Failure::Unavailable)
    }
    #[cfg(unix)]
    fn capture(&self, args: &[&str], timeout: Duration) -> Result<Vec<u8>, Failure> {
        self.capture_with_input(args, None, timeout)
    }
    #[cfg(unix)]
    fn capture_with_input(
        &self,
        args: &[&str],
        input: Option<&[u8]>,
        timeout: Duration,
    ) -> Result<Vec<u8>, Failure> {
        use std::os::{fd::AsRawFd, unix::process::CommandExt};
        let child = Command::new(&self.executable)
            .args(args)
            .process_group(0)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| Failure::Unavailable)?;
        let mut group = OwnedGroup(child);
        let mut stdout = group.0.stdout.take().ok_or(Failure::Unavailable)?;
        let fd = stdout.as_raw_fd();
        // Nonblocking reads avoid any reader thread: even an escaped descendant
        // retaining this pipe cannot outlive the capture deadline in our process.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(Failure::Unavailable);
        }
        // Stdin is written nonblocking between reads, so a command that writes
        // before draining its input can't deadlock against a full pipe.
        let mut stdin = match input {
            Some(_) => {
                let stdin = group.0.stdin.take().ok_or(Failure::Unavailable)?;
                let fd = stdin.as_raw_fd();
                let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
                if flags < 0
                    || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
                {
                    return Err(Failure::Unavailable);
                }
                Some(stdin)
            }
            None => None,
        };
        let mut remaining_input = input.unwrap_or_default();
        let start = Instant::now();
        let mut bytes = Vec::new();
        loop {
            if start.elapsed() >= timeout {
                return Err(Failure::Unavailable);
            }
            if let Some(pipe) = stdin.as_mut() {
                use std::io::Write;
                match pipe.write(remaining_input) {
                    Ok(n) => remaining_input = &remaining_input[n..],
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                        ) => {}
                    // The command closed its input early; its exit status decides.
                    Err(_) => remaining_input = &[],
                }
                if remaining_input.is_empty() {
                    // Closing stdin is the command's end-of-input.
                    stdin = None;
                }
            }
            let mut chunk = [0_u8; 8192];
            match stdout.read(&mut chunk) {
                Ok(0) => {}
                Ok(n) => {
                    if bytes.len() + n > 8 * 1024 * 1024 {
                        return Err(Failure::InvalidResponse);
                    }
                    bytes.extend_from_slice(&chunk[..n]);
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    // A small pipe can drain before its writer runs again. A fixed
                    // sleep here throttles large responses by pipe capacity and
                    // can spend the deadline waiting even while the writer is ready.
                    // Wait on actual readiness, then read normally; readiness alone
                    // never proves EOF, output validity, or child completion.
                    let remaining = timeout.saturating_sub(start.elapsed());
                    if remaining.is_zero() {
                        return Err(Failure::Unavailable);
                    }
                    // Round a positive wait up by at most one millisecond to
                    // avoid a sub-millisecond busy spin. The outer absolute
                    // deadline check still rejects output after expiry.
                    let wait_ms = remaining.as_millis().saturating_add(1).min(10) as libc::c_int;
                    let mut poll = libc::pollfd {
                        fd,
                        events: libc::POLLIN,
                        revents: 0,
                    };
                    // stdout owns fd throughout this call; poll borrows one
                    // initialized stack entry and retains no pointer afterward.
                    let result = unsafe { libc::poll(&mut poll, 1, wait_ms) };
                    if result < 0
                        && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
                    {
                        return Err(Failure::Unavailable);
                    }
                    if poll.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
                        return Err(Failure::Unavailable);
                    }
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(Failure::Unavailable),
            }
            // Do not reap the leader until capture completes. This retains its
            // PID while group cleanup still needs the process-group identifier.
            match group.exited_successfully()? {
                Some(true) => return Ok(bytes),
                Some(_) => return Err(Failure::Unavailable),
                None => {}
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

/// Retain the unreaped leader until its process group has been signalled.
#[cfg(unix)]
struct OwnedGroup(std::process::Child);
#[cfg(unix)]
impl OwnedGroup {
    fn exited_successfully(&self) -> Result<Option<bool>, Failure> {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.0.id() as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result != 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                return Ok(None);
            }
            return Err(Failure::Unavailable);
        }
        if unsafe { info.si_pid() } == 0 {
            return Ok(None);
        }
        Ok(Some(
            info.si_code == libc::CLD_EXITED && unsafe { info.si_status() } == 0,
        ))
    }
}
#[cfg(unix)]
impl Drop for OwnedGroup {
    fn drop(&mut self) {
        // No wait/try_wait may precede this signal. The unreaped leader pins
        // the PID/PGID so a recycled unrelated group cannot receive SIGKILL.
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGKILL);
        }
        let _ = self.0.wait();
    }
}

pub struct Vault<R> {
    manager: Manager,
    runner: R,
    instance: uuid::Uuid,
}
/// One-shot approval bound to the selected item and page. Native UI owns this.
pub struct ApprovedFill {
    instance: uuid::Uuid,
    manager: Manager,
    item: String,
    page: PageBinding,
    issued: Instant,
}
impl<R: VaultCommand> Vault<R> {
    pub fn new(manager: Manager, runner: R) -> Self {
        Self {
            manager,
            runner,
            instance: uuid::Uuid::new_v4(),
        }
    }
    fn json(&self, args: &[&str]) -> Result<Value, Failure> {
        serde_json::from_slice(&self.runner.run(args)?).map_err(|_| Failure::InvalidResponse)
    }
    pub fn status(&self) -> Result<Status, Failure> {
        match self.manager {
            Manager::Bitwarden => {
                match self.json(&["status", "--nointeraction"])?["status"].as_str() {
                    Some("unlocked") => Ok(Status::Ready),
                    Some("locked") => Ok(Status::Locked),
                    Some("unauthenticated") => Ok(Status::NeedsSetup),
                    _ => Err(Failure::InvalidResponse),
                }
            }
            Manager::OnePassword => {
                let value = self.json(&["account", "list", "--format", "json"])?;
                let accounts = value.as_array().ok_or(Failure::InvalidResponse)?;
                Ok(if accounts.is_empty() {
                    Status::NeedsSetup
                } else {
                    Status::UnlocksOnUse
                })
            }
        }
    }
    pub fn logins(&self, page: &PageBinding) -> Result<Vec<Login>, Failure> {
        let value = match self.manager {
            Manager::Bitwarden => {
                self.json(&["list", "items", "--url", &page.origin, "--nointeraction"])
            }
            Manager::OnePassword => {
                self.json(&["item", "list", "--categories", "Login", "--format", "json"])
            }
        }?;
        let entries = value.as_array().ok_or(Failure::InvalidResponse)?;
        Ok(entries
            .iter()
            .filter_map(|entry| {
                let (title, username, urls, key) = match self.manager {
                    Manager::Bitwarden if entry["type"] == 1 => (
                        &entry["name"],
                        &entry["login"]["username"],
                        &entry["login"]["uris"],
                        "uri",
                    ),
                    Manager::OnePassword => (
                        &entry["title"],
                        &entry["additional_information"],
                        &entry["urls"],
                        "href",
                    ),
                    _ => return None,
                };
                // Deliberately exact HTTPS origin: no suffix matching or permissive vault rules.
                if !urls.as_array()?.iter().any(|u| {
                    u[key].as_str().and_then(|s| origin(s).ok()).as_deref() == Some(&page.origin)
                }) {
                    return None;
                }
                let id = entry["id"].as_str()?;
                if !valid_id(id) {
                    return None;
                }
                Some(Login {
                    id: id.into(),
                    title: title.as_str().unwrap_or("").into(),
                    username: username.as_str().unwrap_or("").into(),
                })
            })
            .collect())
    }
    /// Call only after affirmative native UI consent. Denial produces no token.
    pub fn approve(
        &self,
        page: &PageBinding,
        item: &Login,
        allowed: bool,
    ) -> Result<ApprovedFill, Failure> {
        if !allowed {
            return Err(Failure::ApprovalRequired);
        }
        if !self.logins(page)?.iter().any(|v| v.id == item.id) {
            return Err(Failure::NotFound);
        }
        Ok(ApprovedFill {
            instance: self.instance,
            manager: self.manager,
            item: item.id.clone(),
            page: page.clone(),
            issued: Instant::now(),
        })
    }
    pub fn fill(
        &self,
        approval: ApprovedFill,
        current: &PageBinding,
        sink: &mut impl PrivateFillSink,
    ) -> Result<(), Failure> {
        if approval.page != *current {
            return Err(Failure::StalePage);
        }
        if approval.instance != self.instance
            || approval.manager != self.manager
            || approval.issued.elapsed() > Duration::from_secs(300)
        {
            return Err(Failure::ApprovalRequired);
        }
        // Recheck membership after approval, before reading the secret.
        if !self.logins(current)?.iter().any(|v| v.id == approval.item) {
            return Err(Failure::NotFound);
        }
        let secret = match self.manager {
            Manager::Bitwarden => {
                let value = self.json(&["get", "item", &approval.item, "--nointeraction"])?;
                let login = &value["login"];
                if !matches_origin(&login["uris"], "uri", current.origin()) {
                    return Err(Failure::NotFound);
                }
                let totp = if login["totp"].as_str().is_some_and(|s| !s.is_empty()) {
                    let raw =
                        self.runner
                            .run(&["get", "totp", &approval.item, "--nointeraction"])?;
                    let code = String::from_utf8(raw).map_err(|_| Failure::InvalidResponse)?;
                    let code = code.trim();
                    if !(6..=10).contains(&code.len()) || !code.bytes().all(|b| b.is_ascii_digit())
                    {
                        return Err(Failure::InvalidResponse);
                    }
                    Some(code.into())
                } else {
                    None
                };
                Secret {
                    username: login["username"].as_str().unwrap_or("").into(),
                    password: login["password"].as_str().ok_or(Failure::NotFound)?.into(),
                    totp,
                }
            }
            Manager::OnePassword => {
                let value = self.json(&[
                    "item",
                    "get",
                    &approval.item,
                    "--format",
                    "json",
                    "--reveal",
                ])?;
                if !matches_origin(&value["urls"], "href", current.origin()) {
                    return Err(Failure::NotFound);
                }
                let fields = value["fields"].as_array().ok_or(Failure::InvalidResponse)?;
                let field = |purpose| {
                    fields
                        .iter()
                        .find(|f| f["purpose"] == purpose)
                        .and_then(|f| f["value"].as_str())
                };
                Secret {
                    username: field("USERNAME").unwrap_or("").into(),
                    password: field("PASSWORD").ok_or(Failure::NotFound)?.into(),
                    totp: fields
                        .iter()
                        .find(|f| f["type"] == "OTP")
                        .and_then(|f| f["totp"].as_str())
                        .map(str::to_owned),
                }
            }
        };
        sink.fill(current, &secret)
    }
}
fn matches_origin(urls: &Value, key: &str, expected: &str) -> bool {
    urls.as_array().is_some_and(|urls| {
        urls.iter()
            .any(|u| u[key].as_str().and_then(|s| origin(s).ok()).as_deref() == Some(expected))
    })
}
pub(crate) fn valid_id(id: &str) -> bool {
    id.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
/// Neither CLI provides WebAuthn browser ceremonies through this adapter. Sign-in
/// with Bitwarden passkeys is `passkeys`, behind the browser's own native bridge.
pub fn passkey_capability() -> Result<(), &'static str> {
    Err(
        "Passkey ceremonies aren't part of password filling; Bitwarden passkey sign-in goes through the browser's passkey bridge, and registration is unavailable",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    struct Fixture {
        calls: RefCell<Vec<Vec<String>>>,
    }
    impl VaultCommand for Fixture {
        fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
            self.calls
                .borrow_mut()
                .push(args.iter().map(|s| s.to_string()).collect());
            let response = match args {
                ["status", "--nointeraction"] => r#"{"status":"locked"}"#,
                [
                    "list",
                    "items",
                    "--url",
                    "https://example.com",
                    "--nointeraction",
                ] => {
                    r#"[
                    {"id":"safe-id","type":1,"name":"Synthetic","login":{"username":"fixture","uris":[{"uri":"https://example.com/login"}]}},
                    {"id":"evil","type":1,"login":{"uris":[{"uri":"https://example.com.attacker.test"}]}},
                    {"id":"--help","type":1,"login":{"uris":[{"uri":"https://other.test"}]}}
                ]"#
                }
                ["get", "item", "safe-id", "--nointeraction"] => {
                    r#"{"login":{"username":"fixture","password":"synthetic-only","totp":"synthetic-seed","uris":[{"uri":"https://example.com"}]}}"#
                }
                ["get", "totp", "safe-id", "--nointeraction"] => "123456\n",
                _ => return Err(Failure::Unavailable),
            };
            Ok(response.as_bytes().to_vec())
        }
    }
    fn vault() -> Vault<Fixture> {
        Vault::new(
            Manager::Bitwarden,
            Fixture {
                calls: RefCell::new(vec![]),
            },
        )
    }
    struct Sink(bool);
    impl PrivateFillSink for Sink {
        fn fill(&mut self, _: &PageBinding, secret: &Secret) -> Result<(), Failure> {
            assert_eq!(secret.password(), "synthetic-only");
            assert_eq!(secret.totp(), Some("123456"));
            self.0 = true;
            Ok(())
        }
    }
    #[test]
    fn approved_fill_uses_private_sink() {
        let vault = vault();
        let page = PageBinding::new(
            "tab".into(),
            1,
            "https://example.com/login?private=discarded",
        )
        .unwrap();
        let logins = vault.logins(&page).unwrap();
        assert_eq!(logins.len(), 1);
        let approval = vault.approve(&page, &logins[0], true).unwrap();
        let mut sink = Sink(false);
        vault.fill(approval, &page, &mut sink).unwrap();
        assert!(sink.0);
        assert_eq!(vault.status(), Ok(Status::Locked));
    }
    #[test]
    fn denied_or_stale_page_never_fetches_secret() {
        let vault = vault();
        let page = PageBinding::new("tab".into(), 1, "https://example.com").unwrap();
        let item = vault.logins(&page).unwrap().remove(0);
        assert!(matches!(
            vault.approve(&page, &item, false),
            Err(Failure::ApprovalRequired)
        ));
        let approval = vault.approve(&page, &item, true).unwrap();
        let mut changed = page.clone();
        changed.navigation += 1;
        assert_eq!(
            vault.fill(approval, &changed, &mut Sink(false)),
            Err(Failure::StalePage)
        );
        assert!(!vault.runner.calls.borrow().iter().any(|c| c[0] == "get"));
        assert!(PageBinding::new("tab".into(), 1, "http://example.com").is_err());
        assert!(PageBinding::new("tab".into(), 1, "https://user:secret@example.com").is_err());
        assert!(passkey_capability().is_err());
    }
    #[test]
    fn failures_do_not_echo_cli_output() {
        struct Bad;
        impl VaultCommand for Bad {
            fn run(&self, _: &[&str]) -> Result<Vec<u8>, Failure> {
                Ok(b"sensitive malformed fixture".to_vec())
            }
        }
        assert_eq!(
            Vault::new(Manager::OnePassword, Bad).status(),
            Err(Failure::InvalidResponse)
        );
    }
    #[test]
    fn one_password_fixture_and_option_ids() {
        struct Op;
        impl VaultCommand for Op {
            fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
                let value = match args {
                    ["account", "list", "--format", "json"] => {
                        r#"[{"email":"synthetic@example.test"}]"#
                    }
                    ["item", "list", "--categories", "Login", "--format", "json"] => {
                        r#"[{"id":"safe-id","title":"Fixture","urls":[{"href":"https://example.com"}]}]"#
                    }
                    ["item", "get", "safe-id", "--format", "json", "--reveal"] => {
                        r#"{"urls":[{"href":"https://example.com"}],"fields":[{"purpose":"USERNAME","value":"fixture"},{"purpose":"PASSWORD","value":"synthetic-only"},{"type":"OTP","totp":"123456"}]}"#
                    }
                    _ => return Err(Failure::Unavailable),
                };
                Ok(value.as_bytes().to_vec())
            }
        }
        let vault = Vault::new(Manager::OnePassword, Op);
        assert_eq!(vault.status(), Ok(Status::UnlocksOnUse));
        let page = PageBinding::new("tab".into(), 1, "https://example.com").unwrap();
        let item = vault.logins(&page).unwrap().remove(0);
        let approval = vault.approve(&page, &item, true).unwrap();
        vault.fill(approval, &page, &mut Sink(false)).unwrap();
        assert!(!valid_id("--help"));
    }
    #[cfg(unix)]
    #[test]
    fn descendant_retaining_stdout_is_killed_at_deadline() {
        let temp = tempfile::tempdir().unwrap();
        let pid_file = temp.path().join("descendant.pid");
        // No account CLI is invoked: only a synthetic shell descendant.
        let cli = CliCommand::new(PathBuf::from("/bin/sh")).unwrap();
        let start = Instant::now();
        assert_eq!(
            cli.capture(
                &[
                    "-c",
                    "sleep 60 & echo $! > \"$1\"; exit 0",
                    "fixture",
                    pid_file.to_str().unwrap()
                ],
                Duration::from_millis(200)
            ),
            Err(Failure::Unavailable)
        );
        assert!(start.elapsed() < Duration::from_secs(3));
        let pid: i32 = std::fs::read_to_string(pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        // A terminated orphan can briefly remain a zombie; it must not run.
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let result = unsafe { libc::kill(pid, 0) };
            if result != 0 {
                break;
            }
            #[cfg(target_os = "linux")]
            if std::fs::read_to_string(format!("/proc/{pid}/stat"))
                .is_ok_and(|s| s.split_whitespace().nth(2) == Some("Z"))
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "descendant survived group teardown"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    #[cfg(unix)]
    #[test]
    fn bounded_capture_success_failure_and_overflow() {
        let cli = CliCommand::new(PathBuf::from("/bin/sh")).unwrap();
        assert_eq!(
            cli.capture(&["-c", "printf synthetic"], Duration::from_secs(2)),
            Ok(b"synthetic".to_vec())
        );
        assert_eq!(
            cli.capture(&["-c", "printf synthetic; exit 2"], Duration::from_secs(2)),
            Err(Failure::Unavailable)
        );
        assert_eq!(
            cli.capture(&["-c", "yes synthetic"], Duration::from_secs(3)),
            Err(Failure::InvalidResponse)
        );
    }
    #[cfg(unix)]
    #[test]
    fn finite_oversized_output_is_invalid_and_the_actual_leader_is_reaped() {
        let temp = tempfile::tempdir().unwrap();
        let pid_file = temp.path().join("capture-leader.pid");
        let cli = CliCommand::new(PathBuf::from("/bin/sh")).unwrap();
        assert_eq!(
            cli.capture(
                &[
                    "-c",
                    "echo $$ > \"$1\"; /usr/bin/head -c 8388609 /dev/zero; exit 2",
                    "finite-overflow-fixture",
                    pid_file.to_str().unwrap(),
                ],
                Duration::from_secs(3),
            ),
            Err(Failure::InvalidResponse)
        );
        let pid: i32 = std::fs::read_to_string(pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let mut status = 0;
        assert_eq!(
            unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) },
            -1
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD)
        );
    }
    #[cfg(unix)]
    #[test]
    fn input_goes_through_stdin_and_never_blocks_on_a_full_pipe() {
        let cli = CliCommand::new(PathBuf::from("/bin/sh")).unwrap();
        // The script sees no input in its arguments; `cat` echoes stdin back.
        assert_eq!(
            cli.capture_with_input(
                &["-c", "test $# -eq 0 && cat"],
                Some(b"synthetic-encoded-item"),
                Duration::from_secs(2)
            ),
            Ok(b"synthetic-encoded-item".to_vec())
        );
        // Larger than any pipe buffer, echoed while it is still being written.
        let large = vec![b'x'; 1024 * 1024];
        assert_eq!(
            cli.capture_with_input(&["-c", "cat"], Some(&large), Duration::from_secs(5)),
            Ok(large)
        );
        // A command that ignores its input still finishes on its own status.
        assert_eq!(
            cli.capture_with_input(
                &["-c", "exec 0<&-; printf done"],
                Some(&vec![b'y'; 1024 * 1024]),
                Duration::from_secs(5)
            ),
            Ok(b"done".to_vec())
        );
    }
    #[cfg(not(any(unix, windows)))]
    #[test]
    fn unsupported_process_capture_fails_closed() {
        let cli = CliCommand::new(std::env::current_exe().unwrap()).unwrap();
        assert_eq!(cli.run(&[]), Err(Failure::Unavailable));
    }
    #[cfg(unix)]
    #[test]
    fn cleanup_keeps_leader_waitable_until_group_teardown() {
        use std::os::unix::process::CommandExt;
        let child = Command::new("/bin/sh")
            .args(["-c", "exit 0"])
            .process_group(0)
            .spawn()
            .unwrap();
        let group = OwnedGroup(child);
        let pid = group.0.id() as i32;
        let deadline = Instant::now() + Duration::from_secs(2);
        while group.exited_successfully().unwrap().is_none() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        // WNOWAIT must allow repeated observation of the SAME exited leader.
        // A reaping try_wait implementation fails this second observation.
        assert_eq!(group.exited_successfully(), Ok(Some(true)));
        assert_eq!(unsafe { libc::kill(pid, 0) }, 0);
        drop(group); // group signal first, then leader reap
        let mut status = 0;
        assert_eq!(
            unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) },
            -1
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD)
        );
    }
}
