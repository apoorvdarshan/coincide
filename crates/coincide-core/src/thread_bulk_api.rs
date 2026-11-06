//! Native sidebar flag review/apply/Undo. No deletion or session mutation.
use super::*;
use crate::store::FlagRow;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThreadFlagAction {
    Pin,
    Unpin,
    Archive,
    Restore,
}
impl ThreadFlagAction {
    pub fn label(self) -> &'static str {
        match self {
            Self::Pin => "Pin",
            Self::Unpin => "Unpin",
            Self::Archive => "Archive",
            Self::Restore => "Restore",
        }
    }
    pub fn field(self) -> &'static str {
        match self {
            Self::Pin | Self::Unpin => "isPinned",
            Self::Archive | Self::Restore => "isArchived",
        }
    }
    fn desired(self) -> bool {
        matches!(self, Self::Pin | Self::Archive)
    }
}
#[derive(Clone)]
pub struct PreparedThreadFlags {
    owner: Uuid,
    action: ThreadFlagAction,
    rows: Vec<FlagRow>,
    unconfirmed_archive: bool,
}
impl PreparedThreadFlags {
    pub fn requires_confirmation(&self) -> bool {
        !self.unconfirmed_archive
    }
    pub fn action(&self) -> ThreadFlagAction {
        self.action
    }
    pub fn count(&self) -> usize {
        self.rows.iter().filter(|r| r.changed()).count()
    }
    pub fn selected_count(&self) -> usize {
        self.rows.len()
    }
    pub fn titles(&self) -> Vec<String> {
        self.rows
            .iter()
            .filter(|r| r.changed())
            .take(8)
            .map(|r| r.title.clone())
            .collect()
    }
}
#[derive(Clone)]
pub struct ThreadFlagUndo {
    owner: Uuid,
    action: ThreadFlagAction,
    rows: Vec<FlagRow>,
}
impl ThreadFlagUndo {
    pub fn thread_ids(&self) -> Vec<String> {
        self.rows.iter().map(|row| row.id.clone()).collect()
    }
    pub fn count(&self) -> usize {
        self.rows.len()
    }
    pub fn action(&self) -> ThreadFlagAction {
        self.action
    }
    /// Cached flag projection only; UI never needs to parse retained transcripts.
    pub fn applied_flags(&self) -> Vec<(String, &'static str, Option<Value>)> {
        self.rows
            .iter()
            .map(|r| (r.id.clone(), self.action.field(), r.before.clone()))
            .collect()
    }
    pub fn restored_flags(&self) -> Vec<(String, &'static str, Option<Value>)> {
        self.rows
            .iter()
            .map(|r| (r.id.clone(), self.action.field(), r.after.clone()))
            .collect()
    }
}
fn require_idle<'a>(
    ids: impl Iterator<Item = &'a str>,
    running: impl Iterator<Item = &'a str>,
    unsaved: impl Iterator<Item = &'a str>,
) -> Result<()> {
    let ids: HashSet<_> = ids.map(str::to_ascii_lowercase).collect();
    ensure!(
        !running
            .chain(unsaved)
            .any(|id| ids.contains(&id.to_ascii_lowercase())),
        "A selected conversation is running or has unsaved transcript changes"
    );
    Ok(())
}
impl Engine {
    pub fn prepare_thread_flags(
        &mut self,
        ids: &[String],
        action: ThreadFlagAction,
    ) -> Result<PreparedThreadFlags> {
        self.require_admissions()?;
        require_idle(
            ids.iter().map(String::as_str),
            self.runs.keys().map(String::as_str),
            self.unsaved_threads.keys().map(String::as_str),
        )?;
        let rows = self
            .store
            .prepare_flag_rows(ids, action.field(), action.desired())?;
        Ok(PreparedThreadFlags {
            owner: self.thread_bulk_owner,
            action,
            rows,
            unconfirmed_archive: false,
        })
    }
    /// An owned initial Archive action may follow an explicit saved opt-out.
    /// The Store rechecks the same boolean within the atomic row transaction.
    pub fn prepare_native_archive_flags(&mut self, ids: &[String]) -> Result<PreparedThreadFlags> {
        let mut plan = self.prepare_thread_flags(ids, ThreadFlagAction::Archive)?;
        plan.unconfirmed_archive = self
            .store
            .document("settings.json")?
            .is_some_and(|settings| settings["confirmBeforeArchivingThreads"] == false);
        let workers = self.provider_workers_status();
        plan.unconfirmed_archive &=
            workers.running == 0 && workers.panicked == 0 && workers.unclassified == 0;
        Ok(plan)
    }
    pub fn apply_thread_flags(&mut self, prepared: &PreparedThreadFlags) -> Result<ThreadFlagUndo> {
        self.require_admissions()?;
        ensure!(
            prepared.owner == self.thread_bulk_owner,
            "Selection belongs to another app owner"
        );
        require_idle(
            prepared.rows.iter().map(|r| r.id.as_str()),
            self.runs.keys().map(String::as_str),
            self.unsaved_threads.keys().map(String::as_str),
        )?;
        if prepared.unconfirmed_archive {
            let workers = self.provider_workers_status();
            ensure!(
                workers.running == 0 && workers.panicked == 0 && workers.unclassified == 0,
                "Wait for actual provider cleanup before archiving without confirmation"
            );
        }
        self.store.apply_flag_rows_with_archive_preference(
            &prepared.rows,
            prepared.unconfirmed_archive,
        )?;
        let rows = prepared
            .rows
            .iter()
            .filter(|r| r.changed())
            .map(FlagRow::reversed)
            .collect::<Vec<_>>();
        if !rows.is_empty() {
            self.revision += 1;
        }
        Ok(ThreadFlagUndo {
            owner: self.thread_bulk_owner,
            action: prepared.action,
            rows,
        })
    }
    pub fn undo_thread_flags(&mut self, undo: &ThreadFlagUndo) -> Result<()> {
        self.require_admissions()?;
        ensure!(
            undo.owner == self.thread_bulk_owner,
            "Undo belongs to another app owner"
        );
        require_idle(
            undo.rows.iter().map(|r| r.id.as_str()),
            self.runs.keys().map(String::as_str),
            self.unsaved_threads.keys().map(String::as_str),
        )?;
        self.store.apply_flag_rows(&undo.rows)?;
        if !undo.rows.is_empty() {
            self.revision += 1;
        }
        Ok(())
    }
}
#[cfg(test)]
#[path = "thread_bulk_tests.rs"]
mod tests;
