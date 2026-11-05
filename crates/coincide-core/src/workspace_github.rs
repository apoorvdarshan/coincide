//! Offline GitHub PR workspace models for `gh pr view --json` responses.
//! This module never authenticates, fetches, posts reviews or merges. Readiness is
//! advisory; a future writer must refetch and use the exact expected head at GitHub.
use crate::workspace_git::validate_oid;
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    pub number: u64,
    pub title: String,
    pub url: String,
    pub state: String,
    pub is_draft: bool,
    pub head_ref_oid: String,
    pub head_ref_name: String,
    pub base_ref_name: String,
    pub mergeable: String,
    pub merge_state_status: String,
    pub review_decision: String,
    pub reviews: Vec<Review>,
    pub status_check_rollup: Vec<Value>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    pub id: String,
    pub state: String,
    pub body: String,
    pub author: Option<Value>,
    pub commit: Option<Value>,
}

pub fn parse_snapshot(bytes: &[u8]) -> Result<PullRequest> {
    ensure!(bytes.len() <= 3 * 1024 * 1024, "PR snapshot exceeds 3 MiB");
    let pr: PullRequest = serde_json::from_slice(bytes)?;
    ensure!(pr.number > 0, "Invalid PR number");
    validate_oid(&pr.head_ref_oid)?;
    let url = url::Url::parse(&pr.url)?;
    ensure!(
        url.scheme() == "https"
            && url.host_str() == Some("github.com")
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        "Invalid GitHub PR URL"
    );
    let parts = url
        .path_segments()
        .map(|v| v.collect::<Vec<_>>())
        .unwrap_or_default();
    ensure!(
        parts.len() == 4
            && !parts[0].is_empty()
            && !parts[1].is_empty()
            && parts[2] == "pull"
            && parts[3] == pr.number.to_string(),
        "PR URL does not match number"
    );
    Ok(pr)
}

impl PullRequest {
    /// Conservative preflight, not an authorization or proof of merge success.
    /// Missing checks or branch policy information fail closed.
    pub fn preflight(&self, expected_head: &str) -> Result<Value> {
        validate_oid(expected_head)?;
        let mut blockers = Vec::new();
        if self.head_ref_oid != expected_head {
            blockers.push("head_changed");
        }
        if self.state != "OPEN" {
            blockers.push("not_open");
        }
        if self.is_draft {
            blockers.push("draft");
        }
        if self.mergeable != "MERGEABLE" {
            blockers.push("mergeability_unknown_or_conflicting");
        }
        if self.merge_state_status != "CLEAN" {
            blockers.push("branch_policy_not_clean");
        }
        if !matches!(self.review_decision.as_str(), "" | "APPROVED") {
            blockers.push("review_required_or_changes_requested");
        }
        if self.status_check_rollup.is_empty() {
            blockers.push("checks_missing");
        }
        for check in &self.status_check_rollup {
            let passed = match check["__typename"].as_str() {
                Some("CheckRun") => {
                    check["status"] == "COMPLETED" && check["conclusion"] == "SUCCESS"
                }
                Some("StatusContext") => check["state"] == "SUCCESS",
                _ => false,
            };
            if !passed {
                blockers.push("checks_not_successful");
                break;
            }
        }
        Ok(
            json!({"number":self.number,"expectedHead":expected_head,"eligible":blockers.is_empty(),"blockers":blockers,"requiresFreshServerValidation":true}),
        )
    }
}
