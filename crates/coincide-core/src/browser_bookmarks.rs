//! Explicit HTTP(S)-only bookmark import into a separate Rust-owned document.
//! No filesystem paths, cookies, credentials, navigation or source IDs persisted.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use uuid::Uuid;

pub const DOCUMENT: &str = "rust-browser-bookmarks.json";
pub const MAX_EXPORT_BYTES: usize = 1_048_576;
// Keep room for the existing 4 MiB local-control response envelope.
const MAX_LIBRARY_BYTES: usize = 3 * 1_048_576;
const MAX_BOOKMARKS: usize = 5_000;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Candidate {
    pub url: String,
    pub title: String,
    #[serde(default)]
    pub folder: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Bookmark {
    pub id: Uuid,
    pub url: String,
    pub title: String,
    #[serde(default)]
    pub folder: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Library {
    pub version: u32,
    pub revision: u64,
    pub bookmarks: Vec<Bookmark>,
}
impl Default for Library {
    fn default() -> Self {
        Self {
            version: 1,
            revision: 0,
            bookmarks: Vec::new(),
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Plan {
    pub bookmarks: Vec<Candidate>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ImportResult {
    pub library: Library,
    pub added: usize,
    pub duplicates: usize,
}
fn unsafe_text(text: &str) -> bool {
    text.chars().any(|c|c.is_control() || matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}'))
}
fn sensitive_key(key: &str) -> bool {
    matches!(
        key.to_ascii_lowercase().replace(['_', '-'], "").as_str(),
        "password"
            | "passwd"
            | "totp"
            | "privatekey"
            | "accesstoken"
            | "refreshtoken"
            | "authorization"
            | "clientsecret"
            | "apikey"
            | "token"
            | "secret"
    )
}
fn credential_fields(value: &Value) -> bool {
    match value {
        Value::Object(fields) => fields
            .iter()
            .any(|(key, value)| sensitive_key(key) || credential_fields(value)),
        Value::Array(items) => items.iter().any(credential_fields),
        _ => false,
    }
}
pub fn validate_url(raw: &str) -> Result<String> {
    ensure!(
        !raw.is_empty()
            && raw.len() <= 4096
            && raw.trim() == raw
            && !unsafe_text(raw)
            && !raw.contains('\\'),
        "Bookmark URL is invalid or exceeds 4096 bytes"
    );
    let url = crate::browser_protocol::validate_url(raw)?;
    ensure!(
        !url.query_pairs().any(|(key, _)| sensitive_key(&key)),
        "Credential-bearing URL parameters cannot be saved as bookmarks"
    );
    if let Some(fragment) = url.fragment() {
        ensure!(
            !url::form_urlencoded::parse(fragment.as_bytes()).any(|(key, _)| sensitive_key(&key)),
            "Credential-bearing URL fragments cannot be saved as bookmarks"
        );
    }
    Ok(url.into())
}
impl Candidate {
    fn validate(&self) -> Result<()> {
        ensure!(
            validate_url(&self.url)? == self.url,
            "Bookmark URL must use its reviewed canonical form"
        );
        ensure!(
            !self.title.is_empty()
                && self.title.chars().count() <= 500
                && !unsafe_text(&self.title),
            "Bookmark title must contain 1–500 plain characters"
        );
        if let Some(folder) = &self.folder {
            ensure!(
                folder.chars().count() <= 200 && !unsafe_text(folder),
                "Bookmark folder must contain at most 200 plain characters"
            );
        }
        Ok(())
    }
}
pub fn fingerprint(bytes: &[u8]) -> String {
    crate::digest_hex::lower_hex(Sha256::digest(bytes))
}
/// Parses only documented bookmark fields. Other metadata is preview-only and
/// never copied into the durable library. Source IDs are never reused.
pub fn preview(bytes: &[u8]) -> Result<Plan> {
    ensure!(
        bytes.len() <= MAX_EXPORT_BYTES,
        "Bookmark export exceeds 1 MiB"
    );
    let value: Value = serde_json::from_slice(bytes).context("Invalid bookmark JSON export")?;
    ensure!(
        value.is_object() && !credential_fields(&value),
        "Credential-bearing or invalid bookmark exports are refused"
    );
    let entries = value["bookmarks"]
        .as_array()
        .context("Export has no bookmark array")?;
    ensure!(
        !entries.is_empty() && entries.len() <= MAX_BOOKMARKS,
        "Choose an export with 1–5000 bookmarks"
    );
    let mut bookmarks = Vec::with_capacity(entries.len());
    for entry in entries {
        let fields = entry.as_object().context("Invalid bookmark record")?;
        ensure!(
            fields
                .keys()
                .all(|key| matches!(key.as_str(), "id" | "url" | "title" | "folder")),
            "Bookmark record contains unsupported metadata"
        );
        if let Some(id) = fields.get("id") {
            Uuid::parse_str(id.as_str().context("Invalid source bookmark ID")?)?;
        }
        let url = validate_url(entry["url"].as_str().context("Bookmark URL must be text")?)?;
        let title = entry["title"]
            .as_str()
            .context("Bookmark title must be text")?;
        let folder = match fields.get("folder") {
            None | Some(Value::Null) => None,
            Some(value) => Some(
                value
                    .as_str()
                    .context("Bookmark folder must be text")?
                    .to_owned(),
            ),
        };
        let candidate = Candidate {
            title: if title.is_empty() {
                url.clone()
            } else {
                title.into()
            },
            url,
            folder,
        };
        candidate.validate()?;
        bookmarks.push(candidate);
    }
    let plan = Plan { bookmarks };
    plan.validate()?;
    Ok(plan)
}
impl Plan {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.bookmarks.is_empty() && self.bookmarks.len() <= MAX_BOOKMARKS,
            "Import must contain 1–5000 bookmarks"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_EXPORT_BYTES,
            "Bookmark import exceeds 1 MiB"
        );
        for bookmark in &self.bookmarks {
            bookmark.validate()?;
        }
        Ok(())
    }
}
impl Library {
    pub fn from_document(document: Option<Value>) -> Result<Self> {
        let Some(document) = document else {
            return Ok(Self::default());
        };
        ensure!(
            serde_json::to_vec(&document)?.len() <= MAX_LIBRARY_BYTES,
            "Saved bookmark library exceeds its bound"
        );
        let library: Self = serde_json::from_value(document)
            .context("Saved bookmark library is invalid; contents retained")?;
        library.validate()?;
        Ok(library)
    }
    fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 1 && self.bookmarks.len() <= MAX_BOOKMARKS,
            "Unsupported bookmark library version or count"
        );
        let mut ids = HashSet::new();
        let mut urls = HashSet::new();
        for bookmark in &self.bookmarks {
            Candidate {
                url: bookmark.url.clone(),
                title: bookmark.title.clone(),
                folder: bookmark.folder.clone(),
            }
            .validate()?;
            ensure!(
                ids.insert(bookmark.id) && urls.insert(&bookmark.url),
                "Saved library contains duplicate identities or URLs"
            );
        }
        Ok(())
    }
    pub fn merge(&self, expected_revision: u64, plan: &Plan) -> Result<ImportResult> {
        self.validate()?;
        plan.validate()?;
        ensure!(
            self.revision == expected_revision,
            "Saved bookmarks changed; reload before importing"
        );
        let mut library = self.clone();
        let mut urls = self
            .bookmarks
            .iter()
            .map(|bookmark| bookmark.url.clone())
            .collect::<HashSet<_>>();
        let mut added = 0;
        for value in &plan.bookmarks {
            if urls.insert(value.url.clone()) {
                ensure!(
                    library.bookmarks.len() < MAX_BOOKMARKS,
                    "Bookmark library is full; nothing imported"
                );
                library.bookmarks.push(Bookmark {
                    id: Uuid::new_v4(),
                    url: value.url.clone(),
                    title: value.title.clone(),
                    folder: value.folder.clone(),
                });
                added += 1;
            }
        }
        if added > 0 {
            library.revision = library
                .revision
                .checked_add(1)
                .context("Bookmark revision exhausted")?;
        }
        library.validate()?;
        ensure!(
            serde_json::to_vec(&library)?.len() <= MAX_LIBRARY_BYTES,
            "Bookmark library is full; nothing imported"
        );
        Ok(ImportResult {
            library,
            added,
            duplicates: plan.bookmarks.len() - added,
        })
    }
    /// Native current-page toggle. A stale library cannot remove or add a row.
    pub fn toggle(&self, expected_revision: u64, candidate: Candidate) -> Result<Self> {
        self.validate()?;
        ensure!(
            validate_url(&candidate.url)? == candidate.url,
            "Bookmark URL must be canonical"
        );
        ensure!(
            self.revision == expected_revision,
            "Bookmarks changed; reload before toggling"
        );
        if !self.bookmarks.iter().any(|row| row.url == candidate.url) {
            return Ok(self
                .merge(
                    expected_revision,
                    &Plan {
                        bookmarks: vec![candidate],
                    },
                )?
                .library);
        }
        let mut library = self.clone();
        library.bookmarks.retain(|row| row.url != candidate.url);
        library.revision = library
            .revision
            .checked_add(1)
            .context("Bookmark revision exhausted")?;
        library.validate()?;
        Ok(library)
    }
    pub fn selected(&self, id: Uuid, expected_revision: u64) -> Result<&Bookmark> {
        self.validate()?;
        ensure!(
            self.revision == expected_revision,
            "Bookmarks changed; reload before opening"
        );
        self.bookmarks
            .iter()
            .find(|bookmark| bookmark.id == id)
            .context("Saved bookmark no longer exists")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn export(url: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({"bookmarks":[{"id":Uuid::nil(),"url":url,"title":"café 中文","folder":"Imported"}]})).unwrap()
    }
    #[test]
    fn canonical_urls_dedupe_without_reusing_source_ids_or_overwriting_saved_titles() {
        let mut source: Value =
            serde_json::from_slice(&export("https://EXAMPLE.com:443/path")).unwrap();
        let duplicate = source["bookmarks"][0].clone();
        source["bookmarks"].as_array_mut().unwrap().push(duplicate);
        let plan = preview(&serde_json::to_vec(&source).unwrap()).unwrap();
        let result = Library::default().merge(0, &plan).unwrap();
        assert_eq!(result.added, 1);
        assert_eq!(result.duplicates, 1);
        assert_eq!(result.library.revision, 1);
        assert_eq!(result.library.bookmarks[0].url, "https://example.com/path");
        assert_ne!(result.library.bookmarks[0].id, Uuid::nil());
        let mut retry = plan.clone();
        retry.bookmarks[0].title = "different source title".into();
        let replay = result.library.merge(1, &retry).unwrap();
        assert_eq!(replay.added, 0);
        assert_eq!(replay.library, result.library);
        assert!(result.library.merge(0, &retry).is_err());
    }
    #[test]
    fn hostile_urls_and_credential_fields_never_form_a_plan() {
        for url in [
            "javascript:alert(1)",
            "data:text/html,x",
            "file:///etc/passwd",
            "ftp://example.com/a",
            "//example.com/a",
            "https://user:password@example.com/",
            "https://user@example.com/",
            "https://example.com/?access_token=secret",
            "https://example.com/#refresh_token=secret",
            " https://example.com/",
            "https://example.com/\npath",
            "https://example.com/\\path",
            "https://example.com/\u{202e}txt",
        ] {
            assert!(
                preview(&export(url)).is_err(),
                "accepted a hostile bookmark URL"
            );
        }
        for source in [
            serde_json::json!({"bookmarks":[{"url":"https://example.com/","title":"x","sourcePath":"/etc/passwd"}]}),
            serde_json::json!({"bookmarks":[{"url":"https://example.com/","title":"x"}],"profiles":[{"refresh_token":"synthetic secret"}]}),
        ] {
            assert!(preview(&serde_json::to_vec(&source).unwrap()).is_err());
        }
        assert!(
            preview(&export("http://127.0.0.1:1234/local")).is_ok(),
            "user-click HTTP navigation retains existing browser URL policy"
        );
    }
    #[test]
    fn ordinary_search_queries_and_harmless_fragments_are_preserved() {
        for url in [
            "https://example.com/search?q=rust%20gpui&page=2",
            "https://example.com/docs#installation",
            "https://example.com/docs?lang=en#section-2",
        ] {
            assert_eq!(preview(&export(url)).unwrap().bookmarks[0].url, url);
        }
    }
    #[test]
    fn bounds_and_malformed_future_library_fail_without_pruning_or_overwrite() {
        assert!(preview(&vec![b' '; MAX_EXPORT_BYTES + 1]).is_err());
        assert!(
            preview(br#"{"bookmarks":[{"url":"https://example.com/","title":"x","folder":42}]}"#)
                .is_err()
        );
        assert!(preview(br#"{"bookmarks":[]}"#).is_err());
        let full = Library {
            version: 1,
            revision: 7,
            bookmarks: (0..MAX_BOOKMARKS)
                .map(|i| Bookmark {
                    id: Uuid::from_u128(i as u128 + 1),
                    url: format!("https://example.com/{i}"),
                    title: format!("Bookmark {i}"),
                    folder: None,
                })
                .collect(),
        };
        let before = full.clone();
        assert!(
            full.merge(7, &preview(&export("https://example.com/new")).unwrap())
                .is_err()
        );
        assert_eq!(full, before);
        for value in [
            serde_json::json!({"version":2,"revision":0,"bookmarks":[]}),
            serde_json::json!({"version":1,"revision":0,"bookmarks":[],"future":true}),
        ] {
            assert!(Library::from_document(Some(value)).is_err());
        }
        let exhausted = Library {
            revision: u64::MAX,
            ..Library::default()
        };
        assert!(
            exhausted
                .merge(
                    u64::MAX,
                    &preview(&export("https://example.com/new")).unwrap()
                )
                .is_err()
        );
    }
}

#[cfg(test)]
mod toggle_tests {
    use super::*;
    #[test]
    fn toggle_preserves_unrelated_rows_and_rejects_stale_or_sensitive_urls() {
        let candidate = |url: &str| Candidate {
            url: url.into(),
            title: "Page".into(),
            folder: None,
        };
        let first = Library::default()
            .toggle(0, candidate("https://example.com/one"))
            .unwrap();
        let second = first
            .toggle(1, candidate("https://example.com/two"))
            .unwrap();
        assert!(
            second
                .toggle(1, candidate("https://example.com/one"))
                .is_err()
        );
        assert!(
            second
                .toggle(2, candidate("https://example.com/?token=secret"))
                .is_err()
        );
        let removed = second
            .toggle(2, candidate("https://example.com/one"))
            .unwrap();
        assert_eq!(removed.revision, 3);
        assert_eq!(removed.bookmarks, vec![second.bookmarks[1].clone()]);
    }
}
