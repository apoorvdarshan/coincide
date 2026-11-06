//! Reviewed browser metadata history. No browser databases, cookies or navigation.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashSet};
use uuid::Uuid;

pub const MAX_EXPORT_BYTES: usize = 1_048_576;
pub const MAX_LIBRARY_BYTES: usize = 3 * 1_048_576;
const MAX_HISTORY: usize = 5_000;
pub fn document_name(profile: Uuid) -> String {
    format!("rust-browser-history-{profile}.json")
}
fn plain(value: &str) -> bool {
    !value.chars().any(|c| c.is_control() || matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}'))
}
fn credentials(value: &Value) -> bool {
    match value {
        Value::Object(fields) => fields.iter().any(|(key, value)| {
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
                    | "cookies"
                    | "cookie"
                    | "cookiejar"
                    | "setcookie"
            ) || credentials(value)
        }),
        Value::Array(items) => items.iter().any(credentials),
        _ => false,
    }
}
#[derive(Clone, Debug)]
pub struct RecordView {
    pub url: String,
    pub title: String,
    pub visit_count: u64,
    pub last_visit: String,
}
/// The existing Swift metadata format uses seconds since 2001-01-01 for Date.
pub fn record_view(record: &Value) -> Result<RecordView> {
    ensure!(
        record.is_object() && !credentials(record),
        "History record contains credential data or is invalid"
    );
    let url = crate::browser_bookmarks::validate_url(
        record["url"].as_str().context("History URL must be text")?,
    )?;
    let title = record["title"]
        .as_str()
        .context("History title must be text")?;
    ensure!(
        title.chars().count() <= 500 && plain(title),
        "History title must contain at most 500 plain characters"
    );
    let visit_count = record["visitCount"]
        .as_u64()
        .filter(|count| *count > 0 && *count <= i64::MAX as u64)
        .context("History visitCount must be a positive integer")?;
    let seconds = record["lastVisit"]
        .as_f64()
        .filter(|value| {
            value.is_finite() && (-63_113_904_000.0..=253_370_764_799.0).contains(value)
        })
        .context("History lastVisit must be a supported numeric Swift date")?;
    let date =
        chrono::DateTime::<chrono::Utc>::from_timestamp((seconds + 978_307_200.).floor() as i64, 0)
            .context("History lastVisit is outside the supported date range")?;
    Ok(RecordView {
        title: if title.is_empty() {
            url.clone()
        } else {
            title.into()
        },
        url,
        visit_count,
        last_visit: date.format("%Y-%m-%d %H:%M UTC").to_string(),
    })
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Plan {
    pub history: Vec<Value>,
    pub source_metadata: Value,
    pub fingerprint: String,
}
pub fn preview(bytes: &[u8]) -> Result<Plan> {
    ensure!(
        bytes.len() <= MAX_EXPORT_BYTES,
        "History export exceeds 1 MiB"
    );
    let source: Value =
        serde_json::from_slice(bytes).context("Choose a browser metadata JSON export")?;
    let fields = source
        .as_object()
        .context("Browser metadata must be an object")?;
    let history = source["history"]
        .as_array()
        .context("Export has no history array")?
        .clone();
    // Other known export sections are not imported. Opaque non-secret export
    // metadata and each exact parsed history record are retained separately.
    let metadata = fields
        .iter()
        .filter(|(key, _)| {
            !matches!(
                key.as_str(),
                "history"
                    | "bookmarks"
                    | "cookies"
                    | "profiles"
                    | "profileID"
                    | "usesPrivateSessions"
            )
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect::<Map<_, _>>();
    let plan = Plan {
        history,
        source_metadata: Value::Object(metadata),
        fingerprint: crate::browser_bookmarks::fingerprint(bytes),
    };
    plan.validate()?;
    Ok(plan)
}
impl Plan {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.history.is_empty() && self.history.len() <= MAX_HISTORY,
            "Choose an export with 1–5000 history entries"
        );
        ensure!(
            self.source_metadata.is_object() && !credentials(&self.source_metadata),
            "History export metadata contains credential data"
        );
        ensure!(
            self.fingerprint.len() == 64 && self.fingerprint.bytes().all(|b| b.is_ascii_hexdigit()),
            "Invalid history export fingerprint"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_LIBRARY_BYTES,
            "History import exceeds its bound"
        );
        for record in &self.history {
            record_view(record)?;
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Entry {
    pub id: Uuid,
    pub url: String,
    pub record: Value,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Library {
    pub version: u32,
    pub revision: u64,
    pub profile: Uuid,
    pub history: Vec<Entry>,
    #[serde(default)]
    pub imports: BTreeMap<String, Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Debug)]
pub struct ImportResult {
    pub library: Library,
    pub added: usize,
    pub duplicates: usize,
    pub changed: bool,
}
impl Library {
    pub fn empty(profile: Uuid) -> Self {
        Self {
            version: 1,
            revision: 0,
            profile,
            history: Vec::new(),
            imports: BTreeMap::new(),
            extra: Map::new(),
        }
    }
    pub fn from_document(profile: Uuid, document: Option<Value>) -> Result<Self> {
        let library = match document {
            None => Self::empty(profile),
            Some(value) => {
                ensure!(
                    serde_json::to_vec(&value)?.len() <= MAX_LIBRARY_BYTES,
                    "Saved history exceeds its bound"
                );
                serde_json::from_value(value)
                    .context("Saved history is malformed; contents retained")?
            }
        };
        library.validate(profile)?;
        Ok(library)
    }
    pub fn validate(&self, profile: Uuid) -> Result<()> {
        ensure!(
            self.version == 1
                && self.profile == profile
                && self.history.len() <= MAX_HISTORY
                && self.imports.len() <= 100,
            "Invalid history version, profile or count"
        );
        let mut ids = HashSet::new();
        let mut urls = HashSet::new();
        for entry in &self.history {
            let view = record_view(&entry.record)?;
            ensure!(
                entry.url == view.url && ids.insert(entry.id) && urls.insert(&entry.url),
                "Saved history contains duplicate identities/URLs or mismatched URL metadata"
            );
        }
        ensure!(
            !credentials(&serde_json::to_value(self)?),
            "Saved history contains credential data"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_LIBRARY_BYTES,
            "Saved history exceeds its bound"
        );
        Ok(())
    }
    pub fn merge(&self, expected: u64, plan: &Plan) -> Result<ImportResult> {
        self.validate(self.profile)?;
        plan.validate()?;
        ensure!(
            self.revision == expected,
            "Saved history changed; reload before importing"
        );
        let mut library = self.clone();
        let mut urls = self
            .history
            .iter()
            .map(|entry| entry.url.clone())
            .collect::<HashSet<_>>();
        let mut added = 0;
        for record in &plan.history {
            let view = record_view(record)?;
            if urls.insert(view.url.clone()) {
                ensure!(
                    library.history.len() < MAX_HISTORY,
                    "History library is full; nothing imported"
                );
                library.history.push(Entry {
                    id: Uuid::new_v4(),
                    url: view.url,
                    record: record.clone(),
                    extra: Map::new(),
                });
                added += 1;
            }
        }
        let fresh_metadata = !library.imports.contains_key(&plan.fingerprint);
        if fresh_metadata {
            ensure!(
                library.imports.len() < 100,
                "History import metadata is full; nothing imported"
            );
            library
                .imports
                .insert(plan.fingerprint.clone(), plan.source_metadata.clone());
        }
        let changed = added > 0 || fresh_metadata;
        if changed {
            library.revision = library
                .revision
                .checked_add(1)
                .context("History revision exhausted")?;
        }
        library.validate(self.profile)?;
        Ok(ImportResult {
            library,
            added,
            duplicates: plan.history.len() - added,
            changed,
        })
    }
    pub fn selected(&self, id: Uuid, revision: u64) -> Result<&Entry> {
        self.validate(self.profile)?;
        ensure!(
            self.revision == revision,
            "Saved history changed; reload before opening"
        );
        self.history
            .iter()
            .find(|entry| entry.id == id)
            .context("Saved history entry no longer exists")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn source() -> Value {
        json!({"history":[{"url":"https://EXAMPLE.com:443/path","title":"Café 中文","visitCount":2,"lastVisit":0,"future":{"keep":[1,2]}}],"futureExport":{"opaque":true},"cookies":[{"value":"not imported"}]})
    }
    #[test]
    fn source_records_unknown_metadata_and_saved_fields_survive_canonical_deduplication() {
        let original = source();
        let bytes = serde_json::to_vec(&original).unwrap();
        let plan = preview(&bytes).unwrap();
        let profile = Uuid::new_v4();
        let mut library = Library::empty(profile);
        library
            .extra
            .insert("futureLibrary".into(), json!({"keep":true}));
        let first = library.merge(0, &plan).unwrap();
        assert_eq!(first.added, 1);
        assert_eq!(first.library.history[0].record, original["history"][0]);
        assert_eq!(first.library.history[0].url, "https://example.com/path");
        assert_eq!(first.library.extra, library.extra);
        assert_eq!(
            first.library.imports[&plan.fingerprint],
            json!({"futureExport":{"opaque":true}})
        );
        let repeated = first.library.merge(1, &plan).unwrap();
        assert_eq!(repeated.added, 0);
        assert_eq!(repeated.duplicates, 1);
        assert!(!repeated.changed);
        assert_eq!(repeated.library, first.library);
        let mut changed_source = original.clone();
        changed_source["history"][0]["title"] = json!("Different incoming title");
        changed_source["history"][0]["visitCount"] = json!(99);
        changed_source["history"][0]["future"] = json!({"different":"source retained"});
        let changed_plan = preview(&serde_json::to_vec(&changed_source).unwrap()).unwrap();
        let duplicate = first.library.merge(1, &changed_plan).unwrap();
        assert_eq!(duplicate.added, 0);
        assert_eq!(duplicate.duplicates, 1);
        assert_eq!(duplicate.library.history, first.library.history);
        assert_eq!(serde_json::to_vec(&original).unwrap(), bytes);
    }
    #[test]
    fn hostile_urls_credentials_bad_dates_and_counts_fail_all_or_nothing() {
        for url in [
            "file:///private/a",
            "javascript:alert(1)",
            "https://user:pass@example.com/",
            "https://example.com/?token=secret",
        ] {
            let mut value = source();
            value["history"][0]["url"] = json!(url);
            assert!(preview(&serde_json::to_vec(&value).unwrap()).is_err());
        }
        for (key, value) in [
            ("visitCount", json!(0)),
            ("lastVisit", json!("2026-01-01")),
            ("lastVisit", json!(1e100)),
            ("password", json!("synthetic")),
        ] {
            let mut source = source();
            source["history"][0][key] = value;
            assert!(preview(&serde_json::to_vec(&source).unwrap()).is_err());
        }
        let plan = preview(&serde_json::to_vec(&source()).unwrap()).unwrap();
        let profile = Uuid::new_v4();
        let saved = Library::empty(profile).merge(0, &plan).unwrap().library;
        assert!(saved.merge(0, &plan).is_err());
        assert!(saved.validate(Uuid::new_v4()).is_err());
    }
}
