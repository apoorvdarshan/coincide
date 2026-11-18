//! Retained per-provider native drafts. Values cross only the typed private
//! configuration boundary, never settings.patch, logs, or serialized UI state.
use super::*;
#[path = "provider_accounts_ui.rs"]
mod accounts;
use coincide_core::{
    native_ui_edits::{NativeUiEditLease, NativeUiEditors},
    provider_configuration::{ProbeReport, SetupAction, Snapshot},
};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    path::PathBuf,
    sync::mpsc,
};
#[derive(Clone, Copy)]
pub(super) enum Part {
    Status,
    Executable,
    Environment,
    Setup,
    Accounts,
}
struct Variable {
    id: String,
    name: Entity<InputState>,
    value: Entity<InputState>,
    revealed: bool,
    _subscriptions: Vec<Subscription>,
}
struct Editor {
    path: Entity<InputState>,
    variables: Vec<Variable>,
    saved_path: String,
    saved_environment: BTreeMap<String, String>,
    baseline: String,
    generation: u64,
    loaded: bool,
    needs_approval: bool,
    load_requested: bool,
    notice: String,
    report: Option<ProbeReport>,
    catalog: Option<Value>,
    checked: Option<Instant>,
    /// The last check ended in an error rather than a report.
    failed: bool,
    lease: NativeUiEditLease,
    _subscriptions: Vec<Subscription>,
}
impl Editor {
    fn values(&self, cx: &App) -> Result<(String, BTreeMap<String, String>)> {
        let mut values = BTreeMap::new();
        for row in &self.variables {
            let key = row.name.read(cx).value().trim().to_owned();
            if key.is_empty() {
                continue;
            }
            anyhow::ensure!(
                !values.contains_key(&key),
                "A variable name is set more than once"
            );
            values.insert(key, row.value.read(cx).value().to_string());
        }
        Ok((self.path.read(cx).value().trim().to_owned(), values))
    }
    fn dirty(&self, cx: &App) -> bool {
        self.values(cx).map_or(true, |(path, environment)| {
            path != self.saved_path || environment != self.saved_environment
        })
    }
}
enum Request {
    Accounts(accounts::Request),
    Load,
    Save {
        baseline: String,
        path: String,
        environment: BTreeMap<String, String>,
    },
    Check {
        refresh_catalog: bool,
    },
    Setup {
        action: SetupAction,
        baseline: String,
    },
}
enum Outcome {
    Accounts(accounts::Outcome),
    Loaded(Snapshot),
    Saved(Snapshot),
    Checked(ProbeReport, Option<Value>),
    ReloadForCheck(Snapshot),
    ManagedChecked(usize),
    SetupHandedOff(SetupAction),
}
const DEVIN_PROVIDER: &str = "acp-devin";
const LOGIN_CHECK_INTERVAL: Duration = Duration::from_secs(5);
const BUSY_CHECK_INTERVAL: Duration = Duration::from_millis(300);

#[derive(Clone, Copy, PartialEq, Eq)]
enum CheckKind {
    Full,
    SignIn,
    AfterLogin,
}

struct ProviderCheck {
    provider: String,
    kind: CheckKind,
    refresh_catalog: bool,
    next: Instant,
    deadline: Instant,
}

impl ProviderCheck {
    fn new(provider: &str, kind: CheckKind, now: Instant) -> Self {
        let timeout = match kind {
            CheckKind::SignIn => 75,
            CheckKind::Full | CheckKind::AfterLogin => 180,
        };
        Self {
            provider: provider.into(),
            kind,
            refresh_catalog: kind == CheckKind::Full,
            next: now,
            deadline: now + Duration::from_secs(timeout),
        }
    }

    fn retry_delay(&self, result: &Result<Outcome>) -> Option<Duration> {
        match result {
            Err(error) if engine_busy(error) => Some(BUSY_CHECK_INTERVAL),
            Ok(Outcome::Checked(report, _))
                if self.kind == CheckKind::AfterLogin && report.authenticated != Some(true) =>
            {
                Some(LOGIN_CHECK_INTERVAL)
            }
            _ => None,
        }
    }
}

fn enqueue_check(queue: &mut VecDeque<ProviderCheck>, check: ProviderCheck) {
    if let Some(queued) = queue
        .iter_mut()
        .find(|queued| queued.provider == check.provider)
    {
        // Keep the Terminal watch alive when the user requests a fresh result.
        if queued.kind == CheckKind::AfterLogin && check.kind != CheckKind::AfterLogin {
            queued.next = check.next;
            queued.refresh_catalog |= check.refresh_catalog;
        } else {
            let mut check = check;
            check.refresh_catalog |= queued.refresh_catalog;
            *queued = check;
        }
    } else {
        queue.push_back(check);
    }
}

fn observes_terminal_sign_in(provider: &str) -> bool {
    matches!(
        provider,
        DEVIN_PROVIDER | "claude" | "codex" | "cursor" | "grok"
    )
}

struct Reply {
    accounts: bool,
    provider: String,
    generation: u64,
    result: Result<Outcome>,
}
pub(super) struct Panel {
    engine: SharedEngine,
    editors: HashMap<String, Editor>,
    accounts: accounts::Accounts,
    native_editors: NativeUiEditors,
    workers: worker_owner::WorkerOwner,
    sender: mpsc::SyncSender<Reply>,
    receiver: mpsc::Receiver<Reply>,
    pending: Option<String>,
    active: String,
    check_queue: VecDeque<ProviderCheck>,
    pending_check: Option<ProviderCheck>,
    queued_acp_sign_in: Option<String>,
    pending_setup: bool,
    last_clock_refresh: Instant,
    enabled: bool,
    pickers: Vec<Task<()>>,
    _poll: Task<()>,
}
fn secret(name: &str) -> bool {
    let name = name.to_ascii_uppercase();
    ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"]
        .iter()
        .any(|part| name.contains(part))
}
impl Panel {
    pub fn new(
        engine: SharedEngine,
        native_editors: NativeUiEditors,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        let owner_window = window.window_handle();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                if crate::main_window_poll::update_visible_or_owner(
                    owner_window,
                    &this,
                    cx,
                    |this, window, cx| this.poll(window, cx),
                )
                .is_err()
                {
                    break;
                }
            }
        });
        Self {
            engine,
            editors: HashMap::new(),
            accounts: Default::default(),
            native_editors,
            workers: Default::default(),
            sender,
            receiver,
            pending: None,
            active: String::new(),
            check_queue: Default::default(),
            queued_acp_sign_in: None,
            pending_setup: false,
            pending_check: None,
            last_clock_refresh: Instant::now(),
            enabled: true,
            pickers: Vec::new(),
            _poll: poll,
        }
    }
    pub fn select(
        &mut self,
        provider: &str,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.enabled = enabled;
        self.active = provider.into();
        self.accounts.select(provider);
        self.ensure_editor(provider, window, cx);
        if !self.editors[provider].loaded && self.editors[provider].load_requested {
            self.start(provider, Request::Load, cx);
        }
    }

    fn ensure_editor(&mut self, provider: &str, window: &mut Window, cx: &mut Context<Self>) {
        if !self.editors.contains_key(provider) {
            let key = provider.to_owned();
            let path =
                cx.new(|cx| InputState::new(window, cx).placeholder("Automatic: search PATH"));
            let subscription = cx.subscribe_in(&path, window, move |this, _, event, window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.edited(&key, window, cx);
                }
            });
            self.editors.insert(
                provider.into(),
                Editor {
                    path,
                    variables: Vec::new(),
                    saved_path: String::new(),
                    saved_environment: BTreeMap::new(),
                    baseline: "unconfigured".into(),
                    generation: 0,
                    loaded: false,
                    needs_approval: false,
                    load_requested: true,
                    notice: String::new(),
                    report: None,
                    catalog: None,
                    checked: None,
                    failed: false,
                    lease: self.native_editors.editor(),
                    _subscriptions: vec![subscription],
                },
            );
        }
    }
    pub fn queue_acp_sign_in(
        &mut self,
        provider: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.acp_setup_pending() {
            return;
        }
        self.ensure_editor(provider, window, cx);
        self.queued_acp_sign_in = Some(provider.to_owned());
        cx.notify();
    }

    pub fn acp_setup_pending(&self) -> bool {
        self.pending_setup || self.queued_acp_sign_in.is_some()
    }

    pub fn acp_setup_notice(&self, provider: &str) -> Option<&str> {
        let editor = self.editors.get(provider)?;
        if editor.failed
            || editor.notice.starts_with("Handed off")
            || editor.notice.starts_with("Check sign-in again")
        {
            Some(&editor.notice)
        } else {
            editor.report.as_ref()?.status_note.as_deref()
        }
    }

    pub fn check_acp_sign_in(
        &mut self,
        provider: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.ensure_editor(provider, window, cx);
        self.request_check(provider, CheckKind::SignIn, cx);
    }

    pub fn check_all(&mut self, providers: &[String], window: &mut Window, cx: &mut Context<Self>) {
        for provider in providers {
            self.ensure_editor(provider, window, cx);
            self.request_check(provider, CheckKind::Full, cx);
        }
    }

    fn request_check(&mut self, provider: &str, kind: CheckKind, cx: &mut Context<Self>) {
        if let Some(editor) = self.editors.get_mut(provider)
            && !editor.loaded
        {
            editor.load_requested = true;
        }
        enqueue_check(
            &mut self.check_queue,
            ProviderCheck::new(provider, kind, Instant::now()),
        );
        cx.notify();
    }

    pub fn refresh_acp_sign_in_on_open(
        &mut self,
        provider: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.check_status(provider).is_none()
            && self.editors.get(provider).is_none_or(|editor| {
                !editor.failed
                    && editor
                        .checked
                        .is_none_or(|at| at.elapsed() >= Duration::from_secs(60))
            })
        {
            self.check_acp_sign_in(provider, window, cx);
        }
    }

    pub fn checking_all(&self) -> bool {
        self.check_queue
            .iter()
            .chain(&self.pending_check)
            .any(|check| check.refresh_catalog)
    }

    fn check_status(&self, provider: &str) -> Option<&'static str> {
        if let Some(check) = self
            .pending_check
            .as_ref()
            .filter(|check| check.provider == provider)
        {
            return Some(if check.refresh_catalog {
                "Checking provider…"
            } else {
                "Checking sign-in…"
            });
        }
        let check = self
            .check_queue
            .iter()
            .find(|check| check.provider == provider)?;
        match check.kind {
            CheckKind::AfterLogin if check.next > Instant::now() => Some("Waiting for sign-in…"),
            _ => Some("Check queued…"),
        }
    }

    pub fn summary(&self, provider: &str) -> String {
        let Some(editor) = self.editors.get(provider) else {
            return "Not checked".into();
        };
        if editor.needs_approval {
            return "Imported settings need review".into();
        }
        if let Some(status) = self.check_status(provider) {
            return status.into();
        }
        if editor.failed {
            return "Check unavailable".into();
        }
        if let Some(report) = &editor.report {
            let status = match report.authenticated {
                Some(true) => "Signed in",
                Some(false) => "Sign in required",
                None => "Sign-in unverified",
            };
            return [
                Some(status.to_owned()),
                report.version.clone(),
                report.account.clone(),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" · ");
        }
        if editor.checked.is_some() {
            "Managed configuration checked; sign-in not verified".into()
        } else {
            "Not checked".into()
        }
    }
    /// The sidebar dot's color and tooltip, as Swift's SettingsProviderStatus.
    pub fn status_dot(&self, provider: &str, enabled: bool) -> (&'static str, u32) {
        const TERTIARY: u32 = 0x696c71;
        if !enabled {
            return ("Off", TERTIARY);
        }
        let Some(editor) = self.editors.get(provider) else {
            return ("Not checked", TERTIARY);
        };
        if let Some(status) = self.check_status(provider) {
            return (status, TERTIARY);
        }
        if editor.failed {
            return ("Unavailable", 0xff3b30);
        }
        match editor.report.as_ref().map(|report| report.authenticated) {
            Some(Some(true)) => ("Ready", 0x34c759),
            Some(Some(false)) => ("Not signed in", 0xff9500),
            Some(None) => ("Sign-in unverified", TERTIARY),
            _ => ("Not checked", TERTIARY),
        }
    }
    /// The last check found the provider installed but signed out, which
    /// Swift's General pane reports as not ready yet.
    pub fn needs_setup(&self, provider: &str) -> bool {
        self.editors
            .get(provider)
            .and_then(|editor| editor.report.as_ref())
            .is_some_and(|report| report.authenticated == Some(false))
    }
    pub fn last_checked(&self) -> String {
        self.editors
            .values()
            .filter_map(|editor| editor.checked)
            .max()
            .map(|checked| {
                format!(
                    "Last checked {} minutes ago",
                    checked.elapsed().as_secs() / 60
                )
            })
            .unwrap_or_else(|| "Not checked yet".into())
    }
    fn variable(
        &self,
        provider: &str,
        name: &str,
        value: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Variable {
        let id = uuid::Uuid::new_v4().to_string();
        let revealed = !secret(name);
        let name = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("NAME")
                .default_value(name)
        });
        let value = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("value")
                .default_value(value)
        });
        let subscriptions = [&name, &value]
            .into_iter()
            .enumerate()
            .map(|(index, input)| {
                let provider = provider.to_owned();
                let row_id = id.clone();
                cx.subscribe_in(input, window, move |this, _, event, window, cx| {
                    if matches!(event, InputEvent::Change) {
                        if index == 0
                            && let Some(editor) = this.editors.get_mut(&provider)
                            && let Some(row) =
                                editor.variables.iter_mut().find(|row| row.id == row_id)
                        {
                            row.revealed = !secret(&row.name.read(cx).value());
                        }
                        this.edited(&provider, window, cx);
                    }
                })
            })
            .collect();
        Variable {
            id,
            name,
            value,
            revealed,
            _subscriptions: subscriptions,
        }
    }
    fn edited(&mut self, provider: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.accounts.cancel_queued_for_edit(provider);
        if let Some(editor) = self.editors.get_mut(provider) {
            editor.generation = editor.generation.wrapping_add(1);
            for row in &editor.variables {
                let masked = !row.revealed;
                row.value
                    .update(cx, |input, cx| input.set_masked(masked, window, cx));
            }
            let dirty = editor.dirty(cx);
            editor.lease.set_dirty(dirty);
        }
        cx.notify();
    }
    fn load_snapshot(
        &mut self,
        provider: &str,
        snapshot: Snapshot,
        replace: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let path = snapshot
            .executable
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default();
        let rows = if replace {
            snapshot
                .environment
                .iter()
                .map(|(name, value)| self.variable(provider, name, value, window, cx))
                .collect()
        } else {
            Vec::new()
        };
        if let Some(editor) = self.editors.get_mut(provider) {
            editor.needs_approval = snapshot.imported;
            editor.baseline = snapshot.baseline;
            editor.saved_path = path.clone();
            editor.saved_environment = snapshot.environment;
            editor.loaded = true;
            editor.report = None;
            editor.catalog = None;
            editor.checked = None;
            if replace {
                editor
                    .path
                    .update(cx, |input, cx| input.set_value(path, window, cx));
                editor.variables = rows;
                for row in &editor.variables {
                    row.value
                        .update(cx, |input, cx| input.set_masked(!row.revealed, window, cx));
                }
            }
            let dirty = editor.dirty(cx);
            editor.lease.set_dirty(dirty);
            editor.notice = if editor.needs_approval {
                "Imported preferences are unapproved. Review them, then Save to approve their executable and environment, or Discard Imported Values.".into()
            } else if dirty {
                "Saved; newer changes remain unsaved.".into()
            } else {
                "Saved settings loaded.".into()
            };
        }
        cx.notify();
    }
    fn start(&mut self, provider: &str, request: Request, cx: &mut Context<Self>) {
        if self.pending.is_some() || !self.workers.can_start() {
            return;
        }
        let Some(editor) = self.editors.get_mut(provider) else {
            return;
        };
        let generation = editor.generation;
        let baseline = editor.baseline.clone();
        let loading = matches!(&request, Request::Load);
        let setup = matches!(&request, Request::Setup { .. });
        // Account operations own their own notice. In particular, the automatic
        // metadata-only account load must not replace the configuration load
        // acknowledgement (or an imported-values/unsaved-changes warning).
        if let Some(notice) = configuration_request_notice(&request) {
            editor.notice = notice.into();
        }
        let custody = matches!(&request, Request::Setup { .. } | Request::Accounts(_))
            .then(|| editor.lease.pending_native_action());
        let engine = self.engine.clone();
        let sender = self.sender.clone();
        let provider = provider.to_owned();
        let selected = provider.clone();
        let accounts = matches!(&request, Request::Accounts(_));
        if self.workers.spawn(move |admission| {
            let _custody = custody;
            let result = (|| -> Result<Outcome> {
                anyhow::ensure!(admission.allowed(), "Settings are closing");
                match request {
                    Request::Accounts(request) => {
                        accounts::execute(&engine, &provider, request, &|| admission.allowed())
                            .map(Outcome::Accounts)
                    }
                    Request::Load => Ok(Outcome::Loaded(
                        try_state(&engine)?.native_provider_configuration(&provider)?,
                    )),
                    Request::Save {
                        baseline,
                        path,
                        environment,
                    } => {
                        let mut owner = try_state(&engine)?;
                        anyhow::ensure!(admission.allowed(), "Settings are closing");
                        let path = expand_path(&path)?;
                        let plan = owner.prepare_native_provider_configuration(
                            &provider,
                            &baseline,
                            path.as_deref(),
                            environment,
                        )?;
                        anyhow::ensure!(admission.allowed(), "Settings are closing");
                        Ok(Outcome::Saved(
                            owner.apply_native_provider_configuration(plan)?,
                        ))
                    }
                    Request::Setup { action, baseline } => {
                        let helper = std::env::current_exe()?;
                        let mut handoff = {
                            let owner = try_state(&engine)?;
                            anyhow::ensure!(
                                owner.native_provider_configuration(&provider)?.baseline
                                    == baseline,
                                "Provider configuration changed; reload before setup"
                            );
                            owner.prepare_native_provider_setup(&provider, action, &helper)?
                        };
                        super::provider_setup_terminal::hand_off(&mut handoff, &helper, &|| {
                            admission.allowed()
                        })?;
                        Ok(Outcome::SetupHandedOff(action))
                    }
                    Request::Check { .. } if provider == "antigravity" => {
                        let count = try_state(&engine)?
                            .native_key_accounts("antigravity")?
                            .len();
                        Ok(Outcome::ManagedChecked(count))
                    }
                    Request::Check { refresh_catalog } => {
                        let plan = {
                            let owner = try_state(&engine)?;
                            let snapshot = owner.native_provider_configuration(&provider)?;
                            if snapshot.baseline != baseline || snapshot.imported {
                                return Ok(Outcome::ReloadForCheck(snapshot));
                            }
                            owner.prepare_native_provider_check(&provider)?
                        };
                        let report = plan.run(&|| admission.allowed())?;
                        let catalog = if refresh_catalog {
                            checked_catalog(&engine, &provider, &|| admission.allowed())
                        } else {
                            None
                        };
                        Ok(Outcome::Checked(report, catalog))
                    }
                }
            })();
            let _ = sender.send(Reply {
                accounts,
                provider,
                generation,
                result,
            });
        }) {
            if loading {
                if let Some(editor) = self.editors.get_mut(&selected) {
                    editor.load_requested = false;
                }
            }
            self.pending = Some(selected);
            self.pending_setup = setup;
        } else {
            let error = anyhow::anyhow!("Settings worker could not start; nothing was changed.");
            if accounts {
                self.account_error(&selected, &error);
            } else if let Some(editor) = self.editors.get_mut(&selected) {
                editor.notice = error.to_string();
            }
        }
        cx.notify();
    }
    fn poll(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.workers.poll();
        self.flush_account_actions(cx);
        if self.last_clock_refresh.elapsed() >= Duration::from_secs(30)
            && self.editors.values().any(|editor| editor.checked.is_some())
        {
            self.last_clock_refresh = Instant::now();
            cx.notify();
        }
        if self.pending.is_none()
            && self
                .editors
                .get(&self.active)
                .is_some_and(|editor| !editor.loaded && editor.load_requested)
        {
            let provider = self.active.clone();
            self.start(&provider, Request::Load, cx);
        }
        if self.pending.is_none()
            && self.workers.can_start()
            && let Some(provider) = self.queued_acp_sign_in.clone()
            && let Some(editor) = self.editors.get(&provider)
        {
            if editor.loaded || !editor.load_requested {
                self.queued_acp_sign_in = None;
                if editor.loaded {
                    let baseline = editor.baseline.clone();
                    self.start(
                        &provider,
                        Request::Setup {
                            action: SetupAction::SignIn,
                            baseline,
                        },
                        cx,
                    );
                }
            } else {
                self.start(&provider, Request::Load, cx);
            }
        }
        if self.pending.is_none()
            && let Some(provider) = self
                .editors
                .iter()
                .find(|(provider, editor)| editor.loaded && self.accounts.needs_load(provider))
                .map(|(provider, _)| provider.clone())
        {
            self.start(&provider, Request::Accounts(accounts::Request::Load), cx);
        }
        self.pickers.retain(|task| !task.is_ready());
        while let Ok(reply) = self.receiver.try_recv() {
            self.pending = None;
            self.pending_setup = false;
            let check = self.pending_check.take();
            if self.workers.closed() {
                continue;
            }
            let unchanged = self
                .editors
                .get(&reply.provider)
                .is_some_and(|editor| editor.generation == reply.generation);
            if let Some(check) = check {
                if unchanged {
                    self.accept_check(check, reply.result, window, cx);
                }
                cx.notify();
                continue;
            }
            match reply.result {
                Ok(Outcome::Accounts(outcome)) => {
                    self.apply_accounts(&reply.provider, outcome, unchanged, window, cx)
                }
                Ok(Outcome::Loaded(snapshot)) => {
                    self.load_snapshot(&reply.provider, snapshot, unchanged, window, cx);
                }
                Ok(Outcome::Saved(snapshot)) => {
                    self.load_snapshot(&reply.provider, snapshot, unchanged, window, cx)
                }
                Ok(Outcome::SetupHandedOff(action)) => {
                    let watch_sign_in = action == SetupAction::SignIn
                        && unchanged
                        && observes_terminal_sign_in(&reply.provider);
                    if watch_sign_in {
                        self.request_check(&reply.provider, CheckKind::AfterLogin, cx);
                    }
                    if let Some(editor) = self.editors.get_mut(&reply.provider) {
                        editor.failed = false;
                        editor.notice = if watch_sign_in {
                            "Handed off to Terminal. Coincide will check for sign-in automatically."
                                .into()
                        } else {
                            "Handed off to the setup terminal. Check again after finishing there."
                                .into()
                        };
                    }
                }
                Ok(
                    Outcome::Checked(_, _)
                    | Outcome::ManagedChecked(_)
                    | Outcome::ReloadForCheck(_),
                ) => {}
                Err(error) => {
                    if reply.accounts {
                        self.account_error(&reply.provider, &error);
                    } else if let Some(editor) = self.editors.get_mut(&reply.provider) {
                        editor.load_requested = !editor.loaded && engine_busy(&error);
                        editor.failed = !engine_busy(&error);
                        editor.notice = if editor.load_requested {
                            String::new()
                        } else {
                            error.to_string()
                        };
                    }
                }
            }
            cx.notify();
        }
        self.poll_checks(cx);
    }

    fn accept_check(
        &mut self,
        mut check: ProviderCheck,
        result: Result<Outcome>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let now = Instant::now();
        if let Ok(Outcome::ReloadForCheck(snapshot)) = result {
            self.load_snapshot(&check.provider, snapshot, true, window, cx);
            check.next = now;
            enqueue_check(&mut self.check_queue, check);
            return;
        }
        let retry = check.retry_delay(&result);
        let editor = self
            .editors
            .get_mut(&check.provider)
            .expect("check has an editor");
        match result {
            Ok(Outcome::Checked(report, catalog)) => {
                editor.failed = false;
                if let Some(catalog) = catalog.filter(|value| value["state"] == "ready") {
                    editor.catalog = Some(catalog);
                } else if editor.catalog.is_none()
                    && report.models.is_empty()
                    && let Some(previous) = &editor.report
                    && !previous.models.is_empty()
                {
                    editor.catalog = Some(
                        json!({"provider":check.provider,"state":"ready","models":previous.models}),
                    );
                }
                editor.checked = Some(now);
                if retry.is_none() {
                    editor.notice = report
                        .status_note
                        .clone()
                        .unwrap_or_else(|| "Check finished.".into());
                }
                editor.report = Some(report);
                check.refresh_catalog = false;
            }
            Ok(Outcome::ManagedChecked(accounts)) => {
                editor.failed = false;
                editor.checked = Some(now);
                editor.notice = format!(
                    "{accounts} API-key accounts saved. The runtime and keys have not been verified."
                );
            }
            Err(error) if !engine_busy(&error) => {
                editor.failed = true;
                editor.notice = error.to_string();
            }
            Err(_) | Ok(_) => {}
        }
        if let Some(delay) = retry {
            check.next = now + delay;
            if check.next < check.deadline {
                // Preserve a request that arrived while this probe was running.
                if let Some(queued) = self
                    .check_queue
                    .iter_mut()
                    .find(|queued| queued.provider == check.provider)
                {
                    if check.kind == CheckKind::AfterLogin {
                        check.next = queued.next;
                        check.refresh_catalog |= queued.refresh_catalog;
                        *queued = check;
                    }
                } else {
                    self.check_queue.push_back(check);
                }
            } else {
                self.expire_check(&check);
            }
        }
        cx.notify();
    }

    fn expire_check(&mut self, check: &ProviderCheck) {
        if let Some(editor) = self.editors.get_mut(&check.provider) {
            if check.kind == CheckKind::AfterLogin {
                editor.notice = "Check sign-in again after finishing in Terminal.".into();
            } else {
                editor.failed = true;
                editor.notice =
                    "The provider check timed out while waiting to start. Check again.".into();
            }
        }
    }

    fn poll_checks(&mut self, cx: &mut Context<Self>) {
        let now = Instant::now();
        for index in (0..self.check_queue.len()).rev() {
            if self.check_queue[index].deadline <= now {
                let check = self.check_queue.remove(index).expect("valid check index");
                self.expire_check(&check);
                cx.notify();
            }
        }
        if self.pending.is_some() || !self.workers.can_start() {
            return;
        }
        let Some(index) = self
            .check_queue
            .iter()
            .enumerate()
            .filter(|(_, check)| check.next <= now)
            .min_by_key(|(_, check)| check.refresh_catalog)
            .map(|(index, _)| index)
        else {
            return;
        };
        let provider = self.check_queue[index].provider.clone();
        let editor = self
            .editors
            .get_mut(&provider)
            .expect("queued check has an editor");
        if editor.needs_approval || editor.dirty(cx) {
            self.check_queue.remove(index);
            editor.failed = true;
            editor.notice = "Save or review provider settings before checking sign-in.".into();
            cx.notify();
        } else if editor.loaded {
            let refresh_catalog = self.check_queue[index].refresh_catalog;
            self.start(&provider, Request::Check { refresh_catalog }, cx);
            if self.pending.is_some() {
                self.pending_check = self.check_queue.remove(index);
            }
        } else if editor.load_requested {
            // Leave time for other providers while a busy engine blocks this load.
            self.check_queue[index].next = now + BUSY_CHECK_INTERVAL;
            self.start(&provider, Request::Load, cx);
        } else {
            self.check_queue.remove(index);
            cx.notify();
        }
    }

    fn save(&mut self, provider: &str, cx: &mut Context<Self>) {
        let Some(editor) = self.editors.get(provider) else {
            return;
        };
        match editor.values(cx) {
            Ok((path, environment)) => self.start(
                provider,
                Request::Save {
                    baseline: editor.baseline.clone(),
                    path,
                    environment,
                },
                cx,
            ),
            Err(error) => {
                if let Some(editor) = self.editors.get_mut(provider) {
                    editor.notice = error.to_string();
                }
                cx.notify();
            }
        }
    }
    fn discard(&mut self, provider: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.discard_accounts(provider, window, cx);
        let Some(editor) = self.editors.get(provider) else {
            return;
        };
        if editor.needs_approval {
            let baseline = editor.baseline.clone();
            self.start(
                provider,
                Request::Save {
                    baseline,
                    path: String::new(),
                    environment: BTreeMap::new(),
                },
                cx,
            );
            return;
        }
        let snapshot = Snapshot {
            executable: (!editor.saved_path.is_empty()).then(|| PathBuf::from(&editor.saved_path)),
            environment: editor.saved_environment.clone(),
            baseline: editor.baseline.clone(),
            approved: editor.loaded,
            imported: false,
        };
        self.load_snapshot(provider, snapshot, true, window, cx);
    }
    fn choose(&mut self, provider: &str, window: &mut Window, cx: &mut Context<Self>) {
        if !self.workers.begin_picker() {
            return;
        }
        let Some(editor) = self.editors.get(provider) else {
            self.workers.finish_picker();
            return;
        };
        let generation = editor.generation;
        let custody = editor.lease.pending_native_action();
        let provider = provider.to_owned();
        let picker_window = window.window_handle();
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Choose provider executable".into()),
        });
        let task = cx.spawn_in(window, async move |this, cx| {
            let result: Result<_> = async { picker.await? }.await;
            let _custody = custody;
            let _ = crate::main_window_poll::complete_native_picker(
                picker_window,
                &this,
                cx,
                |this, window, cx| {
                    if !this.workers.finish_picker() {
                        return;
                    }
                    if let Ok(Some(paths)) = result {
                        if let Some(path) = paths.first() {
                            if let Some(editor) = this
                                .editors
                                .get(&provider)
                                .filter(|editor| editor.generation == generation)
                            {
                                editor.path.update(cx, |input, cx| {
                                    input.set_value(path.to_string_lossy().into_owned(), window, cx)
                                });
                                this.edited(&provider, window, cx);
                            }
                        }
                    }
                    cx.notify();
                },
                |this, cx| {
                    this.workers.finish_picker();
                    cx.notify();
                },
            );
        });
        self.pickers.push(task);
    }
    pub fn native_action_custody(&self) -> NativeUiEditLease {
        self.native_editors.editor().pending_native_action()
    }
    pub fn dirty_provider(&self, cx: &App) -> Option<String> {
        self.editors
            .iter()
            .find(|(_, editor)| editor.dirty(cx))
            .map(|(provider, _)| provider.clone())
            .or_else(|| self.accounts.dirty_provider(cx))
    }
    pub fn has_pending_write(&self) -> bool {
        self.accounts.has_review()
            || self.accounts.has_queued_action()
            || self.accounts.has_pending_names()
            || self.queued_acp_sign_in.is_some()
            || (self.pending.is_some() && self.pending_check.is_none())
            || self.pickers.iter().any(|task| !task.is_ready())
    }
    pub fn account_revision(&self) -> u64 {
        self.accounts.revision
    }
    pub fn is_selected(&self, provider: &str) -> bool {
        self.active == provider
    }
    pub fn catalogs(&self) -> Vec<Value> {
        self.editors
            .iter()
            .filter_map(|(provider, editor)| {
                editor.catalog.clone().or_else(|| {
                    editor.report.as_ref().map(
                    |report| json!({"provider":provider,"state":"ready","models":report.models}),
                )
                })
            })
            .collect()
    }
    pub fn render_part(&mut self, part: Part, cx: &mut Context<Self>) -> AnyElement {
        if matches!(part, Part::Accounts) {
            return self.render_accounts(cx);
        }
        let provider = self.active.clone();
        let Some(editor) = self.editors.get(&provider) else {
            return div().child("Select a provider.").into_any_element();
        };
        let busy = self.pending.is_some();
        let dirty = editor.dirty(cx);
        let needs_approval = editor.needs_approval;
        let loaded = editor.loaded;
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
            .border_1()
            .border_color(cx.theme().border)
            .rounded(px(10.));
        match part {
            Part::Accounts => unreachable!("accounts are rendered above"),
            Part::Status => {
                let check_provider = provider.clone();
                let reload_provider = provider.clone();
                let status = self.summary(&provider);
                pane = pane
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .gap_2()
                            .child(div().flex_1().child(status))
                            .child(
                                Button::new("provider-check-again")
                                    .label("Check Again")
                                    .small()
                                    .disabled(!self.enabled || dirty || needs_approval)
                                    .tooltip(if dirty || needs_approval {
                                        "Save changes before checking"
                                    } else {
                                        "Check this provider’s installation and sign-in"
                                    })
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if this.active != check_provider {
                                            return;
                                        }
                                        this.request_check(&check_provider, CheckKind::Full, cx);
                                    })),
                            ),
                    )
                    .when_some(editor.report.as_ref(), |pane, report| {
                        let location = report.executable.clone();
                        pane.child(div().text_sm().child(format!(
                            "Version: {}",
                            report.version.as_deref().unwrap_or("Not reported")
                        )))
                        .child(
                            div()
                                .text_sm()
                                .child(format!("Location: {}", report.executable.display())),
                        )
                        .child(
                            Button::new("provider-reveal-executable")
                                .label("Show in File Manager")
                                .small()
                                .ghost()
                                .on_click(move |_, _, cx| cx.reveal_path(&location)),
                        )
                        .when_some(report.account.as_ref(), |pane, account| {
                            pane.child(format!("Account: {account}"))
                        })
                        .when_some(
                            report.integrations.as_ref(),
                            |pane, integrations| {
                                pane.child(format!(
                                    "Connected integrations reported: {integrations}"
                                ))
                            },
                        )
                    })
                    .when_some(editor.checked, |pane, checked| {
                        pane.child(div().text_xs().child(if checked.elapsed().as_secs() < 60 {
                            "Last checked just now".into()
                        } else {
                            format!(
                                "Last checked {} minutes ago",
                                checked.elapsed().as_secs() / 60
                            )
                        }))
                    })
                    .when(
                        !matches!(
                            editor.notice.as_str(),
                            "Saved settings loaded." | "Check finished." | ""
                        ),
                        |pane| pane.child(div().text_xs().child(editor.notice.clone())),
                    )
                    .child(
                        div().flex().justify_start().child(
                            Button::new("provider-config-reload")
                                .label("Reload Saved Settings")
                                .small()
                                .ghost()
                                .disabled(busy || dirty)
                                .tooltip(if dirty {
                                    "Discard changes before reloading saved settings"
                                } else {
                                    "Read current saved settings again"
                                })
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if this.active != reload_provider {
                                        return;
                                    }
                                    this.start(&reload_provider, Request::Load, cx);
                                })),
                        ),
                    );
            }
            Part::Executable => {
                let key = provider.clone();
                pane = pane
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("Executable"))
                    .child(
                        div()
                            .text_xs()
                            .child(if provider == "antigravity" {
                                "Select the Antigravity ACP server and save to approve it and its adjacent helper."
                            } else {
                                "Leave empty to find the command-line tool automatically."
                            }),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(Input::new(&editor.path).small().flex_1())
                            .child(
                                Button::new("provider-choose-executable")
                                    .label("Choose…")
                                    .small()
                                    .disabled(busy)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.choose(&key, window, cx)
                                    })),
                            ),
                    );
                if provider == "antigravity" && cfg!(target_os = "macos") {
                    pane = pane.child(
                        Button::new("provider-find-antigravity")
                            .label("Find installed ACP server")
                            .small()
                            .ghost()
                            .disabled(busy || !loaded)
                            .on_click(cx.listener(|this, _, window, cx| {
                                let platform = if cfg!(target_arch = "aarch64") { "darwin-arm64" } else { "darwin-x64" };
                                let found = std::env::var_os("HOME").map(PathBuf::from)
                                    .and_then(|home| managed_antigravity_executable(&home, platform));
                                if let Some(editor) = this.editors.get_mut("antigravity") {
                                    if let Some(path) = found {
                                        editor.path.update(cx, |input, cx| input.set_value(path.to_string_lossy().into_owned(), window, cx));
                                        this.edited("antigravity", window, cx);
                                    } else {
                                        editor.notice = "No installed ACP server was found. Choose the server file manually.".into();
                                    }
                                }
                                cx.notify();
                            })),
                    );
                }
            }
            Part::Environment => {
                pane = pane
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("Environment Variables"),
                    )
                    .child("Added only to this provider’s processes. Sensitive values are hidden.");
                for row in &editor.variables {
                    let id = row.id.clone();
                    let remove = id.clone();
                    let key = provider.clone();
                    let reveal_key = provider.clone();
                    pane =
                        pane.child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(Input::new(&row.name).w(px(180.)))
                                .child("=")
                                .child(Input::new(&row.value).flex_1())
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "provider-env-reveal-{id}"
                                    )))
                                    .icon(if row.revealed {
                                        gpui_kit::assets::IconName::EyeOff
                                    } else {
                                        gpui_kit::assets::IconName::Eye
                                    })
                                    .ghost()
                                    .compact()
                                    .accessibility_label(if row.revealed {
                                        "Hide value"
                                    } else {
                                        "Show value"
                                    })
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if let Some(editor) = this.editors.get_mut(&reveal_key) {
                                            if let Some(row) =
                                                editor.variables.iter_mut().find(|row| row.id == id)
                                            {
                                                row.revealed = !row.revealed;
                                                row.value.update(cx, |input, cx| {
                                                    input.set_masked(!row.revealed, window, cx)
                                                });
                                            }
                                        }
                                        cx.notify();
                                    })),
                                )
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "provider-env-remove-{remove}"
                                    )))
                                    .icon(gpui_kit::assets::IconName::Minus)
                                    .ghost()
                                    .compact()
                                    .accessibility_label("Remove variable")
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if let Some(editor) = this.editors.get_mut(&key) {
                                            editor.variables.retain(|row| row.id != remove);
                                        }
                                        this.edited(&key, window, cx);
                                    })),
                                ),
                        )
                }
                let key = provider.clone();
                pane = pane.child(
                    Button::new("provider-env-add")
                        .label("Add Variable")
                        .disabled(!loaded || editor.variables.len() >= 128)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            let row = this.variable(&key, "", "", window, cx);
                            if let Some(editor) = this.editors.get_mut(&key) {
                                editor.variables.push(row);
                            }
                            this.edited(&key, window, cx);
                        })),
                );
                let save = provider.clone();
                let discard = provider.clone();
                pane = pane
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                Button::new("provider-config-save")
                                    .label(if needs_approval {
                                        "Approve Imported Values"
                                    } else {
                                        "Save Changes"
                                    })
                                    .disabled(!loaded || (!dirty && !needs_approval) || busy)
                                    .on_click(
                                        cx.listener(move |this, _, _, cx| this.save(&save, cx)),
                                    ),
                            )
                            .child(
                                Button::new("provider-config-discard")
                                    .label(if needs_approval {
                                        "Discard Imported Values"
                                    } else {
                                        "Discard Changes"
                                    })
                                    .disabled((!dirty && !needs_approval) || busy)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.discard(&discard, window, cx)
                                    })),
                            ),
                    )
                    .child(div().text_sm().child(editor.notice.clone()));
            }
            Part::Setup => {
                pane = pane.child(div().font_weight(FontWeight::SEMIBOLD).child("Setup"));
                for command in coincide_core::provider_configuration::setup_commands(
                    &provider,
                    (!editor.saved_path.is_empty())
                        .then(|| std::path::Path::new(&editor.saved_path)),
                ) {
                    let label = command.label;
                    let action = command.action;
                    let setup_provider = provider.clone();
                    let copy = command.display.clone();
                    pane = pane.child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .flex_1()
                                    .child(label)
                                    .child(div().text_sm().child(command.display)),
                            )
                            .child(
                                Button::new(SharedString::from(format!(
                                    "provider-setup-copy-{label}"
                                )))
                                .label("Copy")
                                .on_click(move |_, _, cx| {
                                    cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()))
                                }),
                            )
                            .child(
                                Button::new(SharedString::from(format!(
                                    "provider-setup-run-{label}"
                                )))
                                .label("Run in Terminal")
                                .disabled(!loaded || dirty || needs_approval || busy)
                                .on_click(cx.listener(
                                    move |this, _, _, cx| {
                                        let provider = this.active.clone();
                                        if let Some(editor) = this.editors.get(&provider) {
                                            let baseline = editor.baseline.clone();
                                            this.start(
                                                &provider,
                                                Request::Setup { action, baseline },
                                                cx,
                                            );
                                        }
                                    },
                                )),
                            ),
                    );
                }
                let url = setup_website(&provider);
                pane = pane
                    .child(
                        Button::new("provider-setup-website")
                            .label("Open Setup Website")
                            .on_click(move |_, _, cx| cx.open_url(url)),
                    )
                    .child(if provider == "lithos" {
                        "Add a Lithos API key account for hosted models, or start a local Lithos server."
                    } else if provider == "antigravity" {
                        "Add a Gemini API key account and select it in the composer."
                    } else {
                        "After installing or signing in, choose Check Again."
                    });
            }
        }
        pane.into_any_element()
    }
    pub fn request_shutdown(&mut self) {
        self.check_queue.clear();
        self.queued_acp_sign_in = None;
        self.accounts.cancel_review();
        self.workers.close();
    }
    pub fn shutdown_status(&mut self) -> worker_owner::ShutdownStatus {
        while self.receiver.try_recv().is_ok() {}
        self.workers.status()
    }
}
// Existing Core owns each model worker and its proof lifecycle. The UI waits only
// on its bounded request ID, and never synthesizes readiness from version text.
fn checked_catalog(
    engine: &SharedEngine,
    provider: &str,
    allowed: &impl Fn() -> bool,
) -> Option<Value> {
    if !matches!(provider, "codex" | "claude") || !allowed() {
        return None;
    }
    let mut catalog = call(engine, "agent.models.refresh", json!({"provider":provider})).ok()?;
    let id = catalog["requestId"].as_str()?.to_owned();
    let deadline = Instant::now() + Duration::from_secs(25);
    while catalog["state"] == "loading" && allowed() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
        match call(engine, "agent.models.status", json!({"requestId":id})) {
            Ok(current) => catalog = current,
            Err(error) if engine_busy(&error) => {}
            Err(_) => return None,
        }
    }
    Some(catalog)
}

fn expand_path(path: &str) -> Result<Option<PathBuf>> {
    if path.is_empty() {
        return Ok(None);
    }
    if let Some(rest) = path.strip_prefix("~/") {
        let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
            .context("Home directory is unavailable")?;
        return Ok(Some(PathBuf::from(home).join(rest)));
    }
    Ok(Some(PathBuf::from(path)))
}
fn managed_antigravity_executable(home: &std::path::Path, platform: &str) -> Option<PathBuf> {
    if !home.is_absolute() || !matches!(platform, "darwin-arm64" | "darwin-x64") {
        return None;
    }
    ["Coincide Rust", "Coincide"]
        .into_iter()
        .map(|app| {
            home.join("Library/Application Support")
                .join(app)
                .join("tools/antigravity-acp")
                .join(platform)
                .join("current/agy_acp_server.par")
        })
        .find(|path| path.is_file() && path.with_file_name("localharness_external").is_file())
}
fn setup_website(provider: &str) -> &'static str {
    match provider {
        "claude" => "https://claude.com/product/claude-code",
        "codex" => "https://developers.openai.com/codex/cli",
        "cursor" => "https://cursor.com/cli",
        "grok" => "https://x.ai/cli",
        "opencode" => "https://opencode.ai",
        "lithos" => "https://console.lithosai.cloud/",
        "antigravity" => "https://antigravity.google/docs/ide/extensions/acp",
        _ => "https://antigravity.google",
    }
}

// Returning None keeps account replies/errors in the account editor and leaves
// the independently source-bound configuration acknowledgement intact.
fn configuration_request_notice(request: &Request) -> Option<&'static str> {
    match request {
        Request::Accounts(_) | Request::Check { .. } => None,
        Request::Load => Some("Loading saved settings…"),
        Request::Save { .. } => Some("Saving settings…"),
        Request::Setup { .. } => Some("Opening setup in a separate terminal…"),
    }
}

#[cfg(test)]
#[::core::prelude::v1::test]
fn provider_checks_deduplicate_without_losing_terminal_watch_or_other_providers() {
    let now = Instant::now();
    let mut queue = VecDeque::new();
    enqueue_check(
        &mut queue,
        ProviderCheck::new("claude", CheckKind::AfterLogin, now),
    );
    enqueue_check(
        &mut queue,
        ProviderCheck::new("cursor", CheckKind::Full, now),
    );
    queue[0].next = now + LOGIN_CHECK_INTERVAL;
    enqueue_check(
        &mut queue,
        ProviderCheck::new("claude", CheckKind::Full, now),
    );
    assert_eq!(queue.len(), 2);
    assert!(queue[0].kind == CheckKind::AfterLogin);
    assert_eq!(queue[0].deadline, now + Duration::from_secs(180));
    assert_eq!(queue[0].next, now);
    assert!(queue[0].refresh_catalog);
    assert_eq!(queue[1].provider, "cursor");
}

#[cfg(test)]
#[::core::prelude::v1::test]
fn provider_checks_retry_contention_and_watch_for_terminal_confirmation() {
    let now = Instant::now();
    let manual = ProviderCheck::new(DEVIN_PROVIDER, CheckKind::SignIn, now);
    let handoff = ProviderCheck::new("claude", CheckKind::AfterLogin, now);
    let busy = Err(anyhow::Error::new(EngineBusy));
    assert_eq!(manual.retry_delay(&busy), Some(BUSY_CHECK_INTERVAL));
    let status = |authenticated| {
        Ok(Outcome::Checked(
            ProbeReport {
                authenticated,
                ..Default::default()
            },
            None,
        ))
    };
    assert_eq!(manual.retry_delay(&status(Some(false))), None);
    assert_eq!(
        handoff.retry_delay(&status(Some(false))),
        Some(LOGIN_CHECK_INTERVAL)
    );
    assert_eq!(
        handoff.retry_delay(&status(None)),
        Some(LOGIN_CHECK_INTERVAL)
    );
    assert_eq!(handoff.retry_delay(&status(Some(true))), None);
}

#[cfg(all(test, unix))]
mod provider_check_headless_tests {
    use super::Panel;
    use coincide_core::native_ui_edits::NativeUiEditors;
    use gpui_kit::{AppContext, Context, Entity, IntoElement, Render, TestAppContext, Window, div};
    use std::{
        collections::BTreeMap,
        time::{Duration, Instant},
    };
    #[gpui_kit::test]
    fn manual_checks_survive_an_engine_busy_reply(cx: &mut TestAppContext) {
        use std::{
            fs,
            os::unix::fs::PermissionsExt,
            sync::{Arc, Mutex},
        };

        struct Harness(Entity<Panel>);
        impl Render for Harness {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                div()
            }
        }

        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let executable = root.path().join("claude-fixture");
        fs::write(
        &executable,
        "#!/bin/sh\ncase \"$1\" in\n  --version) echo '2.1.42' ;;\n  auth) echo '{\"loggedIn\":false}'; exit 1 ;;\n  *) exit 2 ;;\nesac\n",
    ).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();

        let mut engine = coincide_core::api::Engine::new(
            coincide_core::store::Store::open(&root.path().join("state.sqlite")).unwrap(),
        );
        let baseline = engine
            .native_provider_configuration("claude")
            .unwrap()
            .baseline;
        let config = engine
            .prepare_native_provider_configuration(
                "claude",
                &baseline,
                Some(&executable),
                BTreeMap::new(),
            )
            .unwrap();
        engine.apply_native_provider_configuration(config).unwrap();
        let engine = Arc::new(Mutex::new(engine));
        cx.update(gpui_kit::init);
        let (view, cx) = cx.add_window_view(|window, cx| {
            Harness(cx.new(|cx| Panel::new(engine.clone(), NativeUiEditors::default(), window, cx)))
        });
        let panel = cx.update(|_, cx| view.read(cx).0.clone());

        let guard = engine.lock().unwrap();
        cx.update(|window, cx| {
            panel.update(cx, |panel, cx| {
                panel.check_acp_sign_in("claude", window, cx);
                assert_eq!(panel.summary("claude"), "Check queued…");
                panel.poll(window, cx);
                assert!(panel.pending.is_some());
                panel.check_acp_sign_in("claude", window, cx);
                assert_eq!(panel.check_queue.len(), 1);
            });
        });
        let until = Instant::now() + Duration::from_secs(5);
        loop {
            let retried = cx.update(|window, cx| {
                panel.update(cx, |panel, cx| {
                    panel.poll(window, cx);
                    panel.pending.is_none() && panel.check_queue.len() == 1
                })
            });
            if retried {
                break;
            }
            assert!(Instant::now() < until, "busy provider load did not return");
            std::thread::sleep(Duration::from_millis(5));
        }
        drop(guard);

        let until = Instant::now() + Duration::from_secs(5);
        loop {
            let status = cx.update(|window, cx| {
                panel.update(cx, |panel, cx| {
                    panel.poll(window, cx);
                    panel.summary("claude")
                })
            });
            if status.starts_with("Sign in required") {
                break;
            }
            assert!(Instant::now() < until, "provider check ended at {status}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

#[cfg(test)]
mod antigravity_discovery_tests {
    use super::managed_antigravity_executable;
    use std::fs;

    #[::core::prelude::v1::test]
    fn suggests_only_an_existing_server_and_helper_without_reading_accounts() {
        let home = tempfile::tempdir().unwrap();
        let base = home.path().join(
            "Library/Application Support/Coincide/tools/antigravity-acp/darwin-arm64/current",
        );
        fs::create_dir_all(&base).unwrap();
        let server = base.join("agy_acp_server.par");
        fs::write(&server, b"fixture server; never executed").unwrap();
        assert!(managed_antigravity_executable(home.path(), "darwin-arm64").is_none());
        fs::write(base.join("localharness_external"), b"fixture helper").unwrap();
        assert_eq!(
            managed_antigravity_executable(home.path(), "darwin-arm64"),
            Some(server)
        );
        assert!(managed_antigravity_executable(home.path(), "unexpected").is_none());
        assert_eq!(fs::read_dir(&base).unwrap().count(), 2);
    }
}
