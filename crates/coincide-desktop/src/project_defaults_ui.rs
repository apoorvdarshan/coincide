//! A retained native form for one explicit folder project. Every popup is bound
//! to its opening generation; saving uses the Core review, never current focus.
use super::*;
use crate::native_menu::AccessibleMenuExt as _;
use coincide_core::project_defaults::ProjectDefaultsReview;
use gpui_kit::assets::IconName;
use gpui_kit::component::{checkbox::Checkbox, menu::PopupMenuItem};

/// A model's catalog entry, when its provider's catalog is loaded.
pub(super) fn catalog_model<'a>(
    catalog: &'a Value,
    provider: &str,
    model: &str,
) -> Option<&'a Value> {
    if catalog["provider"] != provider || catalog["state"] != "ready" {
        return None;
    }
    catalog["models"]
        .as_array()?
        .iter()
        .find(|row| row["id"] == model)
}
/// Swift's model change: the effort stays when the new model offers it, and
/// so does the speed; anything it doesn't offer is cleared.
fn carry_effort_and_speed(previous: &Value, next: &mut Value, model: Option<&Value>) {
    let Some(fields) = next.as_object_mut() else {
        return;
    };
    let offers = |key: &str, field: Option<&str>, value: &str| {
        model
            .and_then(|model| model[key].as_array())
            .is_some_and(|rows| {
                rows.iter().any(|row| match field {
                    Some(field) => row[field] == value,
                    None => row == value,
                })
            })
    };
    match previous["effort"].as_str() {
        Some(effort) if offers("reportedEfforts", None, effort) => {
            fields.insert("effort".into(), json!(effort));
        }
        _ => {
            fields.remove("effort");
        }
    }
    match previous["speed"].as_str() {
        Some(speed) if offers("reportedSpeeds", Some("id"), speed) => {
            fields.insert("speed".into(), json!(speed));
        }
        _ => {
            fields.remove("speed");
        }
    }
}

pub(super) struct State {
    target: Option<String>,
    review: Option<ProjectDefaultsReview>,
    draft: Value,
    global: bool,
    loading: bool,
    generation: u64,
    custom: bool,
    model: Entity<InputState>,
    accounts: Vec<Value>,
    error: String,
    focus: FocusHandle,
    restore_focus: Option<FocusHandle>,
}
impl State {
    pub(super) fn new(window: &mut Window, cx: &mut App) -> Self {
        Self {
            target: None,
            review: None,
            draft: Value::Null,
            global: true,
            loading: false,
            generation: 0,
            custom: false,
            model: cx.new(|cx| InputState::new(window, cx).placeholder("Custom model ID")),
            accounts: Vec::new(),
            error: String::new(),
            focus: cx.focus_handle(),
            restore_focus: None,
        }
    }
    fn matches(&self, generation: u64) -> bool {
        self.target.is_some()
            && self.review.is_some()
            && !self.loading
            && self.generation == generation
    }
}

impl Coincide {
    pub(super) fn open_project_defaults(
        &mut self,
        id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.project_ui_admitted() || self.project_defaults.target.is_some() {
            return;
        }
        self.project_management.session.close();
        self.project_picker_open = false;
        let state = &mut self.project_defaults;
        state.generation = state.generation.wrapping_add(1);
        state.target = Some(id);
        state.review = None;
        state.loading = true;
        state.custom = false;
        state.error.clear();
        state.restore_focus = window.focused(cx);
        state.focus.focus(window, cx);
        self.poll_project_defaults(window, cx);
        cx.notify();
    }

    pub(super) fn poll_project_defaults(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.project_ui_admitted() || !self.project_defaults.loading {
            return;
        }
        let Some(id) = self.project_defaults.target.clone() else {
            return;
        };
        let loaded = (|| -> Result<(ProjectDefaultsReview, Vec<Value>)> {
            let mut engine = try_state(&self.engine)?;
            let review = engine.native_project_defaults(&id)?;
            // Metadata only: this endpoint does not read credentials or start a provider.
            let profiles =
                engine.dispatch(json!({"method":"providers.codex.profiles.status","params":{}}));
            let accounts = profiles["result"]["accounts"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            Ok((review, accounts))
        })();
        match loaded {
            Ok((review, accounts)) => {
                let state = &mut self.project_defaults;
                state.global = review.inherits_global();
                state.draft = review.effective().clone();
                state.model.update(cx, |input, cx| {
                    input.set_value(text(&state.draft["selection"], "modelID"), window, cx)
                });
                state.accounts = accounts;
                state.review = Some(review);
                state.loading = false;
            }
            Err(error) if engine_busy(&error) => return,
            Err(error) => {
                self.project_defaults.loading = false;
                self.project_defaults.error = error.to_string();
            }
        }
        cx.notify();
    }

    fn close_project_defaults(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let state = &mut self.project_defaults;
        state.generation = state.generation.wrapping_add(1);
        state.target = None;
        state.review = None;
        state.loading = false;
        state.error.clear();
        if let Some(focus) = state.restore_focus.take() {
            focus.focus(window, cx);
        }
        cx.notify();
    }

    fn project_defaults_choice(
        &mut self,
        generation: u64,
        field: &'static str,
        value: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let state = &mut self.project_defaults;
        if !state.matches(generation) {
            return;
        }
        if field == "global" {
            state.global = value == true;
            if state.global {
                state.draft = state.review.as_ref().unwrap().global().clone();
            }
        } else if state.global {
            return;
        } else if !state.draft.is_object() || !state.draft["selection"].is_object() {
            state.error = "Saved defaults have an unsupported shape. Reset to Global to replace them explicitly.".into();
            cx.notify();
            return;
        } else if field == "custom" {
            state.custom = true;
        } else {
            state.draft[field] = value;
        }
        if field == "selection" {
            state.custom = false;
        }
        if !state.custom {
            state.model.update(cx, |input, cx| {
                input.set_value(text(&state.draft["selection"], "modelID"), window, cx)
            });
        }
        state.error.clear();
        cx.notify();
    }

    fn save_project_defaults(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.project_ui_admitted() {
            return;
        }
        let state = &mut self.project_defaults;
        let Some(review) = state.review.clone() else {
            return;
        };
        if state.loading {
            return;
        }
        let mut draft = state.draft.clone();
        if state.custom {
            draft["selection"]["modelID"] = json!(state.model.read(cx).value().trim());
        }
        let inherit = state.global;
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            engine.native_save_project_defaults(&review, (!inherit).then_some(&draft))
        })();
        match result {
            Ok(project) => {
                if let Some(old) = self
                    .projects
                    .iter_mut()
                    .find(|project| project["id"] == review.project()["id"])
                {
                    *old = project;
                }
                self.close_project_defaults(window, cx);
            }
            Err(error) => {
                self.project_defaults.error = error.to_string();
                cx.notify();
            }
        }
    }

    pub(super) fn project_defaults_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.project_defaults.target.is_none() {
            return false;
        }
        let key = &event.keystroke;
        let plain = !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
            && !key.modifiers.shift;
        let form_focused = self.project_defaults.focus.is_focused(window)
            || self
                .project_defaults
                .model
                .read(cx)
                .focus_handle(cx)
                .is_focused(window);
        // A popup owns Return/Escape while it is open; let its native handler
        // choose/dismiss the option before the form sees a submission.
        if plain && !event.is_held && form_focused {
            match key.key.as_str() {
                "escape" => {
                    self.close_project_defaults(window, cx);
                    cx.stop_propagation();
                }
                "enter" => {
                    self.save_project_defaults(window, cx);
                    cx.stop_propagation();
                }
                _ => {}
            }
        }
        true
    }

    /// The model picker's Reasoning and Speed choices for the chosen model,
    /// each shown only when the model offers more than one way to run.
    fn project_defaults_capabilities(
        &self,
        mut form: Stateful<Div>,
        generation: u64,
        selection: &Value,
        model: &Value,
        global: bool,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let efforts = model["reportedEfforts"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if !efforts.is_empty() {
            let chosen = selection["effort"]
                .as_str()
                .or_else(|| model["reportedDefaultEffort"].as_str())
                .map(str::to_owned);
            let choices = efforts
                .iter()
                .map(|effort| {
                    let mut next = selection.clone();
                    next["effort"] = json!(effort);
                    (
                        composer_selection::effort_picker_title(&json!(effort)),
                        chosen.as_deref() == Some(effort.as_str()),
                        next,
                    )
                })
                .collect::<Vec<_>>();
            form = form.child(div().mt_2().text_sm().child("Reasoning")).child(
                self.project_defaults_dropdown(
                    "project-defaults-effort",
                    generation,
                    choices,
                    global,
                    cx,
                ),
            );
        }
        let speeds = model["reportedSpeeds"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        if !speeds.is_empty() {
            let chosen = selection["speed"].as_str();
            let mut standard = selection.clone();
            if let Some(fields) = standard.as_object_mut() {
                fields.remove("speed");
            }
            let mut choices = vec![("Standard".to_owned(), chosen.is_none(), standard)];
            choices.extend(speeds.iter().filter_map(|speed| {
                let id = speed["id"].as_str()?;
                let mut next = selection.clone();
                next["speed"] = json!(id);
                Some((
                    speed["name"].as_str().unwrap_or(id).to_owned(),
                    chosen == Some(id),
                    next,
                ))
            }));
            form = form.child(div().mt_2().text_sm().child("Speed")).child(
                self.project_defaults_dropdown(
                    "project-defaults-speed",
                    generation,
                    choices,
                    global,
                    cx,
                ),
            );
        }
        form
    }
    fn project_defaults_dropdown(
        &self,
        id: &'static str,
        generation: u64,
        choices: Vec<(String, bool, Value)>,
        global: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let parent = cx.entity().downgrade();
        let title = choices
            .iter()
            .find(|(_, chosen, _)| *chosen)
            .map(|(title, _, _)| title.clone())
            .unwrap_or_default();
        Button::new(id)
            .label(title)
            .disabled(global)
            .dropdown_caret(true)
            .accessible_menu(move |mut menu, _, _| {
                for (title, chosen, selection) in &choices {
                    let parent = parent.clone();
                    let selection = selection.clone();
                    menu = menu.item(PopupMenuItem::new(title.clone()).checked(*chosen).on_click(
                        move |_, window, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                this.project_defaults_choice(
                                    generation,
                                    "selection",
                                    selection.clone(),
                                    window,
                                    cx,
                                )
                            });
                        },
                    ));
                }
                menu
            })
    }

    pub(super) fn project_defaults_form(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let state = &self.project_defaults;
        state.target.as_ref()?;
        let generation = state.generation;
        let mut form = div()
            .id("project-defaults-form")
            .track_focus(&state.focus)
            .w(px(460.))
            .max_w_full()
            .max_h_full()
            .overflow_y_scroll()
            .p_5()
            .gap_2()
            .flex()
            .flex_col()
            .rounded_lg()
            .border_1()
            .border_color(self.color(0x29303d))
            .bg(self.color(0x10141c))
            .text_color(self.color(0xe4e9f2))
            .child(div().text_lg().child("Project Defaults"))
            .child(
                div().child(
                    state
                        .review
                        .as_ref()
                        .map(|review| text(review.project(), "name"))
                        .unwrap_or_default(),
                ),
            )
            .child(div().text_sm().child(
                "Applies to new threads in this project. Existing threads keep their settings.",
            ));
        if state.review.is_some() {
            let global = state.global;
            form = form.child(
                Checkbox::new("project-defaults-global")
                    .label("Use Global Defaults")
                    .checked(global)
                    .on_click(cx.listener(move |this, checked, window, cx| {
                        this.project_defaults_choice(
                            generation,
                            "global",
                            json!(*checked),
                            window,
                            cx,
                        )
                    })),
            );
            let selection = state.draft["selection"].clone();
            let provider = text(&selection, "provider");
            let model = text(&selection, "modelID");
            let rows = models_settings::model_rows(
                &self.settings,
                &[self.selection_ui.catalog.clone()],
                None,
                "",
            );
            let parent = cx.entity().downgrade();
            let catalog = &self.selection_ui.catalog;
            let current = catalog_model(catalog, &provider, &model);
            // Each choice is decided here, against the catalog shown now.
            let choices = rows
                .iter()
                .filter(|row| !row.hidden)
                .take(1000)
                .map(|row| {
                    let mut next = if selection["provider"] == row.provider {
                        selection.clone()
                    } else {
                        json!({"provider":row.provider,"modelID":row.model})
                    };
                    if next["modelID"] != row.model {
                        next["modelID"] = json!(row.model);
                        carry_effort_and_speed(
                            &selection,
                            &mut next,
                            catalog_model(catalog, &row.provider, &row.model),
                        );
                    }
                    (format!("{} · {}", row.provider, row.name), next)
                })
                .collect::<Vec<_>>();
            form = form.child(div().mt_2().text_sm().child("Model")).child(
                Button::new("project-defaults-model")
                    .accessibility_label("Model")
                    .disabled(global)
                    .child(chat_layout::provider_label(&provider, model.clone()))
                    // Swift's bolt for a faster speed.
                    .when(selection["speed"].is_string(), |button| {
                        button.icon(IconName::Zap)
                    })
                    .dropdown_caret(true)
                    .accessible_menu(move |mut menu, _, _| {
                        for (title, selection) in &choices {
                            let parent = parent.clone();
                            let selection = selection.clone();
                            menu = menu.item(PopupMenuItem::new(title.clone()).on_click(
                                move |_, window, cx| {
                                    let _ = parent.update(cx, |this, cx| {
                                        this.project_defaults_choice(
                                            generation,
                                            "selection",
                                            selection.clone(),
                                            window,
                                            cx,
                                        )
                                    });
                                },
                            ));
                        }
                        let parent = parent.clone();
                        menu.item(PopupMenuItem::separator()).item(
                            PopupMenuItem::new("Custom model…").on_click(move |_, window, cx| {
                                let _ = parent.update(cx, |this, cx| {
                                    this.project_defaults_choice(
                                        generation,
                                        "custom",
                                        Value::Null,
                                        window,
                                        cx,
                                    )
                                });
                            }),
                        )
                    }),
            );
            if state.custom && !global {
                form = form.child(Input::new(&state.model));
            }
            if let Some(model) = current {
                form = self
                    .project_defaults_capabilities(form, generation, &selection, model, global, cx);
            }
            if provider == "codex" {
                let mut accounts = vec![(Value::Null, "Default account".to_owned())];
                accounts.extend(
                    state.accounts.iter().filter_map(|row| {
                        row["id"].as_str().map(|id| (json!(id), text(row, "name")))
                    }),
                );
                let parent = cx.entity().downgrade();
                let account_label = selection["accountID"]
                    .as_str()
                    .and_then(|id| state.accounts.iter().find(|row| row["id"] == id))
                    .map(|row| text(row, "name"))
                    .unwrap_or_else(|| {
                        selection["accountID"]
                            .as_str()
                            .unwrap_or("Default account")
                            .to_owned()
                    });
                form = form.child(
                    Button::new("project-defaults-account")
                        .label(account_label)
                        .disabled(global)
                        .dropdown_caret(true)
                        .accessible_menu(move |mut menu, _, _| {
                            for (account, label) in &accounts {
                                let parent = parent.clone();
                                let mut next = selection.clone();
                                next["accountID"] = account.clone();
                                if next["accountID"] != selection["accountID"] {
                                    next["modelID"] = json!("default");
                                    if let Some(fields) = next.as_object_mut() {
                                        fields.remove("effort");
                                        fields.remove("speed");
                                    }
                                }
                                menu = menu.item(PopupMenuItem::new(label.clone()).on_click(
                                    move |_, window, cx| {
                                        let _ = parent.update(cx, |this, cx| {
                                            this.project_defaults_choice(
                                                generation,
                                                "selection",
                                                next.clone(),
                                                window,
                                                cx,
                                            )
                                        });
                                    },
                                ));
                            }
                            menu
                        }),
                );
            }
            // Swift's model detail: the effort (or the model's default) and speed.
            let effort = state.draft["selection"]["effort"]
                .as_str()
                .or_else(|| current.and_then(|model| model["reportedDefaultEffort"].as_str()));
            let speed = state.draft["selection"]["speed"].as_str().map(|speed| {
                current
                    .and_then(|model| model["reportedSpeeds"].as_array())
                    .and_then(|rows| rows.iter().find(|row| row["id"] == speed))
                    .and_then(|row| row["name"].as_str())
                    .unwrap_or(speed)
                    .to_owned()
            });
            let detail = effort
                .map(|effort| composer_selection::effort_picker_title(&json!(effort)))
                .into_iter()
                .chain(speed)
                .collect::<Vec<_>>()
                .join(" · ");
            form = form.child(div().text_xs().child(detail));
            form = form.child(
                Button::new("project-defaults-agent-settings")
                    .ghost()
                    .compact()
                    .icon(IconName::Settings)
                    .label("Agent Settings…")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.close_project_defaults(window, cx);
                        this.open_settings_panel(window, cx);
                        this.navigate_settings_section(
                            settings::SettingsSection::Models,
                            window,
                            cx,
                        );
                    })),
            );
            for (field, label, values) in [
                (
                    "accessMode",
                    "Permissions",
                    &[("approval", "Approval"), ("fullAccess", "Full access")][..],
                ),
                (
                    "interactionMode",
                    "Mode",
                    &[("build", "Build"), ("plan", "Plan")][..],
                ),
            ] {
                let parent = cx.entity().downgrade();
                let current = text(&state.draft, field);
                let title = values
                    .iter()
                    .find(|(value, _)| *value == current)
                    .map(|(_, label)| *label)
                    .unwrap_or("Unsupported saved choice");
                let choices = values.to_vec();
                let provider = provider.clone();
                form = form.child(div().mt_2().text_sm().child(label)).child(
                    Button::new(SharedString::from(format!("project-defaults-{field}")))
                        .label(title)
                        .disabled(global)
                        .dropdown_caret(true)
                        .accessible_menu(move |mut menu, _, _| {
                            for (value, title) in &choices {
                                let parent = parent.clone();
                                let value = *value;
                                menu = menu.item(
                                    PopupMenuItem::new(*title)
                                        .disabled(
                                            provider != "codex"
                                                && value != "approval"
                                                && value != "build",
                                        )
                                        .on_click(move |_, window, cx| {
                                            let _ = parent.update(cx, |this, cx| {
                                                this.project_defaults_choice(
                                                    generation,
                                                    field,
                                                    json!(value),
                                                    window,
                                                    cx,
                                                )
                                            });
                                        }),
                                );
                            }
                            menu
                        }),
                );
            }
        }
        if state.loading {
            form = form.child(div().text_sm().child("Loading project defaults…"));
        }
        if !state.error.is_empty() {
            form = form.child(div().text_sm().child(state.error.clone()));
            if state.review.is_none() {
                form = form.child(
                    Button::new("project-defaults-retry")
                        .label("Retry")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.project_defaults.loading = true;
                            this.project_defaults.error.clear();
                            this.poll_project_defaults(window, cx);
                        })),
                );
            }
        }
        if !state.error.is_empty() && state.review.is_some() {
            form = form.child(
                Button::new("project-defaults-reload")
                    .label("Reload defaults")
                    .on_click(cx.listener(|this, _, window, cx| {
                        let state = &mut this.project_defaults;
                        state.generation = state.generation.wrapping_add(1);
                        state.review = None;
                        state.loading = true;
                        state.custom = false;
                        state.error.clear();
                        this.poll_project_defaults(window, cx);
                    })),
            );
        }
        form = form.child(
            div()
                .mt_4()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    Button::new("project-defaults-reset")
                        .label("Reset to Global")
                        .ghost()
                        .disabled(state.review.is_none())
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.project_defaults_choice(
                                generation,
                                "global",
                                json!(true),
                                window,
                                cx,
                            )
                        })),
                )
                .child(div().flex_1())
                .child(
                    Button::new("project-defaults-cancel")
                        .label("Cancel")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.close_project_defaults(window, cx)
                        })),
                )
                .child(
                    Button::new("project-defaults-save")
                        .label("Save")
                        .primary()
                        .disabled(state.review.is_none() || state.loading)
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.save_project_defaults(window, cx)
                        })),
                ),
        );
        Some(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .p_3()
                .bg(rgba(0x00000080))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|_, _, _, cx| cx.stop_propagation()),
                )
                .child(form)
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn a_new_model_keeps_the_effort_and_speed_it_offers_and_drops_the_rest() {
        let previous =
            json!({"provider":"codex","modelID":"old","effort":"high","speed":"priority"});
        let offers_both = json!({"id":"new","reportedEfforts":["low","high"],"reportedSpeeds":[{"id":"priority","name":"Fast"}]});
        let mut next =
            json!({"provider":"codex","modelID":"new","effort":"high","speed":"priority"});
        carry_effort_and_speed(&previous, &mut next, Some(&offers_both));
        assert_eq!(next["effort"], "high");
        assert_eq!(next["speed"], "priority");
        let offers_neither = json!({"id":"new","reportedEfforts":["low"],"reportedSpeeds":[]});
        carry_effort_and_speed(&previous, &mut next, Some(&offers_neither));
        assert_eq!(next, json!({"provider":"codex","modelID":"new"}));
        let mut unknown = json!({"provider":"codex","modelID":"new","effort":"high"});
        carry_effort_and_speed(&previous, &mut unknown, None);
        assert_eq!(unknown, json!({"provider":"codex","modelID":"new"}));
    }
    #[::core::prelude::v1::test]
    fn only_a_ready_catalog_of_the_same_provider_describes_a_model() {
        let catalog = json!({"provider":"codex","state":"ready","models":[{"id":"a"}]});
        assert!(catalog_model(&catalog, "codex", "a").is_some());
        assert!(catalog_model(&catalog, "claude", "a").is_none());
        assert!(catalog_model(&catalog, "codex", "b").is_none());
        let loading = json!({"provider":"codex","state":"loading","models":[{"id":"a"}]});
        assert!(catalog_model(&loading, "codex", "a").is_none());
    }
}
