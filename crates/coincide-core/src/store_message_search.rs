//! The sidebar's message search, as Swift's `AppStore.searchMessages`: threads
//! whose user or agent messages contain the typed text, each with the line
//! around its first match for the row's tooltip.
use super::*;
use std::collections::HashMap;

/// A read-only search source tied to the database observed by the engine.
/// The actual SQLite connection is opened on the search worker.
pub struct MessageSearchSource {
    path: std::path::PathBuf,
    identity: crate::private_fs::Identity,
}

impl MessageSearchSource {
    pub fn search(
        &self,
        needle: &str,
        include_archived: bool,
        cancelled: impl Fn() -> bool,
    ) -> Result<Option<HashMap<String, String>>> {
        if cancelled() {
            return Ok(None);
        }
        ensure!(
            crate::private_fs::identity(&self.path)? == self.identity,
            "Message search store changed"
        );
        let connection = Connection::open_with_flags(
            &self.path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        connection.busy_timeout(std::time::Duration::from_millis(250))?;
        ensure!(
            connection.is_readonly("main")?,
            "Message search must be read only"
        );
        ensure!(
            crate::private_fs::identity(&self.path)? == self.identity,
            "Message search store changed"
        );
        // Keep all candidate and transcript reads on one SQLite snapshot.
        connection.execute_batch("BEGIN")?;
        let store = Store {
            db: Some(connection),
            selection_scopes: Default::default(),
            deferred_search_active: Default::default(),
        };
        let result = store.message_matches_cancellable(needle, include_archived, &cancelled)?;
        ensure!(
            crate::private_fs::identity(&self.path)? == self.identity,
            "Message search store changed"
        );
        Ok(result)
    }
}

#[derive(Deserialize)]
struct Transcript {
    #[serde(default)]
    items: Vec<TranscriptItem>,
}
#[derive(Deserialize)]
struct TranscriptItem {
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    text: Option<String>,
}

/// Case- and accent-folded characters with their position in the source;
/// combining marks are left out so an accent never splits a match.
fn folded(text: &str) -> Vec<(usize, char)> {
    text.chars()
        .enumerate()
        .filter_map(|(index, character)| {
            crate::palette_search::fold_char(character).map(|folded| (index, folded))
        })
        .collect()
}

/// The line around the first match of `needle` in `text`, at most 40 characters
/// before and 80 after it, with an ellipsis where it was shortened.
pub(crate) fn snippet(needle: &str, text: &str) -> Option<String> {
    let needle: Vec<char> = folded(needle.trim()).into_iter().map(|(_, c)| c).collect();
    if needle.is_empty() {
        return None;
    }
    let haystack = folded(text);
    let position = haystack
        .windows(needle.len())
        .position(|window| window.iter().map(|(_, c)| *c).eq(needle.iter().copied()))?;
    let characters: Vec<char> = text.chars().collect();
    let lower = haystack[position].0;
    let upper = haystack[position + needle.len() - 1].0 + 1;
    let line_start = characters[..lower]
        .iter()
        .rposition(|c| *c == '\n' || *c == '\r')
        .map_or(0, |index| index + 1);
    let line_end = characters[upper..]
        .iter()
        .position(|c| *c == '\n' || *c == '\r')
        .map_or(characters.len(), |index| upper + index);
    let start = lower.saturating_sub(40).max(line_start);
    let end = (upper + 80).min(line_end);
    let body: String = characters[start..end].iter().collect();
    Some(format!(
        "{}{}{}",
        if start > line_start { "…" } else { "" },
        body.trim_matches(|c| c == ' ' || c == '\t'),
        if end < line_end { "…" } else { "" }
    ))
}

impl Store {
    pub fn message_search_source(&self) -> Result<MessageSearchSource> {
        let path = self.usage_database_path()?;
        let metadata = std::fs::symlink_metadata(&path)?;
        ensure!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "Message search requires a regular database"
        );
        Ok(MessageSearchSource {
            identity: crate::private_fs::identity(&path)?,
            path,
        })
    }
    /// Threads whose user or agent messages contain `needle`, keyed by ID, with
    /// the matching line. Fewer than two typed characters find nothing.
    ///
    /// The lowercased transcript index narrows the candidates first. It folds
    /// case but not accents, so unlike Swift an unaccented needle does not find
    /// accented text.
    pub fn message_matches(
        &self,
        needle: &str,
        include_archived: bool,
    ) -> Result<HashMap<String, String>> {
        Ok(self
            .message_matches_cancellable(needle, include_archived, &|| false)?
            .unwrap_or_default())
    }

    fn message_matches_cancellable(
        &self,
        needle: &str,
        include_archived: bool,
        cancelled: &impl Fn() -> bool,
    ) -> Result<Option<HashMap<String, String>>> {
        if cancelled() {
            return Ok(None);
        }
        let needle = needle.trim();
        if needle.chars().count() < 2 {
            return Ok(Some(HashMap::new()));
        }
        let mut found = HashMap::new();
        for summary in self.summaries(needle, include_archived)? {
            if cancelled() {
                return Ok(None);
            }
            let document: Option<String> = self
                .connection()?
                .query_row(
                    "SELECT document FROM threads WHERE id=?1",
                    [&summary.id],
                    |row| row.get(0),
                )
                .optional()?;
            let Some(transcript) = document
                .as_deref()
                .and_then(|raw| serde_json::from_str::<Transcript>(raw).ok())
            else {
                continue;
            };
            if let Some(line) = transcript
                .items
                .iter()
                .filter(|item| matches!(item.kind.as_deref(), Some("user" | "assistant")))
                .find_map(|item| snippet(needle, item.text.as_deref()?))
            {
                found.insert(summary.id, line);
            }
        }
        Ok((!cancelled()).then_some(found))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn independent_read_only_search_matches_the_store_and_honors_cancellation() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("state.sqlite");
        let mut store = Store::open(&path).unwrap();
        let id = "11111111-1111-4111-8111-111111111111";
        store.save(&json!({"id":id,"title":"Synthetic","projectID":"","items":[{"kind":"user","text":"A searchable synthetic message"}],"updatedAt":1.0})).unwrap();
        let source = store.message_search_source().unwrap();
        assert_eq!(
            source
                .search("searchable", false, || false)
                .unwrap()
                .unwrap(),
            store.message_matches("searchable", false).unwrap()
        );
        assert!(
            source
                .search("searchable", false, || true)
                .unwrap()
                .is_none()
        );
        assert!(
            source
                .search("x", false, || false)
                .unwrap()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn search_source_rejects_a_replaced_database() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("state.sqlite");
        let store = Store::open(&path).unwrap();
        let source = store.message_search_source().unwrap();
        drop(store);
        std::fs::rename(&path, root.path().join("original.sqlite")).unwrap();
        std::fs::write(&path, b"replacement").unwrap();
        assert!(source.search("anything", false, || false).is_err());
    }

    #[test]
    fn long_read_only_search_does_not_block_a_store_write() {
        use std::sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
            mpsc,
        };
        let root = tempfile::tempdir().unwrap();
        let mut store = Store::open(&root.path().join("state.sqlite")).unwrap();
        store.save(&json!({"id":"11111111-1111-4111-8111-111111111111","title":"Synthetic","projectID":"","items":[{"kind":"user","text":"searchable"}],"updatedAt":1.0})).unwrap();
        let source = store.message_search_source().unwrap();
        let (entered, read_started) = mpsc::channel();
        let (release, wait_for_release) = mpsc::channel();
        let gate = Arc::new(Mutex::new(wait_for_release));
        let calls = AtomicUsize::new(0);
        let reader = std::thread::spawn(move || {
            source.search("searchable", false, || {
                if calls.fetch_add(1, Ordering::SeqCst) == 2 {
                    let _ = entered.send(());
                    let _ = gate.lock().unwrap().recv();
                }
                false
            })
        });
        read_started
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        let (written, write_done) = mpsc::channel();
        let writer = std::thread::spawn(move || {
            let result = store.save(&json!({"id":"22222222-2222-4222-8222-222222222222","title":"Second","projectID":"","items":[],"updatedAt":2.0}));
            let _ = written.send(result.is_ok());
        });
        let completed_while_reading = write_done.recv_timeout(std::time::Duration::from_secs(2));
        let _ = release.send(());
        writer.join().unwrap();
        assert!(completed_while_reading.unwrap());
        assert!(reader.join().unwrap().unwrap().is_some());
    }

    #[test]
    fn snippet_keeps_the_matching_line_and_marks_where_it_was_shortened() {
        assert_eq!(
            snippet("needle", "first line\nthe Needle is here\nlast").as_deref(),
            Some("the Needle is here")
        );
        let long = format!("{}needle{}", "a".repeat(60), "b".repeat(100));
        let line = snippet("NEEDLE", &long).unwrap();
        assert!(line.starts_with('…') && line.ends_with('…'));
        assert_eq!(line.chars().count(), 40 + 6 + 80 + 2);
        assert_eq!(
            snippet("café", "Le CAFÉ ouvre").as_deref(),
            Some("Le CAFÉ ouvre")
        );
        assert!(snippet("missing", "nothing here").is_none());
        assert!(snippet("  ", "anything").is_none());
    }

    #[test]
    fn only_user_and_agent_messages_of_listed_threads_match() {
        let root = std::env::temp_dir().join(format!("coincide-message-search-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let mut store = Store::open(&root.join("state.sqlite")).unwrap();
        let thread = |id: &str, archived: bool, items: Value| json!({"id":id,"title":"Synthetic","projectID":"","isArchived":archived,"items":items,"updatedAt":1.0});
        let user = "11111111-1111-4111-8111-111111111111";
        let tool = "22222222-2222-4222-8222-222222222222";
        let archived = "33333333-3333-4333-8333-333333333333";
        store
            .save(&thread(
                user,
                false,
                json!([{"id":"a","kind":"user","text":"Please fix the Sidebar search"}]),
            ))
            .unwrap();
        store
            .save(&thread(
                tool,
                false,
                json!([{"id":"b","kind":"tool","text":"sidebar search output"}]),
            ))
            .unwrap();
        store
            .save(&thread(
                archived,
                true,
                json!([{"id":"c","kind":"assistant","text":"sidebar search done"}]),
            ))
            .unwrap();
        let found = store.message_matches("sidebar search", false).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[user], "Please fix the Sidebar search");
        let all = store.message_matches("sidebar search", true).unwrap();
        assert_eq!(all.len(), 2);
        assert!(store.message_matches("s", true).unwrap().is_empty());
        drop(store);
        fs::remove_dir_all(root).unwrap();
    }
}
