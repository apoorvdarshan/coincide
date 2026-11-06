//! Sidebar term search composes the existing literal transcript index with
//! project/branch metadata. CLI threads.list keeps its original literal query.
use super::*;
use std::collections::HashSet;
pub(super) fn terms_match(value: &str, query: &str) -> bool {
    let value = value.to_lowercase();
    query
        .split_whitespace()
        .all(|term| value.contains(&term.to_lowercase()))
}
pub(super) fn read(
    engine: &SharedEngine,
    query: &str,
    include_archived: bool,
    projects: &[Value],
) -> Result<(Vec<ThreadSummary>, Vec<ThreadSummary>)> {
    let owner = try_state(engine)?;
    let all = owner.store.summaries("", true)?;
    let terms = query
        .split_whitespace()
        .map(str::to_lowercase)
        .collect::<Vec<_>>();
    anyhow::ensure!(terms.len() <= 32, "Use at most 32 search terms");
    let matches = terms
        .iter()
        .map(|term| {
            owner
                .store
                .summaries(term, include_archived)
                .map(|rows| rows.into_iter().map(|row| row.id).collect::<HashSet<_>>())
        })
        .collect::<Result<Vec<_>>>()?;
    let visible = filter(&all, &terms, &matches, include_archived, projects);
    Ok((visible, all))
}
fn filter(
    all: &[ThreadSummary],
    terms: &[String],
    matches: &[HashSet<String>],
    include_archived: bool,
    projects: &[Value],
) -> Vec<ThreadSummary> {
    all.iter()
        .filter(|thread| {
            if thread.archived && !include_archived {
                return false;
            }
            let project = projects
                .iter()
                .find(|project| project["id"] == thread.project_id)
                .map(|project| text(project, "name"))
                .unwrap_or_default();
            let branch = thread
                .navigation
                .as_ref()
                .and_then(|meta| meta.branch.as_deref())
                .unwrap_or("")
                .to_lowercase();
            let project = project.to_lowercase();
            terms.iter().enumerate().all(|(index, term)| {
                project.contains(term)
                    || branch.contains(term)
                    || matches[index].contains(&thread.id)
            })
        })
        .cloned()
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn search_combines_terms_across_transcript_project_and_branch_without_resurrecting_archive() {
        let row = |id: &str, archived| {
            serde_json::from_value::<ThreadSummary>(json!({"id":id,"title":id,"project_id":"p","pinned":false,"archived":archived,"snoozed_until":null,"navigation":{"branch":"feature/Sidebar"}})).unwrap()
        };
        let all = vec![
            row("match", false),
            row("archived", true),
            row("missing", false),
        ];
        let terms = vec!["coincide".into(), "sidebar".into(), "needle".into()];
        let matches = vec![
            HashSet::new(),
            HashSet::new(),
            HashSet::from(["match".into(), "archived".into()]),
        ];
        let projects = vec![json!({"id":"p","name":"Coincide"})];
        assert_eq!(
            filter(&all, &terms, &matches, false, &projects)
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["match"]
        );
        assert_eq!(filter(&all, &terms, &matches, true, &projects).len(), 2);
        assert!(terms_match("Project 12", "12 project"));
        assert!(!terms_match("Project 12", "12 missing"));
    }
}
