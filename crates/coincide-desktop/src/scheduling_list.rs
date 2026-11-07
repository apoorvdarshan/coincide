//! View scoping never changes a schedule's captured execution target. How a
//! schedule reads in the Scheduled panel follows Swift's SchedulePresentation
//! and ScheduleFilter: badges, notes, the next run, groups and search.
use chrono::{DateTime, Datelike, Utc};
use chrono_tz::Tz;
use coincide_core::scheduling::parse_date;
use serde_json::{Value, json};
use std::collections::HashMap;

/// The saved filter in ui-state.json (Swift keeps "ScheduleFilter").
pub(super) const FILTER_KEY: &str = "scheduleFilter";
/// What the Scheduled panel lists. This Thread is the open thread's schedules:
/// the panel starts on it when the thread has some, and never saves it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ScheduleFilter {
    All,
    ThisThread,
    Active,
    Paused,
    Attention,
}
impl ScheduleFilter {
    pub const ALL: [Self; 5] = [
        Self::All,
        Self::ThisThread,
        Self::Active,
        Self::Paused,
        Self::Attention,
    ];
    pub fn wire(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::ThisThread => "thisThread",
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Attention => "attention",
        }
    }
    pub fn title(self) -> &'static str {
        match self {
            Self::All => "All Schedules",
            Self::ThisThread => "This Thread",
            Self::Active => "Active",
            Self::Paused => "Paused",
            Self::Attention => "Needs Attention",
        }
    }
    /// `thread` is the open thread, which This Thread lists.
    pub fn includes(self, task: &Value, thread: Option<&str>) -> bool {
        match self {
            Self::All => true,
            Self::ThisThread => thread.is_some_and(|id| {
                task["threadID"]
                    .as_str()
                    .is_some_and(|t| t.eq_ignore_ascii_case(id))
            }),
            Self::Active => is_active(task),
            Self::Paused => task["isPaused"] == true,
            Self::Attention => {
                needs_approval(task)
                    || task["proposal"].is_object()
                    || !task["pauseReason"].is_null()
                    || matches!(task["lastOutcome"].as_str(), Some("failed" | "missed"))
            }
        }
    }
}
/// The filter the user last chose other than This Thread, or every schedule.
pub(super) fn saved_filter(document: &Value) -> ScheduleFilter {
    let saved = document[FILTER_KEY].as_str();
    ScheduleFilter::ALL
        .into_iter()
        .find(|filter| Some(filter.wire()) == saved && *filter != ScheduleFilter::ThisThread)
        .unwrap_or(ScheduleFilter::All)
}

/// Not yet allowed to run: an agent's request or an imported schedule.
pub(super) fn needs_approval(task: &Value) -> bool {
    task["approvalState"] != "approved"
}
pub(super) fn is_active(task: &Value) -> bool {
    task["isPaused"] != true && !needs_approval(task)
}
pub(super) fn is_running(task: &Value) -> bool {
    !task["rustClaim"].is_null() || !task["activeThreadID"].is_null()
}
/// The fields a row shows: a pending change's, until it is allowed.
pub(super) fn shown(task: &Value) -> &Value {
    task.get("proposal")
        .filter(|p| p.is_object())
        .unwrap_or(task)
}

/// A badge's color, resolved by the panel for light and dark.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Tone {
    Warning,
    Ink,
    Muted,
    Danger,
}
/// A schedule's state as a short badge; none for an active schedule waiting
/// for its next run.
pub(super) fn status(task: &Value) -> Option<(&'static str, Tone)> {
    if needs_approval(task) {
        return Some(("Needs approval", Tone::Warning));
    }
    if is_running(task) {
        return Some(("Running", Tone::Ink));
    }
    if !task["pendingDelivery"].is_null() {
        return Some(("Waiting for thread", Tone::Ink));
    }
    match task["pauseReason"].as_str() {
        Some("threadArchived") => return Some(("Thread archived", Tone::Muted)),
        Some("threadDeleted") => return Some(("Thread deleted", Tone::Danger)),
        _ => {}
    }
    let outcome = task["lastOutcome"].as_str();
    if task["isPaused"] == true {
        return Some(if outcome == Some("failed") {
            ("Failed · Paused", Tone::Danger)
        } else {
            ("Paused", Tone::Muted)
        });
    }
    if task["proposal"].is_object() {
        return Some(("Change needs approval", Tone::Warning));
    }
    match outcome {
        Some("failed") => Some(("Failed", Tone::Danger)),
        Some("missed") => Some(("Missed", Tone::Warning)),
        Some("interrupted") => Some(("Interrupted", Tone::Warning)),
        Some("completed") if task["nextRunAt"].is_null() => Some(("Done", Tone::Muted)),
        _ => None,
    }
}
/// Why a paused schedule is paused, or what its last run did.
pub(super) fn note(task: &Value) -> Option<String> {
    match task["pauseReason"].as_str() {
        Some("threadArchived") => {
            return Some(
                "Paused because its thread is archived. It resumes when you unarchive the thread."
                    .into(),
            );
        }
        Some("threadDeleted") => {
            return Some("Paused because its thread was deleted. Delete the schedule, or undo deleting the thread.".into());
        }
        _ => {}
    }
    if needs_approval(task) {
        return Some(
            if task["awaitingApproval"] == true {
                "An agent created this schedule. It runs once you allow it."
            } else {
                "Imported from an earlier Coincide. It runs here once you allow it."
            }
            .into(),
        );
    }
    if !task["pendingDelivery"].is_null() {
        return Some("Its thread is busy; the run is sent when the current turn ends.".into());
    }
    task["lastMessage"]
        .as_str()
        .filter(|message| !message.trim().is_empty())
        .map(str::to_owned)
}
/// Swift's Pause/Resume and Run Now rules: neither while the schedule waits for
/// approval or its thread is archived or deleted; Run Now also runs a paused
/// schedule, but not one already running.
pub(super) fn actions_enabled(task: &Value) -> (bool, bool) {
    let blocked = needs_approval(task) || !task["pauseReason"].is_null();
    (!blocked, !blocked && !is_running(task))
}

const WEEKDAYS: [&str; 7] = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
];
fn weekday_name(day: u64) -> &'static str {
    WEEKDAYS[(day.clamp(1, 7) - 1) as usize]
}
/// "Every day at 09:00": Swift TaskRecurrence.summary, with 24-hour times.
pub(super) fn summary(recurrence: &Value) -> String {
    let zone = recurrence["timeZoneID"].as_str().unwrap_or("UTC");
    let time = format!(
        "{:02}:{:02}",
        recurrence["hour"].as_u64().unwrap_or(0),
        recurrence["minute"].as_u64().unwrap_or(0)
    );
    match recurrence["kind"].as_str().unwrap_or_default() {
        "once" => match parse_date(&recurrence["date"]) {
            Ok(date) => format!("Once, {}", calendar_time(date, zone)),
            Err(_) => "Once".into(),
        },
        "daily" => format!("Every day at {time}"),
        "weekly" => format!(
            "Every {} at {time}",
            weekday_name(recurrence["weekday"].as_u64().unwrap_or(2))
        ),
        "weekdays" => format!("Weekdays at {time}"),
        "days" => {
            // In the order of the week, starting Monday.
            let mut days = recurrence["weekdays"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_u64)
                .filter(|day| (1..=7).contains(day))
                .collect::<Vec<_>>();
            days.sort_by_key(|day| (day + 5) % 7);
            days.dedup();
            let names = days
                .iter()
                .map(|day| &weekday_name(*day)[..3])
                .collect::<Vec<_>>();
            format!("{} at {time}", list(&names))
        }
        "interval" => {
            let minutes = recurrence["intervalMinutes"].as_u64().unwrap_or(0);
            match minutes {
                1440 => "Every 24 hours".into(),
                m if m > 0 && m % 1440 == 0 => format!("Every {} days", m / 1440),
                60 => "Every hour".into(),
                m if m > 0 && m % 60 == 0 => format!("Every {} hours", m / 60),
                m => format!("Every {m} minutes"),
            }
        }
        "cron" => format!(
            "Custom schedule: {}",
            recurrence["cron"].as_str().unwrap_or_default()
        ),
        _ => "Unknown schedule".into(),
    }
}
/// "a", "a and b", "a, b and c", as ListFormatter joins them.
pub(super) fn list(items: &[&str]) -> String {
    match items {
        [] => String::new(),
        [one] => (*one).to_owned(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}
fn calendar_time(date: DateTime<Utc>, zone: &str) -> String {
    match zone.parse::<Tz>() {
        Ok(tz) => date
            .with_timezone(&tz)
            .format("%b %-d, %Y at %H:%M")
            .to_string(),
        Err(_) => date.format("%b %-d, %Y at %H:%M UTC").to_string(),
    }
}
/// A run in full, said relative to today ("Today at 09:00", "Tomorrow at
/// 09:00"), in the schedule's zone, naming the zone when it isn't the host's.
pub(super) fn full_time(
    date: DateTime<Utc>,
    zone: &str,
    local_zone: &str,
    now: DateTime<Utc>,
) -> String {
    let Ok(tz) = zone.parse::<Tz>() else {
        return calendar_time(date, zone);
    };
    let local = date.with_timezone(&tz);
    let today = now.with_timezone(&tz).date_naive();
    let days = (local.date_naive() - today).num_days();
    let time = local.format("%H:%M");
    let text = match days {
        0 => format!("Today at {time}"),
        1 => format!("Tomorrow at {time}"),
        -1 => format!("Yesterday at {time}"),
        _ if local.year() == today.year() => format!("{} at {time}", local.format("%b %-d")),
        _ => format!("{} at {time}", local.format("%b %-d, %Y")),
    };
    if zone == local_zone {
        text
    } else {
        format!("{text} ({zone})")
    }
}
/// A row's second line: how often it runs, then its next run or why it won't.
pub(super) fn detail(task: &Value, local_zone: &str, now: DateTime<Utc>) -> String {
    let recurrence = &shown(task)["recurrence"];
    let mut parts = vec![summary(recurrence)];
    if is_active(task) && task["pendingDelivery"].is_null() {
        match parse_date(&task["nextRunAt"]) {
            Ok(next) => parts.push(format!(
                "Next: {}",
                full_time(
                    next,
                    recurrence["timeZoneID"].as_str().unwrap_or("UTC"),
                    local_zone,
                    now
                )
            )),
            Err(_) if task["nextRunAt"].is_null() => parts.push("No future runs".into()),
            Err(_) => {}
        }
    }
    parts.join(" · ")
}

/// Where a schedule's runs go, which the Scheduled panel groups by.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(super) enum Owner {
    Bot(String),
    Thread(String),
    /// A project task: every run starts a new thread there.
    Project(String),
}
pub(super) fn owner(task: &Value, bot_of: &dyn Fn(&str) -> Option<String>) -> Owner {
    match task["threadID"].as_str() {
        Some(thread) => bot_of(thread)
            .map(Owner::Bot)
            .unwrap_or_else(|| Owner::Thread(thread.to_owned())),
        None => Owner::Project(task["projectID"].as_str().unwrap_or_default().to_owned()),
    }
}
pub(super) struct Group<'a> {
    pub owner: Owner,
    pub title: String,
    pub subtitle: Option<String>,
    pub tasks: Vec<&'a Value>,
}
/// When an active schedule runs next; inactive ones sort last.
fn soonest(task: &Value) -> Option<DateTime<Utc>> {
    is_active(task)
        .then(|| parse_date(&task["nextRunAt"]).ok())
        .flatten()
}
fn soonest_first(left: &Value, right: &Value) -> std::cmp::Ordering {
    let key = |task: &Value| (soonest(task).is_none(), soonest(task));
    key(left).cmp(&key(right)).then_with(|| {
        crate::sidebar_preferences::name_order(
            shown(left)["name"].as_str().unwrap_or_default(),
            shown(right)["name"].as_str().unwrap_or_default(),
        )
    })
}
/// Schedules grouped by bot, thread and project: the groups with the soonest
/// run first, and inside each group the soonest schedule first.
pub(super) fn groups<'a>(
    tasks: impl IntoIterator<Item = &'a Value>,
    bot_of: &dyn Fn(&str) -> Option<String>,
    title: &dyn Fn(&Owner) -> (String, Option<String>),
) -> Vec<Group<'a>> {
    let mut order = Vec::new();
    let mut by_owner: HashMap<Owner, Vec<&'a Value>> = HashMap::new();
    for task in tasks {
        let owner = owner(task, bot_of);
        if !by_owner.contains_key(&owner) {
            order.push(owner.clone());
        }
        by_owner.entry(owner).or_default().push(task);
    }
    let mut groups = order
        .into_iter()
        .map(|owner| {
            let mut tasks = by_owner.remove(&owner).unwrap_or_default();
            tasks.sort_by(|a, b| soonest_first(a, b));
            let (title, subtitle) = title(&owner);
            Group {
                owner,
                title,
                subtitle,
                tasks,
            }
        })
        .collect::<Vec<_>>();
    groups.sort_by(|left, right| {
        let first = |group: &Group| group.tasks.first().and_then(|task| soonest(task));
        let key = |group: &Group| (first(group).is_none(), first(group));
        key(left)
            .cmp(&key(right))
            .then_with(|| crate::sidebar_preferences::name_order(&left.title, &right.title))
    });
    groups
}
/// Swift SchedulePresentation.matches: the name, prompt, schedule or where it
/// runs (a pending change's own text while it waits), every word of the query.
pub(super) fn matches(task: &Value, query: &str, place: &str) -> bool {
    let shown = shown(task);
    let text = [
        shown["name"].as_str().unwrap_or_default(),
        shown["prompt"].as_str().unwrap_or_default(),
        &summary(&shown["recurrence"]),
        place,
    ]
    .join("\n")
    .to_lowercase();
    query
        .chars()
        .take(256)
        .collect::<String>()
        .to_lowercase()
        .split_whitespace()
        .all(|term| text.contains(term))
}

pub(super) fn schedule_guard_snapshot(task: &Value) -> Value {
    json!({"threadID":task["threadID"],"projectID":task["projectID"],"rustRevision":task["rustRevision"]})
}

pub(super) fn same_schedule_target(task: &Value, expected: &Value) -> bool {
    task["threadID"] == expected["threadID"]
        && task["projectID"] == expected["projectID"]
        && task["rustRevision"] == expected["rustRevision"]
}
/// `place` names where the schedule's runs go, which search also matches.
pub(super) fn schedule_visible(
    task: &Value,
    global: bool,
    selected: Option<&str>,
    query: &str,
    place: &str,
) -> bool {
    if !global && selected.is_none_or(|id| task["threadID"] != id) {
        return false;
    }
    matches(task, query, place)
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn global_lists_cross_project_and_project_only_schedules_without_a_selected_chat() {
        let tasks = [
            json!({"id":"a","projectID":"one","threadID":"chat-a","name":"Morning review","prompt":"Check build"}),
            json!({"id":"b","projectID":"two","threadID":"chat-b","name":"Evening review","prompt":"Check inbox"}),
            json!({"id":"c","projectID":"two","threadID":null,"name":"New conversation","prompt":"Weekly review"}),
        ];
        assert_eq!(
            tasks
                .iter()
                .filter(|t| schedule_visible(t, true, None, "", ""))
                .count(),
            3
        );
        assert_eq!(
            tasks
                .iter()
                .filter(|t| schedule_visible(t, false, Some("chat-a"), "", ""))
                .count(),
            1
        );
        assert!(
            tasks
                .iter()
                .all(|t| !schedule_visible(t, false, None, "", ""))
        );
        assert_eq!(
            tasks
                .iter()
                .filter(|t| schedule_visible(t, true, Some("chat-a"), "REVIEW inbox", ""))
                .count(),
            1
        );
        assert!(schedule_visible(&tasks[2], true, None, "weekly", ""));
    }
    #[test]
    fn proposed_text_is_filterable_and_cached_target_or_revision_changes_refuse() {
        let task = json!({"threadID":"a","projectID":"one","rustRevision":"r1","name":"Old title","proposal":{"name":"Pending review","prompt":"New content"}});
        assert!(schedule_visible(&task, true, None, "pending content", ""));
        assert!(!schedule_visible(&task, true, None, "old title", ""));
        assert!(same_schedule_target(&task, &task));
        for (field, value) in [
            ("threadID", json!("b")),
            ("projectID", json!("two")),
            ("rustRevision", json!("r2")),
        ] {
            let mut changed = task.clone();
            changed[field] = value;
            assert!(!same_schedule_target(&changed, &task), "{field}");
        }
    }
    fn at(text: &str) -> DateTime<Utc> {
        parse_date(&json!(text)).unwrap()
    }
    #[test]
    fn badges_and_notes_follow_swift_in_order() {
        let approved = |extra: Value| {
            let mut task = json!({"approvalState":"approved","isPaused":false,"nextRunAt":"2026-11-08T09:00:00Z"});
            for (key, value) in extra.as_object().unwrap() {
                task[key] = value.clone();
            }
            task
        };
        let label = |task: &Value| status(task).map(|(label, _)| label);
        assert_eq!(
            label(
                &json!({"approvalState":"awaitingUserApproval","awaitingApproval":true,"rustClaim":{}})
            ),
            Some("Needs approval")
        );
        assert_eq!(
            label(&approved(json!({"activeThreadID":"t"}))),
            Some("Running")
        );
        assert_eq!(
            label(&approved(json!({"pendingDelivery":{}}))),
            Some("Waiting for thread")
        );
        assert_eq!(
            label(&approved(
                json!({"pauseReason":"threadDeleted","isPaused":true})
            )),
            Some("Thread deleted")
        );
        assert_eq!(
            label(&approved(json!({"isPaused":true,"lastOutcome":"failed"}))),
            Some("Failed · Paused")
        );
        assert_eq!(
            label(&approved(json!({"proposal":{"name":"x"}}))),
            Some("Change needs approval")
        );
        assert_eq!(
            label(&approved(json!({"lastOutcome":"missed"}))),
            Some("Missed")
        );
        assert_eq!(
            label(&approved(
                json!({"lastOutcome":"completed","nextRunAt":null})
            )),
            Some("Done")
        );
        assert_eq!(label(&approved(json!({"lastOutcome":"completed"}))), None);
        assert_eq!(
            note(&approved(json!({"pauseReason":"threadArchived"}))).unwrap(),
            "Paused because its thread is archived. It resumes when you unarchive the thread."
        );
        assert_eq!(
            note(&json!({"approvalState":"awaitingUserApproval","awaitingApproval":true})).unwrap(),
            "An agent created this schedule. It runs once you allow it."
        );
        assert_eq!(
            note(&approved(json!({"lastMessage":"Sent"}))).as_deref(),
            Some("Sent")
        );
    }
    #[test]
    fn pause_and_run_now_follow_swift_enablement() {
        let task = |extra: Value| {
            let mut task = json!({"approvalState":"approved","isPaused":false});
            for (key, value) in extra.as_object().unwrap() {
                task[key] = value.clone();
            }
            task
        };
        assert_eq!(actions_enabled(&task(json!({}))), (true, true));
        // A paused schedule can still run now; a running one can't again.
        assert_eq!(
            actions_enabled(&task(json!({"isPaused":true}))),
            (true, true)
        );
        assert_eq!(
            actions_enabled(&task(json!({"rustClaim":{}}))),
            (true, false)
        );
        assert_eq!(
            actions_enabled(&task(json!({"pauseReason":"threadArchived"}))),
            (false, false)
        );
        assert_eq!(
            actions_enabled(&json!({"approvalState":"imported"})),
            (false, false)
        );
    }
    #[test]
    fn filters_include_like_swift_and_this_thread_is_never_saved() {
        let failed = json!({"approvalState":"approved","isPaused":false,"lastOutcome":"failed","threadID":"A"});
        let paused = json!({"approvalState":"approved","isPaused":true,"threadID":"b"});
        assert!(ScheduleFilter::ThisThread.includes(&failed, Some("a")));
        assert!(!ScheduleFilter::ThisThread.includes(&failed, None));
        assert!(ScheduleFilter::Active.includes(&failed, None));
        assert!(ScheduleFilter::Attention.includes(&failed, None));
        assert!(ScheduleFilter::Paused.includes(&paused, None));
        assert!(!ScheduleFilter::Active.includes(&paused, None));
        assert!(!ScheduleFilter::Attention.includes(&paused, None));
        assert_eq!(
            saved_filter(&json!({"scheduleFilter":"paused"})),
            ScheduleFilter::Paused
        );
        assert_eq!(
            saved_filter(&json!({"scheduleFilter":"thisThread"})),
            ScheduleFilter::All
        );
        assert_eq!(saved_filter(&json!({})), ScheduleFilter::All);
    }
    #[test]
    fn summaries_and_next_runs_read_like_swift() {
        assert_eq!(
            summary(&json!({"kind":"daily","hour":9,"minute":5})),
            "Every day at 09:05"
        );
        assert_eq!(
            summary(&json!({"kind":"weekly","weekday":2,"hour":9,"minute":0})),
            "Every Monday at 09:00"
        );
        assert_eq!(
            summary(&json!({"kind":"days","weekdays":[1,6,2],"hour":9,"minute":0})),
            "Mon, Fri and Sun at 09:00"
        );
        assert_eq!(
            summary(&json!({"kind":"interval","intervalMinutes":120})),
            "Every 2 hours"
        );
        assert_eq!(
            summary(&json!({"kind":"interval","intervalMinutes":1440})),
            "Every 24 hours"
        );
        assert_eq!(
            summary(&json!({"kind":"interval","intervalMinutes":45})),
            "Every 45 minutes"
        );
        assert_eq!(
            summary(&json!({"kind":"cron","cron":"0 9 * * 1-5"})),
            "Custom schedule: 0 9 * * 1-5"
        );
        let now = at("2026-11-07T12:00:00Z");
        assert_eq!(
            full_time(at("2026-11-07T15:30:00Z"), "UTC", "UTC", now),
            "Today at 15:30"
        );
        assert_eq!(
            full_time(at("2026-11-08T09:00:00Z"), "UTC", "Asia/Kolkata", now),
            "Tomorrow at 09:00 (UTC)"
        );
        assert_eq!(
            full_time(at("2026-11-20T09:00:00Z"), "UTC", "UTC", now),
            "Nov 20 at 09:00"
        );
        let task = json!({"approvalState":"approved","isPaused":false,"nextRunAt":"2026-11-08T09:00:00Z","recurrence":{"kind":"daily","hour":9,"minute":0,"timeZoneID":"UTC"}});
        assert_eq!(
            detail(&task, "UTC", now),
            "Every day at 09:00 · Next: Tomorrow at 09:00"
        );
        let mut done = task.clone();
        done["nextRunAt"] = Value::Null;
        assert_eq!(
            detail(&done, "UTC", now),
            "Every day at 09:00 · No future runs"
        );
        done["isPaused"] = json!(true);
        assert_eq!(detail(&done, "UTC", now), "Every day at 09:00");
        assert_eq!(list(&["a", "b", "c"]), "a, b and c");
    }
    #[test]
    fn groups_by_destination_soonest_first_and_search_matches_place_and_schedule() {
        let tasks = [
            json!({"id":"1","name":"Later","threadID":"t1","projectID":"p","approvalState":"approved","isPaused":false,"nextRunAt":"2026-11-09T09:00:00Z","recurrence":{"kind":"daily","hour":9,"minute":0}}),
            json!({"id":"2","name":"Soon","threadID":null,"projectID":"p","approvalState":"approved","isPaused":false,"nextRunAt":"2026-11-08T09:00:00Z","recurrence":{"kind":"weekdays","hour":9,"minute":0}}),
            json!({"id":"3","name":"Bot run","threadID":"bot-thread","projectID":"bots","approvalState":"approved","isPaused":true,"nextRunAt":"2026-11-07T13:00:00Z","recurrence":{"kind":"daily","hour":9,"minute":0}}),
            json!({"id":"4","name":"First","threadID":"t1","projectID":"p","approvalState":"approved","isPaused":false,"nextRunAt":"2026-11-08T10:00:00Z","recurrence":{"kind":"daily","hour":10,"minute":0}}),
        ];
        let bot_of = |thread: &str| (thread == "bot-thread").then(|| "bot".to_owned());
        let title = |owner: &Owner| match owner {
            Owner::Bot(_) => ("Helper".to_owned(), Some("Bot".to_owned())),
            Owner::Thread(_) => ("Fix the build".to_owned(), Some("Coincide".to_owned())),
            Owner::Project(_) => (
                "Coincide".to_owned(),
                Some("A new thread each run".to_owned()),
            ),
        };
        let groups = groups(&tasks, &bot_of, &title);
        let shape = groups
            .iter()
            .map(|group| {
                (
                    group.title.as_str(),
                    group
                        .tasks
                        .iter()
                        .map(|t| t["id"].as_str().unwrap())
                        .collect::<Vec<_>>(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            shape,
            [
                ("Coincide", vec!["2"]),
                ("Fix the build", vec!["4", "1"]),
                ("Helper", vec!["3"]),
            ]
        );
        assert!(matches(&tasks[1], "weekdays", ""));
        assert!(matches(&tasks[0], "build later", "Fix the build Coincide"));
        assert!(!matches(&tasks[0], "helper", "Fix the build Coincide"));
    }
}
