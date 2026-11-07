//! Bounded project inspection shared by the desktop and CLI.
#[path = "workspace_path.rs"]
mod path;
use anyhow::{Context, Result, bail, ensure};
pub(crate) use path::{external_git_directory, external_git_path};
use serde_json::{Value, json};
use std::{
    io::Read,
    path::{Component, Path},
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

const MAX_OUTPUT: usize = 3 * 1024 * 1024;

/// How one Git invocation differs from the bounded default.
pub(crate) struct GitOptions<'a> {
    /// A throwaway index, so Git never reads or writes the user's.
    pub index_file: Option<&'a Path>,
    pub input: Option<&'a [u8]>,
    pub timeout: Duration,
    pub max_output: usize,
    /// Stop reading at `max_output` and report the cut instead of failing.
    pub truncate: bool,
}

impl Default for GitOptions<'_> {
    fn default() -> Self {
        Self {
            index_file: None,
            input: None,
            timeout: Duration::from_secs(15),
            max_output: MAX_OUTPUT,
            truncate: false,
        }
    }
}

pub(crate) fn git(directory: &Path, arguments: &[&str]) -> Result<Vec<u8>> {
    git_with(directory, arguments, &GitOptions::default()).map(|(bytes, _)| bytes)
}

/// Runs Git like `git`, returning standard output and whether it was cut at
/// `options.max_output` (only when `options.truncate` allows a cut).
pub(crate) fn git_with(
    directory: &Path,
    arguments: &[&str],
    options: &GitOptions,
) -> Result<(Vec<u8>, bool)> {
    ensure!(directory.is_dir(), "Project directory does not exist");
    let mut command = Command::new("git");
    #[cfg(windows)]
    command.args(["-c", "core.longpaths=true"]);
    // An inherited Git config/index can redirect operations into another checkout.
    for (name, _) in std::env::vars_os() {
        if name.to_string_lossy().starts_with("GIT_") {
            command.env_remove(name);
        }
    }
    // A regular file cannot contain executable hooks (portable across platforms).
    let hooks = external_git_path(&std::env::current_exe()?)?;
    command
        .arg("-c")
        .arg(format!("core.hooksPath={}", hooks.to_string_lossy()));
    command
        .args([
            "--no-pager",
            "--literal-pathspecs",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "protocol.allow=never",
            "-C",
        ])
        .arg(path::external_git_directory(directory)?)
        .args(arguments)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(if options.input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for name in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
    ] {
        command.env_remove(name);
    }
    if let Some(index) = options.index_file {
        command.env("GIT_INDEX_FILE", external_git_path(index)?);
    }
    let mut child = command.spawn().context("Unable to start git")?;
    if let Some(input) = options.input {
        let mut stdin = child.stdin.take().context("Missing git stdin")?;
        let input = input.to_vec();
        // Closing the pipe once written ends Git's read; a Git that exits early
        // only fails this write.
        thread::spawn(move || {
            use std::io::Write;
            let _ = stdin.write_all(&input);
        });
    }
    let stdout = child.stdout.take().context("Missing git stdout")?;
    let stderr = child.stderr.take().context("Missing git stderr")?;
    let read_pipe = |pipe: Box<dyn Read + Send>, limit: usize| {
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = pipe
                .take((limit + 1) as u64)
                .read_to_end(&mut bytes)
                .map(|_| bytes);
            let _ = tx.send(result);
        });
        rx
    };
    let output = read_pipe(Box::new(stdout), options.max_output);
    let errors = read_pipe(Box::new(stderr), MAX_OUTPUT);
    let started = Instant::now();
    let mut read = None;
    let mut truncated = false;
    let status = loop {
        if read.is_none()
            && let Ok(result) = output.try_recv()
        {
            read = Some(result);
        }
        // Past the cap Git blocks writing, so a cut must stop it.
        if options.truncate
            && let Some(Ok(bytes)) = &read
            && bytes.len() > options.max_output
        {
            let _ = child.kill();
            break child.wait()?;
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < options.timeout => {
                thread::sleep(Duration::from_millis(20))
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                bail!("Git operation timed out");
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error.into());
            }
        }
    };
    let mut bytes = match read {
        Some(result) => result?,
        None => output
            .recv_timeout(Duration::from_secs(1))
            .context("Git stdout did not close")??,
    };
    let errors = errors
        .recv_timeout(Duration::from_secs(1))
        .context("Git stderr did not close")??;
    if options.truncate && bytes.len() > options.max_output {
        bytes.truncate(options.max_output);
        truncated = true;
    }
    ensure!(
        bytes.len() <= options.max_output && errors.len() <= MAX_OUTPUT,
        "{}",
        if options.max_output == MAX_OUTPUT {
            "Git output exceeds 3 MiB; narrow the path"
        } else {
            "Git output is too large"
        }
    );
    ensure!(
        truncated || status.success(),
        "Git failed: {}",
        String::from_utf8_lossy(&errors)
            .chars()
            .take(2000)
            .collect::<String>()
    );
    Ok((bytes, truncated))
}

fn relative_path(path: &str) -> Result<&Path> {
    let path = Path::new(path);
    ensure!(
        !path.as_os_str().is_empty()
            && path
                .components()
                .all(|part| matches!(part, Component::Normal(_))),
        "Use a relative project path without dot or parent components"
    );
    Ok(path)
}

pub fn status(directory: &Path) -> Result<Value> {
    let bytes = git(
        directory,
        &["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
    )?;
    let mut records = bytes.split(|b| *b == 0).filter(|r| !r.is_empty());
    let mut entries = Vec::new();
    while let Some(record) = records.next() {
        ensure!(record.len() >= 4, "Malformed git status record");
        let state = std::str::from_utf8(&record[..2])?;
        let path = std::str::from_utf8(&record[3..])?;
        let original = if state.contains('R') || state.contains('C') {
            Some(std::str::from_utf8(
                records.next().context("Missing rename source")?,
            )?)
        } else {
            None
        };
        entries.push(json!({"status":state,"path":path,"originalPath":original}));
    }
    let branch = String::from_utf8(
        git(directory, &["symbolic-ref", "--short", "-q", "HEAD"])
            .or_else(|_| git(directory, &["rev-parse", "--short", "HEAD"]))?,
    )?;
    Ok(json!({"branch":branch.trim(),"entries":entries}))
}

pub fn diff(directory: &Path, path: Option<&str>, staged: bool) -> Result<Value> {
    if let Some(path) = path {
        relative_path(path)?;
    }
    let mut args = vec!["diff", "--no-ext-diff", "--no-textconv", "--no-color"];
    if staged {
        args.push("--cached");
    }
    args.push("--");
    if let Some(path) = path {
        args.push(path);
    }
    Ok(json!({"diff":String::from_utf8(git(directory,&args)?)?,"staged":staged}))
}

pub fn files(directory: &Path, query: &str, limit: usize) -> Result<Value> {
    ensure!((1..=5000).contains(&limit), "Limit must be 1–5000");
    let bytes = git(
        directory,
        &[
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ],
    )?;
    let query = query.to_lowercase();
    let mut paths = bytes
        .split(|b| *b == 0)
        .filter(|path| !path.is_empty())
        .map(std::str::from_utf8)
        .collect::<std::result::Result<Vec<_>, _>>()?;
    paths.sort_unstable();
    paths.dedup();
    paths.retain(|path| path.to_lowercase().contains(&query));
    let total = paths.len();
    paths.truncate(limit);
    Ok(json!({"files":paths,"total":total,"truncated":total>limit}))
}

/// Composer completion includes folders derived from Git's literal paths. This
/// stays distinct from the public file-list API, and never reads file bodies.
pub(crate) fn composer_paths(directory: &Path, query: &str, limit: usize) -> Result<Value> {
    let bytes = git(
        directory,
        &[
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ],
    )?;
    composer_path_results(&bytes, query, limit)
}
pub(crate) fn composer_path_results(bytes: &[u8], query: &str, limit: usize) -> Result<Value> {
    ensure!(
        (1..=80).contains(&limit),
        "Composer result limit must be 1–80"
    );
    let mut entries = std::collections::BTreeMap::<String, bool>::new();
    let mut limited = false;
    for raw in bytes.split(|b| *b == 0).filter(|p| !p.is_empty()) {
        let path = std::str::from_utf8(raw).context("Project path is not UTF-8")?;
        if entries.len() >= 25_000 {
            limited = true;
            break;
        }
        entries.entry(path.to_owned()).or_insert(false);
        let mut parent = Path::new(path).parent();
        while let Some(folder) = parent.filter(|p| !p.as_os_str().is_empty()) {
            if entries.len() >= 25_000 {
                limited = true;
                break;
            }
            if let Some(folder) = folder.to_str() {
                entries.entry(folder.to_owned()).or_insert(true);
            }
            parent = folder.parent();
        }
    }
    let query = query.to_lowercase();
    let mut matches: Vec<_> = entries
        .into_iter()
        .filter_map(|(path, directory)| {
            let lower = path.to_lowercase();
            let name = lower.rsplit('/').next().unwrap_or(&lower);
            let depth = lower.bytes().filter(|b| *b == b'/').count();
            let rank = if query.is_empty() {
                if depth == 0 {
                    0
                } else {
                    return None;
                }
            } else if name == query {
                0
            } else if name.starts_with(&query) {
                1
            } else if lower.starts_with(&query) {
                2
            } else if name.contains(&query) {
                3
            } else if lower.contains(&query) {
                4
            } else if let Some(cost) = composer_subsequence_cost(query.as_bytes(), name.as_bytes())
            {
                1_000 + cost
            } else {
                let cost = composer_subsequence_cost(query.as_bytes(), lower.as_bytes())?;
                100_000 + cost
            };
            let directory_order = query.is_empty() && !directory;
            Some((
                rank,
                depth,
                directory_order,
                lower.chars().count(),
                lower,
                path,
            ))
        })
        .collect();
    matches.sort_unstable();
    let total = matches.len();
    let paths: Vec<_> = matches
        .into_iter()
        .take(limit)
        .map(|(_, _, _, _, _, path)| path)
        .collect();
    Ok(json!({"files":paths,"total":total,"truncated":limited || total>limit}))
}

// Same ranking rule as Swift's ComposerFileIndex: scattered byte runs first,
// then their span. Only matching is byte-based; emitted paths stay exact UTF-8.
fn composer_subsequence_cost(query: &[u8], text: &[u8]) -> Option<usize> {
    let mut position = 0;
    let mut previous = None;
    let mut first = None;
    let mut runs = 0;
    for byte in query {
        while position < text.len() && text[position] != *byte {
            position += 1;
        }
        if position == text.len() {
            return None;
        }
        if previous.is_none_or(|last| last + 1 != position) {
            runs += 1;
        }
        first.get_or_insert(position);
        previous = Some(position);
        position += 1;
    }
    Some(runs * 100 + previous?.saturating_sub(first?).min(99))
}

pub fn read_file(directory: &Path, path: &str, offset: usize, limit: usize) -> Result<Value> {
    ensure!((1..=5000).contains(&limit), "Line limit must be 1–5000");
    let relative = relative_path(path)?;
    let root = directory.canonicalize()?;
    let file = root.join(relative).canonicalize()?;
    ensure!(
        file.starts_with(&root),
        "File is outside the project directory"
    );
    ensure!(file.is_file(), "Path is not a regular file");
    let mut bytes = Vec::new();
    std::fs::File::open(file)?
        .take((MAX_OUTPUT + 1) as u64)
        .read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= MAX_OUTPUT, "File exceeds 3 MiB");
    ensure!(!bytes.contains(&0), "File is binary");
    let body = std::str::from_utf8(&bytes).context("File is not UTF-8 text")?;
    let lines = body.lines().collect::<Vec<_>>();
    let total = lines.len();
    let end = offset.saturating_add(limit).min(total);
    let selected = lines.get(offset..end).unwrap_or_default().join("\n");
    Ok(
        json!({"path":path,"text":selected,"lineOffset":offset,"totalLines":total,"truncated":end<total}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn composer_folder_results_narrow_paths_and_preserve_public_file_list_contract() {
        let paths =
            "src/café.rs\0src/deep/main.rs\0src/deep/main.rs\0top.rs\0white space/child.rs\0";
        let top = composer_path_results(paths.as_bytes(), "", 80).unwrap();
        assert_eq!(top["files"], json!(["src", "white space", "top.rs"]));
        let nested = composer_path_results(paths.as_bytes(), "src/", 80).unwrap();
        assert_eq!(
            nested["files"],
            json!(["src/deep", "src/café.rs", "src/deep/main.rs"])
        );
        let limited = composer_path_results(paths.as_bytes(), "src", 1).unwrap();
        assert_eq!(limited["files"], json!(["src"]));
        assert_eq!(limited["total"], 4);
        assert_eq!(limited["truncated"], true);
        assert_eq!(
            composer_path_results(paths.as_bytes(), "CAFÉ", 80).unwrap()["files"],
            json!(["src/café.rs"])
        );
        assert_eq!(
            composer_path_results(paths.as_bytes(), "cf", 80).unwrap()["files"],
            json!(["src/café.rs"])
        );
        assert_eq!(
            composer_path_results(paths.as_bytes(), "sdp", 80).unwrap()["files"],
            json!(["src/deep", "src/deep/main.rs"])
        );
        assert_eq!(composer_subsequence_cost(b"ab", b"xxab"), Some(101));
        assert_eq!(composer_subsequence_cost(b"ab", b"axxb"), Some(203));
        assert!(composer_path_results(&[255, 0], "", 80).is_err());
        assert!(composer_path_results(paths.as_bytes(), "", 81).is_err());
    }
    #[test]
    fn repository_status_diff_and_literal_file_paths() {
        let dir = tempfile::tempdir().unwrap();
        git(dir.path(), &["init", "-q"]).unwrap();
        std::fs::write(dir.path().join("[fixture].txt"), "line one\nline two\n").unwrap();
        let state = status(dir.path()).unwrap();
        assert_eq!(state["entries"][0]["path"], "[fixture].txt");
        git(dir.path(), &["add", "--", "[fixture].txt"]).unwrap();
        assert!(
            diff(dir.path(), Some("[fixture].txt"), true).unwrap()["diff"]
                .as_str()
                .unwrap()
                .contains("+line one")
        );
        assert_eq!(files(dir.path(), "FIXTURE", 10).unwrap()["total"], 1);
        assert_eq!(
            read_file(dir.path(), "[fixture].txt", 1, 1).unwrap()["text"],
            "line two"
        );
        assert!(read_file(dir.path(), "../outside", 0, 10).is_err());
        std::fs::write(dir.path().join("binary"), [0, 1]).unwrap();
        assert!(read_file(dir.path(), "binary", 0, 10).is_err());
        #[cfg(unix)]
        {
            let outside = tempfile::NamedTempFile::new().unwrap();
            std::os::unix::fs::symlink(outside.path(), dir.path().join("escape")).unwrap();
            assert!(read_file(dir.path(), "escape", 0, 10).is_err());
        }
    }
}
