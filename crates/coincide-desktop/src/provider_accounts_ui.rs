//! Account drafts and typed native actions share the provider panel's single
//! worker owner, shutdown custody and generation-aware result application.
use super::*;
use coincide_core::provider_configuration::{
    NativeAccountAuthentication as Auth, NativeProviderAccount, PreparedLegacyCodexRemoval,
    PreparedNativeAccountRemoval,
};
#[derive(Clone, PartialEq, Eq)]
struct Row {
    native: NativeProviderAccount,
    legacy: bool,
}
impl std::ops::Deref for Row {
    type Target = NativeProviderAccount;
    fn deref(&self) -> &Self::Target {
        &self.native
    }
}
pub(super) enum RemovalPlan {
    Native(PreparedNativeAccountRemoval),
    Legacy(PreparedLegacyCodexRemoval),
}
impl RemovalPlan {
    fn name(&self) -> &str {
        match self {
            Self::Native(plan) => plan.name(),
            Self::Legacy(plan) => plan.name(),
        }
    }
    fn conversation_count(&self) -> usize {
        match self {
            Self::Native(plan) => plan.conversation_count(),
            Self::Legacy(plan) => plan.conversation_count(),
        }
    }
}
#[derive(Clone)]
pub(super) struct Snapshot {
    rows: Vec<Row>,
    cleanup: usize,
}
struct Draft {
    name: Entity<InputState>,
    key: Entity<InputState>,
    admin_key: Entity<InputState>,
    saved_name: String,
    lease: NativeUiEditLease,
    _subscriptions: Vec<Subscription>,
}
impl Draft {
    fn dirty(&self, cx: &App) -> bool {
        self.name.read(cx).value().as_ref() != self.saved_name
            || !self.key.read(cx).value().is_empty()
            || !self.admin_key.read(cx).value().is_empty()
    }
}
#[derive(Default)]
struct Editor {
    rows: Vec<Row>,
    drafts: HashMap<String, Draft>,
    loaded: bool,
    load_requested: bool,
    cleanup: usize,
    notice: String,
    reports: HashMap<String, ProbeReport>,
    admin_reports: HashMap<String, coincide_core::provider_configuration::NativeAdminUsageReport>,
}
struct Review {
    provider: String,
    plan: RemovalPlan,
    _custody: NativeUiEditLease,
}
#[derive(Default)]
pub(super) struct Accounts {
    pub(super) revision: u64,
    editors: HashMap<String, Editor>,
    review: Option<Review>,
    legacy_sign_in: Option<String>,
    action_order: action_order::Order,
    pending_names: std::collections::VecDeque<(String, String)>,
    programmatic_names: HashMap<gpui::EntityId, String>,
}
pub(super) enum Request {
    Load,
    CodexAuth {
        id: String,
        revision: String,
        login: bool,
        legacy: bool,
    },
    CreateLegacy {
        name: String,
    },
    Create {
        login: bool,
        name: String,
        variable: String,
    },
    Rename {
        id: String,
        revision: String,
        name: String,
        login: bool,
        legacy: bool,
    },
    Auth {
        id: String,
        revision: String,
        login: bool,
        variable: Option<String>,
    },
    SaveKey {
        id: String,
        revision: String,
        value: String,
    },
    SaveAdmin {
        id: String,
        revision: String,
        value: String,
    },
    RemoveAdmin {
        id: String,
        revision: String,
    },
    ReadAdmin {
        id: String,
        revision: String,
    },
    RemoveKey {
        id: String,
        revision: String,
    },
    Enroll {
        id: String,
        revision: String,
    },
    Setup {
        id: String,
        revision: String,
    },
    Check {
        id: String,
        revision: String,
    },
    Review {
        id: String,
        revision: String,
        legacy: bool,
        custody: NativeUiEditLease,
    },
    Remove {
        plan: RemovalPlan,
        custody: NativeUiEditLease,
    },
    Cleanup,
}
pub(super) enum Outcome {
    Renamed {
        snapshot: Snapshot,
        id: String,
        source_revision: String,
        revision: String,
        name: String,
        provider_baseline: String,
    },
    AdminSaved {
        snapshot: Snapshot,
        id: String,
    },
    AdminReport {
        snapshot: Snapshot,
        id: String,
        report: coincide_core::provider_configuration::NativeAdminUsageReport,
    },
    Snapshot {
        snapshot: Snapshot,
        notice: String,
        clear_key: Option<String>,
    },
    Review {
        plan: RemovalPlan,
        custody: NativeUiEditLease,
    },
    Checked {
        snapshot: Snapshot,
        id: String,
        report: ProbeReport,
    },
}
fn snapshot(engine: &SharedEngine, provider: &str) -> Result<Snapshot> {
    let owner = try_state(engine)?;
    snapshot_from_owner(&owner, provider)
}
fn snapshot_from_owner(owner: &Engine, provider: &str) -> Result<Snapshot> {
    let mut rows = owner
        .native_provider_accounts(provider)?
        .into_iter()
        .map(|native| Row {
            native,
            legacy: false,
        })
        .collect::<Vec<_>>();
    if provider == "codex" {
        let legacy = owner.native_legacy_codex_accounts()?;
        let mut combined = legacy
            .into_iter()
            .filter(|row| !rows.iter().any(|existing| existing.id == row.id))
            .map(|row| Row {
                native: NativeProviderAccount {
                    id: row.id,
                    provider: "codex".into(),
                    name: row.name,
                    revision: row.revision,
                    authentication: Auth::Login,
                    key_variable: None,
                    has_key: false,
                    has_admin_key: false,
                },
                legacy: true,
            })
            .collect::<Vec<_>>();
        combined.append(&mut rows);
        let order = owner.native_codex_account_order()?;
        combined.sort_by_key(|row| {
            order
                .iter()
                .position(|id| id == &row.id)
                .unwrap_or(usize::MAX)
        });
        rows = combined;
    }
    Ok(Snapshot {
        rows,
        cleanup: owner.native_provider_account_cleanup_pending(provider)?,
    })
}
fn done(
    engine: &SharedEngine,
    provider: &str,
    notice: impl Into<String>,
    clear_key: Option<String>,
) -> Result<Outcome> {
    Ok(Outcome::Snapshot {
        snapshot: snapshot(engine, provider)?,
        notice: notice.into(),
        clear_key,
    })
}
fn enroll(
    engine: &SharedEngine,
    id: &str,
    revision: &str,
    allowed: &impl Fn() -> bool,
) -> Result<()> {
    let plan = try_state(engine)?.prepare_native_codex_key_enrollment(id, revision)?;
    let receipt = plan.run(allowed)?;
    anyhow::ensure!(allowed(), "Account settings are closing");
    try_state(engine)?.apply_native_codex_key_enrollment(receipt)?;
    Ok(())
}
pub(super) fn execute(
    engine: &SharedEngine,
    provider: &str,
    request: Request,
    allowed: &impl Fn() -> bool,
) -> Result<Outcome> {
    anyhow::ensure!(allowed(), "Account settings are closing");
    match request {
        Request::Load => done(engine, provider, "", None),
        Request::CodexAuth {
            id,
            revision,
            login,
            legacy,
        } => {
            anyhow::ensure!(
                provider == "codex",
                "Codex authentication choice belongs to another provider"
            );
            let plan = try_state(engine)?
                .prepare_native_codex_auth_change(&id, &revision, login, legacy)?;
            anyhow::ensure!(allowed(), "Account settings are closing");
            try_state(engine)?.apply_native_codex_auth_change(plan)?;
            done(
                engine,
                provider,
                "Authentication method changed. Messages and drafts were kept. Check or sign in to this account before sending.",
                None,
            )
        }
        Request::CreateLegacy { name } => {
            anyhow::ensure!(
                provider == "codex",
                "Legacy account belongs to another provider"
            );
            coincide_core::api::call(
                engine,
                "providers.codex.profiles.create",
                json!({"name":name}),
            )?;
            done(
                engine,
                provider,
                "ChatGPT account added. Sign in explicitly before using it.",
                None,
            )
        }
        Request::SaveAdmin {
            id,
            revision,
            value,
        } => {
            try_state(engine)?.save_native_account_admin_key(provider, &id, &revision, &value)?;
            Ok(Outcome::AdminSaved {
                snapshot: snapshot(engine, provider)?,
                id,
            })
        }
        Request::RemoveAdmin { id, revision } => {
            try_state(engine)?.remove_native_account_admin_key(provider, &id, &revision)?;
            done(
                engine,
                provider,
                "Admin key removed. Private cleanup is retryable.",
                None,
            )
        }
        Request::ReadAdmin { id, revision } => {
            let plan =
                try_state(engine)?.prepare_native_account_admin_usage(provider, &id, &revision)?;
            let report = plan.run(allowed)?;
            anyhow::ensure!(allowed(), "Account settings are closing");
            Ok(Outcome::AdminReport {
                snapshot: snapshot(engine, provider)?,
                id,
                report,
            })
        }
        Request::Create {
            login,
            name,
            variable,
        } => {
            if login {
                try_state(engine)?.create_native_login_account(provider, &name)?;
            } else {
                try_state(engine)?.create_native_key_account(provider, &name, &variable)?;
            }
            done(
                engine,
                provider,
                if login {
                    "Account added. Sign in to this account separately."
                } else {
                    "Account added. Save its API key to use it."
                },
                None,
            )
        }
        Request::Rename {
            id,
            revision,
            name,
            login,
            legacy,
        } => {
            let mut owner = try_state(engine)?;
            let saved_revision = if legacy {
                anyhow::ensure!(
                    provider == "codex",
                    "Legacy account belongs to another provider"
                );
                let plan = owner.prepare_native_legacy_codex_rename(&id, &revision, &name)?;
                owner.apply_native_legacy_codex_rename(plan)?
            } else if login {
                owner
                    .rename_native_login_account(provider, &id, &revision, &name)?
                    .revision
            } else {
                owner
                    .rename_native_key_account(provider, &id, &revision, &name)?
                    .revision
            };
            let provider_baseline = owner.native_provider_configuration(provider)?.baseline;
            Ok(Outcome::Renamed {
                snapshot: snapshot_from_owner(&owner, provider)?,
                id,
                source_revision: revision,
                revision: saved_revision,
                name: name.trim().into(),
                provider_baseline,
            })
        }
        Request::Auth {
            id,
            revision,
            login,
            variable,
        } => {
            try_state(engine)?.set_native_provider_account_auth(
                provider,
                &id,
                &revision,
                if login { "login" } else { "apiKey" },
                variable.as_deref(),
            )?;
            done(
                engine,
                provider,
                "Account authentication preference saved.",
                None,
            )
        }
        Request::SaveKey {
            id,
            revision,
            value,
        } => {
            let saved =
                try_state(engine)?.save_native_account_key(provider, &id, &revision, &value)?;
            let notice = if provider == "codex" {
                match enroll(engine,&id,&saved.account.revision,allowed) {Ok(())=>"Key saved and enrolled locally. Provider authentication has not been verified.".into(),Err(error)=>format!("Key saved. Apply saved key to retry Codex enrollment: {error}")}
            } else {
                "Key saved in the system secret store. Authentication has not been verified.".into()
            };
            let cleanup = if saved.cleanup_pending {
                try_state(engine)?
                    .retry_native_account_secret_cleanup(provider)
                    .is_err()
            } else {
                false
            };
            let notice = if cleanup {
                format!("{notice} Private cleanup is pending; choose Retry cleanup.")
            } else {
                notice
            };
            done(engine, provider, notice, Some(id))
        }
        Request::RemoveKey { id, revision } => {
            try_state(engine)?.remove_native_account_key(provider, &id, &revision)?;
            let notice = match try_state(engine)?.retry_native_account_secret_cleanup(provider) {
                Ok(_) => "Key removed.",
                Err(_) => "Key revoked. System secret cleanup is pending; choose Retry cleanup.",
            };
            done(engine, provider, notice, Some(id))
        }
        Request::Enroll { id, revision } => {
            enroll(engine, &id, &revision, allowed)?;
            done(
                engine,
                provider,
                "Saved key enrolled locally. Provider authentication has not been verified.",
                None,
            )
        }
        Request::Setup { id, revision } => {
            let helper = std::env::current_exe()?;
            let mut handoff = try_state(engine)?
                .prepare_native_login_account_setup(provider, &id, &revision, &helper)?;
            super::super::provider_setup_terminal::hand_off(&mut handoff, &helper, allowed)?;
            done(
                engine,
                provider,
                "Sign-in handed off to a separate terminal. Finish there, then choose Check Again.",
                None,
            )
        }
        Request::Check { id, revision } => {
            let probe =
                try_state(engine)?.prepare_native_login_account_check(provider, &id, &revision)?;
            let report = probe.run(allowed)?;
            Ok(Outcome::Checked {
                snapshot: snapshot(engine, provider)?,
                id,
                report,
            })
        }
        Request::Review {
            id,
            revision,
            legacy,
            custody,
        } => {
            let plan = if legacy {
                anyhow::ensure!(
                    provider == "codex",
                    "Legacy account belongs to another provider"
                );
                RemovalPlan::Legacy(
                    try_state(engine)?.prepare_native_legacy_codex_removal(&id, &revision)?,
                )
            } else {
                RemovalPlan::Native(
                    try_state(engine)?
                        .prepare_native_provider_account_removal(provider, &id, &revision)?,
                )
            };
            Ok(Outcome::Review { plan, custody })
        }
        Request::Remove { plan, custody } => {
            let _custody = custody;
            let removed = match plan {
                RemovalPlan::Native(plan) => {
                    try_state(engine)?.apply_native_provider_account_removal(plan)?
                }
                RemovalPlan::Legacy(plan) => {
                    try_state(engine)?.apply_native_legacy_codex_removal(plan)?
                }
            };
            done(
                engine,
                provider,
                format!(
                    "Account removed. {} conversations now use the default account.{}",
                    removed.conversations,
                    if removed.cleanup_pending {
                        " Private cleanup is pending; choose Retry cleanup."
                    } else {
                        ""
                    }
                ),
                None,
            )
        }
        Request::Cleanup => {
            try_state(engine)?.retry_native_account_secret_cleanup(provider)?;
            try_state(engine)?.retry_native_removed_account_cleanup(provider)?;
            done(engine, provider, "Account cleanup completed.", None)
        }
    }
}
impl Accounts {
    pub(super) fn has_queued_action(&self) -> bool {
        self.action_order.has_queued()
    }
    pub(super) fn has_pending_names(&self) -> bool {
        !self.pending_names.is_empty()
    }
    pub(super) fn cancel_queued_for_edit(&mut self, provider: &str) {
        self.action_order.edited(provider);
    }
    pub(super) fn needs_load(&self, provider: &str) -> bool {
        self.editors
            .get(provider)
            .is_none_or(|editor| !editor.loaded && editor.load_requested)
    }
    pub(super) fn select(&mut self, provider: &str) {
        self.editors
            .entry(provider.into())
            .or_insert_with(|| Editor {
                load_requested: true,
                ..Default::default()
            });
    }
    pub(super) fn cancel_review(&mut self) {
        self.review = None;
        self.action_order.cancel();
        self.pending_names.clear();
    }
    pub(super) fn has_review(&self) -> bool {
        self.review.is_some()
    }
    pub(super) fn dirty_provider(&self, cx: &App) -> Option<String> {
        self.review
            .as_ref()
            .map(|review| review.provider.clone())
            .or_else(|| {
                self.editors
                    .iter()
                    .find(|(_, editor)| editor.drafts.values().any(|draft| draft.dirty(cx)))
                    .map(|(provider, _)| provider.clone())
            })
    }
}
impl Panel {
    pub fn set_account_context(&mut self, provider: Option<&str>) {
        self.accounts.action_order.context(provider);
        self.accounts
            .pending_names
            .retain(|(key, _)| Some(key.as_str()) == provider);
    }
    pub(super) fn flush_account_actions(&mut self, cx: &mut Context<Self>) {
        if self.pending.is_some() || !self.workers.can_start() {
            return;
        }
        let provider = self.active.clone();
        if let (Some(accounts), Some(editor)) = (
            self.accounts.editors.get(&provider),
            self.editors.get(&provider),
        ) {
            match self.accounts.action_order.take(
                &provider,
                &accounts.rows,
                &editor.baseline,
                editor.generation,
            ) {
                action_order::Dispatch::Ready(ready) => {
                    let action_order::Ready {
                        provider,
                        request,
                        custody,
                    } = *ready;
                    let _custody = custody;
                    self.start(&provider, super::Request::Accounts(request), cx);
                    return;
                }
                action_order::Dispatch::Stale => {
                    if let Some(editor) = self.accounts.editors.get_mut(&provider) {
                        editor.notice="The queued change was not applied because its account or edits changed. Your draft is retained.".into();
                    }
                    cx.notify();
                }
                action_order::Dispatch::Empty => {}
            }
        }
        if let Some((provider, id)) = self.accounts.pending_names.pop_front() {
            self.commit_account_name(&provider, &id, cx);
        }
    }
    pub fn take_legacy_codex_sign_in(&mut self) -> Option<String> {
        self.accounts.legacy_sign_in.take()
    }
    pub(super) fn account_edited(&mut self, provider: &str, cx: &mut Context<Self>) {
        self.accounts.action_order.edited(provider);
        if let Some(editor) = self.editors.get_mut(provider) {
            editor.generation = editor.generation.wrapping_add(1);
        }
        if let Some(editor) = self.accounts.editors.get_mut(provider) {
            for draft in editor.drafts.values_mut() {
                let dirty = draft.dirty(cx);
                draft.lease.set_dirty(dirty);
            }
        }
        cx.notify();
    }
    fn account_draft(
        &self,
        provider: &str,
        row: &NativeProviderAccount,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Draft {
        let name = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("Account name")
                .default_value(row.name.clone())
        });
        let key = cx.new(|cx| {
            InputState::new(window, cx).placeholder(if row.has_key {
                "Saved key"
            } else {
                "Paste the API key"
            })
        });
        key.update(cx, |input, cx| input.set_masked(true, window, cx));
        let admin_key = cx.new(|cx| {
            InputState::new(window, cx).placeholder(if row.has_admin_key {
                "Saved Admin key"
            } else {
                "Paste an Admin API key"
            })
        });
        admin_key.update(cx, |input, cx| input.set_masked(true, window, cx));
        let mut subscriptions = Vec::new();
        for input in [&name, &key, &admin_key] {
            let provider = provider.to_owned();
            subscriptions.push(cx.subscribe(input, move |this, input, event, cx| {
                if matches!(event, InputEvent::Change) {
                    if let Some(expected) =
                        this.accounts.programmatic_names.remove(&input.entity_id())
                        && input.read(cx).value().as_ref() == expected
                    {
                        return;
                    }
                    this.account_edited(&provider, cx);
                }
            }));
        }
        let provider_key = provider.to_owned();
        let id = row.id.clone();
        subscriptions.push(cx.subscribe(&name, move |this, _, event, cx| {
            if matches!(event, InputEvent::Blur | InputEvent::PressEnter { .. }) {
                this.commit_account_name(&provider_key, &id, cx);
            }
        }));
        let provider_key = provider.to_owned();
        let id = row.id.clone();
        subscriptions.push(cx.subscribe(&key, move |this, _, event, cx| {
            if matches!(event, InputEvent::PressEnter { .. }) {
                this.save_account_key(&provider_key, &id, cx);
            }
        }));
        let provider_key = provider.to_owned();
        let id = row.id.clone();
        subscriptions.push(cx.subscribe(&admin_key, move |this, _, event, cx| {
            if matches!(event, InputEvent::PressEnter { .. }) {
                this.save_account_admin_key(&provider_key, &id, cx);
            }
        }));
        Draft {
            name,
            key,
            admin_key,
            saved_name: row.name.clone(),
            lease: self.native_editors.editor(),
            _subscriptions: subscriptions,
        }
    }
    pub(super) fn apply_accounts(
        &mut self,
        provider: &str,
        outcome: Outcome,
        unchanged: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mut renamed = None;
        let (snapshot, notice, clear_key) = match outcome {
            Outcome::Renamed {
                snapshot,
                id,
                source_revision,
                revision,
                name,
                provider_baseline,
            } => {
                let had_queue = self.accounts.action_order.has_queued();
                let generation = self
                    .editors
                    .get(provider)
                    .map(|editor| editor.generation)
                    .unwrap_or(u64::MAX);
                let accepted = self.accounts.action_order.finish(action_order::Receipt {
                    provider,
                    id: &id,
                    source_revision: &source_revision,
                    revision: &revision,
                    name: &name,
                    baseline: &provider_baseline,
                    rows: &snapshot.rows,
                    generation,
                });
                renamed = Some((id, name));
                let notice = if had_queue && !accepted {
                    "Account name saved. The queued change was not applied because its account or edits changed; your draft is retained."
                } else if accepted {
                    "Account name saved. Applying your queued change…"
                } else {
                    "Account name saved."
                };
                (snapshot, notice.into(), None)
            }
            Outcome::AdminSaved { snapshot, id } => {
                if unchanged
                    && let Some(draft) = self
                        .accounts
                        .editors
                        .get_mut(provider)
                        .and_then(|editor| editor.drafts.get_mut(&id))
                {
                    draft
                        .admin_key
                        .update(cx, |input, cx| input.set_value("", window, cx));
                }
                (
                    snapshot,
                    "Admin key saved for read-only organization reports.".into(),
                    None,
                )
            }
            Outcome::AdminReport {
                snapshot,
                id,
                report,
            } => {
                if let Some(editor) = self.accounts.editors.get_mut(provider) {
                    editor.admin_reports.insert(id, report);
                }
                (snapshot, "Organization report refreshed.".into(), None)
            }
            Outcome::Review { plan, custody } => {
                self.accounts.review = Some(Review {
                    provider: provider.into(),
                    plan,
                    _custody: custody,
                });
                cx.notify();
                return;
            }
            Outcome::Snapshot {
                snapshot,
                notice,
                clear_key,
            } => (snapshot, notice, clear_key),
            Outcome::Checked {
                snapshot,
                id,
                report,
            } => {
                let notice = match report.authenticated {
                    Some(true) => "Signed in to this account.",
                    Some(false) => "Sign in required for this account.",
                    None => "Account checked; sign-in could not be verified.",
                };
                if let Some(editor) = self.accounts.editors.get_mut(provider) {
                    editor.reports.insert(id, report);
                }
                (snapshot, notice.into(), None)
            }
        };
        self.accounts.select(provider);
        let new = snapshot
            .rows
            .iter()
            .filter(|row| !self.accounts.editors[provider].drafts.contains_key(&row.id))
            .map(|row| {
                (
                    row.id.clone(),
                    self.account_draft(provider, row, window, cx),
                )
            })
            .collect::<Vec<_>>();
        let editor = self.accounts.editors.get_mut(provider).unwrap();
        editor.drafts.extend(new);
        for row in &snapshot.rows {
            let draft = editor.drafts.get_mut(&row.id).unwrap();
            let own_name_ack = renamed.as_ref().is_some_and(|(id, name)| {
                id == &row.id
                    && name == &row.name
                    && draft.name.read(cx).value().trim() == name.as_str()
            });
            if (unchanged && draft.name.read(cx).value().as_ref() == draft.saved_name)
                || own_name_ack
            {
                self.accounts
                    .programmatic_names
                    .insert(draft.name.entity_id(), row.name.clone());
                draft.name.update(cx, |input, cx| {
                    input.set_value(row.name.clone(), window, cx)
                });
            }
            draft.saved_name = row.name.clone();
            if unchanged && clear_key.as_deref() == Some(row.id.as_str()) {
                draft
                    .key
                    .update(cx, |input, cx| input.set_value("", window, cx));
            }
            let dirty = draft.dirty(cx);
            draft.lease.set_dirty(dirty);
        }
        let programmatic_names = &mut self.accounts.programmatic_names;
        editor.drafts.retain(|id, draft| {
            let retained = snapshot.rows.iter().any(|row| row.id == *id);
            if !retained {
                programmatic_names.remove(&draft.name.entity_id());
            }
            retained
        });
        self.accounts
            .pending_names
            .retain(|(key, id)| key != provider || snapshot.rows.iter().any(|row| &row.id == id));
        let changed = editor.rows != snapshot.rows || editor.cleanup != snapshot.cleanup;
        editor.rows = snapshot.rows;
        editor.cleanup = snapshot.cleanup;
        editor.loaded = true;
        editor.load_requested = false;
        editor.notice = notice;
        if changed {
            self.accounts.revision = self.accounts.revision.wrapping_add(1);
        }
        cx.notify();
    }
    pub(super) fn account_error(&mut self, provider: &str, error: &anyhow::Error) {
        self.accounts.action_order.cancel_provider(provider);
        self.accounts
            .pending_names
            .retain(|(key, _)| key != provider);
        if let Some(editor) = self.accounts.editors.get_mut(provider) {
            editor.load_requested = engine_busy(error);
            // Initial reads retry in the background. Keep real failures and
            // refused edits visible, but don't flash a lock-contention error
            // while an unopened account list is being loaded.
            editor.notice = if editor.load_requested && !editor.loaded {
                String::new()
            } else {
                error.to_string()
            };
        }
    }
    pub(super) fn discard_accounts(
        &mut self,
        provider: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.accounts.action_order.cancel_provider(provider);
        self.accounts
            .pending_names
            .retain(|(key, _)| key != provider);
        if self
            .accounts
            .review
            .as_ref()
            .is_some_and(|review| review.provider == provider)
        {
            self.accounts.review = None;
        }
        if let Some(editor) = self.accounts.editors.get_mut(provider) {
            for row in &editor.rows {
                if let Some(draft) = editor.drafts.get_mut(&row.id) {
                    draft.name.update(cx, |input, cx| {
                        input.set_value(row.name.clone(), window, cx)
                    });
                    draft
                        .key
                        .update(cx, |input, cx| input.set_value("", window, cx));
                    draft
                        .admin_key
                        .update(cx, |input, cx| input.set_value("", window, cx));
                    draft.saved_name = row.name.clone();
                    draft.lease.set_dirty(false);
                }
            }
        }
    }
    fn discard_account_draft(
        &mut self,
        provider: &str,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.accounts.action_order.cancel_provider(provider);
        self.accounts
            .pending_names
            .retain(|(key, target)| key != provider || target != id);
        if let Some(editor) = self.accounts.editors.get_mut(provider)
            && let Some(row) = editor.rows.iter().find(|row| row.id == id)
            && let Some(draft) = editor.drafts.get_mut(id)
        {
            draft.name.update(cx, |input, cx| {
                input.set_value(row.name.clone(), window, cx)
            });
            draft
                .key
                .update(cx, |input, cx| input.set_value("", window, cx));
            draft
                .admin_key
                .update(cx, |input, cx| input.set_value("", window, cx));
            draft.saved_name = row.name.clone();
            draft.lease.set_dirty(false);
        }
        cx.notify();
    }
    fn account_request(&mut self, provider: &str, request: Request, cx: &mut Context<Self>) {
        if self.pending.is_some() {
            let source = request
                .after_name_target()
                .and_then(|(id, _)| {
                    self.accounts
                        .editors
                        .get(provider)?
                        .rows
                        .iter()
                        .find(|row| row.id == id)
                })
                .cloned();
            let queued = if let (Some(source), Some(editor)) = (source, self.editors.get(provider))
            {
                self.accounts.action_order.enqueue(
                    provider,
                    request,
                    &source,
                    &editor.baseline,
                    editor.generation,
                    editor.lease.pending_native_action(),
                )
            } else {
                false
            };
            if let Some(editor) = self.accounts.editors.get_mut(provider) {
                editor.notice=if queued { "Saving the account name, then applying your change." } else { "A provider action is still finishing. This change was not applied; your edits are retained." }.into();
            }
            cx.notify();
            return;
        }
        if self.accounts.action_order.has_queued() {
            if let Some(editor) = self.accounts.editors.get_mut(provider) {
                editor.notice = "Your earlier change is queued. Wait for it to finish.".into();
            }
            cx.notify();
            return;
        }
        let rename = if let Request::Rename { id, name, .. } = &request {
            self.accounts
                .editors
                .get(provider)
                .and_then(|editor| editor.rows.iter().find(|row| row.id == *id))
                .cloned()
                .map(|source| (source, name.clone()))
        } else {
            None
        };
        if let Request::Check { id, .. } | Request::Setup { id, .. } | Request::CodexAuth { id, .. } =
            &request
            && let Some(editor) = self.accounts.editors.get_mut(provider)
        {
            editor.reports.remove(id);
        }
        self.start(provider, super::Request::Accounts(request), cx);
        if self.pending.as_deref() == Some(provider)
            && let Some((source, name)) = rename
            && let Some(editor) = self.editors.get(provider)
        {
            self.accounts
                .action_order
                .begin(provider, source, &name, &editor.baseline);
        }
    }
    fn commit_account_name(&mut self, provider: &str, id: &str, cx: &mut Context<Self>) {
        if self.pending.is_some() || self.accounts.action_order.has_queued() {
            if !self
                .accounts
                .pending_names
                .iter()
                .any(|(key, target)| key == provider && target == id)
            {
                self.accounts
                    .pending_names
                    .push_back((provider.into(), id.into()));
            }
            return;
        }
        let Some(editor) = self.accounts.editors.get(provider) else {
            return;
        };
        let Some(row) = editor.rows.iter().find(|row| row.id == id) else {
            return;
        };
        let name = editor.drafts[id].name.read(cx).value().to_string();
        if name == row.name {
            return;
        }
        self.account_request(
            provider,
            Request::Rename {
                id: id.into(),
                revision: row.revision.clone(),
                name,
                login: row.authentication == Auth::Login,
                legacy: row.legacy,
            },
            cx,
        );
    }
    fn save_account_key(&mut self, provider: &str, id: &str, cx: &mut Context<Self>) {
        let Some(editor) = self.accounts.editors.get(provider) else {
            return;
        };
        let Some(row) = editor.rows.iter().find(|row| row.id == id) else {
            return;
        };
        let value = editor.drafts[id].key.read(cx).value().to_string();
        if value.trim().is_empty() {
            return;
        }
        self.account_request(
            provider,
            Request::SaveKey {
                id: id.into(),
                revision: row.revision.clone(),
                value,
            },
            cx,
        );
    }
    pub(super) fn render_accounts(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let provider = self.active.clone();
        let work_busy = self.pending.is_some() || !self.workers.can_start();
        let busy =
            work_busy || self.accounts.has_review() || self.accounts.action_order.has_queued();
        let Some(editor) = self.accounts.editors.get(&provider) else {
            return div().child("Loading accounts…").into_any_element();
        };
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_3()
            .p_4()
            .rounded(px(10.))
            .border_1()
            .border_color(cx.theme().border)
            .child(div().font_weight(FontWeight::SEMIBOLD).child("Accounts"))
            .child(
                div().flex().flex_col().gap_1().child("Default").child(
                    div()
                        .text_sm()
                        .child("Uses this provider’s existing command-line credentials."),
                ),
            );
        if let Some(review) = &self.accounts.review
            && review.provider == provider
        {
            let confirm_provider = provider.clone();
            pane=pane.child(div().p_3().border_1().border_color(rgb(0x914a4a)).rounded_md().flex().flex_col().gap_2()
                .child(format!("Remove “{}”?",review.plan.name()))
                .child(format!("Its saved key and private sign-in are removed. {} native conversations continue with this provider’s default account. Unsaved edits for this account are discarded.",review.plan.conversation_count()))
                .child(div().flex().gap_2().child(Button::new("provider-account-remove-confirm").label("Remove Account").disabled(work_busy).on_click(cx.listener(move|this,_,_,cx| {if let Some(review)=this.accounts.review.take(){this.account_request(&confirm_provider,Request::Remove{plan:review.plan,custody:review._custody},cx);}})))
                    .child(Button::new("provider-account-remove-cancel").label("Cancel").disabled(work_busy).on_click(cx.listener(|this,_,_,cx| {this.accounts.review=None;cx.notify();})))));
        }
        for row in &editor.rows {
            let Some(draft) = editor.drafts.get(&row.id) else {
                continue;
            };
            let id = row.id.clone();
            let revision = row.revision.clone();
            let p = provider.clone();
            let key = row.authentication == Auth::ApiKey;
            let legacy = row.legacy;
            let mut card = div()
                .flex()
                .flex_col()
                .gap_2()
                .py_2()
                .border_t_1()
                .border_color(rgb(0x29303d))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(Input::new(&draft.name).flex_1())
                        .child(
                            Button::new(SharedString::from(format!("account-name-save-{id}")))
                                .label("Save name")
                                .disabled(busy || draft.name.read(cx).value().as_ref() == row.name)
                                .on_click(cx.listener({
                                    let p = p.clone();
                                    let id = id.clone();
                                    move |this, _, _, cx| this.commit_account_name(&p, &id, cx)
                                })),
                        )
                        .child(
                            Button::new(SharedString::from(format!("account-remove-{id}")))
                                .label("Remove")
                                .disabled(busy || self.accounts.review.is_some())
                                .on_click(cx.listener({
                                    let p = p.clone();
                                    let id = id.clone();
                                    let revision = revision.clone();
                                    move |this, _, _, cx| {
                                        if let Some(editor) = this.editors.get(&p) {
                                            let custody = editor.lease.pending_native_action();
                                            this.account_request(
                                                &p,
                                                Request::Review {
                                                    id: id.clone(),
                                                    revision: revision.clone(),
                                                    legacy,
                                                    custody,
                                                },
                                                cx,
                                            );
                                        }
                                    }
                                })),
                        ),
                );
            if provider == "codex" {
                card = card.child(self.codex_auth_controls(row, busy, cx));
            }
            if matches!(provider.as_str(), "claude" | "grok" | "opencode") {
                card =
                    card.child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child("Sign in with")
                            .children([(true, "Login"), (false, "API key")].into_iter().map(
                                |(login, label)| {
                                    let p = p.clone();
                                    let id = id.clone();
                                    let revision = revision.clone();
                                    Button::new(SharedString::from(format!(
                                        "account-auth-{id}-{login}"
                                    )))
                                    .label(label)
                                    .disabled(busy || (login == !key))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.account_request(
                                            &p,
                                            Request::Auth {
                                                id: id.clone(),
                                                revision: revision.clone(),
                                                login,
                                                variable: None,
                                            },
                                            cx,
                                        )
                                    }))
                                },
                            )),
                    );
            }
            if key {
                if provider == "opencode" {
                    card = card.child(div().text_sm().child("Key for"));
                    if let Ok(choices) =
                        coincide_core::provider_configuration::native_account_key_choices(&provider)
                    {
                        card =
                            card.child(div().flex().flex_wrap().gap_1().children(
                                choices.iter().map(|(variable, label)| {
                                    let p = p.clone();
                                    let id = id.clone();
                                    let revision = revision.clone();
                                    let variable = variable.to_string();
                                    let selected =
                                        row.key_variable.as_deref() == Some(variable.as_str());
                                    Button::new(SharedString::from(format!(
                                        "account-service-{id}-{variable}"
                                    )))
                                    .label(*label)
                                    .disabled(busy || selected)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.account_request(
                                            &p,
                                            Request::Auth {
                                                id: id.clone(),
                                                revision: revision.clone(),
                                                login: false,
                                                variable: Some(variable.clone()),
                                            },
                                            cx,
                                        )
                                    }))
                                }),
                            ));
                    }
                }
                card = card
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(Input::new(&draft.key).flex_1())
                            .child(
                                Button::new(SharedString::from(format!("account-key-save-{id}")))
                                    .label(if row.has_key { "Replace" } else { "Save" })
                                    .disabled(busy || draft.key.read(cx).value().trim().is_empty())
                                    .on_click(cx.listener({
                                        let p = p.clone();
                                        let id = id.clone();
                                        move |this, _, _, cx| this.save_account_key(&p, &id, cx)
                                    })),
                            )
                            .when(row.has_key, |line| {
                                line.child(
                                    Button::new(SharedString::from(format!(
                                        "account-key-remove-{id}"
                                    )))
                                    .label("Remove Key")
                                    .disabled(busy)
                                    .on_click(cx.listener({
                                        let p = p.clone();
                                        let id = id.clone();
                                        let revision = revision.clone();
                                        move |this, _, _, cx| {
                                            this.account_request(
                                                &p,
                                                Request::RemoveKey {
                                                    id: id.clone(),
                                                    revision: revision.clone(),
                                                },
                                                cx,
                                            )
                                        }
                                    })),
                                )
                            }),
                    )
                    .child(div().text_sm().child(if row.has_key {
                        "Saved key. Authentication has not been verified."
                    } else {
                        "No saved API key."
                    }));
                if admin_eligible(row) {
                    card = card.child(self.admin_controls(&provider, row, draft, busy, cx));
                }
                if provider == "codex" && row.has_key {
                    card = card.child(
                        Button::new(SharedString::from(format!("account-key-enroll-{id}")))
                            .label("Apply saved key")
                            .disabled(busy)
                            .on_click(cx.listener({
                                let p = p.clone();
                                let id = id.clone();
                                let revision = revision.clone();
                                move |this, _, _, cx| {
                                    this.account_request(
                                        &p,
                                        Request::Enroll {
                                            id: id.clone(),
                                            revision: revision.clone(),
                                        },
                                        cx,
                                    )
                                }
                            })),
                    );
                }
            } else if row.legacy {
                let id = id.clone();
                card = card.child(
                    Button::new(SharedString::from(format!("legacy-account-sign-in-{id}")))
                        .label("Sign in with ChatGPT…")
                        .disabled(busy)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.accounts.legacy_sign_in = Some(id.clone());
                            cx.notify();
                        })),
                );
            } else {
                card = card
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                Button::new(SharedString::from(format!("account-sign-in-{id}")))
                                    .label("Sign In…")
                                    .disabled(busy)
                                    .on_click(cx.listener({
                                        let p = p.clone();
                                        let id = id.clone();
                                        let revision = revision.clone();
                                        move |this, _, _, cx| {
                                            this.account_request(
                                                &p,
                                                Request::Setup {
                                                    id: id.clone(),
                                                    revision: revision.clone(),
                                                },
                                                cx,
                                            )
                                        }
                                    })),
                            )
                            .child(
                                Button::new(SharedString::from(format!("account-check-{id}")))
                                    .label("Check Again")
                                    .disabled(busy)
                                    .on_click(cx.listener({
                                        let p = p.clone();
                                        let id = id.clone();
                                        let revision = revision.clone();
                                        move |this, _, _, cx| {
                                            this.account_request(
                                                &p,
                                                Request::Check {
                                                    id: id.clone(),
                                                    revision: revision.clone(),
                                                },
                                                cx,
                                            )
                                        }
                                    })),
                            ),
                    )
                    .child(
                        div().text_sm().child(
                            editor
                                .reports
                                .get(&id)
                                .map(|report| match report.authenticated {
                                    Some(true) => "Signed in",
                                    Some(false) => "Sign in required",
                                    None => "Sign-in not verified",
                                })
                                .unwrap_or("Sign-in not checked"),
                        ),
                    );
            }
            if let Some(note) = editor
                .reports
                .get(&id)
                .and_then(|report| report.status_note.as_ref())
            {
                card = card.child(div().text_sm().child(note.clone()));
            }
            if draft.dirty(cx) {
                let p = p.clone();
                let id = id.clone();
                card = card.child(
                    Button::new(SharedString::from(format!("account-draft-discard-{id}")))
                        .label("Discard edits")
                        .disabled(busy)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.discard_account_draft(&p, &id, window, cx)
                        })),
                );
            }
            pane = pane.child(card);
        }
        let next_name = format!("Account {}", editor.rows.len() + 1);
        let p = provider.clone();
        let login_provider = provider.clone();
        let login_name = next_name.clone();
        let first_variable =
            coincide_core::provider_configuration::native_account_key_choices(&provider)
                .ok()
                .and_then(|choices| choices.first())
                .map(|(key, _)| key.to_string());
        let mut actions = div().flex().gap_2();
        if matches!(provider.as_str(), "claude" | "grok" | "opencode") {
            actions = actions.child(
                Button::new("provider-account-add-login")
                    .label("Add Login Account")
                    .disabled(busy || !editor.loaded)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.account_request(
                            &login_provider,
                            Request::Create {
                                login: true,
                                name: login_name.clone(),
                                variable: String::new(),
                            },
                            cx,
                        )
                    })),
            );
        }
        if provider == "codex" {
            let name = next_name.clone();
            actions = actions.child(
                Button::new("provider-account-add-chatgpt")
                    .label("Add ChatGPT Account")
                    .disabled(busy || !editor.loaded)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.account_request(
                            "codex",
                            Request::CreateLegacy { name: name.clone() },
                            cx,
                        )
                    })),
            );
        }
        if let Some(variable) = first_variable {
            actions = actions.child(
                Button::new("provider-account-add-key")
                    .label("Add API Key Account")
                    .disabled(busy || !editor.loaded)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.account_request(
                            &p,
                            Request::Create {
                                login: false,
                                name: next_name.clone(),
                                variable: variable.clone(),
                            },
                            cx,
                        )
                    })),
            );
        }
        let reload = provider.clone();
        actions = actions.child(
            Button::new("provider-account-reload")
                .label("Reload accounts")
                .disabled(busy)
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.account_request(&reload, Request::Load, cx)
                })),
        );
        if editor.cleanup > 0 {
            let p = provider.clone();
            actions = actions.child(
                Button::new("provider-account-cleanup")
                    .label("Retry cleanup")
                    .disabled(busy)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.account_request(&p, Request::Cleanup, cx)
                    })),
            );
        }
        pane.child(actions)
            .child(div().text_sm().child(editor.notice.clone()))
            .into_any_element()
    }
}

#[path = "provider_admin_ui.rs"]
mod admin_ui;
use admin_ui::admin_eligible;

#[path = "provider_codex_auth_ui.rs"]
mod codex_auth_ui;

#[path = "provider_account_action_order.rs"]
mod action_order;

#[cfg(test)]
mod tests {
    use super::*;
    pub(super) fn fixture() -> (tempfile::TempDir, SharedEngine) {
        let root = tempfile::tempdir().unwrap();
        let engine = std::sync::Arc::new(std::sync::Mutex::new(Engine::new(
            Store::open(&root.path().join("private/state.sqlite")).unwrap(),
        )));
        (root, engine)
    }
    pub(super) fn rows(outcome: Outcome) -> Vec<Row> {
        match outcome {
            Outcome::Snapshot { snapshot, .. } | Outcome::Renamed { snapshot, .. } => snapshot.rows,
            _ => panic!("Expected account snapshot"),
        }
    }
    #[::core::prelude::v1::test]
    fn codex_method_picker_keeps_row_identity_and_does_not_save_or_enroll_a_key() {
        let (_root, engine) = fixture();
        let legacy = rows(
            execute(
                &engine,
                "codex",
                Request::CreateLegacy {
                    name: "Synthetic convertible".into(),
                },
                &|| true,
            )
            .unwrap(),
        )
        .remove(0);
        let converted = rows(
            execute(
                &engine,
                "codex",
                Request::CodexAuth {
                    id: legacy.id.clone(),
                    revision: legacy.revision.clone(),
                    login: false,
                    legacy: true,
                },
                &|| true,
            )
            .unwrap(),
        )
        .remove(0);
        assert_eq!(converted.id, legacy.id);
        assert!(
            !converted.legacy && converted.authentication == Auth::ApiKey && !converted.has_key
        );
        assert!(
            execute(
                &engine,
                "codex",
                Request::CodexAuth {
                    id: legacy.id.clone(),
                    revision: legacy.revision.clone(),
                    login: false,
                    legacy: true
                },
                &|| true
            )
            .is_err()
        );
        let login = rows(
            execute(
                &engine,
                "codex",
                Request::CodexAuth {
                    id: converted.id.clone(),
                    revision: converted.revision.clone(),
                    login: true,
                    legacy: false,
                },
                &|| true,
            )
            .unwrap(),
        )
        .remove(0);
        assert_eq!(login.id, legacy.id);
        assert!(!login.legacy && login.authentication == Auth::Login && !login.has_key);
        assert!(
            try_state(&engine)
                .unwrap()
                .native_legacy_codex_accounts()
                .unwrap()
                .is_empty()
        );
    }
    #[::core::prelude::v1::test]
    fn legacy_rows_keep_existing_api_accounts_through_typed_rename_and_removal() {
        let (_root, engine) = fixture();
        let legacy = rows(
            execute(
                &engine,
                "codex",
                Request::CreateLegacy {
                    name: "Synthetic subscription".into(),
                },
                &|| true,
            )
            .unwrap(),
        )
        .remove(0);
        let combined = rows(
            execute(
                &engine,
                "codex",
                Request::Create {
                    login: false,
                    name: "Synthetic API".into(),
                    variable: "OPENAI_API_KEY".into(),
                },
                &|| true,
            )
            .unwrap(),
        );
        assert_eq!(combined.len(), 2);
        assert_eq!(combined[0].id, legacy.id);
        assert!(combined[0].legacy && !combined[1].legacy);
        let native_id = combined[1].id.clone();
        let renamed = rows(
            execute(
                &engine,
                "codex",
                Request::Rename {
                    id: legacy.id.clone(),
                    revision: legacy.revision.clone(),
                    name: "Renamed subscription".into(),
                    login: true,
                    legacy: true,
                },
                &|| true,
            )
            .unwrap(),
        );
        assert_eq!(renamed[0].id, legacy.id);
        assert_eq!(renamed[0].name, "Renamed subscription");
        let editors = try_state(&engine).unwrap().native_ui_editors();
        let custody = editors.editor().pending_native_action();
        let review = execute(
            &engine,
            "codex",
            Request::Review {
                id: legacy.id.clone(),
                revision: renamed[0].revision.clone(),
                legacy: true,
                custody,
            },
            &|| true,
        )
        .unwrap();
        let Outcome::Review { plan, custody } = review else {
            panic!("Expected reviewed removal")
        };
        let remaining = rows(
            execute(&engine, "codex", Request::Remove { plan, custody }, &|| {
                true
            })
            .unwrap(),
        );
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].id, native_id);
        assert!(!remaining[0].legacy);
    }
    #[::core::prelude::v1::test]
    fn native_account_ui_actions_reach_typed_core_and_preserve_identity_across_auth_change() {
        let (_root, engine) = fixture();
        let created = rows(
            execute(
                &engine,
                "grok",
                Request::Create {
                    login: false,
                    name: "Synthetic UI account".into(),
                    variable: "XAI_API_KEY".into(),
                },
                &|| true,
            )
            .unwrap(),
        );
        let account = &created[0];
        assert!(account.authentication == Auth::ApiKey);
        assert!(!account.has_key);
        let renamed = rows(
            execute(
                &engine,
                "grok",
                Request::Rename {
                    id: account.id.clone(),
                    revision: account.revision.clone(),
                    name: "Renamed UI account".into(),
                    login: false,
                    legacy: false,
                },
                &|| true,
            )
            .unwrap(),
        );
        assert_eq!(renamed[0].id, account.id);
        assert_eq!(renamed[0].name, "Renamed UI account");
        let changed = rows(
            execute(
                &engine,
                "grok",
                Request::Auth {
                    id: account.id.clone(),
                    revision: renamed[0].revision.clone(),
                    login: true,
                    variable: None,
                },
                &|| true,
            )
            .unwrap(),
        );
        assert_eq!(changed[0].id, account.id);
        assert!(changed[0].authentication == Auth::Login);
        assert!(
            execute(
                &engine,
                "grok",
                Request::Rename {
                    id: account.id.clone(),
                    revision: account.revision.clone(),
                    name: "Stale".into(),
                    login: false,
                    legacy: false
                },
                &|| true
            )
            .is_err()
        );
    }
    #[::core::prelude::v1::test]
    fn reviewed_account_removal_holds_native_quit_custody_until_confirm_or_cancel() {
        let (_root, engine) = fixture();
        let created = rows(
            execute(
                &engine,
                "grok",
                Request::Create {
                    login: true,
                    name: "Synthetic sign-in".into(),
                    variable: String::new(),
                },
                &|| true,
            )
            .unwrap(),
        );
        let account = &created[0];
        let editors = try_state(&engine).unwrap().native_ui_editors();
        let custody = editors.editor().pending_native_action();
        let review = execute(
            &engine,
            "grok",
            Request::Review {
                id: account.id.clone(),
                revision: account.revision.clone(),
                custody,
                legacy: false,
            },
            &|| true,
        )
        .unwrap();
        assert!(
            try_state(&engine)
                .unwrap()
                .dispatch(json!({"method":"app.quit","params":{}}))
                .get("error")
                .is_some()
        );
        let Outcome::Review { plan, custody } = review else {
            panic!("Expected reviewed account removal")
        };
        assert_eq!(plan.conversation_count(), 0);
        let removed =
            rows(execute(&engine, "grok", Request::Remove { plan, custody }, &|| true).unwrap());
        assert!(removed.is_empty());
        assert!(
            try_state(&engine)
                .unwrap()
                .native_provider_accounts("grok")
                .unwrap()
                .is_empty()
        );
    }
}
