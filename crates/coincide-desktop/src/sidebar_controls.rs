//! Shared section controls: real collapse, ordering, sorting and saved filters.
use super::*;
use gpui_kit::assets::IconName;
use gpui_kit::component::menu::{ContextMenuExt, PopupMenuItem};
#[derive(Clone)]
pub(super) struct SectionDrag(pub String);
impl Render for SectionDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().px_3().py_2().child(self.0.clone())
    }
}
impl Coincide {
    pub(super) fn sidebar_section_header(
        &self,
        section: &'static str,
        label: &'static str,
        searching: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let collapsed = !searching && self.sidebar_preferences.collapsed(section);
        let parent = cx.entity().downgrade();
        div()
            .id(SharedString::from(format!("sidebar-section-{section}")))
            .flex()
            .items_center()
            .h(px(36.))
            .gap_1()
            .child(
                Button::new(SharedString::from(format!("sidebar-collapse-{section}")))
                    .ghost()
                    .compact()
                    .flex_1()
                    .h(px(30.))
                    .justify_start()
                    .icon(if collapsed {
                        IconName::ChevronRight
                    } else {
                        IconName::ChevronDown
                    })
                    .label(label)
                    .disabled(searching)
                    .accessibility_label(format!(
                        "{} {label}",
                        if collapsed { "Expand" } else { "Collapse" }
                    ))
                    .on_click(
                        cx.listener(move |this, _, _, cx| this.toggle_sidebar_section(section, cx)),
                    ),
            )
            .when(section == "projects", |row| {
                row.child(
                    Button::new("sidebar-add-project")
                        .icon(IconName::FolderPlus)
                        .accessibility_label("Add project folders")
                        .tooltip("Add folders…")
                        .ghost()
                        .compact()
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.open_project_form(project_management::Mode::Add, None, window, cx)
                        })),
                )
            })
            .when(section == "bots", |row| {
                row.child(
                    Button::new("sidebar-add-bot")
                        .icon(IconName::Plus)
                        .accessibility_label("New Bot")
                        .tooltip("New Bot…")
                        .ghost()
                        .compact()
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.sidebar_edit_bot(None, window, cx)
                        })),
                )
            })
            .on_drag(SectionDrag(section.into()), |drag, _, _, cx| {
                cx.new(|_| drag.clone())
            })
            .on_drop(cx.listener(move |this, drag: &SectionDrag, _, cx| {
                if searching || !sidebar_preferences::SECTIONS.contains(&drag.0.as_str()) {
                    return;
                }
                let order = sidebar_preferences::moved(
                    &this.sidebar_preferences.strings("sidebarSections"),
                    &drag.0,
                    Some(section),
                );
                this.sidebar_preference("sidebarSections", json!(order), cx);
            }))
            .context_menu(move |mut menu, _, _| {
                for target in sidebar_preferences::SECTIONS {
                    if target == section {
                        continue;
                    }
                    let parent = parent.clone();
                    menu = menu.item(
                        PopupMenuItem::new(format!("Move {label} before {target}")).on_click(
                            move |_, _, cx| {
                                let _ = parent.update(cx, |this, cx| {
                                    let order = sidebar_preferences::moved(
                                        &this.sidebar_preferences.strings("sidebarSections"),
                                        section,
                                        Some(target),
                                    );
                                    this.sidebar_preference("sidebarSections", json!(order), cx);
                                });
                            },
                        ),
                    );
                }
                let keys: &'static [(&'static str, &'static str)] = match section {
                    "projects" => &[
                        ("projectSort", "Sort Projects"),
                        ("threadSort", "Sort Threads"),
                    ],
                    "chats" => &[("chatSort", "Sort Chats")],
                    "bots" => &[("botSort", "Sort Bots")],
                    _ => &[],
                };
                for &(key, title) in keys {
                    menu = menu.item(PopupMenuItem::separator());
                    for (sort, name) in [
                        ("manual", "Manual"),
                        ("recentActivity", "Recent Activity"),
                        ("created", "Date Created"),
                        ("name", "Name"),
                    ] {
                        if (sort == "manual" && matches!(key, "threadSort" | "chatSort"))
                            || (sort == "created" && matches!(key, "projectSort" | "botSort"))
                        {
                            continue;
                        }
                        let parent = parent.clone();
                        menu = menu.item(PopupMenuItem::new(format!("{title}: {name}")).on_click(
                            move |_, _, cx| {
                                let _ = parent.update(cx, |this, cx| {
                                    if key == "botSort" {
                                        this.sidebar_preference("choseBotSort", json!(true), cx);
                                    }
                                    this.sidebar_preference(key, json!(sort), cx);
                                });
                            },
                        ));
                    }
                }
                if matches!(section, "projects" | "chats") {
                    menu = menu.item(PopupMenuItem::separator());
                    for (title, limit) in [
                        ("Fit to Sidebar", None),
                        ("10", Some(10)),
                        ("20", Some(20)),
                        ("50", Some(50)),
                        ("All", Some(0)),
                    ] {
                        let parent = parent.clone();
                        menu = menu.item(
                            PopupMenuItem::new(format!("Threads per Project: {title}")).on_click(
                                move |_, _, cx| {
                                    let _ = parent.update(cx, |this, cx| {
                                        this.sidebar_preference(
                                            "sidebarThreadsPerProject",
                                            json!(limit),
                                            cx,
                                        )
                                    });
                                },
                            ),
                        );
                    }
                }
                if section == "projects" {
                    menu = menu.item(PopupMenuItem::separator());
                    for (key, title) in [
                        ("showsArchivedThreads", "Show Archived Threads"),
                        ("showsSnoozedThreads", "Show Snoozed Threads"),
                        ("showsSettledThreads", "Show Settled Threads"),
                    ] {
                        let parent = parent.clone();
                        menu = menu.item(PopupMenuItem::new(title).on_click(move |_, _, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                let value = !this.sidebar_preferences.flag(key);
                                this.sidebar_preference(key, json!(value), cx);
                                this.show_archived =
                                    this.sidebar_preferences.flag("showsArchivedThreads");
                                this.show_snoozed =
                                    this.sidebar_preferences.flag("showsSnoozedThreads");
                                this.refresh(cx);
                            });
                        }));
                    }
                    for (title, expanded) in [
                        ("Expand All Projects", true),
                        ("Collapse All Projects", false),
                    ] {
                        let parent = parent.clone();
                        menu = menu.item(PopupMenuItem::new(title).on_click(move |_, _, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                let ids: Vec<_> = this
                                    .projects
                                    .iter()
                                    .filter(|project| {
                                        project["isChats"] != true && project["isBots"] != true
                                    })
                                    .map(|project| text(project, "id"))
                                    .collect();
                                for id in ids {
                                    this.sidebar_expand_project(&id, expanded, cx);
                                }
                            });
                        }));
                    }
                }
                menu
            })
            .into_any_element()
    }
    pub(super) fn sidebar_expand_project(
        &mut self,
        id: &str,
        expanded: bool,
        cx: &mut Context<Self>,
    ) {
        if id.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID) {
            self.toggle_sidebar_section("bots", cx);
            return;
        }
        if id == navigation::NO_PROJECT_ID {
            self.toggle_sidebar_section("chats", cx);
            return;
        }
        match call(
            &self.engine,
            "projects.patch",
            json!({"projectId":id,"patch":{"isExpanded":expanded}}),
        ) {
            Ok(_) => {
                if expanded {
                    self.collapsed_projects.remove(id);
                } else {
                    self.collapsed_projects.insert(id.into());
                }
                self.refresh(cx);
            }
            Err(error) => {
                self.status = format!("Project expansion could not be saved: {error}");
                cx.notify();
            }
        }
    }
}
