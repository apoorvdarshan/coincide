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
    collections::{BTreeMap, HashMap},
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
    Check,
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
    ManagedChecked(usize),
    SetupHandedOff,
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
    check_queue: std::collections::VecDeque<String>,
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
                    lease: self.native_editors.editor(),
                    _subscriptions: vec![subscription],
                },
            );
        }
        if !self.editors[provider].loaded && self.editors[provider].load_requested {
            self.start(provider, Request::Load, cx);
        }
    }
    pub fn check_all(&mut self, providers: &[String], window: &mut Window, cx: &mut Context<Self>) {
        if self.has_pending_write() || !self.check_queue.is_empty() {
            return;
        }
        let selected = self.active.clone();
        let enabled = self.enabled;
        for provider in providers {
            self.select(provider, true, window, cx);
            self.check_queue.push_back(provider.clone());
        }
        self.active = selected;
        self.enabled = enabled;
        cx.notify();
    }
    pub fn checking_all(&self) -> bool {
        !self.check_queue.is_empty() || self.pending.is_some()
    }
    pub fn summary(&self, provider: &str) -> String {
        let Some(editor) = self.editors.get(provider) else {
            return "Not checked".into();
        };
        if editor.needs_approval {
            return "Imported settings need review".into();
        }
        if self.pending.as_deref() == Some(provider) {
            return editor.notice.clone();
        }
        if let Some(report) = &editor.report {
            let status = match report.authenticated {
                Some(true) => "Signed in",
                Some(false) => "Sign in required",
                None => "Sign-in not checked",
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
        if matches!(&request, Request::Check) {
            editor.report = None;
            editor.catalog = None;
            editor.checked = None;
        }
        editor.notice = match &request {
            Request::Load => "Loading saved settings…",
            Request::Accounts(_) => "Updating provider accounts…",
            Request::Save { .. } => "Saving settings…",
            Request::Check => "Checking provider…",
            Request::Setup { .. } => "Opening setup in a separate terminal…",
        }
        .into();
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
                        Ok(Outcome::SetupHandedOff)
                    }
                    Request::Check if provider == "antigravity" => {
                        let status = call(&engine, "providers.antigravity.status", json!({}))?;
                        Ok(Outcome::ManagedChecked(
                            status["accounts"].as_object().map_or(0, |rows| rows.len()),
                        ))
                    }
                    Request::Check => {
                        let plan = {
                            let owner = try_state(&engine)?;
                            anyhow::ensure!(
                                owner.native_provider_configuration(&provider)?.baseline
                                    == baseline,
                                "Provider configuration changed; reload before checking"
                            );
                            owner.prepare_native_provider_check(&provider)?
                        };
                        let report = plan.run(&|| admission.allowed())?;
                        let catalog = checked_catalog(&engine, &provider, &|| admission.allowed());
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
        } else if let Some(editor) = self.editors.get_mut(&selected) {
            editor.notice = "Settings worker could not start; nothing was changed.".into();
        }
        cx.notify();
    }
    fn poll(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.workers.poll();
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
            && let Some(provider) = self
                .editors
                .iter()
                .find(|(provider, editor)| editor.loaded && self.accounts.needs_load(provider))
                .map(|(provider, _)| provider.clone())
        {
            self.start(&provider, Request::Accounts(accounts::Request::Load), cx);
        }
        if self.pending.is_none() {
            if let Some(provider) = self.check_queue.front().cloned() {
                if self.editors.get(&provider).is_some_and(|editor| {
                    editor.dirty(cx)
                        || editor.needs_approval
                        || (!editor.loaded && !editor.load_requested)
                }) {
                    self.check_queue.pop_front();
                } else if self
                    .editors
                    .get(&provider)
                    .is_some_and(|editor| editor.loaded)
                {
                    self.check_queue.pop_front();
                    self.start(&provider, Request::Check, cx);
                } else {
                    self.start(&provider, Request::Load, cx);
                }
            }
        }
        self.pickers.retain(|task| !task.is_ready());
        while let Ok(reply) = self.receiver.try_recv() {
            self.pending = None;
            if self.workers.closed() {
                continue;
            }
            let unchanged = self
                .editors
                .get(&reply.provider)
                .is_some_and(|editor| editor.generation == reply.generation);
            match reply.result {
                Ok(Outcome::Accounts(outcome)) => {
                    self.apply_accounts(&reply.provider, outcome, unchanged, window, cx)
                }
                Ok(Outcome::Loaded(snapshot)) | Ok(Outcome::Saved(snapshot)) => {
                    self.load_snapshot(&reply.provider, snapshot, unchanged, window, cx)
                }
                Ok(Outcome::SetupHandedOff) => {
                    if let Some(editor) = self.editors.get_mut(&reply.provider) {
                        editor.notice = "Handed off to a separate terminal. Installation and sign-in are not verified; choose Check Again after finishing there.".into();
                        editor.report = None;
                        editor.catalog = None;
                        editor.checked = None;
                    }
                }
                Ok(Outcome::ManagedChecked(accounts)) => {
                    if let Some(editor) = self.editors.get_mut(&reply.provider) {
                        editor.checked = Some(Instant::now());
                        editor.notice = format!(
                            "Managed runtime configuration checked: {accounts} accounts. Sign-in has not been verified."
                        );
                    }
                }
                Ok(Outcome::Checked(report, catalog)) => {
                    if let Some(editor) = self.editors.get_mut(&reply.provider) {
                        editor.report = Some(report);
                        editor.catalog = catalog;
                        editor.checked = Some(Instant::now());
                        editor.notice = "Check finished.".into();
                    }
                }
                Err(error) => {
                    if reply.accounts {
                        self.account_error(&reply.provider, &error);
                    }
                    if let Some(editor) = self.editors.get_mut(&reply.provider) {
                        editor.load_requested = !editor.loaded && engine_busy(&error);
                        editor.notice = error.to_string();
                    }
                }
            }
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
            || !self.check_queue.is_empty()
            || self.pending.is_some()
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
            .p_3()
            .border_1()
            .border_color(rgb(0x29303d))
            .rounded_md();
        match part {
            Part::Accounts => unreachable!("accounts are rendered above"),
            Part::Status => {
                let check_provider = provider.clone();
                let reload_provider = provider.clone();
                let status = editor
                    .report
                    .as_ref()
                    .map(|report| match report.authenticated {
                        Some(true) => "Signed in",
                        Some(false) => "Sign in required",
                        None => "Version checked; sign-in not checked",
                    })
                    .unwrap_or("Not checked");
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
                                    .disabled(
                                        !loaded || !self.enabled || busy || dirty || needs_approval,
                                    )
                                    .tooltip(if dirty || needs_approval {
                                        "Save changes before checking"
                                    } else {
                                        "Check this provider’s installation and sign-in"
                                    })
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if this.active != check_provider {
                                            return;
                                        }
                                        this.start(&check_provider, Request::Check, cx);
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
                                .on_click(move |_, _, cx| cx.reveal_path(&location)),
                        )
                        .when_some(report.status_note.as_ref(), |pane, note| {
                            pane.child(div().text_sm().child(note.clone()))
                        })
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
                    .child(div().text_sm().child(editor.notice.clone()))
                    .child(
                        Button::new("provider-config-reload")
                            .label("Reload Saved Settings")
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
                    );
            }
            Part::Executable => {
                let key = provider.clone();
                pane = pane
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("Executable"))
                    .child("Leave empty to find the command-line tool on your PATH.")
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(Input::new(&editor.path).flex_1())
                            .child(
                                Button::new("provider-choose-executable")
                                    .label("Choose…")
                                    .disabled(busy)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.choose(&key, window, cx)
                                    })),
                            ),
                    );
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
                    .child("After installing or signing in, choose Check Again.");
            }
        }
        pane.into_any_element()
    }
    pub fn request_shutdown(&mut self) {
        self.check_queue.clear();
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
fn setup_website(provider: &str) -> &'static str {
    match provider {
        "claude" => "https://claude.com/product/claude-code",
        "codex" => "https://developers.openai.com/codex/cli",
        "cursor" => "https://cursor.com/cli",
        "grok" => "https://x.ai/cli",
        "opencode" => "https://opencode.ai",
        _ => "https://antigravity.google",
    }
}
