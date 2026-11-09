//! The sidebar's conversation menus, as Swift's SidebarViewController builds
//! them (buildThreadMenu, buildBulkMenu, addMoveMenu, addOpenItems). Items act
//! on the clicked conversation and leave the open one open; only Fork Thread
//! and Schedule… open a conversation, as they do in Swift.
use super::*;
use coincide_core::api::ThreadFlagAction;
use gpui_kit::assets::IconName;
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use std::path::PathBuf;
use std::rc::Rc;

/// A menu item's click handler, shared by the items a submenu rebuilds.
pub(super) type Handler = Rc<dyn Fn(&ClickEvent, &mut Window, &mut App)>;

/// What a conversation's menu offers, captured when its row renders.
#[derive(Clone)]
pub(super) struct ThreadMenu {
    pub id: String,
    pub project: String,
    pub pinned: bool,
    pub archived: bool,
    pub unseen: bool,
    pub branch: Option<String>,
    pub can_fork: bool,
    pub snoozed: bool,
    pub settled: bool,
    pub running: bool,
}

/// The rest of the sidebar a menu needs, shared by every row of one render.
#[derive(Clone)]
pub(super) struct MenuContext {
    pub parent: WeakEntity<Coincide>,
    pub targets: Vec<open_targets::Target>,
    pub preferred: Option<open_targets::Target>,
    /// Every project a conversation can move to, in the sidebar's order, Chats
    /// last: (id, name, is Chats).
    pub destinations: Vec<(String, String, bool)>,
}

#[derive(Clone)]
pub(super) enum ThreadAction {
    Rename,
    Pin(bool),
    Unread(bool),
    NewOnBranch,
    Fork,
    Schedule,
    Move(String),
    OpenIn(open_targets::Target),
    Reveal,
    CopyPath,
    CopyId,
    Snooze(f64),
    Unsnooze,
    Settle(bool),
    Archive(bool),
    Delete,
}

#[derive(Clone, Copy)]
pub(super) enum BulkAction {
    Archive(bool),
    Settle(bool),
    Delete,
}

fn handler(context: &MenuContext, id: &str, action: ThreadAction) -> Handler {
    let parent = context.parent.clone();
    let id = id.to_owned();
    Rc::new(move |_, window, cx| {
        let _ = parent.update(cx, |this, cx| {
            this.sidebar_thread_action(&id, action.clone(), window, cx)
        });
    })
}
fn on(handler: &Handler) -> impl Fn(&ClickEvent, &mut Window, &mut App) + use<> {
    let handler = handler.clone();
    move |event, window, cx| handler(event, window, cx)
}
fn act(
    context: &MenuContext,
    id: &str,
    action: ThreadAction,
) -> impl Fn(&ClickEvent, &mut Window, &mut App) + use<> {
    on(&handler(context, id, action))
}

/// A menu item with Swift's grey second line under its title.
fn subtitled(title: &'static str, detail: String) -> PopupMenuItem {
    PopupMenuItem::element(move |_, cx| {
        div().flex().flex_col().child(title).child(
            div()
                .text_xs()
                .text_color(cx.theme().muted_foreground)
                .child(detail.clone()),
        )
    })
}

/// Open in the preferred app, Open In each installed one, Reveal in the file
/// manager and Copy Path (Swift's addOpenItems). `act_for` binds each item to
/// a conversation or a project.
pub(super) fn open_items(
    mut menu: PopupMenu,
    context: &MenuContext,
    act_for: impl Fn(ThreadAction) -> Handler,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    if let Some(preferred) = context.preferred.clone() {
        menu = menu.item(
            PopupMenuItem::new(format!("Open in {}", preferred.name))
                .on_click(on(&act_for(ThreadAction::OpenIn(preferred)))),
        );
    }
    let targets = context
        .targets
        .iter()
        .map(|target| {
            (
                target.clone(),
                act_for(ThreadAction::OpenIn(target.clone())),
            )
        })
        .collect::<Vec<_>>();
    menu = menu.submenu("Open In", window, cx, move |mut menu, _, _| {
        for (target, handler) in &targets {
            menu = menu.item(PopupMenuItem::new(target.name).on_click(on(handler)));
        }
        menu
    });
    menu.item(
        PopupMenuItem::new(open_targets::reveal_title())
            .on_click(on(&act_for(ThreadAction::Reveal))),
    )
    .item(PopupMenuItem::new("Copy Path").on_click(on(&act_for(ThreadAction::CopyPath))))
}

fn folder_handler(context: &MenuContext, folder: PathBuf, action: ThreadAction) -> Handler {
    let parent = context.parent.clone();
    Rc::new(move |_, window, cx| {
        let _ = parent.update(cx, |this, cx| {
            this.sidebar_folder_action(folder.clone(), action.clone(), window, cx)
        });
    })
}

/// Swift's buildProjectMenu. Chats have no folder of the user's to open,
/// rename or remove.
pub(super) fn project_menu(
    mut menu: PopupMenu,
    id: &str,
    chats: bool,
    folder: Option<PathBuf>,
    context: &MenuContext,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    let project_item =
        |title: &'static str, run: fn(&mut Coincide, &str, &mut Window, &mut Context<Coincide>)| {
            let parent = context.parent.clone();
            let id = id.to_owned();
            PopupMenuItem::new(title).on_click(move |_, window, cx| {
                let _ = parent.update(cx, |this, cx| run(this, &id, window, cx));
            })
        };
    menu = menu.item(project_item(
        if chats { "New Chat" } else { "New Thread" },
        |this, id, window, cx| {
            this.selected_project = Some(id.to_owned());
            this.new_thread_in_project(id, window, cx);
        },
    ));
    let Some(folder) = folder.filter(|_| !chats) else {
        return menu;
    };
    let bind = {
        let context = context.clone();
        let folder = folder.clone();
        move |action| folder_handler(&context, folder.clone(), action)
    };
    menu = open_items(
        menu.item(PopupMenuItem::separator()),
        context,
        bind,
        window,
        cx,
    )
    .item(PopupMenuItem::separator());
    if !folder.is_dir() {
        menu = menu.item(project_item("Locate Folder…", |this, id, window, cx| {
            this.project_picker_open = true;
            this.open_project_form(
                project_management::Mode::Relocate,
                Some(id.to_owned()),
                window,
                cx,
            );
        }));
    }
    menu.item(project_item(
        "Project Defaults…",
        |this, id, window, cx| this.open_project_defaults(id.to_owned(), window, cx),
    ))
    .item(project_item("Rename…", |this, id, window, cx| {
        this.begin_project_rename(id, window, cx)
    }))
    .item(project_item(
        "Remove from Coincide…",
        |this, id, window, cx| {
            this.project_picker_open = true;
            this.open_project_form(
                project_management::Mode::Remove,
                Some(id.to_owned()),
                window,
                cx,
            );
        },
    ))
}

/// Swift's buildThreadMenu for one conversation.
pub(super) fn thread_menu(
    mut menu: PopupMenu,
    model: &ThreadMenu,
    context: &MenuContext,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    let id = model.id.as_str();
    menu = menu
        .item(PopupMenuItem::new("Rename…").on_click(act(context, id, ThreadAction::Rename)))
        .item(
            PopupMenuItem::new(if model.pinned { "Unpin" } else { "Pin" }).on_click(act(
                context,
                id,
                ThreadAction::Pin(!model.pinned),
            )),
        )
        .item(
            PopupMenuItem::new(if model.unseen {
                "Mark as Read"
            } else {
                "Mark as Unread"
            })
            .on_click(act(context, id, ThreadAction::Unread(!model.unseen))),
        );
    if let Some(branch) = model.branch.as_deref().filter(|branch| !branch.is_empty()) {
        menu = menu.item(
            PopupMenuItem::new(format!("New Thread on {branch}")).on_click(act(
                context,
                id,
                ThreadAction::NewOnBranch,
            )),
        );
    }
    menu = menu
        .item(
            PopupMenuItem::new("Fork Thread")
                .disabled(!model.can_fork)
                .on_click(act(context, id, ThreadAction::Fork)),
        )
        .item(PopupMenuItem::new("Schedule…").on_click(act(context, id, ThreadAction::Schedule)));
    menu = move_menu(menu, model, context, window, cx).item(PopupMenuItem::separator());
    let bind = {
        let context = context.clone();
        let id = model.id.clone();
        move |action| handler(&context, &id, action)
    };
    menu = open_items(menu, context, bind, window, cx)
        .item(PopupMenuItem::new("Copy Thread ID").on_click(act(context, id, ThreadAction::CopyId)))
        .item(PopupMenuItem::separator());
    if model.snoozed {
        menu = menu.item(PopupMenuItem::new("Unsnooze").on_click(act(
            context,
            id,
            ThreadAction::Unsnooze,
        )));
    } else {
        let presets = coincide_core::scheduling::native_snooze_menu()
            .into_iter()
            .map(|(title, detail, date)| {
                (
                    title,
                    detail,
                    handler(context, id, ThreadAction::Snooze(date)),
                )
            })
            .collect::<Vec<_>>();
        menu = menu.submenu("Snooze", window, cx, move |mut menu, _, _| {
            for (title, detail, handler) in &presets {
                menu = menu.item(subtitled(title, detail.clone()).on_click(on(handler)));
            }
            menu
        });
    }
    // Settling waits for the work and approvals to finish, as in Swift; the
    // approvals are checked again when it is chosen.
    menu = menu.item(
        if model.settled {
            PopupMenuItem::new("Unsettle")
        } else {
            subtitled("Settle", "Returns when new activity arrives".into())
        }
        .disabled(!model.settled && model.running)
        .on_click(act(context, id, ThreadAction::Settle(!model.settled))),
    );
    menu.item(
        PopupMenuItem::new(if model.archived {
            "Unarchive"
        } else {
            "Archive"
        })
        .disabled(!model.archived && model.running)
        .on_click(act(context, id, ThreadAction::Archive(!model.archived))),
    )
    .item(PopupMenuItem::new("Delete…").on_click(act(context, id, ThreadAction::Delete)))
}

/// Swift's addMoveMenu: every other project, then Chats; disabled with the
/// reason while the conversation can't move.
fn move_menu(
    menu: PopupMenu,
    model: &ThreadMenu,
    context: &MenuContext,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    if model.running {
        return menu.item(
            subtitled("Move to Project", "Stop the running agent first".into()).disabled(true),
        );
    }
    let destinations = move_destinations(&context.destinations, &model.project)
        .into_iter()
        .map(|(target, name, chats)| {
            (
                name,
                chats,
                handler(context, &model.id, ThreadAction::Move(target)),
            )
        })
        .collect::<Vec<_>>();
    if destinations.is_empty() {
        return menu.item(PopupMenuItem::new("Move to Project").disabled(true));
    }
    menu.submenu("Move to Project", window, cx, move |mut menu, _, _| {
        for (index, (name, chats, handler)) in destinations.iter().enumerate() {
            if *chats && index > 0 {
                menu = menu.item(PopupMenuItem::separator());
            }
            menu = menu.item(
                PopupMenuItem::new(name.clone())
                    .icon(if *chats {
                        IconName::MessagesSquare
                    } else {
                        IconName::Folder
                    })
                    .on_click(on(handler)),
            );
        }
        menu
    })
}

/// The destinations other than the conversation's own project, Chats last.
pub(super) fn move_destinations(
    projects: &[(String, String, bool)],
    current: &str,
) -> Vec<(String, String, bool)> {
    let mut result = projects
        .iter()
        .filter(|(id, _, _)| !id.eq_ignore_ascii_case(current))
        .cloned()
        .collect::<Vec<_>>();
    result.sort_by_key(|(_, _, chats)| *chats);
    result
}

/// Swift's buildBulkMenu for a multi-selection that includes the clicked row.
pub(super) fn bulk_menu(
    menu: PopupMenu,
    ids: &[String],
    any_archived: bool,
    any_running: bool,
    parent: &WeakEntity<Coincide>,
) -> PopupMenu {
    let item = |title: &'static str, action: BulkAction| {
        let parent = parent.clone();
        let ids = ids.to_vec();
        PopupMenuItem::new(title).on_click(move |_, window, cx| {
            let _ = parent.update(cx, |this, cx| {
                this.sidebar_bulk_action(&ids, action, window, cx)
            });
        })
    };
    let mut menu =
        menu.item(item("Archive Threads", BulkAction::Archive(true)).disabled(any_running));
    if any_archived {
        menu = menu.item(item("Unarchive Threads", BulkAction::Archive(false)));
    }
    menu.item(item("Settle Threads", BulkAction::Settle(true)).disabled(any_running))
        .item(item("Unsettle Threads", BulkAction::Settle(false)))
        .item(PopupMenuItem::separator())
        .item(item("Delete Threads", BulkAction::Delete))
}

impl Coincide {
    /// The menu context for one render of the sidebar.
    pub(super) fn sidebar_menu_context(&self, cx: &Context<Self>) -> MenuContext {
        let mut destinations = self
            .projects
            .iter()
            .filter(|project| {
                !text(project, "id")
                    .eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID)
                    && project["isBots"] != true
            })
            .map(|project| {
                let id = text(project, "id");
                let chats = project["isChats"] == true || id == navigation::NO_PROJECT_ID;
                let name = if chats {
                    "Chats".to_owned()
                } else {
                    text(project, "name")
                };
                (id, name, chats)
            })
            .collect::<Vec<_>>();
        destinations.sort_by_key(|(_, _, chats)| *chats);
        MenuContext {
            parent: cx.entity().downgrade(),
            targets: self.open_targets.clone(),
            preferred: open_targets::preferred(&self.open_targets, &self.settings).cloned(),
            destinations,
        }
    }

    pub(super) fn sidebar_thread_action(
        &mut self,
        id: &str,
        action: ThreadAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        // Acting on one row discards a reviewed batch, which may include it.
        self.thread_bulk.invalidate();
        match action {
            ThreadAction::Rename => self.begin_sidebar_rename(id, window, cx),
            ThreadAction::Pin(pinned) => {
                self.patch_navigation(
                    id,
                    json!({"isPinned":pinned}),
                    if pinned {
                        "Conversation pinned."
                    } else {
                        "Conversation unpinned."
                    },
                    cx,
                );
            }
            ThreadAction::Unread(unread) => {
                self.sidebar_thread_marker("unseen", id, unread.then(|| json!("completed")), cx)
            }
            ThreadAction::NewOnBranch => self.new_thread_on_branch(id, window, cx),
            ThreadAction::Fork => {
                match call(&self.engine, "threads.fork", json!({"threadId":id})) {
                    Ok(fork) => {
                        self.refresh(cx);
                        self.select(&text(&fork, "id"), window, cx);
                    }
                    Err(error) => {
                        self.status = error.to_string();
                        cx.notify();
                    }
                }
            }
            ThreadAction::Schedule => {
                self.select(id, window, cx);
                if self
                    .selected
                    .as_ref()
                    .is_some_and(|thread| thread["id"] == id)
                {
                    self.open_conversation_schedules(window, cx);
                    self.open_schedule_editor(None, window, cx);
                }
            }
            ThreadAction::Move(target) => self.sidebar_move_to(id.to_owned(), target, cx),
            ThreadAction::OpenIn(_) | ThreadAction::Reveal | ThreadAction::CopyPath => {
                if let Some(folder) = self.thread_folder(id) {
                    self.sidebar_folder_action(folder, action, window, cx);
                } else {
                    self.status = "The conversation folder is unavailable.".into();
                    cx.notify();
                }
            }
            ThreadAction::CopyId => cx.write_to_clipboard(ClipboardItem::new_string(id.to_owned())),
            ThreadAction::Snooze(date) => {
                self.patch_navigation(
                    id,
                    json!({"snoozedUntil":date}),
                    "Conversation snoozed.",
                    cx,
                );
            }
            ThreadAction::Unsnooze => {
                self.patch_navigation(
                    id,
                    json!({"snoozedUntil":null}),
                    "Conversation unsnoozed.",
                    cx,
                );
            }
            ThreadAction::Settle(settled) => self.settle_threads(&[id.to_owned()], settled, cx),
            ThreadAction::Archive(false) => {
                self.set_archived(id, false, cx);
            }
            ThreadAction::Archive(true) => {
                if self.running.iter().any(|running| running == id) {
                    self.status = "Stop this conversation before archiving it.".into();
                    cx.notify();
                } else if self.settings["confirmBeforeArchivingThreads"]
                    .as_bool()
                    .unwrap_or(true)
                {
                    // The confirmation belongs to the open conversation's header.
                    self.select(id, window, cx);
                    if self
                        .selected
                        .as_ref()
                        .is_some_and(|thread| thread["id"] == id)
                    {
                        self.request_archive(window, cx);
                    }
                } else if self
                    .selected
                    .as_ref()
                    .is_some_and(|thread| thread["id"] == id)
                {
                    self.archive_open_thread(id, window, cx);
                } else {
                    self.set_archived(id, true, cx);
                }
            }
            ThreadAction::Delete => self.sidebar_delete_review(id.to_owned(), cx),
        }
    }

    /// Open In, Reveal and Copy Path for a conversation's or project's folder.
    fn sidebar_folder_action(
        &mut self,
        folder: PathBuf,
        action: ThreadAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        match action {
            ThreadAction::OpenIn(target) => {
                self.change_setting("preferredOpenTarget", json!(target.id), window, cx);
                self.open_in_folder(target, folder, cx);
            }
            ThreadAction::Reveal => self.reveal_in_file_manager(folder, cx),
            ThreadAction::CopyPath => cx.write_to_clipboard(ClipboardItem::new_string(
                folder.to_string_lossy().into_owned(),
            )),
            _ => {}
        }
    }

    pub(super) fn sidebar_bulk_action(
        &mut self,
        ids: &[String],
        action: BulkAction,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        match action {
            BulkAction::Archive(archived) => self.review_bulk(
                if archived {
                    ThreadFlagAction::Archive
                } else {
                    ThreadFlagAction::Restore
                },
                cx,
            ),
            BulkAction::Settle(settled) => {
                self.settle_threads(ids, settled, cx);
                self.thread_bulk.close_selection();
                cx.notify();
            }
            BulkAction::Delete => {
                self.thread_bulk.close_selection();
                self.sidebar_delete_threads(ids.to_vec(), cx);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn move_offers_every_other_project_with_chats_last() {
        let projects = vec![
            ("chats".to_owned(), "Chats".to_owned(), true),
            ("A".to_owned(), "Alpha".to_owned(), false),
            ("b".to_owned(), "Beta".to_owned(), false),
        ];
        assert_eq!(
            move_destinations(&projects, "a")
                .into_iter()
                .map(|row| row.1)
                .collect::<Vec<_>>(),
            ["Beta", "Chats"]
        );
        assert_eq!(
            move_destinations(&projects, "chats")
                .into_iter()
                .map(|row| row.1)
                .collect::<Vec<_>>(),
            ["Alpha", "Beta"]
        );
    }
}
