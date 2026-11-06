//! Native-only capture admission and atomic image/text delivery. These methods
//! are deliberately absent from the JSON dispatcher and agent capabilities.
use super::*;
use crate::{attachments::StoredImage, composer_context};

pub struct AppshotTicket {
    target: Option<String>,
    expected_settings: Option<Value>,
    expected_images: Option<Value>,
    expected_context: Option<Value>,
}
pub struct PreparedAppshot {
    pub image: StoredImage,
    pub app: String,
    pub title: Option<String>,
    pub text: Option<String>,
}
impl PreparedAppshot {
    /// Bounded decoder and private UUID attachment directory shared with normal
    /// image imports. Native backends return bytes, never an arbitrary path.
    pub fn prepare(
        root: &std::path::Path,
        png: &[u8],
        app: String,
        title: Option<String>,
        text: Option<String>,
    ) -> Result<Self> {
        ensure!(
            app.len() <= 512 && title.as_ref().is_none_or(|s| s.len() <= 4096),
            "Window metadata exceeds limits"
        );
        ensure!(
            text.as_ref()
                .is_none_or(|s| s.len() <= 32000 && !s.contains('\0')),
            "Window text exceeds limits"
        );
        let image =
            crate::attachments::ingest_image_bytes(root, png, &format!("Appshot of {app}.png"))?;
        Ok(Self {
            image,
            app,
            title,
            text,
        })
    }
}
impl Engine {
    fn appshot_writable(&self, id: &str) -> Result<Value> {
        ensure!(
            !self.unsaved_threads.contains_key(id),
            "Transcript persistence is recovering"
        );
        ensure!(
            !self.store.is_imported(id)?,
            "Imported history cannot receive Appshots"
        );
        let thread = self.store.thread(id)?;
        ensure!(
            thread["isArchived"] != true,
            "Archived chats cannot receive Appshots"
        );
        ensure!(
            thread["rustDraftImages"].is_null() || thread["rustDraftImages"].is_array(),
            "Draft images are malformed"
        );
        ensure!(
            thread["rustDraftImages"].as_array().map_or(0, Vec::len) < 20,
            "A draft can contain at most 20 images"
        );
        Ok(thread)
    }
    pub fn native_appshot_admit(&mut self, recent: Option<&str>) -> Result<AppshotTicket> {
        self.require_background_admission()?;
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        ensure!(
            crate::appshots::Settings::read(&settings).enabled,
            "Appshots are off"
        );
        // Unavailable recent chats fall back to an ordinary projectless chat.
        let target = recent.and_then(|id| {
            self.appshot_writable(id)
                .ok()
                .map(|thread| (id.to_owned(), thread))
        });
        Ok(AppshotTicket {
            expected_settings: settings.get("appshots").cloned(),
            expected_images: target
                .as_ref()
                .and_then(|(_, t)| t.get("rustDraftImages").cloned()),
            expected_context: target
                .as_ref()
                .and_then(|(_, t)| t.get("draftContext").cloned()),
            target: target.map(|(id, _)| id),
        })
    }
    pub fn native_appshot_deliver(
        &mut self,
        ticket: AppshotTicket,
        prepared: PreparedAppshot,
    ) -> Result<Value> {
        self.require_background_admission()?;
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        ensure!(
            settings.get("appshots") == ticket.expected_settings.as_ref()
                && crate::appshots::Settings::read(&settings).enabled,
            "Appshots settings changed; stale capture discarded"
        );
        prepared.image.prepare_in(&self.store.data_directory()?)?;
        let mut thread = if let Some(id) = ticket.target.as_ref() {
            let thread = self.appshot_writable(id)?;
            ensure!(
                thread.get("rustDraftImages") == ticket.expected_images.as_ref()
                    && thread.get("draftContext") == ticket.expected_context.as_ref(),
                "Draft attachments changed; stale capture was not attached"
            );
            thread
        } else {
            // This uses the same global defaults/provider validation as New Chat.
            self.create_ordinary_thread(&json!({}))?
        };
        let mut images = thread["rustDraftImages"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let total = images
            .iter()
            .try_fold(0u64, |sum, image| {
                sum.checked_add(image["byteLen"].as_u64().unwrap_or(u64::MAX))
            })
            .context("Invalid image byte total")?;
        ensure!(
            total.saturating_add(prepared.image.byte_len) <= 20 * 1024 * 1024,
            "Draft images exceed 20 MiB"
        );
        images.push(serde_json::to_value(prepared.image)?);
        if let Some(text) = prepared.text.filter(|s| !s.trim().is_empty()) {
            let raw = thread.get("draftContext").unwrap_or(&Value::Null);
            composer_context::validate(raw)?;
            let mut rows = raw.as_array().cloned().unwrap_or_default();
            rows.push(json!({"id":Uuid::new_v4(),"kind":"window-text","app":prepared.app,"title":prepared.title,"text":text}));
            let raw = Value::Array(rows);
            composer_context::validate(&raw)?;
            thread["draftContext"] = raw;
        }
        thread["rustDraftImages"] = Value::Array(images);
        // Save once: existing draft text/history/selection/unknown fields survive.
        // No send/launch/provider call occurs anywhere on this path.
        self.store.save(&thread)?;
        self.revision += 1;
        Ok(thread)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, String) {
        let directory = tempfile::tempdir().unwrap();
        let mut store = Store::open(&directory.path().join("data/state.sqlite")).unwrap();
        let thread = store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        let id = thread["id"].as_str().unwrap().to_owned();
        let mut engine = Engine::fixture(store);
        engine
            .execute(
                "settings.patch",
                &json!({"patch":{"appshots":{"enabled":true},"future":{"keep":7}}}),
            )
            .unwrap();
        (directory, engine, id)
    }
    fn prepared(engine: &Engine, text: Option<&str>) -> PreparedAppshot {
        let png = crate::appshots::encode_rgba(2, 2, vec![0; 16]).unwrap();
        PreparedAppshot::prepare(
            &engine.store.data_directory().unwrap(),
            &png,
            "Fixture App".into(),
            Some("Private fixture".into()),
            text.map(str::to_owned),
        )
        .unwrap()
    }
    #[test]
    fn atomic_image_text_delivery_preserves_draft_history_unknowns_and_never_sends() {
        let (_directory, mut engine, id) = fixture();
        let mut thread = engine.store.thread(&id).unwrap();
        thread["draft"] = json!("unsent original");
        thread["future"] = json!({"keep":1});
        thread["draftContext"] =
            json!([{"id":Uuid::new_v4(),"kind":"file","path":"/fixture/reference","future":8}]);
        engine.store.save(&thread).unwrap();
        let ticket = engine.native_appshot_admit(Some(&id)).unwrap();
        // An unrelated edit while capture runs survives; the CAS binds only
        // fields Appshots appends, never the entire draft/transcript document.
        let mut latest = engine.store.thread(&id).unwrap();
        latest["draft"] = json!("new unsent text");
        latest["future"]["keep"] = json!(2);
        engine.store.save(&latest).unwrap();
        let capture = prepared(&engine, Some("Fixture window text"));
        let delivered = engine.native_appshot_deliver(ticket, capture).unwrap();
        assert_eq!(delivered["draft"], "new unsent text");
        assert_eq!(delivered["future"]["keep"], 2);
        assert_eq!(delivered["items"], thread["items"]);
        assert_eq!(delivered["sessions"], thread["sessions"]);
        assert_eq!(delivered["draftContext"][0], thread["draftContext"][0]);
        assert_eq!(delivered["draftContext"][1]["kind"], "window-text");
        assert_eq!(delivered["rustDraftImages"].as_array().unwrap().len(), 1);
        assert!(engine.runs.is_empty());
    }
    #[test]
    fn changed_context_or_image_set_rejects_entire_capture() {
        for field in ["draftContext", "rustDraftImages"] {
            let (_directory, mut engine, id) = fixture();
            let ticket = engine.native_appshot_admit(Some(&id)).unwrap();
            let mut thread = engine.store.thread(&id).unwrap();
            thread[field] = json!([]);
            engine.store.save(&thread).unwrap();
            let capture = prepared(&engine, Some("fixture"));
            assert!(engine.native_appshot_deliver(ticket, capture).is_err());
            assert_eq!(engine.store.thread(&id).unwrap(), thread);
        }
    }
    #[test]
    fn setting_revocation_archive_and_quit_freeze_reject_late_delivery() {
        for change in ["off", "archive", "freeze"] {
            let (_directory, mut engine, id) = fixture();
            let ticket = engine.native_appshot_admit(Some(&id)).unwrap();
            let capture = prepared(&engine, None);
            match change {
                "off" => {
                    engine
                        .execute(
                            "settings.patch",
                            &json!({"patch":{"appshots":{"enabled":false}}}),
                        )
                        .unwrap();
                }
                "archive" => {
                    engine
                        .store
                        .patch_thread(&id, &json!({"isArchived":true}))
                        .unwrap();
                }
                _ => engine.freeze_admissions(),
            }
            let before = engine.store.thread(&id).unwrap();
            assert!(engine.native_appshot_deliver(ticket, capture).is_err());
            assert_eq!(engine.store.thread(&id).unwrap(), before);
        }
    }
    #[test]
    fn expired_or_unavailable_target_creates_projectless_chat_with_global_defaults() {
        let (_directory, mut engine, id) = fixture();
        engine.execute("settings.patch",&json!({"patch":{"defaultSelection":{"provider":"claude","modelID":"fixture-default"},"defaultAccessMode":"fullAccess"}})).unwrap();
        let ticket = engine.native_appshot_admit(None).unwrap();
        let capture = prepared(&engine, None);
        let saved = engine.native_appshot_deliver(ticket, capture).unwrap();
        assert_ne!(saved["id"], id);
        assert_eq!(saved["projectID"], "00000000-0000-0000-0000-000000000000");
        assert_eq!(saved["selection"]["modelID"], "fixture-default");
        assert_eq!(saved["items"], json!([]));
        assert_eq!(saved["draft"], "");
    }
    #[test]
    fn malformed_context_is_retained_and_no_image_partially_attached() {
        let (_directory, mut engine, id) = fixture();
        let mut thread = engine.store.thread(&id).unwrap();
        thread["draftContext"] =
            json!([{"id":Uuid::new_v4(),"kind":"future","payload":{"keep":1}}]);
        engine.store.save(&thread).unwrap();
        let ticket = engine.native_appshot_admit(Some(&id)).unwrap();
        let capture = prepared(&engine, Some("fixture"));
        assert!(engine.native_appshot_deliver(ticket, capture).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), thread);
    }
    #[test]
    fn no_control_api_can_capture_or_enable_the_native_owner() {
        let (_directory, mut engine, _) = fixture();
        for method in [
            "appshots.capture",
            "appshots.deliver",
            "appshots.trigger",
            "appshots.hook.install",
        ] {
            assert!(
                engine
                    .dispatch(json!({"method":method,"params":{}}))
                    .get("error")
                    .is_some()
            );
        }
    }
}
