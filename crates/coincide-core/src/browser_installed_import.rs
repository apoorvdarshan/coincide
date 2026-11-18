//! Read only bookmarked URLs and visit records from a selected macOS browser
//! profile. The import UI reviews a bounded snapshot before saving it.
use crate::{browser_bookmarks, browser_history};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs::{self, File},
    io::Read,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

const MAX_SOURCE: u64 = 16 * 1024 * 1024;
const MAX_ROWS: usize = 5_000;
const SWIFT_EPOCH: f64 = 978_307_200.0;
const CHROMIUM_EPOCH: f64 = 11_644_473_600.0;

#[derive(Clone, Copy, Debug)]
enum Format {
    Chromium,
    Firefox,
    Safari,
}
impl Format {
    fn file(self, kind: Kind) -> &'static str {
        match (self, kind) {
            (Self::Chromium, Kind::Bookmarks) => "Bookmarks",
            (Self::Chromium, Kind::History) => "History",
            (Self::Firefox, _) => "places.sqlite",
            (Self::Safari, Kind::Bookmarks) => "Bookmarks.plist",
            (Self::Safari, Kind::History) => "History.db",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum Kind {
    Bookmarks,
    History,
}

struct Browser {
    title: &'static str,
    app: &'static str,
    folder: &'static str,
    format: Format,
}

const BROWSERS: &[Browser] = &[
    Browser {
        title: "Chrome",
        app: "Google Chrome.app",
        folder: "Application Support/Google/Chrome",
        format: Format::Chromium,
    },
    Browser {
        title: "Safari",
        app: "Safari.app",
        folder: "Safari",
        format: Format::Safari,
    },
    Browser {
        title: "Edge",
        app: "Microsoft Edge.app",
        folder: "Application Support/Microsoft Edge",
        format: Format::Chromium,
    },
    Browser {
        title: "Brave",
        app: "Brave Browser.app",
        folder: "Application Support/BraveSoftware/Brave-Browser",
        format: Format::Chromium,
    },
    Browser {
        title: "Arc",
        app: "Arc.app",
        folder: "Application Support/Arc/User Data",
        format: Format::Chromium,
    },
    Browser {
        title: "Vivaldi",
        app: "Vivaldi.app",
        folder: "Application Support/Vivaldi",
        format: Format::Chromium,
    },
    Browser {
        title: "Opera",
        app: "Opera.app",
        folder: "Application Support/com.operasoftware.Opera",
        format: Format::Chromium,
    },
    Browser {
        title: "Firefox",
        app: "Firefox.app",
        folder: "Application Support/Firefox/Profiles",
        format: Format::Firefox,
    },
];

#[derive(Clone, Debug)]
pub struct Profile {
    pub browser: &'static str,
    pub label: String,
    pub bookmarks: bool,
    pub history: bool,
    folder: PathBuf,
    format: Format,
}

impl Profile {
    pub fn source_exists(&self, kind: Kind) -> bool {
        match kind {
            Kind::Bookmarks => self.bookmarks,
            Kind::History => self.history,
        }
    }

    fn path(&self, kind: Kind) -> Result<PathBuf> {
        // Ignore redirected profile folders and paths masquerading as metadata.
        ensure!(
            self.folder.canonicalize()? == self.folder,
            "Browser profile moved"
        );
        let path = self.folder.join(self.format.file(kind));
        ensure!(regular(&path), "Browser data is unavailable");
        Ok(path)
    }

    pub fn read(&self, kind: Kind) -> Result<Vec<u8>> {
        let path = self
            .path(kind)
            .context("Cannot read this browser profile")?;
        match kind {
            Kind::Bookmarks => bookmarks(&path, self.format),
            Kind::History => history(&path, self.format),
        }
    }
}

pub fn discover() -> Vec<Profile> {
    crate::cli_session_discovery::home_directory().map_or_else(Vec::new, |home| {
        discover_at(
            &home,
            &[
                Path::new("/Applications"),
                Path::new("/System/Applications"),
            ],
        )
    })
}

fn discover_at(home: &Path, app_dirs: &[&Path]) -> Vec<Profile> {
    let home_apps = home.join("Applications");
    let Ok(library) = home.join("Library").canonicalize() else {
        return Vec::new();
    };
    let mut result = Vec::new();
    for browser in BROWSERS {
        if !app_dirs
            .iter()
            .copied()
            .chain([home_apps.as_path()])
            .any(|root| root.join(browser.app).is_dir())
        {
            continue;
        }
        let root = home.join("Library").join(browser.folder);
        let mut folders = Vec::new();
        match browser.format {
            Format::Safari => folders.push(("Default".to_owned(), root.clone())),
            Format::Chromium | Format::Firefox => {
                if let Ok(entries) = fs::read_dir(&root) {
                    for entry in entries.filter_map(Result::ok).take(256) {
                        let name = entry.file_name().to_string_lossy().into_owned();
                        let candidate = match browser.format {
                            Format::Chromium => {
                                name == "Default"
                                    || name.strip_prefix("Profile ").is_some_and(|n| {
                                        !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())
                                    })
                            }
                            Format::Firefox => entry.file_type().is_ok_and(|kind| kind.is_dir()),
                            Format::Safari => false,
                        };
                        if candidate && !name.chars().any(char::is_control) {
                            folders.push((name, entry.path()));
                        }
                    }
                }
                // Opera and some older Chromium profiles keep their data at the root.
                if matches!(browser.format, Format::Chromium) {
                    folders.push(("Default".to_owned(), root));
                }
            }
        }
        folders.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        for (label, folder) in folders {
            let Ok(canonical) = folder.canonicalize() else {
                continue;
            };
            if !canonical.starts_with(&library)
                || fs::symlink_metadata(&folder).is_ok_and(|meta| meta.is_symlink())
            {
                continue;
            }
            let bookmarks = regular(&canonical.join(browser.format.file(Kind::Bookmarks)));
            let history = regular(&canonical.join(browser.format.file(Kind::History)));
            if bookmarks || history {
                result.push(Profile {
                    browser: browser.title,
                    label,
                    bookmarks,
                    history,
                    folder: canonical,
                    format: browser.format,
                });
            }
        }
    }
    result
}

fn regular(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|meta| meta.is_file())
}

fn metadata_url(raw: &str) -> Option<String> {
    let validated = browser_bookmarks::validate_url(raw).ok()?;
    let url = url::Url::parse(&validated).ok()?;
    let private_parameter = |key: &str| {
        matches!(
            key.to_ascii_lowercase().replace(['_', '-'], "").as_str(),
            "code"
                | "idtoken"
                | "session"
                | "sessionid"
                | "sessiontoken"
                | "oauthtoken"
                | "samlresponse"
                | "assertion"
                | "otp"
                | "signature"
                | "sig"
        )
    };
    if url.query_pairs().any(|(key, _)| private_parameter(&key))
        || url.fragment().is_some_and(|fragment| {
            url::form_urlencoded::parse(fragment.as_bytes()).any(|(key, _)| private_parameter(&key))
        })
    {
        return None;
    }
    Some(validated)
}

fn plain(value: &str, bound: usize) -> String {
    value.chars().filter(|&c| {
        !c.is_control() && !matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
    }).take(bound).collect()
}

struct Rows {
    rows: Vec<Value>,
    urls: HashSet<String>,
    budget: usize,
}
impl Rows {
    fn new() -> Self {
        Self {
            rows: Vec::new(),
            urls: HashSet::new(),
            budget: browser_history::MAX_EXPORT_BYTES - 64,
        }
    }

    fn push(&mut self, url: String, row: Value) -> Result<()> {
        if self.rows.len() >= MAX_ROWS || self.urls.contains(&url) {
            return Ok(());
        }
        let bytes = serde_json::to_vec(&row)?.len() + 1;
        if let Some(remaining) = self.budget.checked_sub(bytes) {
            self.rows.push(row);
            self.urls.insert(url);
            self.budget = remaining;
        }
        Ok(())
    }

    fn bookmark(&mut self, raw: &str, title: &str, folder: &str) -> Result<()> {
        if let Some(url) = metadata_url(raw) {
            self.push(
                url.clone(),
                json!({"url":url, "title":plain(title, 500), "folder":plain(folder, 200)}),
            )?;
        }
        Ok(())
    }
}

fn open_metadata(path: &Path) -> Result<Connection> {
    ensure!(regular(path), "Browser database is unavailable");
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_NOFOLLOW
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .context("Could not open the browser database read-only")?;
    db.busy_timeout(Duration::from_secs(2))?;
    db.pragma_update(None, "trusted_schema", false)?;
    Ok(db)
}

fn history(path: &Path, format: Format) -> Result<Vec<u8>> {
    let sql = match format {
        Format::Chromium => "SELECT url, COALESCE(title,''), visit_count, CAST(last_visit_time AS REAL)
            FROM urls WHERE hidden=0 AND visit_count>0 AND last_visit_time>0 ORDER BY last_visit_time DESC LIMIT ?",
        Format::Firefox => "SELECT url, COALESCE(title,''), visit_count, CAST(last_visit_date AS REAL)
            FROM moz_places WHERE hidden=0 AND visit_count>0 AND last_visit_date>0 ORDER BY last_visit_date DESC LIMIT ?",
        Format::Safari => "SELECT i.url, COALESCE(v.title,''), i.visit_count, CAST(v.visit_time AS REAL)
            FROM history_items i JOIN history_visits v ON v.id=(
                SELECT id FROM history_visits WHERE history_item=i.id ORDER BY visit_time DESC LIMIT 1
            ) WHERE i.visit_count>0 ORDER BY v.visit_time DESC LIMIT ?",
    };
    let db = open_metadata(path)?;
    let mut stmt = db
        .prepare(sql)
        .context("Unsupported browser history format")?;
    let mut query = stmt.query([MAX_ROWS as i64])?;
    let mut output = Rows::new();
    while let Some(row) = query.next()? {
        let url: &str = row.get_ref(0)?.as_str()?;
        let Some(url) = metadata_url(url) else {
            continue;
        };
        let title = plain(row.get_ref(1)?.as_str()?, 500);
        let visits = row.get::<_, i64>(2)?;
        let raw = row.get::<_, f64>(3)?;
        let last_visit = match format {
            Format::Chromium => raw / 1_000_000.0 - CHROMIUM_EPOCH - SWIFT_EPOCH,
            Format::Firefox => raw / 1_000_000.0 - SWIFT_EPOCH,
            Format::Safari => raw,
        };
        let record = json!({"url":url, "title":title, "visitCount":visits, "lastVisit":last_visit});
        if browser_history::record_view(&record).is_ok() {
            output.push(url, record)?;
        }
    }
    ensure!(!output.rows.is_empty(), "No importable visits found");
    serde_json::to_vec(&json!({"history":output.rows})).map_err(Into::into)
}

fn bookmarks(path: &Path, format: Format) -> Result<Vec<u8>> {
    let mut output = Rows::new();
    match format {
        Format::Chromium => {
            let file = open_bookmarks_file(path)?;
            let mut bytes = Vec::new();
            file.take(MAX_SOURCE + 1).read_to_end(&mut bytes)?;
            ensure!(
                bytes.len() as u64 <= MAX_SOURCE,
                "Browser bookmarks file is too large"
            );
            let document: Value =
                serde_json::from_slice(&bytes).context("Unsupported browser bookmarks format")?;
            let roots = document["roots"]
                .as_object()
                .context("Missing browser bookmark folders")?;
            for value in roots.values() {
                chromium_bookmarks(value, "", &mut output, 0)?;
            }
        }
        Format::Firefox => {
            let db = open_metadata(path)?;
            let mut statement = db
                .prepare(
                    "SELECT p.url, COALESCE(b.title,p.title,''), COALESCE(f.title,'')
                FROM moz_bookmarks b JOIN moz_places p ON p.id=b.fk
                LEFT JOIN moz_bookmarks f ON f.id=b.parent AND f.type=2
                WHERE b.type=1 ORDER BY b.parent,b.position LIMIT ?",
                )
                .context("Unsupported Firefox bookmarks format")?;
            let mut records = statement.query([MAX_ROWS as i64])?;
            while let Some(row) = records.next()? {
                output.bookmark(
                    row.get_ref(0)?.as_str()?,
                    row.get_ref(1)?.as_str()?,
                    row.get_ref(2)?.as_str()?,
                )?;
            }
        }
        Format::Safari => {
            let bytes = plist_xml(path)?;
            let xml = std::str::from_utf8(&bytes)?.replace(
                r#"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
                "",
            );
            let xml =
                roxmltree::Document::parse(&xml).context("Unsupported Safari bookmarks format")?;
            let root = xml
                .root_element()
                .first_element_child()
                .context("Missing Safari bookmark folders")?;
            safari_bookmarks(root, "", &mut output, 0)?;
        }
    }
    ensure!(!output.rows.is_empty(), "No importable bookmarks found");
    serde_json::to_vec(&json!({"bookmarks":output.rows})).map_err(Into::into)
}

fn chromium_bookmarks(node: &Value, folder: &str, rows: &mut Rows, depth: usize) -> Result<()> {
    if depth >= 64 || rows.rows.len() >= MAX_ROWS {
        return Ok(());
    }
    match node["type"].as_str() {
        Some("url") => {
            if let Some(url) = node["url"].as_str() {
                rows.bookmark(url, node["name"].as_str().unwrap_or_default(), folder)?;
            }
        }
        Some("folder") => {
            if let Some(children) = node["children"].as_array() {
                let folder = join_folder(folder, node["name"].as_str().unwrap_or_default());
                for child in children {
                    chromium_bookmarks(child, &folder, rows, depth + 1)?;
                }
            }
        }
        _ => {}
    }
    Ok(())
}

fn join_folder(parent: &str, name: &str) -> String {
    match (parent.is_empty(), name.is_empty()) {
        (true, _) => plain(name, 200),
        (_, true) => parent.to_owned(),
        _ => plain(&format!("{parent} / {}", plain(name, 200)), 200),
    }
}

fn open_bookmarks_file(path: &Path) -> Result<File> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .context("Could not open browser bookmarks")?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.len() <= MAX_SOURCE,
        "Invalid or oversized browser bookmarks file"
    );
    Ok(file)
}

fn plist_xml(path: &Path) -> Result<Vec<u8>> {
    let file = open_bookmarks_file(path)?;
    let mut child = Command::new("/usr/bin/plutil")
        .args(["-convert", "xml1", "-o", "-", "--", "-"])
        .stdin(file)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("Could not read Safari bookmarks")?;
    let mut bytes = Vec::new();
    let result = child
        .stdout
        .take()
        .context("Safari bookmarks reader did not start")?
        .take(MAX_SOURCE + 1)
        .read_to_end(&mut bytes);
    if result.is_err() || bytes.len() as u64 > MAX_SOURCE {
        let _ = child.kill();
    }
    let status = child.wait()?;
    ensure!(
        result.is_ok() && status.success() && bytes.len() as u64 <= MAX_SOURCE,
        "Could not read Safari bookmarks"
    );
    Ok(bytes)
}

fn plist_key<'a, 'input>(
    node: roxmltree::Node<'a, 'input>,
    key: &str,
) -> Option<roxmltree::Node<'a, 'input>> {
    node.children()
        .find(|child| child.has_tag_name("key") && child.text() == Some(key))?
        .next_sibling_element()
}

fn safari_bookmarks(
    node: roxmltree::Node<'_, '_>,
    folder: &str,
    rows: &mut Rows,
    depth: usize,
) -> Result<()> {
    if depth >= 64 || rows.rows.len() >= MAX_ROWS {
        return Ok(());
    }
    let title = plist_key(node, "Title")
        .and_then(|value| value.text())
        .unwrap_or_default();
    if title == "com.apple.ReadingList" {
        return Ok(());
    }
    if let Some(url) = plist_key(node, "URLString").and_then(|value| value.text()) {
        let title = plist_key(node, "URIDictionary")
            .and_then(|uri| plist_key(uri, "title"))
            .and_then(|value| value.text())
            .unwrap_or(title);
        rows.bookmark(url, title, folder)?;
    } else if let Some(children) = plist_key(node, "Children") {
        let folder = join_folder(folder, title);
        for child in children
            .children()
            .filter(|child| child.has_tag_name("dict"))
        {
            safari_bookmarks(child, &folder, rows, depth + 1)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(browser: &Browser, root: &Path) -> Profile {
        Profile {
            browser: browser.title,
            label: "Test profile".into(),
            bookmarks: true,
            history: true,
            folder: root.canonicalize().unwrap(),
            format: browser.format,
        }
    }

    #[test]
    fn discovers_the_eight_installed_sources_and_ignores_links_and_uninstalled_browsers() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let apps = home.join("Applications");
        let library = home.join("Library");
        for browser in BROWSERS {
            fs::create_dir_all(apps.join(browser.app)).unwrap();
            let mut directory = library.join(browser.folder);
            directory = match browser.format {
                Format::Chromium => directory.join("Default"),
                Format::Firefox => directory.join("synthetic.default"),
                Format::Safari => directory,
            };
            fs::create_dir_all(&directory).unwrap();
            fs::write(
                directory.join(browser.format.file(Kind::Bookmarks)),
                b"placeholder",
            )
            .unwrap();
        }
        let profiles = discover_at(home, &[]);
        assert_eq!(profiles.len(), 8);
        let safari = profiles
            .iter()
            .find(|profile| profile.browser == "Safari")
            .unwrap();
        assert!(!safari.source_exists(Kind::History));
        fs::remove_dir(apps.join("Arc.app")).unwrap();
        let firefox = library.join("Application Support/Firefox/Profiles");
        std::os::unix::fs::symlink(
            firefox.join("synthetic.default"),
            firefox.join("redirected"),
        )
        .unwrap();
        let profiles = discover_at(home, &[]);
        assert_eq!(profiles.len(), 7);
        assert!(
            profiles
                .iter()
                .all(|profile| profile.label != "redirected" && profile.browser != "Arc")
        );
    }

    #[test]
    fn chromium_bookmarks_review_is_bounded_deduplicated_and_excludes_private_urls() {
        let temp = tempfile::tempdir().unwrap();
        let browser = profile(&BROWSERS[0], temp.path());
        let source = br#"{"roots":{"bar":{"type":"folder","name":"Toolbar","children":[
            {"type":"url","name":"Search","url":"https://example.test/?q=rust"},
            {"type":"url","name":"Duplicate","url":"https://example.test/?q=rust"},
            {"type":"url","name":"Discard","url":"https://example.test/login?code=synthetic"},
            {"type":"url","name":"Discard","url":"javascript:void(0)"}
        ]}}}"#;
        let path = temp.path().join("Bookmarks");
        fs::write(&path, source).unwrap();
        let export = browser.read(Kind::Bookmarks).unwrap();
        let plan = browser_bookmarks::preview(&export).unwrap();
        assert_eq!(plan.bookmarks.len(), 1);
        assert_eq!(plan.bookmarks[0].url, "https://example.test/?q=rust");
        assert_eq!(plan.bookmarks[0].folder.as_deref(), Some("Toolbar"));
        assert_eq!(fs::read(&path).unwrap(), source);

        fs::remove_file(&path).unwrap();
        let target = temp.path().join("other");
        fs::write(&target, source).unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(browser.read(Kind::Bookmarks).is_err());
        assert_eq!(fs::read(target).unwrap(), source);
    }

    #[test]
    fn history_has_correct_dates_for_each_engine_and_does_not_modify_source() {
        let cases = [
            (&BROWSERS[0], "CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,hidden INTEGER);
                INSERT INTO urls VALUES('https://example.test/','Example',3,12622780800000000,0);
                INSERT INTO urls VALUES('https://example.test/secret?session=synthetic','Skip',1,12622780900000000,0);"),
            (&BROWSERS[7], "CREATE TABLE moz_places(id INTEGER,url TEXT,title TEXT,visit_count INTEGER,last_visit_date INTEGER,hidden INTEGER);
                INSERT INTO moz_places VALUES(1,'https://example.test/','Example',3,978307200000000,0);
                CREATE TABLE moz_bookmarks(id INTEGER,fk INTEGER,title TEXT,type INTEGER,parent INTEGER,position INTEGER);
                INSERT INTO moz_bookmarks VALUES(3,1,'Bookmark',1,4,0),(4,NULL,'Toolbar',2,0,0);"),
            (&BROWSERS[1], "CREATE TABLE history_items(id INTEGER,url TEXT,visit_count INTEGER);
                CREATE TABLE history_visits(id INTEGER,history_item INTEGER,title TEXT,visit_time REAL);
                INSERT INTO history_items VALUES(1,'https://example.test/',3);
                INSERT INTO history_visits VALUES(1,1,'Old',-1800),(2,1,'Example',0);"),
        ];
        for (definition, sql) in cases {
            let temp = tempfile::tempdir().unwrap();
            let browser = profile(definition, temp.path());
            let path = temp.path().join(definition.format.file(Kind::History));
            let db = Connection::open(&path).unwrap();
            db.execute_batch(sql).unwrap();
            drop(db);
            let before = fs::read(&path).unwrap();
            let result = browser_history::preview(&browser.read(Kind::History).unwrap()).unwrap();
            assert_eq!(result.history.len(), 1, "{}", definition.title);
            let record = browser_history::record_view(&result.history[0]).unwrap();
            assert_eq!(record.url, "https://example.test/");
            assert_eq!(record.title, "Example");
            assert_eq!(record.visit_count, 3);
            assert_eq!(record.last_visit, "2001-01-01 00:00 UTC");
            if matches!(browser.format, Format::Firefox) {
                let plan =
                    browser_bookmarks::preview(&browser.read(Kind::Bookmarks).unwrap()).unwrap();
                assert_eq!(plan.bookmarks[0].title, "Bookmark");
                assert_eq!(plan.bookmarks[0].folder.as_deref(), Some("Toolbar"));
            }
            assert_eq!(fs::read(path).unwrap(), before);
        }
    }

    #[test]
    fn safari_reads_binary_bookmarks_and_skips_the_reading_list() {
        let temp = tempfile::tempdir().unwrap();
        let browser = profile(&BROWSERS[1], temp.path());
        let path = temp.path().join("Bookmarks.plist");
        fs::write(
            &path,
            br#"<?xml version="1.0"?>
            <plist version="1.0"><dict><key>Children</key><array>
            <dict><key>Title</key><string>Toolbar</string><key>Children</key><array>
              <dict><key>URLString</key><string>https://example.test/</string>
              <key>URIDictionary</key><dict><key>title</key><string>Saved</string></dict></dict>
            </array></dict>
            <dict><key>Title</key><string>com.apple.ReadingList</string><key>Children</key><array>
              <dict><key>URLString</key><string>https://reading.example.test/</string></dict>
            </array></dict>
            </array></dict></plist>"#,
        )
        .unwrap();
        assert!(
            Command::new("/usr/bin/plutil")
                .args(["-convert", "binary1"])
                .arg(&path)
                .status()
                .unwrap()
                .success()
        );
        let before = fs::read(&path).unwrap();
        assert!(before.starts_with(b"bplist"));
        let plan = browser_bookmarks::preview(&browser.read(Kind::Bookmarks).unwrap()).unwrap();
        assert_eq!(plan.bookmarks.len(), 1);
        assert_eq!(plan.bookmarks[0].title, "Saved");
        assert_eq!(plan.bookmarks[0].folder.as_deref(), Some("Toolbar"));
        assert_eq!(fs::read(path).unwrap(), before);
    }
}
