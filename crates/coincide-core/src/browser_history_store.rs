use super::*;
use crate::browser_history::{self, ImportResult, Library, Plan};
fn read(db: &Connection, name: &str) -> Result<Option<Value>> {
    let row:Option<(Option<Vec<u8>>,i64)>=db.query_row(
        "SELECT CASE WHEN length(CAST(document AS BLOB))<=?2 THEN CAST(document AS BLOB) ELSE NULL END,length(CAST(document AS BLOB)) FROM documents WHERE name=?1",
        params![name,browser_history::MAX_LIBRARY_BYTES as i64],|row|Ok((row.get(0)?,row.get(1)?))).optional()?;
    row.map(|(bytes, size)| {
        ensure!(
            size <= browser_history::MAX_LIBRARY_BYTES as i64,
            "Saved history exceeds its bound; contents retained"
        );
        serde_json::from_slice(&bytes.context("Saved history is unavailable")?).map_err(Into::into)
    })
    .transpose()
}
impl Store {
    pub fn saved_browser_history(&self, profile: Uuid) -> Result<Library> {
        Library::from_document(
            profile,
            read(self.connection()?, &browser_history::document_name(profile))?,
        )
    }
    /// Rust-owned profile library only. Immediate CAS preserves other writers,
    /// malformed documents and all original captured files on every failure.
    pub fn import_browser_history(
        &mut self,
        profile: Uuid,
        expected: u64,
        plan: &Plan,
    ) -> Result<ImportResult> {
        plan.validate()?;
        let name = browser_history::document_name(profile);
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let current = Library::from_document(profile, read(&tx, &name)?)?;
        let result = current.merge(expected, plan)?;
        if result.changed {
            tx.execute("INSERT INTO documents(name,document) VALUES (?1,?2) ON CONFLICT(name) DO UPDATE SET document=excluded.document",params![name,serde_json::to_string(&result.library)?])?;
        }
        tx.commit()?;
        Ok(result)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn plan() -> Plan {
        browser_history::preview(r#"{"history":[{"url":"https://example.test/","title":"Saved café","visitCount":3,"lastVisit":0,"future":{"keep":true}}],"futureExport":42}"#.as_bytes()).unwrap()
    }
    #[test]
    fn history_import_is_profile_scoped_restart_safe_and_source_preserving() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("state.sqlite");
        let profile = Uuid::new_v4();
        let mut store = Store::open(&db).unwrap();
        let source = dir.path().join("source.json");
        let bytes = serde_json::to_vec(&plan()).unwrap();
        std::fs::write(&source, &bytes).unwrap();
        let original = serde_json::json!({"history":[{"future":"captured"}]});
        store
            .save_document("browser-library.json", &original)
            .unwrap();
        let mut initial = Library::empty(profile);
        initial
            .extra
            .insert("futureSaved".into(), serde_json::json!({"opaque":[1,2]}));
        store
            .save_document(
                &browser_history::document_name(profile),
                &serde_json::to_value(&initial).unwrap(),
            )
            .unwrap();
        let saved = store
            .import_browser_history(profile, 0, &plan())
            .unwrap()
            .library;
        assert_eq!(saved.extra, initial.extra);
        let captured_profile = Uuid::new_v4();
        let captured_name = browser_history::document_name(captured_profile);
        let captured_bytes = b"not runtime history authorization";
        store
            .connection()
            .unwrap()
            .execute(
                "INSERT INTO original_files(path,data) VALUES (?1,?2)",
                params![captured_name, captured_bytes.as_slice()],
            )
            .unwrap();
        assert!(
            store
                .saved_browser_history(captured_profile)
                .unwrap()
                .history
                .is_empty()
        );
        store
            .import_browser_history(captured_profile, 0, &plan())
            .unwrap();
        assert_eq!(
            store.original(&captured_name).unwrap().unwrap(),
            captured_bytes
        );
        assert_eq!(
            store
                .saved_browser_history(Uuid::new_v4())
                .unwrap()
                .history
                .len(),
            0
        );
        drop(store);
        let store = Store::open(&db).unwrap();
        assert_eq!(store.saved_browser_history(profile).unwrap(), saved);
        assert_eq!(
            store.document("browser-library.json").unwrap(),
            Some(original)
        );
        assert_eq!(std::fs::read(source).unwrap(), bytes);
    }
    #[test]
    fn failed_sql_stale_revision_and_malformed_library_never_replace_saved_values() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("state.sqlite");
        let profile = Uuid::new_v4();
        let mut one = Store::open(&db).unwrap();
        let mut two = Store::open(&db).unwrap();
        let saved = one
            .import_browser_history(profile, 0, &plan())
            .unwrap()
            .library;
        assert!(two.import_browser_history(profile, 0, &plan()).is_err());
        assert_eq!(one.saved_browser_history(profile).unwrap(), saved);
        one.connection().unwrap().execute_batch("CREATE TRIGGER refuse_history BEFORE UPDATE ON documents BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;").unwrap();
        let mut next = plan();
        next.history[0]["url"] = serde_json::json!("https://other.example/");
        assert!(one.import_browser_history(profile, 1, &next).is_err());
        assert_eq!(one.saved_browser_history(profile).unwrap(), saved);
        one.connection()
            .unwrap()
            .execute_batch("DROP TRIGGER refuse_history;")
            .unwrap();
        let malformed = serde_json::json!({"version":99,"future":"keep"});
        one.save_document(&browser_history::document_name(profile), &malformed)
            .unwrap();
        assert!(one.import_browser_history(profile, 0, &plan()).is_err());
        assert_eq!(
            one.local_document(&browser_history::document_name(profile))
                .unwrap(),
            Some(malformed)
        );
        one.close_for_shutdown().unwrap();
        assert!(one.saved_browser_history(profile).is_err());
    }
}
