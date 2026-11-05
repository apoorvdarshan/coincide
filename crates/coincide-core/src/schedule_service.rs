//! Persisted schedule transitions. The engine must serialize this service with
//! its other Store writers. A claim is durable before work is returned; this
//! provides at-most-once submission, not guaranteed execution after a crash.
use crate::{
    scheduling::{ScheduleDocument, ScheduledTask, parse_date},
    store::Store,
};
use anyhow::{Context, Result, bail, ensure};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

const FILE: &str = "scheduled-tasks.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DueJob {
    pub schedule_id: String,
    pub occurrence: DateTime<Utc>,
    pub revision: String,
    pub manual: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Claim {
    pub claim_id: String,
    pub schedule_id: String,
    pub occurrence: DateTime<Utc>,
    pub project_id: String,
    pub thread_id: Option<String>,
    pub prompt: String,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetState {
    Ready,
    Busy,
    Archived,
    Missing,
    Unavailable,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    Completed,
    Failed,
    Interrupted,
    Missed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ApprovalState {
    AwaitingRustApproval,
    AwaitingUserApproval,
    Approved,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalResult {
    pub task: Value,
    pub newly_approved: bool,
    pub state: ApprovalState,
}

pub struct ScheduleService<'a> {
    store: &'a mut Store,
}
impl<'a> ScheduleService<'a> {
    pub fn new(store: &'a mut Store) -> Self {
        Self { store }
    }
    fn load(&self) -> Result<Value> {
        let value = self
            .store
            .document(FILE)?
            .unwrap_or_else(|| json!({"version":1,"tasks":[]}));
        serde_json::from_value::<ScheduleDocument>(value.clone())?.validate()?;
        Ok(value)
    }
    fn persist(&mut self, value: &Value) -> Result<()> {
        serde_json::from_value::<ScheduleDocument>(value.clone())?.validate()?;
        self.store.save_document(FILE, value)
    }
    pub fn list(&self) -> Result<Vec<Value>> {
        Ok(self.load()?["tasks"]
            .as_array()
            .context("Invalid schedule tasks")?
            .clone())
    }
    pub fn create(&mut self, input: &Value, now: DateTime<Utc>) -> Result<Value> {
        let fields = input.as_object().context("Schedule must be an object")?;
        for key in fields.keys() {
            ensure!(
                [
                    "name",
                    "prompt",
                    "projectID",
                    "threadID",
                    "recurrence",
                    "isPaused"
                ]
                .contains(&key.as_str()),
                "Unsupported schedule field: {key}"
            );
        }
        let mut value = input.clone();
        value["id"] = json!(Uuid::new_v4().to_string().to_uppercase());
        if value.get("isPaused").is_none() {
            value["isPaused"] = json!(false);
        }
        value["awaitingApproval"] = json!(true);
        bump(&mut value);
        let typed = task(&value)?;
        check_future_once(&typed, now)?;
        self.check_target(&value)?;
        value["nextRunAt"] = json!(typed.recurrence.next_after(now)?);
        let mut doc = self.load()?;
        let tasks = doc["tasks"]
            .as_array_mut()
            .context("Invalid schedule tasks")?;
        if let Some(thread) = value["threadID"].as_str() {
            ensure!(
                tasks
                    .iter()
                    .filter(|t| same_id(t["threadID"].as_str().unwrap_or(""), thread))
                    .count()
                    < 10,
                "A thread can have at most 10 schedules"
            );
        }
        tasks.push(value.clone());
        self.persist(&doc)?;
        Ok(value)
    }
    pub fn patch(&mut self, id: &str, patch: &Value, now: DateTime<Utc>) -> Result<Value> {
        let fields = patch
            .as_object()
            .context("Schedule patch must be an object")?;
        for key in fields.keys() {
            ensure!(
                ["name", "prompt", "recurrence"].contains(&key.as_str()),
                "Unsupported schedule patch field: {key}"
            );
        }
        let mut doc = self.load()?;
        let value = find_mut(&mut doc, id)?;
        let old_recurrence = value["recurrence"].clone();
        for (key, next) in fields {
            value[key] = next.clone();
        }
        let typed = task(value)?;
        if fields.contains_key("recurrence") && old_recurrence != value["recurrence"] {
            check_future_once(&typed, now)?;
            value["nextRunAt"] = json!(typed.recurrence.next_after(now)?);
        }
        if !fields.is_empty() {
            value["awaitingApproval"] = json!(true);
            value["rustApprovedRevision"] = Value::Null;
            value["proposal"] = Value::Null;
            value["pendingDelivery"] = Value::Null;
            bump(value);
        }
        let result = value.clone();
        self.persist(&doc)?;
        Ok(result)
    }
    /// This method is for an explicit user approval. Agent-facing APIs must not
    /// expose it as an unrestricted schedule operation.
    pub fn approval_state(&self, id: &str) -> Result<ApprovalState> {
        let mut doc = self.load()?;
        Ok(approval_state(find_mut(&mut doc, id)?))
    }
    pub fn approve(&mut self, id: &str, now: DateTime<Utc>) -> Result<ApprovalResult> {
        let mut doc = self.load()?;
        let value = find_mut(&mut doc, id)?;
        if approval_state(value) == ApprovalState::Approved && value["proposal"].is_null() {
            return Ok(ApprovalResult {
                task: value.clone(),
                newly_approved: false,
                state: ApprovalState::Approved,
            });
        }
        let previous_recurrence = value["recurrence"].clone();
        if let Some(proposal) = value.get("proposal").filter(|p| !p.is_null()).cloned() {
            for field in ["name", "prompt", "recurrence"] {
                value[field] = proposal
                    .get(field)
                    .context("Incomplete schedule proposal")?
                    .clone();
            }
        }
        let typed = task(value)?;
        check_future_once(&typed, now)?;
        self.check_target(value)?;
        value["awaitingApproval"] = json!(false);
        value["proposal"] = Value::Null;
        value["pendingDelivery"] = Value::Null;
        value["nextRunAt"] = if typed.recurrence.kind == "once"
            && previous_recurrence == value["recurrence"]
            && value["nextRunAt"].is_null()
            && date_field(value, "lastFiredOccurrence")?.is_some()
        {
            Value::Null
        } else {
            json!(typed.recurrence.next_after(now)?)
        };
        bump(value);
        value["rustApprovedRevision"] = json!(revision(value));
        let result = value.clone();
        self.persist(&doc)?;
        Ok(ApprovalResult {
            task: result,
            newly_approved: true,
            state: ApprovalState::Approved,
        })
    }
    pub fn set_paused(&mut self, id: &str, paused: bool, now: DateTime<Utc>) -> Result<Value> {
        let mut doc = self.load()?;
        let value = find_mut(&mut doc, id)?;
        if !paused {
            self.check_target(value)?;
        }
        if value["isPaused"] == paused && value["pauseReason"].is_null() {
            return Ok(value.clone());
        }
        value["isPaused"] = json!(paused);
        value["pauseReason"] = Value::Null;
        value["pendingDelivery"] = Value::Null;
        if !paused {
            let typed = task(value)?;
            let next = if typed.recurrence.kind == "once" && value["nextRunAt"].is_null() {
                None
            } else {
                typed.recurrence.next_after(now)?
            };
            value["nextRunAt"] = json!(next);
        }
        bump_preserving_approval(value);
        let result = value.clone();
        self.persist(&doc)?;
        Ok(result)
    }
    pub fn delete(&mut self, id: &str) -> Result<bool> {
        Uuid::parse_str(id)?;
        let mut doc = self.load()?;
        let tasks = doc["tasks"].as_array_mut().context("Invalid tasks")?;
        let before = tasks.len();
        tasks.retain(|v| !same_id(v["id"].as_str().unwrap_or(""), id));
        if tasks.len() == before {
            return Ok(false);
        }
        self.persist(&doc)?;
        Ok(true)
    }
    pub fn plan_due(&self, now: DateTime<Utc>) -> Result<Vec<DueJob>> {
        let mut jobs = Vec::new();
        for value in self.list()? {
            if !task(&value)?.is_active() || approval_state(&value) != ApprovalState::Approved {
                continue;
            }
            let occurrence =
                date_field(&value, "pendingDelivery")?.or(date_field(&value, "nextRunAt")?);
            if let Some(occurrence) = occurrence.filter(|time| *time <= now) {
                jobs.push(DueJob {
                    schedule_id: value["id"].as_str().context("Missing schedule ID")?.into(),
                    occurrence,
                    revision: revision(&value),
                    manual: false,
                });
            }
        }
        jobs.sort_by_key(|job| job.occurrence);
        Ok(jobs)
    }
    pub fn plan_now(&self, id: &str, now: DateTime<Utc>) -> Result<DueJob> {
        let mut doc = self.load()?;
        let value = find_mut(&mut doc, id)?;
        ensure!(
            approval_state(value) == ApprovalState::Approved,
            "Schedule requires explicit approval in Coincide Rust"
        );
        Ok(DueJob {
            schedule_id: id.into(),
            occurrence: now,
            revision: revision(value),
            manual: true,
        })
    }
    /// Caller supplies current thread/provider availability while holding the
    /// engine lock. Only dispatch returned Claims; a plan alone is not runnable.
    pub fn claim(
        &mut self,
        job: &DueJob,
        state: TargetState,
        now: DateTime<Utc>,
    ) -> Result<Option<Claim>> {
        let mut doc = self.load()?;
        let value = find_mut(&mut doc, &job.schedule_id)?;
        ensure!(
            revision(value) == job.revision,
            "Schedule changed after planning"
        );
        let typed = task(value)?;
        ensure!(
            approval_state(value) == ApprovalState::Approved,
            "Schedule requires explicit approval in Coincide Rust"
        );
        if !job.manual && typed.is_paused {
            return Ok(None);
        }
        ensure!(
            job.occurrence <= now,
            "Schedule occurrence is in the future"
        );
        let pending = date_field(value, "pendingDelivery")?;
        let next = date_field(value, "nextRunAt")?;
        if !job.manual && Some(job.occurrence) != pending.or(next) {
            return Ok(None);
        }
        let consumed = date_field(value, "lastFiredOccurrence")?;
        let from_pending = !job.manual && pending == Some(job.occurrence);
        if !from_pending && consumed.is_some_and(|time| job.occurrence <= time) {
            if !job.manual {
                value["nextRunAt"] = json!(typed.recurrence.next_after(now)?);
                self.persist(&doc)?;
            }
            return Ok(None);
        }
        let thread = value["threadID"].as_str().map(str::to_owned);
        if let Some(thread) = &thread {
            Uuid::parse_str(thread).context("Invalid schedule thread ID")?;
        }
        let running = !value["rustClaim"].is_null() || !value["activeThreadID"].is_null();
        let state = if running && state == TargetState::Ready {
            TargetState::Busy
        } else {
            state
        };
        if matches!(state, TargetState::Archived | TargetState::Missing) {
            value["isPaused"] = json!(true);
            value["pauseReason"] = json!(if state == TargetState::Archived {
                "threadArchived"
            } else {
                "threadDeleted"
            });
            value["pendingDelivery"] = Value::Null;
            bump_preserving_approval(value);
            self.persist(&doc)?;
            return Ok(None);
        }
        if job.manual && running {
            bail!("This scheduled task is already running");
        }
        if state == TargetState::Busy && from_pending {
            return Ok(None);
        }
        if state == TargetState::Busy && thread.is_some() {
            if pending.is_none() {
                value["pendingDelivery"] = json!(job.occurrence);
            }
            consume(value, job.occurrence, now, &typed, job.manual)?;
            self.persist(&doc)?;
            return Ok(None);
        }
        if matches!(state, TargetState::Busy | TargetState::Unavailable) {
            consume(value, job.occurrence, now, &typed, job.manual)?;
            value["lastOutcome"] = json!("missed");
            value["lastMessage"] =
                json!("Run skipped because the project or provider was unavailable.");
            self.persist(&doc)?;
            return Ok(None);
        }
        consume(value, job.occurrence, now, &typed, job.manual)?;
        value["pendingDelivery"] = Value::Null;
        let claim = Claim {
            claim_id: Uuid::new_v4().to_string(),
            schedule_id: typed.id,
            occurrence: job.occurrence,
            project_id: typed.project_id,
            thread_id: thread,
            prompt: typed.prompt,
        };
        value["rustClaim"] = serde_json::to_value(&claim)?;
        value["activeThreadID"] = json!(claim.thread_id);
        value["lastThreadID"] = json!(claim.thread_id);
        value["lastRunAt"] = json!(now);
        value["lastOutcome"] = Value::Null;
        value["lastMessage"] = Value::Null;
        value["lastFinishedAt"] = Value::Null;
        self.persist(&doc)?;
        Ok(Some(claim))
    }
    /// Project schedules create their thread after claiming; bind its ID before
    /// starting a provider so recovery and UI retain the actual destination.
    pub fn attach_thread(&mut self, claim_id: &str, thread_id: &str) -> Result<bool> {
        Uuid::parse_str(thread_id)?;
        let thread = self
            .store
            .thread(thread_id)
            .context("Claim thread not found")?;
        let mut doc = self.load()?;
        for value in doc["tasks"].as_array_mut().context("Invalid tasks")? {
            if value["rustClaim"]["claimId"] != claim_id {
                continue;
            }
            ensure!(
                thread["projectID"] == value["rustClaim"]["projectId"],
                "Claim thread belongs to another project"
            );
            if let Some(existing) = value["rustClaim"]["threadId"].as_str() {
                ensure!(
                    same_id(existing, thread_id),
                    "Claim is already bound to another thread"
                );
                return Ok(true);
            }
            value["rustClaim"]["threadId"] = json!(thread_id);
            value["activeThreadID"] = json!(thread_id);
            value["lastThreadID"] = json!(thread_id);
            self.persist(&doc)?;
            return Ok(true);
        }
        Ok(false)
    }
    pub fn complete(
        &mut self,
        claim_id: &str,
        outcome: Outcome,
        message: Option<&str>,
        now: DateTime<Utc>,
    ) -> Result<bool> {
        let mut doc = self.load()?;
        for value in doc["tasks"].as_array_mut().context("Invalid tasks")? {
            if value["rustClaim"]["claimId"] != claim_id {
                continue;
            }
            value["rustClaim"] = Value::Null;
            value["activeThreadID"] = Value::Null;
            value["lastOutcome"] = serde_json::to_value(outcome)?;
            value["lastMessage"] = json!(message);
            value["lastFinishedAt"] = json!(now);
            if value["threadID"].is_null()
                && date_field(value, "nextRunAt")?.is_some_and(|next| next <= now)
            {
                value["nextRunAt"] = json!(task(value)?.recurrence.next_after(now)?);
            }
            self.persist(&doc)?;
            return Ok(true);
        }
        Ok(false)
    }
    /// Call once before timers after relaunch, and on wake with false. Never
    /// replay an interrupted claim or queue missed occurrences as a backlog.
    pub fn recover(&mut self, now: DateTime<Utc>, after_relaunch: bool) -> Result<usize> {
        let mut doc = self.load()?;
        let mut changed = 0;
        for value in doc["tasks"].as_array_mut().context("Invalid tasks")? {
            let mut dirty = false;
            if after_relaunch
                && (!value["rustClaim"].is_null() || !value["activeThreadID"].is_null())
            {
                value["rustClaim"] = Value::Null;
                value["activeThreadID"] = Value::Null;
                value["lastOutcome"] = json!("interrupted");
                value["lastFinishedAt"] = json!(now);
                value["lastMessage"] = json!("Coincide closed before this run finished.");
                dirty = true;
            }
            if after_relaunch && !value["pendingDelivery"].is_null() {
                value["pendingDelivery"] = Value::Null;
                if value["lastOutcome"] != "interrupted" {
                    value["lastOutcome"] = json!("missed");
                    value["lastMessage"] =
                        json!("A pending run was skipped after Coincide restarted.");
                }
                dirty = true;
            }
            if let Some(next) = date_field(value, "nextRunAt")?.filter(|next| *next <= now) {
                let typed = task(value)?;
                value["nextRunAt"] = json!(typed.recurrence.next_after(now)?);
                mark_consumed(value, next)?;
                if value["rustClaim"].is_null()
                    && value["activeThreadID"].is_null()
                    && value["lastOutcome"] != "interrupted"
                    && typed.awaiting_approval != Some(true)
                {
                    value["lastOutcome"] = json!("missed");
                    value["lastMessage"] =
                        json!("A run was skipped while Coincide was closed or asleep.");
                }
                dirty = true;
            }
            if dirty {
                bump_preserving_approval(value);
                changed += 1;
            }
        }
        if changed > 0 {
            self.persist(&doc)?;
        }
        Ok(changed)
    }
    fn check_target(&self, value: &Value) -> Result<()> {
        if let Some(id) = value["threadID"].as_str() {
            let thread = self
                .store
                .thread(id)
                .context("Scheduled thread is missing")?;
            ensure!(thread["isArchived"] != true, "Scheduled thread is archived");
            ensure!(
                thread["projectID"] == value["projectID"],
                "Schedule project does not match its thread"
            );
        } else {
            ensure!(
                self.store
                    .projects()?
                    .as_array()
                    .context("Invalid projects")?
                    .iter()
                    .any(|p| p["id"] == value["projectID"]),
                "Scheduled project is missing"
            );
        }
        Ok(())
    }
}
fn find_mut<'a>(doc: &'a mut Value, id: &str) -> Result<&'a mut Value> {
    Uuid::parse_str(id)?;
    doc["tasks"]
        .as_array_mut()
        .context("Invalid tasks")?
        .iter_mut()
        .find(|v| same_id(v["id"].as_str().unwrap_or(""), id))
        .context("Schedule not found")
}
fn same_id(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}
fn task(value: &Value) -> Result<ScheduledTask> {
    let task: ScheduledTask = serde_json::from_value(value.clone())?;
    task.validate()?;
    if let Some(thread) = value.get("threadID").filter(|v| !v.is_null()) {
        Uuid::parse_str(thread.as_str().context("Invalid schedule thread ID")?)
            .context("Invalid schedule thread ID")?;
    }
    Ok(task)
}
fn revision(value: &Value) -> String {
    value["rustRevision"].as_str().unwrap_or("").into()
}
fn bump(value: &mut Value) {
    value["rustRevision"] = json!(Uuid::new_v4().to_string());
}
fn approval_state(value: &Value) -> ApprovalState {
    let current = revision(value);
    if current.is_empty() || value["rustApprovedRevision"].as_str() != Some(current.as_str()) {
        ApprovalState::AwaitingRustApproval
    } else if value["awaitingApproval"] == true {
        ApprovalState::AwaitingUserApproval
    } else {
        ApprovalState::Approved
    }
}
fn bump_preserving_approval(value: &mut Value) {
    let approved = approval_state(value) == ApprovalState::Approved;
    bump(value);
    if approved {
        value["rustApprovedRevision"] = json!(revision(value));
    }
}
fn date_field(value: &Value, key: &str) -> Result<Option<DateTime<Utc>>> {
    value
        .get(key)
        .filter(|v| !v.is_null())
        .map(parse_date)
        .transpose()
}
fn check_future_once(task: &ScheduledTask, now: DateTime<Utc>) -> Result<()> {
    ensure!(
        task.recurrence.kind != "once" || parse_date(&task.recurrence.date)? > now,
        "Choose a future date for a one-time task"
    );
    Ok(())
}
fn mark_consumed(value: &mut Value, occurrence: DateTime<Utc>) -> Result<()> {
    value["lastFiredOccurrence"] = json!(
        date_field(value, "lastFiredOccurrence")?.map_or(occurrence, |old| old.max(occurrence))
    );
    Ok(())
}
fn consume(
    value: &mut Value,
    occurrence: DateTime<Utc>,
    now: DateTime<Utc>,
    task: &ScheduledTask,
    manual: bool,
) -> Result<()> {
    mark_consumed(value, occurrence)?;
    if task.recurrence.kind == "once" {
        value["nextRunAt"] = Value::Null;
    } else if !manual || date_field(value, "nextRunAt")?.is_none_or(|next| next <= now) {
        value["nextRunAt"] = json!(task.recurrence.next_after(now)?);
    }
    Ok(())
}
