//! Native schedule editing uses the same validator and recurrence calculations
//! as the API. Saving a draft never grants execution approval.
use super::*;
use coincide_core::scheduling::{
    Recurrence, format_local_datetime, parse_date, parse_local_datetime,
};

#[path = "scheduling_list.rs"]
mod list;
use list::{same_schedule_target, schedule_guard_snapshot, schedule_visible};

const KINDS: &[(&str, &str)] = &[
    ("once", "Once"),
    ("daily", "Daily"),
    ("weekly", "Weekly"),
    ("weekdays", "Weekdays"),
    ("days", "Selected days"),
    ("interval", "Interval"),
    ("cron", "Cron"),
];
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
            filter: cx.new(|cx| InputState::new(window, cx).placeholder("Filter schedules")),
            editing_global: false,
            baseline_target: Value::Null,
            target_label: String::new(),
            project_id: Value::Null,
            editing_id: None,
            baseline_revision: Value::Null,
            baseline_recurrence: json!({}),
            original_date: String::new(),
            original_time: String::new(),
            kind: "once".into(),
            weekday: 2,
            days: vec![2, 3, 4, 5, 6],
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
            interval: cx.new(|cx| InputState::new(window, cx).placeholder("Minutes between runs")),
            cron: cx.new(|cx| InputState::new(window, cx).placeholder("0 9 * * 1-5")),
            preview: String::new(),
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
            value["intervalMinutes"] = json!(
                self.interval
                    .read(cx)
                    .value()
                    .trim()
                    .parse::<u32>()
                    .map_err(|_| anyhow::anyhow!("Enter an interval in whole minutes"))?
            );
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
            self.cron.read(cx).value().as_ref()
        ])
    }
    fn update_preview(&mut self, cx: &App) {
        let key = self.form_key(cx);
        if self.preview_key.as_ref() == Some(&key) {
            return;
        }
        self.preview_key = Some(key);
        let result = (|| -> Result<String> {
            let recurrence: Recurrence = serde_json::from_value(self.recurrence(cx)?)?;
            let mut after = parse_date(&json!(coincide_core::store::swift_timestamp()))?;
            let mut dates = Vec::new();
            for _ in 0..3 {
                let Some(next) = recurrence.next_after(after)? else {
                    break;
                };
                let (day, time) = format_local_datetime(&json!(next), &recurrence.time_zone_id)?;
                dates.push(format!("{day} {time}"));
                after = next;
            }
            anyhow::ensure!(
                !dates.is_empty(),
                "This timing has no future run. Choose a future date or a matching recurrence."
            );
            Ok(format!(
                "Next runs in {}: {}",
                recurrence.time_zone_id,
                dates.join(" · ")
            ))
        })();
        self.preview = match result {
            Ok(preview) => preview,
            Err(error) => format!("Timing needs attention: {error}"),
        };
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
        let recurrence=proposed.map(|task|task["recurrence"].clone()).unwrap_or_else(||json!({
            "kind":"once","timeZoneID":"UTC","date":coincide_core::store::swift_timestamp()+3600.,
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
            input.set_value(
                recurrence["intervalMinutes"]
                    .as_u64()
                    .unwrap_or(30)
                    .to_string(),
                window,
                cx,
            )
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
            Ok(_) => {
                self.schedule_editor.open = false;
                self.schedule_status="Saved for review. Execution requires a separate approval below; any previous approval was revoked.".into();
            }
            Err(error) => self.schedule_status = format!("Schedule was not saved: {error}"),
        }
        self.refresh_schedules(cx);
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
            form = form
                .child(div().text_sm().child("Repeat every N minutes (5–44,640)"))
                .child(Input::new(&editor.interval));
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
        form.child(div().text_sm().child(editor.preview.clone()))
            .child(div().text_sm().child("Busy conversations wait for their current turn. Saving edits requires renewed approval; it does not interrupt an already running turn."))
            .child(div().flex().gap_2()
                .child(Button::new("schedule-save").label("Save for review").primary().on_click(cx.listener(|this,_,_,cx|this.save_schedule(cx))))
                .child(Button::new("schedule-cancel").label("Cancel").on_click(cx.listener(|this,_,_,cx|{this.schedule_editor.open=false;cx.notify();}))))
            .into_any_element()
    }

    pub(super) fn schedules_pane(&mut self, cx: &mut Context<Self>) -> AnyElement {
        if self.schedule_editor.open {
            self.schedule_editor.update_preview(cx);
        }
        let mut content=div().id("schedule-panel").flex().flex_col().flex_1().min_h_0().min_w_0().gap_3().p_4().overflow_y_scroll()
            .child(div().text_lg().child(if self.schedule_editor.all_conversations {"Scheduled"} else {"Schedules for this conversation"}))
            .child(Input::new(&self.schedule_editor.filter))
            .child(div().text_sm().child("Imported schedules remain dormant until approved separately in Coincide Rust. The app must stay open; missed occurrences are skipped."))
            .child(Button::new("schedule-new").label(if self.schedule_editor.all_conversations {"New for selected conversation"} else {"New schedule"}).disabled(self.selected.is_none() || self.schedule_editor.open)
                .on_click(cx.listener(|this,_,window,cx|this.open_schedule_editor(None,window,cx))))
            .child(div().text_sm().child(self.schedule_status.clone()));
        if self.schedule_editor.open {
            content = content.child(self.schedule_editor_pane(cx));
        }
        let query = self.schedule_editor.filter.read(cx).value().to_string();
        let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
        let rows = self
            .schedules
            .iter()
            .filter(|task| {
                schedule_visible(
                    task,
                    self.schedule_editor.all_conversations,
                    selected.as_deref(),
                    &query,
                )
            })
            .collect::<Vec<_>>();
        if rows.is_empty() {
            content = content.child(div().child(if query.trim().is_empty() {
                "No schedules in this view."
            } else {
                "No schedules match this filter."
            }));
        }
        let scope_epoch = self.schedule_editor.scope_epoch;
        for schedule in rows {
            let id = text(schedule, "id");
            let state = text(schedule, "approvalState");
            let approved = state == "approved";
            let proposed = schedule
                .get("proposal")
                .filter(|value| value.is_object())
                .unwrap_or(schedule);
            let mut card = div()
                .flex()
                .flex_col()
                .flex_shrink_0()
                .gap_2()
                .p_3()
                .rounded_md()
                .bg(self.color(0x202a3b))
                .child(div().font_semibold().child(text(proposed, "name")))
                .child(div().child(text(proposed, "prompt")))
                .child(div().text_sm().child(format!(
                    "Next run: {}",
                    schedule_date(&schedule["nextRunAt"])
                )))
                .child(div().text_sm().child(format!(
                    "Timing: {}",
                    schedule_timing(&proposed["recurrence"])
                )))
                .child(div().text_sm().child(format!(
                    "Approval: {} · {}",
                    if approved {
                        "Approved"
                    } else if state == "awaitingUserApproval" {
                        "Awaiting your approval"
                    } else {
                        "Awaiting separate Rust approval"
                    },
                    if schedule["isPaused"] == true {
                        "Paused"
                    } else {
                        "Enabled"
                    }
                )));
            if self.schedule_editor.all_conversations {
                let project = self
                    .projects
                    .iter()
                    .find(|p| p["id"] == schedule["projectID"])
                    .map(|p| text(p, "name"))
                    .filter(|name| !name.is_empty())
                    .unwrap_or_else(|| "Other project".into());
                card = card.child(div().text_sm().child(format!(
                    "{project} · {}",
                    if schedule["threadID"].is_string() {
                        "Saved conversation"
                    } else {
                        "New conversation per run"
                    }
                )));
            }
            if !schedule["proposal"].is_null() {
                card = card.child(
                    div()
                        .text_sm()
                        .child("Pending changes shown above will take effect when approved."),
                );
            }
            if let Some(reason) = schedule["pauseReason"].as_str() {
                card = card.child(div().text_sm().child(reason.to_owned()));
            }
            if !schedule["pendingDelivery"].is_null() {
                card = card.child(
                    div()
                        .text_sm()
                        .child("Waiting for this conversation's current turn to finish."),
                );
            }
            if !schedule["rustClaim"].is_null() {
                card = card.child(div().text_sm().child("A scheduled turn is running."));
            }
            if let Some(outcome) = schedule["lastOutcome"].as_str() {
                card = card.child(div().text_sm().child(format!("Last outcome: {outcome}")));
            }
            if let Some(message) = schedule["lastMessage"].as_str() {
                card = card.child(div().text_sm().child(message.to_owned()));
            }
            let editing = self.schedule_editor.open
                && self.schedule_editor.editing_id.as_deref() == Some(id.as_str());
            let edit_id = id.clone();
            let edit_expected = schedule_guard_snapshot(schedule);
            let mut actions = div().flex().flex_wrap().gap_2().child(
                Button::new(SharedString::from(format!("schedule-edit-{id}")))
                    .label("Edit")
                    .disabled(self.schedule_editor.open)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if this.schedule_editor.scope_epoch == scope_epoch
                            && this.schedules.iter().any(|task| {
                                task["id"] == edit_id && same_schedule_target(task, &edit_expected)
                            })
                        {
                            this.open_schedule_editor(Some(&edit_id), window, cx);
                        } else {
                            this.schedule_status =
                                "Schedule view changed. Reopen the schedule before editing.".into();
                            cx.notify();
                        }
                    })),
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
                ("schedules.delete", "Delete"),
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
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.schedule_action(&id, action, &expected, scope_epoch, cx)
                        })),
                );
            }
            content = content.child(card.child(actions));
        }
        content.into_any_element()
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
