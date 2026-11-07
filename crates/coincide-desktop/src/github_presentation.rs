//! How pull request states, checks and reviews look in the panel, after Swift's
//! PullRequestPresentation and CoincideKit's PullRequestJSON: a symbol, its
//! tone and what it says. Pure functions of the validated `gh` JSON.
use gpui_kit::assets::IconName;
use serde_json::Value;
use std::collections::HashMap;

/// The theme color a glyph takes; the panel resolves it for light and dark.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Tone {
    Success,
    Failure,
    Warning,
    Merged,
    /// Secondary text, as drafts and closed pull requests are.
    Muted,
    /// Tertiary text: skipped and neutral checks, a review still to come.
    Faint,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Glyph {
    pub icon: IconName,
    pub tone: Tone,
    pub label: &'static str,
}
const fn glyph(icon: IconName, tone: Tone, label: &'static str) -> Glyph {
    Glyph { icon, tone, label }
}

/// Open, draft, merged or closed.
pub(super) fn state(pr: &Value) -> Glyph {
    match pr["state"].as_str() {
        Some("MERGED") => glyph(IconName::GitMerge, Tone::Merged, "Merged"),
        Some("CLOSED") => glyph(IconName::CircleX, Tone::Muted, "Closed"),
        _ if pr["isDraft"] == true => glyph(IconName::GitPullRequestDraft, Tone::Muted, "Draft"),
        _ => glyph(IconName::GitPullRequest, Tone::Success, "Open"),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ChecksState {
    Passing,
    Failing,
    Pending,
}
impl ChecksState {
    pub fn glyph(self) -> Glyph {
        match self {
            Self::Passing => glyph(
                IconName::CircleCheck,
                Tone::Success,
                "All checks have passed",
            ),
            Self::Failing => glyph(
                IconName::CircleX,
                Tone::Failure,
                "Some checks were not successful",
            ),
            Self::Pending => glyph(
                IconName::CircleDot,
                Tone::Warning,
                "Some checks haven’t completed yet",
            ),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ReviewDecision {
    Approved,
    ChangesRequested,
    ReviewRequired,
}
impl ReviewDecision {
    pub fn glyph(self) -> Glyph {
        match self {
            Self::Approved => glyph(IconName::UserCheck, Tone::Success, "Approved"),
            Self::ChangesRequested => glyph(IconName::UserX, Tone::Warning, "Changes requested"),
            Self::ReviewRequired => glyph(IconName::User, Tone::Faint, "Awaiting review"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CheckStatus {
    Success,
    Failure,
    Cancelled,
    Pending,
    /// Waiting on someone, such as a fork's workflow run a maintainer must approve.
    ActionRequired,
    Skipped,
    Neutral,
}
impl CheckStatus {
    fn is_failure(self) -> bool {
        matches!(self, Self::Failure | Self::Cancelled)
    }
    pub fn glyph(self) -> Glyph {
        match self {
            Self::Success => glyph(IconName::CircleCheck, Tone::Success, "Passed"),
            Self::Failure => glyph(IconName::CircleX, Tone::Failure, "Failed"),
            Self::Cancelled => glyph(IconName::CircleX, Tone::Failure, "Cancelled"),
            Self::Pending => glyph(IconName::CircleDot, Tone::Warning, "In progress"),
            Self::ActionRequired => {
                glyph(IconName::CircleAlert, Tone::Warning, "Awaiting approval")
            }
            Self::Skipped => glyph(IconName::CircleSlash, Tone::Faint, "Skipped"),
            Self::Neutral => glyph(IconName::CircleDashed, Tone::Faint, "Neutral"),
        }
    }
}

/// One check run or commit status on the head commit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Check {
    pub name: String,
    pub status: CheckStatus,
    /// The run's page, when GitHub links one (already https-only from Core).
    pub url: Option<String>,
}

fn text(value: &Value) -> Option<&str> {
    value
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

/// A check run is pending until it completes, then its conclusion counts; a
/// commit status has only its state.
fn status(check: &Value) -> CheckStatus {
    if let Some(status) = text(&check["status"])
        && !status.eq_ignore_ascii_case("COMPLETED")
    {
        return CheckStatus::Pending;
    }
    let outcome = text(&check["conclusion"])
        .or_else(|| text(&check["state"]))
        .map(str::to_ascii_uppercase);
    match outcome.as_deref() {
        Some("SUCCESS") => CheckStatus::Success,
        Some("ACTION_REQUIRED") => CheckStatus::ActionRequired,
        Some("FAILURE" | "ERROR" | "TIMED_OUT" | "STARTUP_FAILURE") => CheckStatus::Failure,
        Some("CANCELLED") => CheckStatus::Cancelled,
        Some("SKIPPED") => CheckStatus::Skipped,
        Some("PENDING" | "EXPECTED") => CheckStatus::Pending,
        _ => CheckStatus::Neutral,
    }
}

/// GitHub writes `0001-01-01T00:00:00Z` for a time not reached yet.
fn timestamp(value: &Value) -> Option<&str> {
    text(value).filter(|at| !at.starts_with("0001-"))
}

/// Every check once: a rerun, or a check both a push and a pull request
/// workflow ran, is reported again, so only the newest run of each workflow's
/// check stays, a running one counting as newest. A name more than one
/// workflow uses is shown with its workflow. Failing checks come first.
pub(super) fn checks(rollup: &Value) -> Vec<Check> {
    struct Entry {
        check: Check,
        workflow: String,
        order: usize,
        at: String,
    }
    let mut newest: HashMap<String, Entry> = HashMap::new();
    for (order, raw) in rollup.as_array().into_iter().flatten().enumerate() {
        let Some(name) = text(&raw["name"]).or_else(|| text(&raw["context"])) else {
            continue;
        };
        let status = status(raw);
        let workflow = text(&raw["workflowName"]).unwrap_or_default().to_owned();
        // ISO 8601 times in one format sort as text.
        let at = if status == CheckStatus::Pending {
            "9999".to_owned()
        } else {
            timestamp(&raw["completedAt"])
                .or_else(|| timestamp(&raw["startedAt"]))
                .unwrap_or_default()
                .to_owned()
        };
        let url = text(&raw["detailsUrl"])
            .or_else(|| text(&raw["targetUrl"]))
            .map(str::to_owned);
        let key = format!("{workflow}\0{name}");
        if newest.get(&key).is_some_and(|kept| kept.at > at) {
            continue;
        }
        // A later run keeps the place of the first, so the list doesn't
        // reorder as checks rerun.
        let order = newest.get(&key).map_or(order, |kept| kept.order);
        newest.insert(
            key,
            Entry {
                check: Check {
                    name: name.to_owned(),
                    status,
                    url,
                },
                workflow,
                order,
                at,
            },
        );
    }
    let mut survivors = newest.into_values().collect::<Vec<_>>();
    survivors.sort_by_key(|entry| entry.order);
    let mut counts = HashMap::<String, usize>::new();
    for entry in &survivors {
        *counts.entry(entry.check.name.clone()).or_default() += 1;
    }
    let named = survivors
        .into_iter()
        .map(|entry| {
            let mut check = entry.check;
            if !entry.workflow.is_empty() && counts[&check.name] > 1 {
                check.name = format!("{} / {}", entry.workflow, check.name);
            }
            check
        })
        .collect::<Vec<_>>();
    let (mut failing, passing): (Vec<_>, Vec<_>) = named
        .into_iter()
        .partition(|check| check.status.is_failure());
    failing.extend(passing);
    failing
}

/// Any failure fails the pull request; otherwise anything unfinished keeps it
/// pending. Nameless entries still count. All skipped or neutral is nothing.
pub(super) fn checks_state(rollup: &Value) -> Option<ChecksState> {
    let mut statuses = checks(rollup)
        .into_iter()
        .map(|check| check.status)
        .collect::<Vec<_>>();
    statuses.extend(
        rollup
            .as_array()
            .into_iter()
            .flatten()
            .filter(|raw| text(&raw["name"]).is_none() && text(&raw["context"]).is_none())
            .map(status),
    );
    if statuses.iter().any(|status| status.is_failure()) {
        Some(ChecksState::Failing)
    } else if statuses
        .iter()
        .any(|status| matches!(status, CheckStatus::Pending | CheckStatus::ActionRequired))
    {
        Some(ChecksState::Pending)
    } else {
        statuses
            .contains(&CheckStatus::Success)
            .then_some(ChecksState::Passing)
    }
}

/// GitHub's reviewDecision only counts reviews its branch rules require, so a
/// repository without them reports none even after an approval; the latest
/// reviews fill in.
pub(super) fn review_decision(pr: &Value) -> Option<ReviewDecision> {
    let summarized = match text(&pr["reviewDecision"])
        .map(str::to_ascii_uppercase)
        .as_deref()
    {
        Some("APPROVED") => Some(ReviewDecision::Approved),
        Some("CHANGES_REQUESTED") => Some(ReviewDecision::ChangesRequested),
        Some("REVIEW_REQUIRED") => Some(ReviewDecision::ReviewRequired),
        _ => None,
    };
    if matches!(
        summarized,
        Some(ReviewDecision::Approved | ReviewDecision::ChangesRequested)
    ) {
        return summarized;
    }
    let states = pr["latestReviews"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|review| text(&review["state"]).map(str::to_ascii_uppercase))
        .collect::<Vec<_>>();
    if states.iter().any(|state| state == "CHANGES_REQUESTED") {
        Some(ReviewDecision::ChangesRequested)
    } else if states.iter().any(|state| state == "APPROVED") {
        Some(ReviewDecision::Approved)
    } else {
        summarized
    }
}

/// Swift PullRequestDetail.canMerge: the merge button needs an open, ready,
/// mergeable pull request whose checks and reviews don't hold it up.
pub(super) fn can_merge(pr: &Value) -> bool {
    pr["state"] == "OPEN"
        && pr["isDraft"] == false
        && pr["headRefOid"]
            .as_str()
            .is_some_and(|head| !head.is_empty())
        && pr["mergeable"]
            .as_str()
            .is_some_and(|value| value.eq_ignore_ascii_case("MERGEABLE"))
        && !matches!(
            checks_state(&pr["statusCheckRollup"]),
            Some(ChecksState::Failing | ChecksState::Pending)
        )
        && !matches!(
            review_decision(pr),
            Some(ReviewDecision::ChangesRequested | ReviewDecision::ReviewRequired)
        )
}

/// The open pull request conflicts with its base ("Conflicts with main").
pub(super) fn conflicting(pr: &Value) -> bool {
    pr["state"] == "OPEN"
        && pr["mergeable"]
            .as_str()
            .is_some_and(|value| value.eq_ignore_ascii_case("CONFLICTING"))
}

/// A review's state as the detail lists it.
pub(super) fn review_state(state: &str) -> &'static str {
    match state {
        "APPROVED" => "Approved",
        "CHANGES_REQUESTED" => "Changes requested",
        "DISMISSED" => "Dismissed",
        _ => "Commented",
    }
}

/// The description without HTML comments, which pull request templates leave
/// as instructions to the author and GitHub never shows (Swift
/// PullRequestBody.displayMarkdown). An unclosed comment runs to the end.
pub(super) fn display_markdown(body: &str) -> String {
    let mut shown = String::with_capacity(body.len());
    let mut rest = body;
    while let Some(start) = rest.find("<!--") {
        shown.push_str(&rest[..start]);
        rest = match rest[start + 4..].find("-->") {
            Some(end) => &rest[start + 4 + end + 3..],
            None => "",
        };
    }
    shown.push_str(rest);
    shown.trim().to_owned()
}

/// "now", "5m", "3h", "2d", "1w": how long ago the pull request changed.
pub(super) fn age(updated_at: &Value, now_unix: f64) -> String {
    coincide_core::scheduling::parse_date(updated_at)
        .ok()
        .map(|date| crate::navigation::sidebar_age(Some(date.timestamp() as f64), now_unix))
        .unwrap_or_default()
}

/// The second line of a row: "#12 · Draft · octocat · feature/branch".
pub(super) fn row_meta(pr: &Value) -> String {
    let mut meta = vec![format!("#{}", pr["number"].as_u64().unwrap_or(0))];
    if pr["isDraft"] == true {
        meta.push("Draft".into());
    }
    if let Some(author) = text(&pr["author"]["login"]) {
        meta.push(author.to_owned());
    }
    meta.push(pr["headRefName"].as_str().unwrap_or_default().to_owned());
    meta.join(" · ")
}

/// "Open · #12 by octocat", the detail's state line.
pub(super) fn byline(pr: &Value) -> String {
    let number = pr["number"].as_u64().unwrap_or(0);
    let by = match text(&pr["author"]["login"]) {
        Some(author) => format!("#{number} by {author}"),
        None => format!("#{number}"),
    };
    format!("{} · {by}", state(pr).label)
}

/// "+12  −3  4 files", once the detail has its counts.
pub(super) fn stats(pr: &Value) -> Option<String> {
    let (additions, deletions) = (pr["additions"].as_u64()?, pr["deletions"].as_u64()?);
    let mut parts = vec![format!("+{additions}"), format!("−{deletions}")];
    if let Some(files) = pr["changedFiles"].as_u64() {
        parts.push(format!("{files} files"));
    }
    Some(parts.join("  "))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum MergeMethod {
    Merge,
    Squash,
    Rebase,
}
impl MergeMethod {
    pub fn parse(wire: &str) -> Option<Self> {
        match wire {
            "merge" => Some(Self::Merge),
            "squash" => Some(Self::Squash),
            "rebase" => Some(Self::Rebase),
            _ => None,
        }
    }
    pub fn wire(self) -> &'static str {
        match self {
            Self::Merge => "merge",
            Self::Squash => "squash",
            Self::Rebase => "rebase",
        }
    }
    /// The method as GitHub's merge button names it.
    pub fn title(self) -> &'static str {
        match self {
            Self::Merge => "Create a Merge Commit",
            Self::Squash => "Squash and Merge",
            Self::Rebase => "Rebase and Merge",
        }
    }
    /// The confirmation's question for pull request `number`.
    pub fn question(self, number: u64) -> String {
        match self {
            Self::Merge => format!("Merge pull request #{number} with a merge commit?"),
            Self::Squash => format!("Squash and merge pull request #{number}?"),
            Self::Rebase => format!("Rebase and merge pull request #{number}?"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn state_glyphs_follow_swift_for_open_draft_merged_and_closed() {
        let label =
            |state: &str, draft: bool| super::state(&json!({"state":state,"isDraft":draft})).label;
        assert_eq!(label("OPEN", false), "Open");
        assert_eq!(label("OPEN", true), "Draft");
        assert_eq!(label("MERGED", false), "Merged");
        assert_eq!(label("CLOSED", true), "Closed");
        assert_eq!(super::state(&json!({"state":"MERGED"})).tone, Tone::Merged);
    }
    #[test]
    fn checks_keep_the_newest_run_name_shared_workflows_and_put_failures_first() {
        let rollup = json!([
            {"name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-11-01T09:00:00Z"},
            {"name":"test","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-11-01T09:00:00Z"},
            // A rerun of lint that failed later replaces the earlier pass in place.
            {"name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-11-01T10:00:00Z"},
            {"name":"test","workflowName":"Nightly","status":"IN_PROGRESS","conclusion":null,"completedAt":"0001-01-01T00:00:00Z"},
            {"context":"ci/legacy","state":"SUCCESS","targetUrl":"https://ci.example/run"},
            {"state":"PENDING"}
        ]);
        let checks = checks(&rollup);
        let names = checks
            .iter()
            .map(|check| check.name.as_str())
            .collect::<Vec<_>>();
        assert_eq!(names, ["lint", "CI / test", "Nightly / test", "ci/legacy"]);
        assert_eq!(checks[0].status, CheckStatus::Failure);
        assert_eq!(checks[2].status, CheckStatus::Pending);
        assert_eq!(checks[3].url.as_deref(), Some("https://ci.example/run"));
        assert_eq!(checks_state(&rollup), Some(ChecksState::Failing));
        // A nameless pending status still holds the pull request up.
        assert_eq!(
            checks_state(
                &json!([{"name":"ok","status":"COMPLETED","conclusion":"SUCCESS"},{"state":"PENDING"}])
            ),
            Some(ChecksState::Pending)
        );
        assert_eq!(
            checks_state(&json!([{"name":"ok","status":"COMPLETED","conclusion":"SKIPPED"}])),
            None
        );
        assert_eq!(checks_state(&json!([])), None);
    }
    #[test]
    fn check_statuses_map_like_swift() {
        for (check, expected) in [
            (json!({"status":"QUEUED"}), CheckStatus::Pending),
            (
                json!({"status":"COMPLETED","conclusion":"TIMED_OUT"}),
                CheckStatus::Failure,
            ),
            (
                json!({"status":"COMPLETED","conclusion":"CANCELLED"}),
                CheckStatus::Cancelled,
            ),
            (
                json!({"status":"COMPLETED","conclusion":"ACTION_REQUIRED"}),
                CheckStatus::ActionRequired,
            ),
            (json!({"state":"EXPECTED"}), CheckStatus::Pending),
            (json!({"state":"ERROR"}), CheckStatus::Failure),
            (
                json!({"status":"COMPLETED","conclusion":"STALE"}),
                CheckStatus::Neutral,
            ),
        ] {
            assert_eq!(status(&check), expected, "{check}");
        }
        assert_eq!(
            CheckStatus::ActionRequired.glyph().label,
            "Awaiting approval"
        );
    }
    #[test]
    fn latest_reviews_fill_in_a_missing_review_decision() {
        assert_eq!(
            review_decision(&json!({"reviewDecision":"","latestReviews":[{"state":"APPROVED"}]})),
            Some(ReviewDecision::Approved)
        );
        assert_eq!(
            review_decision(
                &json!({"reviewDecision":"REVIEW_REQUIRED","latestReviews":[{"state":"APPROVED"},{"state":"CHANGES_REQUESTED"}]})
            ),
            Some(ReviewDecision::ChangesRequested)
        );
        assert_eq!(
            review_decision(
                &json!({"reviewDecision":"REVIEW_REQUIRED","latestReviews":[{"state":"COMMENTED"}]})
            ),
            Some(ReviewDecision::ReviewRequired)
        );
        assert_eq!(
            review_decision(
                &json!({"reviewDecision":"APPROVED","latestReviews":[{"state":"CHANGES_REQUESTED"}]})
            ),
            Some(ReviewDecision::Approved)
        );
        assert_eq!(review_decision(&json!({"reviewDecision":null})), None);
    }
    #[test]
    fn merge_needs_an_open_ready_mergeable_unblocked_pull_request() {
        let ready = json!({"state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"mergeable":"MERGEABLE","reviewDecision":"APPROVED","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]});
        assert!(can_merge(&ready));
        for (key, value) in [
            ("isDraft", json!(true)),
            ("state", json!("MERGED")),
            ("mergeable", json!("CONFLICTING")),
            ("mergeable", json!(null)),
            ("reviewDecision", json!("REVIEW_REQUIRED")),
            (
                "statusCheckRollup",
                json!([{"name":"ci","status":"IN_PROGRESS"}]),
            ),
        ] {
            let mut blocked = ready.clone();
            blocked[key] = value;
            assert!(!can_merge(&blocked), "{key}");
        }
        let mut conflict = ready.clone();
        conflict["mergeable"] = json!("CONFLICTING");
        assert!(conflicting(&conflict));
        conflict["state"] = json!("CLOSED");
        assert!(!conflicting(&conflict));
    }
    #[test]
    fn description_drops_template_comments_and_trims() {
        assert_eq!(
            display_markdown(
                "<!-- Describe your change -->\n## Summary\nFixes it.<!-- hidden -->\n\n<!-- unclosed"
            ),
            "## Summary\nFixes it."
        );
        assert_eq!(display_markdown("  <!---->  "), "");
        assert_eq!(display_markdown("plain"), "plain");
    }
    #[test]
    fn rows_and_detail_lines_read_like_swift() {
        let pr = json!({"number":12,"state":"OPEN","isDraft":true,"author":{"login":"octocat"},"headRefName":"feature/x","additions":12,"deletions":3,"changedFiles":4});
        assert_eq!(row_meta(&pr), "#12 · Draft · octocat · feature/x");
        assert_eq!(byline(&pr), "Draft · #12 by octocat");
        assert_eq!(stats(&pr).as_deref(), Some("+12  −3  4 files"));
        let deleted =
            json!({"number":3,"state":"MERGED","isDraft":false,"author":null,"headRefName":"fix"});
        assert_eq!(row_meta(&deleted), "#3 · fix");
        assert_eq!(byline(&deleted), "Merged · #3");
        assert_eq!(stats(&deleted), None);
        let now = coincide_core::scheduling::parse_date(&json!("2026-11-07T12:00:00Z"))
            .unwrap()
            .timestamp() as f64;
        assert_eq!(age(&json!("2026-11-07T11:59:30Z"), now), "now");
        assert_eq!(age(&json!("2026-11-07T09:00:00Z"), now), "3h");
        assert_eq!(age(&json!("2026-11-05T12:00:00Z"), now), "2d");
        assert_eq!(age(&json!(null), now), "");
    }
    #[test]
    fn merge_methods_use_github_button_titles_and_questions() {
        assert_eq!(MergeMethod::parse("squash"), Some(MergeMethod::Squash));
        assert_eq!(MergeMethod::parse("admin"), None);
        assert_eq!(MergeMethod::Rebase.title(), "Rebase and Merge");
        assert_eq!(
            MergeMethod::Merge.question(7),
            "Merge pull request #7 with a merge commit?"
        );
    }
}
