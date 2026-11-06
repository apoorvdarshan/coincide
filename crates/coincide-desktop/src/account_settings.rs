//! Native profile metadata, explicit enrollment and optimistic conversation
//! selection. Device challenges remain ephemeral and are never logged/saved.
use super::*;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

pub(super) struct AccountSettings {
    name: Entity<InputState>,
    report: Value,
    account: String,
    message: String,
    busy: bool,
    polling: bool,
    operation: Option<Value>,
    pending_start: Option<Arc<AtomicBool>>,
    cancel_requested: bool,
    cancel_sent: bool,
}
impl AccountSettings {
    pub(super) fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            name: cx.new(|cx| InputState::new(window, cx).placeholder("Profile name")),
            report: json!({}),
            account: "default".into(),
            message: String::new(),
            busy: false,
            polling: false,
            operation: None,
            pending_start: None,
            cancel_requested: false,
            cancel_sent: false,
        }
    }
    pub(super) fn subscriptions(&self, cx: &mut Context<Coincide>) -> Vec<Subscription> {
        vec![cx.subscribe(&self.name, |_, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        })]
    }
    fn signing_in(&self) -> bool {
        self.operation
            .as_ref()
            .is_some_and(|operation| operation["workerReturned"] != true)
    }
    fn configured(&self) -> bool {
        self.report["accounts"]
            .as_array()
            .is_some_and(|accounts| accounts.iter().any(|account| account["id"] == self.account))
    }
    fn cancel(&mut self) {
        if let Some(pending) = &self.pending_start {
            pending.store(true, Ordering::Release);
        }
        if self.signing_in() {
            self.cancel_requested = true;
            if let Some(operation) = &mut self.operation {
                operation["verificationUrl"] = Value::Null;
                operation["userCode"] = Value::Null;
                operation["state"] = json!("stopping");
            }
            self.message = "Stopping sign-in and waiting for the owned Codex process…".into();
        }
    }
}

fn matching_operation(value: &Value, account: &str, operation: Option<&str>) -> bool {
    value["accountId"] == account
        && value["operationId"].as_str().is_some_and(|id| {
            uuid::Uuid::parse_str(id).is_ok_and(|parsed| parsed.to_string() == id)
        })
        && operation.is_none_or(|id| value["operationId"] == id)
}

impl Coincide {
    pub(crate) fn open_codex_account_settings(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.focus_settings_route(window, cx);
        self.provider_settings.open = true;
        self.provider_settings.codex_open = true;
        self.settings_open = true;
        self.schedules_open = false;
        self.credentials_open = false;
        self.browser_settings_open = false;
        self.credential_panel
            .update(cx, |panel, cx| panel.cancel(cx));
        if !self.provider_settings.codex.signing_in() {
            self.provider_settings.codex.account = self
                .selected
                .as_ref()
                .filter(|thread| thread["selection"]["provider"] == "codex")
                .and_then(|thread| thread["selection"]["accountID"].as_str())
                .unwrap_or("default")
                .to_owned();
        }
        self.refresh_codex_accounts(cx);
        cx.notify();
    }
    fn refresh_codex_accounts(&mut self, cx: &mut Context<Self>) {
        if self.provider_settings.codex.busy {
            return;
        }
        self.provider_settings.codex.busy = true;
        let engine = self.engine.clone();
        let task = cx.background_executor().spawn(async move {
            coincide_core::api::call(&engine, "providers.codex.profiles.status", json!({}))
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.provider_settings.codex.busy = false;
                match result {
                    Ok(report) => this.provider_settings.codex.report = report,
                    Err(error) => this.provider_settings.codex.message = error.to_string(),
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn create_codex_profile(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let state = &mut self.provider_settings.codex;
        if state.busy || state.signing_in() {
            return;
        }
        let name = state.name.read(cx).value().trim().to_owned();
        state.busy = true;
        let engine = self.engine.clone();
        let task = cx.background_executor().spawn(async move {
            let created = coincide_core::api::call(
                &engine,
                "providers.codex.profiles.create",
                json!({"name":name}),
            )?;
            let report =
                coincide_core::api::call(&engine, "providers.codex.profiles.status", json!({}))?;
            Ok::<_, anyhow::Error>((created, report))
        });
        cx.spawn_in(window,async move |this,cx| {
            let result = task.await;
            let _ = this.update_in(cx,|this,window,cx| {
                let state = &mut this.provider_settings.codex;
                state.busy = false;
                match result {
                    Ok((created,report))=> {
                        state.account = text(&created,"id"); state.report=report;
                        state.name.update(cx,|input,cx|input.set_value("",window,cx));
                        state.message="Empty isolated profile created. Click Sign in to authenticate it explicitly.".into();
                    }
                    Err(error)=>state.message=error.to_string(),
                }
                cx.notify();
            });
        }).detach();
        cx.notify();
    }
    fn start_codex_profile_login(&mut self, cx: &mut Context<Self>) {
        let state = &mut self.provider_settings.codex;
        if state.busy || state.signing_in() || !state.configured() || state.account == "default" {
            return;
        }
        let account = state.account.clone();
        let pending = Arc::new(AtomicBool::new(false));
        state.pending_start = Some(pending.clone());
        state.cancel_requested = false;
        state.cancel_sent = false;
        state.busy = true;
        state.message = "Starting isolated Codex sign-in…".into();
        let engine = self.engine.clone();
        let requested = account.clone();
        let task = cx.background_executor().spawn(async move {
            let mut engine = engine.lock().map_err(|_| anyhow::anyhow!("Engine lock failed"))?;
            anyhow::ensure!(
                !pending.load(Ordering::Acquire),
                "Sign-in panel closed before launch"
            );
            let response = engine.dispatch(json!({"method":"providers.codex.profiles.login.start","params":{"accountId":requested}}));
            if let Some(error) = response.get("error") { anyhow::bail!("{}",text(error,"message")); }
            let result = response["result"].clone();
            if pending.load(Ordering::Acquire) {
                let response = engine.dispatch(json!({"method":"providers.codex.profiles.login.cancel","params":{"accountId":requested,"operationId":result["operationId"]}}));
                if let Some(error) = response.get("error") { anyhow::bail!("{}",text(error,"message")); }
                return Ok(response["result"].clone());
            }
            Ok(result)
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let visible = this.settings_open
                    && this.provider_settings.open
                    && this.provider_settings.codex_open;
                let state = &mut this.provider_settings.codex;
                state.busy = false;
                match result {
                    Ok(operation) if matching_operation(&operation, &account, None) => {
                        state.message = text(&operation, "message");
                        state.operation = Some(operation);
                        if !visible {
                            state.cancel();
                        }
                    }
                    Ok(_) => state.message =
                        "Sign-in returned another profile operation; no browser page was opened."
                            .into(),
                    Err(error) => {
                        state.message = error.to_string();
                        state.pending_start = None;
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub(crate) fn poll_codex_account_settings(&mut self, cx: &mut Context<Self>) {
        let visible = self.settings_open
            && self.provider_settings.open
            && self.provider_settings.codex_open
            && !self.session_import_open
            && !self.workspace_open
            && !self.command_palette.read(cx).is_open();
        let state = &mut self.provider_settings.codex;
        if !visible {
            state.cancel();
        }
        if state.polling || !state.signing_in() || self.media.shutdown_requested {
            return;
        }
        let operation = state.operation.as_ref().unwrap();
        let account = text(operation, "accountId");
        let id = text(operation, "operationId");
        let cancelling = state.cancel_requested && !state.cancel_sent;
        if cancelling {
            state.cancel_sent = true;
        }
        state.polling = true;
        let engine = self.engine.clone();
        let expected_account = account.clone();
        let expected_id = id.clone();
        let task = cx.background_executor().spawn(async move {
            coincide_core::api::call(
                &engine,
                if cancelling {
                    "providers.codex.profiles.login.cancel"
                } else {
                    "providers.codex.profiles.login.status"
                },
                json!({"accountId":account,"operationId":id}),
            )
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let state = &mut this.provider_settings.codex;
                state.polling = false;
                if !state.operation.as_ref().is_some_and(|operation| {
                    matching_operation(operation, &expected_account, Some(&expected_id))
                }) {
                    return;
                }
                match result {
                    Ok(mut operation)
                        if matching_operation(
                            &operation,
                            &expected_account,
                            Some(&expected_id),
                        ) =>
                    {
                        if state.cancel_requested {
                            operation["verificationUrl"] = Value::Null;
                            operation["userCode"] = Value::Null;
                        }
                        state.message = text(&operation, "message");
                        if operation["workerReturned"] == true {
                            state.pending_start = None;
                            state.cancel_requested = false;
                        }
                        state.operation = Some(operation);
                    }
                    Ok(_) => {
                        state.message = "Sign-in status did not match its captured target.".into()
                    }
                    Err(error) => state.message = error.to_string(),
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn use_codex_profile(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let state = &mut self.provider_settings.codex;
        if state.busy || state.signing_in() {
            return;
        }
        let Some(thread) = &self.selected else {
            return;
        };
        let id = text(thread, "id");
        let account = state.account.clone();
        let baseline = thread["selection"].clone();
        state.busy = true;
        let engine = self.engine.clone();
        let target = id.clone();
        let task = cx.background_executor().spawn(async move {
            coincide_core::api::call(
                &engine,
                "providers.codex.profiles.select",
                json!({"threadId":target,"accountId":account,"expectedSelection":baseline}),
            )
        });
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.provider_settings.codex.busy = false;
                match result {
                    Ok(thread) => {
                        if this
                            .selected
                            .as_ref()
                            .is_some_and(|selected| selected["id"] == id)
                        {
                            this.accept_saved_provider_selection(thread);
                            this.provider_settings.open = false;
                            this.settings_open = false;
                            this.focus_settings_route(window, cx);
                            this.status =
                                "Codex profile selected. Authentication is checked before sending."
                                    .into();
                        }
                    }
                    Err(error) => this.provider_settings.codex.message = error.to_string(),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub(super) fn codex_account_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let state = &self.provider_settings.codex;
        let busy = state.busy || state.signing_in();
        let eligible = self.selected.as_ref().is_some_and(|thread| {
            thread["selection"]["provider"] == "codex"
                && thread["selection"]["modelID"] == "default"
                && thread["selection"]["effort"].is_null()
                && thread["selection"]["speed"].is_null()
        });
        let mut accounts = div().flex().flex_wrap().gap_2();
        let mut values = vec![("default".to_owned(), "Default CLI account".to_owned())];
        if let Some(configured) = state.report["accounts"].as_array() {
            values.extend(
                configured
                    .iter()
                    .map(|account| (text(account, "id"), text(account, "name"))),
            );
        }
        for (id, name) in values {
            let selected = state.account == id;
            accounts=accounts.child(Button::new(SharedString::from(format!("codex-profile-{id}"))).label(name).disabled(busy)
                .when(selected,|button|button.primary()).on_click(cx.listener(move |this,_,_,cx| {
                    this.provider_settings.codex.account=id.clone();
                    this.provider_settings.codex.message="Profile display name is a local label; account identity is unverified.".into();cx.notify();
                })));
        }
        let waiting = state.operation.as_ref().filter(|operation| {
            operation["state"] == "waiting"
                && operation["accountId"] == state.account
                && operation["workerReturned"] != true
        });
        div().id("codex-account-settings").flex_1().min_h_0().overflow_y_scroll().p_4().flex().flex_col().gap_3()
            .child(div().flex().items_center().justify_between().child(div().text_xl().child("Codex login profiles"))
                .child(Button::new("codex-profiles-done").label("Done").on_click(cx.listener(|this,_,window,cx| {this.provider_settings.codex.cancel();this.provider_settings.open=false;this.focus_settings_route(window,cx);cx.notify();}))))
            .child(div().text_sm().child("Named profiles use separate private Codex homes. Existing default CLI sign-in and configuration stay separate. Profile labels do not verify account identity."))
            .child(accounts)
            .child(div().flex().gap_2().child(Input::new(&state.name).disabled(busy))
                .child(Button::new("codex-profile-create").label("Create profile").disabled(busy||state.name.read(cx).value().trim().is_empty()).on_click(cx.listener(|this,_,window,cx|this.create_codex_profile(window,cx)))))
            .child(Button::new("codex-profiles-refresh").label("Reload profile list").disabled(busy).on_click(cx.listener(|this,_,_,cx|this.refresh_codex_accounts(cx))))
            .child(div().text_lg().child("Sign in to selected profile"))
            .child(div().text_sm().child(if state.account=="default" {"Default-account sign-in is managed by your existing Codex CLI. Create a named profile to sign in here."}else{"Sign in explicitly with an existing ChatGPT account. This can replace the login in the selected isolated profile; it does not create an OpenAI account or copy credentials from another profile."}))
            .child(Button::new("codex-profile-sign-in").label("Sign in with ChatGPT").disabled(busy||!state.configured()||!self.running.is_empty()).on_click(cx.listener(|this,_,_,cx|this.start_codex_profile_login(cx))))
            .when_some(waiting,|pane,waiting|pane
                .child(div().id("codex-profile-device-code").text_lg().child(format!("One-time code: {}",waiting["userCode"].as_str().unwrap_or("Unavailable"))))
                .child(Button::new("codex-profile-open-sign-in").label("Open device sign-in in browser").primary().on_click(cx.listener(|this,_,_,cx| {
                let state=&this.provider_settings.codex;
                if !state.cancel_requested && let Some(operation)=&state.operation && operation["state"]=="waiting" && operation["accountId"]==state.account && let Some(url)=operation["verificationUrl"].as_str() { cx.open_url(url); }
            }))))
            .when(state.signing_in(),|pane|pane.child(Button::new("codex-profile-cancel-sign-in").label("Cancel sign-in").disabled(state.cancel_requested).on_click(cx.listener(|this,_,_,cx| {this.provider_settings.codex.cancel();cx.notify();}))))
            .child(div().text_sm().child("Enter the code only on the OpenAI page you open from this sign-in. Device login avoids a shared local callback port. No prompt, model, turn or native-session resume is sent during enrollment; cancellation stops the owned CLI and waits for cleanup."))
            .child(div().text_lg().child("Use in this conversation"))
            .child(Button::new("codex-profile-use").label("Use selected profile").disabled(busy||!eligible||self.selected.as_ref().is_some_and(|thread|self.running.contains(&text(thread,"id")))||state.account!="default"&&!state.configured()).on_click(cx.listener(|this,_,window,cx|this.use_codex_profile(window,cx))))
            .child(div().text_sm().child(if eligible {"Choose a profile using Provider default and approval/build. In the conversation, refresh this profile’s models to choose an explicit model, advertised reasoning effort/speed and optional full access. Every turn checks authentication and replays history in a fresh native session. Read this selected profile’s limits explicitly in Settings Usage. Plan, bots and imported execution remain unavailable."}else{"Choose Codex with Provider default, approval/build and no effort/speed in the conversation first. Profile selection keeps the current thread and checks that its selection has not changed."}))
            .child(div().text_sm().child(state.message.clone())).into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn account_status_rejects_other_profile_operation_and_noncanonical_ids() {
        let account = "00000000-0000-4000-8000-aaaaaaaaaaaa".to_owned();
        let operation = "00000000-0000-4000-8000-bbbbbbbbbbbb".to_owned();
        let status = json!({"accountId":account,"operationId":operation});
        assert!(matching_operation(&status, &account, Some(&operation)));
        assert!(!matching_operation(&status, "another", Some(&operation)));
        assert!(!matching_operation(&status, &account, Some("another")));
        assert!(!matching_operation(
            &json!({"accountId":account,"operationId":operation.to_uppercase()}),
            &account,
            None
        ));
    }
}
