//! Bounded project inspection shared by the desktop and CLI.
#[path = "workspace_path.rs"]
mod path;
use anyhow::{Context, Result, bail, ensure};
pub(crate) use path::external_git_path;
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

pub(crate) fn git(directory: &Path, arguments: &[&str]) -> Result<Vec<u8>> {
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
        .stdin(Stdio::null())
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
    let mut child = command.spawn().context("Unable to start git")?;
    let stdout = child.stdout.take().context("Missing git stdout")?;
    let stderr = child.stderr.take().context("Missing git stderr")?;
    let read_pipe = |pipe: Box<dyn Read + Send>| {
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = pipe
                .take((MAX_OUTPUT + 1) as u64)
                .read_to_end(&mut bytes)
                .map(|_| bytes);
            let _ = tx.send(result);
        });
        rx
    };
    let output = read_pipe(Box::new(stdout));
    let errors = read_pipe(Box::new(stderr));
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < Duration::from_secs(15) => {
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
    let bytes = output
        .recv_timeout(Duration::from_secs(1))
        .context("Git stdout did not close")??;
    let errors = errors
        .recv_timeout(Duration::from_secs(1))
        .context("Git stderr did not close")??;
    ensure!(
        bytes.len() <= MAX_OUTPUT && errors.len() <= MAX_OUTPUT,
        "Git output exceeds 3 MiB; narrow the path"
    );
    ensure!(
        status.success(),
        "Git failed: {}",
        String::from_utf8_lossy(&errors)
            .chars()
            .take(2000)
            .collect::<String>()
    );
    Ok(bytes)
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
