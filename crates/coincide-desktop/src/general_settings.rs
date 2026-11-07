//! Settings › General rows ported from Swift's GeneralSettingsView: the model
//! and reasoning effort new threads start with, link routing, the follow-up
//! caption and the worktree branch prefix. Values use Swift's settings keys.
use super::models_settings::ModelRow;
use super::*;
use gpui_kit::component::{
    checkbox::Checkbox,
    menu::{DropdownMenu, PopupMenuItem},
};

pub(super) const BRANCH_PREFIX_DEFAULT: &str = "coincide/";

pub(super) struct GeneralSettings {
    branch_prefix: Entity<InputState>,
}
impl GeneralSettings {
    pub(super) fn new(settings: &Value, window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        let saved = branch_prefix(settings);
        Self {
            branch_prefix: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("No prefix")
                    .default_value(saved)
            }),
        }
    }
    pub(super) fn subscriptions(
        &self,
        window: &mut Window,
        cx: &mut Context<Coincide>,
    ) -> Vec<Subscription> {
        vec![
            cx.subscribe_in(&self.branch_prefix, window, |this, _, event, window, cx| {
                match event {
                    InputEvent::Change => cx.notify(),
                    // Swift saves on Return and when the field loses focus.
                    InputEvent::PressEnter { .. } | InputEvent::Blur => {
                        this.commit_branch_prefix(window, cx)
                    }
                    _ => {}
                }
            }),
        ]
    }
    /// The field shows the saved prefix again whenever it isn't being edited.
    pub(super) fn sync(&self, settings: &Value, window: &mut Window, cx: &mut Context<Coincide>) {
        let saved = branch_prefix(settings);
        let focused = self
            .branch_prefix
            .read(cx)
            .focus_handle(cx)
            .is_focused(window);
        if !focused && self.branch_prefix.read(cx).value().as_ref() != saved.as_str() {
            self.branch_prefix
                .update(cx, |input, cx| input.set_value(saved, window, cx));
        }
    }
}

pub(super) fn branch_prefix(settings: &Value) -> String {
    settings["worktreeBranchPrefix"]
        .as_str()
        .unwrap_or(BRANCH_PREFIX_DEFAULT)
        .to_owned()
}

/// Why a prefix would make invalid git branch names, following
/// `git check-ref-format` as Swift's `BranchPrefixRow.problem` does.
pub(super) fn branch_prefix_problem(prefix: &str) -> Option<String> {
    let value = prefix.trim();
    if value.is_empty() {
        return None;
    }
    if value
        .chars()
        .any(|c| c.is_whitespace() || (c as u32) < 0x20 || c as u32 == 0x7F)
    {
        return Some("Branch names can’t contain spaces.".into());
    }
    if let Some(character) = value.chars().find(|c| "~^:?*[\\".contains(*c)) {
        return Some(format!("Branch names can’t contain “{character}”."));
    }
    if value.contains("..") || value.contains("@{") || value.contains("//") {
        return Some("Branch names can’t contain “..”, “@{” or “//”.".into());
    }
    if value.starts_with('/') || value.starts_with('-') || value.starts_with('.') {
        return Some("Branch names can’t start with “/”, “-” or “.”.".into());
    }
    if value
        .split('/')
        .any(|part| part.starts_with('.') || part.ends_with(".lock"))
    {
        return Some("Parts of a branch name can’t start with “.” or end with “.lock”.".into());
    }
    None
}

/// Where a plain or Command/Control-held click on a web link opens: `true` for
/// the default browser. The setting flips which of the two the plain click is.
/// Transcript links don't route clicks yet; their owner calls this when they do.
#[allow(dead_code)]
pub(super) fn link_opens_default_browser(settings: &Value, command_held: bool) -> bool {
    (settings["opensLinksInDefaultBrowser"] == true) != command_held
}

fn link_caption(default_browser: bool) -> &'static str {
    if default_browser {
        "Clicking a web link opens your default browser. Command / Control-click opens it in Coincide’s browser preview."
    } else {
        "Clicking a web link opens it in Coincide’s browser preview. Command / Control-click opens your default browser."
    }
}

/// What a message sent while an agent works does, and the key that does the
/// other for one message, as Swift's follow-up caption.
pub(super) fn follow_up_caption(behavior: &str, send_on_return: bool) -> String {
    let other = if send_on_return {
        "Command / Control + Return"
    } else {
        "Shift + Command / Control + Return"
    };
    let first = match behavior {
        "queue" => format!(
            "Messages sent while an agent works wait until its turn ends. {other} sends one into the current turn instead."
        ),
        "interrupt" => format!(
            "Messages sent while an agent works stop its current turn and go next. {other} queues one for after the turn instead."
        ),
        _ => format!(
            "Messages sent while an agent works go into its current turn, if it can take them. {other} queues one for after the turn instead."
        ),
    };
    format!(
        "{first} New threads start with this; each thread keeps its own choice, set in its composer."
    )
}

/// Swift's New Threads › Model caption.
fn model_caption(provider: &str, enabled: bool, needs_setup: bool) -> String {
    let name = models_settings::provider_display_name(provider);
    if !enabled {
        format!("{name} is turned off. Turn it on in Providers or pick another model.")
    } else if needs_setup {
        format!("{name} isn’t ready yet. Set it up in Providers or pick another model.")
    } else {
        "New threads start with this model. Choosing a model, effort, speed or access in a thread makes that the new default.".into()
    }
}

impl Coincide {
    fn commit_branch_prefix(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let value = self
            .general_settings
            .branch_prefix
            .read(cx)
            .value()
            .trim()
            .to_owned();
        if branch_prefix_problem(&value).is_some() {
            return;
        }
        if value != branch_prefix(&self.settings) {
            self.change_setting("worktreeBranchPrefix", json!(value), window, cx);
        }
    }

    fn general_row(
        &self,
        label: &'static str,
        caption: impl Into<SharedString>,
        control: impl IntoElement,
    ) -> Div {
        div()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(div().font_weight(FontWeight::SEMIBOLD).child(label))
            .child(control)
            .child(div().text_sm().child(caption.into()))
    }

    /// New Threads › Model and Reasoning effort, written to `defaultSelection`.
    pub(super) fn default_model_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let catalogs = self.model_catalogs(cx);
        let rows = models_settings::model_rows(&self.settings, &catalogs, None, "");
        let selection = models_settings::default_selection(&self.settings);
        let provider = text(&selection, "provider");
        let model = text(&selection, "modelID");
        let current = rows
            .iter()
            .find(|row| row.provider == provider && row.model == model)
            .cloned();
        let enabled =
            models_settings::provider_value(&self.settings, &provider)["isEnabled"] != false;
        let needs_setup = self
            .provider_configuration_panel
            .read(cx)
            .needs_setup(&provider);
        let parent = cx.entity().downgrade();
        let choices: Vec<ModelRow> = rows
            .into_iter()
            .filter(|row| !row.hidden || row.default)
            .take(1000)
            .collect();
        let model_button = Button::new("general-default-model")
            .accessibility_label("Model for new threads")
            .child(chat_layout::provider_label(
                &provider,
                current
                    .as_ref()
                    .map_or(model.clone(), |row| row.name.clone()),
            ))
            .dropdown_caret(true)
            .dropdown_menu(move |mut menu, _, _| {
                let mut last = String::new();
                for row in &choices {
                    if row.provider != last {
                        if !last.is_empty() {
                            menu = menu.item(PopupMenuItem::separator());
                        }
                        menu = menu.item(
                            PopupMenuItem::new(models_settings::provider_display_name(
                                &row.provider,
                            ))
                            .disabled(true),
                        );
                        last = row.provider.clone();
                    }
                    let parent = parent.clone();
                    let choice = row.clone();
                    menu = menu.item(
                        PopupMenuItem::new(if row.default {
                            format!("✓ {}", row.name)
                        } else {
                            row.name.clone()
                        })
                        .on_click(move |_, window, cx| {
                            let _ = parent
                                .update(cx, |this, cx| this.set_default_model(&choice, window, cx));
                        }),
                    );
                }
                menu
            });
        let mut rows = div().flex().flex_col().child(self.general_row(
            "Model",
            model_caption(&provider, enabled, needs_setup),
            model_button,
        ));
        if let Some(current) = current.filter(|row| !row.efforts.is_empty()) {
            let saved = selection["effort"].as_str().map(str::to_owned);
            let default_effort = catalogs
                .iter()
                .filter(|c| c["provider"] == current.provider && c["state"] == "ready")
                .flat_map(|c| c["models"].as_array().into_iter().flatten())
                .find(|row| row["id"] == current.model)
                .and_then(|row| row["reportedDefaultEffort"].as_str())
                .map(models_settings::effort_label);
            let mut choices = vec![(
                None,
                default_effort.map_or("Default".to_owned(), |effort| format!("Default ({effort})")),
            )];
            choices.extend(
                current
                    .efforts
                    .iter()
                    .map(|effort| (Some(effort.clone()), models_settings::effort_label(effort))),
            );
            let buttons =
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .children(
                        choices
                            .into_iter()
                            .enumerate()
                            .map(|(index, (effort, label))| {
                                let chosen = effort == saved;
                                let mut next = selection.clone();
                                next["effort"] = effort.map_or(Value::Null, Value::String);
                                Button::new(SharedString::from(format!("general-effort-{index}")))
                                    .label(label)
                                    .when(chosen, |button| button.primary())
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.change_setting(
                                            "defaultSelection",
                                            next.clone(),
                                            window,
                                            cx,
                                        )
                                    }))
                            }),
                    );
            rows = rows.child(self.general_row(
                "Reasoning effort",
                "How long the model thinks before it answers.",
                buttons,
            ));
        }
        rows.into_any_element()
    }

    pub(super) fn link_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let default_browser = self.settings["opensLinksInDefaultBrowser"] == true;
        self.general_row(
            "Links",
            link_caption(default_browser),
            Checkbox::new("general-links-default-browser")
                .label("Open links in your default browser")
                .checked(default_browser)
                .on_click(cx.listener(|this, checked: &bool, window, cx| {
                    this.change_setting("opensLinksInDefaultBrowser", json!(*checked), window, cx)
                })),
        )
        .into_any_element()
    }

    pub(super) fn follow_up_settings_caption(&self) -> AnyElement {
        div()
            .px_3()
            .pb_3()
            .text_sm()
            .child(follow_up_caption(
                self.settings["followUpBehavior"]
                    .as_str()
                    .unwrap_or("steer"),
                self.settings["sendOnReturn"].as_bool().unwrap_or(true),
            ))
            .into_any_element()
    }

    pub(super) fn branch_prefix_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let draft = self
            .general_settings
            .branch_prefix
            .read(cx)
            .value()
            .to_string();
        let problem = branch_prefix_problem(&draft);
        let caption = div().text_sm().child(match &problem {
            Some(problem) => problem.clone(),
            None => format!(
                "New worktree branches are named like {}fix-login.",
                draft.trim()
            ),
        });
        div()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(
                div()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Worktree branch prefix"),
            )
            .child(
                div()
                    .w(px(220.))
                    .font_family("monospace")
                    .child(Input::new(&self.general_settings.branch_prefix)),
            )
            .child(if problem.is_some() {
                caption.text_color(rgb(0xE5484D))
            } else {
                caption
            })
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn branch_prefix_problems_follow_git_check_ref_format() {
        for ok in ["", "  ", "coincide/", "team/feature-", "a.b/c"] {
            assert_eq!(branch_prefix_problem(ok), None, "{ok}");
        }
        let cases = [
            ("my prefix/", "Branch names can’t contain spaces."),
            ("tab\u{7}", "Branch names can’t contain spaces."),
            ("fix:", "Branch names can’t contain “:”."),
            ("a\\b", "Branch names can’t contain “\\”."),
            ("a..b", "Branch names can’t contain “..”, “@{” or “//”."),
            ("a@{b", "Branch names can’t contain “..”, “@{” or “//”."),
            ("a//b", "Branch names can’t contain “..”, “@{” or “//”."),
            ("/a", "Branch names can’t start with “/”, “-” or “.”."),
            ("-a", "Branch names can’t start with “/”, “-” or “.”."),
            (
                "a/.b",
                "Parts of a branch name can’t start with “.” or end with “.lock”.",
            ),
            (
                "x.lock/",
                "Parts of a branch name can’t start with “.” or end with “.lock”.",
            ),
        ];
        for (prefix, message) in cases {
            assert_eq!(
                branch_prefix_problem(prefix).as_deref(),
                Some(message),
                "{prefix}"
            );
        }
        assert_eq!(branch_prefix(&json!({})), "coincide/");
        assert_eq!(branch_prefix(&json!({"worktreeBranchPrefix":""})), "");
    }

    #[::core::prelude::v1::test]
    fn link_routing_flips_with_the_command_key() {
        let preview = json!({});
        assert!(!link_opens_default_browser(&preview, false));
        assert!(link_opens_default_browser(&preview, true));
        let browser = json!({"opensLinksInDefaultBrowser":true});
        assert!(link_opens_default_browser(&browser, false));
        assert!(!link_opens_default_browser(&browser, true));
    }

    #[::core::prelude::v1::test]
    fn captions_follow_the_behavior_send_key_and_provider_state() {
        assert!(follow_up_caption("steer", true).starts_with(
            "Messages sent while an agent works go into its current turn, if it can take them. Command / Control + Return queues one"
        ));
        assert!(
            follow_up_caption("queue", false)
                .contains("Shift + Command / Control + Return sends one into the current turn")
        );
        assert!(follow_up_caption("interrupt", true).contains("stop its current turn and go next"));
        assert_eq!(
            model_caption("codex", false, false),
            "Codex is turned off. Turn it on in Providers or pick another model."
        );
        assert_eq!(
            model_caption("claude", true, true),
            "Claude Code isn’t ready yet. Set it up in Providers or pick another model."
        );
        assert!(model_caption("claude", true, false).starts_with("New threads start with"));
    }
}
