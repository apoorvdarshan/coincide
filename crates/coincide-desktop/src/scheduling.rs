//! Native schedule editing uses the same validator and recurrence calculations
//! as the API. Saving a draft never grants execution approval.
use super::*;
use coincide_core::scheduling::{
    Recurrence, format_local_datetime, parse_date, parse_local_datetime,
};
use gpui_kit::{
    assets::IconName as Symbol,
    component::{
        checkbox::Checkbox,
        input::{Enter, Escape},
        menu::{ContextMenuExt, DropdownMenu, PopupMenuItem},
        tooltip::Tooltip,
    },
};

#[path = "scheduling_list.rs"]
mod list;
use list::{
    Owner, ScheduleFilter, Tone, same_schedule_target, schedule_guard_snapshot, schedule_visible,
};

/// Swift ScheduledTaskEditor's Repeat menu, in its order and words.
const KINDS: &[(&str, &str)] = &[
    ("once", "Once"),
    ("daily", "Daily"),
    ("weekdays", "Weekdays"),
    ("weekly", "Weekly"),
    ("days", "On Selected Days"),
    ("interval", "Every…"),
    ("cron", "Custom (cron)"),
];
/// Every…'s units, in minutes.
const UNITS: [(u64, &str); 3] = [(1, "Minutes"), (60, "Hours"), (1440, "Days")];
/// What a schedule row's hover buttons, click and context menu do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RowAction {
    Open,
    TogglePause,
    RunNow,
    Edit,
    Delete,
}
const DAYS: &[(u32, &str)] = &[
    (2, "Mon"),
    (3, "Tue"),
    (4, "Wed"),
    (5, "Thu"),
    (6, "Fri"),
    (7, "Sat"),
    (1, "Sun"),
];

pub(super) struct ScheduleEditor {
    pub open: bool,
    pub thread_id: String,
    pub(super) all_conversations: bool,
    scope_epoch: u64,
    filter: Entity<InputState>,
    editing_global: bool,
    baseline_target: Value,
    target_label: String,
    project_id: Value,
    editing_id: Option<String>,
    baseline_revision: Value,
    baseline_recurrence: Value,
    original_date: String,
    original_time: String,
    kind: String,
    weekday: u32,
    days: Vec<u32>,
    /// Index into UNITS for Every….
    interval_unit: usize,
    /// The editor's Paused checkbox, and the schedule's state when it opened.
    paused: bool,
    baseline_paused: bool,
    /// What the panel lists, and whether the saved choice has been read.
    view_filter: ScheduleFilter,
    filter_loaded: bool,
    /// The row under the pointer shows its actions in place of its badge.
    hovered: Option<String>,
    /// The minute the rows last said "Next: …" for (Swift's 60 s timer).
    rendered_minute: i64,
    name: Entity<InputState>,
    prompt: Entity<TextareaState>,
    date: Entity<InputState>,
    time: Entity<InputState>,
    zone: Entity<InputState>,
    interval: Entity<InputState>,
    cron: Entity<InputState>,
    preview: String,
    // Validate/preview after timing changes or a minute passes; ordinary 150ms
    // UI polls must not repeat a potentially multi-year cron search.
    preview_key: Option<Value>,
    /// The open Delete confirmation; a second Delete waits for its answer.
    delete_prompt: Option<Task<()>>,
}
impl ScheduleEditor {
    pub fn subscriptions(&self, cx: &mut Context<Coincide>) -> Vec<Subscription> {
        let mut subscriptions: Vec<_> = [
            &self.name,
            &self.date,
            &self.time,
            &self.zone,
            &self.interval,
            &self.cron,
        ]
        .into_iter()
        .map(|input| {
            cx.subscribe(input, |_, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            })
        })
        .collect();
        subscriptions.push(cx.subscribe(&self.prompt, |_, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        }));
        subscriptions.push(cx.subscribe(&self.filter, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.schedule_editor.scope_epoch = this.schedule_editor.scope_epoch.wrapping_add(1);
                cx.notify();
            }
        }));
        subscriptions
    }
    pub fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            open: false,
            thread_id: String::new(),
            all_conversations: false,
            scope_epoch: 0,
            filter: cx.new(|cx| InputState::new(window, cx).placeholder("Search schedules")),
            editing_global: false,
            baseline_target: Value::Null,
            target_label: String::new(),
            project_id: Value::Null,
            editing_id: None,
            baseline_revision: Value::Null,
            baseline_recurrence: json!({}),
            original_date: String::new(),
            original_time: String::new(),
            kind: "daily".into(),
            weekday: 2,
            days: vec![2, 3, 4, 5, 6],
            interval_unit: 0,
            paused: false,
            baseline_paused: false,
            view_filter: ScheduleFilter::All,
            filter_loaded: false,
            hovered: None,
            rendered_minute: 0,
            name: cx.new(|cx| InputState::new(window, cx).placeholder("Schedule name")),
            prompt: cx.new(|cx| {
                TextareaState::new(window, cx)
                    .placeholder("Message to send to this conversation")
                    .submit_on_enter(false)
            }),
            date: cx.new(|cx| InputState::new(window, cx).placeholder("YYYY-MM-DD")),
            time: cx.new(|cx| InputState::new(window, cx).placeholder("HH:MM")),
            zone: cx.new(|cx| {
                InputState::new(window, cx).placeholder("IANA time zone, e.g. Asia/Kolkata")
            }),
            interval: cx.new(|cx| InputState::new(window, cx).placeholder("30")),
            cron: cx.new(|cx| InputState::new(window, cx).placeholder("0 9 * * 1-5")),
            preview: String::new(),
            delete_prompt: None,
            preview_key: None,
        }
    }
    fn recurrence(&self, cx: &App) -> Result<Value> {
        let zone = self.zone.read(cx).value().trim().to_owned();
        let time = self.time.read(cx).value().trim().to_owned();
        let (hour, minute) =
            if matches!(self.kind.as_str(), "daily" | "weekly" | "weekdays" | "days") {
                let (hour, minute) = time
                    .split_once(':')
                    .ok_or_else(|| anyhow::anyhow!("Enter a 24-hour time as HH:MM"))?;
                (hour.parse::<u32>()?, minute.parse::<u32>()?)
            } else {
                (0, 0)
            };
        let mut value = self.baseline_recurrence.clone();
        if !value.is_object() {
            value = json!({});
        }
        value["kind"] = json!(self.kind);
        value["timeZoneID"] = json!(zone);
        if matches!(self.kind.as_str(), "daily" | "weekly" | "weekdays" | "days") {
            value["hour"] = json!(hour);
            value["minute"] = json!(minute);
        }
        value["weekday"] = json!(self.weekday);
        if self.kind == "days" {
            value["weekdays"] = json!(self.days);
        }
        if self.kind == "interval" {
            let count = self
                .interval
                .read(cx)
                .value()
                .trim()
                .parse::<u64>()
                .map_err(|_| anyhow::anyhow!("Enter a whole number for the interval"))?;
            value["intervalMinutes"] = json!(count.saturating_mul(UNITS[self.interval_unit].0));
        }
        if self.kind == "cron" {
            value["cron"] = json!(self.cron.read(cx).value().trim());
        }
        if matches!(self.kind.as_str(), "once" | "interval") {
            let date = self.date.read(cx).value().trim().to_owned();
            // Keep exact seconds and the imported representation for unchanged
            // dates. Editing only the title must not silently move an occurrence.
            if date != self.original_date
                || time != self.original_time
                || value["timeZoneID"] != self.baseline_recurrence["timeZoneID"]
                || value["kind"] != self.baseline_recurrence["kind"]
            {
                value["date"] = json!(parse_local_datetime(&date, &time, &zone)?.to_rfc3339());
            }
        }
        if value["date"].is_null() {
            value["date"] = json!(coincide_core::store::swift_timestamp());
        }
        let recurrence: Recurrence = serde_json::from_value(value.clone())?;
        recurrence.validate()?;
        Ok(value)
    }
    fn form_key(&self, cx: &App) -> Value {
        json!([
            (coincide_core::store::swift_timestamp() / 60.).floor(),
            self.kind,
            self.weekday,
            self.days,
            self.date.read(cx).value().as_ref(),
            self.time.read(cx).value().as_ref(),
            self.zone.read(cx).value().as_ref(),
            self.interval.read(cx).value().as_ref(),
            self.interval_unit,
            self.cron.read(cx).value().as_ref()
        ])
    }
    fn update_preview(&mut self, cx: &App) {
        let key = self.form_key(cx);
        if self.preview_key.as_ref() == Some(&key) {
            return;
        }
        self.preview_key = Some(key);
        // Swift's preview: "Every day at 09:00. Next: a, b and c".
        let result = (|| -> Result<String> {
            let value = self.recurrence(cx)?;
            let recurrence: Recurrence = serde_json::from_value(value.clone())?;
            let now = parse_date(&json!(coincide_core::store::swift_timestamp()))?;
            let local = coincide_core::scheduling::local_time_zone();
            let mut after = now;
            let mut dates = Vec::new();
            for _ in 0..3 {
                let Some(next) = recurrence.next_after(after)? else {
                    break;
                };
                dates.push(list::full_time(next, &recurrence.time_zone_id, &local, now));
                after = next;
            }
            anyhow::ensure!(!dates.is_empty(), "No future runs. Choose a later time.");
            let dates = dates.iter().map(String::as_str).collect::<Vec<_>>();
            Ok(format!(
                "{}. Next: {}",
                list::summary(&value),
                list::list(&dates)
            ))
        })();
        self.preview = result.unwrap_or_else(|error| error.to_string());
    }
}

impl Coincide {
    pub(super) fn refresh_schedules(&mut self, cx: &mut Context<Self>) {
        let params = if self.schedule_editor.all_conversations {
            json!({})
        } else if let Some(thread) = self.selected.as_ref() {
            json!({"threadId":thread["id"]})
        } else {
            self.schedules.clear();
            return;
        };
        match call(&self.engine, "schedules.list", params) {
            Ok(result) => {
                self.schedules = result["tasks"].as_array().cloned().unwrap_or_default();
                if let Some(error) = result["error"].as_str() {
                    self.schedule_status = format!("Scheduler: {error}");
                }
            }
            Err(error) if engine_busy(&error) => return,
            Err(error) => {
                self.schedules.clear();
                self.schedule_status = format!("Unable to load schedules: {error}");
            }
        }
        cx.notify();
    }
    pub(super) fn close_schedule_surface(&mut self) {
        self.schedules_open = false;
        self.schedule_editor.open = false;
        self.schedule_editor.scope_epoch = self.schedule_editor.scope_epoch.wrapping_add(1);
    }
    pub(super) fn rebind_conversation_schedule_editor(&mut self, id: &str) {
        if !self.schedule_editor.all_conversations && self.schedule_editor.thread_id != id {
            self.schedule_editor.open = false;
            self.schedule_editor.scope_epoch = self.schedule_editor.scope_epoch.wrapping_add(1);
        }
    }
    pub(super) fn open_global_schedules(&mut self, cx: &mut Context<Self>) {
        self.clear_inspector_placeholders();
        self.schedule_editor.all_conversations = true;
        self.schedule_editor.scope_epoch = self.schedule_editor.scope_epoch.wrapping_add(1);
        self.schedule_editor.open = false;
        self.schedules_open = true;
        self.refresh_schedules(cx);
        self.prepare_schedule_filter();
    }
    pub(super) fn open_conversation_schedules(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.clear_inspector_placeholders();
        self.workspace_open = false;
        self.ensure_inspector_space(window);
        self.schedule_editor.all_conversations = false;
        self.schedule_editor.scope_epoch = self.schedule_editor.scope_epoch.wrapping_add(1);
        self.schedule_editor.open = false;
        self.schedules_open = true;
        self.hide_selected_browser_surface(cx);
        if self.terminal_on_right() {
            self.terminal_open = false;
        }
        self.refresh_schedules(cx);
        self.prepare_schedule_filter();
    }
    fn schedule_action(
        &mut self,
        id: &str,
        action: &str,
        expected: &Value,
        scope_epoch: u64,
        cx: &mut Context<Self>,
    ) {
        let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
        let query = self.schedule_editor.filter.read(cx).value().to_string();
        if scope_epoch != self.schedule_editor.scope_epoch
            || !self.schedules.iter().any(|task| {
                task["id"] == id
                    && same_schedule_target(task, expected)
                    && schedule_visible(
                        task,
                        self.schedule_editor.all_conversations,
                        selected.as_deref(),
                        &query,
                        &self.schedule_place(task),
                    )
            })
        {
            self.schedule_status =
                "Schedule view changed. Reopen the schedule before acting.".into();
            cx.notify();
            return;
        }
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            check_schedule_revision(
                &mut engine,
                id,
                &expected["rustRevision"],
                &expected["threadID"],
                &expected["projectID"],
            )?;
            if action == "approve" {
                return engine.approve_schedule(id);
            }
            let response = engine.dispatch(json!({"method":action,"params":{"scheduleId":id}}));
            if let Some(error) = response.get("error") {
                anyhow::bail!(
                    "{}",
                    error["message"]
                        .as_str()
                        .unwrap_or("Schedule action failed")
                );
            }
            Ok(response["result"].clone())
        })();
        let succeeded = result.is_ok();
        self.schedule_status=match result {
            Ok(_)=>match action {
                "approve"=>"Approved for execution in Coincide Rust.",
                "schedules.pause"=>"Schedule paused.",
                "schedules.resume"=>"Schedule resumed; approval is still required if shown.",
                "schedules.delete"=>"Schedule deleted.",
                "schedules.run-now"=>"Run requested. A busy conversation defers delivery until its current turn ends.",
                _=>"Schedule updated.",
            }.into(),
            Err(error)=>format!("Schedule action failed: {error}"),
        };
        if succeeded
            && action == "schedules.delete"
            && self.schedule_editor.editing_id.as_deref() == Some(id)
        {
            self.schedule_editor.open = false;
        }
        self.refresh_schedules(cx);
    }
    /// Swift's ScheduleActions.confirmDelete: nothing is deleted until the
    /// user picks Delete, and the guard snapshot is checked again then.
    fn confirm_schedule_delete(
        &mut self,
        id: String,
        expected: Value,
        scope_epoch: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .schedule_editor
            .delete_prompt
            .as_ref()
            .is_some_and(|task| !task.is_ready())
        {
            return;
        }
        let Some(task) = self.schedules.iter().find(|task| task["id"] == id) else {
            self.schedule_status = "Schedule no longer exists. Refresh and try again.".into();
            cx.notify();
            return;
        };
        let (message, detail) =
            delete_confirmation(&text(task, "name"), task["threadID"].is_string());
        let answer = window.prompt(
            PromptLevel::Warning,
            &message,
            Some(detail),
            &["Delete", "Cancel"],
            cx,
        );
        self.schedule_editor.delete_prompt = Some(cx.spawn_in(window, async move |this, cx| {
            if answer.await.unwrap_or(1) != 0 {
                return;
            }
            this.update(cx, |this, cx| {
                this.schedule_action(&id, "schedules.delete", &expected, scope_epoch, cx)
            })
            .ok();
        }));
    }
    pub(super) fn open_schedule_editor(
        &mut self,
        id: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.selected.is_none() && (id.is_none() || !self.schedule_editor.all_conversations) {
            self.schedule_status = "Choose a conversation before creating a schedule.".into();
            cx.notify();
            return;
        }
        let existing = match id {
            Some(id) => match self.schedules.iter().find(|task| {
                task["id"] == id
                    && schedule_visible(
                        task,
                        self.schedule_editor.all_conversations,
                        self.selected.as_ref().and_then(|t| t["id"].as_str()),
                        &self.schedule_editor.filter.read(cx).value(),
                        &self.schedule_place(task),
                    )
            }) {
                Some(task) => Some(task.clone()),
                None => {
                    self.schedule_status =
                        "Schedule no longer exists. Refresh and try again.".into();
                    cx.notify();
                    return;
                }
            },
            None => None,
        };
        let proposed = existing.as_ref().map(|task| {
            task.get("proposal")
                .filter(|p| p.is_object())
                .unwrap_or(task)
        });
        // Swift TaskRecurrence's default: daily at 9:00 in the host's zone.
        let recurrence=proposed.map(|task|task["recurrence"].clone()).unwrap_or_else(||json!({
            "kind":"daily","timeZoneID":coincide_core::scheduling::local_time_zone(),"date":coincide_core::store::swift_timestamp()+3600.,
            "hour":9,"minute":0,"weekday":2,"weekdays":null,"intervalMinutes":30,"cron":"0 9 * * 1-5"
        }));
        let zone = recurrence["timeZoneID"]
            .as_str()
            .unwrap_or("UTC")
            .to_owned();
        let (date, mut time) = match format_local_datetime(&recurrence["date"], &zone) {
            Ok(formatted) => formatted,
            Err(error) => {
                self.schedule_status = format!("Schedule could not be opened: {error}");
                cx.notify();
                return;
            }
        };
        let kind = text(&recurrence, "kind");
        if !matches!(kind.as_str(), "once" | "interval") {
            time = format!(
                "{:02}:{:02}",
                recurrence["hour"].as_u64().unwrap_or(9),
                recurrence["minute"].as_u64().unwrap_or(0)
            );
        }
        let editor = &mut self.schedule_editor;
        editor.editing_global = editor.all_conversations;
        editor.baseline_target = existing
            .as_ref()
            .map(|task| task["threadID"].clone())
            .unwrap_or_else(|| self.selected.as_ref().unwrap()["id"].clone());
        editor.thread_id = editor
            .baseline_target
            .as_str()
            .unwrap_or_default()
            .to_owned();
        editor.project_id = existing
            .as_ref()
            .map(|task| task["projectID"].clone())
            .unwrap_or_else(|| self.selected.as_ref().unwrap()["projectID"].clone());
        editor.target_label = if editor.thread_id.is_empty() {
            "New conversation per run".into()
        } else {
            self.threads
                .iter()
                .find(|t| t.id == editor.thread_id)
                .map(|t| t.title.clone())
                .filter(|title| !title.is_empty())
                .unwrap_or_else(|| "Saved conversation".into())
        };
        editor.editing_id = id.map(str::to_owned);
        editor.baseline_revision = existing
            .as_ref()
            .map(|task| task["rustRevision"].clone())
            .unwrap_or(Value::Null);
        editor.kind = kind;
        editor.weekday = recurrence["weekday"].as_u64().unwrap_or(2) as u32;
        editor.days = recurrence["weekdays"]
            .as_array()
            .map(|days| {
                days.iter()
                    .filter_map(|d| d.as_u64().map(|d| d as u32))
                    .collect()
            })
            .unwrap_or_else(|| vec![2, 3, 4, 5, 6]);
        editor.original_date = date.clone();
        editor.original_time = time.clone();
        // Every… shows the largest unit the interval is a whole number of.
        let minutes = recurrence["intervalMinutes"].as_u64().unwrap_or(30).max(1);
        editor.interval_unit = UNITS
            .iter()
            .rposition(|(unit, _)| minutes % unit == 0)
            .unwrap_or(0);
        let interval = minutes / UNITS[editor.interval_unit].0;
        editor.paused = existing
            .as_ref()
            .is_some_and(|task| task["isPaused"] == true);
        editor.baseline_paused = editor.paused;
        editor.name.update(cx, |input, cx| {
            input.set_value(
                proposed.map(|p| text(p, "name")).unwrap_or_default(),
                window,
                cx,
            )
        });
        editor.prompt.update(cx, |input, cx| {
            input.set_value(
                proposed.map(|p| text(p, "prompt")).unwrap_or_default(),
                window,
                cx,
            )
        });
        editor
            .date
            .update(cx, |input, cx| input.set_value(date, window, cx));
        editor
            .time
            .update(cx, |input, cx| input.set_value(time, window, cx));
        editor
            .zone
            .update(cx, |input, cx| input.set_value(zone, window, cx));
        editor.interval.update(cx, |input, cx| {
            input.set_value(interval.to_string(), window, cx)
        });
        editor.cron.update(cx, |input, cx| {
            input.set_value(
                recurrence["cron"]
                    .as_str()
                    .unwrap_or("0 9 * * 1-5")
                    .to_owned(),
                window,
                cx,
            )
        });
        editor.baseline_recurrence = recurrence;
        editor.preview_key = None;
        editor.open = true;
        self.schedule_status.clear();
        cx.notify();
    }
    fn save_schedule(&mut self, cx: &mut Context<Self>) {
        let editor = &self.schedule_editor;
        let outcome = (|| -> Result<Value> {
            anyhow::ensure!(
                editor.open
                    && editor.editing_global == editor.all_conversations
                    && (editor.editing_global
                        || self
                            .selected
                            .as_ref()
                            .is_some_and(|v| v["id"] == editor.thread_id)),
                "Conversation changed. Reopen the schedule editor."
            );
            let name = editor.name.read(cx).value().trim().to_owned();
            let prompt = editor.prompt.read(cx).value().to_string();
            anyhow::ensure!(
                !name.is_empty() && name.len() <= 1024,
                "Enter a schedule name up to 1,024 bytes."
            );
            anyhow::ensure!(
                !prompt.trim().is_empty() && prompt.len() <= 1_048_576,
                "Enter a nonempty prompt up to 1 MiB."
            );
            let recurrence = editor.recurrence(cx)?;
            if let Some(id) = &editor.editing_id {
                let mut engine = try_state(&self.engine)?;
                check_schedule_revision(
                    &mut engine,
                    id,
                    &editor.baseline_revision,
                    &editor.baseline_target,
                    &editor.project_id,
                )?;
                let response = engine.dispatch(json!({"method":"schedules.patch", "params":{
                    "scheduleId":id,"patch":{"name":name,"prompt":prompt,"recurrence":recurrence}
                }}));
                if let Some(error) = response.get("error") {
                    anyhow::bail!(
                        "{}",
                        error["message"]
                            .as_str()
                            .unwrap_or("Schedule could not be saved")
                    );
                }
                Ok(response["result"].clone())
            } else {
                call(
                    &self.engine,
                    "schedules.create",
                    json!({"task":{"name":name,"prompt":prompt,"projectID":editor.project_id,"threadID":editor.thread_id,"recurrence":recurrence}}),
                )
            }
        })();
        match outcome {
            Ok(saved) => {
                self.schedule_editor.open = false;
                self.schedule_status="Saved for review. Execution requires a separate approval below; any previous approval was revoked.".into();
                // The editor's Paused checkbox, applied to what was just saved.
                let id = self
                    .schedule_editor
                    .editing_id
                    .clone()
                    .or_else(|| saved["task"]["id"].as_str().map(str::to_owned));
                let paused = self.schedule_editor.paused;
                if let Some(id) = id
                    && (saved["task"]["isPaused"] == true) != paused
                    && (paused || self.schedule_editor.baseline_paused)
                {
                    let method = if paused {
                        "schedules.pause"
                    } else {
                        "schedules.resume"
                    };
                    if let Err(error) = call(&self.engine, method, json!({"scheduleId":id})) {
                        self.schedule_status = format!(
                            "Schedule saved, but it couldn’t be {}: {error}",
                            if paused { "paused" } else { "resumed" }
                        );
                    }
                }
            }
            Err(error) => self.schedule_status = format!("Schedule was not saved: {error}"),
        }
        self.refresh_schedules(cx);
    }
    /// Swift's ⌘Return and Esc in the editor.
    fn schedule_editor_keys(&self, form: Div, cx: &mut Context<Self>) -> Div {
        form.capture_action(cx.listener(|this, action: &Enter, window, cx| {
            if action.secondary && this.schedule_editor.open {
                window.prevent_default();
                cx.stop_propagation();
                this.save_schedule(cx);
            }
        }))
        .capture_action(cx.listener(|this, _: &Escape, _, cx| {
            if this.schedule_editor.open {
                cx.stop_propagation();
                this.schedule_editor.open = false;
                cx.notify();
            }
        }))
    }
    fn schedule_editor_pane(&self, cx: &mut Context<Self>) -> AnyElement {
        let editor = &self.schedule_editor;
        let kind = editor.kind.as_str();
        let mut form = div()
            .flex()
            .flex_col()
            .flex_shrink_0()
            .gap_2()
            .p_3()
            .rounded_md()
            .bg(self.color(0x202a3b))
            .child(div().font_semibold().child(if editor.editing_id.is_some() {
                "Edit schedule for review"
            } else {
                "Create schedule for review"
            }))
            .child(
                div()
                    .text_sm()
                    .child(format!("Conversation: {}", editor.target_label)),
            )
            .child(div().text_sm().child("Name"))
            .child(Input::new(&editor.name))
            .child(div().text_sm().child("Message"))
            .child(Textarea::new(&editor.prompt).h(px(90.)))
            .child(div().flex().flex_wrap().gap_2().children(KINDS.iter().map(
                |&(value, label)| {
                    Button::new(SharedString::from(format!("schedule-kind-{value}")))
                        .label(label)
                        .when(kind == value, |b| b.primary())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.schedule_editor.kind = value.into();
                            cx.notify();
                        }))
                },
            )))
            .child(div().text_sm().child("Time zone (IANA name)"))
            .child(Input::new(&editor.zone));
        if matches!(kind, "once" | "interval") {
            form = form
                .child(div().text_sm().child(if kind == "once" {
                    "Run at (local date and 24-hour time)"
                } else {
                    "First run (local date and 24-hour time)"
                }))
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(Input::new(&editor.date))
                        .child(Input::new(&editor.time)),
                );
        } else if kind != "cron" {
            form = form
                .child(div().text_sm().child("Local time (HH:MM, 24-hour)"))
                .child(Input::new(&editor.time));
        }
        if kind == "interval" {
            let unit = editor.interval_unit;
            form = form.child(div().text_sm().child("Every")).child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().w(px(90.)).child(Input::new(&editor.interval)))
                    .children(UNITS.iter().enumerate().map(|(index, (_, label))| {
                        Button::new(SharedString::from(format!("schedule-unit-{index}")))
                            .label(*label)
                            .small()
                            .when(unit == index, |b| b.primary())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.schedule_editor.interval_unit = index;
                                cx.notify();
                            }))
                    })),
            );
        }
        if matches!(kind, "weekly" | "days") {
            form = form
                .child(div().text_sm().child(if kind == "weekly" {
                    "Choose one weekday"
                } else {
                    "Choose one or more weekdays"
                }))
                .child(div().flex().flex_wrap().gap_2().children(DAYS.iter().map(
                    |&(day, label)| {
                        let selected = if kind == "weekly" {
                            editor.weekday == day
                        } else {
                            editor.days.contains(&day)
                        };
                        Button::new(SharedString::from(format!("schedule-weekday-{day}")))
                            .label(label)
                            .when(selected, |b| b.primary())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if this.schedule_editor.kind == "weekly" {
                                    this.schedule_editor.weekday = day;
                                } else if this.schedule_editor.days.contains(&day) {
                                    this.schedule_editor.days.retain(|value| *value != day);
                                } else {
                                    this.schedule_editor.days.push(day);
                                    this.schedule_editor.days.sort_unstable();
                                }
                                cx.notify();
                            }))
                    },
                )));
        }
        if kind == "cron" {
            form=form.child(div().text_sm().child("Cron: minute hour day-of-month month day-of-week" )).child(Input::new(&editor.cron))
            .child(div().text_sm().child("Example: 0 9 * * 1-5 runs at 09:00 on weekdays. Runs must be at least five minutes apart."));
        }
        let paused = editor.paused;
        let form = form.child(
            Checkbox::new("schedule-paused")
                .label("Paused")
                .checked(paused)
                .on_click(cx.listener(|this, checked: &bool, _, cx| {
                    this.schedule_editor.paused = *checked;
                    cx.notify();
                })),
        );
        self.schedule_editor_keys(form, cx)
            .child(div().text_sm().child(editor.preview.clone()))
            .child(div().text_sm().child("Busy conversations wait for their current turn. Saving edits requires renewed approval; it does not interrupt an already running turn."))
            .child(div().flex().gap_2()
                .child(Button::new("schedule-save").label("Save for review").primary().on_click(cx.listener(|this,_,_,cx|this.save_schedule(cx))))
                .child(Button::new("schedule-cancel").label("Cancel").on_click(cx.listener(|this,_,_,cx|{this.schedule_editor.open=false;cx.notify();}))))
            .into_any_element()
    }

    /// The bot a thread belongs to, when the sidebar knows that bot.
    fn schedule_bot_of(&self, thread: &str) -> Option<String> {
        let bot = self
            .sidebar_all_threads
            .iter()
            .chain(&self.threads)
            .find(|summary| summary.id.eq_ignore_ascii_case(thread))?
            .navigation
            .as_ref()?
            .bot_id
            .clone()?;
        self.sidebar_bots
            .iter()
            .any(|known| {
                known["id"]
                    .as_str()
                    .is_some_and(|id| id.eq_ignore_ascii_case(&bot))
            })
            .then_some(bot)
    }
    fn schedule_thread_title(&self, thread: &str) -> Option<String> {
        self.sidebar_all_threads
            .iter()
            .chain(&self.threads)
            .find(|summary| summary.id.eq_ignore_ascii_case(thread))
            .map(|summary| summary.title.clone())
            .filter(|title| !title.is_empty())
    }
    fn schedule_project_name(&self, project: &str) -> Option<String> {
        self.projects
            .iter()
            .find(|known| {
                known["id"]
                    .as_str()
                    .is_some_and(|id| id.eq_ignore_ascii_case(project))
            })
            .map(|known| text(known, "name"))
            .filter(|name| !name.is_empty())
    }
    /// A group's heading: the bot, the thread and its project, or the project
    /// whose new threads the runs start (Swift SchedulesPanelController.title).
    fn schedule_group_title(&self, owner: &Owner) -> (String, Option<String>) {
        match owner {
            Owner::Bot(id) => (
                self.sidebar_bots
                    .iter()
                    .find(|bot| {
                        bot["id"]
                            .as_str()
                            .is_some_and(|known| known.eq_ignore_ascii_case(id))
                    })
                    .map(|bot| text(bot, "name"))
                    .filter(|name| !name.is_empty())
                    .unwrap_or_else(|| "Bot".into()),
                Some("Bot".into()),
            ),
            Owner::Thread(id) => {
                let Some(title) = self.schedule_thread_title(id) else {
                    return ("Deleted thread".into(), None);
                };
                let project = self
                    .sidebar_all_threads
                    .iter()
                    .chain(&self.threads)
                    .find(|summary| summary.id.eq_ignore_ascii_case(id))
                    .map(|summary| summary.project_id.clone());
                let place = project.and_then(|project| {
                    if project == crate::navigation::NO_PROJECT_ID {
                        Some("Chat".into())
                    } else {
                        self.schedule_project_name(&project)
                    }
                });
                (title, place)
            }
            Owner::Project(id) => (
                self.schedule_project_name(id)
                    .unwrap_or_else(|| "Project unavailable".into()),
                Some("A new thread each run".into()),
            ),
        }
    }
    /// Where a schedule's runs go, which search matches too.
    fn schedule_place(&self, task: &Value) -> String {
        let owner = list::owner(task, &|thread: &str| self.schedule_bot_of(thread));
        let (title, subtitle) = self.schedule_group_title(&owner);
        let thread = task["threadID"]
            .as_str()
            .and_then(|thread| self.schedule_thread_title(thread))
            .unwrap_or_default();
        [title, subtitle.unwrap_or_default(), thread].join(" ")
    }
    /// The thread a row opens: its own, or a project task's last run.
    fn schedule_open_target(&self, task: &Value) -> Option<String> {
        task["threadID"]
            .as_str()
            .or_else(|| task["lastThreadID"].as_str())
            .filter(|thread| self.schedule_thread_title(thread).is_some())
            .map(str::to_owned)
    }
    /// The saved filter, read when the panel opens (Swift UserDefaults).
    fn load_schedule_filter(&mut self) {
        if self.schedule_editor.filter_loaded {
            return;
        }
        if let Ok(engine) = try_state(&self.engine) {
            let document = engine.store.document("ui-state.json").ok().flatten();
            self.schedule_editor.view_filter =
                list::saved_filter(document.as_ref().unwrap_or(&Value::Null));
            self.schedule_editor.filter_loaded = true;
        }
    }
    /// Swift prepareToShow: the window-wide panel opens on This Thread when the
    /// open thread has schedules, otherwise on the filter last chosen.
    pub(super) fn prepare_schedule_filter(&mut self) {
        self.load_schedule_filter();
        let saved = if self.schedule_editor.view_filter == ScheduleFilter::ThisThread {
            ScheduleFilter::All
        } else {
            self.schedule_editor.view_filter
        };
        let thread = self.selected.as_ref().map(|thread| text(thread, "id"));
        let here = self.schedule_editor.all_conversations
            && thread.as_deref().is_some_and(|id| {
                self.schedules
                    .iter()
                    .any(|task| ScheduleFilter::ThisThread.includes(task, Some(id)))
            });
        self.schedule_editor.view_filter = if here {
            ScheduleFilter::ThisThread
        } else {
            saved
        };
    }
    fn choose_schedule_filter(&mut self, filter: ScheduleFilter, cx: &mut Context<Self>) {
        self.schedule_editor.view_filter = filter;
        self.schedule_editor.scope_epoch = self.schedule_editor.scope_epoch.wrapping_add(1);
        // This Thread follows the window and is never remembered.
        if filter != ScheduleFilter::ThisThread {
            let saved = try_state(&self.engine).and_then(|mut engine| {
                engine
                    .store
                    .patch_document("ui-state.json", &json!({list::FILTER_KEY:filter.wire()}))
            });
            if saved.is_err() {
                self.schedule_status =
                    "The filter applies now but wasn’t saved for next time.".into();
            }
        }
        cx.notify();
    }
    /// The 60 s timer that keeps "Next: Today at 09:00" current.
    pub(super) fn tick_schedule_times(&mut self, cx: &mut Context<Self>) {
        let minute = (coincide_core::store::swift_timestamp() / 60.).floor() as i64;
        if self.schedules_open && minute != self.schedule_editor.rendered_minute {
            self.schedule_editor.rendered_minute = minute;
            cx.notify();
        }
    }
    fn schedule_row_action(
        &mut self,
        action: RowAction,
        id: &str,
        expected: &Value,
        scope_epoch: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(task) = self
            .schedules
            .iter()
            .find(|task| task["id"] == id && same_schedule_target(task, expected))
            .cloned()
        else {
            self.schedule_status =
                "Schedule view changed. Reopen the schedule before acting.".into();
            cx.notify();
            return;
        };
        let (pause, run_now) = list::actions_enabled(&task);
        match action {
            RowAction::Open => {
                if let Some(thread) = self.schedule_open_target(&task) {
                    self.select(&thread, window, cx);
                }
            }
            RowAction::TogglePause if pause => {
                let method = if task["isPaused"] == true {
                    "schedules.resume"
                } else {
                    "schedules.pause"
                };
                self.schedule_action(id, method, expected, scope_epoch, cx);
            }
            RowAction::RunNow if run_now => {
                self.schedule_action(id, "schedules.run-now", expected, scope_epoch, cx)
            }
            RowAction::Edit if !self.schedule_editor.open => {
                if self.schedule_editor.scope_epoch == scope_epoch {
                    self.open_schedule_editor(Some(id), window, cx);
                } else {
                    self.schedule_status =
                        "Schedule view changed. Reopen the schedule before editing.".into();
                    cx.notify();
                }
            }
            RowAction::Delete => {
                self.schedule_action(id, "schedules.delete", expected, scope_epoch, cx)
            }
            _ => {}
        }
    }
    fn schedule_tone(&self, tone: Tone, cx: &App) -> Hsla {
        let theme = cx.theme();
        match tone {
            Tone::Warning => theme.warning,
            Tone::Ink => theme.foreground,
            Tone::Muted => theme.muted_foreground,
            Tone::Danger => theme.danger,
        }
    }
    fn schedule_filter_menu(&self, cx: &Context<Self>) -> AnyElement {
        let parent = cx.entity().downgrade();
        let current = self.schedule_editor.view_filter;
        let global = self.schedule_editor.all_conversations;
        let thread_open = self.selected.is_some();
        Button::new("schedule-filter")
            .label(current.title())
            .ghost()
            .compact()
            .dropdown_caret(true)
            .accessibility_label("Schedules to show")
            .dropdown_menu(move |mut menu, _, _| {
                for filter in ScheduleFilter::ALL {
                    // A thread's own schedules panel already is This Thread.
                    if filter == ScheduleFilter::ThisThread && !global {
                        continue;
                    }
                    let parent = parent.clone();
                    menu = menu.item(
                        PopupMenuItem::new(filter.title())
                            .checked(filter == current)
                            // This Thread needs a thread open.
                            .disabled(filter == ScheduleFilter::ThisThread && !thread_open)
                            .on_click(move |_, _, cx| {
                                let _ = parent
                                    .update(cx, |this, cx| this.choose_schedule_filter(filter, cx));
                            }),
                    );
                }
                menu
            })
            .into_any_element()
    }
    fn schedule_group_header(&self, group: &list::Group<'_>, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let (muted, hover) = (theme.muted_foreground, theme.list_hover);
        let icon = match group.owner {
            Owner::Bot(_) => Symbol::Bot,
            Owner::Thread(_) => Symbol::MessagesSquare,
            Owner::Project(_) => Symbol::Folder,
        };
        // A thread's header opens it; a bot's opens its first schedule's thread.
        let target = match &group.owner {
            Owner::Thread(id) => self.schedule_thread_title(id).map(|_| id.clone()),
            Owner::Bot(_) => group
                .tasks
                .first()
                .and_then(|task| self.schedule_open_target(task)),
            Owner::Project(_) => None,
        };
        let key = match &group.owner {
            Owner::Bot(id) | Owner::Thread(id) | Owner::Project(id) => id.clone(),
        };
        div()
            .id(SharedString::from(format!("schedule-group-{key}")))
            .flex()
            .flex_none()
            .items_center()
            .gap_2()
            .px_2()
            .py_1p5()
            .mt_1()
            .rounded_md()
            .child(Icon::new(icon).xsmall().text_color(muted))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .items_baseline()
                    .gap_1p5()
                    .child(
                        div()
                            .truncate()
                            .text_sm()
                            .font_semibold()
                            .child(group.title.clone()),
                    )
                    .when_some(group.subtitle.clone(), |row, subtitle| {
                        row.child(div().truncate().text_xs().text_color(muted).child(subtitle))
                    }),
            )
            .child(
                div()
                    .flex_none()
                    .text_xs()
                    .text_color(muted)
                    .child(group.tasks.len().to_string()),
            )
            .when_some(target, |header, thread| {
                header
                    .cursor_pointer()
                    .hover(move |style| style.bg(hover))
                    .on_click(
                        cx.listener(move |this, _, window, cx| this.select(&thread, window, cx)),
                    )
            })
            .into_any_element()
    }
    fn schedule_row(
        &self,
        schedule: &Value,
        local_zone: &str,
        now: chrono::DateTime<chrono::Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme();
        let (ink, muted, hover, warning) = (
            theme.foreground,
            theme.muted_foreground,
            theme.list_hover,
            theme.warning,
        );
        let id = text(schedule, "id");
        let shown = list::shown(schedule);
        let name = text(shown, "name");
        let active = list::is_active(schedule);
        let approval = list::needs_approval(schedule);
        let status = list::status(schedule);
        let detail = list::detail(schedule, local_zone, now);
        let note = list::note(schedule);
        let tooltip = [Some(name.clone()), Some(detail.clone()), note]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join("\n");
        let spoken = [
            Some(name.clone()),
            Some(detail.clone()),
            status.map(|(label, _)| label.to_owned()),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(", ");
        let hovered = self.schedule_editor.hovered.as_deref() == Some(id.as_str());
        let scope_epoch = self.schedule_editor.scope_epoch;
        let expected = schedule_guard_snapshot(schedule);
        let (pause_enabled, run_enabled) = list::actions_enabled(schedule);
        let paused = schedule["isPaused"] == true;
        let editing = self.schedule_editor.open
            && self.schedule_editor.editing_id.as_deref() == Some(id.as_str());
        let mut first = div().flex().items_center().gap_1p5().min_w_0().child(
            div()
                .min_w_0()
                .truncate()
                .text_sm()
                .font_medium()
                .text_color(if active { ink } else { muted })
                .child(name.clone()),
        );
        if schedule["createdByAgent"] == true {
            first = first.child(
                div()
                    .id(SharedString::from(format!("schedule-agent-{id}")))
                    .flex_none()
                    .tooltip(|window, cx| Tooltip::new("Created by the agent").build(window, cx))
                    .child(
                        Icon::new(Symbol::Sparkles)
                            .xsmall()
                            .text_color(muted.opacity(0.7)),
                    ),
            );
        }
        first = first.child(div().flex_1());
        // On hover the actions take the badge's place, as in Swift.
        if hovered {
            let mut buttons = div().flex().flex_none().items_center();
            for (action, icon, label, enabled) in [
                (
                    RowAction::TogglePause,
                    if paused { Symbol::Play } else { Symbol::Pause },
                    if paused { "Resume" } else { "Pause" },
                    pause_enabled,
                ),
                (
                    RowAction::RunNow,
                    Symbol::CircleArrowRight,
                    "Run Now",
                    run_enabled && !editing,
                ),
                (
                    RowAction::Edit,
                    Symbol::Pencil,
                    "Edit…",
                    !self.schedule_editor.open,
                ),
                (RowAction::Delete, Symbol::Trash, "Delete…", true),
            ] {
                let id = id.clone();
                let expected = expected.clone();
                buttons = buttons.child(
                    Button::new(SharedString::from(format!("schedule-{action:?}-{id}")))
                        .icon(icon)
                        .ghost()
                        .xsmall()
                        .tooltip(label)
                        .accessibility_label(label)
                        .disabled(!enabled)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            cx.stop_propagation();
                            this.schedule_row_action(
                                action,
                                &id,
                                &expected,
                                scope_epoch,
                                window,
                                cx,
                            )
                        })),
                );
            }
            first = first.child(buttons);
        } else if let Some((label, tone)) = status {
            let color = self.schedule_tone(tone, cx);
            first = first.child(
                div()
                    .flex_none()
                    .px_1p5()
                    .rounded_sm()
                    .border_1()
                    .border_color(color.opacity(0.5))
                    .text_xs()
                    .text_color(color)
                    .child(label),
            );
        }
        let mut lines = div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_0p5()
            .child(first)
            .child(div().truncate().text_xs().text_color(muted).child(detail));
        // Allowing a schedule stays its own explicit step.
        if approval || schedule["proposal"].is_object() {
            let id = id.clone();
            let expected = expected.clone();
            lines = lines.child(
                div().flex().child(
                    Button::new(SharedString::from(format!("schedule-approve-{id}")))
                        .label("Approve in Rust")
                        .small()
                        .disabled(editing)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            cx.stop_propagation();
                            this.schedule_action(&id, "approve", &expected, scope_epoch, cx)
                        })),
                ),
            );
        }
        let clock = if active {
            ink
        } else if approval {
            warning
        } else {
            muted.opacity(0.6)
        };
        let hover_id = id.clone();
        let click_id = id.clone();
        let click_expected = expected.clone();
        let parent = cx.entity().downgrade();
        let menu_id = id.clone();
        let menu_expected = expected.clone();
        let open_label = if schedule["threadID"].is_string() {
            "Open Thread"
        } else {
            "Open Last Run"
        };
        let can_open = self.schedule_open_target(schedule).is_some();
        let edit_open = self.schedule_editor.open;
        div()
            .id(SharedString::from(format!("schedule-row-{id}")))
            .aria_label(spoken)
            .flex()
            .flex_none()
            .items_center()
            .gap_2()
            .px_2()
            .py_1p5()
            .rounded_md()
            .cursor_pointer()
            .hover(move |style| style.bg(hover))
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                let editor = &mut this.schedule_editor;
                if *hovered {
                    editor.hovered = Some(hover_id.clone());
                } else if editor.hovered.as_deref() == Some(hover_id.as_str()) {
                    editor.hovered = None;
                }
                cx.notify();
            }))
            // A click opens the thread, a double-click edits (Swift's mouseUp).
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                let action = if event.click_count() >= 2 {
                    RowAction::Edit
                } else {
                    RowAction::Open
                };
                this.schedule_row_action(
                    action,
                    &click_id,
                    &click_expected,
                    scope_epoch,
                    window,
                    cx,
                );
            }))
            .child(
                div()
                    .flex_none()
                    .w(px(14.))
                    .child(Icon::new(Symbol::Clock).xsmall().text_color(clock)),
            )
            .child(lines)
            .context_menu(move |menu, _, _| {
                let item = |label: &'static str, action: RowAction, enabled: bool| {
                    let parent = parent.clone();
                    let id = menu_id.clone();
                    let expected = menu_expected.clone();
                    PopupMenuItem::new(label)
                        .disabled(!enabled)
                        .on_click(move |_, window, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                this.schedule_row_action(
                                    action,
                                    &id,
                                    &expected,
                                    scope_epoch,
                                    window,
                                    cx,
                                )
                            });
                        })
                };
                menu.item(item(open_label, RowAction::Open, can_open))
                    .separator()
                    .item(item(
                        if paused { "Resume" } else { "Pause" },
                        RowAction::TogglePause,
                        pause_enabled,
                    ))
                    .item(item("Run Now", RowAction::RunNow, run_enabled && !editing))
                    .item(item("Edit…", RowAction::Edit, !edit_open))
                    .separator()
                    .item(item("Delete…", RowAction::Delete, true))
            })
            .into_any_element()
    }
    pub(super) fn schedules_pane(&mut self, cx: &mut Context<Self>) -> AnyElement {
        if self.schedule_editor.open {
            self.schedule_editor.update_preview(cx);
        }
        self.load_schedule_filter();
        self.schedule_editor.rendered_minute =
            (coincide_core::store::swift_timestamp() / 60.).floor() as i64;
        let muted = cx.theme().muted_foreground;
        let global = self.schedule_editor.all_conversations;
        let mut header =
            div()
                .flex()
                .flex_none()
                .items_center()
                .gap_2()
                .child(div().text_lg().child(if global {
                    "Scheduled"
                } else {
                    "Schedules for this conversation"
                }));
        if !self.schedules.is_empty() {
            header = header.child(
                div()
                    .text_sm()
                    .text_color(muted)
                    .child(self.schedules.len().to_string()),
            );
        }
        header = header
            .child(div().flex_1())
            .child(self.schedule_filter_menu(cx));
        let mut content=div().id("schedule-panel").flex().flex_col().flex_1().min_h_0().min_w_0().gap_3().p_4().overflow_y_scroll()
            .child(header)
            .child(Input::new(&self.schedule_editor.filter))
            .child(div().text_sm().child("Imported schedules remain dormant until approved separately in Coincide Rust. The app must stay open; missed occurrences are skipped."))
            .child(Button::new("schedule-new").label(if global {"New for selected conversation"} else {"New schedule"}).disabled(self.selected.is_none() || self.schedule_editor.open)
                .on_click(cx.listener(|this,_,window,cx|this.open_schedule_editor(None,window,cx))));
        if !self.schedule_status.is_empty() {
            content = content.child(
                div()
                    .text_sm()
                    .text_color(muted)
                    .child(self.schedule_status.clone()),
            );
        }
        if self.schedule_editor.open {
            content = content.child(self.schedule_editor_pane(cx));
        }
        let query = self.schedule_editor.filter.read(cx).value().to_string();
        let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
        let filter = self.schedule_editor.view_filter;
        let shown = self
            .schedules
            .iter()
            .filter(|task| {
                filter.includes(task, selected.as_deref())
                    && schedule_visible(
                        task,
                        global,
                        selected.as_deref(),
                        &query,
                        &self.schedule_place(task),
                    )
            })
            .collect::<Vec<_>>();
        let groups = list::groups(
            shown,
            &|thread: &str| self.schedule_bot_of(thread),
            &|owner: &Owner| self.schedule_group_title(owner),
        );
        if groups.is_empty() {
            content = content.child(
                div()
                    .py_6()
                    .text_sm()
                    .text_color(muted)
                    .text_center()
                    .child(if self.schedules.is_empty() && global {
                        "Nothing is scheduled yet. Ask an agent in any thread to do something later or on a schedule, or choose Schedule… from a thread’s menu."
                    } else if query.trim().is_empty()
                        && (!global || filter == ScheduleFilter::ThisThread)
                    {
                        "Nothing is scheduled here yet. Add a schedule, or ask the agent to do something later or on a schedule."
                    } else {
                        "No schedules match."
                    }),
            );
            if !approved {
                let id = id.clone();
                let expected = schedule_guard_snapshot(schedule);
                actions = actions.child(
                    Button::new(SharedString::from(format!("schedule-approve-{id}")))
                        .label("Approve in Rust")
                        .disabled(editing)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.schedule_action(&id, "approve", &expected, scope_epoch, cx)
                        })),
                );
            }
            for (action, label) in [
                (
                    if schedule["isPaused"] == true {
                        "schedules.resume"
                    } else {
                        "schedules.pause"
                    },
                    if schedule["isPaused"] == true {
                        "Resume"
                    } else {
                        "Pause"
                    },
                ),
                ("schedules.run-now", "Run now"),
                ("schedules.delete", "Delete…"),
            ] {
                if action == "schedules.run-now" && !approved {
                    continue;
                }
                let id = id.clone();
                let expected = schedule_guard_snapshot(schedule);
                actions = actions.child(
                    Button::new(SharedString::from(format!("schedule-{action}-{id}")))
                        .label(label)
                        .disabled(
                            action == "schedules.run-now"
                                && (editing || schedule["isPaused"] == true),
                        )
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if action == "schedules.delete" {
                                this.confirm_schedule_delete(
                                    id.clone(),
                                    expected.clone(),
                                    scope_epoch,
                                    window,
                                    cx,
                                );
                            } else {
                                this.schedule_action(&id, action, &expected, scope_epoch, cx)
                            }
                        })),
                );
            }
            content = content.child(card.child(actions));
        }
        let local_zone = coincide_core::scheduling::local_time_zone();
        let now = chrono::Utc::now();
        let mut rows = Vec::new();
        for group in &groups {
            rows.push(self.schedule_group_header(group, cx));
            for task in &group.tasks {
                rows.push(self.schedule_row(task, &local_zone, now, cx));
            }
        }
        content.children(rows).into_any_element()
    }
}
// The engine lock stays held from this comparison through approval or edit,
// so an API writer cannot substitute unseen content between review and action.
fn check_schedule_revision(
    engine: &mut Engine,
    id: &str,
    revision: &Value,
    target: &Value,
    project: &Value,
) -> Result<()> {
    let tasks = coincide_core::schedule_service::ScheduleService::new(&mut engine.store).list()?;
    let task = tasks
        .iter()
        .find(|task| task["id"] == id)
        .ok_or_else(|| anyhow::anyhow!("Schedule was deleted. Refresh and reopen it."))?;
    anyhow::ensure!(
        task["rustRevision"] == *revision
            && task["threadID"] == *target
            && task["projectID"] == *project,
        "Schedule changed. Refresh and reopen it to review the latest values."
    );
    Ok(())
}
/// The Delete alert's title and explanation, worded as Swift's. A task bound
/// to one conversation keeps it; a project task keeps the threads it made.
fn delete_confirmation(name: &str, has_thread: bool) -> (String, &'static str) {
    (
        format!("Delete scheduled task “{name}”?"),
        if has_thread {
            "The thread and the messages it already sent are kept. A running turn continues until you stop it."
        } else {
            "Existing threads are kept. A running thread continues until you stop it."
        },
    )
}
fn schedule_timing(recurrence: &Value) -> String {
    let zone = text(recurrence, "timeZoneID");
    let time = format!(
        "{:02}:{:02} ({zone})",
        recurrence["hour"].as_u64().unwrap_or(0),
        recurrence["minute"].as_u64().unwrap_or(0)
    );
    let weekday = |day: u64| {
        [
            "Sunday",
            "Monday",
            "Tuesday",
            "Wednesday",
            "Thursday",
            "Friday",
            "Saturday",
        ]
        .get(day.saturating_sub(1) as usize)
        .copied()
        .unwrap_or("Unknown day")
    };
    match recurrence["kind"].as_str().unwrap_or("") {
        "once" => format!("Once at {} · {zone}", schedule_date(&recurrence["date"])),
        "interval" => format!(
            "Every {} minutes · first run {}",
            recurrence["intervalMinutes"],
            schedule_date(&recurrence["date"])
        ),
        "daily" => format!("Daily at {time}"),
        "weekly" => format!(
            "Every {} at {time}",
            weekday(recurrence["weekday"].as_u64().unwrap_or(0))
        ),
        "weekdays" => format!("Monday–Friday at {time}"),
        "days" => format!(
            "{} at {time}",
            recurrence["weekdays"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_u64)
                .map(weekday)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        "cron" => format!("Cron {} ({zone})", text(recurrence, "cron")),
        _ => "Unsupported timing".into(),
    }
}

#[cfg(test)]
mod global_schedule_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn delete_confirmation_names_the_task_and_says_what_is_kept() {
        let (title, detail) = delete_confirmation("Morning review", true);
        assert_eq!(title, "Delete scheduled task “Morning review”?");
        assert!(detail.starts_with("The thread and the messages it already sent are kept."));
        let (_, detail) = delete_confirmation("Weekly", false);
        assert_eq!(
            detail,
            "Existing threads are kept. A running thread continues until you stop it."
        );
    }
    #[::core::prelude::v1::test]
    fn global_api_read_keeps_targets_and_native_cas_rejects_revision_or_target_changes() {
        let root = std::env::temp_dir().join(format!(
            "coincide-global-schedules-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&root).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let mut engine = Engine::new(Store::open(&root.join("state.sqlite")).unwrap());
        let request = |engine: &mut Engine, method: &str, params: Value| {
            let response = engine.dispatch(json!({"method":method,"params":params}));
            assert!(response.get("error").is_none(), "{method}: {response}");
            response["result"].clone()
        };
        let mut tasks = Vec::new();
        for name in ["first", "second"] {
            let path = root.join(name);
            std::fs::create_dir(&path).unwrap();
            let project = request(
                &mut engine,
                "projects.create",
                json!({"path":path,"name":name}),
            );
            let thread = request(
                &mut engine,
                "threads.create",
                json!({"projectId":project["id"]}),
            );
            let result = request(
                &mut engine,
                "schedules.create",
                json!({"task":{"name":name,"prompt":"Synthetic dormant task; never execute","projectID":project["id"],"threadID":thread["id"],"recurrence":{"kind":"once","timeZoneID":"UTC","date":coincide_core::store::swift_timestamp()+3600.,"hour":9,"minute":0,"weekday":2,"weekdays":null,"intervalMinutes":30,"cron":"0 9 * * 1-5"}}}),
            );
            tasks.push(result["task"].clone());
        }
        let global = request(&mut engine, "schedules.list", json!({}));
        assert_eq!(global["tasks"].as_array().unwrap().len(), 2);
        let scoped = request(
            &mut engine,
            "schedules.list",
            json!({"threadId":tasks[0]["threadID"]}),
        );
        assert_eq!(scoped["tasks"].as_array().unwrap().len(), 1);
        let task = &tasks[1];
        let id = task["id"].as_str().unwrap();
        check_schedule_revision(
            &mut engine,
            id,
            &task["rustRevision"],
            &task["threadID"],
            &task["projectID"],
        )
        .unwrap();
        assert!(
            check_schedule_revision(
                &mut engine,
                id,
                &task["rustRevision"],
                &tasks[0]["threadID"],
                &task["projectID"]
            )
            .is_err()
        );
        assert!(
            check_schedule_revision(
                &mut engine,
                id,
                &task["rustRevision"],
                &task["threadID"],
                &tasks[0]["projectID"]
            )
            .is_err()
        );
        request(
            &mut engine,
            "schedules.patch",
            json!({"scheduleId":id,"patch":{"name":"Changed while editor open"}}),
        );
        assert!(
            check_schedule_revision(
                &mut engine,
                id,
                &task["rustRevision"],
                &task["threadID"],
                &task["projectID"]
            )
            .is_err()
        );
        let latest = request(&mut engine, "schedules.list", json!({}));
        assert_eq!(latest["tasks"][0]["threadID"], tasks[0]["threadID"]);
        assert_eq!(latest["tasks"][1]["threadID"], tasks[1]["threadID"]);
        assert!(
            latest["tasks"]
                .as_array()
                .unwrap()
                .iter()
                .all(|t| t["approvalState"] != "approved")
        );
        engine.freeze_admissions();
        engine.request_core_owner_shutdown().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !engine
            .poll_core_owner_shutdown()
            .unwrap()
            .rust_owners_drained()
        {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        engine.close_store_after_core_shutdown().unwrap();
        drop(engine);
        std::fs::remove_dir_all(root).unwrap();
    }
}
