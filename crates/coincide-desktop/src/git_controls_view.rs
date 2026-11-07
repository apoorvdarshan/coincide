//! Rendering for the git action bar, its result banner and commit sheet, the
//! default-branch question, and the branch toolbar with its branch picker.
use super::*;
use coincide_core::git_actions::{QuickKind, StackedAction};
use gpui_kit::{
    assets::IconName,
    component::{
        checkbox::Checkbox,
        menu::{DropdownMenu, PopupMenuItem},
        popover::Popover,
        spinner::Spinner,
        tooltip::Tooltip,
    },
};

const GREEN: u32 = 0x5caf7d;
const ORANGE: u32 = 0xe0a040;
const RED: u32 = 0xe0706c;

/// The platform's name for showing a folder in its file manager.
fn reveal_title() -> &'static str {
    if cfg!(target_os = "macos") {
        "Reveal in Finder"
    } else if cfg!(target_os = "windows") {
        "Show in File Explorer"
    } else {
        "Show in Files"
    }
}

fn commit_shortcut() -> &'static str {
    if cfg!(target_os = "macos") {
        "Commit (⌘↩)"
    } else {
        "Commit (Ctrl+Enter)"
    }
}

fn quick_icon(kind: &QuickKind) -> IconName {
    match kind {
        QuickKind::Pull => IconName::CircleArrowDown,
        QuickKind::Hint(_) | QuickKind::Run(StackedAction::Commit) => IconName::CircleCheck,
        QuickKind::Run(StackedAction::CommitPush | StackedAction::Push) => IconName::CircleArrowUp,
        QuickKind::Run(StackedAction::CommitPushPr | StackedAction::CreatePr) => {
            IconName::GitPullRequest
        }
    }
}

impl Coincide {
    fn git_counts(&self, additions: u64, deletions: u64) -> Div {
        div()
            .flex()
            .gap_1()
            .text_xs()
            .font_weight(FontWeight::MEDIUM)
            .child(div().text_color(rgb(GREEN)).child(format!("+{additions}")))
            .child(div().text_color(rgb(RED)).child(format!("−{deletions}")))
    }

    fn git_banner(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let banner = &self.git_controls.banner.as_ref()?.banner;
        let label = [Some(banner.title.clone()), banner.detail.clone()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(". ");
        Some(
            div()
                .id("git-result-banner")
                .role(Role::Group)
                .aria_label(label)
                .flex()
                .items_center()
                .gap_2()
                .px(px(12.))
                .py(px(8.))
                .rounded(px(14.))
                .border_1()
                .border_color(self.color(0x29303d))
                .bg(self.color(0x202a3b))
                .child(
                    Icon::new(if banner.error {
                        IconName::TriangleAlert
                    } else {
                        IconName::CircleCheck
                    })
                    .small()
                    .text_color(rgb(if banner.error {
                        ORANGE
                    } else {
                        GREEN
                    })),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .truncate()
                                .text_sm()
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(banner.title.clone()),
                        )
                        .when_some(banner.detail.clone(), |view, detail| {
                            view.child(
                                div()
                                    .text_xs()
                                    .max_h(px(64.))
                                    .overflow_hidden()
                                    .text_color(self.color(0xe4e9f2).opacity(0.65))
                                    .child(detail),
                            )
                        }),
                )
                .when_some(banner.action.clone(), |view, (title, action)| {
                    view.child(
                        Button::new("git-banner-action")
                            .label(title)
                            .small()
                            .compact()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.git_run_banner_action(action.clone(), cx)
                            })),
                    )
                })
                .child(
                    Button::new("git-banner-dismiss")
                        .icon(IconName::Close)
                        .accessibility_label("Dismiss")
                        .tooltip("Dismiss")
                        .ghost()
                        .xsmall()
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.git_controls.banner = None;
                            cx.notify();
                        })),
                )
                .into_any_element(),
        )
    }

    /// The bar at the foot of the Git workspace: the branch, how it stands against its
    /// upstream, and a primary action with a menu of the others.
    pub(crate) fn git_actions_bar(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let controls = &self.git_controls;
        controls.binding.thread.as_ref()?;
        let status = controls
            .status
            .clone()
            .filter(|status| status.is_repository)?;
        let quick = self.git_quick();
        let available = self.git_availability();
        let term = controls.term;
        let pull_request = controls.pull_request.clone();
        // Another thread's action shows here as busy buttons, not as this thread's progress.
        let progress = (controls.action_thread == controls.binding.thread
            && controls.toolbar_op.is_none())
        .then(|| controls.progress.clone())
        .flatten();
        let detached = status.branch.is_none();
        let sync = git_controls_sync(&status, pull_request.as_ref(), term);
        let tooltip = super::branch_tooltip(&status, pull_request.as_ref(), term);
        let branch = div()
            .id("git-actions-branch")
            .flex()
            .items_center()
            .gap_1()
            .min_w_0()
            .flex_shrink_1()
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .child(
                Icon::new(IconName::GitBranch)
                    .xsmall()
                    .text_color(self.color(0xe4e9f2).opacity(0.65)),
            )
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_sm()
                    .font_weight(FontWeight::MEDIUM)
                    .when(detached, |label| label.text_color(rgb(ORANGE)))
                    .child(
                        status
                            .branch
                            .clone()
                            .unwrap_or_else(|| "Detached HEAD".into()),
                    ),
            )
            .when(!sync.is_empty(), |view| {
                view.child(
                    div()
                        .id("git-actions-sync")
                        .flex_shrink_0()
                        .text_xs()
                        .text_color(self.color(0xe4e9f2).opacity(0.65))
                        .aria_label(format!(
                            "{} commits to push, {} to pull",
                            status.ahead, status.behind
                        ))
                        .child(sync),
                )
            });
        let mut bar = div()
            .id("git-actions-bar")
            .role(Role::Group)
            .aria_label("Git actions")
            .flex()
            .items_center()
            .gap(px(6.))
            .h(px(44.))
            .pl(px(14.))
            .pr(px(6.))
            .rounded(px(18.))
            .border_1()
            .border_color(self.color(0x29303d))
            .bg(self.color(0x202a3b))
            .child(branch)
            .child(div().flex_1());
        if let Some(progress) = progress {
            bar = bar
                .child(Spinner::new().small())
                .child(div().truncate().text_xs().child(progress));
        } else {
            let hint = match &quick.kind {
                QuickKind::Hint(hint) if !hint.is_empty() => Some(hint.clone()),
                _ => None,
            };
            let parent = cx.entity().downgrade();
            let branch_name = status.branch.clone();
            let has_upstream = status.has_upstream();
            let behind = status.behind > 0;
            let busy = controls.busy();
            bar = bar
                .child(
                    Button::new("git-quick-action")
                        .label(quick.title.clone())
                        .icon(quick_icon(&quick.kind))
                        .small()
                        .when(quick.is_enabled, |button| button.primary())
                        .disabled(!quick.is_enabled)
                        .when_some(hint, |button, hint| button.tooltip(hint))
                        .on_click(cx.listener(|this, _, _, cx| this.git_quick_action(cx))),
                )
                .child(
                    Button::new("git-actions-menu")
                        .icon(IconName::ChevronDown)
                        .accessibility_label("More Git actions")
                        .tooltip("More Git actions")
                        .small()
                        .ghost()
                        .dropdown_menu(move |mut menu, _, _| {
                            let item = |title: String, icon: IconName, enabled: bool| {
                                PopupMenuItem::new(title).icon(icon).disabled(!enabled)
                            };
                            let target = parent.clone();
                            menu = menu.item(
                                item(
                                    "Commit…".into(),
                                    IconName::CircleCheck,
                                    available.can_commit,
                                )
                                .on_click(move |_, window, cx| {
                                    let _ = target.update(cx, |this, cx| {
                                        this.git_show_commit_sheet(window, cx)
                                    });
                                }),
                            );
                            if available.shows_remote_actions {
                                let target = parent.clone();
                                menu = menu.item(
                                    item(
                                        "Push".into(),
                                        IconName::CircleArrowUp,
                                        available.can_push,
                                    )
                                    .on_click(
                                        move |_, _, cx| {
                                            let _ = target.update(cx, |this, cx| {
                                                this.git_perform(
                                                    StackedAction::Push,
                                                    None,
                                                    None,
                                                    false,
                                                    false,
                                                    cx,
                                                )
                                            });
                                        },
                                    ),
                                );
                                let target = parent.clone();
                                menu = match pull_request.clone().filter(|pr| !pr.url.is_empty()) {
                                    Some(pull_request) => menu.item(
                                        item(
                                            term.view_title(pull_request.number),
                                            IconName::GitPullRequest,
                                            true,
                                        )
                                        .on_click(
                                            move |_, _, cx| {
                                                let _ = target.update(cx, |this, cx| {
                                                    this.git_run_banner_action(
                                                        super::BannerAction::Open(
                                                            pull_request.url.clone(),
                                                        ),
                                                        cx,
                                                    )
                                                });
                                            },
                                        ),
                                    ),
                                    None => menu.item(
                                        item(
                                            term.create_menu_title().into(),
                                            IconName::GitPullRequest,
                                            available.can_create_pr,
                                        )
                                        .on_click(
                                            move |_, _, cx| {
                                                let _ = target.update(cx, |this, cx| {
                                                    this.git_perform(
                                                        StackedAction::CreatePr,
                                                        None,
                                                        None,
                                                        false,
                                                        false,
                                                        cx,
                                                    )
                                                });
                                            },
                                        ),
                                    ),
                                };
                                let target = parent.clone();
                                menu = menu.item(PopupMenuItem::separator()).item(
                                    item(
                                        "Pull".into(),
                                        IconName::CircleArrowDown,
                                        !busy && has_upstream && behind,
                                    )
                                    .on_click(
                                        move |_, _, cx| {
                                            let _ = target.update(cx, |this, cx| this.git_pull(cx));
                                        },
                                    ),
                                );
                            }
                            if branch_name.is_none() {
                                menu = menu.item(PopupMenuItem::separator()).item(
                                    PopupMenuItem::new(term.detached_head_note()).disabled(true),
                                );
                            }
                            menu
                        }),
                );
        }
        Some(
            div()
                .id("git-actions-footer")
                .flex_shrink_0()
                .flex()
                .flex_col()
                .gap_2()
                .px(px(14.))
                .pb(px(14.))
                .pt_2()
                .when_some(self.git_banner(cx), |view, banner| view.child(banner))
                .child(bar)
                .into_any_element(),
        )
    }

    fn git_modal_frame(&self, id: &'static str, title: &str, width: f32) -> Stateful<Div> {
        div()
            .id(id)
            .role(Role::Dialog)
            .aria_label(title.to_owned())
            .w(px(width))
            .max_w_full()
            .max_h_full()
            .overflow_y_scroll()
            .p_5()
            .flex()
            .flex_col()
            .gap_2()
            .rounded_lg()
            .border_1()
            .border_color(self.color(0x29303d))
            .bg(self.color(0x10141c))
            .text_color(self.color(0xe4e9f2))
    }

    fn git_commit_sheet(
        &self,
        sheet: &super::CommitSheet,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let selected: Vec<&coincide_core::git_actions::ChangedFile> = sheet
            .files
            .iter()
            .filter(|file| !sheet.excluded.contains(&file.path))
            .collect();
        let all = sheet.excluded.is_empty();
        let selection = if all {
            format!("{} changed", sheet.files.len())
        } else {
            format!("{} of {}", selected.len(), sheet.files.len())
        };
        let additions = selected.iter().map(|file| file.additions).sum();
        let deletions = selected.iter().map(|file| file.deletions).sum();
        let none = selected.is_empty();
        let mut list = div()
            .id("git-commit-files")
            .aria_label("Files to commit")
            .h(px(170.))
            .overflow_y_scroll()
            .rounded_md()
            .border_1()
            .border_color(self.color(0x29303d))
            .p_1()
            .flex()
            .flex_col();
        for (index, file) in sheet.files.iter().enumerate() {
            let included = !sheet.excluded.contains(&file.path);
            let path = file.path.clone();
            let shown = match &file.old_path {
                Some(old) => format!("{old} → {}", file.path),
                None => file.path.clone(),
            };
            list = list.child(
                div()
                    .h(px(24.))
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .gap_1()
                    .px_1()
                    .child(
                        Checkbox::new(SharedString::from(format!("git-commit-file-{index}")))
                            .checked(included)
                            .on_click(cx.listener(move |this, checked: &bool, _, cx| {
                                if let Some(sheet) = this.git_controls.commit.as_mut() {
                                    if *checked {
                                        sheet.excluded.remove(&path);
                                    } else {
                                        sheet.excluded.insert(path.clone());
                                    }
                                    cx.notify();
                                }
                            })),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!("git-commit-path-{index}")))
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_sm()
                            .aria_label(format!("Include {}", file.path))
                            .when(!included, |label| label.opacity(0.5))
                            .child(shown),
                    )
                    .child(self.git_counts(file.additions, file.deletions)),
            );
        }
        self.git_modal_frame("git-commit-sheet", "Commit Changes", 520.)
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                let key = &event.keystroke;
                let command = if cfg!(target_os = "macos") {
                    key.modifiers.platform
                } else {
                    key.modifiers.control
                };
                match key.key.as_str() {
                    "escape" => this.git_close_modal(window, cx),
                    "enter" if command => this.git_commit(false, window, cx),
                    _ => return,
                }
                cx.stop_propagation();
            }))
            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child("Commit Changes"))
            .child(
                div()
                    .text_sm()
                    .text_color(self.color(0xe4e9f2).opacity(0.65))
                    .child("Review and confirm your commit. Leave the message empty to generate one from the changed files."),
            )
            .child(
                div()
                    .mt_2()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(Icon::new(IconName::GitBranch).xsmall())
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .font_weight(FontWeight::MEDIUM)
                            .child(sheet.branch.clone().unwrap_or_else(|| "(detached HEAD)".into())),
                    )
                    .when(sheet.is_default, |row| {
                        row.child(
                            div()
                                .text_xs()
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(rgb(ORANGE))
                                .child("Default branch"),
                        )
                    }),
            )
            .child(
                div()
                    .mt_2()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(
                        Checkbox::new("git-commit-all")
                            .label("Files")
                            .checked(all)
                            .on_click(cx.listener(|this, _: &bool, _, cx| {
                                if let Some(sheet) = this.git_controls.commit.as_mut() {
                                    sheet.excluded = if sheet.excluded.is_empty() {
                                        sheet.files.iter().map(|file| file.path.clone()).collect()
                                    } else {
                                        Default::default()
                                    };
                                    cx.notify();
                                }
                            })),
                    )
                    .child(
                        div()
                            .text_sm()
                            .text_color(self.color(0xe4e9f2).opacity(0.65))
                            .child(selection),
                    )
                    .child(div().flex_1())
                    .child(self.git_counts(additions, deletions)),
            )
            .child(list)
            .child(div().mt_2().font_weight(FontWeight::MEDIUM).child("Message"))
            .child(
                Textarea::new(&self.git_controls.message)
                    .aria_label("Commit message")
                    .h(px(84.)),
            )
            .child(
                div()
                    .mt_3()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1())
                    .child(
                        Button::new("git-commit-cancel")
                            .label("Cancel")
                            .on_click(cx.listener(|this, _, window, cx| this.git_close_modal(window, cx))),
                    )
                    .child(
                        Button::new("git-commit-new-branch")
                            .label("Commit on New Branch")
                            .tooltip("Create a feature branch named after the change, then commit there.")
                            .disabled(none)
                            .on_click(cx.listener(|this, _, window, cx| this.git_commit(true, window, cx))),
                    )
                    .child(
                        Button::new("git-commit")
                            .label("Commit")
                            .primary()
                            .tooltip(commit_shortcut())
                            .disabled(none)
                            .on_click(cx.listener(|this, _, window, cx| this.git_commit(false, window, cx))),
                    ),
            )
    }

    /// T3 Code's default-branch question: continue there, or move the work to a
    /// feature branch.
    fn git_confirm_dialog(
        &self,
        confirm: &super::Confirm,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let commits = confirm.action.includes_commit();
        let question = match confirm.action {
            StackedAction::CommitPush | StackedAction::Push if commits => {
                "Commit and push to the default branch?"
            }
            StackedAction::CommitPush | StackedAction::Push => "Push to the default branch?",
            _ => self.git_controls.term.default_branch_question(commits),
        };
        let branch = confirm.branch.clone();
        self.git_modal_frame("git-default-branch", question, 440.)
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" {
                    this.git_close_modal(window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(question))
            .child(div().text_sm().child(format!(
                "This works on “{branch}”. You can continue on this branch, or create a feature branch and run the same action there."
            )))
            .child(
                div()
                    .mt_3()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("git-default-cancel")
                            .label("Cancel")
                            .on_click(cx.listener(|this, _, window, cx| this.git_close_modal(window, cx))),
                    )
                    .child(
                        Button::new("git-default-continue")
                            .label(if commits {
                                format!("Continue on {branch}")
                            } else {
                                format!("Push to {branch}")
                            })
                            .when(!confirm.can_branch, |button| button.primary())
                            .on_click(cx.listener(|this, _, window, cx| this.git_confirm(false, window, cx))),
                    )
                    .when(confirm.can_branch, |row| {
                        row.child(
                            Button::new("git-default-feature")
                                .label("Use a Feature Branch")
                                .primary()
                                .on_click(cx.listener(|this, _, window, cx| this.git_confirm(true, window, cx))),
                        )
                    }),
            )
    }

    fn git_alert(&self, alert: &super::Banner, cx: &mut Context<Self>) -> Stateful<Div> {
        self.git_modal_frame("git-alert", &alert.title, 420.)
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if matches!(event.keystroke.key.as_str(), "escape" | "enter") {
                    this.git_close_modal(window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(Icon::new(IconName::TriangleAlert).text_color(rgb(ORANGE)))
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(alert.title.clone()),
                    ),
            )
            .when_some(alert.detail.clone(), |view, detail| {
                view.child(div().text_sm().child(detail))
            })
            .child(
                div().mt_3().flex().justify_end().child(
                    Button::new("git-alert-ok").label("OK").primary().on_click(
                        cx.listener(|this, _, window, cx| this.git_close_modal(window, cx)),
                    ),
                ),
            )
    }

    /// The commit sheet, the default-branch question or a toolbar failure, over the window.
    pub(crate) fn git_modal(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let controls = &self.git_controls;
        let content = if let Some(sheet) = &controls.commit {
            self.git_commit_sheet(sheet, cx)
        } else if let Some(confirm) = &controls.confirm {
            self.git_confirm_dialog(confirm, cx)
        } else if let Some(alert) = &controls.alert {
            self.git_alert(alert, cx)
        } else {
            return None;
        };
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
                .child(content)
                .into_any_element(),
        )
    }

    // MARK: Branch toolbar

    /// The strip under the composer: where the thread runs and on which branch.
    pub(crate) fn branch_toolbar(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let controls = &self.git_controls;
        controls.binding.thread.as_ref()?;
        let status = controls
            .status
            .as_ref()
            .filter(|status| status.is_repository)?;
        let binding = controls.binding.clone();
        let preparing = self.git_preparing();
        let busy = preparing || binding.running || controls.busy();
        let new_base = (!binding.started)
            .then(|| controls.toolbar.base_branch.clone())
            .flatten();
        let previous = controls.toolbar.previous.clone();
        let (title, icon) = if preparing {
            ("Preparing worktree…", IconName::FolderPlus)
        } else if binding.worktree.is_none() {
            (
                if binding.started {
                    "Local checkout"
                } else {
                    "Current checkout"
                },
                IconName::Folder,
            )
        } else if new_base.is_some() {
            ("New worktree", IconName::FolderPlus)
        } else {
            (
                if binding.started {
                    "Worktree"
                } else {
                    "Current worktree"
                },
                IconName::Layers,
            )
        };
        let parent = cx.entity().downgrade();
        let folder = binding.folder.clone().unwrap_or_default();
        let workspace = Button::new("git-workspace-menu")
            .label(title)
            .icon(icon)
            .accessibility_label(format!("Workspace: {title}"))
            .tooltip(folder)
            .xsmall()
            .h(px(26.))
            .rounded(px(7.))
            .ghost()
            .compact()
            .disabled(preparing);
        let workspace: AnyElement = if preparing {
            workspace.into_any_element()
        } else {
            let worktree = binding.worktree.clone();
            let started = binding.started;
            let has_base = new_base.is_some();
            workspace
                .dropdown_caret(true)
                .dropdown_menu(move |mut menu, _, _| {
                    if !started {
                        let target = parent.clone();
                        menu = menu.item(
                            PopupMenuItem::new("Current Checkout")
                                .icon(IconName::Folder)
                                .checked(worktree.is_none())
                                .disabled(busy)
                                .on_click(move |_, _, cx| {
                                    let _ = target.update(cx, |this, cx| this.git_use_checkout(cx));
                                }),
                        );
                        let target = parent.clone();
                        menu = menu.item(
                            PopupMenuItem::new("New Worktree")
                                .icon(IconName::FolderPlus)
                                .checked(has_base)
                                .disabled(busy || has_base)
                                .on_click(move |_, _, cx| {
                                    let _ = target
                                        .update(cx, |this, cx| this.git_use_new_worktree(None, cx));
                                }),
                        );
                        if let Some((path, branch)) = previous.clone() {
                            let target = parent.clone();
                            let title = match &branch {
                                Some(branch) => format!("Previous Worktree ({branch})"),
                                None => "Previous Worktree".into(),
                            };
                            let current = worktree.as_deref() == Some(path.as_str());
                            menu = menu.item(
                                PopupMenuItem::new(title)
                                    .icon(IconName::Layers)
                                    .checked(current)
                                    .disabled(busy)
                                    .on_click(move |_, _, cx| {
                                        let _ = target.update(cx, |this, cx| {
                                            this.git_use_existing(path.clone(), branch.clone(), cx)
                                        });
                                    }),
                            );
                        }
                        menu = menu.item(PopupMenuItem::separator());
                    }
                    let target = parent.clone();
                    menu = menu.item(PopupMenuItem::new(reveal_title()).on_click(
                        move |_, _, cx| {
                            let _ = target.update(cx, |this, cx| this.git_reveal_folder(cx));
                        },
                    ));
                    let target = parent.clone();
                    menu.item(
                        PopupMenuItem::new("Copy Path")
                            .icon(IconName::Copy)
                            .on_click(move |_, _, cx| {
                                let _ = target.update(cx, |this, cx| this.git_copy_path(cx));
                            }),
                    )
                })
                .into_any_element()
        };

        let current = status.branch.clone();
        let (label, icon, warning, tooltip, pickable) = if let Some(base) = &new_base {
            (
                format!("From {base}"),
                IconName::GitBranch,
                false,
                "The branch the new worktree starts from".to_owned(),
                true,
            )
        } else if binding.worktree.is_none() {
            let mismatch = binding.started
                && binding.branch.is_some()
                && current.is_some()
                && binding.branch != current;
            (
                current.clone().unwrap_or_else(|| "Detached HEAD".into()),
                if mismatch {
                    IconName::TriangleAlert
                } else {
                    IconName::GitBranch
                },
                mismatch,
                if mismatch {
                    format!(
                        "This thread started on {}; the folder is now on {}.",
                        binding.branch.clone().unwrap_or_default(),
                        current.clone().unwrap_or_default()
                    )
                } else {
                    "Switch or create a branch".into()
                },
                true,
            )
        } else {
            (
                current
                    .clone()
                    .or_else(|| binding.branch.clone())
                    .unwrap_or_else(|| "Detached HEAD".into()),
                IconName::GitBranch,
                false,
                binding.worktree.clone().unwrap_or_default(),
                false,
            )
        };
        let branch_button = Button::new("git-branch-button")
            .label(label.clone())
            .icon(Icon::new(icon).when(warning, |icon| icon.text_color(rgb(ORANGE))))
            .accessibility_label(format!("Branch: {label}"))
            .tooltip(tooltip)
            .xsmall()
            .h(px(26.))
            .rounded(px(7.))
            .ghost()
            .compact()
            .when(pickable, |button| button.dropdown_caret(true))
            .disabled(pickable && busy);
        let branch: AnyElement = if pickable {
            let open = controls.picker.is_some();
            let parent = cx.entity().downgrade();
            // Opening focuses the search field, as Swift's popup makes it first responder.
            let search = controls.search.read(cx).focus_handle(cx);
            Popover::new("git-branch-picker")
                .anchor(Anchor::BottomRight)
                .track_focus(&search)
                .open(open)
                .on_open_change(move |open, window, cx| {
                    let open = *open;
                    let _ = parent.update(cx, |this, cx| {
                        if open && this.git_controls.picker.is_none() {
                            let blocked = this.git_preparing()
                                || this.git_controls.binding.running
                                || this.git_controls.busy();
                            if !blocked {
                                this.git_open_picker(window, cx);
                            }
                        } else if !open {
                            this.git_close_picker(window, cx);
                        }
                        cx.notify();
                    });
                })
                .trigger(branch_button)
                .when(open, |popover| popover.child(self.git_picker(cx)))
                .into_any_element()
        } else {
            branch_button.into_any_element()
        };
        Some(
            div()
                .id("branch-toolbar")
                .w_full()
                .max_w(px(presentation::CONTENT_WIDTH))
                .h(px(28.))
                .mt_1()
                .px_1()
                .flex()
                .items_center()
                .gap_1()
                .child(workspace)
                .when(preparing, |row| row.child(Spinner::new().small()))
                .child(div().flex_1())
                .child(branch)
                .into_any_element(),
        )
    }

    fn git_picker(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(picker) = &self.git_controls.picker else {
            return div().into_any_element();
        };
        let visible = picker.rows.len().clamp(3, 10) as f32;
        let mut list = div()
            .id("git-branch-rows")
            .role(Role::List)
            .aria_label("Branches")
            .h(px(visible * 28. + 12.))
            .py(px(6.))
            .overflow_y_scroll()
            .flex()
            .flex_col();
        for (index, row) in picker.rows.iter().enumerate() {
            let highlighted = picker.highlighted == Some(index);
            list =
                list.child(match row {
                    super::PickerRow::Header(title) => div()
                        .h(px(28.))
                        .flex_shrink_0()
                        .flex()
                        .items_end()
                        .pb_1()
                        .px(px(14.))
                        .text_xs()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(self.color(0xe4e9f2).opacity(0.65))
                        .child(*title)
                        .into_any_element(),
                    super::PickerRow::Branch(branch) => {
                        let selected = match &picker.selected_name {
                            Some(name) => &branch.name == name,
                            None => branch.is_current,
                        };
                        let mut tags = Vec::new();
                        if branch.is_default {
                            tags.push("default");
                        }
                        if branch.worktree_path.is_some() && !branch.is_current {
                            tags.push("in a worktree");
                        }
                        let tags = tags.join(" · ");
                        let accessible = [
                            Some(branch.name.as_str()),
                            selected.then_some("current"),
                            (!tags.is_empty()).then_some(tags.as_str()),
                        ]
                        .into_iter()
                        .flatten()
                        .collect::<Vec<_>>()
                        .join(", ");
                        let worktree = branch.worktree_path.clone();
                        div()
                            .id(SharedString::from(format!("git-branch-row-{index}")))
                            .role(Role::ListItem)
                            .aria_label(accessible)
                            .h(px(28.))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .px(px(14.))
                            .mx_1()
                            .rounded(px(6.))
                            .cursor_pointer()
                            .when(highlighted, |row| row.bg(self.color(0x253046)))
                            .hover(|row| row.bg(self.color(0x253046)))
                            .when_some(worktree, |row, path| {
                                row.tooltip(move |window, cx| {
                                    Tooltip::new(format!("Checked out in {path}")).build(window, cx)
                                })
                            })
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.git_pick(index, window, cx)
                            }))
                            .child(
                                div().w(px(16.)).flex().justify_center().child(
                                    Icon::new(if selected {
                                        IconName::Check
                                    } else if branch.is_remote {
                                        IconName::Globe
                                    } else {
                                        IconName::GitBranch
                                    })
                                    .xsmall(),
                                ),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_sm()
                                    .when(selected, |name| name.font_weight(FontWeight::SEMIBOLD))
                                    .child(branch.name.clone()),
                            )
                            .when(!tags.is_empty(), |row| {
                                row.child(
                                    div()
                                        .flex_shrink_0()
                                        .text_xs()
                                        .text_color(self.color(0xe4e9f2).opacity(0.5))
                                        .child(tags),
                                )
                            })
                            .into_any_element()
                    }
                    super::PickerRow::Create(name) => {
                        let title = format!("Create branch “{name}”");
                        div()
                            .id(SharedString::from(format!("git-branch-row-{index}")))
                            .role(Role::ListItem)
                            .aria_label(title.clone())
                            .h(px(28.))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .px(px(14.))
                            .mx_1()
                            .rounded(px(6.))
                            .cursor_pointer()
                            .when(highlighted, |row| row.bg(self.color(0x253046)))
                            .hover(|row| row.bg(self.color(0x253046)))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.git_pick(index, window, cx)
                            }))
                            .child(
                                div()
                                    .w(px(16.))
                                    .flex()
                                    .justify_center()
                                    .child(Icon::new(IconName::Plus).xsmall()),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_sm()
                                    .font_weight(FontWeight::MEDIUM)
                                    .child(title),
                            )
                            .into_any_element()
                    }
                });
        }
        div()
            .id("git-branch-picker-content")
            .w(px(340.))
            .flex()
            .flex_col()
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                let key = &event.keystroke;
                if key.modifiers.control || key.modifiers.platform || key.modifiers.alt {
                    return;
                }
                match key.key.as_str() {
                    "down" => this.git_picker_move(true, cx),
                    "up" => this.git_picker_move(false, cx),
                    "escape" => this.git_close_picker(window, cx),
                    _ => return,
                }
                cx.stop_propagation();
            }))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(12.))
                    .pt(px(10.))
                    .pb(px(8.))
                    .child(Icon::new(IconName::Search).xsmall())
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(Input::new(&self.git_controls.search).appearance(false)),
                    ),
            )
            .child(div().h(px(1.)).bg(self.color(0x29303d)))
            .child(list)
            .child(div().h(px(1.)).bg(self.color(0x29303d)))
            .child(
                div()
                    .px(px(12.))
                    .pt(px(7.))
                    .pb(px(8.))
                    .truncate()
                    .text_xs()
                    .text_color(self.color(0xe4e9f2).opacity(0.5))
                    .child(picker.footer.clone()),
            )
            .into_any_element()
    }
}

fn git_controls_sync(
    status: &coincide_core::git_actions::GitStatus,
    pull_request: Option<&coincide_core::git_actions::GitPullRequest>,
    term: coincide_core::git_actions::host::Term,
) -> String {
    super::sync_label(status, pull_request, term)
}
