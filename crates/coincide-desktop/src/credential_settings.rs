//! Native password settings and browser-login workflow. No agent API entrypoint.
use crate::credentials::{
    ApprovalPrompt, ApprovalView, FillJob, NativeDecision, QueuedSink, complete_approval,
    private_fill_channel,
};
use coincide_core::credentials::{
    CliCommand, Failure, Login, Manager, PageBinding, Status, Vault, VaultCommand,
};
use gpui_kit::{
    AppContext, Context, Entity, IntoElement, ParentElement, Render, SharedString, Styled, Window,
    component::{Disableable, button::Button},
    div,
};
use std::{
    path::PathBuf,
    sync::{
        Arc,
        mpsc::{self, Receiver, Sender},
    },
    time::{Duration, Instant},
};

#[derive(Clone)]
pub struct CredentialSource {
    manager: Manager,
    command: Arc<dyn VaultCommand + Send + Sync>,
}
impl CredentialSource {
    pub fn new(manager: Manager, executable: PathBuf) -> Result<Self, Failure> {
        Ok(Self {
            manager,
            command: Arc::new(CliCommand::new(executable)?),
        })
    }
    pub fn label(&self) -> &'static str {
        match self.manager {
            Manager::Bitwarden => "Bitwarden",
            Manager::OnePassword => "1Password",
        }
    }
}
/// Filesystem-only CLI discovery. This does not read a vault or verify login.
/// Explicit executable selection can instead be supplied through CredentialSource.
pub fn installed_sources() -> Vec<CredentialSource> {
    [(Manager::Bitwarden, "bw"), (Manager::OnePassword, "op")]
        .into_iter()
        .filter_map(|(manager, name)| {
            ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
                .into_iter()
                .find_map(|root| {
                    CredentialSource::new(manager, PathBuf::from(root).join(name)).ok()
                })
        })
        .collect()
}
#[derive(Clone)]
struct Account {
    id: String,
    label: String,
}
fn accounts(source: &CredentialSource) -> Result<Vec<Account>, Failure> {
    let args: &[&str] = match source.manager {
        Manager::Bitwarden => &["status", "--nointeraction"],
        Manager::OnePassword => &["account", "list", "--format", "json"],
    };
    let value: serde_json::Value =
        serde_json::from_slice(&source.command.run(args)?).map_err(|_| Failure::InvalidResponse)?;
    match source.manager {
        Manager::Bitwarden => match value["status"].as_str() {
            Some("unlocked" | "locked") => Ok(vec![Account {
                id: "current".into(),
                label: value["userEmail"]
                    .as_str()
                    .unwrap_or("Current Bitwarden CLI account")
                    .into(),
            }]),
            Some("unauthenticated") => Ok(vec![]),
            _ => Err(Failure::InvalidResponse),
        },
        Manager::OnePassword => value
            .as_array()
            .ok_or(Failure::InvalidResponse)?
            .iter()
            .map(|entry| {
                let id = entry["account_uuid"]
                    .as_str()
                    .ok_or(Failure::InvalidResponse)?;
                if !id.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
                    || id.len() > 128
                    || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                {
                    return Err(Failure::InvalidResponse);
                }
                Ok(Account {
                    id: id.into(),
                    label: format!(
                        "{} · {}",
                        entry["email"].as_str().unwrap_or("1Password account"),
                        entry["url"].as_str().unwrap_or(id)
                    ),
                })
            })
            .collect(),
    }
}
struct AccountCommand {
    source: CredentialSource,
    account: String,
}
impl VaultCommand for AccountCommand {
    fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
        if self.source.manager == Manager::OnePassword {
            let mut scoped = args.to_vec();
            scoped.extend(["--account", self.account.as_str()]);
            self.source.command.run(&scoped)
        } else {
            self.source.command.run(args)
        }
    }
}
type Client = Arc<Vault<AccountCommand>>;
enum Update {
    Accounts(u64, Result<Vec<Account>, Failure>),
    Logins(u64, Client, Result<(Status, Vec<Login>), Failure>),
    Filled(u64, Result<(), Failure>),
}
struct PendingApproval {
    prompt: ApprovalPrompt,
    decisions: Receiver<NativeDecision>,
    view: Entity<ApprovalView>,
    started: Instant,
}
/// Parent creates an Entity<CredentialSettings>, polls it on its existing UI
/// tick, sets the active native PageBinding/capability before polling, and drains
/// the returned private FillJob receiver through BrowserController each tick.
pub struct CredentialSettings {
    sources: Vec<CredentialSource>,
    selected_source: Option<usize>,
    accounts: Vec<Account>,
    selected_account: Option<usize>,
    page: Option<PageBinding>,
    fill_available: bool,
    revision: u64,
    busy: bool,
    client: Option<Client>,
    logins: Vec<Login>,
    approval: Option<PendingApproval>,
    status: String,
    sink: QueuedSink,
    active_scope: Option<QueuedSink>,
    sender: Sender<Update>,
    updates: Receiver<Update>,
}
impl CredentialSettings {
    pub fn new(sources: Vec<CredentialSource>) -> (Self, Receiver<FillJob>) {
        let (sink, jobs) = private_fill_channel();
        let (sender, updates) = mpsc::channel();
        (
            Self {
                sources,
                selected_source: None,
                accounts: vec![],
                selected_account: None,
                page: None,
                fill_available: false,
                revision: 0,
                busy: false,
                client: None,
                logins: vec![],
                approval: None,
                status: "Select a password manager to read account metadata.".into(),
                sink,
                active_scope: None,
                sender,
                updates,
            },
            jobs,
        )
    }
    fn invalidate(&mut self) {
        self.revision = self.revision.wrapping_add(1);
        self.approval = None;
        self.client = None;
        self.logins.clear();
        if let Some(scope) = self.active_scope.take() {
            scope.revoke();
        }
    }
    pub fn set_page(
        &mut self,
        page: Option<PageBinding>,
        fill_available: bool,
        cx: &mut Context<Self>,
    ) {
        if self.page != page || self.fill_available != fill_available {
            self.invalidate();
            self.page = page;
            self.fill_available = fill_available;
            self.status = "Page changed. Refresh matching logins for the current page.".into();
            cx.notify();
        }
    }
    fn connect(&mut self, source: usize, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(selected) = self.sources.get(source).cloned() else {
            return;
        };
        self.invalidate();
        self.selected_source = Some(source);
        self.accounts.clear();
        self.selected_account = None;
        self.busy = true;
        self.status = "Reading account metadata…".into();
        let sender = self.sender.clone();
        let revision = self.revision;
        std::thread::spawn(move || {
            let _ = sender.send(Update::Accounts(revision, accounts(&selected)));
        });
        cx.notify();
    }
    fn load_account(&mut self, account: usize, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(source) = self
            .selected_source
            .and_then(|i| self.sources.get(i))
            .cloned()
        else {
            return;
        };
        let Some(selected) = self.accounts.get(account).cloned() else {
            return;
        };
        let Some(page) = self.page.clone() else {
            self.status = "Open an HTTPS page before loading matching logins.".into();
            cx.notify();
            return;
        };
        self.invalidate();
        self.selected_account = Some(account);
        self.busy = true;
        self.status =
            "Reading matching login metadata… 1Password may request native approval.".into();
        let client = Arc::new(Vault::new(
            source.manager,
            AccountCommand {
                source,
                account: selected.id,
            },
        ));
        let sender = self.sender.clone();
        let revision = self.revision;
        std::thread::spawn(move || {
            let result = client.status().and_then(|status| match status {
                Status::Ready | Status::UnlocksOnUse => {
                    client.logins(&page).map(|items| (status, items))
                }
                _ => Err(Failure::Locked),
            });
            let _ = sender.send(Update::Logins(revision, client, result));
        });
        cx.notify();
    }
    fn request_approval(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.busy || !self.fill_available || self.approval.is_some() || self.client.is_none() {
            return;
        }
        let (Some(page), Some(item)) = (self.page.clone(), self.logins.get(index).cloned()) else {
            return;
        };
        let prompt = ApprovalPrompt::new(page, item);
        let (view, decisions) = ApprovalView::new(prompt.clone());
        self.approval = Some(PendingApproval {
            prompt,
            decisions,
            view: cx.new(|_| view),
            started: Instant::now(),
        });
        cx.notify();
    }
    pub fn poll(&mut self, cx: &mut Context<Self>) {
        while let Ok(update) = self.updates.try_recv() {
            // Only one metadata/fill worker runs at once. A page change can
            // invalidate its result but must still release the busy state.
            self.busy = false;
            match update {
                Update::Accounts(revision, result) if revision == self.revision => match result {
                    Ok(accounts) => {
                        self.accounts = accounts;
                        self.status = if self.accounts.is_empty() {
                            "No configured account. Set up the manager's CLI outside Coincide."
                        } else {
                            "Select an account to load matching login metadata."
                        }
                        .into();
                    }
                    Err(error) => self.status = failure_text(error).into(),
                },
                Update::Logins(revision, client, result) if revision == self.revision => {
                    match result {
                        Ok((status, logins)) => {
                            self.client = Some(client);
                            self.logins = logins;
                            self.status = format!(
                                "{} matching login(s). {}",
                                self.logins.len(),
                                match status {
                                    Status::UnlocksOnUse =>
                                        "1Password unlocks through its app when needed.",
                                    _ => "Vault session is unlocked.",
                                }
                            );
                        }
                        Err(error) => self.status = failure_text(error).into(),
                    }
                }
                Update::Filled(revision, result) if revision == self.revision => {
                    self.active_scope = None;
                    self.status = match result {
                        Ok(()) => "Login filled and confirmed.",
                        Err(error) => failure_text(error),
                    }
                    .into();
                }
                _ => {}
            }
            cx.notify();
        }
        let decision = self
            .approval
            .as_ref()
            .and_then(|pending| pending.decisions.try_recv().ok());
        if let Some(decision) = decision {
            let Some(pending) = self.approval.take() else {
                return;
            };
            if !self.fill_available {
                self.status =
                    "Private credential filling is unavailable on this browser backend.".into();
                cx.notify();
                return;
            }
            let (Some(client), Some(page)) = (self.client.clone(), self.page.clone()) else {
                return;
            };
            let mut scope = self.sink.new_scope();
            self.active_scope = Some(scope.clone());
            let sender = self.sender.clone();
            let revision = self.revision;
            self.busy = true;
            self.status = "Processing native approval…".into();
            std::thread::spawn(move || {
                let result =
                    complete_approval(&client, pending.prompt, decision, &page, &mut scope);
                let _ = sender.send(Update::Filled(revision, result));
            });
            cx.notify();
        } else if self
            .approval
            .as_ref()
            .is_some_and(|pending| pending.started.elapsed() >= Duration::from_secs(300))
        {
            self.approval = None;
            self.status = "Login request expired. Nothing was filled.".into();
            cx.notify();
        }
    }
}
impl Drop for CredentialSettings {
    fn drop(&mut self) {
        if let Some(scope) = self.active_scope.take() {
            scope.revoke();
        }
    }
}
fn failure_text(failure: Failure) -> &'static str {
    match failure {
        Failure::Locked => {
            "Unlock or sign in to the selected password manager, then refresh. Coincide does not change your CLI login."
        }
        Failure::ApprovalRequired => "Login request was denied or expired. Nothing was filled.",
        Failure::StalePage => "The page or account changed. Request a new login fill.",
        Failure::NotFound => "The selected login no longer matches this page.",
        Failure::InvalidOrigin => "Saved-login lookup requires an HTTPS page.",
        Failure::InvalidResponse => "The password manager returned an unreadable response.",
        Failure::Unavailable => "The password manager or private browser fill is unavailable.",
        Failure::FillFailed => {
            "The browser did not confirm a fill. Check the page before trying again."
        }
    }
}
impl Render for CredentialSettings {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut panel = div().flex().flex_col().gap_2().p_4().child("Password managers")
            .child("Select a connected CLI account. Login approval is always required; approval cannot be disabled.");
        if self.sources.is_empty() {
            panel = panel.child("No supported CLI found. Install Bitwarden CLI or 1Password CLI with Homebrew, then reopen this panel.");
        }
        for (index, source) in self.sources.iter().enumerate() {
            panel = panel.child(
                Button::new(SharedString::from(format!("credential-manager-{index}")))
                    .label(format!(
                        "{}{}",
                        source.label(),
                        if self.selected_source == Some(index) {
                            " · selected"
                        } else {
                            ""
                        }
                    ))
                    .disabled(self.busy)
                    .on_click(cx.listener(move |this, _, _, cx| this.connect(index, cx))),
            );
        }
        for (index, account) in self.accounts.iter().enumerate() {
            panel = panel.child(
                Button::new(SharedString::from(format!("credential-account-{index}")))
                    .label(format!(
                        "{}{}",
                        account.label,
                        if self.selected_account == Some(index) {
                            " · selected"
                        } else {
                            ""
                        }
                    ))
                    .disabled(self.busy || self.page.is_none())
                    .on_click(cx.listener(move |this, _, _, cx| this.load_account(index, cx))),
            );
        }
        if let Some(index) = self.selected_account {
            panel = panel.child(
                Button::new("credential-refresh-logins")
                    .label("Refresh matching logins")
                    .disabled(self.busy || self.page.is_none())
                    .on_click(cx.listener(move |this, _, _, cx| this.load_account(index, cx))),
            );
        }
        panel = panel
            .child(SharedString::from(
                self.page
                    .as_ref()
                    .map(|page| page.origin().to_owned())
                    .unwrap_or_else(|| "No eligible HTTPS browser page selected.".into()),
            ))
            .child(SharedString::from(self.status.clone()));
        if !self.fill_available {
            panel = panel.child("Private filling is unavailable in this browser backend. You can inspect matching login metadata; filling and individual secret retrieval are disabled.");
        }
        for (index, login) in self.logins.iter().enumerate() {
            panel = panel.child(
                Button::new(SharedString::from(format!("credential-login-{index}")))
                    .label(format!("{} · {}", login.title, login.username))
                    .disabled(self.busy || !self.fill_available || self.approval.is_some())
                    .on_click(cx.listener(move |this, _, _, cx| this.request_approval(index, cx))),
            );
        }
        if let Some(pending) = &self.approval {
            panel = panel.child(pending.view.clone());
        }
        panel.child("Bitwarden uses its current CLI account; switching Bitwarden accounts is not supported here. 1Password reads are scoped to the selected account. Passkeys are not supported in the Rust preview.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    struct Fixture {
        calls: Mutex<Vec<Vec<String>>>,
    }
    impl VaultCommand for Fixture {
        fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
            self.calls
                .lock()
                .unwrap()
                .push(args.iter().map(|s| s.to_string()).collect());
            match args {
                ["account", "list", "--format", "json"] => Ok(br#"[{"account_uuid":"account1","email":"synthetic@example.test","url":"example.1password.test"}]"#.to_vec()),
                ["item", "list", "--account", "account1"] => Ok(b"[]".to_vec()),
                _ => Err(Failure::Unavailable),
            }
        }
    }
    #[test]
    fn account_metadata_and_reads_are_scoped_without_login_mutation() {
        let runner = Arc::new(Fixture {
            calls: Mutex::new(vec![]),
        });
        let source = CredentialSource {
            manager: Manager::OnePassword,
            command: runner.clone(),
        };
        let list = accounts(&source).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, "account1");
        let scoped = AccountCommand {
            source,
            account: list[0].id.clone(),
        };
        assert_eq!(scoped.run(&["item", "list"]), Ok(b"[]".to_vec()));
        assert_eq!(runner.calls.lock().unwrap().len(), 2);
    }
    #[test]
    fn new_workflow_does_not_query_cli_and_starts_unavailable() {
        let runner = Arc::new(Fixture {
            calls: Mutex::new(vec![]),
        });
        let (settings, _jobs) = CredentialSettings::new(vec![CredentialSource {
            manager: Manager::OnePassword,
            command: runner.clone(),
        }]);
        assert!(!settings.fill_available);
        assert!(settings.approval.is_none());
        assert!(runner.calls.lock().unwrap().is_empty());
        assert_eq!(settings.sources[0].label(), "1Password");
    }
}
