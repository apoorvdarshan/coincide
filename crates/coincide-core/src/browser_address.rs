//! What the browser's address bar opens for what the user typed, the search
//! engine it searches with, and inline completion from bookmarks and history.
//! Ported from Swift `BrowserAddress`, `SearchEngine`, `PreviewCommand.url` and
//! `BrowserLibrary.suggestions`/`inlineCompletion`. Local files are only ever
//! opened from the user's own typing; agents keep HTTP(S)-only navigation.
use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};
pub use url::Url;

/// The search engine the address bar searches with when what's typed isn't an
/// address. Raw values match Swift's `browser.json` `searchEngine`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SearchEngine {
    #[default]
    #[serde(rename = "google")]
    Google,
    #[serde(rename = "duckDuckGo")]
    DuckDuckGo,
    #[serde(rename = "bing")]
    Bing,
    #[serde(rename = "brave")]
    Brave,
    #[serde(rename = "ecosia")]
    Ecosia,
    #[serde(rename = "kagi")]
    Kagi,
}

impl SearchEngine {
    pub const ALL: [Self; 6] = [
        Self::Google,
        Self::DuckDuckGo,
        Self::Bing,
        Self::Brave,
        Self::Ecosia,
        Self::Kagi,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Google => "google",
            Self::DuckDuckGo => "duckDuckGo",
            Self::Bing => "bing",
            Self::Brave => "brave",
            Self::Ecosia => "ecosia",
            Self::Kagi => "kagi",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|engine| engine.id() == id)
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Google => "Google",
            Self::DuckDuckGo => "DuckDuckGo",
            Self::Bing => "Bing",
            Self::Brave => "Brave Search",
            Self::Ecosia => "Ecosia",
            Self::Kagi => "Kagi",
        }
    }

    fn base(self) -> &'static str {
        match self {
            Self::Google => "https://www.google.com/search",
            Self::DuckDuckGo => "https://duckduckgo.com/",
            Self::Bing => "https://www.bing.com/search",
            Self::Brave => "https://search.brave.com/search",
            Self::Ecosia => "https://www.ecosia.org/search",
            Self::Kagi => "https://kagi.com/search",
        }
    }

    /// The results page for `query`.
    pub fn url(self, query: &str) -> Option<Url> {
        let mut url = Url::parse(self.base()).ok()?;
        url.query_pairs_mut().append_pair("q", query);
        Some(url)
    }

    /// The engine saved in Settings › Browser; unknown or missing values are Google.
    pub fn from_settings(document: Option<&serde_json::Value>) -> Self {
        document
            .and_then(|value| value["searchEngine"].as_str())
            .and_then(Self::from_id)
            .unwrap_or_default()
    }
}

/// What the address bar opens.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Destination {
    Web(Url),
    /// An existing local file, standardized; its folder is what it may read.
    File(PathBuf),
    Search(Url),
}

/// Endings of files and code that are not web domains, so `notes.txt` or
/// `next.js` searches instead of failing.
const FILE_ENDINGS: &[&str] = &[
    "c", "cpp", "css", "csv", "env", "gif", "h", "htm", "html", "java", "jpeg", "jpg", "js",
    "json", "jsx", "kt", "lock", "log", "mjs", "pdf", "png", "py", "sh", "svg", "swift", "toml",
    "ts", "tsx", "txt", "xml", "yaml", "yml", "zip",
];

/// Swift's `split(whereSeparator:)` omits empty pieces; the first piece names
/// the authority of an address typed without a scheme.
fn authority(typed: &str) -> &str {
    typed
        .split(['/', '?', '#'])
        .find(|piece| !piece.is_empty())
        .unwrap_or(typed)
}

fn is_ipv4(labels: &[&str]) -> bool {
    labels.len() == 4 && labels.iter().all(|label| label.parse::<u8>().is_ok())
}

/// Whether an address typed without a scheme names a development server, which
/// gets `http://` as browsers give it: localhost, an IP address, a `.local` or
/// `.localhost` name, a single-label name, or any address with a port.
fn is_local(address: &str) -> bool {
    let authority = authority(address);
    if authority.starts_with('[') || authority.contains(':') {
        return true;
    }
    let host = authority.to_lowercase();
    if host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || !host.contains('.')
    {
        return true;
    }
    is_ipv4(
        &host
            .split('.')
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>(),
    )
}

/// An HTTP(S) address for what was typed, adding `https://` (or `http://` for a
/// development server) when there is no scheme. Like Swift `PreviewCommand.url`.
pub fn normalize_address(address: &str) -> Option<Url> {
    let trimmed = address.trim();
    if trimmed.is_empty() || trimmed.len() > 8192 {
        return None;
    }
    if let Some(colon) = trimmed.find(':')
        && !trimmed.contains("://")
        && !trimmed.starts_with('[')
    {
        let suffix = trimmed[colon + 1..]
            .split('/')
            .find(|piece| !piece.is_empty())
            .unwrap_or("");
        if suffix.is_empty() || !suffix.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
    }
    let normalized = if trimmed.contains("://") {
        trimmed.to_owned()
    } else if is_local(trimmed) {
        format!("http://{trimmed}")
    } else {
        format!("https://{trimmed}")
    };
    crate::browser_protocol::validate_url(&normalized).ok()
}

/// Whether text without a scheme names a site rather than being words to
/// search: no spaces, and a host that is a development server (localhost, an IP
/// address, `.local`, a port), or a domain whose last part isn't a file ending.
pub fn looks_like_address(typed: &str) -> bool {
    if typed.chars().any(char::is_whitespace) {
        return false;
    }
    let authority = authority(typed);
    if authority.starts_with('[') {
        return true;
    }
    let host = authority
        .split(':')
        .find(|piece| !piece.is_empty())
        .unwrap_or("")
        .to_lowercase();
    if host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || authority.contains(':')
    {
        return true;
    }
    let labels = host.split('.').collect::<Vec<_>>();
    if is_ipv4(&labels) {
        return true;
    }
    // A single word searches, unless typed as a path such as `devbox/`.
    if labels.len() <= 1 {
        return typed.starts_with(&format!("{host}/"));
    }
    let Some(last) = labels.last() else {
        return false;
    };
    labels.iter().all(|label| !label.is_empty())
        && last.chars().count() >= 2
        && last.chars().all(char::is_alphabetic)
        && !FILE_ENDINGS.contains(last)
}

/// Removes `.` and resolves `..` without touching the filesystem, like
/// Foundation's `standardizedFileURL`.
pub fn standardize(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !matches!(
                    result.components().next_back(),
                    None | Some(Component::RootDir | Component::Prefix(_))
                ) {
                    result.pop();
                }
            }
            other => result.push(other.as_os_str()),
        }
    }
    result
}

/// A path to a local file: `file:` addresses, absolute paths and `~/` paths.
pub fn file_path(typed: &str, home: &Path) -> Option<PathBuf> {
    if typed
        .get(..5)
        .is_some_and(|scheme| scheme.eq_ignore_ascii_case("file:"))
    {
        let url = Url::parse(typed).ok()?;
        if url.scheme() != "file" {
            return None;
        }
        let path = url.to_file_path().ok()?;
        return (!path.as_os_str().is_empty()).then(|| standardize(&path));
    }
    if let Some(rest) = typed
        .strip_prefix("~/")
        .or_else(|| cfg!(windows).then(|| typed.strip_prefix("~\\")).flatten())
    {
        return Some(standardize(&home.join(rest)));
    }
    let path = Path::new(typed);
    (path.is_absolute() || (cfg!(unix) && typed.starts_with('/'))).then(|| standardize(path))
}

/// What to open for `text`: a web address when it looks like one, a local file
/// by its path (only when `allows_files`, which is the user's own typing), and
/// otherwise a search. A leading `?` always searches. `is_file` reports whether
/// a path is an existing regular file; tests replace it.
pub fn resolve(
    text: &str,
    engine: SearchEngine,
    allows_files: bool,
    home: &Path,
    is_file: impl Fn(&Path) -> bool,
) -> Option<Destination> {
    let typed = text.trim();
    if typed.is_empty() || typed.len() > 8192 {
        return None;
    }
    if let Some(query) = typed.strip_prefix('?') {
        let query = query.trim();
        return (!query.is_empty())
            .then(|| engine.url(query).map(Destination::Search))
            .flatten();
    }
    if let Some(file) = file_path(typed, home) {
        if !allows_files {
            return None;
        }
        if is_file(&file) {
            return Some(Destination::File(file));
        }
        return if typed.to_ascii_lowercase().starts_with("file:") {
            None
        } else {
            engine.url(typed).map(Destination::Search)
        };
    }
    if typed.contains("://") {
        return normalize_address(typed).map(Destination::Web);
    }
    if looks_like_address(typed)
        && let Some(url) = normalize_address(typed)
    {
        return Some(Destination::Web(url));
    }
    engine.url(typed).map(Destination::Search)
}

/// An existing regular file, following symbolic links as a browser does.
pub fn is_regular_file(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
}

/// The folder a local page the user opened may read: the file's own folder.
pub fn file_root(file: &Path) -> Option<PathBuf> {
    file.parent().map(standardize)
}

/// Whether native navigation may load `address` in a tab whose user opened a
/// local file under `root`: file URLs inside that folder only. Hosts (UNC
/// shares) are refused; web addresses are decided by the HTTP(S) policy.
pub fn file_navigation_allowed(address: &str, root: &Path) -> bool {
    let Ok(url) = Url::parse(address) else {
        return false;
    };
    if url.scheme() != "file" || url.host_str().is_some_and(|host| !host.is_empty()) {
        return false;
    }
    let Ok(path) = url.to_file_path() else {
        return false;
    };
    let root = standardize(root);
    root.components().next().is_some() && standardize(&path).starts_with(&root)
}

/// A history entry offered for completion. `last_visit` is seconds since
/// 2001-01-01, as Swift saves dates.
#[derive(Clone, Debug, PartialEq)]
pub struct HistoryItem {
    pub url: String,
    pub title: String,
    pub visit_count: u64,
    pub last_visit: f64,
}

/// Seconds between 1970 and Swift's 2001 reference date.
pub const REFERENCE_DATE_OFFSET: f64 = 978_307_200.;

/// The current time in seconds since 2001-01-01.
pub fn reference_now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0., |elapsed| elapsed.as_secs_f64())
        - REFERENCE_DATE_OFFSET
}

/// Bookmarks and history the address bar completes from.
#[derive(Clone, Debug, Default)]
pub struct CompletionIndex {
    bookmarks: Vec<(String, String)>,
    history: Vec<HistoryItem>,
}

fn stripped(text: &str) -> &str {
    let text = text
        .strip_prefix("https://")
        .or_else(|| text.strip_prefix("http://"))
        .unwrap_or(text);
    text.strip_prefix("www.").unwrap_or(text)
}

/// The ways a user might start typing an address: without `www.`, without its
/// scheme, and in full.
fn display_forms(address: &str) -> Vec<&str> {
    let bare = address
        .strip_prefix("https://")
        .or_else(|| address.strip_prefix("http://"))
        .unwrap_or(address);
    let mut forms = vec![address, bare];
    if let Some(short) = bare.strip_prefix("www.") {
        forms.push(short);
    }
    forms.reverse();
    forms
}

impl CompletionIndex {
    pub fn new(bookmarks: Vec<(String, String)>, history: Vec<HistoryItem>) -> Self {
        Self { bookmarks, history }
    }

    /// From the saved Rust bookmarks and one profile's saved history.
    pub fn from_libraries(
        bookmarks: Option<&crate::browser_bookmarks::Library>,
        history: Option<&crate::browser_history::Library>,
    ) -> Self {
        let bookmarks = bookmarks
            .into_iter()
            .flat_map(|library| &library.bookmarks)
            .map(|bookmark| (bookmark.url.clone(), bookmark.title.clone()))
            .collect();
        let history = history
            .into_iter()
            .flat_map(|library| &library.history)
            .filter_map(|entry| {
                Some(HistoryItem {
                    url: entry.url.clone(),
                    title: entry.record["title"].as_str()?.to_owned(),
                    visit_count: entry.record["visitCount"].as_u64()?,
                    last_visit: entry.record["lastVisit"].as_f64()?,
                })
            })
            .collect();
        Self { bookmarks, history }
    }

    pub fn is_empty(&self) -> bool {
        self.bookmarks.is_empty() && self.history.is_empty()
    }

    /// Addresses for what the user typed: bookmarks first, then history by how
    /// often and how recently it was visited. Matches the address without its
    /// scheme and `www.`, or a word in the title.
    pub fn suggestions(&self, text: &str, limit: usize, now: f64) -> Vec<String> {
        let query = text.trim().to_lowercase();
        if query.is_empty() {
            return Vec::new();
        }
        let bare = stripped(&query).to_owned();
        let matches = |address: &str, title: &str| {
            stripped(&address.to_lowercase()).starts_with(&bare)
                || title.to_lowercase().contains(&query)
        };
        let mut seen = std::collections::HashSet::new();
        let mut result = Vec::new();
        for (url, title) in &self.bookmarks {
            if matches(url, title) && seen.insert(url.as_str()) {
                result.push(url.clone());
            }
        }
        let score = |item: &HistoryItem| {
            let days = ((now - item.last_visit) / 86_400.).max(0.);
            item.visit_count as f64 / (1. + days / 7.)
        };
        let mut ranked = self
            .history
            .iter()
            .filter(|item| matches(&item.url, &item.title) && !seen.contains(item.url.as_str()))
            .collect::<Vec<_>>();
        ranked.sort_by(|a, b| score(b).total_cmp(&score(a)));
        result.extend(ranked.into_iter().take(limit).map(|item| item.url.clone()));
        result.truncate(limit);
        result
    }

    /// What to complete inline as the user types `text`: the rest of the best
    /// history or bookmark address that starts with it, keeping what the user
    /// typed (so `git` completes to `github.com/…`).
    pub fn inline_completion(&self, text: &str, now: f64) -> Option<String> {
        let typed = text.trim_matches(|c: char| c.is_whitespace() && c != '\n');
        let typed_count = typed.chars().count();
        if typed_count < 2 || typed.contains(' ') {
            return None;
        }
        let lower = typed.to_lowercase();
        for address in self.suggestions(typed, 20, now) {
            for form in display_forms(&address) {
                if form.to_lowercase().starts_with(&lower) && form.chars().count() > typed_count {
                    return Some(format!(
                        "{typed}{}",
                        form.chars().skip(typed_count).collect::<String>()
                    ));
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn resolve_text(text: &str, files: &[&str]) -> Option<Destination> {
        let files = files.iter().map(PathBuf::from).collect::<Vec<_>>();
        resolve(
            text,
            SearchEngine::Google,
            true,
            Path::new(if cfg!(windows) {
                r"C:\Users\person"
            } else {
                "/Users/person"
            }),
            |path| files.iter().any(|file| file == path),
        )
    }

    fn web(text: &str) -> String {
        match resolve_text(text, &[]) {
            Some(Destination::Web(url)) => url.to_string(),
            other => panic!("{text} did not open as an address: {other:?}"),
        }
    }

    fn search(text: &str) -> String {
        match resolve_text(text, &[]) {
            Some(Destination::Search(url)) => url.to_string(),
            other => panic!("{text} did not search: {other:?}"),
        }
    }

    #[test]
    fn bare_hosts_get_https_and_development_servers_get_http() {
        assert_eq!(web("example.com"), "https://example.com/");
        assert_eq!(
            web("github.com/apple/swift"),
            "https://github.com/apple/swift"
        );
        assert_eq!(web("localhost:3000"), "http://localhost:3000/");
        assert_eq!(web("localhost"), "http://localhost/");
        assert_eq!(web("app.localhost/x"), "http://app.localhost/x");
        assert_eq!(web("printer.local"), "http://printer.local/");
        assert_eq!(web("192.168.1.10"), "http://192.168.1.10/");
        assert_eq!(
            web("192.168.1.10:8080/admin"),
            "http://192.168.1.10:8080/admin"
        );
        assert_eq!(web("[::1]:5173"), "http://[::1]:5173/");
        assert_eq!(web("devbox/"), "http://devbox/");
        assert_eq!(
            web("https://example.com/a?b=c"),
            "https://example.com/a?b=c"
        );
        assert_eq!(web("  http://Example.COM  "), "http://example.com/");
    }

    #[test]
    fn words_files_and_code_endings_search_with_the_engine() {
        assert_eq!(
            search("rust ownership"),
            "https://www.google.com/search?q=rust+ownership"
        );
        assert_eq!(
            search("notes.txt"),
            "https://www.google.com/search?q=notes.txt"
        );
        assert_eq!(search("next.js"), "https://www.google.com/search?q=next.js");
        assert_eq!(search("swift"), "https://www.google.com/search?q=swift");
        assert_eq!(search("a.1b"), "https://www.google.com/search?q=a.1b");
        assert_eq!(
            search("? example.com"),
            "https://www.google.com/search?q=example.com"
        );
        assert_eq!(
            search("c++ & rust"),
            "https://www.google.com/search?q=c%2B%2B+%26+rust"
        );
        assert_eq!(resolve_text("?   ", &[]), None);
        assert_eq!(resolve_text("   ", &[]), None);
        assert_eq!(resolve_text(&"a".repeat(8193), &[]), None);
    }

    #[test]
    fn credentials_unknown_schemes_and_bad_ports_are_refused() {
        assert_eq!(resolve_text("https://user:secret@example.com", &[]), None);
        assert_eq!(resolve_text("javascript://alert(1)", &[]), None);
        assert_eq!(resolve_text("ftp://example.com", &[]), None);
        assert_eq!(normalize_address("example.com:abc"), None);
        assert_eq!(normalize_address("example.com:"), None);
        assert_eq!(normalize_address("user@example.com"), None);
        assert_eq!(
            normalize_address("example.com:443/path").map(String::from),
            Some("http://example.com:443/path".into())
        );
    }

    #[test]
    fn every_engine_has_a_results_page_and_reads_its_saved_id() {
        for engine in SearchEngine::ALL {
            let url = engine.url("a b").unwrap();
            assert_eq!(url.scheme(), "https");
            assert_eq!(url.query(), Some("q=a+b"));
            assert_eq!(SearchEngine::from_id(engine.id()), Some(engine));
            assert_eq!(
                serde_json::to_value(engine).unwrap(),
                serde_json::json!(engine.id())
            );
        }
        assert_eq!(
            SearchEngine::DuckDuckGo.url("x").unwrap().as_str(),
            "https://duckduckgo.com/?q=x"
        );
        assert_eq!(SearchEngine::Brave.name(), "Brave Search");
        let saved = serde_json::json!({"searchEngine":"kagi","profileID":"opaque"});
        assert_eq!(
            SearchEngine::from_settings(Some(&saved)),
            SearchEngine::Kagi
        );
        let future = serde_json::json!({"searchEngine":"future"});
        assert_eq!(
            SearchEngine::from_settings(Some(&future)),
            SearchEngine::Google
        );
        assert_eq!(SearchEngine::from_settings(None), SearchEngine::Google);
    }

    #[cfg(unix)]
    #[test]
    fn typed_paths_open_existing_files_and_otherwise_search() {
        let files = ["/Users/person/site/index.html", "/tmp/report.pdf"];
        assert_eq!(
            resolve_text("~/site/index.html", &files),
            Some(Destination::File("/Users/person/site/index.html".into()))
        );
        assert_eq!(
            resolve_text("/tmp/./x/../report.pdf", &files),
            Some(Destination::File("/tmp/report.pdf".into()))
        );
        assert_eq!(
            resolve_text("file:///tmp/report.pdf", &files),
            Some(Destination::File("/tmp/report.pdf".into()))
        );
        assert_eq!(
            resolve_text("FILE:///tmp/report.pdf", &files),
            Some(Destination::File("/tmp/report.pdf".into()))
        );
        assert_eq!(resolve_text("file:///tmp/missing.pdf", &files), None);
        assert!(matches!(
            resolve_text("/tmp/missing.pdf", &files),
            Some(Destination::Search(_))
        ));
        let agent = resolve(
            "/tmp/report.pdf",
            SearchEngine::Google,
            false,
            Path::new("/Users/person"),
            |_| true,
        );
        assert_eq!(agent, None);
    }

    #[cfg(windows)]
    #[test]
    fn typed_drive_paths_open_existing_files_on_windows() {
        let files = [r"C:\Users\person\site\index.html"];
        assert_eq!(
            resolve_text(r"C:\Users\person\site\index.html", &files),
            Some(Destination::File(r"C:\Users\person\site\index.html".into()))
        );
        assert_eq!(
            resolve_text(r"~\site\index.html", &files),
            Some(Destination::File(r"C:\Users\person\site\index.html".into()))
        );
        assert_eq!(
            resolve_text("file:///C:/Users/person/site/index.html", &files),
            Some(Destination::File(r"C:\Users\person\site\index.html".into()))
        );
    }

    #[test]
    fn file_pages_may_load_only_their_own_folder() {
        let root = if cfg!(windows) {
            PathBuf::from(r"C:\site")
        } else {
            PathBuf::from("/site")
        };
        let inside = Url::from_file_path(root.join("pages").join("a.html")).unwrap();
        let sibling =
            Url::from_file_path(root.with_file_name("site-other").join("a.html")).unwrap();
        let parent = Url::from_file_path(root.with_file_name("secret.txt")).unwrap();
        assert!(file_navigation_allowed(inside.as_str(), &root));
        assert!(file_navigation_allowed(&format!("{inside}#part"), &root));
        assert!(!file_navigation_allowed(sibling.as_str(), &root));
        assert!(!file_navigation_allowed(parent.as_str(), &root));
        assert!(!file_navigation_allowed(
            &format!("{}/../secret.txt", Url::from_file_path(&root).unwrap()),
            &root
        ));
        assert!(!file_navigation_allowed("https://example.com/", &root));
        assert!(!file_navigation_allowed(
            "file://server/share/a.html",
            &root
        ));
        assert!(!file_navigation_allowed(inside.as_str(), Path::new("")));
        assert_eq!(file_root(&root.join("a.html")), Some(root));
    }

    fn day(days: f64) -> f64 {
        1_000_000_000. - days * 86_400.
    }

    fn index() -> CompletionIndex {
        CompletionIndex::new(
            vec![("https://docs.rs/".into(), "Docs.rs".into())],
            vec![
                HistoryItem {
                    url: "https://github.com/apple/swift".into(),
                    title: "Swift".into(),
                    visit_count: 3,
                    last_visit: day(1.),
                },
                HistoryItem {
                    url: "https://www.github.com/".into(),
                    title: "GitHub".into(),
                    visit_count: 40,
                    last_visit: day(2.),
                },
                HistoryItem {
                    url: "http://gitlab.example/".into(),
                    title: "Old".into(),
                    visit_count: 50,
                    last_visit: day(700.),
                },
            ],
        )
    }

    #[test]
    fn suggestions_put_bookmarks_first_then_frequent_recent_history() {
        let now = day(0.);
        assert_eq!(
            index().suggestions("git", 8, now),
            vec![
                "https://www.github.com/",
                "https://github.com/apple/swift",
                "http://gitlab.example/"
            ]
        );
        assert_eq!(
            index().suggestions("docs", 8, now),
            vec!["https://docs.rs/"]
        );
        assert_eq!(
            index().suggestions("swift", 8, now),
            vec!["https://github.com/apple/swift"]
        );
        assert!(index().suggestions("  ", 8, now).is_empty());
        assert_eq!(index().suggestions("git", 1, now).len(), 1);
    }

    #[test]
    fn inline_completion_keeps_what_was_typed_and_adds_the_rest() {
        let now = day(0.);
        assert_eq!(
            index().inline_completion("git", now).as_deref(),
            Some("github.com/")
        );
        assert_eq!(
            index().inline_completion("GitHub.com/a", now).as_deref(),
            Some("GitHub.com/apple/swift")
        );
        assert_eq!(
            index().inline_completion("https://www.g", now).as_deref(),
            Some("https://www.github.com/")
        );
        assert_eq!(
            index().inline_completion("do", now).as_deref(),
            Some("docs.rs/")
        );
        assert_eq!(index().inline_completion("g", now), None);
        assert_eq!(index().inline_completion("git hub", now), None);
        assert_eq!(
            index().inline_completion("github.com/", now),
            Some("github.com/apple/swift".into())
        );
        assert_eq!(index().inline_completion("nothing", now), None);
        assert_eq!(
            CompletionIndex::default().inline_completion("git", now),
            None
        );
    }

    #[test]
    fn saved_rust_libraries_feed_completion() {
        let mut bookmarks = crate::browser_bookmarks::Library::default();
        bookmarks
            .bookmarks
            .push(crate::browser_bookmarks::Bookmark {
                id: uuid::Uuid::new_v4(),
                url: "https://example.com/".into(),
                title: "Example".into(),
                folder: None,
            });
        let profile = uuid::Uuid::new_v4();
        let mut history = crate::browser_history::Library::empty(profile);
        history.history.push(crate::browser_history::Entry {
            id: uuid::Uuid::new_v4(),
            url: "https://rust-lang.org/".into(),
            record: serde_json::json!({"url":"https://rust-lang.org/","title":"Rust","visitCount":2,"lastVisit":0}),
            extra: Default::default(),
        });
        let index = CompletionIndex::from_libraries(Some(&bookmarks), Some(&history));
        assert!(!index.is_empty());
        assert_eq!(
            index.inline_completion("ex", 0.).as_deref(),
            Some("example.com/")
        );
        assert_eq!(
            index.inline_completion("ru", 0.).as_deref(),
            Some("rust-lang.org/")
        );
        assert!(CompletionIndex::from_libraries(None, None).is_empty());
    }
}
