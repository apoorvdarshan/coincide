//! Native schedule editing uses the same validator and recurrence calculations
//! as the API. As in Swift, what the user saves in this editor is allowed to
//! run; schedules written through the API, by agents or imported from an
//! earlier Coincide wait until the user allows them here.
use super::*;
use coincide_core::scheduling::{
    Recurrence, format_local_datetime, parse_date, parse_local_datetime,
};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};

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
    baseline_project: Value,
    target_label: String,
    /// Where each run goes: the thread's project, or a project task's choice.
    project_id: Value,
    /// An agent's request, reviewed here ("Review Scheduled Task").
    review: bool,
    /// Saving also allows a schedule that isn't allowed yet ("Save and Allow").
    allows: bool,
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
            baseline_project: Value::Null,
            target_label: String::new(),
            project_id: Value::Null,
            review: false,
            allows: false,
            editing_id: None,
            baseline_revision: Value::Null,
            baseline_recurrence: json!({}),
            original_date: String::new(),
            original_time: String::new(),
            kind: "once".into(),
            weekday: 2,
            days: vec![2, 3, 4, 5, 6],
            name: cx.new(|cx| InputState::new(window, cx).placeholder("Task name")),
            prompt: cx.new(|cx| {
                TextareaState::new(window, cx)
                    .placeholder("Task prompt")
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
                "approve"=>"Schedule allowed.",
                "schedules.pause"=>"Schedule paused.",
                "schedules.resume"=>"Schedule resumed.",
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
    /// Projects a project task can start its threads in: every one but Bots.
    fn schedule_projects(&self) -> Vec<(String, String)> {
        self.projects
            .iter()
            .filter(|project| {
                project["isBots"] != true
                    && !text(project, "id")
                        .eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID)
            })
            .map(|project| (text(project, "id"), text(project, "name")))
            .collect()
    }
    /// Add › New Thread Each Run…: a project task in the open thread's
    /// project, or the first project.
    pub(super) fn open_project_task_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_schedule_editor_for(None, true, window, cx);
    }
    pub(super) fn open_schedule_editor(
        &mut self,
        id: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_schedule_editor_for(id, false, window, cx);
    }
    fn open_schedule_editor_for(
        &mut self,
        id: Option<&str>,
        project_task: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let projects = self.schedule_projects();
        if project_task && projects.is_empty() {
            self.schedule_status = "Add a project before creating a project task.".into();
            cx.notify();
            return;
        }
        if !project_task
            && self.selected.is_none()
            && (id.is_none() || !self.schedule_editor.all_conversations)
        {
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
        let selected_project = self
            .selected
            .as_ref()
            .map(|thread| text(thread, "projectID"))
            .filter(|id| projects.iter().any(|(project, _)| project == id));
        let editor = &mut self.schedule_editor;
        editor.editing_global = editor.all_conversations;
        editor.baseline_target = match &existing {
            Some(task) => task["threadID"].clone(),
            None if project_task => Value::Null,
            None => self.selected.as_ref().unwrap()["id"].clone(),
        };
        editor.thread_id = editor
            .baseline_target
            .as_str()
            .unwrap_or_default()
            .to_owned();
        editor.baseline_project = match &existing {
            Some(task) => task["projectID"].clone(),
            None if project_task => {
                json!(selected_project.unwrap_or_else(|| projects[0].0.clone()))
            }
            None => self.selected.as_ref().unwrap()["projectID"].clone(),
        };
        editor.project_id = editor.baseline_project.clone();
        // Swift's "Sends to": the thread's title, then its bot or project.
        editor.target_label = if editor.thread_id.is_empty() {
            String::new()
        } else {
            let thread = self.threads.iter().find(|t| t.id == editor.thread_id);
            let place = thread
                .and_then(|thread| thread.navigation.as_ref()?.bot_id.as_deref())
                .and_then(|bot| {
                    self.sidebar_bots.iter().find(|known| {
                        known["id"]
                            .as_str()
                            .is_some_and(|id| id.eq_ignore_ascii_case(bot))
                    })
                })
                .map(|bot| text(bot, "name"))
                .or_else(|| {
                    projects
                        .iter()
                        .find(|(id, _)| editor.project_id == *id)
                        .map(|(_, name)| name.clone())
                })
                .filter(|place| !place.is_empty());
            [thread
                .map(|t| t.title.clone())
                .filter(|title| !title.is_empty())
                .unwrap_or_else(|| "Thread unavailable".into())]
            .into_iter()
            .chain(place)
            .collect::<Vec<_>>()
            .join(" · ")
        };
        let approved = existing
            .as_ref()
            .is_none_or(|task| task["approvalState"] == "approved" && task["proposal"].is_null());
        editor.review = existing
            .as_ref()
            .is_some_and(|task| task["awaitingApproval"] == true || task["proposal"].is_object());
        editor.allows = !approved;
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
        let outcome = (|| -> Result<Result<Value>> {
            // A project task names its project itself, so only a thread
            // schedule depends on which conversation is open.
            anyhow::ensure!(
                editor.open
                    && editor.editing_global == editor.all_conversations
                    && (editor.editing_global
                        || editor.thread_id.is_empty()
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
            anyhow::ensure!(
                editor.project_id.is_string(),
                "Choose a project for this task."
            );
            let recurrence = editor.recurrence(cx)?;
            let write = if let Some(id) = &editor.editing_id {
                let mut patch = json!({"name":name,"prompt":prompt,"recurrence":recurrence});
                if editor.project_id != editor.baseline_project {
                    patch["projectID"] = editor.project_id.clone();
                }
                ScheduleWrite::Patch {
                    id,
                    reviewed: [
                        &editor.baseline_revision,
                        &editor.baseline_target,
                        &editor.baseline_project,
                    ],
                    patch,
                }
            } else {
                let mut task = json!({"name":name,"prompt":prompt,"projectID":editor.project_id,"recurrence":recurrence});
                if !editor.thread_id.is_empty() {
                    task["threadID"] = json!(editor.thread_id);
                }
                ScheduleWrite::Create(task)
            };
            save_and_allow(&mut *try_state(&self.engine)?, write)
        })();
        match outcome {
            Ok(Ok(_)) => {
                self.schedule_editor.open = false;
                self.schedule_status.clear();
            }
            Ok(Err(error)) => {
                self.schedule_editor.open = false;
                self.schedule_status =
                    format!("Schedule saved, but it can't run until you allow it: {error}");
            }
            Err(error) => self.schedule_status = format!("Schedule was not saved: {error}"),
        }
        self.refresh_schedules(cx);
    }
    fn schedule_project_picker(&self, cx: &Context<Self>) -> AnyElement {
        let projects = self.schedule_projects();
        let current = projects
            .iter()
            .find(|(id, _)| self.schedule_editor.project_id == *id)
            .map(|(_, name)| name.clone())
            .unwrap_or_else(|| "Choose a Project".into());
        let selected = self.schedule_editor.project_id.clone();
        let parent = cx.entity().downgrade();
        Button::new("schedule-project")
            .label(current)
            .accessibility_label("Project")
            .dropdown_caret(true)
            .dropdown_menu(move |mut menu, _, _| {
                for (id, name) in &projects {
                    let parent = parent.clone();
                    let id = id.clone();
                    menu = menu.item(
                        PopupMenuItem::new(name.clone())
                            .checked(selected == id)
                            .on_click(move |_, _, cx| {
                                let _ = parent.update(cx, |this, cx| {
                                    let editor = &mut this.schedule_editor;
                                    if editor.open && editor.thread_id.is_empty() {
                                        editor.project_id = json!(id);
                                        cx.notify();
                                    }
                                });
                            }),
                    );
                }
                menu
            })
            .into_any_element()
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
            .child(div().font_semibold().child(if editor.review {
                "Review Scheduled Task"
            } else if editor.editing_id.is_some() {
                "Edit Scheduled Task"
            } else {
                "New Scheduled Task"
            }))
            .child(div().text_sm().child("Name"))
            .child(Input::new(&editor.name));
        // A thread schedule shows where it sends, a project task its project.
        form = if editor.thread_id.is_empty() {
            form.child(div().text_sm().child("Project"))
                .child(self.schedule_project_picker(cx))
        } else {
            form.child(div().text_sm().child("Sends to"))
                .child(div().truncate().child(editor.target_label.clone()))
        };
        form = form
            .child(div().text_sm().child("Task prompt"))
            .child(Textarea::new(&editor.prompt).h(px(90.)))
            .child(div().text_sm().child("Schedule"))
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
            .child(div().text_xs().opacity(0.7).child(if editor.thread_id.is_empty() {
                "Runs only while Coincide is open. Missed runs are skipped after quitting or sleep. Each run starts a new thread using the project's defaults."
            } else {
                "Each run sends the prompt into this thread as your next message, with the thread’s agent, model and access at that time. A busy thread gets it when its turn ends. Runs only while Coincide is open; missed runs are skipped."
            }))
            .child(div().flex().justify_end().gap_2()
                .child(Button::new("schedule-cancel").label("Cancel").on_click(cx.listener(|this,_,_,cx|{this.schedule_editor.open=false;cx.notify();})))
                .child(Button::new("schedule-save").label(if editor.allows {"Save and Allow"} else {"Save"}).primary().on_click(cx.listener(|this,_,_,cx|this.save_schedule(cx)))))
            .into_any_element()
    }

    /// Swift's Add (+) menu: a schedule in the open thread, or a project task
    /// that starts a new thread at each run.
    fn new_schedule_menu(&self, cx: &Context<Self>) -> AnyElement {
        let parent = cx.entity().downgrade();
        let in_thread = self.selected.is_some();
        let has_projects = !self.schedule_projects().is_empty();
        Button::new("schedule-new")
            .icon(IconName::Plus)
            .ghost()
            .compact()
            .accessibility_label("New Scheduled Task")
            .tooltip("New Scheduled Task")
            .disabled(self.schedule_editor.open)
            .dropdown_menu(move |menu, _, _| {
                let thread_parent = parent.clone();
                let project_parent = parent.clone();
                menu.item(
                    PopupMenuItem::new("Schedule in This Thread…")
                        .disabled(!in_thread)
                        .on_click(move |_, window, cx| {
                            let _ = thread_parent
                                .update(cx, |this, cx| this.open_schedule_editor(None, window, cx));
                        }),
                )
                .item(
                    PopupMenuItem::element(|_, _| {
                        div().flex().flex_col().child("New Thread Each Run…").child(
                            div()
                                .text_xs()
                                .opacity(0.6)
                                .child("Starts a new thread in a project at each run"),
                        )
                    })
                    .disabled(!has_projects)
                    .on_click(move |_, window, cx| {
                        let _ = project_parent
                            .update(cx, |this, cx| this.open_project_task_editor(window, cx));
                    }),
                )
            })
            .into_any_element()
    }
    pub(super) fn schedules_pane(&mut self, cx: &mut Context<Self>) -> AnyElement {
        if self.schedule_editor.open {
            self.schedule_editor.update_preview(cx);
        }
        let imported = self
            .schedules
            .iter()
            .any(|task| task["approvalState"] != "approved" && task["awaitingApproval"] != true);
        let mut content=div().id("schedule-panel").flex().flex_col().flex_1().min_h_0().min_w_0().gap_3().p_4().overflow_y_scroll()
            .child(div().flex().items_center().gap_2()
                .child(div().flex_1().text_lg().child(if self.schedule_editor.all_conversations {"Scheduled"} else {"Schedules for this conversation"}))
                .child(self.new_schedule_menu(cx)))
            .child(Input::new(&self.schedule_editor.filter))
            .when(imported, |content| content.child(div().text_sm().child("Schedules imported from an earlier Coincide run here only once you allow them.")))
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
                .child(div().text_sm().child(if !approved {
                    "Needs approval"
                } else if schedule["proposal"].is_object() {
                    "Change needs approval"
                } else if schedule["isPaused"] == true {
                    "Paused"
                } else {
                    "Active"
                }));
            if !approved {
                card = card.child(div().text_sm().opacity(0.7).child(
                    if schedule["awaitingApproval"] == true {
                        "An agent created or changed this schedule. It runs once you allow it."
                    } else {
                        "Imported from an earlier Coincide. It runs here once you allow it."
                    },
                ));
            }
            if self.schedule_editor.all_conversations {
                let project = self
                    .projects
                    .iter()
                    .find(|p| p["id"] == schedule["projectID"])
                    .map(|p| text(p, "name"))
                    .filter(|name| !name.is_empty())
                    .unwrap_or_else(|| "Other project".into());
                let destination = match schedule["threadID"].as_str() {
                    Some(id) => self
                        .threads
                        .iter()
                        .find(|thread| thread.id.eq_ignore_ascii_case(id))
                        .map(|thread| thread.title.clone())
                        .filter(|title| !title.is_empty())
                        .unwrap_or_else(|| "Saved conversation".into()),
                    None => "A new thread each run".into(),
                };
                card = card.child(div().text_sm().child(format!("{project} · {destination}")));
            }
            if !schedule["proposal"].is_null() {
                card = card.child(
                    div()
                        .text_sm()
                        .child("The change shown above takes effect once you allow it."),
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
            if !approved || schedule["proposal"].is_object() {
                let id = id.clone();
                let expected = schedule_guard_snapshot(schedule);
                actions = actions.child(
                    Button::new(SharedString::from(format!("schedule-approve-{id}")))
                        .label("Allow")
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
                let id = id.clone();
                let expected = schedule_guard_snapshot(schedule);
                actions = actions.child(
                    Button::new(SharedString::from(format!("schedule-{action}-{id}")))
                        .label(label)
                        .disabled(
                            action == "schedules.run-now"
                                && (!approved || editing || schedule["isPaused"] == true),
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
/// What the editor saves: a new schedule, or a patch to the schedule whose
/// revision, thread and project the user reviewed.
enum ScheduleWrite<'a> {
    Create(Value),
    Patch {
        id: &'a str,
        reviewed: [&'a Value; 3],
        patch: Value,
    },
}
/// Saves and allows in one engine lock, so no API writer can change what the
/// user reviewed in between. Saving in the editor is the user's own choice, as
/// in Swift; agent and API writes still wait for Allow. The inner result is
/// the approval: a saved schedule may still fail to be allowed.
fn save_and_allow(engine: &mut Engine, write: ScheduleWrite<'_>) -> Result<Result<Value>> {
    let request = match write {
        ScheduleWrite::Create(task) => json!({"method":"schedules.create","params":{"task":task}}),
        ScheduleWrite::Patch {
            id,
            reviewed: [revision, target, project],
            patch,
        } => {
            check_schedule_revision(engine, id, revision, target, project)?;
            json!({"method":"schedules.patch","params":{"scheduleId":id,"patch":patch}})
        }
    };
    let response = engine.dispatch(request);
    if let Some(error) = response.get("error") {
        anyhow::bail!(
            "{}",
            error["message"]
                .as_str()
                .unwrap_or("Schedule could not be saved")
        );
    }
    Ok(engine.approve_schedule(&text(&response["result"]["task"], "id")))
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

    #[::core::prelude::v1::test]
    fn editor_saves_are_allowed_while_api_writes_still_wait() {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&root.path().join("state.sqlite")).unwrap());
        // The first poll finishes scheduler recovery, which approval requires.
        engine.poll();
        let request = |engine: &mut Engine, method: &str, params: Value| {
            let response = engine.dispatch(json!({"method":method,"params":params}));
            assert!(response.get("error").is_none(), "{method}: {response}");
            response["result"].clone()
        };
        let mut projects = Vec::new();
        for name in ["first", "second"] {
            let path = root.path().join(name);
            std::fs::create_dir(&path).unwrap();
            projects.push(request(
                &mut engine,
                "projects.create",
                json!({"path":path,"name":name}),
            ));
        }
        let thread = request(
            &mut engine,
            "threads.create",
            json!({"projectId":projects[0]["id"]}),
        );
        // Allowed schedules here must never come due while the test runs.
        let recurrence = json!({"kind":"once","timeZoneID":"UTC","date":coincide_core::store::swift_timestamp()+30.*86400.,"hour":9,"minute":0,"weekday":2});
        let state = |engine: &mut Engine, id: &str| {
            request(engine, "schedules.list", json!({}))["tasks"]
                .as_array()
                .unwrap()
                .iter()
                .find(|task| task["id"] == id)
                .cloned()
                .unwrap()
        };
        // A thread schedule and a project task, each allowed as it is saved.
        let saved = save_and_allow(
            &mut engine,
            ScheduleWrite::Create(json!({"name":"Thread","prompt":"Synthetic task; never execute","projectID":thread["projectID"],"threadID":thread["id"],"recurrence":recurrence})),
        )
        .unwrap()
        .unwrap();
        let thread_task = text(&saved["task"], "id");
        assert_eq!(
            state(&mut engine, &thread_task)["approvalState"],
            "approved"
        );
        let saved = save_and_allow(
            &mut engine,
            ScheduleWrite::Create(json!({"name":"Project","prompt":"Synthetic task; never execute","projectID":projects[0]["id"],"recurrence":recurrence})),
        )
        .unwrap()
        .unwrap();
        let project_task = text(&saved["task"], "id");
        let listed = state(&mut engine, &project_task);
        assert_eq!(listed["approvalState"], "approved");
        assert!(listed.get("threadID").is_none());
        // An API write waits; saving it in the editor allows it, and a
        // project task can move to another project.
        let api = request(
            &mut engine,
            "schedules.patch",
            json!({"scheduleId":project_task,"patch":{"name":"Changed by the API"}}),
        )["task"]
            .clone();
        assert_ne!(
            state(&mut engine, &project_task)["approvalState"],
            "approved"
        );
        save_and_allow(
            &mut engine,
            ScheduleWrite::Patch {
                id: &project_task,
                reviewed: [&api["rustRevision"], &Value::Null, &api["projectID"]],
                patch: json!({"name":"Reviewed","projectID":projects[1]["id"]}),
            },
        )
        .unwrap()
        .unwrap();
        let listed = state(&mut engine, &project_task);
        assert_eq!(listed["approvalState"], "approved");
        assert_eq!(listed["projectID"], projects[1]["id"]);
        // What the user reviewed must still be what is saved.
        assert!(
            save_and_allow(
                &mut engine,
                ScheduleWrite::Patch {
                    id: &project_task,
                    reviewed: [&api["rustRevision"], &Value::Null, &api["projectID"]],
                    patch: json!({"name":"Stale"}),
                },
            )
            .is_err()
        );
        assert_eq!(state(&mut engine, &project_task)["name"], "Reviewed");
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
    }
}
