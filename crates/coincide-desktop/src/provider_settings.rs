//! Native provider setup uses the same explicit configuration/acknowledgement
//! commands as the CLI. Discovery reads metadata only; Codex enrollment requires
//! an explicit action in the isolated profile panel.
use super::*;
use std::path::PathBuf;
#[path = "account_settings.rs"]
mod account_settings;

const RISK_NOTICE: &str = "Using Antigravity through Coincide may break Google’s Antigravity terms, which forbid accessing it with third-party tools. Google has suspended accounts for this, including access to Gemini CLI and Code Assist. Use at your own risk; consider a separate Google account.";
const API_KEY_NOTE: &str =
    "Gemini API keys from Google AI Studio or Gemini Enterprise aren’t affected.";
const RISK_KEY: &str = "provider:antigravity-account-risk";

#[derive(Default)]
struct Suggestions {
    executables: Vec<String>,
    profiles: Vec<String>,
}
pub(super) struct ProviderSettings {
    pub open: bool,
    codex_open: bool,
    codex: account_settings::AccountSettings,
    account: String,
    name: Entity<InputState>,
    executable: Entity<InputState>,
    source: Entity<InputState>,
    model: Entity<InputState>,
    report: Value,
    message: String,
    busy: bool,
    discovering: bool,
    suggestions: Suggestions,
}
impl ProviderSettings {
    pub fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            open: false,
            codex_open: false,
            codex: account_settings::AccountSettings::new(window, cx),
            account: "default".into(),
            name: cx.new(|cx| InputState::new(window, cx).placeholder("Account name")),
            executable: cx
                .new(|cx| InputState::new(window, cx).placeholder("Path to agy_acp_server.par")),
            source: cx.new(|cx| {
                InputState::new(window, cx).placeholder("Existing Antigravity profile folder")
            }),
            model: cx.new(|cx| {
                InputState::new(window, cx).placeholder("Default model, or enter a model ID")
            }),
            report: json!({}),
            message: String::new(),
            busy: false,
            discovering: false,
            suggestions: Suggestions::default(),
        }
    }
    pub fn subscriptions(&self, cx: &mut Context<Coincide>) -> Vec<Subscription> {
        let mut subscriptions = [&self.name, &self.executable, &self.source, &self.model]
            .into_iter()
            .map(|input| {
                cx.subscribe(input, |_, _, event, cx| {
                    if matches!(event, InputEvent::Change) {
                        cx.notify();
                    }
                })
            })
            .collect::<Vec<_>>();
        subscriptions.extend(self.codex.subscriptions(cx));
        subscriptions
    }
    fn configured(&self) -> bool {
        self.report["accounts"].get(&self.account).is_some()
    }
    fn has_unsaved_changes(&self, cx: &App) -> bool {
        let value = &self.report["accounts"][&self.account];
        !self.configured()
            || self.name.read(cx).value().trim() != self.account_label(&self.account, value)
            || self.executable.read(cx).value().trim() != text(value, "executable")
            || self.source.read(cx).value().trim() != text(value, "sourceProfile")
    }
    fn acknowledged(&self) -> bool {
        self.report["riskAcknowledged"] == true
    }
    fn account_label(&self, id: &str, account: &Value) -> String {
        account["name"]
            .as_str()
            .filter(|name| !name.trim().is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| {
                if id == "default" {
                    "Default account".into()
                } else {
                    format!("Account {}", &id[..id.len().min(8)])
                }
            })
    }
}

impl Coincide {
    pub(super) fn open_antigravity_settings(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.provider_settings.open = true;
        self.provider_settings.codex_open = false;
        self.settings_open = true;
        self.schedules_open = false;
        self.refresh_antigravity_settings(cx);
        let account = self
            .selected
            .as_ref()
            .filter(|thread| thread["selection"]["provider"] == "antigravity")
            .and_then(|thread| thread["selection"]["accountID"].as_str())
            .unwrap_or("default")
            .to_owned();
        self.edit_antigravity_account(account, window, cx);
        self.discover_antigravity_paths(cx);
        cx.notify();
    }
    fn refresh_antigravity_settings(&mut self, cx: &mut Context<Self>) {
        match call(&self.engine, "providers.antigravity.status", json!({})) {
            Ok(status) => self.provider_settings.report = status,
            Err(error) => self.provider_settings.message = error.to_string(),
        }
        cx.notify();
    }
    fn edit_antigravity_account(
        &mut self,
        account: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.provider_settings.busy {
            return;
        }
        let value = self.provider_settings.report["accounts"]
            .get(&account)
            .cloned()
            .unwrap_or(json!({}));
        let name = self.provider_settings.account_label(&account, &value);
        let executable = text(&value, "executable");
        let source = text(&value, "sourceProfile");
        self.provider_settings.account = account;
        self.provider_settings
            .name
            .update(cx, |input, cx| input.set_value(name, window, cx));
        self.provider_settings
            .executable
            .update(cx, |input, cx| input.set_value(executable, window, cx));
        self.provider_settings
            .source
            .update(cx, |input, cx| input.set_value(source, window, cx));
        let model = self
            .selected
            .as_ref()
            .filter(|thread| thread["selection"]["provider"] == "antigravity")
            .map(|thread| text(&thread["selection"], "modelID"))
            .filter(|model| !matches!(model.as_str(), "default" | "antigravity-default"))
            .unwrap_or_default();
        self.provider_settings
            .model
            .update(cx, |input, cx| input.set_value(model, window, cx));
        self.provider_settings.message = if self.provider_settings.configured() {
            "Saved configuration. Authentication has not been checked.".into()
        } else {
            "Choose the runtime and the existing profile for this account, then save.".into()
        };
        cx.notify();
    }
    fn choose_antigravity_path(
        &mut self,
        profile: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.provider_settings.busy {
            return;
        }
        let account = self.provider_settings.account.clone();
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: !profile,
            directories: profile,
            multiple: false,
            prompt: Some(
                if profile {
                    "Choose existing Antigravity profile"
                } else {
                    "Choose Antigravity executable"
                }
                .into(),
            ),
        });
        cx.spawn_in(window, async move |this, cx| {
            let result: Result<_> = async { picker.await? }.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.provider_settings.account != account || this.provider_settings.busy {
                    return;
                }
                match result {
                    Ok(Some(paths)) => {
                        if let Some(path) = paths.first() {
                            let text = path.to_string_lossy().to_string();
                            let input = if profile {
                                &this.provider_settings.source
                            } else {
                                &this.provider_settings.executable
                            };
                            input.update(cx, |input, cx| input.set_value(text, window, cx));
                            this.provider_settings.message =
                                "Path selected. Save configuration to use it.".into();
                        }
                    }
                    Ok(None) => {}
                    Err(error) => this.provider_settings.message = error.to_string(),
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn discover_antigravity_paths(&mut self, cx: &mut Context<Self>) {
        if self.provider_settings.discovering {
            return;
        }
        self.provider_settings.discovering = true;
        let report = call(&self.engine, "providers.list", json!({})).unwrap_or(json!({}));
        let home = std::env::var_os("HOME").map(PathBuf::from);
        let explicit = std::env::var_os("COINCIDE_ANTIGRAVITY_EXECUTABLE").map(PathBuf::from);
        let scan = cx
            .background_executor()
            .spawn(async move { metadata_suggestions(home.as_deref(), explicit, &report) });
        cx.spawn(async move |this, cx| {
            let suggestions = scan.await;
            let _ = this.update(cx, |this, cx| {
                this.provider_settings.suggestions = suggestions;
                this.provider_settings.discovering = false;
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn save_antigravity_configuration(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.provider_settings.busy {
            return;
        }
        let params = json!({"accountId":self.provider_settings.account,"name":self.provider_settings.name.read(cx).value().trim(),"auth":"login","executable":self.provider_settings.executable.read(cx).value().trim(),"sourceProfile":self.provider_settings.source.read(cx).value().trim()});
        let engine = self.engine.clone();
        self.provider_settings.busy = true;
        self.provider_settings.message = "Checking selected paths and saving configuration…".into();
        let save = cx
            .background_executor()
            .spawn(async move { call(&engine, "providers.antigravity.configure", params) });
        cx.spawn_in(window, async move |this, cx| {
            let result = save.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.provider_settings.busy = false;
                match result {
                    Ok(status) => {
                        this.provider_settings.report = status;
                        let account = &this.provider_settings.account;
                        let value = &this.provider_settings.report["accounts"][account];
                        let name = this.provider_settings.account_label(account, value);
                        let executable = text(value, "executable");
                        let source = text(value, "sourceProfile");
                        this.provider_settings
                            .name
                            .update(cx, |input, cx| input.set_value(name, window, cx));
                        this.provider_settings
                            .executable
                            .update(cx, |input, cx| input.set_value(executable, window, cx));
                        this.provider_settings
                            .source
                            .update(cx, |input, cx| input.set_value(source, window, cx));
                        this.provider_settings.message =
                            "Configuration saved. No sign-in or provider process was started."
                                .into();
                    }
                    Err(error) => this.provider_settings.message = error.to_string(),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn acknowledge_antigravity_risk(&mut self, cx: &mut Context<Self>) {
        if self.provider_settings.busy {
            return;
        }
        match call(
            &self.engine,
            "providers.antigravity.acknowledge",
            json!({"key":RISK_KEY,"accepted":true}),
        ) {
            Ok(status) => {
                self.provider_settings.report = status;
                self.provider_settings.message="Account risk acknowledged. Select an account below to use it in this conversation.".into();
            }
            Err(error) => self.provider_settings.message = error.to_string(),
        }
        cx.notify();
    }
    fn use_antigravity_account(&mut self, cx: &mut Context<Self>) {
        if self.provider_settings.busy || self.provider_settings.has_unsaved_changes(cx) {
            return;
        }
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            self.provider_settings.message = "Open a conversation first.".into();
            cx.notify();
            return;
        };
        let model = self
            .provider_settings
            .model
            .read(cx)
            .value()
            .trim()
            .to_owned();
        match call(
            &self.engine,
            "agent.select",
            json!({"threadId":id,"provider":"antigravity","accountId":self.provider_settings.account,"model":if model.is_empty(){"default"}else{&model}}),
        ) {
            Ok(thread) => {
                self.accept_saved_provider_selection(thread);
                self.provider_settings.open = false;
                self.settings_open = false;
                self.status = "Antigravity account selected. Send a message when ready.".into();
            }
            Err(error) => self.provider_settings.message = error.to_string(),
        }
        cx.notify();
    }
    pub(super) fn antigravity_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.provider_settings.codex_open {
            return self.codex_account_settings(cx);
        }
        let state = &self.provider_settings;
        let configured = state.configured();
        let unsaved = state.has_unsaved_changes(cx);
        let acknowledged = state.acknowledged();
        let running = self
            .selected
            .as_ref()
            .is_some_and(|thread| self.running.contains(&text(thread, "id")));
        let mut pane=div().id("antigravity-settings").flex_1().min_h_0().overflow_y_scroll().p_4().flex().flex_col().gap_3()
            .child(div().flex().justify_between().items_center().child(div().text_xl().child("Antigravity"))
                .child(Button::new("antigravity-done").label("Done").on_click(cx.listener(|this,_,_,cx|{this.provider_settings.open=false;cx.notify();}))))
            .child(div().rounded_md().border_1().border_color(rgb(0xa66b21)).p_3().flex().flex_col().gap_2()
                .child(div().text_lg().child("⚠ Antigravity Account Risk"))
                .child(div().text_sm().child(RISK_NOTICE))
                .child(div().text_sm().child(API_KEY_NOTE))
                .child(Button::new("antigravity-terms").label("Read Google’s terms").on_click(|_,_,cx|cx.open_url("https://antigravity.google/terms")))
                .when(!acknowledged,|view|view.child(div().flex().gap_2()
                    .child(Button::new("antigravity-acknowledge").label("I Understand").disabled(state.busy).on_click(cx.listener(|this,_,_,cx|this.acknowledge_antigravity_risk(cx))))
                    .child(Button::new("antigravity-risk-cancel").label("Cancel").on_click(cx.listener(|this,_,_,cx|{this.provider_settings.open=false;cx.notify();})))))
                .when(acknowledged,|view|view.child(div().text_sm().child("Account risk acknowledged."))))
            .child(div().text_sm().child("Use an existing Google subscription profile. This Rust preview does not install the runtime, start Google sign-in, or support API-key accounts yet."));
        let mut accounts = div().flex().flex_wrap().gap_2();
        let mut values = state.report["accounts"]
            .as_object()
            .map(|accounts| {
                accounts
                    .iter()
                    .map(|(id, account)| (id.clone(), state.account_label(id, account)))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if !values.iter().any(|(id, _)| id == "default") {
            values.insert(0, ("default".into(), "Default account".into()));
        }
        if !values.iter().any(|(id, _)| id == &state.account) {
            values.push((state.account.clone(), "New account".into()));
        }
        for (id, name) in values {
            let selected = id == state.account;
            accounts = accounts.child(
                Button::new(SharedString::from(format!("antigravity-account-{id}")))
                    .label(name)
                    .disabled(state.busy)
                    .when(selected, |button| button.primary())
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.edit_antigravity_account(id.clone(), window, cx)
                    })),
            );
        }
        accounts = accounts.child(
            Button::new("antigravity-add-account")
                .label("Add account")
                .disabled(state.busy)
                .on_click(cx.listener(|this, _, window, cx| {
                    this.edit_antigravity_account(uuid::Uuid::new_v4().to_string(), window, cx)
                })),
        );
        pane=pane.child(div().text_lg().child("Google account profile")).child(accounts)
            .child(Input::new(&state.name).disabled(state.busy))
            .child(div().text_sm().child("Antigravity executable — localharness_external must be beside it"))
            .child(div().flex().gap_2().child(Input::new(&state.executable).disabled(state.busy)).child(Button::new("antigravity-browse-runtime").label("Choose file…").disabled(state.busy).on_click(cx.listener(|this,_,window,cx|this.choose_antigravity_path(false,window,cx)))))
            .child(div().text_sm().child("Existing profile folder — select the folder containing antigravity-acp"))
            .child(div().flex().gap_2().child(Input::new(&state.source).disabled(state.busy)).child(Button::new("antigravity-browse-profile").label("Choose folder…").disabled(state.busy).on_click(cx.listener(|this,_,window,cx|this.choose_antigravity_path(true,window,cx)))))
            .child(div().text_sm().child("Original sign-in and conversations stay in their original profile. The Rust app uses its own private copy when a turn starts."));
        for (index, path) in state.suggestions.executables.iter().enumerate() {
            let path = path.clone();
            pane = pane.child(
                Button::new(SharedString::from(format!(
                    "antigravity-runtime-hint-{index}"
                )))
                .label(format!("Use found runtime: {path}"))
                .disabled(state.busy)
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.provider_settings
                        .executable
                        .update(cx, |input, cx| input.set_value(path.clone(), window, cx));
                    this.provider_settings.message =
                        "Runtime selected. Save configuration to use it.".into();
                    cx.notify();
                })),
            );
        }
        for (index, path) in state.suggestions.profiles.iter().enumerate() {
            let path = path.clone();
            pane = pane.child(
                Button::new(SharedString::from(format!(
                    "antigravity-profile-hint-{index}"
                )))
                .label(format!("Use found profile folder: {path}"))
                .disabled(state.busy)
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.provider_settings
                        .source
                        .update(cx, |input, cx| input.set_value(path.clone(), window, cx));
                    this.provider_settings.message =
                        "Profile selected. Authentication has not been checked.".into();
                    cx.notify();
                })),
            );
        }
        pane.child(div().flex().gap_2()
                .child(Button::new("antigravity-discover").label(if state.discovering{"Looking for paths…"}else{"Find existing installation"}).disabled(state.discovering||state.busy).on_click(cx.listener(|this,_,_,cx|this.discover_antigravity_paths(cx))))
                .child(Button::new("antigravity-save").label(if state.busy{"Saving…"}else{"Save configuration"}).disabled(state.busy).on_click(cx.listener(|this,_,window,cx|this.save_antigravity_configuration(window,cx)))))
            .child(div().text_sm().child("Found paths are metadata hints only; version, authentication and model access have not been verified."))
            .child(div().text_lg().child("Use in this conversation"))
            .child(Input::new(&state.model).disabled(state.busy))
            .child(div().text_sm().child("Leave the model empty for the account default. An explicit model must be offered by Antigravity when the session starts."))
            .child(Button::new("antigravity-use-account").label("Use selected account").primary().disabled(state.busy||unsaved||!acknowledged||!configured||self.selected.is_none()||running).on_click(cx.listener(|this,_,_,cx|this.use_antigravity_account(cx))))
            .child(div().text_sm().child(if running{"Stop the current turn before changing provider."}else if self.selected.is_none(){"Open a conversation to select this provider."}else if !configured{"Save this account’s configuration first."}else if unsaved{"Save your configuration changes before selecting this account."}else if !acknowledged{"Read and acknowledge the account risk first."}else{"Selecting this provider does not send a prompt or start sign-in."}))
            .child(div().text_sm().child(state.message.clone())).into_any_element()
    }
}

fn metadata_suggestions(
    home: Option<&std::path::Path>,
    explicit: Option<PathBuf>,
    report: &Value,
) -> Suggestions {
    let mut suggestions = Suggestions::default();
    let mut paths = Vec::new();
    if let Some(path) = explicit {
        paths.push(path);
    }
    if let Some(path) = report["discovery"]["providers"]
        .as_array()
        .and_then(|providers| {
            providers
                .iter()
                .find(|provider| provider["provider"] == "antigravity")
        })
        .and_then(|provider| provider["executable"].as_str())
    {
        paths.push(PathBuf::from(path));
    }
    #[cfg(target_os = "macos")]
    if let Some(home) = home.filter(|home| home.is_absolute()) {
        let data = home.join("Library/Application Support/Coincide");
        for platform in ["darwin-arm64", "darwin-x64"] {
            paths.push(
                data.join("tools/antigravity-acp")
                    .join(platform)
                    .join("current/agy_acp_server.par"),
            );
        }
        let profile = data.join("providers/antigravity/default");
        if profile.is_dir() {
            suggestions
                .profiles
                .push(profile.to_string_lossy().into_owned());
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = home;
    for path in paths {
        if path.is_absolute()
            && path.is_file()
            && path.with_file_name("localharness_external").is_file()
        {
            let path = path.to_string_lossy().into_owned();
            if !suggestions.executables.contains(&path) {
                suggestions.executables.push(path);
            }
        }
    }
    suggestions
}

#[cfg(test)]
mod tests {
    use super::metadata_suggestions;
    use serde_json::json;
    use std::{fs, path::PathBuf};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "coincide-provider-settings-{}",
                uuid::Uuid::new_v4()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[::core::prelude::v1::test]
    fn metadata_discovery_requires_runtime_pair_and_deduplicates_without_execution() {
        let root = Fixture::new();
        let executable = root.0.join("agy_acp_server.par");
        let contents = b"synthetic runtime: not an executable";
        fs::write(&executable, contents).unwrap();
        let report =
            json!({"discovery":{"providers":[{"provider":"antigravity","executable":executable}]}});
        assert!(
            metadata_suggestions(None, Some(executable.clone()), &report)
                .executables
                .is_empty()
        );
        fs::write(root.0.join("localharness_external"), b"synthetic helper").unwrap();
        let found = metadata_suggestions(None, Some(executable.clone()), &report);
        assert_eq!(found.executables, [executable.to_string_lossy()]);
        assert!(found.profiles.is_empty());
        assert_eq!(fs::read(&executable).unwrap(), contents);
        assert!(
            metadata_suggestions(None, Some(PathBuf::from("relative")), &json!({}))
                .executables
                .is_empty()
        );
    }

    #[::core::prelude::v1::test]
    #[cfg(target_os = "macos")]
    fn mac_profile_discovery_does_not_require_or_read_credentials() {
        let root = Fixture::new();
        let profile = root
            .0
            .join("Library/Application Support/Coincide/providers/antigravity/default");
        fs::create_dir_all(&profile).unwrap();
        let found = metadata_suggestions(Some(&root.0), None, &json!({}));
        assert_eq!(found.profiles, [profile.to_string_lossy()]);
        assert_eq!(fs::read_dir(&profile).unwrap().count(), 0);
        assert!(found.executables.is_empty());
    }
}
