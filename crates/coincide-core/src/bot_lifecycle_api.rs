//! Native reviewed bot removal; its tasks and conversations change atomically.
use super::*;
use crate::store::{BotLifecycle, BotLifecycleUndo};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BotConversationDisposition {
    KeepAsChats,
    Delete,
}
pub struct PreparedBotDeletion {
    owner: Uuid,
    source: (PathBuf, crate::private_fs::Identity),
    plan: BotLifecycle,
    data_root: (PathBuf, crate::private_fs::Identity),
    chats: Option<(PathBuf, crate::private_fs::Identity)>,
}
impl PreparedBotDeletion {
    pub fn name(&self) -> String {
        text(&self.plan.bot, "name")
    }
    pub fn conversation_count(&self) -> usize {
        self.plan.rows.len()
    }
    pub fn task_count(&self) -> usize {
        self.plan.task_count
    }
    pub fn disposition(&self) -> BotConversationDisposition {
        if self.plan.deleting {
            BotConversationDisposition::Delete
        } else {
            BotConversationDisposition::KeepAsChats
        }
    }
    pub fn new_chats_folder(&self) -> Option<&std::path::Path> {
        self.plan.chats_folder.as_deref()
    }
    pub fn chats_folder(&self) -> Option<&std::path::Path> {
        self.plan
            .chats_folder
            .as_deref()
            .or_else(|| self.chats.as_ref().map(|folder| folder.0.as_path()))
    }
}
pub struct BotDeletionUndo {
    owner: Uuid,
    source: (PathBuf, crate::private_fs::Identity),
    receipt: BotLifecycleUndo,
}
impl BotDeletionUndo {
    pub fn conversation_count(&self) -> usize {
        self.receipt.thread_ids().len()
    }
}
fn folder_identity(path: &std::path::Path) -> Result<(PathBuf, crate::private_fs::Identity)> {
    ensure!(
        path.is_absolute() && path.is_dir(),
        "Chats folder is unavailable"
    );
    let path = path.canonicalize()?;
    Ok((path.clone(), crate::private_fs::identity(&path)?))
}
fn validate_folder(folder: &(PathBuf, crate::private_fs::Identity)) -> Result<()> {
    ensure!(
        folder.0.is_dir() && crate::private_fs::identity(&folder.0)? == folder.1,
        "Reviewed folder identity changed"
    );
    Ok(())
}
impl Engine {
    /// Native Stop-and-review only: requests cancellation of this selected
    /// bot's actual running conversations; the caller must still wait for joins.
    pub fn request_native_bot_stop(&mut self, bot: &str) -> Result<usize> {
        let plan = self.store.prepare_bot_lifecycle(bot, true)?;
        let mut stopped = 0;
        for row in &plan.rows {
            if self.runs.contains_key(&row.id) {
                self.request_provider_stop(&row.id)?;
                stopped += 1;
            }
        }
        Ok(stopped)
    }
    pub fn prepare_native_bot_deletion(
        &mut self,
        bot: &str,
        disposition: BotConversationDisposition,
    ) -> Result<PreparedBotDeletion> {
        self.require_admissions()?;
        let plan = self
            .store
            .prepare_bot_lifecycle(bot, disposition == BotConversationDisposition::Delete)?;
        let ids = plan.rows.iter().map(|r| r.id.clone()).collect::<Vec<_>>();
        self.archive_delete_admitted(&ids, false)?;
        let chats = if !plan.deleting && plan.chats_folder.is_none() && !plan.targets.is_empty() {
            let project = text(&plan.targets[0], "projectID");
            let projects = self.store.projects()?;
            let row = projects
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["id"] == project)
                .context("Chats project changed")?;
            Some(folder_identity(std::path::Path::new(required(
                row, "path",
            )?))?)
        } else {
            None
        };
        Ok(PreparedBotDeletion {
            owner: self.thread_bulk_owner,
            source: self.store.delete_source_identity()?,
            data_root: folder_identity(&self.store.data_directory()?)?,
            plan,
            chats,
        })
    }
    pub fn apply_native_bot_deletion(
        &mut self,
        mut review: PreparedBotDeletion,
    ) -> Result<BotDeletionUndo> {
        ensure!(
            review.owner == self.thread_bulk_owner
                && review.source == self.store.delete_source_identity()?,
            "Bot review belongs to another app or Store"
        );
        let ids = review
            .plan
            .rows
            .iter()
            .map(|r| r.id.clone())
            .collect::<Vec<_>>();
        self.archive_delete_admitted(&ids, false)?;
        validate_folder(&review.data_root)?;
        if let Some(folder) = &review.chats {
            validate_folder(folder)?;
        }
        self.store.validate_bot_lifecycle(&review.plan)?;
        if let Some(folder) = &review.plan.chats_folder {
            ensure!(
                folder.parent() == Some(review.data_root.0.as_path()),
                "Chats creation is outside this Store"
            );
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                std::fs::DirBuilder::new().mode(0o700).create(folder)?;
            }
            #[cfg(not(unix))]
            {
                std::fs::create_dir(folder)?;
            }
            crate::native_file::private_directory(folder)
                .context("New Chats folder could not be validated; it was retained for recovery")?;
        }
        if self
            .active_thread()
            .is_some_and(|active| ids.iter().any(|id| id.eq_ignore_ascii_case(active)))
        {
            self.cancel_provider_restore();
        }
        self.model_catalog.invalidate_deleted_threads(&ids);
        let revoked = self.named_resume.invalidate_threads(&ids, &self.store)?;
        for (thread, native) in revoked {
            let row = review
                .plan
                .rows
                .iter_mut()
                .find(|row| row.id.eq_ignore_ascii_case(&thread))
                .context("Private bot continuation belongs to another conversation")?;
            row.revoke_native(&native)?;
        }
        let receipt = self.store.apply_bot_lifecycle(review.plan)?;
        for id in &ids {
            self.enabled_queues.remove(id);
            self.computer_use_thread_removed(Uuid::parse_str(id)?);
        }
        self.notification_events.discard_deleted_threads(&ids);
        if self
            .active_thread()
            .is_some_and(|active| ids.iter().any(|id| id.eq_ignore_ascii_case(active)))
        {
            self.active_thread = None;
            self.requested_open = None;
        }
        self.revision += 1;
        Ok(BotDeletionUndo {
            owner: review.owner,
            source: review.source,
            receipt,
        })
    }
    pub fn undo_native_bot_deletion(&mut self, undo: &BotDeletionUndo) -> Result<()> {
        ensure!(
            undo.owner == self.thread_bulk_owner
                && undo.source == self.store.delete_source_identity()?,
            "Bot Undo belongs to another app or Store"
        );
        self.archive_delete_admitted(&undo.receipt.thread_ids(), false)?;
        self.store.undo_bot_lifecycle(&undo.receipt)?;
        self.revision += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(chats: bool) -> (tempfile::TempDir, Engine, String, String, String) {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        crate::native_file::private_directory(&data).unwrap();
        let bot = Uuid::new_v4().to_string();
        let other = Uuid::new_v4().to_string();
        let mut store = Store::open(&data.join("state.sqlite")).unwrap();
        if chats {
            let folder = dir.path().join("chats");
            std::fs::create_dir(&folder).unwrap();
            let mut project = store.create_project(&folder, Some("Chats")).unwrap();
            project["isChats"] = json!(true);
            store
                .save_document("projects.json", &json!([project]))
                .unwrap();
        }
        store.save_document("bots.json",&json!({"bots":[{"id":bot,"name":"Reviewed Bot","unknown":{"keep":1}},{"id":other,"name":"Other Bot"}],"future":{"keep":[1,2]},"addedStarters":true})).unwrap();
        let mut thread = store
            .new_thread(crate::bot_runtime::BOTS_PROJECT_ID)
            .unwrap();
        let id = required(&thread, "id").unwrap().to_owned();
        let context = json!({"version":1,"botId":bot,"instructions":"Synthetic retained bot snapshot","cwd":dir.path()});
        thread["botID"] = json!(bot);
        thread["rustBotContext"] = context.clone();
        thread["worktreePath"] = json!(dir.path());
        thread["draft"] = json!("Keep full draft");
        thread["items"] =
            json!([{"kind":"user","text":"Keep full transcript","images":[{"unknown":true}]}]);
        thread["sessions"] =
            json!({"codex":{"sessionID":"synthetic-old-bot-native","seenItemCount":1}});
        thread["future"] = json!({"keep":"opaque"});
        store.save(&thread).unwrap();
        let context_name = crate::bot_runtime::context_document_name(&context).unwrap();
        store.save_document(&context_name, &context).unwrap();
        store.save_document("scheduled-tasks.json",&json!({"tasks":[{"id":"selected-task","threadID":id,"future":7},{"id":"other-task","threadID":Uuid::new_v4().to_string(),"future":8}],"unknown":{"keep":true}})).unwrap();
        (dir, Engine::fixture(store), bot, id, context_name)
    }
    #[test]
    fn an_older_archive_undo_cannot_reauthorize_a_deleted_bots_local_instruction_snapshot() {
        let (_dir, mut engine, bot, id, context) = fixture(true);
        // This regression archives the conversation before deleting its bot.
        // Keep the fixture's opaque schedule envelope, but target its synthetic
        // task elsewhere so the ordinary archive-deletion guard remains valid.
        let mut schedules = engine
            .store
            .document("scheduled-tasks.json")
            .unwrap()
            .unwrap();
        schedules["tasks"][0]["threadID"] = json!(Uuid::new_v4().to_string());
        engine
            .store
            .save_document("scheduled-tasks.json", &schedules)
            .unwrap();
        let mut thread = engine.store.thread(&id).unwrap();
        thread["isArchived"] = json!(true);
        engine.store.save(&thread).unwrap();
        let archived = engine
            .prepare_native_thread_deletion(std::slice::from_ref(&id))
            .unwrap();
        let archived = engine.apply_native_thread_deletion(archived).unwrap();
        assert!(engine.store.local_document(&context).unwrap().is_some());
        let plan = engine
            .prepare_native_bot_deletion(&bot, BotConversationDisposition::Delete)
            .unwrap();
        assert_eq!(plan.conversation_count(), 0);
        let _undo = engine.apply_native_bot_deletion(plan).unwrap();
        assert!(engine.store.local_document(&context).unwrap().is_none());
        engine.undo_native_thread_deletion(&archived).unwrap();
        let restored = engine.store.thread(&id).unwrap();
        assert!(
            engine
                .bot_instructions(
                    &restored,
                    std::path::Path::new(restored["rustBotContext"]["cwd"].as_str().unwrap())
                )
                .is_err()
        );
    }
    #[test]
    fn both_native_bot_delete_modes_and_undo_are_atomic_preserve_unknowns_and_deny_old_sessions() {
        for mode in [
            BotConversationDisposition::KeepAsChats,
            BotConversationDisposition::Delete,
        ] {
            let (_dir, mut engine, bot, id, context) = fixture(true);
            let before = engine.store.thread(&id).unwrap();
            let bots = engine.store.document("bots.json").unwrap();
            let tasks = engine.store.document("scheduled-tasks.json").unwrap();
            let projects = engine.store.document("projects.json").unwrap();
            let authorization = engine.store.local_document(&context).unwrap();
            let plan = engine.prepare_native_bot_deletion(&bot, mode).unwrap();
            assert_eq!(plan.conversation_count(), 1);
            assert_eq!(plan.task_count(), 1);
            let undo = engine.apply_native_bot_deletion(plan).unwrap();
            assert_eq!(
                engine.store.document("bots.json").unwrap().unwrap()["bots"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );
            assert_eq!(
                engine
                    .store
                    .document("scheduled-tasks.json")
                    .unwrap()
                    .unwrap()["tasks"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );
            assert!(engine.store.local_document(&context).unwrap().is_none());
            if mode == BotConversationDisposition::KeepAsChats {
                let kept = engine.store.thread(&id).unwrap();
                assert_eq!(kept["draft"], before["draft"]);
                assert_eq!(kept["items"], before["items"]);
                assert_eq!(kept["future"], before["future"]);
                for key in [
                    "botID",
                    "rustBotContext",
                    "worktreePath",
                    "accountSessions",
                    "branch",
                ] {
                    assert!(kept.get(key).is_none());
                }
                assert_eq!(kept["sessions"], json!({}));
            } else {
                assert!(engine.store.thread(&id).is_err());
            }
            assert!(
                engine
                    .store
                    .is_native_session_revoked(&id, "synthetic-old-bot-native")
                    .unwrap()
            );
            engine.undo_native_bot_deletion(&undo).unwrap();
            assert_eq!(engine.store.thread(&id).unwrap(), before);
            assert_eq!(engine.store.document("bots.json").unwrap(), bots);
            assert_eq!(
                engine.store.document("scheduled-tasks.json").unwrap(),
                tasks
            );
            assert_eq!(engine.store.document("projects.json").unwrap(), projects);
            assert_eq!(
                engine.store.local_document(&context).unwrap(),
                authorization
            );
            assert!(
                engine
                    .store
                    .is_native_session_revoked(&id, "synthetic-old-bot-native")
                    .unwrap()
            );
            assert!(engine.undo_native_bot_deletion(&undo).is_err());
        }
    }
    #[test]
    fn external_aba_or_kept_conversation_change_refuses_without_partial_bot_or_task_loss() {
        let (dir, mut engine, bot, id, _) = fixture(true);
        let before = engine.store.thread(&id).unwrap();
        let bots = engine.store.document("bots.json").unwrap();
        let tasks = engine.store.document("scheduled-tasks.json").unwrap();
        let plan = engine
            .prepare_native_bot_deletion(&bot, BotConversationDisposition::Delete)
            .unwrap();
        let mut other = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
        other
            .patch_thread(&id, &json!({"draft":"External transient"}))
            .unwrap();
        other.save(&before).unwrap();
        assert!(engine.apply_native_bot_deletion(plan).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(engine.store.document("bots.json").unwrap(), bots);
        assert_eq!(
            engine.store.document("scheduled-tasks.json").unwrap(),
            tasks
        );
        let plan = engine
            .prepare_native_bot_deletion(&bot, BotConversationDisposition::KeepAsChats)
            .unwrap();
        let undo = engine.apply_native_bot_deletion(plan).unwrap();
        let removed_bots = engine.store.document("bots.json").unwrap();
        let removed_tasks = engine.store.document("scheduled-tasks.json").unwrap();
        other
            .patch_thread(&id, &json!({"draft":"New kept-chat edit"}))
            .unwrap();
        assert!(engine.undo_native_bot_deletion(&undo).is_err());
        assert_eq!(engine.store.document("bots.json").unwrap(), removed_bots);
        assert_eq!(
            engine.store.document("scheduled-tasks.json").unwrap(),
            removed_tasks
        );
        assert_eq!(
            engine.store.thread(&id).unwrap()["draft"],
            "New kept-chat edit"
        );
    }
    #[test]
    fn new_chats_creation_is_reviewed_and_a_racing_directory_is_not_adopted() {
        let (_dir, mut engine, bot, id, _) = fixture(false);
        let before = engine.store.thread(&id).unwrap();
        let bots = engine.store.document("bots.json").unwrap();
        let plan = engine
            .prepare_native_bot_deletion(&bot, BotConversationDisposition::KeepAsChats)
            .unwrap();
        let folder = plan.new_chats_folder().unwrap().to_owned();
        assert!(!folder.exists());
        std::fs::create_dir(&folder).unwrap();
        std::fs::write(folder.join("foreign.txt"), "Do not touch").unwrap();
        assert!(engine.apply_native_bot_deletion(plan).is_err());
        assert_eq!(
            std::fs::read(folder.join("foreign.txt")).unwrap(),
            b"Do not touch"
        );
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(engine.store.document("bots.json").unwrap(), bots);
    }
}
