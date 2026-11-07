//! The sidebar's message search, as Swift's `AppStore.searchMessages`: threads
//! whose user or agent messages contain the typed text, each with the line
//! around its first match for the row's tooltip.
use super::*;
use std::collections::HashMap;

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
        let needle = needle.trim();
        if needle.chars().count() < 2 {
            return Ok(HashMap::new());
        }
        let mut found = HashMap::new();
        for summary in self.summaries(needle, include_archived)? {
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
        Ok(found)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
