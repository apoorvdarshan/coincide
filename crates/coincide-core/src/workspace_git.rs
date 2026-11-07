//! Local Git primitives. Checkpoints capture the index, never unstaged/untracked data.
//! No checkout, reset, clean, worktree removal, network or user hook execution.
use crate::workspace::{external_git_path, git};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::path::{Component, Path};
use uuid::Uuid;

fn text(directory: &Path, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8(git(directory, args)?)?.trim().to_owned())
}

pub fn validate_oid(oid: &str) -> Result<()> {
    ensure!(
        matches!(oid.len(), 40 | 64) && oid.bytes().all(|b| b.is_ascii_hexdigit()),
        "Expected a full Git object ID"
    );
    Ok(())
}

fn root(directory: &Path) -> Result<()> {
    let top = text(directory, &["rev-parse", "--show-toplevel"])?;
    ensure!(
        Path::new(&top).canonicalize()? == directory.canonicalize()?,
        "Operation requires the repository root"
    );
    Ok(())
}

pub fn validate_branch(directory: &Path, branch: &str) -> Result<()> {
    ensure!(
        !branch.is_empty()
            && branch.len() <= 200
            && !branch.starts_with('-')
            && !branch.contains('@')
            && !branch.chars().any(char::is_control),
        "Invalid branch name"
    );
    git(
        directory,
        &["check-ref-format", &format!("refs/heads/{branch}")],
    )?;
    Ok(())
}

fn checkpoint_ref(id: &str) -> Result<String> {
    let uuid = Uuid::parse_str(id).context("Invalid checkpoint ID")?;
    ensure!(uuid.to_string() == id, "Expected canonical checkpoint ID");
    Ok(format!("refs/coincide/checkpoints/{id}"))
}

/// Creates an immutable staged snapshot, preserving index, branch and working files.
/// expected_head detects a stale UI selection. The snapshot's parent is that head even
/// if an external process subsequently moves the branch. Unmerged indexes fail closed.
pub fn create_checkpoint(directory: &Path, expected_head: &str, label: &str) -> Result<Value> {
    root(directory)?;
    validate_oid(expected_head)?;
    ensure!(
        !label.trim().is_empty() && label.len() <= 500 && !label.contains('\0'),
        "Invalid checkpoint label"
    );
    let head = text(directory, &["rev-parse", "--verify", "HEAD"])?;
    ensure!(
        head == expected_head,
        "HEAD changed; refresh before checkpointing"
    );
    let tree = text(directory, &["write-tree"])?;
    let commit = text(
        directory,
        &[
            "-c",
            "user.name=Coincide",
            "-c",
            "user.email=checkpoint@coincide.invalid",
            "-c",
            "commit.gpgSign=false",
            "commit-tree",
            &tree,
            "-p",
            &head,
            "-m",
            label,
        ],
    )?;
    validate_oid(&commit)?;
    let id = Uuid::new_v4().to_string();
    let reference = checkpoint_ref(&id)?;
    // Empty old value requires an absent reference (compare-and-swap).
    git(directory, &["update-ref", &reference, &commit, ""])?;
    Ok(json!({"id":id,"commit":commit,"parent":head,"tree":tree,"scope":"staged"}))
}

pub fn checkpoints(directory: &Path) -> Result<Value> {
    let data = text(
        directory,
        &[
            "for-each-ref",
            "--sort=-creatordate",
            "--format=%(refname) %(objectname)",
            "refs/coincide/checkpoints/",
        ],
    )?;
    let mut entries = Vec::new();
    for line in data.lines() {
        let (reference, commit) = line.split_once(' ').context("Malformed checkpoint ref")?;
        let id = reference
            .strip_prefix("refs/coincide/checkpoints/")
            .context("Invalid checkpoint namespace")?;
        // Per-turn snapshots (<thread>/<turn>/<phase>, also written by the
        // Swift app) share the namespace; only staged checkpoints are listed.
        if id.contains('/') {
            continue;
        }
        checkpoint_ref(id)?;
        validate_oid(commit)?;
        entries.push(json!({"id":id,"commit":commit}));
    }
    Ok(json!({"checkpoints":entries}))
}

pub fn checkpoint_diff(directory: &Path, id: &str) -> Result<Value> {
    let reference = checkpoint_ref(id)?;
    let commit = text(
        directory,
        &["rev-parse", "--verify", &format!("{reference}^{{commit}}")],
    )?;
    validate_oid(&commit)?;
    let diff = String::from_utf8(git(
        directory,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            &format!("{commit}^"),
            &commit,
            "--",
        ],
    )?)?;
    Ok(json!({"id":id,"commit":commit,"diff":diff}))
}

pub fn worktrees(directory: &Path) -> Result<Value> {
    let bytes = git(directory, &["worktree", "list", "--porcelain", "-z"])?;
    let mut entries = Vec::new();
    let mut entry = serde_json::Map::new();
    for record in bytes.split(|b| *b == 0) {
        if record.is_empty() {
            if !entry.is_empty() {
                entries.push(Value::Object(std::mem::take(&mut entry)));
            }
            continue;
        }
        let record = std::str::from_utf8(record)?;
        let (key, value) = record.split_once(' ').unwrap_or((record, ""));
        entry.insert(
            key.into(),
            if value.is_empty() {
                json!(true)
            } else {
                json!(value)
            },
        );
    }
    if !entry.is_empty() {
        entries.push(Value::Object(entry));
    }
    Ok(json!({"worktrees":entries}))
}

/// Reserve a new branch and empty linked worktree at an exact commit. No checkout
/// means repository smudge filters cannot execute. A separate reviewed checkout
/// flow is required to populate files. Existing destinations are never overwritten.
pub fn create_worktree(
    directory: &Path,
    parent: &Path,
    name: &str,
    branch: &str,
    base: &str,
) -> Result<Value> {
    root(directory)?;
    validate_branch(directory, branch)?;
    validate_oid(base)?;
    ensure!(
        name.len() <= 128
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_')),
        "Use a portable worktree name containing only letters, digits, hyphens and underscores"
    );
    ensure!(
        !matches!(
            name.to_ascii_uppercase().as_str(),
            "CON"
                | "PRN"
                | "AUX"
                | "NUL"
                | "COM1"
                | "COM2"
                | "COM3"
                | "COM4"
                | "COM5"
                | "COM6"
                | "COM7"
                | "COM8"
                | "COM9"
                | "LPT1"
                | "LPT2"
                | "LPT3"
                | "LPT4"
                | "LPT5"
                | "LPT6"
                | "LPT7"
                | "LPT8"
                | "LPT9"
        ),
        "Reserved worktree name"
    );
    let components = Path::new(name).components().collect::<Vec<_>>();
    ensure!(
        components.len() == 1
            && matches!(components[0], Component::Normal(_))
            && !name.starts_with('-')
            && !name.contains(['/', '\\'])
            && !name.chars().any(char::is_control),
        "Expected a single worktree directory name"
    );
    ensure!(parent.is_absolute(), "Worktree parent must be absolute");
    let parent = parent.canonicalize()?;
    ensure!(
        !parent.starts_with(directory.canonicalize()?),
        "Worktree must be outside the source checkout"
    );
    let destination = parent.join(name);
    ensure!(
        std::fs::symlink_metadata(&destination)
            .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
        "Worktree destination already exists or is inaccessible"
    );
    let external_destination = external_git_path(&destination)?;
    let destination_text = external_destination
        .to_str()
        .context("Worktree path is not UTF-8")?;
    ensure!(
        text(directory, &["cat-file", "-t", base])? == "commit",
        "Base must be a commit object"
    );
    git(
        directory,
        &[
            "worktree",
            "add",
            "--no-checkout",
            "-b",
            branch,
            "--",
            destination_text,
            base,
        ],
    )?;
    Ok(json!({"path":destination_text,"branch":branch,"head":base,"populated":false}))
}
