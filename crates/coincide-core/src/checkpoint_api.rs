//! Engine ownership of per-turn checkpoints (Swift CheckpointService). The
//! before snapshot runs on the provider worker ahead of the agent, the after
//! snapshot on a background worker once the turn ends, and each thread's index
//! lives in the Store. Rewind truncates the same conversation and restores its
//! message to the draft; restoring files is a separate, confirmed choice.
use super::*;
use crate::turn_checkpoints::{self as checkpoints, ChangedFile, TurnCheckpoint};
use std::path::Path;

pub(super) const METHODS: &[&str] = &[
    "checkpoints.list",
    "checkpoints.diff",
    "checkpoints.canRestore",
    "threads.rewind",
];

const UNAVAILABLE: &str = "There is no checkpoint for this turn.";
const MISSING_FOLDER: &str = "The folder this turn ran in no longer exists.";
const SHARED_FOLDER: &str = "Another thread has worked in this folder since this turn, so restoring files would undo its changes too. Rewind the conversation without restoring files instead.";

type BeforeSlot = Arc<Mutex<Option<std::result::Result<(String, f64), String>>>>;

struct PendingBefore {
    user_item_id: String,
    cwd: PathBuf,
    slot: BeforeSlot,
    recorded: bool,
}

struct AfterCapture {
    thread_id: String,
    user_item_id: String,
    result: std::result::Result<(String, Vec<ChangedFile>), String>,
    at: f64,
}

pub(super) struct State {
    cache: HashMap<String, Vec<TurnCheckpoint>>,
    /// The running turn's before snapshot, by thread (one turn at a time).
    before: HashMap<String, PendingBefore>,
    tx: std::sync::mpsc::Sender<AfterCapture>,
    rx: std::sync::mpsc::Receiver<AfterCapture>,
}
impl Default for State {
    fn default() -> Self {
        let (tx, rx) = std::sync::mpsc::channel();
        Self {
            cache: HashMap::new(),
            before: HashMap::new(),
            tx,
            rx,
        }
    }
}

fn document_name(thread_id: &str) -> Result<String> {
    let id = Uuid::parse_str(thread_id).context("Invalid thread ID")?;
    Ok(format!(
        "checkpoints-{}.json",
        id.hyphenated().to_string().to_uppercase()
    ))
}

fn same_id(a: &str, b: &str) -> bool {
    a == b || matches!((Uuid::parse_str(a), Uuid::parse_str(b)), (Ok(a), Ok(b)) if a == b)
}

fn file_json(file: &ChangedFile) -> Value {
    serde_json::to_value(file).unwrap_or(Value::Null)
}

impl Engine {
    fn checkpoints_enabled(&self) -> bool {
        self.store
            .document("settings.json")
            .ok()
            .flatten()
            .and_then(|settings| settings["checkpointsEnabled"].as_bool())
            .unwrap_or(true)
    }

    /// The thread's checkpoints, oldest first. A thread imported from the
    /// Swift app keeps reading the index that app saved beside it.
    fn turn_checkpoints(&mut self, thread_id: &str) -> Vec<TurnCheckpoint> {
        if let Some(cached) = self.turn_checkpoints.cache.get(thread_id) {
            return cached.clone();
        }
        let loaded = document_name(thread_id)
            .ok()
            .and_then(|name| self.store.local_document(&name).ok().flatten())
            .and_then(|value| serde_json::from_value(value).ok())
            .or_else(|| {
                let id = Uuid::parse_str(thread_id).ok()?.hyphenated().to_string();
                let original = self
                    .store
                    .original(&format!("checkpoints/{}.json", id.to_uppercase()))
                    .ok()
                    .flatten()?;
                Some(checkpoints::parse_swift_index(&original))
            })
            .unwrap_or_default();
        self.turn_checkpoints
            .cache
            .insert(thread_id.to_owned(), loaded.clone());
        loaded
    }

    fn save_turn_checkpoints(&mut self, thread_id: &str, turns: Vec<TurnCheckpoint>) {
        if let Ok(name) = document_name(thread_id)
            && let Ok(value) = serde_json::to_value(&turns)
            && let Err(error) = self.store.save_document(&name, &value)
        {
            self.schedule_error = Some(format!("Checkpoints could not be saved: {error}"));
        }
        self.turn_checkpoints
            .cache
            .insert(thread_id.to_owned(), turns);
    }

    /// Work the provider worker runs before launching the agent, or None when
    /// this turn is not snapshotted (disabled, a broad bot folder, bad IDs).
    pub(super) fn prepare_turn_checkpoint(
        &mut self,
        thread_id: &str,
        user_item_id: &str,
        cwd: &Path,
    ) -> Option<Box<dyn FnOnce() + Send>> {
        if !self.checkpoints_enabled() || checkpoints::broad_folder(cwd) {
            return None;
        }
        let reference = checkpoints::reference(thread_id, user_item_id, "before").ok()?;
        let slot: BeforeSlot = Arc::default();
        self.turn_checkpoints.before.insert(
            thread_id.to_owned(),
            PendingBefore {
                user_item_id: user_item_id.to_owned(),
                cwd: cwd.to_path_buf(),
                slot: slot.clone(),
                recorded: false,
            },
        );
        let cwd = cwd.to_path_buf();
        Some(Box::new(move || {
            // Taken before waiting for the folder, so a change the snapshot
            // may have missed counts as made after it.
            let at = swift_timestamp();
            let result = checkpoints::capture(&cwd, Some(&reference))
                .map(|commit| (commit, at))
                .map_err(|error| error.to_string());
            *slot.lock().unwrap_or_else(|error| error.into_inner()) = Some(result);
        }))
    }

    fn record_before(&mut self, thread_id: &str) {
        let Some(pending) = self.turn_checkpoints.before.get_mut(thread_id) else {
            return;
        };
        if pending.recorded {
            return;
        }
        let Some(Ok((commit, at))) = pending
            .slot
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone()
        else {
            return;
        };
        pending.recorded = true;
        let user_item_id = pending.user_item_id.clone();
        let cwd = pending.cwd.clone();
        let mut turns = self.turn_checkpoints(thread_id);
        let checkpoint = TurnCheckpoint {
            user_item_id: user_item_id.clone(),
            cwd: cwd.to_string_lossy().into_owned(),
            before: Some(commit),
            before_at: Some(at),
            after: None,
            after_at: None,
            files: Vec::new(),
        };
        match turns
            .iter_mut()
            .find(|turn| same_id(&turn.user_item_id, &user_item_id))
        {
            Some(turn) => *turn = checkpoint,
            None => turns.push(checkpoint),
        }
        // Turns cut from the transcript are forgotten only once the next turn
        // starts, so a rewind can still restore files after truncating.
        let present = self
            .unsaved_threads
            .get(thread_id)
            .cloned()
            .or_else(|| self.store.thread(thread_id).ok())
            .map(|thread| user_item_ids(&thread))
            .unwrap_or_default();
        let (kept, stale): (Vec<_>, Vec<_>) = turns.into_iter().partition(|turn| {
            same_id(&turn.user_item_id, &user_item_id)
                || present.iter().any(|id| same_id(id, &turn.user_item_id))
        });
        self.save_turn_checkpoints(thread_id, kept);
        self.delete_checkpoint_refs(thread_id, &stale);
        self.revision += 1;
    }

    fn delete_checkpoint_refs(&mut self, thread_id: &str, stale: &[TurnCheckpoint]) {
        let mut groups: HashMap<String, Vec<String>> = HashMap::new();
        for turn in stale {
            for phase in ["before", "after"] {
                if let Ok(reference) = checkpoints::reference(thread_id, &turn.user_item_id, phase)
                {
                    groups.entry(turn.cwd.clone()).or_default().push(reference);
                }
            }
        }
        if groups.is_empty() || self.background_workers.check_admission().is_err() {
            return;
        }
        let worker = std::thread::spawn(move || {
            for (cwd, references) in groups {
                checkpoints::delete_refs(Path::new(&cwd), &references);
            }
        });
        self.background_workers.track(worker);
    }

    /// The turn ended: snapshot the folder again and work out what changed.
    pub(super) fn finish_turn_checkpoint(&mut self, thread_id: &str) {
        self.record_before(thread_id);
        let Some(pending) = self.turn_checkpoints.before.remove(thread_id) else {
            return;
        };
        let Some(Ok((before, _))) = pending
            .slot
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone()
        else {
            return;
        };
        let Ok(reference) = checkpoints::reference(thread_id, &pending.user_item_id, "after")
        else {
            return;
        };
        if self.background_workers.check_admission().is_err() {
            return;
        }
        let tx = self.turn_checkpoints.tx.clone();
        let thread_id = thread_id.to_owned();
        let activity = self.idle_sleep.background_job();
        let worker = std::thread::spawn(move || {
            let _activity = activity;
            let result = checkpoints::capture(&pending.cwd, Some(&reference))
                .and_then(|after| {
                    let files = checkpoints::changed_files(&pending.cwd, &before, &after)?;
                    Ok((after, files))
                })
                .map_err(|error| error.to_string());
            let _ = tx.send(AfterCapture {
                thread_id,
                user_item_id: pending.user_item_id,
                result,
                at: swift_timestamp(),
            });
        });
        self.background_workers.track(worker);
    }

    pub(super) fn poll_turn_checkpoints(&mut self) {
        let waiting = self
            .turn_checkpoints
            .before
            .iter()
            .filter(|(_, pending)| !pending.recorded)
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for id in waiting {
            self.record_before(&id);
        }
        let finished = self.turn_checkpoints.rx.try_iter().collect::<Vec<_>>();
        for capture in finished {
            let Ok((after, files)) = capture.result else {
                continue;
            };
            let mut turns = self.turn_checkpoints(&capture.thread_id);
            let Some(turn) = turns
                .iter_mut()
                .find(|turn| same_id(&turn.user_item_id, &capture.user_item_id))
            else {
                continue;
            };
            turn.after = Some(after);
            turn.after_at = Some(capture.at);
            turn.files = files;
            self.save_turn_checkpoints(&capture.thread_id, turns);
            self.revision += 1;
        }
    }

    fn checkpoint(&mut self, thread_id: &str, user_item_id: &str) -> Option<TurnCheckpoint> {
        self.turn_checkpoints(thread_id)
            .into_iter()
            .find(|turn| same_id(&turn.user_item_id, user_item_id))
    }

    /// Restoring rewrites the whole folder, so it is refused when another
    /// thread has worked in the same folder (or one inside or around it) since
    /// the snapshot was taken, or is running there now.
    fn restore_isolated(&self, thread_id: &str, cwd: &Path, since: f64) -> Result<bool> {
        let resolve = |path: PathBuf| path.canonicalize().unwrap_or(path);
        let target = resolve(cwd.to_path_buf());
        for summary in self.store.summaries("", true)? {
            if same_id(&summary.id, thread_id) {
                continue;
            }
            let running = self.runs.contains_key(&summary.id);
            let updated = summary
                .navigation
                .as_ref()
                .and_then(|navigation| navigation.updated_at);
            if !running && updated.is_some_and(|updated| updated <= since) {
                continue;
            }
            let Ok(other) = self.store.thread(&summary.id) else {
                continue;
            };
            if !running
                && other["updatedAt"]
                    .as_f64()
                    .is_some_and(|updated| updated <= since)
            {
                continue;
            }
            let Ok(folder) = self.working_directory(&other) else {
                continue;
            };
            let folder = resolve(folder);
            if folder.starts_with(&target) || target.starts_with(&folder) {
                return Ok(false);
            }
        }
        Ok(true)
    }

    fn can_restore_turn(&mut self, thread_id: &str, user_item_id: &str) -> Result<bool> {
        let Some(checkpoint) = self.checkpoint(thread_id, user_item_id) else {
            return Ok(false);
        };
        let (Some(_), Some(since)) = (&checkpoint.before, checkpoint.before_at) else {
            return Ok(false);
        };
        if !Path::new(&checkpoint.cwd).is_dir() {
            return Ok(false);
        }
        self.restore_isolated(thread_id, Path::new(&checkpoint.cwd), since)
    }

    pub(super) fn checkpoint_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        let thread_id = required(p, "threadId")?.to_owned();
        match method {
            "checkpoints.list" => {
                let thread = match self.unsaved_threads.get(&thread_id) {
                    Some(thread) => thread.clone(),
                    None => self.store.thread(&thread_id)?,
                };
                let present = user_item_ids(&thread);
                let running = self
                    .turn_checkpoints
                    .before
                    .get(&thread_id)
                    .map(|pending| pending.user_item_id.clone());
                let turns = self
                    .turn_checkpoints(&thread_id)
                    .into_iter()
                    .filter(|turn| present.iter().any(|id| same_id(id, &turn.user_item_id)))
                    .map(|turn| {
                        json!({
                            "userItemID": turn.user_item_id,
                            "complete": turn.is_complete(),
                            "running": running.as_deref().is_some_and(|id| same_id(id, &turn.user_item_id)),
                            "files": turn.files.iter().map(file_json).collect::<Vec<_>>(),
                        })
                    })
                    .collect::<Vec<_>>();
                Ok(json!({"turns": turns}))
            }
            "checkpoints.canRestore" => {
                let item = required(p, "userItemId")?;
                Ok(json!({"canRestore": self.can_restore_turn(&thread_id, item)?}))
            }
            "checkpoints.diff" => {
                let item = required(p, "userItemId")?;
                let checkpoint = self.checkpoint(&thread_id, item).context(UNAVAILABLE)?;
                let (Some(before), Some(after)) = (&checkpoint.before, &checkpoint.after) else {
                    bail!(UNAVAILABLE);
                };
                let cwd = PathBuf::from(&checkpoint.cwd);
                ensure!(cwd.is_dir(), MISSING_FOLDER);
                // A finished turn's diff covers only the files it wrote,
                // leaving out what a pull brought in.
                let mut paths = match p["path"].as_str() {
                    Some(path) => {
                        let file = checkpoint
                            .files
                            .iter()
                            .find(|file| file.path == path)
                            .context("The turn did not change this file")?;
                        std::iter::once(file.path.clone())
                            .chain(file.old_path.clone())
                            .collect::<Vec<_>>()
                    }
                    None => checkpoint
                        .files
                        .iter()
                        .flat_map(|file| {
                            std::iter::once(file.path.clone()).chain(file.old_path.clone())
                        })
                        .collect(),
                };
                if paths.is_empty() {
                    return Ok(json!({"diff":"","truncated":false}));
                }
                paths.dedup();
                let paths = (paths.len() <= 2000).then_some(paths);
                let patch = checkpoints::diff(&cwd, before, after, paths.as_deref())?;
                Ok(json!({"diff": patch.text, "truncated": patch.truncated}))
            }
            "threads.rewind" => self.rewind_thread(&thread_id, p),
            _ => bail!("Unsupported checkpoint command"),
        }
    }

    /// Swift's "Edit from here": the conversation is cut back to before the
    /// message, which returns to the draft. With revertFiles, files are first
    /// put back the way they were before the message's turn.
    fn rewind_thread(&mut self, thread_id: &str, p: &Value) -> Result<Value> {
        let item_id = required(p, "itemId")?;
        let revert = p["revertFiles"].as_bool().unwrap_or(false);
        ensure!(
            !self.unsaved_threads.contains_key(thread_id),
            "Transcript persistence is recovering; retry after recovery"
        );
        ensure!(
            !self.runs.contains_key(thread_id),
            "Stop the running turn before editing an earlier message"
        );
        ensure!(
            !self.store.is_imported(thread_id)?,
            "Imported conversations are read-only until cutover; edit in a new branch instead"
        );
        let mut thread = self.store.thread(thread_id)?;
        let items = thread["items"]
            .as_array()
            .context("Thread transcript is malformed")?;
        let index = items
            .iter()
            .position(|item| item["id"].as_str().is_some_and(|id| same_id(id, item_id)))
            .context("Selected item is no longer in the conversation")?;
        let item = items[index].clone();
        ensure!(item["kind"] == "user", "Select a user message to edit");
        // Named Codex profiles also keep private continuations. Revoking them
        // is deny-only and comes first: a failure leaves files and transcript
        // as they were, while a later one only costs the next turn a fresh
        // session.
        if named_continuation_possible(&thread) {
            self.named_resume
                .invalidate_threads(&[thread_id.to_owned()], &self.store)?;
        }
        let mut restored = false;
        if revert {
            let checkpoint = self.checkpoint(thread_id, item_id).context(UNAVAILABLE)?;
            let before = checkpoint.before.clone().context(UNAVAILABLE)?;
            let cwd = PathBuf::from(&checkpoint.cwd);
            ensure!(cwd.is_dir(), MISSING_FOLDER);
            ensure!(
                self.restore_isolated(thread_id, &cwd, checkpoint.before_at.unwrap_or(f64::MIN))?,
                SHARED_FOLDER
            );
            checkpoints::restore(&cwd, &before)?;
            restored = true;
            // The history later checkpoints describe no longer exists.
            let mut turns = self.turn_checkpoints(thread_id);
            if let Some(start) = turns
                .iter()
                .position(|turn| same_id(&turn.user_item_id, item_id))
            {
                let stale = turns.split_off(start);
                self.save_turn_checkpoints(thread_id, turns);
                self.delete_checkpoint_refs(thread_id, &stale);
            }
        }
        let object = thread.as_object_mut().context("Thread must be an object")?;
        if let Some(items) = object.get_mut("items").and_then(Value::as_array_mut) {
            items.truncate(index);
        }
        // Native sessions have seen the removed turns, so they cannot be
        // resumed faithfully.
        object.insert("sessions".into(), json!({}));
        object.insert("accountSessions".into(), json!({}));
        object.insert("draft".into(), json!(item["text"].as_str().unwrap_or("")));
        object.insert(
            "draftContext".into(),
            item.get("context")
                .filter(|value| value.is_array())
                .cloned()
                .unwrap_or(json!([])),
        );
        object.insert(
            "rustDraftImages".into(),
            item.get("rustImages")
                .filter(|value| value.is_array())
                .cloned()
                .unwrap_or(json!([])),
        );
        // Legacy attachment paths stay inert; only the StoredImage flow imports.
        object.remove("rustLegacyDraftAttachments");
        if let Some(attachments) = item.get("attachments").filter(|value| value.is_array()) {
            object.insert("rustLegacyDraftAttachments".into(), attachments.clone());
        }
        object.insert("updatedAt".into(), json!(swift_timestamp()));
        self.store.save(&thread)?;
        self.revision += 1;
        Ok(json!({"thread": thread, "filesRestored": restored}))
    }
}

fn named_continuation_possible(thread: &Value) -> bool {
    codex_profile_models_api::named_thread(thread)
        || thread["accountSessions"]
            .as_object()
            .is_some_and(|sessions| {
                sessions.keys().any(|key| {
                    key.strip_prefix("codex/").is_some_and(|account| {
                        !crate::composer_selection::default_account(&json!(account))
                    })
                })
            })
}

fn user_item_ids(thread: &Value) -> Vec<String> {
    thread["items"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| item["kind"] == "user")
        .filter_map(|item| item["id"].as_str().map(str::to_owned))
        .collect()
}
