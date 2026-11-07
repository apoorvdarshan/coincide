//! Native copy picker and explicit, captured three-way sync review.
use super::*;
use crate::instructions::sync::{Keep, Plan, Receipt, Step};
pub(super) struct State {
    scope: Option<NativeScope>,
    pub(super) review: Option<Plan>,
    baseline: Option<Metadata>,
    receipt: Option<Receipt>,
}
impl State {
    pub(super) fn new() -> Self {
        Self {
            scope: None,
            review: None,
            baseline: None,
            receipt: None,
        }
    }
    pub(super) fn native_scope(&self) -> Option<NativeScope> {
        self.scope.clone()
    }
    pub(super) fn invalidate(&mut self) {
        self.scope = None;
        self.receipt = None;
        self.review = None;
        self.baseline = None;
    }
    pub(super) fn invalidate_review(&mut self) {
        self.review = None;
        self.baseline = None;
    }
}
impl InstructionsPanel {
    fn copy_picker_result(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let result = (|| -> Result<NativeScope> {
            let mut scope = self
                .setup
                .scope
                .clone()
                .context("Select an instruction master")?;
            let engine = self.setup.engine.clone();
            let mut owner = crate::try_state(&engine)?;
            scope.choose_master_native(path, &owner.store)?;
            let baseline = self
                .setup
                .metadata
                .as_ref()
                .context("Refresh configuration")?;
            let preview = Plan::capture(
                self.setup.scope.clone().unwrap(),
                scope.clone(),
                &owner.store,
                None,
            )?;
            anyhow::ensure!(
                preview.master_text().is_some() || preview.copy_text().is_some(),
                "Create a master or choose an existing copy before syncing"
            );
            self.setup.metadata = Some(
                self.setup
                    .scope
                    .as_ref()
                    .unwrap()
                    .persist_file_copy_native(&mut owner.store, baseline, Some(&scope), None)?,
            );
            Ok(scope)
        })();
        match result {
            Ok(scope) => {
                self.setup.copy.receipt = None;
                self.setup.copy.scope = Some(scope);
                self.prepare_copy_sync(cx);
            }
            Err(error) => self.setup.status = format!("Copy was not selected: {error}"),
        };
        cx.notify();
    }
    pub(super) fn choose_instruction_copy(
        &mut self,
        new_file: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.setup_clean(cx) {
            return;
        }
        self.setup.copy.invalidate_review();
        self.setup.git.invalidate();
        self.setup.picker_pending = true;
        self.setup.generation = self.setup.generation.wrapping_add(1);
        let generation = self.setup.generation;
        let directory = self
            .setup
            .scope
            .as_ref()
            .and_then(|s| s.master_path().parent())
            .map(Path::to_owned);
        let picker_window = window.window_handle();
        if new_file {
            let Some(directory) = directory else {
                self.setup.picker_pending = false;
                return;
            };
            let picker_lease = self.edit_lease.pending_native_action();
            let picker_owner = cx.entity().clone();
            let picker = cx.prompt_for_new_path(&directory, Some("Instructions-copy.md"));
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
                                "Copy choice expired because the editor changed.".into();
                            cx.notify();
                            return;
                        }
                        match result {
                            Ok(Some(path)) => this.copy_picker_result(path, window, cx),
                            Ok(None) => {
                                this.setup.status = "Copy choice cancelled".into();
                                cx.notify();
                            }
                            Err(error) => {
                                this.setup.status = format!("Copy picker failed: {error}");
                                cx.notify();
                            }
                        }
                    },
                    move |this, cx| this.abandon_instruction_picker(generation, cx),
                );
            }));
        } else {
            let picker_lease = self.edit_lease.pending_native_action();
            let picker_owner = cx.entity().clone();
            let picker = cx.prompt_for_paths(PathPromptOptions {
                files: true,
                directories: false,
                multiple: false,
                prompt: Some("Choose instruction copy".into()),
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
                                "Copy choice expired because the editor changed.".into();
                            cx.notify();
                            return;
                        }
                        match result {
                            Ok(Some(paths)) if paths.len() == 1 => {
                                this.copy_picker_result(paths[0].clone(), window, cx)
                            }
                            Ok(None) => {
                                this.setup.status = "Copy choice cancelled".into();
                                cx.notify();
                            }
                            Ok(_) => {
                                this.setup.status = "Choose one copy file".into();
                                cx.notify();
                            }
                            Err(error) => {
                                this.setup.status = format!("Copy picker failed: {error}");
                                cx.notify();
                            }
                        }
                    },
                    move |this, cx| this.abandon_instruction_picker(generation, cx),
                );
            }));
        }
        cx.notify();
    }
    pub(super) fn prepare_copy_sync(&mut self, cx: &mut Context<Self>) {
        if !self.setup_clean(cx) {
            return;
        }
        self.setup.copy.invalidate_review();
        let result = (|| -> Result<(Plan, Metadata)> {
            let scope = self.setup.scope.clone().context("Select a master")?;
            let copy = self
                .setup
                .copy
                .scope
                .clone()
                .context("Choose a copy with the native picker first")?;
            let engine = self.setup.engine.clone();
            let owner = crate::try_state(&engine)?;
            let actual = Metadata::from_document(owner.store.document("instructions.json")?)?;
            let baseline = self
                .setup
                .metadata
                .as_ref()
                .context("Refresh instruction configuration")?;
            anyhow::ensure!(
                actual.document == baseline.document,
                "Configuration changed; refresh before syncing"
            );
            let config = baseline
                .configuration(self.setup.project_root.as_deref())?
                .context("Copy configuration disappeared")?;
            anyhow::ensure!(
                config.raw["fileCopy"]["path"] == serde_json::json!(copy.master_path()),
                "Configured copy changed; choose it again with the native picker"
            );
            Ok((
                Plan::capture(scope, copy, &owner.store, self.setup.copy.receipt.as_ref())?,
                baseline.clone(),
            ))
        })();
        match result {
            Ok((plan, baseline)) => {
                self.setup.copy.review = Some(plan);
                self.setup.copy.baseline = Some(baseline);
                self.setup.status = "Review both versions before saving synchronized files.".into();
            }
            Err(error) => self.setup.status = format!("Copy sync could not be reviewed: {error}"),
        };
        cx.notify();
    }
    pub(super) fn apply_copy_sync(
        &mut self,
        keep: Option<Keep>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.dirty(cx) {
            self.setup.status = "Save or discard editor changes before applying copy sync.".into();
            cx.notify();
            return;
        }
        let Some(plan) = self.setup.copy.review.take() else {
            return;
        };
        let baseline = self.setup.copy.baseline.take();
        let result = (|| -> Result<(NativeScope, Vec<PathBuf>)> {
            let engine = self.setup.engine.clone();
            let mut owner = crate::try_state(&engine)?;
            let baseline = baseline.context("Copy review expired")?;
            let actual = Metadata::from_document(owner.store.document("instructions.json")?)?;
            anyhow::ensure!(
                actual.document == baseline.document,
                "Configuration changed after sync review; no files were written"
            );
            let master = plan.master_scope.clone();
            let copy = plan.copy_scope.clone();
            let applied = plan.apply(&owner.store, keep)?;
            self.setup.metadata = Some(master.persist_file_copy_native(
                &mut owner.store,
                &baseline,
                Some(&copy),
                applied.agreed_for_metadata(),
            )?);
            self.setup.copy.receipt = applied.receipt;
            Ok((master, applied.backups))
        })();
        match result {
            Ok((scope, backups)) => {
                let mut status = "Master and file copy are synchronized.".to_owned();
                for path in backups {
                    status.push_str(&format!(" Preserved version: {}.", path.display()));
                }
                if let Err(error) = self.bind_native_source(&scope, window, cx) {
                    status.push_str(&format!(" Reload needed: {error}"));
                }
                self.setup.status = status;
            }
            Err(error) => {
                self.setup.status = format!(
                    "Copy sync did not complete: {error}. Existing recovery versions are retained; review files before retrying."
                )
            }
        };
        cx.notify();
    }
    fn unlink_instruction_copy(&mut self, cx: &mut Context<Self>) {
        if !self.setup_clean(cx) {
            return;
        }
        let result = (|| -> Result<Metadata> {
            let engine = self.setup.engine.clone();
            let mut owner = crate::try_state(&engine)?;
            self.setup
                .scope
                .as_ref()
                .context("Select a master")?
                .persist_file_copy_native(
                    &mut owner.store,
                    self.setup
                        .metadata
                        .as_ref()
                        .context("Refresh configuration")?,
                    None,
                    None,
                )
        })();
        match result {
            Ok(metadata) => {
                self.setup.metadata = Some(metadata);
                self.setup.copy.invalidate();
                self.setup.status = "Copy sync disconnected. Both files were kept.".into();
            }
            Err(error) => self.setup.status = error.to_string(),
        };
        cx.notify();
    }
    pub(super) fn copy_controls(&self, cx: &mut Context<Self>) -> AnyElement {
        let busy = self.setup.review.is_some()
            || self.setup.copy.review.is_some()
            || self.setup.picker_pending
            || self.setup.git_busy();
        let configured = self
            .setup
            .metadata
            .as_ref()
            .and_then(|m| {
                m.configuration(self.setup.project_root.as_deref())
                    .ok()
                    .flatten()
            })
            .and_then(|c| c.raw["fileCopy"]["path"].as_str().map(str::to_owned));
        let mut pane=div().flex().flex_col().gap_2().child(div().text_lg().child("File Copy Sync")).child("Keep a separate file in step with this master. Every change is reviewed before Save; your cloud folder can sync that file between computers.");
        if let Some(path) = &configured {
            pane = pane.child(format!("Configured copy: {path}"));
        }
        pane.child(
            div()
                .flex()
                .flex_wrap()
                .gap_2()
                .child(
                    Button::new("instructions-copy-new")
                        .label("New Copy…")
                        .disabled(busy || self.setup.scope.is_none())
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.choose_instruction_copy(true, window, cx)
                        })),
                )
                .child(
                    Button::new("instructions-copy-choose")
                        .label("Choose Existing Copy…")
                        .disabled(busy || self.setup.scope.is_none())
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.choose_instruction_copy(false, window, cx)
                        })),
                )
                .child(
                    Button::new("instructions-copy-review")
                        .label("Review Sync…")
                        .disabled(busy || self.setup.copy.scope.is_none())
                        .on_click(cx.listener(|this, _, _, cx| this.prepare_copy_sync(cx))),
                )
                .child(
                    Button::new("instructions-copy-unlink")
                        .label("Disconnect Copy")
                        .disabled(busy || configured.is_none())
                        .on_click(cx.listener(|this, _, _, cx| this.unlink_instruction_copy(cx))),
                ),
        )
        .into_any_element()
    }
    pub(super) fn copy_review(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(plan) = &self.setup.copy.review else {
            return div().into_any_element();
        };
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_2()
            .child("Review File Copy Sync")
            .child(format!(
                "Master: {}",
                plan.master_scope.master_path().display()
            ))
            .child(
                div()
                    .id("instructions-copy-master-preview")
                    .max_h(px(130.))
                    .overflow_y_scroll()
                    .font_family("monospace")
                    .child(plan.master_text().unwrap_or("(missing file)").to_owned()),
            )
            .child(format!("Copy: {}", plan.copy_scope.master_path().display()))
            .child(
                div()
                    .id("instructions-copy-file-preview")
                    .max_h(px(130.))
                    .overflow_y_scroll()
                    .font_family("monospace")
                    .child(plan.copy_text().unwrap_or("(missing file)").to_owned()),
            );
        if plan.step == Step::Conflict {
            pane=pane.child("Both versions changed or have never agreed. Choose which to keep; both original versions will be preserved in private backups.");
        }
        let mut actions = div().flex().flex_wrap().gap_2().child(
            Button::new("instructions-copy-cancel")
                .label("Cancel")
                .on_click(cx.listener(|this, _, _, cx| {
                    this.setup.copy.invalidate_review();
                    this.setup.status = "Sync review cancelled; no files were changed.".into();
                    cx.notify();
                })),
        );
        if plan.master_text().is_none() && plan.copy_text().is_none() {
            return pane
                .child(
                    "Neither file exists. Cancel and create a master or choose an existing copy.",
                )
                .child(actions)
                .into_any_element();
        }
        match plan.step {
            Step::Matching => {
                actions = actions.child(
                    Button::new("instructions-copy-matching")
                        .label("Record Matching Files")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.apply_copy_sync(None, window, cx)
                        })),
                )
            }
            Step::UpdateCopy => {
                actions = actions.child(
                    Button::new("instructions-copy-update")
                        .label("Save Master to Copy")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.apply_copy_sync(None, window, cx)
                        })),
                )
            }
            Step::UpdateMaster => {
                actions = actions.child(
                    Button::new("instructions-master-update")
                        .label("Save Copy to Master")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.apply_copy_sync(None, window, cx)
                        })),
                )
            }
            Step::Conflict => {
                actions = actions
                    .child(
                        Button::new("instructions-copy-keep-master")
                            .label("Keep Master; Save Copy")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.apply_copy_sync(Some(Keep::Master), window, cx)
                            })),
                    )
                    .child(
                        Button::new("instructions-copy-keep-copy")
                            .label("Keep Copy; Save Master")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.apply_copy_sync(Some(Keep::Copy), window, cx)
                            })),
                    );
            }
        }
        pane.child(actions).into_any_element()
    }
}
