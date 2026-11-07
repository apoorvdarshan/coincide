//! The command palette's folder searches, as Swift's `ProjectSearch`,
//! `TextSearch` and `PaletteCatalog.folderItems`: Go to File and Search in
//! Project over a thread's folder, and the folders a "/" or "~" query lists to
//! add as projects. Searches only read names and lines; nothing is written.
use anyhow::{Context, Result, ensure};
use std::{
    cmp::Ordering,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering as AtomicOrdering},
    },
    time::{Duration, Instant},
};

/// Swift `ProjectSearch.goToFileMenu` asks the file index for this many.
pub const FILE_LIMIT: usize = 60;
/// Swift `TextSearch.run`'s default and per-file limits, and its output cap.
pub const TEXT_LIMIT: usize = 300;
pub const LINES_PER_FILE: usize = 6;
const OUTPUT_LIMIT: usize = 1_000_000;
const FOLDER_LIMIT: usize = 40;
const LINE_CHARS: usize = 160;

/// One admitted search's cancellation and deadline, shared by its owned worker.
#[derive(Clone)]
pub struct SearchControl {
    cancelled: Arc<AtomicBool>,
    deadline: Instant,
    cleanup_uncertain: Arc<AtomicBool>,
}
impl Default for SearchControl {
    fn default() -> Self {
        Self::with_timeout(Duration::from_secs(10))
    }
}
impl SearchControl {
    pub fn with_timeout(timeout: Duration) -> Self {
        Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            deadline: Instant::now() + timeout,
            cleanup_uncertain: Arc::new(AtomicBool::new(false)),
        }
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, AtomicOrdering::Release);
    }
    pub fn cancelled(&self) -> bool {
        self.cancelled.load(AtomicOrdering::Acquire)
    }
    pub fn allowed(&self) -> bool {
        !self.cancelled() && Instant::now() < self.deadline
    }
    pub fn cleanup_confirmed(&self) -> bool {
        !self.cleanup_uncertain.load(AtomicOrdering::Acquire)
    }
    fn check(&self) -> Result<()> {
        ensure!(self.allowed(), "Project search cancelled or timed out");
        Ok(())
    }
}
const VISIT_LIMIT: usize = 20_000;
const DEPTH_LIMIT: usize = 64;
const SCAN_BYTES: usize = 16 * 1024 * 1024;

/// A file the index found, relative to the searched folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileHit {
    pub path: String,
    pub name: String,
    /// The folder it is in, relative to the root; empty at the top.
    pub parent: String,
}

/// Go to File: the project's files whose names best match `query`, folders left
/// out, through the composer's file index (`git ls-files`).
pub fn files(root: &Path, query: &str) -> Result<Vec<FileHit>> {
    files_controlled(root, query, &SearchControl::default())
}
pub fn files_controlled(root: &Path, query: &str, control: &SearchControl) -> Result<Vec<FileHit>> {
    control.check()?;
    ensure!(
        query.len() <= 256 && !query.chars().any(char::is_control),
        "Search must be at most 256 bytes without control characters"
    );
    let listed = search_paths(root, query, control)?;
    control.check()?;
    let paths = listed["files"]
        .as_array()
        .context("File listing is unavailable")?;
    Ok(paths
        .iter()
        .filter_map(|path| path.as_str())
        .filter(|path| std::fs::symlink_metadata(root.join(path)).is_ok_and(|meta| !meta.is_dir()))
        .map(|path| {
            let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
            FileHit {
                path: path.into(),
                name: name.into(),
                parent: parent.into(),
            }
        })
        .collect())
}

/// A line of a folder's file that contains the searched text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextMatch {
    pub path: String,
    pub line: usize,
    pub text: String,
}

/// `path:line:text` lines, as ripgrep and grep print them.
pub fn parse(output: &str) -> Vec<TextMatch> {
    output
        .lines()
        .filter_map(|raw| {
            let mut parts = raw.splitn(3, ':');
            let (path, line, text) = (parts.next()?, parts.next()?, parts.next()?);
            let line = line.parse().ok()?;
            // ripgrep on Windows prints `.\src\a.rs`; paths are shown with "/".
            let path = if cfg!(windows) {
                path.replace('\\', "/")
            } else {
                path.to_owned()
            };
            let path = path.strip_prefix("./").unwrap_or(&path);
            Some(TextMatch {
                path: path.into(),
                line,
                text: text
                    .trim_matches([' ', '\t'])
                    .chars()
                    .take(LINE_CHARS)
                    .collect(),
            })
        })
        .collect()
}

fn ripgrep() -> Option<PathBuf> {
    let name = if cfg!(windows) { "rg.exe" } else { "rg" };
    let fixed = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
        .into_iter()
        .map(PathBuf::from);
    let path: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| {
            std::env::split_paths(&path)
                .map(|dir| dir.join(name))
                .collect()
        })
        .unwrap_or_default();
    fixed.chain(path).find(|path| path.is_file())
}

/// Search in Project: the folder's lines containing `query`, with ripgrep when
/// it is installed and a built-in search like Swift's grep fallback otherwise.
/// Queries under two characters find nothing, as in Swift.
pub fn text(root: &Path, query: &str) -> Result<Vec<TextMatch>> {
    text_controlled(root, query, &SearchControl::default())
}
pub fn text_controlled(
    root: &Path,
    query: &str,
    control: &SearchControl,
) -> Result<Vec<TextMatch>> {
    control.check()?;
    ensure!(
        query.len() <= 256 && !query.contains(['\0', '\n', '\r']),
        "Search must be at most 256 bytes on one line"
    );
    if query.trim_matches(' ').chars().count() < 2 {
        return Ok(Vec::new());
    }
    ensure!(root.is_dir(), "The project folder is unavailable");
    let mut matches = match ripgrep() {
        Some(rg) => run_ripgrep(&rg, root, query, control)?,
        None => walk_controlled(root, query, control),
    };
    matches.truncate(TEXT_LIMIT);
    Ok(matches)
}

fn run_ripgrep(
    rg: &Path,
    root: &Path,
    query: &str,
    control: &SearchControl,
) -> Result<Vec<TextMatch>> {
    let mut command = Command::new(rg);
    command
        .args([
            "--no-config",
            "--line-number",
            "--no-heading",
            "--fixed-strings",
            "--smart-case",
            "--max-count",
            "6",
            "--max-filesize",
            "1M",
            "--color",
            "never",
            "--",
            query,
            ".",
        ])
        .current_dir(root);
    let output = capture_search(&mut command, control, OUTPUT_LIMIT)?;
    Ok(parse(&String::from_utf8_lossy(&output)))
}
fn search_paths(root: &Path, query: &str, control: &SearchControl) -> Result<serde_json::Value> {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.to_string_lossy().starts_with("GIT_") {
            command.env_remove(name);
        }
    }
    let hooks = crate::workspace::external_git_path(&std::env::current_exe()?)?;
    command
        .args(["--no-pager", "--literal-pathspecs", "-c"])
        .arg(format!("core.hooksPath={}", hooks.display()))
        .args([
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "protocol.allow=never",
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ])
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .current_dir(root);
    let output = process::capture_checked(&mut command, control, 3 * 1024 * 1024, true)?;
    crate::workspace::composer_path_results(&output, query, FILE_LIMIT)
}

/// grep -rnIF --exclude-dir=.git --exclude-dir=node_modules -m 6: text files
/// only, case-sensitive, six lines a file, in name order.
#[cfg(test)]
fn walk(root: &Path, query: &str) -> Vec<TextMatch> {
    walk_controlled(root, query, &SearchControl::default())
}
fn walk_controlled(root: &Path, query: &str, control: &SearchControl) -> Vec<TextMatch> {
    let mut matches = Vec::new();
    let mut folders = vec![PathBuf::new()];
    let mut visited = 0;
    let mut bytes_left = SCAN_BYTES;
    while let Some(relative) = folders.pop() {
        if !control.allowed() || visited >= VISIT_LIMIT || bytes_left == 0 {
            break;
        }
        let Ok(entries) = std::fs::read_dir(root.join(&relative)) else {
            continue;
        };
        let mut entries = entries
            .take(VISIT_LIMIT.saturating_sub(visited))
            .take_while(|_| control.allowed())
            .inspect(|_| visited += 1)
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| Some((entry.file_name().into_string().ok()?, entry)))
            .collect::<Vec<_>>();
        entries.sort_by(|left, right| left.0.cmp(&right.0));
        let mut subfolders = Vec::new();
        for (name, entry) in entries {
            if !control.allowed() || bytes_left == 0 {
                return matches;
            }
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let path = relative.join(&name);
            if kind.is_dir() {
                if name != ".git"
                    && name != "node_modules"
                    && path.components().count() <= DEPTH_LIMIT
                {
                    subfolders.push(path);
                }
            } else if kind.is_file() {
                search_file(root, &path, query, &mut matches, control, &mut bytes_left);
                if matches.len() >= TEXT_LIMIT {
                    return matches;
                }
            }
        }
        folders.extend(subfolders.into_iter().rev());
    }
    matches
}

fn search_file(
    root: &Path,
    path: &Path,
    query: &str,
    matches: &mut Vec<TextMatch>,
    control: &SearchControl,
    bytes_left: &mut usize,
) {
    if !control.allowed() {
        return;
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let Ok(file) = options.open(root.join(path)) else {
        return;
    };
    if file.metadata().map_or(true, |meta| {
        !meta.is_file() || meta.file_type().is_symlink() || meta.len() > OUTPUT_LIMIT as u64
    }) {
        return;
    }
    let allowance = (*bytes_left).min(OUTPUT_LIMIT);
    let mut reader = BufReader::new(file.take(allowance as u64));
    // Binary files (a NUL early on) are skipped, as grep -I does.
    if reader.fill_buf().is_ok_and(|head| head.contains(&0)) {
        return;
    }
    let display = path
        .components()
        .map(|part| part.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/");
    let mut found = 0;
    for (index, line) in reader.split(b'\n').enumerate() {
        if !control.allowed() || *bytes_left == 0 {
            return;
        }
        let Ok(line) = line else {
            return;
        };
        *bytes_left = bytes_left.saturating_sub(line.len() + 1);
        let line = String::from_utf8_lossy(&line);
        if line.contains(query) {
            matches.push(TextMatch {
                path: display.clone(),
                line: index + 1,
                text: line
                    .trim_end_matches('\r')
                    .trim_matches([' ', '\t'])
                    .chars()
                    .take(LINE_CHARS)
                    .collect(),
            });
            found += 1;
            if found == LINES_PER_FILE || matches.len() >= TEXT_LIMIT {
                return;
            }
        }
    }
}

/// Search in Project's lists: up to 40 files in path order, six lines each.
pub fn group_by_file(matches: Vec<TextMatch>) -> Vec<(String, Vec<TextMatch>)> {
    let mut groups: Vec<(String, Vec<TextMatch>)> = Vec::new();
    for found in matches {
        match groups.iter_mut().find(|(path, _)| *path == found.path) {
            Some((_, lines)) => lines.push(found),
            None => groups.push((found.path.clone(), vec![found])),
        }
    }
    groups.sort_by(|left, right| left.0.cmp(&right.0));
    groups.truncate(FOLDER_LIMIT);
    for (_, lines) in &mut groups {
        lines.truncate(LINES_PER_FILE);
    }
    groups
}

/// T3's add-project browsing: a query starting with "/" or "~" lists folders.
pub fn is_path_query(query: &str) -> bool {
    query.starts_with('/') || query.starts_with('~')
}

/// A folder a path query offers to add as a project.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FolderHit {
    pub path: PathBuf,
    pub title: String,
    /// The path with `~` for the home folder.
    pub subtitle: String,
    /// What Tab puts in the search field to browse into it.
    pub completion: String,
}

fn expand(query: &str, home: &Path) -> PathBuf {
    let path = match query.strip_prefix('~') {
        Some("") => home.to_owned(),
        Some(rest) if rest.starts_with('/') => home.join(rest.trim_start_matches('/')),
        _ => PathBuf::from(query),
    };
    standardized(&path)
}

/// Without a trailing separator or "." parts, as Foundation's file URLs.
fn standardized(path: &Path) -> PathBuf {
    path.components()
        .filter(|part| !matches!(part, std::path::Component::CurDir))
        .collect()
}

/// The path with `~` for the home folder, as Swift's `Formatting.abbreviatedPath`.
pub fn abbreviated(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.to_string_lossy()),
        Err(_) => path.to_string_lossy().into_owned(),
    }
}

/// Finder's name order: case-insensitive, with digit runs compared as numbers.
fn natural(left: &str, right: &str) -> Ordering {
    let (mut a, mut b) = (left.chars().peekable(), right.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return left.cmp(right),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let number = |chars: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut digits = String::new();
                    while let Some(c) = chars.peek().copied().filter(char::is_ascii_digit) {
                        digits.push(c);
                        chars.next();
                    }
                    digits.trim_start_matches('0').to_owned()
                };
                let (x, y) = (number(&mut a), number(&mut b));
                let order = x.len().cmp(&y.len()).then_with(|| x.cmp(&y));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

/// The folders a path query lists: the folder itself first when it exists, as
/// the project to add, then up to 40 subfolders whose names start with what
/// follows the last "/". Hidden folders only when that starts with ".".
pub fn folders(query: &str, home: &Path) -> Vec<FolderHit> {
    folders_controlled(query, home, &SearchControl::default())
}
pub fn folders_controlled(query: &str, home: &Path, control: &SearchControl) -> Vec<FolderHit> {
    if !control.allowed() {
        return Vec::new();
    }
    let expanded = expand(query, home);
    let tilde = query.starts_with('~');
    let hit = |path: PathBuf, title: String| {
        let shown = if tilde {
            abbreviated(&path, home)
        } else {
            path.to_string_lossy().into_owned()
        };
        FolderHit {
            subtitle: abbreviated(&path, home),
            completion: if shown.ends_with('/') {
                shown
            } else {
                format!("{shown}/")
            },
            title,
            path,
        }
    };
    let mut items = Vec::new();
    if expanded.is_dir() {
        let name = expanded
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| expanded.to_string_lossy().into_owned());
        items.push(hit(expanded.clone(), format!("Add “{name}” as a Project")));
    }
    let (parent, prefix) = if query.ends_with('/') {
        (expanded.clone(), String::new())
    } else {
        (
            expanded.parent().map(Path::to_owned).unwrap_or_default(),
            expanded
                .file_name()
                .map(|name| name.to_string_lossy().to_lowercase())
                .unwrap_or_default(),
        )
    };
    let mut names = std::fs::read_dir(&parent)
        .map(|entries| {
            entries
                .take(VISIT_LIMIT)
                .take_while(|_| control.allowed())
                .filter_map(|entry| entry.ok())
                .filter_map(|entry| entry.file_name().into_string().ok())
                .filter(|name| {
                    (!name.starts_with('.') || prefix.starts_with('.'))
                        && name.to_lowercase().starts_with(&prefix)
                        && parent.join(name).is_dir()
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    names.sort_by(|left, right| natural(left, right));
    for name in names.into_iter().take(FOLDER_LIMIT) {
        let path = parent.join(&name);
        if path == expanded {
            continue;
        }
        items.push(hit(path, name));
    }
    items
}

/// Xcode opens a workspace, project or package better than a bare folder.
pub fn xcode_document(folder: &Path) -> PathBuf {
    let mut names = std::fs::read_dir(folder)
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .filter_map(|entry| entry.file_name().into_string().ok())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    names.sort();
    names
        .iter()
        .find(|name| name.ends_with(".xcworkspace"))
        .or_else(|| names.iter().find(|name| name.ends_with(".xcodeproj")))
        .or_else(|| names.iter().find(|name| *name == "Package.swift"))
        .map(|name| folder.join(name))
        .unwrap_or_else(|| folder.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("coincide-palette-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn folder(&self, name: &str) {
            std::fs::create_dir_all(self.0.join(name)).unwrap();
        }
        fn file(&self, name: &str, text: &str) {
            if let Some(parent) = self.0.join(name).parent() {
                std::fs::create_dir_all(parent).unwrap();
            }
            std::fs::write(self.0.join(name), text).unwrap();
        }
        fn path(&self) -> String {
            self.0.to_string_lossy().into_owned()
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn go_to_file_lists_matching_files_without_their_folders() {
        let scratch = Scratch::new();
        scratch.file("src/main.rs", "fn main() {}\n");
        scratch.file("src/maintenance/notes.md", "");
        scratch.file("README.md", "");
        let git = |args: &[&str]| {
            let status = Command::new("git")
                .args(args)
                .current_dir(&scratch.0)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .unwrap();
            assert!(status.success(), "git {args:?}");
        };
        git(&["init", "-q"]);
        git(&["add", "-A"]);
        let hits = files(&scratch.0, "main").unwrap();
        assert_eq!(
            hits.first(),
            Some(&FileHit {
                path: "src/main.rs".into(),
                name: "main.rs".into(),
                parent: "src".into(),
            })
        );
        assert!(hits.iter().all(|hit| hit.path != "src/maintenance"));
        assert!(
            files(&scratch.0, "")
                .unwrap()
                .iter()
                .any(|hit| hit.path == "README.md" && hit.parent.is_empty())
        );
        assert!(files(&scratch.0, "a\u{7}").is_err());
    }

    #[test]
    fn slash_or_tilde_starts_a_path_query() {
        assert!(is_path_query("/Users"));
        assert!(is_path_query("~/code"));
        assert!(!is_path_query("code"));
        assert!(!is_path_query(""));
    }

    #[test]
    fn a_folder_path_lists_its_matching_subfolders() {
        let scratch = Scratch::new();
        scratch.folder("Alpha");
        scratch.folder("alpine");
        scratch.folder("beta");
        scratch.folder(".alcove");
        scratch.file("alfa.txt", "");
        let home = Path::new("/nonexistent-home");
        let prefixed = folders(&format!("{}/al", scratch.path()), home);
        assert_eq!(
            prefixed
                .iter()
                .map(|hit| hit.title.as_str())
                .collect::<Vec<_>>(),
            ["Alpha", "alpine"]
        );
        assert_eq!(
            prefixed[0].completion,
            format!("{}/", scratch.0.join("Alpha").to_string_lossy())
        );
        assert_eq!(prefixed[0].path, scratch.0.join("Alpha"));
        // Hidden folders only when asked for.
        assert_eq!(
            folders(&format!("{}/.a", scratch.path()), home)
                .iter()
                .map(|hit| hit.title.as_str())
                .collect::<Vec<_>>(),
            [".alcove"]
        );
        assert!(folders(&format!("{}/zzz", scratch.path()), home).is_empty());
    }

    #[test]
    fn an_existing_folder_is_offered_as_a_project_first() {
        let scratch = Scratch::new();
        scratch.folder("one");
        scratch.folder("two");
        let home = Path::new("/nonexistent-home");
        let name = scratch
            .0
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let items = folders(&format!("{}/", scratch.path()), home);
        assert_eq!(
            items
                .iter()
                .map(|hit| hit.title.clone())
                .collect::<Vec<_>>(),
            [
                format!("Add “{name}” as a Project"),
                "one".into(),
                "two".into()
            ]
        );
        assert_eq!(items[0].completion, format!("{}/", scratch.path()));
        assert_eq!(items[0].path, scratch.0);
        // Typing a folder's whole name offers it once, as the project to add.
        let exact = folders(&format!("{}/one", scratch.path()), home);
        assert_eq!(
            exact
                .iter()
                .map(|hit| hit.title.as_str())
                .collect::<Vec<_>>(),
            ["Add “one” as a Project"]
        );
    }

    #[test]
    fn home_folder_paths_keep_their_tilde_for_completion() {
        let scratch = Scratch::new();
        scratch.folder("code");
        let items = folders("~", &scratch.0);
        assert_eq!(items[0].completion, "~/");
        assert_eq!(items[0].subtitle, "~");
        let inside = folders("~/co", &scratch.0);
        assert_eq!(inside[0].completion, "~/code/");
        assert_eq!(inside[0].subtitle, "~/code");
    }

    #[test]
    fn folder_names_sort_like_finder() {
        let mut names = vec!["v10", "V2", "alpha", "Beta", "v1"];
        names.sort_by(|a, b| natural(a, b));
        assert_eq!(names, ["alpha", "Beta", "v1", "V2", "v10"]);
    }

    #[test]
    fn grep_and_ripgrep_lines_parse_into_matches() {
        let output = "./Sources/App.swift:12:    let email = defaults.string(forKey: \"login:last\")\nREADME.md:3:Login\nnot a match\n";
        assert_eq!(
            parse(output),
            [
                TextMatch {
                    path: "Sources/App.swift".into(),
                    line: 12,
                    text: "let email = defaults.string(forKey: \"login:last\")".into()
                },
                TextMatch {
                    path: "README.md".into(),
                    line: 3,
                    text: "Login".into()
                },
            ]
        );
    }

    #[test]
    fn a_search_finds_text_in_the_folder_with_or_without_ripgrep() {
        let scratch = Scratch::new();
        scratch.file("src/a.txt", "one\nthe needle is here\nthree\n");
        scratch.file("b.txt", "nothing\n");
        scratch.file(".git/config", "needle\n");
        scratch.file("node_modules/x.js", "needle\n");
        scratch.file("bin.dat", "needle\0binary");
        let expected = [TextMatch {
            path: "src/a.txt".into(),
            line: 2,
            text: "the needle is here".into(),
        }];
        assert_eq!(walk(&scratch.0, "needle"), expected);
        // ripgrep also skips hidden and binary files; node_modules is searched
        // unless ignored, as in Swift.
        assert!(text(&scratch.0, "needle").unwrap().contains(&expected[0]));
        assert!(text(&scratch.0, "n").unwrap().is_empty());
        assert!(text(&scratch.0, "a\nb").is_err());
    }

    #[test]
    fn matches_group_per_file_in_path_order_with_six_lines_each() {
        let lines = (1..=8)
            .map(|line| TextMatch {
                path: if line % 2 == 0 { "b.rs" } else { "a.rs" }.into(),
                line,
                text: "x".into(),
            })
            .chain((1..=7).map(|line| TextMatch {
                path: "c.rs".into(),
                line,
                text: "x".into(),
            }))
            .collect();
        let groups = group_by_file(lines);
        assert_eq!(
            groups
                .iter()
                .map(|(path, _)| path.as_str())
                .collect::<Vec<_>>(),
            ["a.rs", "b.rs", "c.rs"]
        );
        assert_eq!(groups[2].1.len(), 6);
        assert_eq!(groups[0].1[0].line, 1);
    }

    #[test]
    fn xcode_opens_the_workspace_then_project_then_package() {
        let scratch = Scratch::new();
        assert_eq!(xcode_document(&scratch.0), scratch.0);
        scratch.file("Package.swift", "");
        assert_eq!(xcode_document(&scratch.0), scratch.0.join("Package.swift"));
        scratch.folder("App.xcodeproj");
        assert_eq!(xcode_document(&scratch.0), scratch.0.join("App.xcodeproj"));
        scratch.folder("App.xcworkspace");
        assert_eq!(
            xcode_document(&scratch.0),
            scratch.0.join("App.xcworkspace")
        );
    }

    #[test]
    fn fallback_checks_cancellation_deadline_and_depth_without_following_symlinks() {
        let scratch = Scratch::new();
        scratch.file("visible.txt", "needle\n");
        let deep = (0..DEPTH_LIMIT + 2)
            .map(|_| "a")
            .collect::<Vec<_>>()
            .join("/");
        scratch.file(&format!("{deep}/hidden.txt"), "needle\n");
        let matches = walk_controlled(&scratch.0, "needle", &SearchControl::default());
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].path, "visible.txt");
        let cancelled = SearchControl::default();
        cancelled.cancel();
        assert!(walk_controlled(&scratch.0, "needle", &cancelled).is_empty());
        assert!(folders_controlled(&scratch.path(), &scratch.0, &cancelled).is_empty());
        assert!(files_controlled(&scratch.0, "needle", &cancelled).is_err());
        assert!(
            walk_controlled(
                &scratch.0,
                "needle",
                &SearchControl::with_timeout(Duration::ZERO)
            )
            .is_empty()
        );
        #[cfg(unix)]
        {
            let outside = Scratch::new();
            outside.file("outside.txt", "needle\n");
            std::os::unix::fs::symlink(&outside.0, scratch.0.join("linked-folder")).unwrap();
            assert_eq!(
                walk_controlled(&scratch.0, "needle", &SearchControl::default()).len(),
                1
            );
        }
    }

    #[test]
    fn home_paths_abbreviate_with_a_tilde() {
        let home = Path::new("/Users/me");
        assert_eq!(abbreviated(Path::new("/Users/me"), home), "~");
        assert_eq!(
            abbreviated(Path::new("/Users/me/code/app"), home),
            "~/code/app"
        );
        assert_eq!(abbreviated(Path::new("/opt/app"), home), "/opt/app");
    }
}

#[path = "project_search_process.rs"]
mod process;
use process::capture_search;
