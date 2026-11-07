//! A bot is a navigation row, not a synthetic project conversation list.
//! Creating a conversation uses the saved Core bot validator, never UI drafts.
use super::*;
use gpui_kit::assets::IconName;
use gpui_kit::component::menu::{ContextMenuExt, PopupMenuItem};
use gpui_kit::component::tooltip::Tooltip;
#[derive(Clone)]
struct BotDrag(String);
impl Render for BotDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child("Move bot")
    }
}
/// Swift's personality chip names; a personality the user wrote reads Custom.
fn personality_name(bot: &Value) -> Option<String> {
    let personality = bot.get("personality").filter(|value| value.is_object())?;
    match personality["preset"].as_str().filter(|id| !id.is_empty()) {
        Some(id) => Some(
            match id {
                "cheerful" => "Cheerful",
                "calm" => "Calm & Concise",
                "witty" => "Witty",
                "mentor" => "Mentor",
                "coach" => "Coach",
                "candid" => "Straight Shooter",
                "curious" => "Curious Explorer",
                "professional" => "Professional",
                "gentle" => "Gentle",
                "creative" => "Creative",
                other => other,
            }
            .to_owned(),
        ),
        None => personality["custom"]
            .as_str()
            .filter(|text| !text.trim().is_empty())
            .map(|_| "Custom".to_owned()),
    }
}
/// The bot's working folder as Swift abbreviates it, under `~`.
fn bot_folder(bot: &Value, home: Option<&std::path::Path>) -> String {
    let folder = bot["folder"].as_str().unwrap_or_default();
    if folder.is_empty() || folder == "~" || folder.starts_with("~/") {
        return if folder.is_empty() {
            "~".into()
        } else {
            folder.into()
        };
    }
    match home.and_then(|home| std::path::Path::new(folder).strip_prefix(home).ok()) {
        Some(rest) if rest.as_os_str().is_empty() => "~".into(),
        Some(rest) => format!("~/{}", rest.display()),
        None => folder.into(),
    }
}
/// Swift's bot row tooltip: its name, personality, latest conversation, agent
/// and model, folder and status.
fn bot_tooltip(
    bot: &Value,
    name: &str,
    latest: Option<&str>,
    model: &str,
    status: Option<&str>,
    home: Option<&std::path::Path>,
) -> String {
    let mut lines = vec![name.to_owned()];
    if let Some(personality) = personality_name(bot) {
        lines.push(format!("Personality: {personality}"));
    }
    lines.extend(latest.map(str::to_owned));
    lines.push(format!(
        "{} · {model}",
        presentation::provider_name(bot["selection"]["provider"].as_str().unwrap_or_default())
    ));
    lines.push(bot_folder(bot, home));
    lines.extend(status.map(str::to_owned));
    lines.join("\n")
}

impl Coincide {
    pub(super) fn sidebar_edit_bot(
        &mut self,
        id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_settings_panel(window, cx);
        self.bots_open = true;
        self.bot_panel.update(cx, |panel, cx| {
            if let Some(id) = id {
                panel.select(id, cx);
            } else {
                panel.create(window, cx);
            }
        });
        self.sync_transcription_binding(cx);
        cx.notify();
    }
    pub(super) fn sidebar_open_bot(
        &mut self,
        id: String,
        fresh: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.thread_bulk.mode
            || self.sidebar_bot_pending.is_some()
            || self.media.shutdown_requested
            || self.media.close_requested
        {
            return;
        }
        let conversations = bot_conversations(&self.sidebar_all_threads, &id);
        let existing = if fresh {
            conversations.iter().find(|thread| {
                thread
                    .navigation
                    .as_ref()
                    .is_some_and(|meta| meta.item_count == Some(0) && meta.has_draft == Some(false))
            })
        } else {
            conversations.first()
        };
        if let Some(thread) = existing {
            let target = thread.id.clone();
            let reusable = !fresh
                || (!self.pending_drafts.contains_key(&target)
                    && !self.attachment_import_threads.contains(&target)
                    && call(&self.engine, "threads.read", json!({"threadId":target}))
                        .ok()
                        .is_some_and(|saved| {
                            saved["items"].as_array().is_some_and(Vec::is_empty)
                                && saved["draft"].as_str().is_none_or(str::is_empty)
                                && saved["draftContext"].as_array().is_none_or(Vec::is_empty)
                                && saved["rustDraftImages"]
                                    .as_array()
                                    .is_none_or(Vec::is_empty)
                        }));
            if reusable {
                self.created_bot_thread_to_focus = Some(target.clone());
                self.select(&target, window, cx);
                return;
            }
        }
        if !self.sidebar_bots.iter().any(|bot| {
            bot["id"]
                .as_str()
                .is_some_and(|stored| stored.eq_ignore_ascii_case(&id))
        }) {
            self.status = "This bot is no longer available.".into();
            cx.notify();
            return;
        }
        self.sidebar_bot_pending = Some(id.clone());
        let engine = self.engine.clone();
        let create = cx.background_executor().spawn(async move {
            let saved = call(&engine, "bots.read", json!({"botId":id}))?;
            call(
                &engine,
                "bots.conversations.create",
                json!({"botId":id,"baseline":saved["baseline"]}),
            )
        });
        let completion = cx.spawn_in(window, async move |this, cx| {
            let result = create.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.sidebar_bot_pending = None;
                if this.media.shutdown_requested || this.media.close_requested {
                    return;
                }
                match result {
                    Ok(reply) => {
                        this.refresh(cx);
                        let created = text(&reply, "threadId");
                        this.created_bot_thread_to_focus = Some(created.clone());
                        this.select(&created, window, cx);
                    }
                    Err(error) => {
                        this.status = format!("Bot conversation could not be opened: {error}")
                    }
                }
                cx.notify();
            });
        });
        self.navigation_tasks.push(completion);
        cx.notify();
    }
    fn sidebar_bot_matches(&self, bot: &Value, searching: bool, cx: &Context<Self>) -> bool {
        !searching
            || sidebar_search::terms_match(&text(bot, "name"), &self.search.read(cx).value())
            || self.threads.iter().any(|thread| {
                thread
                    .navigation
                    .as_ref()
                    .and_then(|meta| meta.bot_id.as_deref())
                    .is_some_and(|id| {
                        bot["id"]
                            .as_str()
                            .is_some_and(|known| known.eq_ignore_ascii_case(id))
                    })
            })
    }
    pub(super) fn has_sidebar_bot_rows(&self, searching: bool, cx: &Context<Self>) -> bool {
        self.sidebar_bots
            .iter()
            .any(|bot| self.sidebar_bot_matches(bot, searching, cx))
    }
    pub(super) fn sidebar_bot_rows(&self, searching: bool, cx: &mut Context<Self>) -> AnyElement {
        let mut bots: Vec<_> = self
            .sidebar_bots
            .iter()
            .filter(|bot| self.sidebar_bot_matches(bot, searching, cx))
            .collect();
        match self.sidebar_preferences.sort("botSort") {
            "name" => bots.sort_by(|left, right| {
                sidebar_preferences::name_order(&text(left, "name"), &text(right, "name"))
            }),
            "recentActivity" => bots.sort_by(|left, right| {
                let stamp = |bot: &Value| {
                    bot_conversations(&self.sidebar_all_threads, &text(bot, "id"))
                        .first()
                        .and_then(|thread| thread.navigation.as_ref()?.updated_at)
                        .unwrap_or(0.)
                };
                stamp(right).total_cmp(&stamp(left))
            }),
            _ => {}
        }
        let mut rows = div().flex().flex_col();
        for bot in bots {
            let id = text(bot, "id");
            let drag_id = id.clone();
            let drop_id = id.clone();
            let baseline = self.sidebar_bot_baseline.clone();
            let click_id = id.clone();
            let menu_id = id.clone();
            let conversations = bot_conversations(&self.sidebar_all_threads, &id);
            let latest = conversations.first();
            let selected = self
                .selected
                .as_ref()
                .and_then(|thread| thread["botID"].as_str())
                .is_some_and(|current| current.eq_ignore_ascii_case(&id));
            let name = bot["name"]
                .as_str()
                .filter(|name| !name.is_empty())
                .unwrap_or("Bot")
                .to_owned();
            let preview = latest
                .and_then(|thread| thread.navigation.as_ref()?.preview.clone())
                .unwrap_or_else(|| "Say hello".into());
            let running = conversations
                .iter()
                .any(|thread| self.running.contains(&thread.id));
            // The most pressing unseen result among its conversations: a
            // failure shows as a badge, a finished reply as the green dot.
            let unseen = conversations
                .iter()
                .filter_map(|thread| {
                    self.sidebar_preferences.document["unseen"][&thread.id].as_str()
                })
                .fold(None, |strongest, kind| match strongest {
                    Some("failed") => strongest,
                    _ => Some(kind),
                })
                .filter(|_| !running);
            let failed = unseen == Some("failed");
            let completed = unseen.is_some() && !failed;
            let status = if running {
                Some("Working")
            } else if failed {
                Some("Failed")
            } else if completed {
                Some("Completed")
            } else {
                None
            };
            let selection = &bot["selection"];
            let model_id = text(selection, "modelID");
            let model = project_defaults_ui::catalog_model(
                &self.selection_ui.catalog,
                &text(selection, "provider"),
                &model_id,
            )
            .and_then(|model| model["displayName"].as_str())
            .map(str::to_owned)
            .unwrap_or(model_id);
            let home = std::env::var_os("HOME")
                .or_else(|| std::env::var_os("USERPROFILE"))
                .map(std::path::PathBuf::from);
            let mut tooltip = bot_tooltip(
                bot,
                &name,
                latest.map(|thread| thread.title.as_str()),
                &model,
                status,
                home.as_deref(),
            );
            let age = navigation::sidebar_age(
                latest.and_then(|thread| thread.navigation.as_ref()?.updated_at),
                coincide_core::store::swift_timestamp(),
            );
            let active_schedules = self
                .sidebar_schedules
                .iter()
                .filter(|task| {
                    task["isPaused"] != true
                        && task["awaitingApproval"] != true
                        && conversations
                            .iter()
                            .any(|thread| task["threadID"] == thread.id)
                })
                .map(|task| text(task, "name"))
                .collect::<Vec<_>>();
            if !active_schedules.is_empty() {
                tooltip.push('\n');
                tooltip.push_str(&active_schedules.join("\n"));
            }
            let accessibility = [Some(name.as_str()), status, Some(preview.as_str())]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(", ");
            let ink = self.color(0xe4e9f2);
            let theme = cx.theme();
            let (danger, success) = (theme.danger, theme.success);
            let parent = cx.entity().downgrade();
            let past = conversations
                .iter()
                .map(|thread| (thread.id.clone(), thread.title.clone()))
                .collect::<Vec<_>>();
            rows = rows.child(
                div()
                    .id(SharedString::from(format!("sidebar-bot-drag-{id}")))
                    .w_full()
                    .on_drag(BotDrag(drag_id), |drag, _, _, cx| cx.new(|_| drag.clone()))
                    .on_drop(cx.listener(move |this, drag: &BotDrag, _, cx| {
                        if drag.0.eq_ignore_ascii_case(&drop_id)
                            || !this.search.read(cx).value().trim().is_empty()
                            || this.thread_bulk.mode
                            || this.sidebar_bot_pending.is_some()
                            || this.media.close_requested
                            || this.media.shutdown_requested
                        {
                            return;
                        }
                        let mut ids: Vec<_> = this
                            .sidebar_bots
                            .iter()
                            .map(|bot| text(bot, "id"))
                            .collect();
                        if !ids.iter().any(|id| id.eq_ignore_ascii_case(&drag.0)) {
                            return;
                        }
                        ids.retain(|id| !id.eq_ignore_ascii_case(&drag.0));
                        let index = ids
                            .iter()
                            .position(|id| id.eq_ignore_ascii_case(&drop_id))
                            .unwrap_or(ids.len());
                        ids.insert(index, drag.0.clone());
                        let result = try_state(&this.engine)
                            .and_then(|mut engine| engine.reorder_native_bots(&ids, &baseline));
                        match result {
                            Ok(reply) => {
                                this.sidebar_bots =
                                    reply["bots"].as_array().cloned().unwrap_or_default();
                                this.sidebar_bot_baseline = text(&reply, "baseline");
                                this.sidebar_preference("choseBotSort", json!(true), cx);
                                this.sidebar_preference("botSort", json!("manual"), cx);
                            }
                            Err(error) => {
                                this.status = format!("Bots could not be reordered: {error}")
                            }
                        }
                        cx.notify();
                    }))
                    .child(
                        Button::new(SharedString::from(format!("sidebar-bot-{id}")))
                            .ghost()
                            .compact()
                            .w_full()
                            .h(px(44.))
                            .justify_start()
                            .selected(selected)
                            .disabled(self.sidebar_bot_pending.is_some())
                            .accessibility_label(accessibility)
                            .tooltip(tooltip)
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .w_full()
                                    .min_w_0()
                                    .child(bot_avatar::avatar(&bot["avatar"], 26.))
                                    .child(
                                        div()
                                            .flex()
                                            .flex_col()
                                            .min_w_0()
                                            .flex_1()
                                            .child(
                                                div()
                                                    .flex()
                                                    .items_center()
                                                    .justify_between()
                                                    .gap_1()
                                                    .child(
                                                        div()
                                                            .truncate()
                                                            .text_size(px(13.))
                                                            .font_weight(if unseen.is_some() {
                                                                FontWeight::SEMIBOLD
                                                            } else {
                                                                FontWeight::MEDIUM
                                                            })
                                                            .child(name),
                                                    )
                                                    .child(
                                                        div()
                                                            .flex()
                                                            .flex_shrink_0()
                                                            .items_center()
                                                            .gap_1()
                                                            .when(failed, |row| {
                                                                row.child(
                                                                    div()
                                                                        .px(px(5.))
                                                                        .rounded_full()
                                                                        .bg(danger.opacity(0.18))
                                                                        .text_color(danger)
                                                                        .text_size(px(10.))
                                                                        .font_weight(
                                                                            FontWeight::SEMIBOLD,
                                                                        )
                                                                        .child("Failed"),
                                                                )
                                                            })
                                                            .when(completed, |row| {
                                                                row.child(
                                                                    div()
                                                                        .size(px(7.))
                                                                        .rounded_full()
                                                                        .bg(success),
                                                                )
                                                            })
                                                            .when(!failed, |row| {
                                                                row.child(
                                                                    div()
                                                                        .text_size(px(11.))
                                                                        .text_color(
                                                                            ink.opacity(0.55),
                                                                        )
                                                                        .child(age),
                                                                )
                                                            }),
                                                    ),
                                            )
                                            .child(div().truncate().text_xs().child(preview)),
                                    )
                                    .when(running, |row| {
                                        row.child(
                                            gpui_kit::component::spinner::Spinner::new().small(),
                                        )
                                    })
                                    .when(!active_schedules.is_empty(), |row| {
                                        row.child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "sidebar-bot-clock-{id}"
                                                )))
                                                .child(IconName::Clock)
                                                .tooltip(move |window, cx| {
                                                    Tooltip::new(active_schedules.join("\n"))
                                                        .build(window, cx)
                                                }),
                                        )
                                    }),
                            )
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.sidebar_open_bot(click_id.clone(), false, window, cx)
                            }))
                            .context_menu(move |mut menu, window, cx| {
                                let parent_new = parent.clone();
                                let id = menu_id.clone();
                                menu = menu.item(PopupMenuItem::new("New Conversation").on_click(
                                    move |_, window, cx| {
                                        let _ = parent_new.update(cx, |this, cx| {
                                            this.sidebar_open_bot(id.clone(), true, window, cx)
                                        });
                                    },
                                ));
                                let parent_past = parent.clone();
                                let past_rows = past.clone();
                                menu = menu.submenu(
                                    "Past Conversations",
                                    window,
                                    cx,
                                    move |mut menu, _, _| {
                                        for (thread, title) in &past_rows {
                                            let parent = parent_past.clone();
                                            let thread = thread.clone();
                                            menu = menu.item(
                                                PopupMenuItem::new(title.clone()).on_click(
                                                    move |_, window, cx| {
                                                        let _ = parent.update(cx, |this, cx| {
                                                            this.select(&thread, window, cx)
                                                        });
                                                    },
                                                ),
                                            );
                                        }
                                        menu
                                    },
                                );
                                if let Some((latest, _)) = past.first() {
                                    let parent = parent.clone();
                                    let latest = latest.clone();
                                    menu = menu.item(PopupMenuItem::new("Schedule…").on_click(
                                        move |_, window, cx| {
                                            let _ = parent.update(cx, |this, cx| {
                                                this.select(&latest, window, cx);
                                                if this
                                                    .selected
                                                    .as_ref()
                                                    .is_some_and(|thread| thread["id"] == latest)
                                                {
                                                    this.open_conversation_schedules(window, cx);
                                                    this.open_schedule_editor(None, window, cx);
                                                }
                                            });
                                        },
                                    ));
                                }
                                menu = menu.item(PopupMenuItem::separator());
                                let parent_edit = parent.clone();
                                let id = menu_id.clone();
                                menu = menu.item(PopupMenuItem::new("Edit Bot…").on_click(
                                    move |_, window, cx| {
                                        let _ = parent_edit.update(cx, |this, cx| {
                                            this.sidebar_edit_bot(Some(id.clone()), window, cx)
                                        });
                                    },
                                ));
                                let parent_delete = parent.clone();
                                let id = menu_id.clone();
                                menu.item(PopupMenuItem::separator()).item(
                                    PopupMenuItem::new("Delete Bot…").on_click(move |_, _, cx| {
                                        let _ = parent_delete.update(cx, |this, cx| {
                                            this.sidebar_bot_delete_review(id.clone(), cx)
                                        });
                                    }),
                                )
                            }),
                    ),
            );
        }
        rows.into_any_element()
    }
}
pub(super) fn bot_conversations<'a>(
    threads: &'a [ThreadSummary],
    bot: &str,
) -> Vec<&'a ThreadSummary> {
    let mut rows: Vec<_> = threads
        .iter()
        .filter(|thread| {
            !thread.archived
                && thread
                    .navigation
                    .as_ref()
                    .and_then(|meta| meta.bot_id.as_deref())
                    .is_some_and(|id| id.eq_ignore_ascii_case(bot))
        })
        .collect();
    rows.sort_by(|left, right| {
        right
            .navigation
            .as_ref()
            .and_then(|meta| meta.updated_at)
            .unwrap_or(0.)
            .total_cmp(
                &left
                    .navigation
                    .as_ref()
                    .and_then(|meta| meta.updated_at)
                    .unwrap_or(0.),
            )
            .then_with(|| left.id.cmp(&right.id))
    });
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn bot_tooltip_lists_personality_latest_conversation_agent_folder_and_status() {
        let home = std::path::Path::new("/Users/fixture");
        let bot = json!({"name":"Helper","personality":{"preset":"calm"},"folder":"/Users/fixture/work/site","selection":{"provider":"claude","modelID":"sonnet"}});
        assert_eq!(
            bot_tooltip(
                &bot,
                "Helper",
                Some("Fix the build"),
                "Sonnet",
                Some("Completed"),
                Some(home)
            ),
            "Helper\nPersonality: Calm & Concise\nFix the build\nClaude · Sonnet\n~/work/site\nCompleted"
        );
        let plain = json!({"selection":{"provider":"codex","modelID":"default"},"personality":{"custom":"  "}});
        assert_eq!(
            bot_tooltip(&plain, "Bot", None, "default", None, Some(home)),
            "Bot\nCodex · default\n~"
        );
        assert_eq!(
            personality_name(&json!({"personality":{"custom":"Speak like a pirate"}})).as_deref(),
            Some("Custom")
        );
        assert_eq!(
            bot_folder(&json!({"folder":"~/notes"}), Some(home)),
            "~/notes"
        );
        assert_eq!(
            bot_folder(&json!({"folder":"/srv/bot"}), Some(home)),
            "/srv/bot"
        );
        assert_eq!(
            bot_folder(&json!({"folder":"/Users/fixture"}), Some(home)),
            "~"
        );
    }
    #[::core::prelude::v1::test]
    fn latest_bot_routing_ignores_pinning_archived_and_other_bots_and_handles_legacy_summaries() {
        let row = |id: &str, bot: Option<&str>, date: f64, archived: bool, pinned: bool| {
            serde_json::from_value::<ThreadSummary>(json!({"id":id,"title":id,"project_id":"bots","archived":archived,"pinned":pinned,"snoozed_until":null,"navigation":{"bot_id":bot,"updated_at":date}})).unwrap()
        };
        let rows = vec![
            row("old", Some("BOT"), 1., false, true),
            row("latest", Some("bot"), 5., false, false),
            row("archived", Some("BOT"), 9., true, false),
            row("other", Some("other"), 10., false, false),
            row("legacy", None, 20., false, false),
        ];
        assert_eq!(
            bot_conversations(&rows, "Bot")
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["latest", "old"]
        );
    }
}
