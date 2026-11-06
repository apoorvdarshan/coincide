//! Pure sidebar projection. Input search/archive filtering and summary order stay authoritative.
use coincide_core::{bot_runtime::BOTS_PROJECT_ID, store::ThreadSummary};
use std::collections::HashSet;

pub(super) const NO_PROJECT: &str = "00000000-0000-0000-0000-000000000000";
pub(super) fn project_key(id: &str) -> &str {
    if id.is_empty() || id == NO_PROJECT {
        NO_PROJECT
    } else if id.eq_ignore_ascii_case(BOTS_PROJECT_ID) {
        BOTS_PROJECT_ID
    } else {
        id
    }
}
pub(super) struct Section<'a> {
    /// None identifies the Pinned presentation section, never a synthetic project.
    pub project_id: Option<String>,
    pub name: String,
    pub threads: Vec<&'a ThreadSummary>,
}
pub(super) fn project<'a>(
    threads: &'a [ThreadSummary],
    projects: Vec<(String, String)>,
    selected_project: Option<&str>,
    show_snoozed: bool,
    now: f64,
) -> Vec<Section<'a>> {
    let mut seen = HashSet::new();
    let visible: Vec<_> = threads
        .iter()
        .filter(|thread| {
            selected_project.is_none_or(|id| project_key(&thread.project_id) == id)
                && (show_snoozed || thread.snoozed_until.is_none_or(|date| date <= now))
                && seen.insert(thread.id.as_str())
        })
        .collect();
    let mut sections = Vec::new();
    let pinned: Vec<_> = visible
        .iter()
        .copied()
        .filter(|thread| thread.pinned)
        .collect();
    if !pinned.is_empty() {
        sections.push(Section {
            project_id: None,
            name: "Pinned".into(),
            threads: pinned,
        });
    }
    let mut known = HashSet::new();
    let mut groups: Vec<_> = projects
        .into_iter()
        .filter(|(id, _)| {
            !id.is_empty()
                && id != NO_PROJECT
                && !id.eq_ignore_ascii_case(BOTS_PROJECT_ID)
                && known.insert(id.clone())
        })
        .collect();
    groups.push((BOTS_PROJECT_ID.into(), "Bots".into()));
    groups.push((NO_PROJECT.into(), "Chats".into()));
    for thread in &visible {
        let id = project_key(&thread.project_id);
        if !groups.iter().any(|(known, _)| known == id) {
            groups.push((id.into(), "Unavailable project".into()));
        }
    }
    for (id, name) in groups {
        let threads: Vec<_> = visible
            .iter()
            .copied()
            .filter(|thread| !thread.pinned && project_key(&thread.project_id) == id)
            .collect();
        if !threads.is_empty() {
            sections.push(Section {
                project_id: Some(id),
                name,
                threads,
            });
        }
    }
    sections
}
#[cfg(test)]
mod tests {
    use super::*;
    fn row(id: &str, project: &str, pinned: bool) -> ThreadSummary {
        ThreadSummary {
            id: id.into(),
            title: id.into(),
            project_id: project.into(),
            archived: false,
            pinned,
            snoozed_until: None,
        }
    }
    fn ids(sections: &[Section<'_>]) -> Vec<String> {
        sections
            .iter()
            .flat_map(|section| section.threads.iter().map(|thread| thread.id.clone()))
            .collect()
    }
    #[test]
    fn pinned_threads_appear_once_above_projects_and_chats_in_input_order() {
        let rows = vec![
            row("chat-pin", "", true),
            row("project-pin", "p", true),
            row("project", "p", false),
            row("chat", NO_PROJECT, false),
            row("orphan-pin", "missing", true),
        ];
        let sections = project(&rows, vec![("p".into(), "Project".into())], None, false, 0.);
        assert_eq!(sections[0].name, "Pinned");
        assert!(sections[0].project_id.is_none());
        assert_eq!(
            sections[0]
                .threads
                .iter()
                .map(|t| t.id.as_str())
                .collect::<Vec<_>>(),
            ["chat-pin", "project-pin", "orphan-pin"]
        );
        assert_eq!(
            ids(&sections),
            ["chat-pin", "project-pin", "orphan-pin", "project", "chat"]
        );
        assert_eq!(sections.last().unwrap().name, "Chats");
    }
    #[test]
    fn project_and_snooze_filters_apply_before_pinned_projection() {
        let mut snoozed = row("hidden-pin", "p", true);
        snoozed.snoozed_until = Some(20.);
        let rows = vec![
            row("pin", "p", true),
            snoozed,
            row("other-pin", "other", true),
            row("plain", "p", false),
        ];
        assert_eq!(
            ids(&project(&rows, vec![], Some("p"), false, 10.)),
            ["pin", "plain"]
        );
        assert_eq!(
            ids(&project(&rows, vec![], Some("p"), true, 10.)),
            ["pin", "hidden-pin", "plain"]
        );
        assert_eq!(
            ids(&project(&rows, vec![], Some("p"), false, 21.)),
            ["pin", "hidden-pin", "plain"]
        );
        assert!(project(&rows, vec![], Some(NO_PROJECT), true, 10.).is_empty());
    }
    #[test]
    fn upstream_search_archive_subset_is_not_resurrected_and_selected_identity_is_unchanged() {
        let mut archived = row("visible-archived-pin", "missing", true);
        archived.archived = true;
        let rows = vec![archived, row("selected", "missing", false)];
        let before = serde_json::to_value(&rows).unwrap();
        let sections = project(&rows, vec![], None, false, 0.);
        assert_eq!(ids(&sections), ["visible-archived-pin", "selected"]);
        assert_eq!(sections[1].name, "Unavailable project");
        assert_eq!(sections[1].threads[0].id, "selected");
        assert_eq!(serde_json::to_value(&rows).unwrap(), before);
        // Hidden search/archive summaries are absent from the supplied subset.
        let filtered = &rows[1..];
        assert_eq!(
            ids(&project(filtered, vec![], None, false, 0.)),
            ["selected"]
        );
    }
    #[test]
    fn empty_and_unknown_projects_and_bots_never_lose_or_duplicate_rows() {
        let rows = vec![
            row("empty", "", false),
            row("orphan", "unknown", false),
            row("bot", &BOTS_PROJECT_ID.to_ascii_lowercase(), false),
            row("empty", "", false),
        ];
        let sections = project(
            &rows,
            vec![("unused".into(), "Unused".into())],
            None,
            false,
            0.,
        );
        assert_eq!(ids(&sections), ["bot", "empty", "orphan"]);
        assert_eq!(
            sections.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
            ["Bots", "Chats", "Unavailable project"]
        );
        assert_eq!(rows[0].project_id, "");
    }
    #[test]
    fn declared_project_order_is_stable_and_duplicate_project_metadata_does_not_duplicate_ids() {
        let rows = vec![row("a", "first", false), row("b", "second", false)];
        let sections = project(
            &rows,
            vec![
                ("second".into(), "Second".into()),
                ("first".into(), "First".into()),
                ("first".into(), "Duplicate".into()),
            ],
            None,
            false,
            0.,
        );
        assert_eq!(ids(&sections), ["b", "a"]);
        assert_eq!(sections.len(), 2);
    }
}
