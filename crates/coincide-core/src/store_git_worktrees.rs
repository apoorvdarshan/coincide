//! Threads that run in a worktree, for the branch toolbar's "Previous Worktree" and
//! for keeping a worktree another thread uses. Only scalar JSON fields are read;
//! transcripts are never decoded.
use super::*;

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WorktreeThread {
    pub id: String,
    pub project_id: String,
    pub path: String,
    pub branch: Option<String>,
    pub updated_at: f64,
}

impl Store {
    pub(crate) fn worktree_threads(&self) -> Result<Vec<WorktreeThread>> {
        let db = self.connection()?;
        let mut statement = db.prepare(
            "SELECT threads.id,coalesce(json_extract(document,'$.projectID'),''),json_extract(document,'$.worktreePath'),
             CASE WHEN json_type(document,'$.branch')='text' THEN json_extract(document,'$.branch') END,
             coalesce(thread_summaries.updated_at,0)
             FROM threads LEFT JOIN thread_summaries ON thread_summaries.id=threads.id
             WHERE json_type(document,'$.worktreePath')='text' ORDER BY threads.id LIMIT 10000",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(WorktreeThread {
                id: row.get(0)?,
                project_id: row.get(1)?,
                path: row.get(2)?,
                branch: row.get(3)?,
                updated_at: row.get(4)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }
}
