//! A visible queued message can be moved back to its native composer once.
//! This is an edit, never a provider send or a JSON runtime-authority route.
use super::*;
use crate::message_queue::{self, State};

impl Engine {
    pub fn edit_native_queued_message(
        &mut self,
        expected: &Value,
        visible_message: &Value,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let id = required(expected, "id")?;
        ensure!(
            self.active_thread.as_deref() == Some(id),
            "Conversation is no longer active"
        );
        ensure!(
            !self.unsaved_threads.contains_key(id),
            "Transcript persistence is recovering"
        );
        ensure!(
            !self.native_follow_up.pending_thread(id),
            "Collect the pending follow-up before editing the queue"
        );
        ensure!(
            !self.store.is_imported(id)?,
            "Imported conversations are read-only"
        );
        ensure!(
            expected["isArchived"] != true,
            "Restore this conversation before editing its queue"
        );
        ensure!(
            serde_json::to_vec(expected)?.len() <= 8 * 1024 * 1024,
            "Conversation exceeds the safe edit limit"
        );
        let message_id = required(visible_message, "id")?;
        let messages = message_queue::read(expected)?;
        let (index, message) = messages
            .iter()
            .enumerate()
            .find(|(_, message)| message.id == message_id)
            .context("Queued message is no longer available")?;
        ensure!(
            matches!(
                message.state,
                State::Pending | State::Failed | State::Interrupted
            ),
            "A dispatched or completed message cannot be taken back into the composer"
        );
        ensure!(
            serde_json::to_value(message)? == *visible_message,
            "Queued message changed; refresh before editing"
        );
        ensure!(
            message.text.len() <= 256 * 1024
                && (!message.text.trim().is_empty()
                    || !message.images.is_empty()
                    || crate::composer_context::has_context(&message.context)),
            "Queued message text is invalid"
        );
        let draft = expected
            .get("draft")
            .filter(|value| !value.is_null())
            .map(|value| value.as_str().context("Saved draft is malformed"))
            .transpose()?
            .unwrap_or_default();
        let merged = if draft.chars().any(|ch| !ch.is_whitespace()) {
            format!("{draft}\n\n{}", message.text)
        } else {
            message.text.clone()
        };
        ensure!(
            merged.len() <= 1024 * 1024,
            "Combined draft exceeds 1 MiB; current draft and queue retained"
        );
        let mut next = expected.clone();
        // Keep every neighboring queue record's unknown metadata byte-for-byte
        // in its JSON value. Do not round-trip the list through the typed DTO.
        next["rustMessageQueue"]
            .as_array_mut()
            .context("Saved queue is malformed")?
            .remove(index);
        next["draft"] = json!(merged);
        if crate::composer_context::has_context(&message.context) {
            crate::composer_context::validate(&expected["draftContext"])?;
            crate::composer_context::validate(&message.context)?;
            let mut context = expected["draftContext"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            for card in message.context.as_array().unwrap() {
                if let Some(existing) = context.iter().find(|item| item["id"] == card["id"]) {
                    ensure!(
                        existing == card,
                        "A context card identity changed; queue retained"
                    );
                } else {
                    context.push(card.clone());
                }
            }
            let context = Value::Array(context);
            crate::composer_context::validate(&context)?;
            next["draftContext"] = context;
        }
        if !message.images.is_empty() {
            let mut images: Vec<crate::attachments::StoredImage> =
                if expected["rustDraftImages"].is_null() {
                    Vec::new()
                } else {
                    serde_json::from_value(expected["rustDraftImages"].clone())
                        .context("Invalid current draft images")?
                };
            for image in &message.images {
                if let Some(existing) = images.iter().find(|existing| existing.id == image.id) {
                    ensure!(
                        serde_json::to_value(existing)? == serde_json::to_value(image)?,
                        "An image identity changed; queue retained"
                    );
                } else {
                    images.push(image.clone());
                }
            }
            ensure!(
                images.len() <= 20
                    && images
                        .iter()
                        .try_fold(0u64, |sum, image| sum.checked_add(image.byte_len))
                        .is_some_and(|n| n <= 20 * 1024 * 1024),
                "Combined images exceed safe limits"
            );
            next["rustDraftImages"] = serde_json::to_value(images)?;
        }

        next["updatedAt"] = json!(swift_timestamp());
        // This existing Store seam checks the full effective source and import/
        // tombstone guards in the same IMMEDIATE transaction as the write.
        self.store.save_native_follow_up_turn(expected, &next)?;
        self.revision += 1;
        Ok(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, Value, Value) {
        let directory = tempfile::tempdir().unwrap();
        let mut engine =
            Engine::fixture(Store::open(&directory.path().join("state.sqlite")).unwrap());
        let mut thread = engine
            .execute("threads.create", &json!({"cwd":directory.path()}))
            .unwrap();
        let message = message_queue::add(&mut thread, "queued é 👩‍💻\nsecond line").unwrap();
        message_queue::add(&mut thread, "neighbor").unwrap();
        thread["rustMessageQueue"][1]["future"] = json!({"preserve":[1,2,3]});
        thread["draft"] = json!("existing draft\n");
        thread["draftContext"] = json!([{"future":"untouched"}]);
        thread["rustDraftImages"] = json!([{"future":"image unchanged"}]);
        thread["future"] = json!({"keep":true});
        engine.store.save(&thread).unwrap();
        engine.set_active_thread(Some(text(&thread, "id"))).unwrap();
        (
            directory,
            engine,
            thread,
            serde_json::to_value(message).unwrap(),
        )
    }
    #[test]
    fn queue_edit_atomically_appends_without_changing_context_session_or_neighbors() {
        let (_directory, mut engine, source, message) = fixture();
        let result = engine
            .edit_native_queued_message(&source, &message)
            .unwrap();
        assert_eq!(
            result["draft"],
            "existing draft\n\n\nqueued é 👩‍💻\nsecond line"
        );
        assert_eq!(
            result["rustMessageQueue"],
            json!([source["rustMessageQueue"][1]])
        );
        let mut expected = source.clone();
        expected["draft"] = result["draft"].clone();
        expected["updatedAt"] = result["updatedAt"].clone();
        expected["rustMessageQueue"] = result["rustMessageQueue"].clone();
        assert_eq!(result, expected);
        assert_eq!(engine.store.thread(&text(&source, "id")).unwrap(), result);
        assert!(engine.runs.is_empty());
        assert!(
            engine
                .edit_native_queued_message(&source, &message)
                .is_err()
        );
        assert_eq!(engine.store.thread(&text(&source, "id")).unwrap(), result);
        engine.store.close_for_shutdown().unwrap();
    }
    #[test]
    fn queue_edit_refuses_external_source_and_visible_message_changes_atomically() {
        let (directory, mut engine, source, message) = fixture();
        let mut changed = message.clone();
        changed["text"] = json!("stale display");
        assert!(
            engine
                .edit_native_queued_message(&source, &changed)
                .is_err()
        );
        let id = text(&source, "id");
        let mut other = Store::open(&directory.path().join("state.sqlite")).unwrap();
        let mut newer = source.clone();
        newer["draft"] = json!("external newer draft");
        other.save(&newer).unwrap();
        assert!(
            engine
                .edit_native_queued_message(&source, &message)
                .is_err()
        );
        assert_eq!(engine.store.thread(&id).unwrap(), newer);
        engine.store.close_for_shutdown().unwrap();
    }
    #[test]
    fn queue_edit_refuses_dispatched_completed_archived_frozen_and_other_thread() {
        for state in ["dispatching", "completed"] {
            let (_directory, mut engine, mut source, mut message) = fixture();
            source["rustMessageQueue"][0]["state"] = json!(state);
            message["state"] = json!(state);
            engine.store.save(&source).unwrap();
            assert!(
                engine
                    .edit_native_queued_message(&source, &message)
                    .is_err()
            );
            assert_eq!(engine.store.thread(&text(&source, "id")).unwrap(), source);
            engine.store.close_for_shutdown().unwrap();
        }
        for mode in ["archived", "frozen", "other"] {
            let (_directory, mut engine, mut source, message) = fixture();
            match mode {
                "archived" => {
                    source["isArchived"] = json!(true);
                    engine.store.save(&source).unwrap();
                }
                "frozen" => engine.freeze_admissions(),
                _ => {
                    engine.set_active_thread(None).unwrap();
                }
            }
            assert!(
                engine
                    .edit_native_queued_message(&source, &message)
                    .is_err()
            );
            assert_eq!(engine.store.thread(&text(&source, "id")).unwrap(), source);
            engine.store.close_for_shutdown().unwrap();
        }
    }
    #[test]
    fn queue_edit_keeps_oversized_draft_and_replaces_only_whitespace() {
        let (_directory, mut engine, mut source, message) = fixture();
        source["draft"] = json!("x".repeat(1024 * 1024));
        engine.store.save(&source).unwrap();
        assert!(
            engine
                .edit_native_queued_message(&source, &message)
                .is_err()
        );
        assert_eq!(engine.store.thread(&text(&source, "id")).unwrap(), source);
        source["draft"] = json!(" \n\t");
        engine.store.save(&source).unwrap();
        let result = engine
            .edit_native_queued_message(&source, &message)
            .unwrap();
        assert_eq!(result["draft"], message["text"]);
        engine.store.close_for_shutdown().unwrap();
    }
    #[test]
    fn queue_edit_restores_exact_payload_alongside_existing_composer() {
        let (directory, mut engine, mut source, _) = fixture();
        let path = directory.path().join("synthetic-queued-image.png");
        image::RgbImage::from_pixel(2, 2, image::Rgb([5, 6, 7]))
            .save(&path)
            .unwrap();
        let image =
            crate::attachments::ingest_image(&engine.store.data_directory().unwrap(), &path)
                .unwrap();
        source["draftContext"] =
            json!([{"id":Uuid::new_v4(),"kind":"quote","text":"Existing draft reference"}]);
        source["rustDraftImages"] = json!([]);
        let context = json!([{"id":Uuid::new_v4(),"kind":"file","path":"/synthetic/never-open-this-reference","future":{"keep":9}}]);
        source["rustMessageQueue"][0]["context"] = context.clone();
        source["rustMessageQueue"][0]["rustImages"] = json!([image]);
        engine.store.save(&source).unwrap();
        let visible = serde_json::to_value(&message_queue::read(&source).unwrap()[0]).unwrap();
        let next = engine
            .edit_native_queued_message(&source, &visible)
            .unwrap();
        assert_eq!(next["draftContext"][0], source["draftContext"][0]);
        assert_eq!(next["draftContext"][1], context[0]);
        assert_eq!(
            next["rustDraftImages"],
            source["rustMessageQueue"][0]["rustImages"]
        );
        assert_eq!(
            next["rustMessageQueue"],
            json!([source["rustMessageQueue"][1]])
        );
        assert_eq!(next["future"], source["future"]);
    }
}
