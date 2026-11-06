//! Named model controls use the captured profile catalog, never default metadata.
use super::*;
pub(super) fn named_thread(thread: &Value) -> bool {
    thread["selection"]["provider"] == "codex"
        && default_account_id(&thread["selection"]["accountID"]).is_some_and(|id| id != "default")
}
fn catalog_scope(catalog: &Value, thread: &Value) -> bool {
    catalog["provider"] == "codex"
        && catalog["accountID"] == thread["selection"]["accountID"]
        && catalog["threadId"] == thread["id"]
}
struct NamedModelOptions<'a> {
    access: Option<&'a str>,
    effort: Option<&'a Value>,
    expected_access: &'a Value,
    expected_interaction: &'a Value,
}
impl Coincide {
    fn refresh_named_profile_models(
        &mut self,
        id: &str,
        selection: &Value,
        cx: &mut Context<Self>,
    ) {
        if self.selection_ui.catalog_request.is_some() {
            return;
        }
        let Some(thread) = self.selected.as_ref().filter(|thread| {
            thread["id"] == id && thread["selection"] == *selection && named_thread(thread)
        }) else {
            return;
        };
        let account = text(&thread["selection"], "accountID");
        match call(
            &self.engine,
            "providers.codex.profiles.models.refresh",
            json!({"threadId":id,"accountId":account,"expectedSelection":selection}),
        ) {
            Ok(value) => {
                let request = CatalogRequest {
                    request_id: text(&value, "requestId"),
                    provider: "codex".into(),
                    account_id: account,
                    thread_id: Some(id.into()),
                };
                if !request.request_id.is_empty() && catalog_response_matches(&value, &request) {
                    self.selection_ui.catalog = value;
                    self.selection_ui.catalog_request = Some(request);
                    self.selection_ui.catalog_last_poll = None;
                } else {
                    self.status = "Invalid named-profile model catalog response".into();
                }
            }
            Err(error) => self.status = format!("Profile model refresh failed: {error}"),
        }
        self.selection_ui.context = None;
        cx.notify();
    }
    fn select_named_profile_model(
        &mut self,
        id: &str,
        selection: &Value,
        model: &str,
        request: Option<&str>,
        options: Option<NamedModelOptions<'_>>,
        cx: &mut Context<Self>,
    ) {
        let Some(thread) = self.selected.as_ref().filter(|thread| {
            thread["id"] == id && thread["selection"] == *selection && named_thread(thread)
        }) else {
            return;
        };
        let mut params = json!({"threadId":id,"accountId":thread["selection"]["accountID"],"expectedSelection":selection,"model":model});
        if let Some(request) = request {
            params["requestId"] = json!(request);
        }
        if let Some(options) = options {
            params["expectedAccessMode"] = options.expected_access.clone();
            params["expectedInteractionMode"] = options.expected_interaction.clone();
            if let Some(effort) = options.effort {
                params["effort"] = effort.clone();
            }
            if let Some(access) = options.access {
                params["accessMode"] = json!(access);
            }
        }
        match call(
            &self.engine,
            "providers.codex.profiles.models.select",
            params,
        ) {
            Ok(thread) => {
                self.accept_saved_provider_selection(thread);
                self.status =
                    "Profile model/access/effort saved. This profile is authenticated again before every turn."
                        .into();
            }
            Err(error) => self.status = format!("Profile model was not changed: {error}"),
        }
        self.selection_ui.context = None;
        cx.notify();
    }
    pub(super) fn named_profile_model_pane(
        &self,
        thread: &Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let caps = &self.selection_ui.capabilities["namedModels"];
        let bound = caps["supported"] == true
            && caps["threadId"] == thread["id"]
            && caps["accountID"] == thread["selection"]["accountID"];
        let disabled =
            !bound || caps["refreshAllowed"] != true || self.running.contains(&text(thread, "id"));
        let id = text(thread, "id");
        let selection = thread["selection"].clone();
        let refresh_id = id.clone();
        let refresh_selection = selection.clone();
        let default_id = id.clone();
        let default_selection = selection.clone();
        let elevated = thread["accessMode"] == "fullAccess";
        let clear_effort = !thread["selection"]["effort"].is_null();
        let default_access = thread["accessMode"].clone();
        let default_interaction = thread["interactionMode"].clone();
        let mut pane = div().id("named-profile-model-controls").flex().flex_col().gap_2().p_3()
            .child(div().text_sm().child("Codex profile models"))
            .child(div().text_xs().child("Models are read from this selected profile. Display names do not verify account identity. Full access and explicit reasoning effort require this profile’s refreshed model catalog. Speed, Plan, bots and native resume remain unavailable."))
            .child(div().flex().flex_wrap().gap_2()
                .child(Button::new("named-profile-model-default").label(match (elevated,clear_effort) {(true,true)=>"Provider default, approval and clear effort",(true,false)=>"Provider default and approval",(false,true)=>"Provider default and clear effort",_=>"Provider default"}).disabled(disabled)
                    .on_click(cx.listener(move |this,_,_,cx|this.select_named_profile_model(&default_id,&default_selection,"default",None,if elevated || clear_effort {Some(NamedModelOptions{access:if elevated {Some("approval")}else{None},effort:if clear_effort {Some(&Value::Null)}else{None},expected_access:&default_access,expected_interaction:&default_interaction})}else{None},cx))))
                .child(Button::new("named-profile-model-refresh").label("Refresh profile models").disabled(disabled || self.selection_ui.catalog_request.is_some())
                    .on_click(cx.listener(move |this,_,_,cx|this.refresh_named_profile_models(&refresh_id,&refresh_selection,cx)))));
        if let Some(reason) = self.selection_ui.capabilities["lockReason"].as_str() {
            pane = pane.child(div().text_xs().child(reason.to_owned()));
        }
        let catalog = &self.selection_ui.catalog;
        if catalog_scope(catalog, thread) {
            if catalog["state"] == "loading" {
                pane = pane.child("Reading this profile’s model catalog…");
            } else if catalog["state"] == "ready" && catalog["authenticationChecked"] == true {
                pane = pane.child(div().text_xs().child("Subscription authentication checked for this catalog read; model execution is checked by Codex when used."));
                let mut models = div()
                    .id("named-profile-model-list")
                    .max_h(px(160.))
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .gap_1();
                for row in catalog["models"].as_array().into_iter().flatten().take(200) {
                    let model = text(row, "id");
                    let unsupported =
                        matches!(model.as_str(), "gpt-6-astra" | "openai.gpt-6-astra");
                    let row_id = id.clone();
                    let row_selection = selection.clone();
                    let request = text(catalog, "requestId");
                    let chosen = model.clone();
                    models = models.child(
                        Button::new(SharedString::from(format!("named-profile-model-{model}")))
                            .label(if unsupported {
                                format!(
                                    "{} — named app-default effort unavailable",
                                    text(row, "displayName")
                                )
                            } else {
                                text(row, "displayName")
                            })
                            .tooltip(model.clone())
                            .disabled(disabled || unsupported)
                            .when(thread["selection"]["modelID"] == model, |button| {
                                button.primary()
                            })
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.select_named_profile_model(
                                    &row_id,
                                    &row_selection,
                                    &chosen,
                                    Some(&request),
                                    None,
                                    cx,
                                )
                            })),
                    );
                }
                pane = pane.child(models);
                if catalog["models"]
                    .as_array()
                    .is_some_and(|rows| rows.len() > 200)
                {
                    pane = pane.child("Showing the first 200 reported models.");
                }
            } else if let Some(error) = catalog["error"].as_str() {
                pane = pane.child(div().text_xs().child(error.to_owned()));
            }
        }
        let model = text(&thread["selection"], "modelID");
        let request = text(catalog, "requestId");
        let access_ready = !disabled
            && caps["fullAccessSupported"] == true
            && catalog_scope(catalog, thread)
            && catalog["state"] == "ready"
            && catalog["authenticationChecked"] == true;
        let mut access_controls = div().flex().flex_wrap().gap_2();
        for (access, label) in [
            ("approval", "Approval required"),
            ("fullAccess", "Full access (no app approvals)"),
        ] {
            let row_id = id.clone();
            let row_selection = selection.clone();
            let row_model = model.clone();
            let row_request = request.clone();
            let expected_access = thread["accessMode"].clone();
            let expected_interaction = thread["interactionMode"].clone();
            access_controls = access_controls.child(
                Button::new(SharedString::from(format!("named-profile-access-{access}")))
                    .label(label)
                    .disabled(!access_ready)
                    .when(thread["accessMode"] == access, |button| button.primary())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_named_profile_model(
                            &row_id,
                            &row_selection,
                            &row_model,
                            Some(&row_request),
                            Some(NamedModelOptions {
                                access: Some(access),
                                effort: None,
                                expected_access: &expected_access,
                                expected_interaction: &expected_interaction,
                            }),
                            cx,
                        )
                    })),
            );
        }
        let effort_caps = self.selection_ui.capabilities["providers"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["provider"] == "codex"))
            .map(|row| &row["effort"]);
        let effort_ready = !disabled
            && caps["effortSupported"] == true
            && catalog_scope(catalog, thread)
            && catalog["state"] == "ready"
            && catalog["authenticationChecked"] == true;
        let mut effort_controls = div()
            .id("named-profile-effort-controls")
            .flex()
            .flex_col()
            .gap_2()
            .child(div().text_sm().child("Reasoning effort"));
        if clear_effort {
            let row_id = id.clone();
            let row_selection = selection.clone();
            let row_model = model.clone();
            let expected_access = thread["accessMode"].clone();
            let expected_interaction = thread["interactionMode"].clone();
            effort_controls = effort_controls.child(
                Button::new("named-profile-effort-clear")
                    .label("Use provider effort (clear saved effort)")
                    .disabled(disabled)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_named_profile_model(
                            &row_id,
                            &row_selection,
                            &row_model,
                            None,
                            Some(NamedModelOptions {
                                access: None,
                                effort: Some(&Value::Null),
                                expected_access: &expected_access,
                                expected_interaction: &expected_interaction,
                            }),
                            cx,
                        )
                    })),
            );
        }
        let mut efforts = div().flex().flex_wrap().gap_2();
        for effort in effort_caps
            .and_then(|value| value["choices"].as_array())
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .take(32)
        {
            let row_id = id.clone();
            let row_selection = selection.clone();
            let row_model = model.clone();
            let row_request = request.clone();
            let row_effort = json!(effort);
            let expected_access = thread["accessMode"].clone();
            let expected_interaction = thread["interactionMode"].clone();
            efforts = efforts.child(
                Button::new(SharedString::from(format!("named-profile-effort-{effort}")))
                    .label(SharedString::from(effort.to_owned()))
                    .tooltip(SharedString::from(format!(
                        "Use reported reasoning effort {effort} for {model}"
                    )))
                    .disabled(!effort_ready)
                    .when(thread["selection"]["effort"] == effort, |button| {
                        button.primary()
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_named_profile_model(
                            &row_id,
                            &row_selection,
                            &row_model,
                            Some(&row_request),
                            Some(NamedModelOptions {
                                access: None,
                                effort: Some(&row_effort),
                                expected_access: &expected_access,
                                expected_interaction: &expected_interaction,
                            }),
                            cx,
                        )
                    })),
            );
        }
        effort_controls = effort_controls.child(efforts).child(div().text_xs().child("Only efforts reported for this exact profile/model can be applied. Clearing keeps the model and modes; unproved models remain locked until Refresh. No message is sent."));
        if let Some(reason) = effort_caps.and_then(|value| value["reason"].as_str()) {
            effort_controls = effort_controls.child(div().text_xs().child(reason.to_owned()));
        }
        pane = pane.child(effort_controls);
        pane = pane.child(access_controls);
        if elevated {
            pane = pane.child(div().text_xs().child("Full access lets Codex run without app approval prompts. The saved model must retain this profile’s current catalog proof; authentication is checked before every turn. Changing this setting sends no message."));
        }
        pane.into_any_element()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn named_catalog_ui_requires_exact_thread_and_account() {
        let thread = json!({"id":"a","selection":{"provider":"codex","accountID":"profile-a"}});
        let mut catalog = json!({"provider":"codex","accountID":"profile-a","threadId":"a"});
        assert!(catalog_scope(&catalog, &thread));
        catalog["threadId"] = json!("b");
        assert!(!catalog_scope(&catalog, &thread));
        catalog["threadId"] = json!("a");
        catalog["accountID"] = json!("profile-b");
        assert!(!catalog_scope(&catalog, &thread));
        catalog["accountID"] = json!("default");
        assert!(!catalog_scope(&catalog, &thread));
    }
}
