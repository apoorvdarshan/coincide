//! Native schedule editing uses the same validator and recurrence calculations
//! as the API. Saving a draft never grants execution approval.
use super::*;
use coincide_core::scheduling::{
    Recurrence, format_local_datetime, parse_date, parse_local_datetime,
};

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
        subscriptions
    }
    pub fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            open: false,
            thread_id: String::new(),
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
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            self.schedules.clear();
            return;
        };
        match call(&self.engine, "schedules.list", json!({"threadId":thread})) {
            Ok(result) => {
                self.schedules = result["tasks"].as_array().cloned().unwrap_or_default();
                if let Some(error) = result["error"].as_str() {
                    self.schedule_status = format!("Scheduler: {error}");
                }
            }
            Err(error) => {
                self.schedules.clear();
                self.schedule_status = format!("Unable to load schedules: {error}");
            }
        }
        cx.notify();
    }
    fn schedule_action(
        &mut self,
        id: &str,
        action: &str,
        expected_revision: &Value,
        cx: &mut Context<Self>,
    ) {
        // A cached accessibility/click handler must not act on a card from a
        // conversation that is no longer selected, including after read errors.
        if !self.schedules.iter().any(|task| {
            task["id"] == id
                && self
                    .selected
                    .as_ref()
                    .is_some_and(|thread| task["threadID"] == thread["id"])
        }) {
            self.schedule_status =
                "Conversation changed. Reopen the schedule before acting.".into();
            cx.notify();
            return;
        }
        let result = if action == "approve" {
            match self.engine.lock() {
                Ok(mut engine) => check_schedule_revision(&mut engine, id, expected_revision)
                    .and_then(|_| engine.approve_schedule(id)),
                Err(_) => Err(anyhow::anyhow!("App engine is unavailable")),
            }
        } else {
            call(&self.engine, action, json!({"scheduleId":id}))
        };
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
        if action == "schedules.delete" && self.schedule_editor.editing_id.as_deref() == Some(id) {
            self.schedule_editor.open = false;
        }
        self.refresh_schedules(cx);
    }
    fn open_schedule_editor(
        &mut self,
        id: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(thread) = self.selected.as_ref() else {
            self.schedule_status = "Choose a conversation first.".into();
            cx.notify();
            return;
        };
        let existing = match id {
            Some(id) => match self.schedules.iter().find(|task| task["id"] == id) {
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
        editor.thread_id = text(thread, "id");
        editor.project_id = thread["projectID"].clone();
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
                self.selected
                    .as_ref()
                    .is_some_and(|v| v["id"] == editor.thread_id),
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
                let mut engine = self
                    .engine
                    .lock()
                    .map_err(|_| anyhow::anyhow!("App engine is unavailable"))?;
                check_schedule_revision(&mut engine, id, &editor.baseline_revision)?;
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
            .child(div().text_lg().child("Schedules for this conversation"))
            .child(div().text_sm().child("Imported schedules remain dormant until approved separately in Coincide Rust. The app must stay open; missed occurrences are skipped."))
            .child(Button::new("schedule-new").label("New schedule").disabled(self.selected.is_none() || self.schedule_editor.open)
                .on_click(cx.listener(|this,_,window,cx|this.open_schedule_editor(None,window,cx))))
            .child(div().text_sm().child(self.schedule_status.clone()));
        if self.schedule_editor.open {
            content = content.child(self.schedule_editor_pane(cx));
        }
        if self.schedules.is_empty() {
            content = content.child(div().child("No schedules in this conversation."));
        }
        for schedule in &self.schedules {
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
            let mut actions = div().flex().flex_wrap().gap_2().child(
                Button::new(SharedString::from(format!("schedule-edit-{id}")))
                    .label("Edit")
                    .disabled(self.schedule_editor.open)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open_schedule_editor(Some(&edit_id), window, cx)
                    })),
            );
            if !approved {
                let id = id.clone();
                let revision = schedule["rustRevision"].clone();
                actions = actions.child(
                    Button::new(SharedString::from(format!("schedule-approve-{id}")))
                        .label("Approve in Rust")
                        .disabled(editing)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.schedule_action(&id, "approve", &revision, cx)
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
                actions = actions.child(
                    Button::new(SharedString::from(format!("schedule-{action}-{id}")))
                        .label(label)
                        .disabled(
                            action == "schedules.run-now"
                                && (editing || schedule["isPaused"] == true),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.schedule_action(&id, action, &Value::Null, cx)
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
fn check_schedule_revision(engine: &mut Engine, id: &str, revision: &Value) -> Result<()> {
    let tasks = coincide_core::schedule_service::ScheduleService::new(&mut engine.store).list()?;
    let task = tasks
        .iter()
        .find(|task| task["id"] == id)
        .ok_or_else(|| anyhow::anyhow!("Schedule was deleted. Refresh and reopen it."))?;
    anyhow::ensure!(
        task["rustRevision"] == *revision,
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
