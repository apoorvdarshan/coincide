//! The composer's folder browser follows the bot folder picker, while attaching
//! the selected directory to the conversation that opened it.
use super::*;
use std::path::PathBuf;

pub(super) struct Picker {
    pub(super) path: Entity<InputState>,
    owner: Option<String>,
    generation: u64,
    completions: Vec<PathBuf>,
    completion_index: usize,
    loading: bool,
    validating: bool,
    error: String,
    restore_focus: Option<FocusHandle>,
}
impl Picker {
    pub(super) fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            path: cx.new(|cx| InputState::new(window, cx).placeholder("Folder path")),
            owner: None,
            generation: 0,
            completions: Vec::new(),
            completion_index: 0,
            loading: false,
            validating: false,
            error: String::new(),
            restore_focus: None,
        }
    }
    fn invalidate(&mut self) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.generation
    }
    fn owns(&self, generation: u64, owner: &str) -> bool {
        self.generation == generation && self.owner.as_deref() == Some(owner)
    }
}

fn selected_folder(typed: &str) -> Result<PathBuf> {
    let path = crate::project_management::expand_home(typed.trim());
    anyhow::ensure!(
        path.is_absolute() && path.is_dir(),
        "Choose an existing folder."
    );
    anyhow::ensure!(
        path.to_str().is_some(),
        "The selected folder path is not UTF-8."
    );
    Ok(path)
}

impl Coincide {
    pub(super) fn open_composer_folder_picker(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.composer_folder.owner.is_some() {
            return;
        }
        let Some(owner) = self
            .selected
            .as_ref()
            .and_then(|thread| thread["id"].as_str())
            .map(str::to_owned)
        else {
            return;
        };
        self.composer_folder.owner = Some(owner);
        self.composer_folder.restore_focus = window.focused(cx);
        self.composer_folder.error.clear();
        self.composer_folder.completions.clear();
        let input = self.composer_folder.path.clone();
        input.update(cx, |input, cx| {
            input.set_value("~", window, cx);
            input.focus(window, cx);
        });
        self.composer_folder_path_changed(cx);
        cx.notify();
    }

    pub(super) fn composer_folder_path_changed(&mut self, cx: &mut Context<Self>) {
        let Some(owner) = self.composer_folder.owner.clone() else {
            return;
        };
        let query = self.composer_folder.path.read(cx).value().to_string();
        let generation = self.composer_folder.invalidate();
        self.composer_folder.completions.clear();
        self.composer_folder.completion_index = 0;
        self.composer_folder.error.clear();
        self.composer_folder.validating = false;
        self.composer_folder.loading = true;
        cx.spawn(async move |this, cx| {
            // Avoid scanning every intermediate keystroke, and keep filesystem
            // reads off the window thread (including slow network volumes).
            cx.background_executor()
                .timer(Duration::from_millis(80))
                .await;
            if !this
                .update(cx, |this, _| this.composer_folder.owns(generation, &owner))
                .unwrap_or(false)
            {
                return;
            }
            let folders = cx
                .background_executor()
                .spawn(async move { crate::project_management::path_completions(&query) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.composer_folder.owns(generation, &owner) {
                    this.composer_folder.loading = false;
                    this.composer_folder.completions = folders;
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn close_composer_folder_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer_folder.invalidate();
        self.composer_folder.owner = None;
        self.composer_folder.loading = false;
        self.composer_folder.validating = false;
        if let Some(focus) = self.composer_folder.restore_focus.take() {
            focus.focus(window, cx);
        }
        cx.notify();
    }

    fn navigate_composer_folder_picker(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(path) = self.composer_folder.completions.get(index) else {
            return;
        };
        let value = path.to_string_lossy().into_owned();
        self.composer_folder.path.update(cx, |input, cx| {
            input.set_value(value, window, cx);
            input.focus(window, cx);
        });
        // Programmatic InputState changes do not emit the same Change event as
        // typing, so explicitly load the selected folder's children.
        self.composer_folder_path_changed(cx);
    }

    fn attach_composer_folder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(owner) = self.composer_folder.owner.clone() else {
            return;
        };
        if self.composer_folder.validating {
            return;
        }
        let typed = self.composer_folder.path.read(cx).value().to_string();
        let generation = self.composer_folder.generation;
        self.composer_folder.validating = true;
        self.composer_folder.error.clear();
        let worker = cx
            .background_executor()
            .spawn(async move { selected_folder(&typed) });
        cx.spawn_in(window, async move |this, cx| {
            let result = worker.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if !this.composer_folder.owns(generation, &owner) {
                    return;
                }
                this.composer_folder.validating = false;
                match result {
                    Ok(path) => {
                        this.close_composer_folder_picker(window, cx);
                        this.attach_folder_path(owner, path, cx);
                    }
                    Err(error) => {
                        this.composer_folder.error = error.to_string();
                        cx.notify();
                    }
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn composer_folder_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let count = self.composer_folder.completions.len();
        match event.keystroke.key.as_str() {
            "escape" => self.close_composer_folder_picker(window, cx),
            "down" if count > 0 => {
                self.composer_folder.completion_index =
                    (self.composer_folder.completion_index + 1) % count;
                cx.notify();
            }
            "up" if count > 0 => {
                self.composer_folder.completion_index =
                    (self.composer_folder.completion_index + count - 1) % count;
                cx.notify();
            }
            "tab" if count > 0 => self.navigate_composer_folder_picker(
                self.composer_folder.completion_index,
                window,
                cx,
            ),
            "enter" => self.attach_composer_folder(window, cx),
            _ => return,
        }
        cx.stop_propagation();
    }

    pub(super) fn composer_folder_overlay(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let picker = &self.composer_folder;
        picker.owner.as_ref()?;
        let mut folders = div().flex().flex_col().gap_1();
        for (index, path) in picker.completions.iter().enumerate() {
            let full = path.to_string_lossy().into_owned();
            let label = path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| full.clone());
            folders = folders.child(
                Button::new(SharedString::from(format!("composer-folder-entry-{index}")))
                    .accessibility_label(format!("Open folder {full}"))
                    .tooltip(full)
                    .ghost()
                    .compact()
                    .w_full()
                    .selected(index == picker.completion_index)
                    .child(
                        div()
                            .w_full()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(Icon::new(gpui_kit::assets::IconName::Folder).xsmall())
                            .child(label),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.navigate_composer_folder_picker(index, window, cx)
                    })),
            );
        }
        let theme = cx.theme();
        let panel = div()
            .id("composer-folder-picker")
            .w(px(520.))
            .max_w_full()
            .h(px(440.))
            .max_h_full()
            .flex()
            .flex_col()
            .overflow_hidden()
            .rounded(px(12.))
            .border_1()
            .border_color(theme.border)
            .bg(theme.background)
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                this.composer_folder_key(event, window, cx)
            }))
            .child(
                div()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .px_5()
                    .py_3()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(
                        div()
                            .text_lg()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("Attach Folder"),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                Button::new("composer-folder-cancel")
                                    .label("Cancel")
                                    .compact()
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.close_composer_folder_picker(window, cx)
                                    })),
                            )
                            .child(
                                Button::new("composer-folder-use")
                                    .label("Attach Folder")
                                    .compact()
                                    .primary()
                                    .disabled(picker.validating)
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.attach_composer_folder(window, cx)
                                    })),
                            ),
                    ),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .px_5()
                    .pt_4()
                    .child(Input::new(&picker.path)),
            )
            .when(!picker.error.is_empty(), |view| {
                view.child(
                    div()
                        .px_5()
                        .pt_2()
                        .text_sm()
                        .text_color(theme.danger)
                        .child(picker.error.clone()),
                )
            })
            .child(
                div()
                    .id("composer-folder-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .px_5()
                    .py_3()
                    .child(folders)
                    .when(picker.completions.is_empty(), |view| {
                        view.child(div().text_sm().text_color(theme.muted_foreground).child(
                            if picker.loading {
                                "Finding folders…"
                            } else {
                                "No matching folders."
                            },
                        ))
                    }),
            );
        Some(
            chat_layout::modal_backdrop()
                .id("composer-folder-backdrop")
                .flex()
                .items_center()
                .justify_center()
                .p_3()
                .bg(rgba(0x00000080))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|_, _, _, cx| cx.stop_propagation()),
                )
                .child(panel)
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn only_existing_absolute_directories_can_be_attached() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("file.txt");
        std::fs::write(&file, b"hello").unwrap();
        assert!(selected_folder(root.path().to_str().unwrap()).is_ok());
        assert!(selected_folder(file.to_str().unwrap()).is_err());
        assert!(selected_folder(root.path().join("missing").to_str().unwrap()).is_err());
        assert!(selected_folder("relative/folder").is_err());
    }
}
