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
fn astra_model(model: &str) -> bool {
    matches!(model, "gpt-6-astra" | "openai.gpt-6-astra")
}
fn astra_row_reason(model: &str, row: &Value, selection: &Value) -> Option<&'static str> {
    if !astra_model(model) {
        return None;
    }
    let effort = if selection["effort"].is_null() {
        "medium"
    } else {
        selection["effort"].as_str().unwrap_or("")
    };
    if row["reportedEfforts"]
        .as_array()
        .is_some_and(|choices| choices.iter().any(|choice| choice.as_str() == Some(effort)))
    {
        None
    } else if selection["effort"].is_null() {
        Some("app default requires reported medium")
    } else {
        Some("saved effort is not reported by this model")
    }
}
fn named_astra_default_available(caps: Option<&Value>) -> bool {
    caps.is_some_and(|caps| {
        caps["provenance"] == "named_profile_model_list"
            && caps["effectiveDefault"] == "medium"
            && caps["effectiveDefaultProvenance"] == "app_policy+named_profile_model_list"
            && caps["appDefaultRequired"] == true
            && caps["appDefaultAvailable"] == true
    })
}
struct NamedModelOptions<'a> {
    access: Option<&'a str>,
    interaction: Option<&'a str>,
    effort: Option<&'a Value>,
    speed: Option<&'a Value>,
    expected_access: Option<&'a Value>,
    expected_interaction: Option<&'a Value>,
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
            if let Some(expected) = options.expected_access {
                params["expectedAccessMode"] = expected.clone();
            }
            if let Some(expected) = options.expected_interaction {
                params["expectedInteractionMode"] = expected.clone();
            }
            if let Some(effort) = options.effort {
                params["effort"] = effort.clone();
            }
            if let Some(speed) = options.speed {
                params["speed"] = speed.clone();
            }
            if let Some(mode) = options.interaction {
                params["interactionMode"] = json!(mode);
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
                    "Profile model/mode/access/effort/speed saved. This profile is authenticated again before every turn."
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
        let planning = thread["interactionMode"] == "plan";
        let clear_effort = !thread["selection"]["effort"].is_null();
        let clear_speed = !thread["selection"]["speed"].is_null();
        let mut default_label = "Provider default".to_owned();
        if elevated {
            default_label.push_str(", approval");
        }
        if planning {
            default_label.push_str(", Build");
        }
        if clear_effort {
            default_label.push_str(", clear effort");
        }
        if clear_speed {
            default_label.push_str(", Standard speed");
        }
        let default_access = thread.get("accessMode").cloned();
        let default_interaction = thread.get("interactionMode").cloned();
        let mut pane = div().id("named-profile-model-controls").flex().flex_col().gap_2().p_3()
            .child(div().text_sm().child("Codex profile models"))
            .child(div().text_xs().child("Models are read from this selected profile. Display names do not verify account identity. Plan, full access, reasoning effort and faster speeds require this profile’s refreshed explicit model. Completed conversations can resume after reopening when their saved session and account are still available. Bots remain unavailable."))
            .child(div().flex().flex_wrap().gap_2()
                .child(Button::new("named-profile-model-default").label(default_label).disabled(disabled)
                    .on_click(cx.listener(move |this,_,_,cx|this.select_named_profile_model(&default_id,&default_selection,"default",None,if elevated || planning || clear_effort || clear_speed {Some(NamedModelOptions{interaction:if planning {Some("build")}else{None},access:if elevated {Some("approval")}else{None},effort:if clear_effort {Some(&Value::Null)}else{None},speed:if clear_speed {Some(&Value::Null)}else{None},expected_access:default_access.as_ref(),expected_interaction:default_interaction.as_ref()})}else{None},cx))))
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
                    let unsupported = astra_row_reason(&model, row, &selection);
                    let row_id = id.clone();
                    let row_selection = selection.clone();
                    let request = text(catalog, "requestId");
                    let chosen = model.clone();
                    models = models.child(
                        Button::new(SharedString::from(format!("named-profile-model-{model}")))
                            .label(if let Some(reason) = unsupported {
                                format!("{} — {reason}", text(row, "displayName"))
                            } else {
                                text(row, "displayName")
                            })
                            .tooltip(model.clone())
                            .disabled(disabled || unsupported.is_some())
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
        let plan_ready = access_ready && caps["planSupported"] == true;
        let mut mode_controls = div()
            .id("named-profile-mode-controls")
            .flex()
            .flex_col()
            .gap_2()
            .child(div().text_sm().child("Interaction mode"));
        let mut modes = div().flex().flex_wrap().gap_2();
        for (mode, label) in [("build", "Build"), ("plan", "Plan")] {
            let row_id = id.clone();
            let row_selection = selection.clone();
            let row_model = model.clone();
            let row_request = request.clone();
            let expected_access = thread.get("accessMode").cloned();
            let expected_interaction = thread.get("interactionMode").cloned();
            modes = modes.child(
                Button::new(SharedString::from(format!("named-profile-mode-{mode}")))
                    .label(label)
                    .disabled(if mode == "build" {
                        disabled || !planning
                    } else {
                        !plan_ready || planning
                    })
                    .when(planning == (mode == "plan"), |button| button.primary())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_named_profile_model(
                            &row_id,
                            &row_selection,
                            &row_model,
                            if mode == "build" {
                                None
                            } else {
                                Some(&row_request)
                            },
                            Some(NamedModelOptions {
                                interaction: Some(mode),
                                access: None,
                                effort: None,
                                speed: None,
                                expected_access: expected_access.as_ref(),
                                expected_interaction: expected_interaction.as_ref(),
                            }),
                            cx,
                        )
                    })),
            );
        }
        mode_controls = mode_controls.child(modes).child(div().text_xs().child("Plan uses this profile’s exact model, effort and speed. Build clears only Plan; it keeps permissions and options. Unproved saved models remain locked until Refresh. No message is sent."));
        pane = pane.child(mode_controls);
        let mut access_controls = div().flex().flex_wrap().gap_2();
        for (access, label) in [
            ("approval", "Approval required"),
            ("fullAccess", "Full access (no app approvals)"),
        ] {
            let row_id = id.clone();
            let row_selection = selection.clone();
            let row_model = model.clone();
            let row_request = request.clone();
            let expected_access = thread.get("accessMode").cloned();
            let expected_interaction = thread.get("interactionMode").cloned();
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
                                interaction: None,
                                access: Some(access),
                                effort: None,
                                speed: None,
                                expected_access: expected_access.as_ref(),
                                expected_interaction: expected_interaction.as_ref(),
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
        let astra = astra_model(&model);
        let app_default = named_astra_default_available(effort_caps);
        if astra {
            effort_controls=effort_controls.child(div().text_xs().child(if app_default {
                "App default: medium, available for this profile. Choose an effort below to override it."
            }else{
                "Astra app default requires medium from this profile's exact model catalog. Refresh or choose a reported explicit effort."
            }));
        }
        if clear_effort {
            let row_id = id.clone();
            let row_selection = selection.clone();
            let row_model = model.clone();
            let expected_access = thread.get("accessMode").cloned();
            let expected_interaction = thread.get("interactionMode").cloned();
            effort_controls = effort_controls.child(
                Button::new("named-profile-effort-clear")
                    .label(if astra {
                        if app_default {
                            "Use app default (medium)"
                        } else {
                            "Clear saved effort (app default unavailable)"
                        }
                    } else {
                        "Use provider effort (clear saved effort)"
                    })
                    .disabled(disabled)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_named_profile_model(
                            &row_id,
                            &row_selection,
                            &row_model,
                            None,
                            Some(NamedModelOptions {
                                interaction: None,
                                access: None,
                                effort: Some(&Value::Null),
                                speed: None,
                                expected_access: expected_access.as_ref(),
                                expected_interaction: expected_interaction.as_ref(),
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
            let expected_access = thread.get("accessMode").cloned();
            let expected_interaction = thread.get("interactionMode").cloned();
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
                                interaction: None,
                                access: None,
                                effort: Some(&row_effort),
                                speed: None,
                                expected_access: expected_access.as_ref(),
                                expected_interaction: expected_interaction.as_ref(),
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
        let speed_caps = self.selection_ui.capabilities["providers"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["provider"] == "codex"))
            .map(|row| &row["speed"]);
        let speed_ready = !disabled
            && caps["speedSupported"] == true
            && catalog_scope(catalog, thread)
            && catalog["state"] == "ready"
            && catalog["authenticationChecked"] == true;
        let mut speed_controls = div()
            .id("named-profile-speed-controls")
            .flex()
            .flex_col()
            .gap_2()
            .child(div().text_sm().child("Speed"));
        {
            let row_id = id.clone();
            let row_selection = selection.clone();
            let row_model = model.clone();
            let expected_access = thread.get("accessMode").cloned();
            let expected_interaction = thread.get("interactionMode").cloned();
            speed_controls = speed_controls.child(
                Button::new("named-profile-speed-clear")
                    .label("Standard speed (clear saved speed)")
                    .disabled(disabled || !clear_speed)
                    .when(!clear_speed, |button| button.primary())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_named_profile_model(
                            &row_id,
                            &row_selection,
                            &row_model,
                            None,
                            Some(NamedModelOptions {
                                interaction: None,
                                access: None,
                                effort: None,
                                speed: Some(&Value::Null),
                                expected_access: expected_access.as_ref(),
                                expected_interaction: expected_interaction.as_ref(),
                            }),
                            cx,
                        )
                    })),
            );
        }
        let mut speeds = div().flex().flex_wrap().gap_2();
        for row in speed_caps
            .and_then(|value| value["choices"].as_array())
            .into_iter()
            .flatten()
            .take(32)
        {
            let Some(speed) = row["id"].as_str().filter(|id| !id.is_empty()) else {
                continue;
            };
            let row_id = id.clone();
            let row_selection = selection.clone();
            let row_model = model.clone();
            let row_request = request.clone();
            let row_speed = json!(speed);
            let expected_access = thread.get("accessMode").cloned();
            let expected_interaction = thread.get("interactionMode").cloned();
            speeds = speeds.child(
                Button::new(SharedString::from(format!("named-profile-speed-{speed}")))
                    .label(SharedString::from(
                        row["name"].as_str().unwrap_or(speed).to_owned(),
                    ))
                    .tooltip(SharedString::from(format!(
                        "Use reported speed {speed} for {model}"
                    )))
                    .disabled(!speed_ready)
                    .when(thread["selection"]["speed"] == speed, |button| {
                        button.primary()
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_named_profile_model(
                            &row_id,
                            &row_selection,
                            &row_model,
                            Some(&row_request),
                            Some(NamedModelOptions {
                                interaction: None,
                                access: None,
                                effort: None,
                                speed: Some(&row_speed),
                                expected_access: expected_access.as_ref(),
                                expected_interaction: expected_interaction.as_ref(),
                            }),
                            cx,
                        )
                    })),
            );
        }
        speed_controls = speed_controls.child(speeds).child(div().text_xs().child("Only speeds reported for this exact profile/model can be applied. Standard clears only saved speed; unproved models remain locked until Refresh. No message is sent."));
        if let Some(reason) = speed_caps.and_then(|value| value["reason"].as_str()) {
            speed_controls = speed_controls.child(div().text_xs().child(reason.to_owned()));
        }
        pane = pane.child(speed_controls);
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
    fn astra_rows_require_reported_effective_or_retained_effort() {
        let row = json!({"reportedEfforts":["high"]});
        for model in ["gpt-6-astra", "openai.gpt-6-astra"] {
            assert!(astra_row_reason(model, &row, &json!({"effort":null})).is_some());
            assert!(astra_row_reason(model, &row, &json!({"effort":"high"})).is_none());
            assert!(astra_row_reason(model, &row, &json!({"effort":"low"})).is_some());
            assert!(
                astra_row_reason(
                    model,
                    &json!({"reportedEfforts":["medium"]}),
                    &json!({"effort":null})
                )
                .is_none()
            );
        }
        assert!(astra_row_reason("gpt-6-astra-v2", &row, &Value::Null).is_none());
    }
    #[::core::prelude::v1::test]
    fn app_default_label_requires_named_catalog_provenance_and_reported_medium() {
        let caps = json!({"provenance":"named_profile_model_list","effectiveDefault":"medium","effectiveDefaultProvenance":"app_policy+named_profile_model_list","appDefaultRequired":true,"appDefaultAvailable":true});
        assert!(named_astra_default_available(Some(&caps)));
        assert!(!named_astra_default_available(None));
        for (field, value) in [
            ("provenance", json!("provider_model_list")),
            (
                "effectiveDefaultProvenance",
                json!("app_policy+provider_model_list"),
            ),
            ("appDefaultAvailable", json!(false)),
            ("effectiveDefault", Value::Null),
        ] {
            let mut changed = caps.clone();
            changed[field] = value;
            assert!(!named_astra_default_available(Some(&changed)));
        }
    }
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
