//! View scoping never changes a schedule's captured execution target.
use serde_json::{Value, json};

pub(super) fn schedule_guard_snapshot(task: &Value) -> Value {
    json!({"threadID":task["threadID"],"projectID":task["projectID"],"rustRevision":task["rustRevision"]})
}

pub(super) fn same_schedule_target(task: &Value, expected: &Value) -> bool {
    task["threadID"] == expected["threadID"]
        && task["projectID"] == expected["projectID"]
        && task["rustRevision"] == expected["rustRevision"]
}
pub(super) fn schedule_visible(
    task: &Value,
    global: bool,
    selected: Option<&str>,
    query: &str,
) -> bool {
    if !global && selected.is_none_or(|id| task["threadID"] != id) {
        return false;
    }
    let proposed = task
        .get("proposal")
        .filter(|p| p.is_object())
        .unwrap_or(task);
    let text = format!(
        "{} {}",
        proposed["name"].as_str().unwrap_or_default(),
        proposed["prompt"].as_str().unwrap_or_default()
    )
    .to_lowercase();
    query
        .chars()
        .take(256)
        .collect::<String>()
        .to_lowercase()
        .split_whitespace()
        .all(|term| text.contains(term))
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
                .filter(|t| schedule_visible(t, true, None, ""))
                .count(),
            3
        );
        assert_eq!(
            tasks
                .iter()
                .filter(|t| schedule_visible(t, false, Some("chat-a"), ""))
                .count(),
            1
        );
        assert!(tasks.iter().all(|t| !schedule_visible(t, false, None, "")));
        assert_eq!(
            tasks
                .iter()
                .filter(|t| schedule_visible(t, true, Some("chat-a"), "REVIEW inbox"))
                .count(),
            1
        );
        assert!(schedule_visible(&tasks[2], true, None, "weekly"));
    }
    #[test]
    fn proposed_text_is_filterable_and_cached_target_or_revision_changes_refuse() {
        let task = json!({"threadID":"a","projectID":"one","rustRevision":"r1","name":"Old title","proposal":{"name":"Pending review","prompt":"New content"}});
        assert!(schedule_visible(&task, true, None, "pending content"));
        assert!(!schedule_visible(&task, true, None, "old title"));
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
}
