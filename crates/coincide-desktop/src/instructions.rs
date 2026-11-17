//! Native instruction editor and reviewed scoped setup. Only this component's native human Save
//! callback invokes the bound file writer. No API/tool route can submit text.
#[path = "instructions_file.rs"]
mod file;
#[path = "instructions_git.rs"]
mod git;
#[path = "instructions_setup.rs"]
mod setup;
#[path = "instructions_sync.rs"]
mod sync;
use file::EditorFile;
use gpui_kit::assets::IconName;
use gpui_kit::{
    base::Disableable,
    component::{
        ActiveTheme, Icon, Selectable, StyledExt,
        button::*,
        input::{InputEvent, Textarea, TextareaState},
    },
    prelude::FluentBuilder,
    *,
};

pub(super) struct InstructionsPanel {
    setup: setup::Setup,
    source: Option<EditorFile>,
    edit_lease: coincide_core::native_ui_edits::NativeUiEditLease,
    editor: Entity<TextareaState>,
    status: String,
    blocked: bool,
    native_edited: bool,
    setup_open: bool,
    _subscription: Subscription,
}
impl InstructionsPanel {
    pub(super) fn new(
        engine: coincide_core::api::SharedEngine,
        edit_lease: coincide_core::native_ui_edits::NativeUiEditLease,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let editor = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Instructions")
                .submit_on_enter(false)
        });
        let subscription = cx.subscribe(&editor, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.native_edited = true;
                let dirty = this.dirty(cx);
                this.edit_lease.set_dirty(dirty);
                cx.notify();
            }
        });
        let setup = setup::Setup::new(engine);
        let (source, status) = match setup
            .scope
            .as_ref()
            .map(EditorFile::from_native_scope)
            .transpose()
        {
            Ok(source) => (source, String::new()),
            Err(error) => (None, error.to_string()),
        };
        let mut panel = Self {
            setup,
            source,
            edit_lease,
            editor,
            status,
            blocked: false,
            native_edited: false,
            setup_open: false,
            _subscription: subscription,
        };
        panel.reload(window, cx);
        panel
    }
    pub(super) fn native_target_label(&self) -> String {
        self.source
            .as_ref()
            .map(|s| s.path().display().to_string())
            .or_else(|| {
                self.setup
                    .scope
                    .as_ref()
                    .map(|s| s.master_path().display().to_string())
            })
            .unwrap_or_else(|| "Instructions".into())
    }
    fn dirty(&self, cx: &App) -> bool {
        self.native_edited
            && self
                .source
                .as_ref()
                .and_then(EditorFile::baseline)
                .is_some_and(|baseline| {
                    let draft = self.editor.read(cx).text();
                    if draft.len() != baseline.len() {
                        return true;
                    }
                    let mut remaining = baseline;
                    !draft.chunks().all(|chunk| {
                        if let Some(rest) = remaining.strip_prefix(chunk) {
                            remaining = rest;
                            true
                        } else {
                            false
                        }
                    })
                })
    }
    pub(super) fn has_unsaved_edits(&self, cx: &App) -> bool {
        self.dirty(cx)
    }
    /// Parent's typed native Don't Save/Discard action only. No disk read/write
    /// or API operation occurs; the panel's existing baseline is restored.
    pub(super) fn native_discard(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(text) = self
            .source
            .as_ref()
            .and_then(EditorFile::baseline)
            .map(str::to_owned)
        {
            self.editor
                .update(cx, |editor, cx| editor.set_value(text, window, cx));
        }
        self.native_edited = false;
        self.edit_lease.set_dirty(false);
        self.status = "Edits discarded".into();
        cx.notify();
    }
    /// Parent's typed native Save-and-Quit choice, never a control API route.
    /// false retains the draft and keeps the parent's Quit gate open.
    pub(super) fn native_save(&mut self, cx: &mut Context<Self>) -> bool {
        self.human_save(cx)
    }
    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(source) = &mut self.source {
            match source.load() {
                Ok(text) => {
                    self.editor
                        .update(cx, |editor, cx| editor.set_value(text, window, cx));
                    self.status.clear();
                    self.blocked = false;
                    self.native_edited = false;
                    self.edit_lease.set_dirty(false);
                }
                Err(error) => {
                    self.status = format!("{error:#}");
                    self.blocked = true;
                }
            }
        }
        cx.notify();
    }
    fn human_save(&mut self, cx: &mut Context<Self>) -> bool {
        if !self.dirty(cx) {
            return !self.blocked;
        }
        if self.blocked {
            return false;
        }
        let text = self.editor.read(cx).text().to_string();
        let mut saved = false;
        if let Some(source) = &mut self.source {
            match source.save(&text) {
                Ok(()) => {
                    self.status.clear();
                    self.native_edited = false;
                    self.edit_lease.set_dirty(false);
                    saved = true;
                }
                Err(error) => {
                    self.status = format!("{error:#}");
                    // Keep typed edits and allow an explicit retry. Every retry
                    // repeats the file lease and full CAS; stale text can never
                    // become an overwrite through this UI error state.
                }
            }
        }
        let dirty = self.dirty(cx);
        self.edit_lease.set_dirty(dirty);
        if !dirty {
            self.native_edited = false;
        }
        cx.notify();
        saved
    }
}
impl Render for InstructionsPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dirty = self.dirty(cx);
        let readable = self
            .source
            .as_ref()
            .is_some_and(|source| source.baseline().is_some());
        let reviewing =
            self.setup.review.is_some() || self.setup.has_copy_review() || self.setup.git_busy();
        let path = self.native_target_label();
        let display_path = crate::navigation::home_display_path(&path);
        div()
            .id("global-instructions-editor")
            .flex()
            .size_full()
            .min_h_0()
            .min_w_0()
            .overflow_hidden()
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                let modifiers = event.keystroke.modifiers;
                let primary = if cfg!(target_os = "macos") {
                    modifiers.platform && !modifiers.control
                } else {
                    modifiers.control && !modifiers.platform
                };
                if !event.prefer_character_input
                    && event.keystroke.key.eq_ignore_ascii_case("s")
                    && primary
                    && !modifiers.alt
                    && !modifiers.shift
                    && !modifiers.function
                {
                    this.human_save(cx);
                    window.prevent_default();
                    cx.stop_propagation();
                }
            }))
            .child(self.instructions_sidebar(cx))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .flex_none()
                            .flex()
                            .items_center()
                            .gap_2()
                            .px_4()
                            .py_2()
                            .border_b_1()
                            .border_color(cx.theme().border)
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .child(
                                        div().truncate().font_semibold().child(
                                            self.source
                                                .as_ref()
                                                .and_then(|source| source.path().file_name())
                                                .map(|name| name.to_string_lossy().into_owned())
                                                .unwrap_or_else(|| "Instructions".into()),
                                        ),
                                    )
                                    .when(self.source.is_some(), |heading| {
                                        heading.child(
                                            div()
                                                .id("instructions-source-path")
                                                .truncate()
                                                .text_xs()
                                                .text_color(cx.theme().muted_foreground)
                                                .child(display_path)
                                                .tooltip(move |window, cx| {
                                                    gpui_kit::component::tooltip::Tooltip::new(path.clone())
                                                        .build(window, cx)
                                                }),
                                        )
                                    }),
                            )
                            .child(
                                Button::new("global-instructions-reload")
                                    .icon(IconName::RefreshCw)
                                    .ghost()
                                    .compact()
                                    .accessibility_label(if dirty {
                                        "Discard edits and reload"
                                    } else {
                                        "Reload instructions"
                                    })
                                    .tooltip(if dirty {
                                        "Discard edits and reload"
                                    } else {
                                        "Reload instructions"
                                    })
                                    .on_click(
                                        cx.listener(|this, _, window, cx| this.reload(window, cx)),
                                    ),
                            )
                            .child(
                                Button::new("global-instructions-save")
                                    .label("Save")
                                    .primary()
                                    .compact()
                                    .disabled(
                                        !readable
                                            || !dirty
                                            || self.blocked
                                            || reviewing
                                            || self.setup.picker_pending,
                                    )
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.human_save(cx);
                                    })),
                            ),
                    )
                    .when(self.setup_open || reviewing, |view| {
                        view.child(
                            div()
                                .id("instructions-setup-scroll")
                                .debug_selector(|| "instructions-setup-scroll".into())
                                .max_h(relative(0.56))
                                .min_h_0()
                                .overflow_y_scroll()
                                .border_b_1()
                                .border_color(cx.theme().border)
                                .px_4()
                                .py_3()
                                .when(reviewing, |pane| pane.child(self.setup_review(cx)))
                                .when(!reviewing, |pane| pane.child(self.setup_controls(cx))),
                        )
                    })
                    .child(
                        div()
                            .id("instructions-document")
                            .debug_selector(|| "instructions-document".into())
                            .flex_1()
                            .min_h_0()
                            .overflow_hidden()
                            .p_4()
                            .when(readable, |body| {
                                body.child(
                                    Textarea::new(&self.editor)
                                        .accessibility_id("instructions-text")
                                        .aria_label("Instruction file contents")
                                        .appearance(false)
                                        .bordered(false)
                                        .h_full()
                                        .font_family(cx.theme().mono_font_family.clone())
                                        .disabled(reviewing || self.setup.picker_pending),
                                )
                            })
                            .when(!readable, |body| {
                                body.child(
                                    div()
                                        .text_sm()
                                        .text_color(cx.theme().muted_foreground)
                                        .child("Select an instruction file or open Setup and sync to create one."),
                                )
                            }),
                    )
                    .child(
                        div()
                            .flex_none()
                            .flex()
                            .items_center()
                            .gap_2()
                            .border_t_1()
                            .border_color(cx.theme().border)
                            .px_4()
                            .py_2()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .when(readable && (!self.blocked || dirty), |bar| {
                                bar.child(
                                    Icon::new(if dirty { IconName::Pencil } else { IconName::Check })
                                        .size(px(12.)),
                                )
                                .child(if dirty { "Unsaved changes" } else { "Saved" })
                            })
                            .when(!self.status.is_empty(), |bar| {
                                bar.child(div().min_w_0().child(self.status.clone()))
                            }),
                    ),
            )
    }
}
