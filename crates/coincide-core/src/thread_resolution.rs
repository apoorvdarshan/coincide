//! Exact UUID resolution without a global summary list or transcript read.
use super::*;
impl Engine {
    pub(super) fn resolve_thread_id_command(&self, params: &Value) -> Result<Value> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Request {
            thread_id: String,
        }
        let request: Request = serde_json::from_value(params.clone())?;
        ensure!(request.thread_id.len() <= 64, "Invalid thread UUID");
        let id = Uuid::parse_str(&request.thread_id)
            .context("Thread reference must be an exact UUID")?;
        let stored = self
            .store
            .resolve_thread_id(id)?
            .context("Thread ID not found")?;
        Ok(json!({"threadId":stored}))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "aBcD1234-1234-4234-8234-aBcD12345678";
    fn fixture(stored: &str, body: &Value) -> (tempfile::TempDir, Engine) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        let engine = Engine::fixture(Store::open(&path).unwrap());
        rusqlite::Connection::open(&path)
            .unwrap()
            .execute(
                "INSERT INTO threads(id,document) VALUES(?1,?2)",
                rusqlite::params![stored, body.to_string()],
            )
            .unwrap();
        (dir, engine)
    }
    #[test]
    fn resolver_preserves_stored_forms_and_case_without_decoding_large_or_invalid_transcript() {
        let id = Uuid::parse_str(ID).unwrap();
        for stored in [
            ID.to_owned(),
            id.simple().to_string(),
            format!("{{{ID}}}"),
            format!("urn:uuid:{ID}"),
        ] {
            // Valid JSON but deliberately not a thread/transcript. Identity
            // resolution must not decode or transmit this >4MiB metadata.
            let body = json!({"unrelated":"x".repeat(4*1024*1024+1024)});
            let (_dir, mut engine) = fixture(&stored, &body);
            let revision = engine.revision;
            for requested in [
                id.to_string(),
                id.simple().to_string(),
                format!("{{{id}}}"),
                format!("urn:uuid:{id}"),
            ] {
                let resolved = engine
                    .execute("threads.resolve_id", &json!({"threadId":requested}))
                    .unwrap();
                assert_eq!(resolved, json!({"threadId":stored}));
                assert!(serde_json::to_vec(&resolved).unwrap().len() < 128);
                assert_eq!(engine.revision, revision);
            }
            assert_eq!(engine.store.thread(&stored).unwrap(), body);
        }
    }
    #[test]
    fn resolver_rejects_ambiguous_aliases_and_never_returns_arbitrary_first_match() {
        let (_dir, mut engine) = fixture(ID, &json!({}));
        let alternate = Uuid::parse_str(ID).unwrap().simple().to_string();
        let path = _dir.path().join("state.sqlite");
        rusqlite::Connection::open(path)
            .unwrap()
            .execute(
                "INSERT INTO threads(id,document) VALUES(?1,'{}')",
                [alternate],
            )
            .unwrap();
        assert!(
            engine
                .execute("threads.resolve_id", &json!({"threadId":ID}))
                .unwrap_err()
                .to_string()
                .contains("ambiguous")
        );
    }
    #[test]
    fn scalar_normalization_never_substitutes_a_malformed_stored_uuid() {
        let malformed = format!("----{ID}");
        let (_dir, mut engine) = fixture(&malformed, &json!({}));
        assert!(
            engine
                .execute("threads.resolve_id", &json!({"threadId":ID}))
                .is_err()
        );
    }
    #[test]
    fn resolver_accepts_only_exact_uuid_and_rejects_unknown_missing_and_prefix_parameters() {
        let (_dir, mut engine) = fixture(ID, &json!({}));
        let revision = engine.revision;
        for request in [
            json!({}),
            json!({"threadId":false}),
            json!({"threadId":"aBcD"}),
            json!({"threadId":"Exact title"}),
            json!({"threadId":ID,"title":"ignored"}),
            json!({"threadId":Uuid::new_v4()}),
        ] {
            assert!(
                engine.execute("threads.resolve_id", &request).is_err(),
                "accepted {request}"
            );
            assert_eq!(engine.revision, revision);
        }
        assert!(
            engine
                .execute("app.capabilities", &json!({}))
                .unwrap()
                .as_array()
                .unwrap()
                .contains(&json!("threads.resolve_id"))
        );
    }
}
