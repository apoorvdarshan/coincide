//! Conventional GLOBAL master editor. Only this component's native human Save
//! callback invokes the bound file writer. No API/tool route can submit text.
#[path = "instructions_file.rs"]
mod file;
use file::EditorFile;
use gpui_kit::{
    base::Disableable,
    component::{
        button::*,
        input::{InputEvent, Textarea, TextareaState},
    },
    *,
};

pub(super) struct InstructionsPanel {
    source: Option<EditorFile>,
    edit_lease: coincide_core::native_ui_edits::NativeUiEditLease,
    editor: Entity<TextareaState>,
    status: String,
    blocked: bool,
    native_edited: bool,
    _subscription: Subscription,
}
impl InstructionsPanel {
    pub(super) fn new(
        edit_lease: coincide_core::native_ui_edits::NativeUiEditLease,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let editor = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Global instructions")
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
        let (source, status) = match EditorFile::runtime() {
            Ok(source) => (Some(source), String::new()),
            Err(error) => (None, error.to_string()),
        };
        let mut panel = Self {
            source,
            edit_lease,
            editor,
            status,
            blocked: false,
            native_edited: false,
            _subscription: subscription,
        };
        panel.reload(window, cx);
        panel
    }
    fn dirty(&self, cx: &App) -> bool {
        self.native_edited
            && self
                .source
                .as_ref()
                .and_then(EditorFile::baseline)
                .is_some_and(|baseline| baseline != self.editor.read(cx).value().as_ref())
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
                    self.status = "Matches the saved global master".into();
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
        let text = self.editor.read(cx).value().to_string();
        let mut saved = false;
        if let Some(source) = &mut self.source {
            match source.save(&text) {
                Ok(()) => {
                    self.status = "Saved global instructions".into();
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
        div().id("global-instructions-editor").flex().flex_col().gap_3().p_4().size_full().min_h_0()
            .capture_key_down(cx.listener(|this,event:&KeyDownEvent,window,cx|{
                let modifiers=event.keystroke.modifiers;
                let primary=if cfg!(target_os="macos"){modifiers.platform && !modifiers.control}else{modifiers.control && !modifiers.platform};
                if !event.prefer_character_input && event.keystroke.key.eq_ignore_ascii_case("s") && primary && !modifiers.alt && !modifiers.shift && !modifiers.function{
                    this.human_save(cx);window.prevent_default();cx.stop_propagation();
                }
            }))
            .child(div().text_lg().child("Global instructions"))
            .child("Edit the shared master used by your existing instruction links.")
            .when_some(self.source.as_ref().map(|source|source.path().display().to_string()),|view,path|view.child(div().text_sm().child(path)))
            .child(div().flex().gap_2()
                .child(Button::new("global-instructions-save").label("Save").primary().disabled(!readable || !dirty || self.blocked).on_click(cx.listener(|this,_,_,cx|{this.human_save(cx);})))
                .child(Button::new("global-instructions-reload").label(if dirty{"Discard edits and reload"}else{"Reload"}).on_click(cx.listener(|this,_,window,cx|this.reload(window,cx)))))
            .child(if dirty{"Unsaved edits"}else{"Saved text"})
            .child(div().text_sm().child(self.status.clone()))
            .child(div().flex_1().min_h_0().font_family("monospace").child(Textarea::new(&self.editor).h_full().disabled(!readable)))
            .child(div().text_sm().child("This editor opens the conventional global master. Project files, custom master selection, link setup and copy synchronization use your existing setup."))
    }
}
