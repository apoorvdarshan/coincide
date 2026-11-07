//! What a sidebar thread row says about its thread, as Swift's ThreadRowModel
//! and ThreadActivity do: approvals waiting, then working, then an unseen
//! failure, then an unseen completion. Turn results come from the engine's
//! session-only `app.status`; unseen marks persist in ui-state.json.
use super::*;
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum RowStatus {
    Idle,
    Running { since: f64 },
    Approval(usize),
    Failed,
    Completed,
}
impl RowStatus {
    /// Swift's label for the status, for tooltips and accessibility.
    pub(super) fn label(self) -> Option<&'static str> {
        match self {
            Self::Idle => None,
            Self::Running { .. } => Some("Working"),
            Self::Approval(_) => Some("Pending approval"),
            Self::Failed => Some("Failed"),
            Self::Completed => Some("Completed"),
        }
    }
    /// The capsule after the title: "Approval", "Approval 2" or "Failed".
    pub(super) fn badge(self) -> Option<String> {
        match self {
            Self::Approval(count) if count > 1 => Some(format!("Approval {count}")),
            Self::Approval(_) => Some("Approval".into()),
            Self::Failed => Some("Failed".into()),
            _ => None,
        }
    }
    /// A result the user hasn't looked at, which sets the title in semibold.
    pub(super) fn unseen(self) -> bool {
        matches!(self, Self::Failed | Self::Completed)
    }
}

pub(super) fn row_status(
    approvals: usize,
    running_since: Option<f64>,
    unseen: Option<&str>,
) -> RowStatus {
    if approvals > 0 {
        return RowStatus::Approval(approvals);
    }
    if let Some(since) = running_since {
        return RowStatus::Running { since };
    }
    match unseen {
        Some("failed") => RowStatus::Failed,
        Some(_) => RowStatus::Completed,
        None => RowStatus::Idle,
    }
}

/// "0:42", "12:05", "1:02:09": how long a turn has been running.
pub(super) fn elapsed(seconds: f64) -> String {
    let seconds = seconds.max(0.) as u64;
    let (hours, minutes, seconds) = (seconds / 3600, seconds / 60 % 60, seconds % 60);
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes}:{seconds:02}")
    }
}

/// Session-only activity the sidebar draws from `app.status`.
#[derive(Default)]
pub(super) struct ThreadActivity {
    running_since: HashMap<String, f64>,
    approvals: HashMap<String, usize>,
    /// The newest turn result already handled; none before the first reply,
    /// so a reopened window never marks turns it didn't watch end.
    serial: Option<u64>,
    /// Unseen marks not yet saved because the engine was busy.
    pending: Vec<(String, &'static str)>,
    window_active: bool,
    last_tick: Option<Instant>,
}
impl ThreadActivity {
    pub(super) fn approvals(&self, id: &str) -> usize {
        self.approvals.get(id).copied().unwrap_or(0)
    }
    pub(super) fn running_since(&self, id: &str) -> Option<f64> {
        self.running_since.get(id).copied()
    }
    /// Folds one `app.status` reply. Returns whether a row changed, and keeps
    /// turns that ended since the last reply for `take_finished`.
    pub(super) fn observe(&mut self, status: &Value, running: &[String], now: f64) -> bool {
        let before = (self.running_since.clone(), self.approvals.clone());
        self.running_since.retain(|id, _| running.contains(id));
        for id in running {
            self.running_since.entry(id.clone()).or_insert(now);
        }
        self.approvals = status["pendingApprovals"]
            .as_object()
            .map(|counts| {
                counts
                    .iter()
                    .filter_map(|(id, count)| Some((id.clone(), count.as_u64()? as usize)))
                    .filter(|(_, count)| *count > 0)
                    .collect()
            })
            .unwrap_or_default();
        let results = &status["turnResults"];
        let serial = results["serial"].as_u64().unwrap_or(0);
        if let Some(seen) = self.serial.filter(|seen| *seen <= serial) {
            for entry in results["recent"].as_array().into_iter().flatten() {
                let outcome = match entry["outcome"].as_str() {
                    Some("completed") => "completed",
                    Some("failed") => "failed",
                    _ => continue,
                };
                if entry["serial"].as_u64().is_some_and(|value| value > seen)
                    && let Some(thread) = entry["threadId"].as_str()
                {
                    self.pending.retain(|(id, _)| id != thread);
                    self.pending.push((thread.to_owned(), outcome));
                }
            }
        }
        self.serial = Some(serial);
        before != (self.running_since.clone(), self.approvals.clone()) || !self.pending.is_empty()
    }
    pub(super) fn take_finished(&mut self) -> Vec<(String, &'static str)> {
        std::mem::take(&mut self.pending)
    }
    pub(super) fn retry_finished(&mut self, marks: Vec<(String, &'static str)>) {
        for mark in marks.into_iter().rev() {
            if !self.pending.iter().any(|(id, _)| *id == mark.0) {
                self.pending.insert(0, mark);
            }
        }
    }
    /// Whether the window just became active, when the thread it shows counts
    /// as seen, as Swift's markVisibleThreadSeen does.
    pub(super) fn activate(&mut self, active: bool) -> bool {
        let became = active && !self.window_active;
        self.window_active = active;
        became
    }
    /// Running rows count their time each second.
    pub(super) fn tick(&mut self) -> bool {
        if self.running_since.is_empty() {
            self.last_tick = None;
            return false;
        }
        if self
            .last_tick
            .is_some_and(|tick| tick.elapsed() < Duration::from_secs(1))
        {
            return false;
        }
        self.last_tick = Some(Instant::now());
        true
    }
}

impl Coincide {
    /// After each `app.status`: marks threads whose turn ended out of sight,
    /// and clears the shown thread's mark when the window comes forward.
    pub(super) fn observe_thread_activity(
        &mut self,
        status: &Value,
        window: &Window,
        cx: &mut Context<Self>,
    ) {
        let now = coincide_core::store::swift_timestamp();
        let mut changed = self.thread_activity.observe(status, &self.running, now);
        let active = window.is_window_active() && window.visibility().is_visible();
        let shown = self
            .selected
            .as_ref()
            .filter(|_| active && self.chat_visible())
            .map(|thread| text(thread, "id"));
        let marks = self
            .thread_activity
            .take_finished()
            .into_iter()
            .filter(|(id, outcome)| {
                shown.as_deref() != Some(id.as_str())
                    && self.sidebar_preferences.document["unseen"][id] != *outcome
            })
            .collect::<Vec<_>>();
        let mut clear = None;
        if self.thread_activity.activate(active)
            && let Some(id) = &shown
            && self.sidebar_preferences.document["unseen"][id].is_string()
        {
            clear = Some(id.clone());
        }
        if !marks.is_empty() || clear.is_some() {
            match self.save_unseen_marks(&marks, clear.as_deref()) {
                Ok(()) => changed = true,
                Err(error) if engine_busy(&error) => {
                    self.thread_activity.retry_finished(marks);
                }
                Err(error) => {
                    self.status = format!("Conversation marker could not be saved: {error}");
                    changed = true;
                }
            }
        }
        if changed | self.thread_activity.tick() {
            cx.notify();
        }
    }
    fn save_unseen_marks(&mut self, marks: &[(String, &str)], clear: Option<&str>) -> Result<()> {
        let document = {
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
            let current = engine.store.document("ui-state.json")?.unwrap_or(json!({}));
            anyhow::ensure!(current.is_object(), "Invalid interface preferences");
            let mut entries = current["unseen"].as_object().cloned().unwrap_or_default();
            for (id, outcome) in marks {
                entries.insert(id.clone(), json!(outcome));
            }
            if let Some(id) = clear {
                entries.remove(id);
            }
            engine
                .store
                .patch_document("ui-state.json", &json!({"unseen":entries}))?
        };
        self.sidebar_preferences.document = document;
        self.sidebar_preferences.pending = false;
        self.sidebar_preferences.error = None;
        self.thread_bulk.invalidate();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn status_priority_badges_and_elapsed_time_follow_swift() {
        assert_eq!(
            row_status(2, Some(5.), Some("failed")),
            RowStatus::Approval(2)
        );
        assert_eq!(
            row_status(0, Some(5.), Some("failed")),
            RowStatus::Running { since: 5. }
        );
        assert_eq!(row_status(0, None, Some("failed")), RowStatus::Failed);
        assert_eq!(row_status(0, None, Some("completed")), RowStatus::Completed);
        assert_eq!(row_status(0, None, None), RowStatus::Idle);
        assert_eq!(RowStatus::Approval(1).badge().as_deref(), Some("Approval"));
        assert_eq!(
            RowStatus::Approval(3).badge().as_deref(),
            Some("Approval 3")
        );
        assert_eq!(RowStatus::Failed.badge().as_deref(), Some("Failed"));
        assert_eq!(RowStatus::Completed.badge(), None);
        assert!(RowStatus::Completed.unseen() && RowStatus::Failed.unseen());
        assert!(!RowStatus::Running { since: 0. }.unseen());
        assert_eq!(RowStatus::Approval(1).label(), Some("Pending approval"));
        assert_eq!(elapsed(-4.), "0:00");
        assert_eq!(elapsed(42.9), "0:42");
        assert_eq!(elapsed(725.), "12:05");
        assert_eq!(elapsed(3729.), "1:02:09");
    }

    #[::core::prelude::v1::test]
    fn activity_marks_only_turns_that_end_after_the_first_reply() {
        let mut activity = ThreadActivity::default();
        let status = |serial: u64, recent: Value, approvals: Value| json!({"pendingApprovals":approvals,"turnResults":{"serial":serial,"recent":recent}});
        let running = vec!["a".to_owned()];
        // Results from before this window watched are never replayed.
        assert!(activity.observe(
            &status(
                2,
                json!([{"serial":2,"threadId":"old","outcome":"completed"}]),
                json!({"a":1})
            ),
            &running,
            10.,
        ));
        assert!(activity.take_finished().is_empty());
        assert_eq!(activity.approvals("a"), 1);
        assert_eq!(activity.running_since("a"), Some(10.));
        assert!(!activity.observe(&status(2, json!([]), json!({"a":1})), &running, 11.));
        assert_eq!(activity.running_since("a"), Some(10.));
        let recent = json!([
            {"serial":2,"threadId":"old","outcome":"completed"},
            {"serial":3,"threadId":"a","outcome":"completed"},
            {"serial":4,"threadId":"b","outcome":"interrupted"},
            {"serial":5,"threadId":"c","outcome":"failed"},
            {"serial":6,"threadId":"a","outcome":"failed"}
        ]);
        assert!(activity.observe(&status(6, recent.clone(), json!({})), &[], 12.));
        assert_eq!(activity.approvals("a"), 0);
        assert_eq!(activity.running_since("a"), None);
        let finished = activity.take_finished();
        assert_eq!(
            finished,
            vec![("c".to_owned(), "failed"), ("a".to_owned(), "failed")]
        );
        // A busy engine keeps marks for the next reply without duplicates.
        activity.retry_finished(finished);
        assert!(activity.observe(&status(6, recent, json!({})), &[], 13.));
        assert_eq!(activity.take_finished().len(), 2);
        assert!(activity.activate(true));
        assert!(!activity.activate(true));
        assert!(!activity.activate(false));
        assert!(activity.activate(true));
    }
}
