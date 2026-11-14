//! Read long conversations away from the UI thread. The receipt is accepted
//! only for the same selected view and unchanged local conversation metadata.
use crate::worker_owner::{ShutdownStatus, WorkerOwner};
use coincide_core::api::SharedEngine;
use serde_json::{Map, Value};
use std::sync::mpsc::{self, Receiver};

#[derive(Clone)]
struct Scope {
    id: String,
    generation: u64,
    metadata: Map<String, Value>,
    draft: Option<Value>,
}

fn metadata(thread: &Value) -> Option<Map<String, Value>> {
    let object = thread.as_object()?;
    Some(
        object
            .iter()
            .filter(|(key, _)| *key != "items" && *key != "draft")
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    )
}
impl Scope {
    fn capture(thread: &Value, generation: u64) -> Option<Self> {
        Some(Self {
            id: thread["id"].as_str()?.to_owned(),
            generation,
            metadata: metadata(thread)?,
            draft: thread.get("draft").cloned(),
        })
    }
    fn matches(&self, thread: &Value, generation: u64) -> bool {
        let Some(object) = thread.as_object() else {
            return false;
        };
        self.generation == generation
            && thread["id"].as_str() == Some(&self.id)
            && object
                .iter()
                .filter(|(key, _)| *key != "items" && *key != "draft")
                .count()
                == self.metadata.len()
            && self
                .metadata
                .iter()
                .all(|(key, value)| object.get(key) == Some(value))
    }
}

pub(super) struct Completed {
    scope: Scope,
    pub revision: u64,
    pub thread: Value,
    pub queue: Result<Value, String>,
    pub turn_changes: Option<(Value, Option<bool>)>,
}
impl Completed {
    /// Preserve a newer draft typed while the saved snapshot was decoding.
    pub fn apply_if_current(
        mut self,
        selected: &Value,
        generation: u64,
    ) -> Option<(
        u64,
        Value,
        Result<Value, String>,
        Option<(Value, Option<bool>)>,
    )> {
        if !self.scope.matches(selected, generation) {
            return None;
        }
        if selected.get("draft") != self.scope.draft.as_ref() {
            let target = self.thread.as_object_mut()?;
            match selected.get("draft") {
                Some(draft) => {
                    target.insert("draft".into(), draft.clone());
                }
                None => {
                    target.remove("draft");
                }
            }
        }
        Some((self.revision, self.thread, self.queue, self.turn_changes))
    }
}

#[derive(Default)]
pub(super) struct Reader {
    owner: WorkerOwner,
    receiver: Option<Receiver<Result<Completed, ()>>>,
}
impl Reader {
    pub fn start(&mut self, engine: &SharedEngine, selected: &Value, generation: u64) -> bool {
        if self.receiver.is_some() || !self.owner.can_start() {
            return false;
        }
        let Some(scope) = Scope::capture(selected, generation) else {
            return false;
        };
        let engine = engine.clone();
        let (sender, receiver) = mpsc::sync_channel(1);
        if !self.owner.spawn(move |admission| {
            if !admission.allowed() {
                return;
            }
            let result = (|| {
                let (revision, snapshot, queue_enabled) = {
                    let engine = engine.try_lock().map_err(|_| ())?;
                    if engine.shutdown || engine.admissions_frozen() {
                        return Err(());
                    }
                    engine.capture_thread_read(&scope.id).map_err(|_| ())?
                };
                let thread = snapshot.decode().map_err(|_| ())?;
                let queue = match queue_enabled {
                    Some(enabled) => coincide_core::message_queue::read(&thread)
                        .map(|messages| {
                            serde_json::json!({
                                "messages": messages,
                                "rawQueue": thread["rustMessageQueue"],
                                "error": thread["rustQueueError"],
                                "enabled": enabled,
                            })
                        })
                        .map_err(|error| error.to_string()),
                    None => {
                        Err("Transcript persistence is recovering; retry after recovery".into())
                    }
                };
                // Checkpoint listing can itself read the whole thread, so it
                // belongs on the worker too.
                let turn_changes = if admission.allowed() {
                    let mut engine = engine.lock().map_err(|_| ())?;
                    if engine.shutdown || engine.admissions_frozen() {
                        None
                    } else {
                        let imported = engine.store.is_imported(&scope.id).ok();
                        engine
                            .checkpoint_list_for_snapshot(&scope.id, &thread)
                            .ok()
                            .map(|value| (value, imported))
                    }
                } else {
                    None
                };
                Ok(Completed {
                    scope,
                    revision,
                    thread,
                    queue,
                    turn_changes,
                })
            })();
            if admission.allowed() {
                let _ = sender.try_send(result);
            }
        }) {
            return false;
        }
        self.receiver = Some(receiver);
        true
    }
    pub fn poll(&mut self) -> Option<Result<Completed, ()>> {
        self.owner.poll();
        if self.owner.closed() {
            self.receiver = None;
            return None;
        }
        let receiver = self.receiver.as_ref()?;
        match receiver.try_recv() {
            Ok(result) => {
                self.receiver = None;
                Some(result)
            }
            Err(mpsc::TryRecvError::Empty) => None,
            Err(mpsc::TryRecvError::Disconnected) => {
                self.receiver = None;
                Some(Err(()))
            }
        }
    }
    pub fn close(&mut self) {
        self.owner.close();
        self.receiver = None;
    }
    pub fn closed_and_drained(&mut self) -> bool {
        let status = self.owner.status();
        status.closed && status.unjoined == 0 && status.panicked == 0 && status.unclassified == 0
    }
    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        self.owner.status()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{
        sync::{Arc, Mutex},
        time::{Duration, Instant},
    };

    #[test]
    fn accepts_stream_updates_but_preserves_a_newer_draft() {
        let original = json!({"id":"a", "draft":"old", "selection":{"provider":"codex"}, "items":[{"id":"u"}]});
        let scope = Scope::capture(&original, 4).unwrap();
        let mut selected = original.clone();
        selected["draft"] = json!("new draft");
        let completed = Completed {
            scope,
            revision: 8,
            thread: json!({"id":"a", "draft":"old", "selection":{"provider":"codex"}, "items":[{"id":"u"},{"id":"reply"}]}),
            queue: Ok(json!({"messages":[]})),
            turn_changes: None,
        };
        let (revision, thread, _, _) = completed.apply_if_current(&selected, 4).unwrap();
        assert_eq!(revision, 8);
        assert_eq!(thread["draft"], "new draft");
        assert_eq!(thread["items"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn rejects_a_switched_thread_newer_view_or_changed_selection() {
        let original =
            json!({"id":"a", "draft":"old", "selection":{"provider":"codex"}, "items":[]});
        let scope = Scope::capture(&original, 4).unwrap();
        let complete = || Completed {
            scope: scope.clone(),
            revision: 8,
            thread: original.clone(),
            queue: Ok(json!({"messages":[]})),
            turn_changes: None,
        };
        assert!(complete().apply_if_current(&json!({"id":"b"}), 4).is_none());
        assert!(complete().apply_if_current(&original, 5).is_none());
        let mut changed = original.clone();
        changed["selection"]["provider"] = json!("claude");
        assert!(complete().apply_if_current(&changed, 4).is_none());
    }

    #[test]
    fn background_reads_keep_queued_messages_for_every_provider() {
        let dir = tempfile::tempdir().unwrap();
        let store = coincide_core::store::Store::open(&dir.path().join("scroll.sqlite")).unwrap();
        let engine = Arc::new(Mutex::new(coincide_core::api::Engine::new(store)));
        let mut selected = engine
            .lock()
            .unwrap()
            .dispatch(json!({"method":"threads.create","params":{}}))["result"]
            .clone();
        for provider in coincide_core::agent::Provider::supported_names() {
            selected["selection"]["provider"] = json!(provider);
            selected["rustMessageQueue"] = Value::Null;
            coincide_core::message_queue::add(&mut selected, "queued for this provider").unwrap();
            selected["rustMessageQueue"][0]["futureField"] = json!({"preserve":true});
            engine.lock().unwrap().store.save(&selected).unwrap();
            let mut reader = Reader::default();
            assert!(reader.start(&engine, &selected, 3));
            let deadline = Instant::now() + Duration::from_secs(5);
            let completed = loop {
                if let Some(result) = reader.poll() {
                    break result.unwrap();
                }
                assert!(
                    Instant::now() < deadline,
                    "background thread read timed out"
                );
                std::thread::yield_now();
            };
            let (_, thread, queue, changes) = completed.apply_if_current(&selected, 3).unwrap();
            assert_eq!(thread["selection"]["provider"], *provider);
            let queue = queue.unwrap();
            assert_eq!(queue["messages"][0]["text"], "queued for this provider");
            assert_eq!(queue["rawQueue"][0]["futureField"]["preserve"], true);
            assert!(changes.is_some());
            reader.close();
            while !reader.closed_and_drained() {
                assert!(Instant::now() < deadline, "background reader did not drain");
                std::thread::yield_now();
            }
        }
    }
}
