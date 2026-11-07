//! How the toolbar presents a thread's schedules, as Swift's
//! `SchedulePresentation` and `ScheduledTasks.nextRun(inThread:)` do. Times use
//! the 24-hour form the Rust schedule editor shows, not the system locale.
use crate::scheduling::parse_date;
use chrono::{DateTime, Offset, TimeZone, Utc};
use chrono_tz::Tz;
use serde_json::Value;

/// Allowed and not paused: a schedule that runs.
pub fn is_active(task: &Value) -> bool {
    task["isPaused"] != true && task["awaitingApproval"] != true
}

fn date(task: &Value, key: &str) -> Option<DateTime<Utc>> {
    task.get(key)
        .filter(|value| !value.is_null())
        .and_then(|value| parse_date(value).ok())
}

fn same_id(left: &Value, right: &str) -> bool {
    left.as_str()
        .is_some_and(|left| left.eq_ignore_ascii_case(right))
}

/// The open thread's next run among its active schedules: a delivery already
/// due first, else the next occurrence.
pub fn next_run_in_thread<'a>(
    tasks: &'a [Value],
    thread: &str,
) -> Option<(DateTime<Utc>, &'a Value)> {
    tasks
        .iter()
        .filter(|task| same_id(&task["threadID"], thread) && is_active(task))
        .filter_map(|task| {
            date(task, "pendingDelivery")
                .or_else(|| date(task, "nextRunAt"))
                .map(|when| (when, task))
        })
        .min_by_key(|(when, _)| *when)
}

/// "9:00" today, "Tue 9:00" within the week, otherwise "Nov 9".
pub fn compact_time<T: TimeZone>(date: DateTime<Utc>, now: &DateTime<T>) -> String {
    let local = date.with_timezone(&now.timezone()).naive_local();
    let time = local.format("%-H:%M").to_string();
    let days = (local.date() - now.date_naive()).num_days();
    if days == 0 {
        time
    } else if (1..=6).contains(&days) {
        format!("{} {time}", local.format("%a"))
    } else {
        local.format("%b %-d").to_string()
    }
}

/// The next run in full, in the schedule's own zone, named when it isn't the
/// Mac's (compared by offset at that instant).
pub fn full_time<T: TimeZone>(date: DateTime<Utc>, zone_id: &str, now: &DateTime<T>) -> String {
    let Ok(zone) = zone_id.parse::<Tz>() else {
        return compact_time(date, now);
    };
    let local = date.with_timezone(&zone);
    let today = now.with_timezone(&zone).date_naive();
    let day = match (local.date_naive() - today).num_days() {
        0 => "Today".to_owned(),
        1 => "Tomorrow".to_owned(),
        -1 => "Yesterday".to_owned(),
        _ => local.format("%b %-d, %Y").to_string(),
    };
    let text = format!("{day} at {}", local.format("%-H:%M"));
    let host = date.with_timezone(&now.timezone()).offset().fix();
    if local.offset().fix() == host {
        text
    } else {
        format!("{text} ({zone_id})")
    }
}

/// The clock's tooltip for a thread's schedules ("2 scheduled tasks", then the
/// next run or "All paused"); None when the thread has none.
pub fn thread_tooltip<T: TimeZone>(
    tasks: &[Value],
    thread: &str,
    now: &DateTime<T>,
) -> Option<String> {
    let tasks: Vec<&Value> = tasks
        .iter()
        .filter(|task| same_id(&task["threadID"], thread))
        .collect();
    if tasks.is_empty() {
        return None;
    }
    let mut lines = vec![if tasks.len() == 1 {
        "1 scheduled task".to_owned()
    } else {
        format!("{} scheduled tasks", tasks.len())
    }];
    let active: Vec<&&Value> = tasks.iter().filter(|task| is_active(task)).collect();
    if let Some((when, task)) = active
        .iter()
        .filter_map(|task| date(task, "nextRunAt").map(|when| (when, task)))
        .min_by_key(|(when, _)| *when)
    {
        let zone = task["recurrence"]["timeZoneID"].as_str().unwrap_or("UTC");
        lines.push(format!(
            "Next: {}, {}",
            task["name"].as_str().unwrap_or("Scheduled task"),
            full_time(when, zone, now)
        ));
    } else if active.is_empty() {
        lines.push("All paused".into());
    }
    Some(lines.join("\n"))
}

/// The toolbar clock's next run for `thread` in the host's zone, now.
pub fn next_run_label(tasks: &[Value], thread: &str) -> Option<String> {
    let (when, _) = next_run_in_thread(tasks, thread)?;
    Some(compact_time(when, &chrono::Local::now()))
}

/// The toolbar clock's tooltip for `thread`, now.
pub fn thread_tooltip_now(tasks: &[Value], thread: &str) -> Option<String> {
    thread_tooltip(tasks, thread, &chrono::Local::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;
    use serde_json::json;

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn compact_time_reads_today_this_week_or_a_date() {
        let zone = FixedOffset::east_opt(0).unwrap();
        let now = at("2026-11-07T08:00:00Z").with_timezone(&zone);
        assert_eq!(compact_time(at("2026-11-07T09:00:00Z"), &now), "9:00");
        assert_eq!(compact_time(at("2026-11-10T21:30:00Z"), &now), "Tue 21:30");
        assert_eq!(compact_time(at("2026-11-20T09:00:00Z"), &now), "Nov 20");
        // The host zone decides the day.
        let east = FixedOffset::east_opt(10 * 3600).unwrap();
        assert_eq!(
            compact_time(at("2026-11-07T20:00:00Z"), &now.with_timezone(&east)),
            "Sun 6:00"
        );
    }

    #[test]
    fn next_run_takes_the_due_delivery_of_active_thread_schedules() {
        let tasks = vec![
            json!({"threadID":"T","name":"Later","nextRunAt":"2026-11-08T09:00:00Z"}),
            json!({"threadID":"t","name":"Due","nextRunAt":"2026-11-09T09:00:00Z","pendingDelivery":"2026-11-07T07:00:00Z"}),
            json!({"threadID":"T","name":"Paused","isPaused":true,"nextRunAt":"2026-11-07T06:00:00Z"}),
            json!({"threadID":"T","name":"Proposed","awaitingApproval":true,"nextRunAt":"2026-11-07T06:00:00Z"}),
            json!({"threadID":"other","name":"Other","nextRunAt":"2026-11-07T05:00:00Z"}),
        ];
        let (when, task) = next_run_in_thread(&tasks, "T").unwrap();
        assert_eq!(when, at("2026-11-07T07:00:00Z"));
        assert_eq!(task["name"], "Due");
        assert!(next_run_in_thread(&tasks, "missing").is_none());
    }

    #[test]
    fn tooltip_counts_schedules_and_names_the_next_or_all_paused() {
        let now = at("2026-11-07T08:00:00Z").with_timezone(&FixedOffset::east_opt(0).unwrap());
        let tasks = vec![
            json!({"threadID":"T","name":"Standup","nextRunAt":"2026-11-07T09:00:00Z","recurrence":{"timeZoneID":"UTC"}}),
            json!({"threadID":"T","name":"Review","nextRunAt":"2026-11-08T09:00:00Z","recurrence":{"timeZoneID":"Asia/Tokyo"}}),
        ];
        assert_eq!(
            thread_tooltip(&tasks, "T", &now).unwrap(),
            "2 scheduled tasks\nNext: Standup, Today at 9:00"
        );
        let paused = vec![json!({"threadID":"T","name":"Standup","isPaused":true})];
        assert_eq!(
            thread_tooltip(&paused, "T", &now).unwrap(),
            "1 scheduled task\nAll paused"
        );
        assert!(thread_tooltip(&tasks, "none", &now).is_none());
        assert_eq!(
            full_time(at("2026-11-08T09:00:00Z"), "Asia/Tokyo", &now),
            "Tomorrow at 18:00 (Asia/Tokyo)"
        );
    }
}
