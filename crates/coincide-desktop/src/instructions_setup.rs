//! Native setup controls. Persisted configuration is display-only until an
//! explicit native action adopts it; no control API can invoke these callbacks.
use super::*;
use crate::native_menu::AccessibleMenuExt as _;
use crate::{
    instructions_config::{Choice, Metadata},
    instructions_scope::{DiscoveredFile, NativeReviewPlan, NativeScope},
};
use anyhow::{Context as _, Result};
use coincide_core::api::SharedEngine;
use serde_json::Value;
use std::path::PathBuf;
#[path = "instructions_sync_ui.rs"]
mod copy_ui;
#[path = "instructions_git_ui.rs"]
mod git_ui;
use std::path::Path;
pub(super) struct Setup {
    engine: SharedEngine,
    copy: copy_ui::State,
    git: git_ui::State,
    pub(super) scope: Option<NativeScope>,
    metadata: Option<Metadata>,
    projects: Vec<Value>,
    project: Option<String>,
    project_root: Option<PathBuf>,
    files: Vec<DiscoveredFile>,
    pub(super) review: Option<NativeReviewPlan>,
    review_editor: Option<EditorFile>,
    choices: Vec<Choice>,
    disable_review: bool,
    pub(super) picker: Option<Task<()>>,
    pub(super) picker_pending: bool,
    generation: u64,
    status: String,
    initial_retry: Option<String>,
}
impl Setup {
    pub(super) fn visible_status(&self) -> String {
        let git = self.git.visible_status();
        if git.is_empty() {
            self.status.clone()
        } else {
            format!("{}\n{}", self.status, git)
        }
    }
    pub(super) fn git_busy(&self) -> bool {
        self.git.busy() || self.git.reviewing()
    }
    pub(super) fn has_copy_review(&self) -> bool {
        self.copy.review.is_some()
    }
    pub(super) fn new(engine: SharedEngine) -> Self {
        let scope = NativeScope::global_native();
        let status = scope
            .as_ref()
            .err()
            .map(ToString::to_string)
            .unwrap_or_default();
        let mut result = Self {
            engine,
            copy: copy_ui::State::new(),
            git: git_ui::State::new(),
            scope: scope.ok(),
            metadata: None,
            projects: Vec::new(),
            project: None,
            project_root: None,
            files: Vec::new(),
            review: None,
            review_editor: None,
            choices: Vec::new(),
            disable_review: false,
            picker: None,
            picker_pending: false,
            generation: 0,
            status,
            initial_retry: None,
        };
        if let Err(error) = result.refresh() {
            result.status = error.to_string();
            if crate::engine_busy(&error) {
                result.initial_retry = Some(result.status.clone());
            }
        }
        result
    }
    fn refresh(&mut self) -> Result<()> {
        let owner = crate::try_state(&self.engine)?;
        let metadata = Metadata::from_document(owner.store.document("instructions.json")?)?;
        let projects = owner
            .store
            .projects()?
            .as_array()
            .context("Projects are malformed")?
            .clone();
        let files = self
            .scope
            .as_ref()
            .map(|scope| scope.discover_native(&owner.store))
            .transpose()?;
        // Publish the read snapshot only after every part succeeds. A failed
        // discovery must not make a half-initialized pane appear ready.
        self.metadata = Some(metadata);
        self.projects = projects;
        if let Some(files) = files {
            self.files = files;
        }
        Ok(())
    }
    fn configured_path(&self) -> Result<Option<PathBuf>> {
        Ok(self
            .metadata
            .as_ref()
            .map(|m| m.configuration(self.project_root.as_deref()))
            .transpose()?
            .flatten()
            .map(|c| c.master))
    }
}
impl InstructionsPanel {
    /// Retry only a typed initial EngineBusy result on the existing owner poll.
    /// This refreshes metadata/discovery; it never adopts a master, loads editor
    /// text, creates files or writes configuration.
    pub(crate) fn poll_initial_instruction_setup(&mut self, cx: &mut Context<Self>) {
        let Some(initial) = self.setup.initial_retry.clone() else {
            return;
        };
        if self.setup.metadata.is_some() {
            self.setup.initial_retry = None;
            return;
        }
        match self.setup.refresh() {
            Ok(()) => {
                self.setup.initial_retry = None;
                if self.setup.status == initial {
                    self.setup.status.clear();
                }
                cx.notify();
            }
            Err(error) if crate::engine_busy(&error) => {}
            Err(error) => {
                self.setup.initial_retry = None;
                if self.setup.status == initial {
                    self.setup.status = error.to_string();
                }
                cx.notify();
            }
        }
    }
    fn setup_clean(&mut self, cx: &mut Context<Self>) -> bool {
        if self.dirty(cx) {
            self.setup.status = format!(
                "Save or discard edits to {} before changing the instruction file.",
                self.native_target_label()
            );
            cx.notify();
            return false;
        }
        if self.setup.picker_pending || self.setup.git.busy() {
            self.setup.status = "Finish or cancel the current instruction operation first.".into();
            cx.notify();
            return false;
        }
        // Constructor discovery is nonblocking; a busy Engine must not leave
        // native setup permanently unusable after the owner becomes available.
        if self.setup.metadata.is_none()
            && let Err(error) = self.setup.refresh()
        {
            self.setup.status = format!(
                "Instruction configuration is not ready: {error}. Try again when the current operation finishes."
            );
            cx.notify();
            return false;
        }
        true
    }
    fn bind_native_source(
        &mut self,
        scope: &NativeScope,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        let source = EditorFile::from_native_scope(scope)?;
        self.source = Some(source);
        self.native_edited = false;
        self.edit_lease.set_dirty(false);
        self.editor
            .update(cx, |editor, cx| editor.set_value("", window, cx));
        self.reload(window, cx);
        Ok(())
    }
    fn setup_switch_scope(
        &mut self,
        project: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.setup_clean(cx) {
            return;
        }
        let engine = self.setup.engine.clone();
        let result = (|| -> Result<(NativeScope, Option<PathBuf>)> {
            let owner = crate::try_state(&engine)?;
            let scope = if let Some(id) = project.as_deref() {
                NativeScope::project_native(&owner.store, id)?
            } else {
                NativeScope::global_native()?
            };
            let current_projects = owner.store.projects()?;
            let root = project
                .as_ref()
                .map(|id| {
                    current_projects
                        .as_array()
                        .context("Projects are malformed")?
                        .iter()
                        .find(|p| p["id"].as_str() == Some(id))
                        .and_then(|p| p["path"].as_str())
                        .map(PathBuf::from)
                        .context("Project disappeared; refresh setup")
                })
                .transpose()?;
            Ok((scope, root))
        })();
        match result {
            Ok((scope, root)) => {
                self.setup.generation = self.setup.generation.wrapping_add(1);
                self.setup.copy.invalidate();
                self.setup.git.invalidate();
                self.setup.review = None;
                self.setup.review_editor = None;
                self.setup.project = project;
                self.setup.project_root = root;
                self.setup.scope = Some(scope.clone());
                self.setup.status.clear();
                if let Err(e) = self.bind_native_source(&scope, window, cx) {
                    self.setup.status = e.to_string();
                }
                if let Err(e) = self.setup.refresh() {
                    self.setup.status = e.to_string();
                }
            }
            Err(e) => self.setup.status = e.to_string(),
        };
        cx.notify();
    }
    fn setup_adopt_configured(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.setup_clean(cx) {
            return;
        }
        let result = (|| -> Result<NativeScope> {
            let mut scope = self
                .setup
                .scope
                .clone()
                .context("Select an instruction scope")?;
            let metadata = self
                .setup
                .metadata
                .as_ref()
                .context("Refresh instruction configuration")?;
            let engine = self.setup.engine.clone();
            let owner = crate::try_state(&engine)?;
            scope.use_configured_master_native(metadata, &owner.store)?;
            Ok(scope)
        })();
        match result {
            Ok(scope) => {
                self.setup.generation = self.setup.generation.wrapping_add(1);
                self.setup.copy.invalidate();
                self.setup.git.invalidate();
                self.setup.review = None;
                self.setup.review_editor = None;
                self.setup.scope = Some(scope.clone());
                if let Err(e) = self.bind_native_source(&scope, window, cx) {
                    self.setup.status = e.to_string();
                } else {
                    self.setup.status =
                        "Configured master opened. Existing files and links were kept.".into();
                }
                if let Err(e) = self.setup.refresh() {
                    self.setup.status = e.to_string();
                }
            }
            Err(e) => self.setup.status = e.to_string(),
        };
        cx.notify();
    }
    fn setup_open_file(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if !self.setup_clean(cx) {
            return;
        }
        let result = (|| -> Result<NativeScope> {
            let path = self
                .setup
                .files
                .get(index)
                .context("Instruction list changed; refresh it")?
                .path
                .clone();
            let mut scope = self
                .setup
                .scope
                .clone()
                .context("Select an instruction scope")?;
            let engine = self.setup.engine.clone();
            let owner = crate::try_state(&engine)?;
            scope.choose_master_native(path, &owner.store)?;
            Ok(scope)
        })();
        match result {
            Ok(scope) => {
                self.setup.review = None;
                self.setup.review_editor = None;
                if let Err(e) = self.bind_native_source(&scope, window, cx) {
                    self.setup.status = e.to_string();
                }
            }
            Err(e) => self.setup.status = e.to_string(),
        };
        cx.notify();
    }
    fn abandon_instruction_picker(&mut self, generation: u64, cx: &mut Context<Self>) {
        if self.setup.generation == generation {
            self.setup.picker_pending = false;
            self.setup.generation = self.setup.generation.wrapping_add(1);
            self.setup.status =
                "Choice cancelled because its Settings window closed; existing setup kept.".into();
            cx.notify();
        }
    }
    fn setup_choose_master(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.setup_clean(cx) {
            return;
        }
        // A native click may begin a new review, but the asynchronous dialog
        // must retain this exact document baseline through its eventual save.
        if let Err(error) = self.setup.refresh() {
            self.setup.status = format!("Master chooser could not start: {error}");
            cx.notify();
            return;
        }
        let baseline = self
            .setup
            .metadata
            .clone()
            .expect("refresh captured metadata");
        self.setup.review = None;
        self.setup.review_editor = None;
        self.setup.picker_pending = true;
        self.setup.generation = self.setup.generation.wrapping_add(1);
        self.setup.copy.invalidate();
        self.setup.git.invalidate();
        let generation = self.setup.generation;
        let picker_lease = self.edit_lease.pending_native_action();
        let picker_owner = cx.entity().clone();
        let picker_window = window.window_handle();
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Choose instruction master".into()),
        });
        self.setup.picker = Some(cx.spawn_in(window, async move |this, cx| {
            let _picker_lease = picker_lease;
            let _picker_owner = picker_owner;
            let result: Result<_> = async { picker.await? }.await;
            let _ = crate::main_window_poll::complete_native_picker(
                picker_window,
                &this,
                cx,
                |this, window, cx| {
                    this.setup.picker_pending = false;
                    if this.setup.generation != generation || this.dirty(cx) {
                        this.setup.status =
                            "Master choice discarded because the editor changed.".into();
                        cx.notify();
                        return;
                    }
                    let result = (|| -> Result<Option<NativeScope>> {
                        let Some(paths) = result? else {
                            return Ok(None);
                        };
                        anyhow::ensure!(paths.len() == 1, "Choose one master file");
                        let mut scope = this
                            .setup
                            .scope
                            .clone()
                            .context("Select an instruction scope")?;
                        let engine = this.setup.engine.clone();
                        let mut owner = crate::try_state(&engine)?;
                        scope.choose_master_native(paths[0].clone(), &owner.store)?;
                        // The native chooser supplied this path; importing metadata
                        // alone never reaches this configuration/write capability.
                        let enabled = baseline
                            .configuration(this.setup.project_root.as_deref())?
                            .is_some_and(|c| c.enabled);
                        this.setup.metadata = Some(scope.persist_configuration_native(
                            &mut owner.store,
                            &baseline,
                            enabled,
                        )?);
                        Ok(Some(scope))
                    })();
                    match result {
                        Ok(Some(scope)) => {
                            this.setup.scope = Some(scope.clone());
                            if let Err(e) = this.bind_native_source(&scope, window, cx) {
                                this.setup.status = e.to_string();
                            } else {
                                this.setup.status =
                                    "Master selected. Review links to use it for your agents."
                                        .into();
                            }
                            if let Err(e) = this.setup.refresh() {
                                this.setup.status = e.to_string();
                            }
                        }
                        Ok(None) => {
                            this.setup.status =
                                "Master choice cancelled; existing setup kept.".into()
                        }
                        Err(e) => this.setup.status = e.to_string(),
                    };
                    cx.notify();
                },
                move |this, cx| this.abandon_instruction_picker(generation, cx),
            );
        }));
        cx.notify();
    }
    fn setup_create_master(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.setup_clean(cx) {
            return;
        }
        let result = (|| -> Result<NativeScope> {
            let scope = self
                .setup
                .scope
                .clone()
                .context("Select an instruction scope")?;
            let engine = self.setup.engine.clone();
            let owner = crate::try_state(&engine)?;
            scope.create_master_native(&owner.store, "# Instructions\n\n")?;
            Ok(scope)
        })();
        match result {
            Ok(scope) => {
                if let Err(e) = self.bind_native_source(&scope, window, cx) {
                    self.setup.status = e.to_string();
                } else {
                    self.setup.status = "Master created. Edit it and choose Save.".into();
                }
                if let Err(e) = self.setup.refresh() {
                    self.setup.status = e.to_string();
                }
            }
            Err(e) => self.setup.status = e.to_string(),
        };
        cx.notify();
    }
    fn setup_prepare_links(&mut self, cx: &mut Context<Self>) {
        self.setup.disable_review = false;
        self.setup.copy.invalidate_review();
        if !self.setup_clean(cx) {
            return;
        }
        self.setup.review = None;
        self.setup.review_editor = None;
        let result = (|| -> Result<(NativeReviewPlan, Option<EditorFile>)> {
            let scope = self
                .setup
                .scope
                .clone()
                .context("Select an instruction scope")?;
            let engine = self.setup.engine.clone();
            let owner = crate::try_state(&engine)?;
            // Capture writer authority BEFORE the plan. A later same-byte inode
            // replacement cannot become a newly adopted Save capability.
            let mut writer = EditorFile::from_native_scope(&scope)?;
            let writer = match writer.load() {
                Ok(_) => Some(writer),
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
                {
                    None
                }
                Err(error) => return Err(error),
            };
            let plan = scope.review_native(&owner.store)?;
            anyhow::ensure!(
                plan.has_existing_master() == writer.is_some(),
                "Master appeared or disappeared during review; retry"
            );
            if let Some(writer) = &writer {
                writer.validate_review_source()?;
                let choices = vec![Choice::Skip; plan.targets.len()];
                anyhow::ensure!(
                    writer.baseline() == Some(plan.preview_text(&choices)?.as_str()),
                    "Master changed during review; retry"
                );
            }
            Ok((plan, writer))
        })();
        match result {
            Ok((plan, writer)) => {
                self.setup.choices = plan
                    .targets
                    .iter()
                    .map(|t| t.state.default_choice())
                    .collect();
                self.setup.review_editor = writer;
                self.setup.review = Some(plan);
                self.setup.status = "Review every target before saving and applying links.".into();
            }
            Err(error) => self.setup.status = error.to_string(),
        }
        cx.notify();
    }
    fn setup_prepare_disable(&mut self, cx: &mut Context<Self>) {
        self.setup_prepare_links(cx);
        if self.setup.review.is_some() {
            self.setup.disable_review = true;
            self.setup.status =
                "Choose whether to keep links or replace this master's links with separate copies."
                    .into();
        }
        cx.notify();
    }
    fn setup_confirm_disable(
        &mut self,
        replace: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.dirty(cx) {
            self.setup.status =
                "Save or discard editor changes before disabling the shared master.".into();
            cx.notify();
            return;
        }
        let Some(plan) = self.setup.review.take() else {
            return;
        };
        self.setup.copy.invalidate();
        self.setup.git.invalidate();
        self.setup.review_editor = None;
        let result = (|| -> Result<(NativeScope, Vec<crate::instructions_scope::LinkOutcome>)> {
            let engine = self.setup.engine.clone();
            let mut owner = crate::try_state(&engine)?;
            let (scope, outcomes) = plan.disable_native(&owner.store, replace)?;
            if outcomes.iter().all(|o| o.error.is_none()) {
                let baseline = self
                    .setup
                    .metadata
                    .as_ref()
                    .context("Refresh instruction configuration")?;
                self.setup.metadata =
                    Some(scope.persist_configuration_native(&mut owner.store, baseline, false)?);
            }
            Ok((scope, outcomes))
        })();
        match result {
            Ok((scope, outcomes)) => {
                let converted = outcomes.iter().filter(|o| o.linked).count();
                let failed = outcomes.iter().any(|o| o.error.is_some());
                let mut status = if failed {
                    format!(
                        "Copied {converted} link(s); shared-master configuration was kept because a file operation failed."
                    )
                } else if replace {
                    format!(
                        "Shared-master mode turned off; {converted} link(s) replaced with separate copies."
                    )
                } else {
                    "Shared-master mode turned off. Existing links still read the master.".into()
                };
                for outcome in outcomes {
                    if let Some(backup) = outcome.backup {
                        status.push_str(&format!(" Backup: {}.", backup.display()));
                    }
                    if let Some(error) = outcome.error {
                        status.push_str(&format!(
                            " {}: {error}. Setup was only partially changed.",
                            outcome.path.display()
                        ));
                    }
                }
                self.setup.scope = Some(scope.clone());
                if let Err(e) = self.bind_native_source(&scope, window, cx) {
                    status.push_str(&format!(" {e}"));
                }
                self.setup.status = status;
                if let Err(e) = self.setup.refresh() {
                    self.setup.status.push_str(&format!(" {e}"));
                }
            }
            Err(error) => {
                self.setup.status = format!("Shared-master setup was not changed: {error}")
            }
        };
        cx.notify();
    }
    fn setup_apply_links(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.dirty(cx) {
            self.setup.status =
                "The editor changed. Cancel this review and save or discard your edits first."
                    .into();
            cx.notify();
            return;
        }
        let Some(plan) = self.setup.review.take() else {
            return;
        };
        let mut review_editor = self.setup.review_editor.take();
        let result = (|| -> Result<(NativeScope, Vec<crate::instructions_scope::LinkOutcome>)> {
            let engine = self.setup.engine.clone();
            let mut owner = crate::try_state(&engine)?;
            let scope = self
                .setup
                .scope
                .clone()
                .context("Instruction scope disappeared")?;
            let (scope, outcomes) =
                plan.apply_native(&owner.store, &self.setup.choices, |path, expected, text| {
                    anyhow::ensure!(path == scope.master_path(), "Reviewed master changed");
                    let editor = review_editor
                        .as_mut()
                        .context("Reviewed master writer is unavailable; review again")?;
                    anyhow::ensure!(
                        editor.path() == path && editor.baseline() == Some(expected),
                        "Reviewed writer belongs to another source"
                    );
                    editor.save(text)
                })?;
            let failed = outcomes.iter().any(|o| o.error.is_some());
            if !failed {
                let metadata = self
                    .setup
                    .metadata
                    .as_ref()
                    .context("Instruction configuration unavailable")?;
                self.setup.metadata =
                    Some(scope.persist_configuration_native(&mut owner.store, metadata, true)?);
            }
            Ok((scope, outcomes))
        })();
        match result {
            Ok((scope, outcomes)) => {
                let linked = outcomes.iter().filter(|o| o.linked).count();
                let mut status = format!(
                    "{linked} file(s) linked to {}.",
                    scope.master_path().display()
                );
                for outcome in outcomes {
                    if let Some(backup) = outcome.backup {
                        status.push_str(&format!(" Backup: {}.", backup.display()));
                    }
                    if let Some(error) = outcome.error {
                        status.push_str(&format!(" {}: {error}.", outcome.path.display()));
                    }
                }
                self.setup.scope = Some(scope.clone());
                if let Err(e) = self.bind_native_source(&scope, window, cx) {
                    status.push_str(&format!(" {e}"));
                }
                self.setup.status = status;
                if let Err(e) = self.setup.refresh() {
                    self.setup.status.push_str(&format!(" {e}"));
                }
            }
            Err(e) => {
                self.setup.status = format!(
                    "Setup was not completed: {e}. Existing backups are retained; review files before retrying."
                )
            }
        };
        cx.notify();
    }
    pub(super) fn instructions_sidebar(&self, cx: &mut Context<Self>) -> AnyElement {
        use gpui_kit::component::menu::PopupMenuItem;
        let pending = self.setup.picker_pending
            || self.setup.review.is_some()
            || self.setup.has_copy_review()
            || self.setup.git_busy();
        let project_name = self
            .setup
            .project
            .as_ref()
            .and_then(|id| {
                self.setup
                    .projects
                    .iter()
                    .find(|project| project["id"] == *id)
            })
            .and_then(|project| project["name"].as_str())
            .unwrap_or("Global");
        let mut choices = vec![(None, "Global".to_owned())];
        choices.extend(self.setup.projects.iter().filter_map(|project| {
            Some((
                Some(project["id"].as_str()?.to_owned()),
                project["name"].as_str().unwrap_or("Project").to_owned(),
            ))
        }));
        let selected = self.setup.project.clone();
        let owner = cx.entity().downgrade();
        let current = self.source.as_ref().map(|source| source.path());
        let mut sidebar = div().id("instructions-sidebar").w(px(210.)).flex_shrink_0().min_h_0().overflow_y_scroll().p_3().flex().flex_col().gap_3()
            .bg(cx.theme().muted).border_r_1().border_color(cx.theme().border)
            .child(Button::new("instructions-scope").label(project_name.to_owned()).disabled(pending).dropdown_caret(true)
                .accessible_menu(move|mut menu,_,_|{for (id,label) in &choices {let owner=owner.clone();let id=id.clone();menu=menu.item(PopupMenuItem::new(label.clone()).checked(id==selected).on_click(move|_,window,cx|{let _=owner.update(cx,|this,cx|this.setup_switch_scope(id.clone(),window,cx));}));}menu}))
            .child(div().flex().flex_col().gap_2().p_2().rounded_md().bg(cx.theme().background)
                .child(div().text_sm().font_semibold().child("Shared instructions"))
                .child(div().text_xs().text_color(cx.theme().muted_foreground).child("Use one master file across your agents. Review changes before linking existing files."))
                .child(Button::new("instructions-manage").label(if self.setup_open {"Hide setup and sync"} else {"Setup and sync…"}).compact().ghost()
                    .on_click(cx.listener(|this,_,_,cx|{this.setup_open=!this.setup_open;cx.notify();}))));
        if let Some(scope) = &self.setup.scope {
            let path = scope.master_path();
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "Master file".into());
            sidebar = sidebar.child(
                Button::new("instructions-master-file")
                    .accessibility_label(name.clone())
                    .child(div().w_full().text_left().truncate().child(name))
                    .w_full()
                    .compact()
                    .selected(current == Some(path))
                    .disabled(pending)
                    .on_click(cx.listener(|this, _, window, cx| {
                        if !this.setup_clean(cx) {
                            return;
                        }
                        if let Some(scope) = this.setup.scope.clone() {
                            if let Err(error) = this.bind_native_source(&scope, window, cx) {
                                this.status = error.to_string();
                            }
                            cx.notify();
                        }
                    })),
            );
        }
        sidebar = sidebar.child(
            div()
                .text_xs()
                .text_color(cx.theme().muted_foreground)
                .child("Agent files"),
        );
        for (index, file) in self
            .setup
            .files
            .iter()
            .enumerate()
            .filter(|(_, file)| file.exists)
        {
            sidebar = sidebar.child(
                Button::new(SharedString::from(format!("instructions-source-{index}")))
                    .accessibility_label(file.name.clone())
                    .child(
                        div()
                            .w_full()
                            .text_left()
                            .truncate()
                            .child(file.name.clone()),
                    )
                    .w_full()
                    .compact()
                    .selected(current == Some(file.path.as_path()))
                    .disabled(pending || !file.readable)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.setup_open_file(index, window, cx)
                    })),
            );
        }
        sidebar
            .when(self.setup_open, |view| view.child(self.setup_controls(cx)))
            .when(!self.setup.visible_status().is_empty(), |view| {
                view.child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(self.setup.visible_status()),
                )
            })
            .into_any_element()
    }
    pub(super) fn setup_controls(&self, cx: &mut Context<Self>) -> AnyElement {
        let pending = self.setup.picker_pending
            || self.setup.review.is_some()
            || self.setup.has_copy_review()
            || self.setup.git_busy();
        let mut scopes = div().flex().flex_wrap().gap_1().child(
            Button::new("instructions-global-scope")
                .label("Global")
                .disabled(pending)
                .when(self.setup.project.is_none(), |b| b.primary())
                .on_click(
                    cx.listener(|this, _, window, cx| this.setup_switch_scope(None, window, cx)),
                ),
        );
        for project in self.setup.projects.iter().take(200) {
            let Some(id) = project["id"].as_str() else {
                continue;
            };
            let id = id.to_owned();
            let selected = self.setup.project.as_ref() == Some(&id);
            scopes = scopes.child(
                Button::new(SharedString::from(format!("instructions-project-{id}")))
                    .label(project["name"].as_str().unwrap_or("Project").to_owned())
                    .disabled(pending)
                    .when(selected, |b| b.primary())
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.setup_switch_scope(Some(id.clone()), window, cx)
                    })),
            );
        }
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_2()
            .child(scopes)
            .child(format!("Editing: {}", self.native_target_label()));
        if let Some(scope) = &self.setup.scope {
            pane = pane.child(format!(
                "{} master: {}",
                scope.label(),
                scope.master_path().display()
            ));
        }
        match self.setup.configured_path() {
            Ok(Some(path)) => {
                pane = pane
                    .child(format!("Configured master: {}", path.display()))
                    .child(
                        Button::new("instructions-use-configured")
                            .label("Open Configured Master")
                            .disabled(pending)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.setup_adopt_configured(window, cx)
                            })),
                    );
            }
            Err(e) => pane = pane.child(e.to_string()),
            _ => {}
        }
        pane = pane.child(
            div()
                .flex()
                .flex_wrap()
                .gap_2()
                .child(
                    Button::new("instructions-choose-master")
                        .label("Choose Master…")
                        .disabled(pending)
                        .on_click(
                            cx.listener(|this, _, window, cx| this.setup_choose_master(window, cx)),
                        ),
                )
                .child(
                    Button::new("instructions-create-master")
                        .label("Create Master")
                        .disabled(
                            pending || self.source.as_ref().is_some_and(|s| s.baseline().is_some()),
                        )
                        .on_click(
                            cx.listener(|this, _, window, cx| this.setup_create_master(window, cx)),
                        ),
                )
                .child(
                    Button::new("instructions-review-links")
                        .label("Review Links…")
                        .disabled(pending || self.setup.scope.is_none())
                        .on_click(cx.listener(|this, _, _, cx| this.setup_prepare_links(cx))),
                )
                .child(
                    Button::new("instructions-disable-master")
                        .label("Turn Off Shared Master…")
                        .disabled(pending || self.setup.scope.is_none())
                        .on_click(cx.listener(|this, _, _, cx| this.setup_prepare_disable(cx))),
                )
                .child(
                    Button::new("instructions-refresh-setup")
                        .label("Refresh Files")
                        .disabled(pending)
                        .on_click(cx.listener(|this, _, _, cx| {
                            match this.setup.refresh() {
                                Ok(()) => {
                                    this.setup.status = "Instruction file list refreshed".into()
                                }
                                Err(e) => this.setup.status = e.to_string(),
                            };
                            cx.notify();
                        })),
                ),
        );
        let mut files = div().flex().flex_wrap().gap_1();
        for (index, file) in self.setup.files.iter().enumerate() {
            if !file.exists {
                continue;
            }
            files = files.child(
                Button::new(SharedString::from(format!("instructions-source-{index}")))
                    .label(format!(
                        "{}{}",
                        file.name,
                        if file.linked { " · Linked" } else { "" }
                    ))
                    .disabled(pending || !file.readable)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.setup_open_file(index, window, cx)
                    })),
            );
        }
        div()
            .id("instruction-setup-controls")
            .w_full()
            .min_w_0()
            .child(
                pane.child(files)
                    .child(self.copy_controls(cx))
                    .child(self.git_copy_controls(cx))
                    .child(self.setup.status.clone()),
            )
            .into_any_element()
    }
    pub(super) fn setup_review(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut pane = div().flex().flex_col().gap_2();
        if let Some(review) = &self.setup.review {
            if self.setup.disable_review {
                pane=pane.child(format!("Turn off shared-master mode for {}?",review.master_path().display())).child("Only links to this master can become copies. Other files and foreign links stay unchanged.");
                for target in review
                    .targets
                    .iter()
                    .filter(|t| t.state == crate::instructions_config::TargetState::Linked)
                {
                    pane = pane.child(target.path.display().to_string());
                }
                return pane
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_2()
                            .child(
                                Button::new("instructions-disable-cancel")
                                    .label("Cancel")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.setup.review = None;
                                        this.setup.review_editor = None;
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("instructions-disable-keep")
                                    .label("Keep Links and Turn Off")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.setup_confirm_disable(false, window, cx)
                                    })),
                            )
                            .child(
                                Button::new("instructions-disable-copies")
                                    .label("Replace Links with Copies")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.setup_confirm_disable(true, window, cx)
                                    })),
                            ),
                    )
                    .into_any_element();
            }
            pane = pane.child("Proposed master text").child(
                div()
                    .id("instruction-plan-preview")
                    .max_h(px(140.))
                    .overflow_y_scroll()
                    .font_family("monospace")
                    .child(match review.preview_text(&self.setup.choices) {
                        Ok(text) => text,
                        Err(e) => e.to_string(),
                    }),
            );
            pane = pane.child(format!("Link files to {}", review.master_path().display()));
            for (index, target) in review.targets.iter().enumerate() {
                let mut row = div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_1()
                    .child(format!("{} · {}", target.label, target.state.label()));
                for (choice, label) in [
                    (Choice::Merge, "Merge"),
                    (Choice::UseMaster, "Use Master"),
                    (Choice::Skip, "Skip"),
                ] {
                    let disabled = choice == Choice::Merge
                        && target.state != crate::instructions_config::TargetState::Differs;
                    let selected = self.setup.choices.get(index) == Some(&choice);
                    row = row.child(
                        Button::new(SharedString::from(format!(
                            "instructions-choice-{index}-{label}"
                        )))
                        .label(label)
                        .disabled(disabled)
                        .when(selected, |b| b.primary())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(selected) = this.setup.choices.get_mut(index) {
                                *selected = choice;
                            }
                            cx.notify();
                        })),
                    );
                }
                pane = pane.child(row);
            }
            pane=pane.child("Separate files are kept in backups before links replace them. Foreign links stay unchanged unless you choose Use Master.").child(div().flex().gap_2().child(Button::new("instructions-cancel-plan").label("Cancel").on_click(cx.listener(|this,_,_,cx|{this.setup.review=None;this.setup.review_editor=None;this.setup.status="Link review cancelled; no changes were made.".into();cx.notify();})))
            .child(Button::new("instructions-apply-plan").label("Save and Apply Links").on_click(cx.listener(|this,_,window,cx|this.setup_apply_links(window,cx)))));
        }
        if let Some(metadata) = &self.setup.metadata {
            if let Ok(Some(config)) = metadata.configuration(self.setup.project_root.as_deref()) {
                for status in config.copy_status() {
                    pane = pane.child(status);
                }
            }
        }
        pane.child(self.copy_review(cx)).into_any_element()
    }
}

#[cfg(test)]
#[path = "instructions_headless_tests.rs"]
mod headless_tests;
