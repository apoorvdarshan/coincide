//! Last native window selection is display metadata, never runtime authority.
//! Preserve the Swift document's other fields and every conversation byte.
use super::*;
#[cfg(test)]
const DOCUMENT: &str = "ui-state.json";

impl Store {
    /// Return an existing stored identity, without opening its transcript or
    /// selecting it on an Engine. The native host applies visibility/fallback.
    pub fn native_last_selected_thread(&self) -> Result<Option<String>> {
        let Some(document) = self.native_inspector_document()? else {
            return Ok(None);
        };
        ensure!(document.is_object(), "Saved window state is not an object");
        let Some(id) = document["selectedThreadID"]
            .as_str()
            .and_then(|id| Uuid::parse_str(id).ok())
        else {
            return Ok(None);
        };
        self.resolve_thread_id(id)
    }
    /// Call after the native view actually loaded a conversation. This does not
    /// change its model/account, transcript, native session or update timestamp.
    /// False means no write occurred, including equivalent legacy UUID forms.
    pub fn remember_native_selected_thread(&mut self, id: Option<&str>) -> Result<bool> {
        self.connection()?;
        let selected = id
            .map(|id| -> Result<String> {
                self.resolve_thread_id(
                    Uuid::parse_str(id).context("Invalid selected conversation")?,
                )?
                .context("Selected conversation no longer exists")
            })
            .transpose()?;
        let source = self.native_inspector_document()?;
        let mut document = source.clone().unwrap_or_else(|| json!({}));
        ensure!(document.is_object(), "Saved window state is not an object");
        let unchanged = match &selected {
            Some(selected) => {
                document["selectedThreadID"]
                    .as_str()
                    .and_then(|id| Uuid::parse_str(id).ok())
                    == Uuid::parse_str(selected).ok()
            }
            None => document["selectedThreadID"].is_null(),
        };
        if unchanged {
            return Ok(false);
        }
        crate::inspector_preferences::migrate_legacy(&mut document);
        document["selectedThreadID"] = selected.clone().map(Value::String).unwrap_or(Value::Null);
        self.save_native_ui_document_if_unchanged(source.as_ref(), &document, selected.as_deref())?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const A: &str = "12345678-1234-4234-8234-1234567890ab";
    const B: &str = "abcdefab-1234-4234-8234-abcdefabcdef";
    fn fixture() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("private-data");
        crate::native_file::private_directory(&data).unwrap();
        let mut store = Store::open(&data.join("state.sqlite")).unwrap();
        for (id, updated) in [(A, 1), (B, 2)] {
            store.save(&json!({"id":id,"title":id,"createdAt":0,"updatedAt":updated,"draft":"Keep exact draft","items":[{"kind":"user","text":"Keep exact history"}],"selection":{"provider":"codex","accountID":"default","modelID":"default"},"sessions":{"codex":{"sessionID":"untrusted display metadata only","seenItemCount":1}},"future":{"keep":[1,2]}})).unwrap();
        }
        (dir, store)
    }
    fn raw_threads(store: &Store) -> Vec<(String, String)> {
        store
            .connection()
            .unwrap()
            .prepare("SELECT id,document FROM threads ORDER BY id")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    }
    #[test]
    fn older_last_selected_conversation_survives_restart_without_changing_any_thread_bytes() {
        let (_dir, mut store) = fixture();
        let path = std::path::PathBuf::from(store.connection().unwrap().path().unwrap());
        assert_eq!(
            store.summaries("", false).unwrap()[0].id,
            B,
            "Newer B exists while the user chooses older A"
        );
        let original = raw_threads(&store);
        let metadata = json!({"windowFrame":"synthetic frame","future":{"opaque":[3,4]},"previewTabs":{"keep":"unchanged"}});
        store.save_document(DOCUMENT, &metadata).unwrap();
        assert!(store.remember_native_selected_thread(Some(A)).unwrap());
        let mut expected = metadata.clone();
        expected["selectedThreadID"] = json!(A);
        assert_eq!(store.document(DOCUMENT).unwrap().unwrap(), expected);
        assert_eq!(raw_threads(&store), original);
        let serial = store.mutation_serial().unwrap();
        assert!(!store.remember_native_selected_thread(Some(A)).unwrap());
        assert_eq!(store.mutation_serial().unwrap(), serial);
        store.close_for_shutdown().unwrap();
        let reopened = Store::open(&path).unwrap();
        assert_eq!(
            reopened.native_last_selected_thread().unwrap().as_deref(),
            Some(A)
        );
        assert_eq!(raw_threads(&reopened), original);
        assert_eq!(reopened.document(DOCUMENT).unwrap().unwrap(), expected);
    }
    #[test]
    fn uuid_aliases_and_absent_selection_do_not_rewrite_window_state() {
        let (_dir, mut store) = fixture();
        let serial = store.mutation_serial().unwrap();
        assert!(!store.remember_native_selected_thread(None).unwrap());
        assert_eq!(store.mutation_serial().unwrap(), serial);
        assert!(store.document(DOCUMENT).unwrap().is_none());
        let alias = format!("urn:uuid:{}", A.to_uppercase());
        let metadata = json!({"selectedThreadID":alias,"future":7});
        store.save_document(DOCUMENT, &metadata).unwrap();
        let serial = store.mutation_serial().unwrap();
        assert_eq!(
            store.native_last_selected_thread().unwrap().as_deref(),
            Some(A)
        );
        assert!(!store.remember_native_selected_thread(Some(A)).unwrap());
        assert_eq!(store.mutation_serial().unwrap(), serial);
        assert_eq!(store.document(DOCUMENT).unwrap().unwrap(), metadata);
        assert!(store.remember_native_selected_thread(None).unwrap());
        assert_eq!(store.native_last_selected_thread().unwrap(), None);
        assert_eq!(store.document(DOCUMENT).unwrap().unwrap()["future"], 7);
    }
    #[test]
    fn deleted_or_invalid_hints_fall_back_while_bad_documents_and_closed_databases_stay_errors() {
        let (_dir, mut store) = fixture();
        for id in ["not a UUID", "87654321-1234-4234-8234-1234567890ab"] {
            let metadata = json!({"selectedThreadID":id,"future":8});
            store.save_document(DOCUMENT, &metadata).unwrap();
            let serial = store.mutation_serial().unwrap();
            assert_eq!(store.native_last_selected_thread().unwrap(), None);
            assert_eq!(store.mutation_serial().unwrap(), serial);
            assert_eq!(store.document(DOCUMENT).unwrap().unwrap(), metadata);
        }
        store.remember_native_selected_thread(Some(A)).unwrap();
        store
            .connection()
            .unwrap()
            .execute("DELETE FROM threads WHERE id=?1", [A])
            .unwrap();
        assert_eq!(store.native_last_selected_thread().unwrap(), None);
        let before = store.document(DOCUMENT).unwrap();
        assert!(store.remember_native_selected_thread(Some(A)).is_err());
        assert_eq!(store.document(DOCUMENT).unwrap(), before);
        store.save_document(DOCUMENT, &json!([])).unwrap();
        assert!(store.native_last_selected_thread().is_err());
        assert!(store.remember_native_selected_thread(Some(B)).is_err());
        assert_eq!(store.document(DOCUMENT).unwrap(), Some(json!([])));
        store.close_for_shutdown().unwrap();
        assert!(store.native_last_selected_thread().is_err());
        assert!(store.remember_native_selected_thread(None).is_err());
    }
}
