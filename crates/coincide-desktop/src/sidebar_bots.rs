//! A bot is a navigation row, not a synthetic project conversation list.
//! Creating a conversation uses the saved Core bot validator, never UI drafts.
use super::*;
use gpui_kit::assets::IconName;
use gpui_kit::base::ElementExt as _;
use gpui_kit::component::menu::{ContextMenuExt, PopupMenuItem};
use gpui_kit::component::tooltip::Tooltip;
#[derive(Clone)]
struct BotDrag(String);
impl Render for BotDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child("Move bot")
    }
}

/// The backdrop is an input barrier as well as a visual dimmer. In particular,
/// wheel events must not reach the conversation behind the sheet.
pub(super) fn bot_editor_backdrop(
    panel: Entity<bot_settings::BotSettingsPanel>,
    cx: &App,
) -> AnyElement {
    chat_layout::modal_backdrop()
        .id("bot-editor-overlay")
        .flex()
        .items_center()
        .justify_center()
        .p_4()
        .bg(rgba(0x00000090))
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .child(
            div()
                .id("bot-editor-dialog")
                .role(Role::Dialog)
                .aria_label("Bot editor")
                .w(px(560.))
                .h(px(720.))
                .max_w_full()
                .max_h_full()
                .overflow_hidden()
                .rounded(px(14.))
                .border_1()
                .border_color(cx.theme().border)
                .bg(cx.theme().background)
                .child(panel),
        )
        .into_any_element()
}

/// Sidebar previews are short snippets, so show Markdown's readable text
/// without changing the stored message or the text used by search. Snippets
/// may end in the middle of a link or emphasis after the cache truncates them.
fn preview_text(raw: &str) -> String {
    let raw = raw.trim();
    if !raw.contains(['*', '_', '`', '[', '!', '#', '>', '~', '\\']) {
        return raw.split_whitespace().collect::<Vec<_>>().join(" ");
    }
    let truncated = raw.ends_with('…');
    let mut source = raw.strip_suffix('…').unwrap_or(raw).to_owned();
    if truncated {
        if let Some(link) = source.rfind("](")
            && !source[link + 2..].contains(')')
            && source[..link].contains('[')
        {
            source.truncate(link + 2);
            source.push_str("#)");
        } else if source.rfind('[') > source.rfind(']') {
            source.push_str("](#)");
        }
        for marker in ["**", "__", "`"] {
            if source.matches(marker).count() % 2 == 1 {
                source.push_str(marker);
            }
        }
    }
    fn collect(node: &markdown::mdast::Node, output: &mut String) {
        use markdown::mdast::Node;
        match node {
            Node::Image(image) => output.push_str(&image.alt),
            Node::ImageReference(image) => output.push_str(&image.alt),
            Node::Break(_) => output.push(' '),
            Node::Html(_) => {}
            _ => {
                if let Some(children) = node.children() {
                    for (index, child) in children.iter().enumerate() {
                        if index > 0
                            && matches!(
                                node,
                                Node::Root(_) | Node::List(_) | Node::Table(_) | Node::TableRow(_)
                            )
                        {
                            output.push(' ');
                        }
                        collect(child, output);
                    }
                } else {
                    output.push_str(&node.to_string());
                }
            }
        }
    }
    let mut options = markdown::ParseOptions::gfm();
    options.constructs.math_text = false;
    let mut result = String::new();
    if let Ok(tree) = markdown::to_mdast(&source, &options) {
        collect(&tree, &mut result);
    }
    let result = result.split_whitespace().collect::<Vec<_>>().join(" ");
    if result.is_empty() {
        return raw.to_owned();
    }
    if truncated {
        format!("{result}…")
    } else {
        result
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
/// A compact label for the folder the user explicitly chose. Home is the
/// default and does not need a badge on every bot.
fn bot_folder_name(bot: &Value) -> Option<String> {
    let path = bot["folder"].as_str()?.trim();
    if path.is_empty() || path == "~" {
        return None;
    }
    let trimmed = path.trim_end_matches(['/', '\\']);
    if trimmed.is_empty() {
        return Some(path.to_owned());
    }
    trimmed.rsplit(['/', '\\']).next().map(str::to_owned)
}

fn folder_badge(bot: &Value, bot_name: &str) -> Option<String> {
    let folder = bot_folder_name(bot)?;
    // Many existing bots already include their folder in their chosen name.
    // Avoid repeating it while still keeping the actual folder in the tooltip.
    let repeated = bot_name
        .rsplit_once(" - ")
        .is_some_and(|(_, suffix)| suffix.trim().eq_ignore_ascii_case(&folder));
    (!repeated).then_some(folder)
}
/// This runs on a background executor, so waiting for the engine here keeps a
/// newly saved bot from failing to open during a concurrent settings refresh.
fn create_bot_conversation(engine: &SharedEngine, id: &str) -> Result<Value> {
    let saved = coincide_core::api::call(engine, "bots.read", json!({"botId":id}))?;
    coincide_core::api::call(
        engine,
        "bots.conversations.create",
        json!({"botId":id,"baseline":saved["baseline"]}),
    )
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
        if self.bot_editor_panel.is_some()
            || self.media.close_requested
            || self.media.shutdown_requested
        {
            return;
        }
        let engine = self.engine.clone();
        let bots = self.sidebar_bots.clone();
        let baseline = self.sidebar_bot_baseline.clone();
        let panel = cx.new(|cx| {
            bot_settings::BotSettingsPanel::new_sheet(engine, id, bots, baseline, window, cx)
        });
        let subscription = cx.subscribe_in(&panel, window, |this, _, event, window, cx| {
            match event {
                bot_settings::BotSettingsEvent::Saved {
                    bot_id,
                    bot,
                    baseline,
                    created,
                    close_editor,
                } => {
                    this.remember_saved_bot(bot.clone(), baseline.clone());
                    this.bot_panel
                        .update(cx, |panel, cx| panel.refresh_list(cx));
                    if *close_editor {
                        this.bot_editor_panel = None;
                        this.bot_editor_subscription = None;
                        // Swift opens the new bot's first empty conversation.
                        if *created {
                            this.sidebar_open_bot(bot_id.clone(), false, window, cx);
                        }
                    }
                }
                bot_settings::BotSettingsEvent::Closed => {
                    this.bot_editor_panel = None;
                    this.bot_editor_subscription = None;
                }
                bot_settings::BotSettingsEvent::ConversationCreated { .. } => {}
            }
            cx.notify();
        });
        self.bot_editor_panel = Some(panel);
        self.bot_editor_subscription = Some(subscription);
        cx.notify();
    }
    pub(super) fn remember_saved_bot(&mut self, bot: Value, baseline: String) {
        let id = text(&bot, "id");
        if let Some(saved) = self.sidebar_bots.iter_mut().find(|saved| {
            saved["id"]
                .as_str()
                .is_some_and(|stored| stored.eq_ignore_ascii_case(&id))
        }) {
            *saved = bot;
        } else {
            self.sidebar_bots.push(bot);
        }
        self.sidebar_bot_baseline = baseline;
    }
    pub(super) fn bot_editor_overlay(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let panel = self.bot_editor_panel.as_ref()?;
        Some(bot_editor_backdrop(panel.clone(), cx))
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
                    && !self.attachment_imports.contains(&target)
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
                self.navigate_to_thread(&target, window, cx);
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
        let create = cx
            .background_executor()
            .spawn(async move { create_bot_conversation(&engine, &id) });
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
            || bot_folder_name(bot).is_some_and(|folder| {
                sidebar_search::terms_match(&folder, &self.search.read(cx).value())
            })
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
            let anchor_bounds = self.sidebar_row_bounds.clone();
            let anchor_key = format!("bot:{id}");
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
            let folder = folder_badge(bot, &name);
            let preview = latest
                .and_then(|thread| thread.navigation.as_ref()?.preview.clone())
                .map(|preview| preview_text(&preview))
                .filter(|preview| !preview.is_empty())
                .unwrap_or_else(|| "Say hello".into());
            use sidebar_thread_status::RowStatus;
            let activity = sidebar_thread_status::strongest_status(
                conversations
                    .iter()
                    .map(|thread| self.sidebar_thread_status(thread)),
            )
            .unwrap_or(RowStatus::Idle);
            let running = matches!(activity, RowStatus::Running { .. });
            let approval = matches!(activity, RowStatus::Approval(_));
            let failed = activity == RowStatus::Failed;
            let completed = activity == RowStatus::Completed;
            let unseen = activity.unseen().then_some("unseen");
            let status = activity.label();
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
            let age = if let RowStatus::Running { since } = activity {
                sidebar_thread_status::elapsed(coincide_core::store::swift_timestamp() - since)
            } else {
                navigation::sidebar_age(
                    latest.and_then(|thread| thread.navigation.as_ref()?.updated_at),
                    coincide_core::store::swift_timestamp(),
                )
            };
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
            let folder_accessibility =
                bot_folder_name(bot).map(|folder| format!("Folder: {folder}"));
            let accessibility = [
                Some(name.as_str()),
                folder_accessibility.as_deref(),
                status,
                Some(preview.as_str()),
            ]
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
                    .on_prepaint(move |bounds, _, _| {
                        if let Ok(mut rows) = anchor_bounds.lock() {
                            rows.insert(anchor_key, bounds);
                        }
                    })
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
                                    .child(bot_avatar::avatar_for(&bot["avatar"], 26.))
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
                                                            .flex()
                                                            .items_center()
                                                            .gap_1()
                                                            .flex_1()
                                                            .min_w_0()
                                                            .child(div()
                                                                .min_w_0()
                                                                .truncate()
                                                                .text_size(px(13.))
                                                                .font_weight(if unseen.is_some() {
                                                                    FontWeight::SEMIBOLD
                                                                } else {
                                                                    FontWeight::MEDIUM
                                                                })
                                                                .child(name))
                                                            .when_some(folder, |row, folder| row.child(
                                                                div()
                                                                    .flex()
                                                                    .items_center()
                                                                    .gap(px(3.))
                                                                    .min_w_0()
                                                                    .max_w(px(105.))
                                                                    .text_color(ink.opacity(0.58))
                                                                    .child(Icon::new(IconName::Folder).size(px(11.)))
                                                                    .child(div().min_w_0().truncate().text_size(px(11.)).child(folder))
                                                            )),
                                                    )
                                                    .child(
                                                        div()
                                                            .flex()
                                                            .flex_shrink_0()
                                                            .items_center()
                                                            .gap_1()
                                                            .when(running, |row| row.child(gpui_kit::component::spinner::Spinner::new().xsmall()))
                                                            .when(approval, |row| row.child(div().px(px(5.)).rounded_full().bg(theme.warning.opacity(0.18)).text_size(px(10.)).font_weight(FontWeight::SEMIBOLD).text_color(theme.warning).child("Approval")))
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
                                                            .when(!failed && !approval, |row| {
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
                                            .child(
                                                div()
                                                    .truncate()
                                                    .text_size(px(11.5))
                                                    .text_color(ink.opacity(0.62))
                                                    .child(preview.clone()),
                                            ),
                                    )
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
                                                            this.navigate_to_thread(&thread, window, cx)
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
                                    PopupMenuItem::new("Delete Bot…").on_click(move |event, window, cx| {
                                        let _ = parent_delete.update(cx, |this, cx| {
                                            this.sidebar_bot_delete_review(id.clone(), window, cx);
                                            this.anchor_sidebar_review_to_click(event, cx);
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
    fn creating_a_bot_conversation_waits_for_a_busy_engine_without_sending() {
        use std::{
            sync::{Arc, Mutex, mpsc},
            time::Duration,
        };
        let root = std::env::temp_dir().join(format!("coincide-bot-open-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let folder = root.join("workspace");
        std::fs::create_dir(&folder).unwrap();
        let engine: SharedEngine = Arc::new(Mutex::new(Engine::new(
            Store::open(&root.join("state.sqlite")).unwrap(),
        )));
        let list = coincide_core::api::call(&engine, "bots.list", json!({})).unwrap();
        let bot = coincide_core::api::call(
            &engine,
            "bots.save",
            json!({"baseline":list["baseline"],"patch":{"name":"Fixture bot","folder":folder}}),
        )
        .unwrap();
        let id = text(&bot["bot"], "id");
        let held = engine.lock().unwrap();
        let worker_engine = engine.clone();
        let (started_tx, started_rx) = mpsc::channel();
        let (result_tx, result_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            result_tx
                .send(create_bot_conversation(&worker_engine, &id))
                .unwrap();
        });
        started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(matches!(
            result_rx.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        drop(held);
        let created = result_rx
            .recv_timeout(Duration::from_secs(5))
            .unwrap()
            .unwrap();
        assert_eq!(created["created"], true);
        assert_eq!(created["executionStarted"], false);
        worker.join().unwrap();
        drop(engine);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[::core::prelude::v1::test]
    fn preview_shows_readable_markdown_even_when_the_cached_snippet_is_truncated() {
        assert_eq!(
            preview_text("Quick read: **a substantial native app…"),
            "Quick read: a substantial native app…"
        );
        assert_eq!(
            preview_text("Stopped. Pushed in [PR #61…"),
            "Stopped. Pushed in PR #61…"
        );
        assert_eq!(
            preview_text("See [PR #61](https://example.test/pull/61) and `cargo test`."),
            "See PR #61 and cargo test."
        );
        assert_eq!(
            preview_text("Show ![diagram](diagram.png) now"),
            "Show diagram now"
        );
        assert_eq!(
            preview_text("Use foo_bar and 2 * 3."),
            "Use foo_bar and 2 * 3."
        );
        assert_eq!(
            preview_text("Keep \\*literal\\* markers"),
            "Keep *literal* markers"
        );
    }
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
    fn sidebar_folder_labels_follow_the_saved_folder_without_repeating_the_name() {
        assert_eq!(bot_folder_name(&json!({})), None);
        assert_eq!(bot_folder_name(&json!({"folder":"~"})), None);
        assert_eq!(
            bot_folder_name(&json!({"folder":"/Users/test/My Project/"})).as_deref(),
            Some("My Project")
        );
        assert_eq!(
            bot_folder_name(&json!({"folder":"C:\\work\\app\\"})).as_deref(),
            Some("app")
        );
        let bot = json!({"folder":"/work/Verceltics"});
        assert_eq!(
            folder_badge(&bot, "Croissant").as_deref(),
            Some("Verceltics")
        );
        assert_eq!(folder_badge(&bot, "Croissant - verceltics"), None);
        assert_eq!(
            folder_badge(&bot, "Verceltics helper").as_deref(),
            Some("Verceltics")
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
