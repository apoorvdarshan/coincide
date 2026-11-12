//! Native account selection never travels through descriptive account JSON.
//! Source view validation and the Core's full native CAS preserve drafts/content.
use super::*;
#[derive(Clone)]
pub(super) struct PendingChoice {
    pub(super) scope: Value,
    pub(super) account: Option<String>,
}
fn apply_native_choice(
    engine: &SharedEngine,
    selected: &Value,
    account: Option<&str>,
    running: bool,
    importing: bool,
) -> Result<Value> {
    let id = text(selected, "id");
    anyhow::ensure!(
        !running && !importing,
        "Finish the current turn or attachment import before changing accounts"
    );
    let mut engine = try_state(engine)?;
    let current = selection_response(&mut engine, "threads.read", json!({"threadId":id}))?;
    anyhow::ensure!(
        picker_view_scope(&current) == picker_view_scope(selected),
        "The conversation selection changed; open the picker again"
    );
    engine.select_native_provider_account(&current, account)
}

impl Coincide {
    pub(super) fn select_native_account_from_picker(
        &mut self,
        account: Option<String>,
        cx: &mut Context<Self>,
    ) {
        let source = self.selected.as_ref().map(picker_view_scope);
        let result = self
            .selected
            .as_ref()
            .context("Select a conversation first")
            .and_then(|selected| {
                apply_native_choice(
                    &self.engine,
                    selected,
                    account.as_deref(),
                    self.running.contains(&text(selected, "id")),
                    self.attachment_imports.contains(&text(selected, "id")),
                )
            });
        match result {
            Ok(thread) => {
                self.selection_ui.pending_native_account = None;
                self.selection_ui.pending_provider = None;
                self.selection_ui.pending_provider_picker = None;
                self.accept_saved_provider_selection(thread);
                self.selection_ui.capability_cache.invalidate();
                self.status="Account selected. Your draft is retained; no message was sent. Refresh models when needed.".into();
            }
            Err(error) if engine_busy(&error) => {
                self.selection_ui.pending_native_account =
                    source.map(|scope| PendingChoice { scope, account });
                self.status = "Waiting to select the account. Your draft is retained.".into();
            }
            Err(error) => {
                self.selection_ui.pending_native_account = None;
                self.status = format!("Account was not changed: {error}");
            }
        }
        cx.notify();
    }
    pub(super) fn composer_native_accounts(
        &self,
        thread: &Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let provider = text(&thread["selection"], "provider");
        let rows = self
            .selection_ui
            .native_accounts
            .iter()
            .filter(|row| row.provider == provider)
            .collect::<Vec<_>>();
        if rows.is_empty() {
            return div().into_any_element();
        }
        let native_current = rows
            .iter()
            .any(|row| thread["selection"]["accountID"] == row.id);
        let disabled = self
            .selection_ui
            .drafts
            .get(&text(thread, "id"))
            .is_some_and(|draft| draft.has_edits())
            || self.selection_ui.capabilities["nativeAccountSelectionAllowed"] != true
            || self.running.contains(&text(thread, "id"))
            || !thread["rustBotContext"].is_null()
            || !thread["botID"].is_null()
            || self.selection_ui.pending_provider.is_some()
            || self.selection_ui.pending_provider_picker.is_some()
            || self.selection_ui.pending_native_account.is_some();
        let mut choices = Vec::new();
        if provider != "codex" || native_current {
            choices.push((None, "Default account".to_string(), true));
        }
        choices.extend(rows.into_iter().map(|row| {
            (
                Some(row.id.clone()),
                row.name.clone(),
                row.authentication
                    == coincide_core::provider_configuration::NativeAccountAuthentication::Login
                    || row.has_key,
            )
        }));
        let scope = Arc::new(picker_view_scope(thread));
        let mut pane = div().flex().flex_wrap().gap_1();
        for (account, name, ready) in choices {
            let selected = match &account {
                Some(account) => thread["selection"]["accountID"] == *account,
                None => coincide_core::composer_selection::default_account(
                    &thread["selection"]["accountID"],
                ),
            };
            let scope = scope.clone();
            let id = account.as_deref().unwrap_or("default");
            pane = pane.child(
                Button::new(SharedString::from(format!(
                    "picker-native-account-{provider}-{id}"
                )))
                .label(name)
                .compact()
                .ghost()
                .when(selected, |button| button.primary())
                .disabled(disabled || !ready)
                .on_click(cx.listener(move |this, _, _, cx| {
                    if selected {
                        return;
                    }
                    if !this
                        .selected
                        .as_ref()
                        .is_some_and(|thread| picker_view_scope(thread) == *scope)
                    {
                        this.status =
                            "The conversation changed. Open the model picker again.".into();
                        cx.notify();
                        return;
                    }
                    this.select_native_account_from_picker(account.clone(), cx);
                })),
            );
        }
        pane.into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn native_picker_uses_full_core_cas_and_retains_paged_view_draft_and_history() {
        let root = tempfile::tempdir().unwrap();
        let binary = root.path().join(if cfg!(windows) {
            "synthetic.exe"
        } else {
            "synthetic"
        });
        std::fs::write(&binary, b"synthetic provider bytes; never executed").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let mut store = Store::open(&root.path().join("private/state.sqlite")).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let full = json!({"id":id,"title":"Keep","items":[{"kind":"user","text":"Keep history"}],"selection":{"provider":"grok","modelID":"default"},"draft":"Keep stored draft","unknown":{"keep":[1,2]}});
        store.save(&full).unwrap();
        let mut engine = Engine::new(store);
        engine.set_active_thread(Some(id.clone())).unwrap();
        let baseline = engine
            .native_provider_configuration("grok")
            .unwrap()
            .baseline;
        let prepared = engine
            .prepare_native_provider_configuration(
                "grok",
                &baseline,
                Some(&binary),
                Default::default(),
            )
            .unwrap();
        engine
            .apply_native_provider_configuration(prepared)
            .unwrap();
        let account = engine.create_native_login_account("grok", "Work").unwrap();
        let engine = std::sync::Arc::new(std::sync::Mutex::new(engine));
        let mut paged = full.clone();
        paged["items"] = json!([]);
        paged["page"] = json!({"offset":1,"total":1});
        let changed =
            apply_native_choice(&engine, &paged, Some(&account.id), false, false).unwrap();
        assert_eq!(changed["selection"]["accountID"], account.id);
        assert_eq!(changed["items"], full["items"]);
        assert_eq!(changed["draft"], full["draft"]);
        assert_eq!(changed["unknown"], full["unknown"]);
        assert!(apply_native_choice(&engine, &paged, None, false, false).is_err());
        let restored = apply_native_choice(&engine, &changed, None, false, false).unwrap();
        assert_eq!(restored, full);
    }
}
