//! Typed native Move and Undo. Native session folders are never retargeted.
use super::*;
use crate::store::SidebarRow;
use std::path::Path;
struct Folder {
    path: PathBuf,
    identity: crate::private_fs::Identity,
}
impl Folder {
    fn capture(path: &str) -> Result<Self> {
        let path = PathBuf::from(path);
        ensure!(
            path.is_absolute() && path.is_dir(),
            "Project folder is unavailable"
        );
        let path = path.canonicalize()?;
        Ok(Self {
            identity: crate::private_fs::identity(&path)?,
            path,
        })
    }
    fn validate(&self) -> Result<()> {
        ensure!(
            self.path.is_dir() && crate::private_fs::identity(&self.path)? == self.identity,
            "Project folder changed after review"
        );
        Ok(())
    }
}
pub struct PreparedThreadMove {
    owner: Uuid,
    store: (PathBuf, crate::private_fs::Identity),
    row: SidebarRow,
    from: Folder,
    to: Folder,
    original: Value,
}
impl PreparedThreadMove {
    pub fn thread_id(&self) -> &str {
        &self.row.id
    }
    pub fn title(&self) -> String {
        text(&self.original, "title")
    }
    pub fn destination(&self) -> &Path {
        &self.to.path
    }
}
pub struct ThreadMoveUndo {
    owner: Uuid,
    store: (PathBuf, crate::private_fs::Identity),
    original: Value,
    destination: String,
    token: Uuid,
    external: i64,
    from: Folder,
    to: Folder,
}
fn clear_sessions(thread: &mut Value) {
    thread["sessions"] = json!({});
    thread.as_object_mut().unwrap().remove("accountSessions");
    thread.as_object_mut().unwrap().remove("branch");
}
fn ordinary_move(thread: &Value, target: &str) -> Result<()> {
    ensure!(
        thread["botID"].is_null() && thread["rustBotContext"].is_null(),
        "Bot conversations stay with their bot"
    );
    ensure!(
        thread["worktreePath"].is_null(),
        "A worktree conversation stays with its repository"
    );
    ensure!(
        target != crate::bot_runtime::BOTS_PROJECT_ID
            && thread["projectID"].as_str() != Some(target),
        "Choose another ordinary project"
    );
    Ok(())
}
fn project_folder(projects: &Value, id: &str) -> Result<Folder> {
    let project = projects
        .as_array()
        .context("Invalid projects")?
        .iter()
        .find(|p| p["id"].as_str() == Some(id))
        .context("Project is unavailable")?;
    Folder::capture(required(project, "path")?)
}
impl Engine {
    pub fn prepare_native_thread_move(
        &mut self,
        id: &str,
        target: &str,
    ) -> Result<PreparedThreadMove> {
        self.archive_delete_admitted(&[id.into()], false)?;
        let original = self.store.thread(id)?;
        ordinary_move(&original, target)?;
        let projects = self.store.projects()?;
        let from = project_folder(&projects, required(&original, "projectID")?)?;
        let to = project_folder(&projects, target)?;
        let mut next = original.clone();
        next["projectID"] = json!(target);
        clear_sessions(&mut next);
        Ok(PreparedThreadMove {
            owner: self.thread_bulk_owner,
            store: self.store.delete_source_identity()?,
            row: self.store.capture_sidebar_row(&original, &next)?,
            from,
            to,
            original,
        })
    }
    pub fn apply_native_thread_move(
        &mut self,
        prepared: PreparedThreadMove,
    ) -> Result<ThreadMoveUndo> {
        ensure!(
            prepared.owner == self.thread_bulk_owner
                && prepared.store == self.store.delete_source_identity()?,
            "Move belongs to another app or Store"
        );
        self.archive_delete_admitted(&[prepared.row.id.clone()], false)?;
        prepared.from.validate()?;
        prepared.to.validate()?;
        self.store.validate_sidebar_row(&prepared.row)?;
        // Park only a real explicit departure, before cancelling the catalog.
        self.park_named_departure(&prepared.original)?;
        self.cancel_provider_restore();
        self.model_catalog
            .invalidate_deleted_threads(&[prepared.row.id.clone()]);
        self.store.apply_sidebar_row(&prepared.row)?;
        self.computer_use_selection_changed(Uuid::parse_str(&prepared.row.id)?);
        self.revision += 1;
        let next: Value = serde_json::from_str(&prepared.row.target)?;
        if self.native_move_undos.len() >= 256 {
            self.native_move_undos.clear();
        }
        let token = Uuid::new_v4();
        self.native_move_undos
            .insert(prepared.row.id.clone(), token);
        Ok(ThreadMoveUndo {
            owner: prepared.owner,
            store: prepared.store,
            destination: required(&next, "projectID")?.into(),
            token,
            external: self.store.sidebar_external_version()?,
            original: prepared.original,
            from: prepared.from,
            to: prepared.to,
        })
    }
    pub fn undo_native_thread_move(&mut self, undo: &ThreadMoveUndo) -> Result<()> {
        ensure!(
            undo.owner == self.thread_bulk_owner
                && undo.store == self.store.delete_source_identity()?,
            "Move Undo belongs to another app or Store"
        );
        let id = required(&undo.original, "id")?;
        self.archive_delete_admitted(&[id.into()], false)?;
        ensure!(
            self.native_move_undos.get(id) == Some(&undo.token)
                && self.store.sidebar_external_version()? == undo.external,
            "A later Move or external Store change invalidated this Undo"
        );
        undo.from.validate()?;
        undo.to.validate()?;
        let current = self.store.thread(id)?;
        ensure!(
            current["projectID"] == undo.destination,
            "Conversation is no longer in the moved project"
        );
        let old_project = required(&undo.original, "projectID")?;
        let projects = self.store.projects()?;
        let current_from = project_folder(&projects, old_project)?;
        let current_to = project_folder(&projects, &undo.destination)?;
        ensure!(
            current_from.path == undo.from.path
                && current_from.identity == undo.from.identity
                && current_to.path == undo.to.path
                && current_to.identity == undo.to.identity,
            "Project folder binding changed since the move"
        );
        ordinary_move(&current, old_project)?;
        let mut next = current.clone();
        next["projectID"] = json!(old_project);
        if current["items"] == undo.original["items"] {
            for field in ["sessions", "accountSessions", "branch"] {
                match undo.original.get(field) {
                    Some(value) => {
                        next[field] = value.clone();
                    }
                    None => {
                        next.as_object_mut().unwrap().remove(field);
                    }
                }
            }
        } else {
            clear_sessions(&mut next);
        }
        let row = self.store.capture_sidebar_row(&current, &next)?;
        self.park_named_departure(&current)?;
        self.cancel_provider_restore();
        self.model_catalog.invalidate_deleted_threads(&[id.into()]);
        self.store.apply_sidebar_row(&row)?;
        self.native_move_undos.remove(id);
        self.computer_use_selection_changed(Uuid::parse_str(id)?);
        self.revision += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, String, String, String) {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        let target = dir.path().join("target");
        std::fs::create_dir(&source).unwrap();
        std::fs::create_dir(&target).unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let a = store.create_project(&source, Some("Source")).unwrap();
        let b = store.create_project(&target, Some("Target")).unwrap();
        let a = required(&a, "id").unwrap().to_owned();
        let b = required(&b, "id").unwrap().to_owned();
        let mut thread = store.new_thread(&a).unwrap();
        thread["draft"] = json!("Keep exact draft 👩🏽‍💻");
        thread["items"] =
            json!([{"kind":"user","text":"Keep transcript","attachments":[{"opaque":[1,2]}]}]);
        thread["sessions"] =
            json!({"codex":{"sessionID":"descriptive-only-old","seenItemCount":1}});
        thread["accountSessions"] = json!({"codex/opaque":{"keep":true}});
        thread["branch"] = json!("main");
        thread["future"] = json!({"opaque":[3,4]});
        store.save(&thread).unwrap();
        let id = required(&thread, "id").unwrap().to_owned();
        (dir, Engine::fixture(store), id, a, b)
    }
    #[test]
    fn absent_private_undo_token_and_external_aba_cannot_be_adopted() {
        let (dir, mut engine, id, _, b) = fixture();
        let plan = engine.prepare_native_thread_move(&id, &b).unwrap();
        let undo = engine.apply_native_thread_move(plan).unwrap();
        let moved = engine.store.thread(&id).unwrap();
        engine.native_move_undos.clear();
        assert!(engine.undo_native_thread_move(&undo).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), moved);
        let mut other = Store::open(&dir.path().join("state.sqlite")).unwrap();
        // Even reinstating the private token cannot erase observed external ABA.
        engine.native_move_undos.insert(id.clone(), undo.token);
        other
            .patch_thread(&id, &json!({"draft":"External transient"}))
            .unwrap();
        other.save(&moved).unwrap();
        assert!(engine.undo_native_thread_move(&undo).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), moved);
    }
    #[test]
    fn old_move_undo_cannot_cross_a_later_native_move_intent() {
        let (_dir, mut engine, id, _, b) = fixture();
        let first = engine.prepare_native_thread_move(&id, &b).unwrap();
        let first = engine.apply_native_thread_move(first).unwrap();
        engine.undo_native_thread_move(&first).unwrap();
        let second = engine.prepare_native_thread_move(&id, &b).unwrap();
        let second = engine.apply_native_thread_move(second).unwrap();
        let before = engine.store.thread(&id).unwrap();
        assert!(engine.undo_native_thread_move(&first).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        engine.undo_native_thread_move(&second).unwrap();
    }
    #[test]
    fn real_owned_worker_return_is_required_before_move_or_ordinary_delete_review() {
        use std::{
            sync::mpsc,
            time::{Duration, Instant},
        };
        let (_dir, mut engine, id, _, b) = fixture();
        let before = engine.store.thread(&id).unwrap();
        let (release_tx, release_rx) = mpsc::channel();
        let worker = crate::agent::WorkerCompletion::observe(std::thread::spawn(move || {
            release_rx.recv().unwrap();
        }));
        engine.provider_workers.push(worker.clone());
        assert!(engine.prepare_native_thread_move(&id, &b).is_err());
        assert!(
            engine
                .prepare_native_conversation_deletion(&[id.clone()])
                .is_err()
        );
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while worker.status() == crate::agent::WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(worker.status(), crate::agent::WorkerThreadStatus::Returned);
        assert!(engine.prepare_native_thread_move(&id, &b).is_ok());
        assert!(engine.prepare_native_conversation_deletion(&[id]).is_ok());
    }
    #[test]
    fn native_move_clears_foreign_folder_sessions_and_untouched_undo_preserves_every_other_field() {
        let (_dir, mut engine, id, a, b) = fixture();
        let before = engine.store.thread(&id).unwrap();
        let plan = engine.prepare_native_thread_move(&id, &b).unwrap();
        let undo = engine.apply_native_thread_move(plan).unwrap();
        let mut expected = before.clone();
        expected["projectID"] = json!(b);
        clear_sessions(&mut expected);
        assert_eq!(engine.store.thread(&id).unwrap(), expected);
        let mut edited = engine.store.thread(&id).unwrap();
        edited["draft"] = json!("Typed after move; preserve on Undo");
        edited["future"] = json!({"keep":"new"});
        engine.store.save(&edited).unwrap();
        expected = before.clone();
        expected["draft"] = json!("Typed after move; preserve on Undo");
        expected["future"] = json!({"keep":"new"});
        engine.undo_native_thread_move(&undo).unwrap();
        assert_eq!(engine.store.thread(&id).unwrap(), expected);
        assert_eq!(engine.store.thread(&id).unwrap()["projectID"], a);
        assert!(engine.undo_native_thread_move(&undo).is_err());
    }
    #[test]
    fn target_turn_then_undo_keeps_new_content_but_never_adopts_target_session_in_old_folder() {
        let (_dir, mut engine, id, a, b) = fixture();
        let plan = engine.prepare_native_thread_move(&id, &b).unwrap();
        let undo = engine.apply_native_thread_move(plan).unwrap();
        let mut thread = engine.store.thread(&id).unwrap();
        thread["items"]
            .as_array_mut()
            .unwrap()
            .push(json!({"kind":"assistant","text":"New target-folder reply"}));
        thread["sessions"] = json!({"codex":{"sessionID":"new-target-folder-native"}});
        thread["branch"] = json!("target-branch");
        engine.store.save(&thread).unwrap();
        let mut expected = thread;
        expected["projectID"] = json!(a);
        clear_sessions(&mut expected);
        engine.undo_native_thread_move(&undo).unwrap();
        assert_eq!(engine.store.thread(&id).unwrap(), expected);
    }
    #[test]
    fn two_connection_aba_and_worktree_and_folder_replacement_refuse_without_thread_writes() {
        let (dir, mut engine, id, _, b) = fixture();
        let before = engine.store.thread(&id).unwrap();
        let plan = engine.prepare_native_thread_move(&id, &b).unwrap();
        let mut other = Store::open(&dir.path().join("state.sqlite")).unwrap();
        other
            .patch_thread(&id, &json!({"draft":"Temporary external change"}))
            .unwrap();
        other.save(&before).unwrap();
        assert!(engine.apply_native_thread_move(plan).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        let mut worktree = before.clone();
        worktree["worktreePath"] = json!(dir.path().join("source"));
        engine.store.save(&worktree).unwrap();
        assert!(engine.prepare_native_thread_move(&id, &b).is_err());
        engine.store.save(&before).unwrap();
        let plan = engine.prepare_native_thread_move(&id, &b).unwrap();
        std::fs::rename(dir.path().join("target"), dir.path().join("target-old")).unwrap();
        std::fs::create_dir(dir.path().join("target")).unwrap();
        assert!(engine.apply_native_thread_move(plan).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
    }
}
