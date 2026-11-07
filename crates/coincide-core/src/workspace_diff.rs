//! The Diff inspector's changes: uncommitted or since the branch left its base,
//! untracked files previewed through a throwaway intent-to-add index, parsed into
//! files, hunks and lines. Mirrors Swift's GitOps.diff, DiffParser and SplitDiffLine.
//! Reads only; the user's index, branches and working files are never written.
use crate::workspace::{GitOptions, external_git_path, git, git_with};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    cmp::Ordering,
    collections::{HashMap, HashSet},
    ops::Range,
    path::{Path, PathBuf},
    time::Duration,
};

/// Patches beyond this are cut at a file boundary; a byte more is read to notice the cut.
pub const MAX_PATCH_BYTES: usize = 8 * 1024 * 1024;
/// Beyond this many untracked files the working tree diff omits their previews.
pub const MAX_UNTRACKED_FILES: usize = 5_000;
/// Room for `MAX_UNTRACKED_FILES` paths of a kilobyte.
const MAX_UNTRACKED_LIST_BYTES: usize = MAX_UNTRACKED_FILES * 1024;
/// No file in a diff has this many lines; capping hunk numbers keeps counting from overflowing.
const MAX_LINE_NUMBER: usize = i32::MAX as usize;

/// What the Diff inspector compares the working tree against.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Scope {
    /// HEAD: staged, unstaged and untracked changes.
    #[default]
    Uncommitted,
    /// Where the branch left its base, committed or not.
    Branch,
}

impl Scope {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "uncommitted" => Some(Self::Uncommitted),
            "branch" => Some(Self::Branch),
            _ => None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Uncommitted => "uncommitted",
            Self::Branch => "branch",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChangeStatus {
    Added,
    Untracked,
    Modified,
    Deleted,
    Renamed,
}

impl ChangeStatus {
    pub fn letter(self) -> &'static str {
        match self {
            Self::Added => "A",
            Self::Untracked => "U",
            Self::Modified => "M",
            Self::Deleted => "D",
            Self::Renamed => "R",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::Added => "Added",
            Self::Untracked => "Untracked",
            Self::Modified => "Modified",
            Self::Deleted => "Deleted",
            Self::Renamed => "Renamed",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LineKind {
    Context,
    Addition,
    Deletion,
    /// `\ No newline at end of file`.
    NoNewline,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DiffLine {
    pub kind: LineKind,
    pub text: String,
    pub old_line: Option<usize>,
    pub new_line: Option<usize>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct DiffHunk {
    pub old_start: usize,
    pub old_count: usize,
    pub new_start: usize,
    pub new_count: usize,
    /// Text after the second `@@`, usually the enclosing function.
    pub section: String,
    pub lines: Vec<DiffLine>,
}

impl DiffHunk {
    pub fn header(&self) -> String {
        let range = format!(
            "@@ -{},{} +{},{} @@",
            self.old_start, self.old_count, self.new_start, self.new_count
        );
        if self.section.is_empty() {
            range
        } else {
            format!("{range} {}", self.section)
        }
    }
}

/// One file of a unified diff.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FileDiff {
    pub path: String,
    pub old_path: Option<String>,
    pub status: ChangeStatus,
    pub additions: usize,
    pub deletions: usize,
    pub is_binary: bool,
    /// Mode change, such as `100644 → 100755`, when there is one.
    pub mode_change: Option<String>,
    pub hunks: Vec<DiffHunk>,
}

impl FileDiff {
    pub fn new(path: impl Into<String>, status: ChangeStatus) -> Self {
        Self {
            path: path.into(),
            old_path: None,
            status,
            additions: 0,
            deletions: 0,
            is_binary: false,
            mode_change: None,
            hunks: Vec::new(),
        }
    }
}

/// Changes in one scope, with the patch split per file.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct GitDiff {
    pub files: Vec<FileDiff>,
    /// The patch was cut short, so some files lack hunks.
    pub is_truncated: bool,
    /// What the changes are compared against, such as `HEAD` or `origin/main`.
    pub base_label: Option<String>,
}

impl GitDiff {
    pub fn additions(&self) -> usize {
        self.files.iter().map(|file| file.additions).sum()
    }
    pub fn deletions(&self) -> usize {
        self.files.iter().map(|file| file.deletions).sum()
    }
}

/// One `git diff --numstat -z` record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Numstat {
    pub path: String,
    pub old_path: Option<String>,
    pub additions: usize,
    pub deletions: usize,
    pub is_binary: bool,
}

/// Parses `git diff --numstat -z`, including rename records (`adds\tdels\t\0old\0new\0`).
pub fn parse_numstat(output: &str) -> Vec<Numstat> {
    let fields: Vec<&str> = output.split('\0').collect();
    let mut result = Vec::new();
    let mut index = 0;
    while index < fields.len() {
        let field = fields[index];
        index += 1;
        let parts: Vec<&str> = field.splitn(3, '\t').collect();
        if parts.len() != 3 {
            continue;
        }
        let is_binary = parts[0] == "-" && parts[1] == "-";
        let mut path = parts[2].to_owned();
        let mut old_path = None;
        if path.is_empty() {
            if index + 1 >= fields.len() {
                break;
            }
            old_path = Some(fields[index].to_owned());
            path = fields[index + 1].to_owned();
            index += 2;
        }
        if path.is_empty() {
            continue;
        }
        result.push(Numstat {
            path,
            old_path,
            additions: parts[0].parse().unwrap_or(0),
            deletions: parts[1].parse().unwrap_or(0),
            is_binary,
        });
    }
    result
}

fn nul_fields(output: &str) -> Vec<String> {
    output
        .split('\0')
        .filter(|field| !field.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Undoes Git's C-style quoting of a path (`"a\tb"`, octal escapes for raw bytes).
fn unquote(value: &str) -> String {
    let bytes = value.as_bytes();
    if bytes.len() < 2 || bytes[0] != b'"' || bytes[bytes.len() - 1] != b'"' {
        return value.to_owned();
    }
    let mut out = Vec::with_capacity(bytes.len());
    let mut iter = bytes[1..bytes.len() - 1].iter().copied().peekable();
    while let Some(byte) = iter.next() {
        if byte != b'\\' {
            out.push(byte);
            continue;
        }
        let Some(next) = iter.next() else {
            out.push(byte);
            break;
        };
        match next {
            b'n' => out.push(0x0A),
            b't' => out.push(0x09),
            b'r' => out.push(0x0D),
            b'a' => out.push(0x07),
            b'b' => out.push(0x08),
            b'f' => out.push(0x0C),
            b'v' => out.push(0x0B),
            b'0'..=b'7' => {
                let mut octal = u32::from(next - b'0');
                for _ in 0..2 {
                    match iter.peek() {
                        Some(digit @ b'0'..=b'7') => {
                            octal = octal * 8 + u32::from(digit - b'0');
                            iter.next();
                        }
                        _ => break,
                    }
                }
                out.push(octal as u8);
            }
            other => out.push(other),
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn strip(value: &str, prefix: &str) -> String {
    value.strip_prefix(prefix).unwrap_or(value).to_owned()
}

/// Paths from `a/<old> b/<new>`, which are ambiguous when names contain " b/".
fn header_paths(value: &str) -> (String, String) {
    if value.starts_with('"') {
        let mut escaped = false;
        let mut end = value.len();
        for (index, ch) in value.char_indices().skip(1) {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                end = index + 1;
                break;
            }
        }
        let old = strip(&unquote(&value[..end]), "a/");
        let rest = value[end..].trim_start_matches(' ');
        return (old, strip(&unquote(rest), "b/"));
    }
    // Without a rename both halves are the same path, so split where they match.
    let chars: Vec<char> = value.chars().collect();
    let count = chars.len();
    if count >= 5 && (count - 5).is_multiple_of(2) && value.starts_with("a/") {
        let length = (count - 5) / 2;
        let left = &chars[2..2 + length];
        let right = &chars[count - length..];
        if left == right {
            let path: String = left.iter().collect();
            return (path.clone(), path);
        }
    }
    if let Some(index) = value.rfind(" b/") {
        return (strip(&value[..index], "a/"), value[index + 3..].to_owned());
    }
    (value.to_owned(), value.to_owned())
}

fn marker_path(value: &str, prefix: &str) -> Option<String> {
    // Git appends a tab after names that contain spaces.
    let trimmed = value.strip_suffix('\t').unwrap_or(value);
    (trimmed != "/dev/null").then(|| strip(&unquote(trimmed), prefix))
}

/// Swift's `split(separator:maxSplits:omittingEmptySubsequences: true)` on spaces:
/// the last part keeps what follows its separator, leading spaces included.
fn split_spaces(line: &str, max_splits: usize) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0;
    let bytes = line.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b' ' {
            let appended = index > start;
            if appended {
                parts.push(&line[start..index]);
            }
            index += 1;
            start = index;
            if appended && parts.len() == max_splits {
                break;
            }
            continue;
        }
        index += 1;
    }
    if start < line.len() {
        parts.push(&line[start..]);
    }
    parts
}

/// Parses `@@ -a,b +c,d @@ section`; a missing count means 1. A negative or absurdly
/// large number, which Git never writes, makes the line not a hunk header.
pub fn hunk_header(line: &str) -> Option<DiffHunk> {
    let parts = split_spaces(line, 4);
    if parts.len() < 4 || parts[0] != "@@" || !parts[3].starts_with("@@") {
        return None;
    }
    let range = |value: &str| -> Option<(usize, usize)> {
        let mut chars = value.chars();
        chars.next()?;
        let pieces: Vec<&str> = chars.as_str().split(',').collect();
        let start: i64 = pieces[0].parse().ok()?;
        let count: i64 = if pieces.len() > 1 {
            pieces[1].parse().unwrap_or(1)
        } else {
            1
        };
        let valid = |value: i64| (0..=MAX_LINE_NUMBER as i64).contains(&value);
        (valid(start) && valid(count)).then_some((start as usize, count as usize))
    };
    let old = range(parts[1])?;
    let new = range(parts[2])?;
    Some(DiffHunk {
        old_start: old.0,
        old_count: old.1,
        new_start: new.0,
        new_count: new.1,
        section: parts.get(4).map_or_else(String::new, |s| (*s).to_owned()),
        lines: Vec::new(),
    })
}

/// Splits a unified diff (made with `--src-prefix=a/ --dst-prefix=b/`) into files and hunks.
pub fn parse_patch(patch: &str) -> Vec<FileDiff> {
    struct Parser {
        files: Vec<FileDiff>,
        file: Option<FileDiff>,
        hunk: Option<DiffHunk>,
        old_remaining: usize,
        new_remaining: usize,
        old_line: usize,
        new_line: usize,
        in_binary_patch: bool,
    }
    impl Parser {
        fn finish_hunk(&mut self) {
            if let Some(hunk) = self.hunk.take()
                && let Some(file) = self.file.as_mut()
            {
                file.hunks.push(hunk);
            }
        }
        fn finish_file(&mut self) {
            self.finish_hunk();
            if let Some(file) = self.file.take() {
                self.files.push(file);
            }
            self.in_binary_patch = false;
        }
    }
    let mut p = Parser {
        files: Vec::new(),
        file: None,
        hunk: None,
        old_remaining: 0,
        new_remaining: 0,
        old_line: 0,
        new_line: 0,
        in_binary_patch: false,
    };
    for raw in patch.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if let Some(header) = line.strip_prefix("diff --git ") {
            p.finish_file();
            p.file = Some(FileDiff::new(
                header_paths(header).1,
                ChangeStatus::Modified,
            ));
            continue;
        }
        if p.file.is_none() {
            continue;
        }
        if p.hunk.is_some() && (p.old_remaining > 0 || p.new_remaining > 0) {
            let mut chars = line.chars();
            let marker = chars.next();
            let text = chars.as_str().to_owned();
            let (Some(hunk), Some(file)) = (p.hunk.as_mut(), p.file.as_mut()) else {
                continue;
            };
            match marker {
                Some('+') => {
                    hunk.lines.push(DiffLine {
                        kind: LineKind::Addition,
                        text,
                        old_line: None,
                        new_line: Some(p.new_line),
                    });
                    p.new_line += 1;
                    p.new_remaining = p.new_remaining.saturating_sub(1);
                    file.additions += 1;
                }
                Some('-') => {
                    hunk.lines.push(DiffLine {
                        kind: LineKind::Deletion,
                        text,
                        old_line: Some(p.old_line),
                        new_line: None,
                    });
                    p.old_line += 1;
                    p.old_remaining = p.old_remaining.saturating_sub(1);
                    file.deletions += 1;
                }
                Some('\\') => hunk.lines.push(DiffLine {
                    kind: LineKind::NoNewline,
                    text: line.to_owned(),
                    old_line: None,
                    new_line: None,
                }),
                _ => {
                    // A context line; an empty line is context whose leading space was stripped.
                    hunk.lines.push(DiffLine {
                        kind: LineKind::Context,
                        text,
                        old_line: Some(p.old_line),
                        new_line: Some(p.new_line),
                    });
                    p.old_line += 1;
                    p.new_line += 1;
                    p.old_remaining = p.old_remaining.saturating_sub(1);
                    p.new_remaining = p.new_remaining.saturating_sub(1);
                }
            }
            continue;
        }
        if line.starts_with("@@") {
            p.finish_hunk();
            let Some(parsed) = hunk_header(line) else {
                continue;
            };
            p.old_line = parsed.old_start;
            p.new_line = parsed.new_start;
            p.old_remaining = parsed.old_count;
            p.new_remaining = parsed.new_count;
            p.hunk = Some(parsed);
            continue;
        }
        if line.starts_with('\\') {
            if let Some(hunk) = p.hunk.as_mut() {
                hunk.lines.push(DiffLine {
                    kind: LineKind::NoNewline,
                    text: line.to_owned(),
                    old_line: None,
                    new_line: None,
                });
            }
            continue;
        }
        if p.in_binary_patch {
            continue;
        }
        let Some(file) = p.file.as_mut() else {
            continue;
        };
        if line.starts_with("new file mode") {
            file.status = ChangeStatus::Added;
        } else if line.starts_with("deleted file mode") {
            file.status = ChangeStatus::Deleted;
        } else if let Some(mode) = line.strip_prefix("old mode ") {
            file.mode_change = Some(mode.to_owned());
        } else if let Some(mode) = line.strip_prefix("new mode ") {
            let old = file.mode_change.take().unwrap_or_default();
            file.mode_change = Some(format!("{old} → {mode}"));
        } else if let Some(name) = line.strip_prefix("rename from ") {
            file.old_path = Some(unquote(name));
            file.status = ChangeStatus::Renamed;
        } else if let Some(name) = line.strip_prefix("rename to ") {
            file.path = unquote(name);
        } else if let Some(name) = line.strip_prefix("copy to ") {
            file.path = unquote(name);
            file.status = ChangeStatus::Added;
        } else if line.starts_with("Binary files ") {
            file.is_binary = true;
        } else if line.starts_with("GIT binary patch") {
            file.is_binary = true;
            p.in_binary_patch = true;
        } else if let Some(name) = line.strip_prefix("--- ") {
            if let Some(path) = marker_path(name, "a/")
                && file.status != ChangeStatus::Renamed
            {
                file.old_path = (path != file.path).then_some(path);
            }
        } else if let Some(name) = line.strip_prefix("+++ ")
            && let Some(path) = marker_path(name, "b/")
        {
            file.path = path;
        }
    }
    p.finish_file();
    p.files
}

/// Finder's order: case-insensitive, with runs of digits compared as numbers.
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let take = |chars: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut digits = String::new();
                    while let Some(c) = chars.peek().copied().filter(char::is_ascii_digit) {
                        digits.push(c);
                        chars.next();
                    }
                    digits
                };
                let (x, y) = (take(&mut a), take(&mut b));
                let (tx, ty) = (x.trim_start_matches('0'), y.trim_start_matches('0'));
                let order = tx.len().cmp(&ty.len()).then_with(|| tx.cmp(ty));
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

/// Joins a patch with its numstat: counts come from numstat, hunks from the patch.
pub fn assemble(patch: &str, stats: &[Numstat], untracked: &HashSet<String>) -> GitDiff {
    let mut text = patch;
    let mut truncated = false;
    if text.len() > MAX_PATCH_BYTES {
        let mut limit = MAX_PATCH_BYTES;
        while !text.is_char_boundary(limit) {
            limit -= 1;
        }
        let head = &text[..limit];
        let cut = head.rfind("\ndiff --git ").unwrap_or(limit);
        text = &text[..cut];
        truncated = true;
    }
    let mut by_path: HashMap<String, FileDiff> = HashMap::new();
    for file in parse_patch(text) {
        by_path.insert(file.path.clone(), file);
    }
    let mut files = Vec::with_capacity(stats.len());
    for stat in stats {
        let mut file = by_path
            .remove(&stat.path)
            .unwrap_or_else(|| FileDiff::new(stat.path.clone(), ChangeStatus::Modified));
        if file.old_path.is_none() {
            file.old_path = stat.old_path.clone();
        }
        if file.old_path.is_some() && file.status == ChangeStatus::Modified {
            file.status = ChangeStatus::Renamed;
        }
        file.additions = stat.additions;
        file.deletions = stat.deletions;
        file.is_binary = file.is_binary || stat.is_binary;
        if untracked.contains(&stat.path) {
            file.status = ChangeStatus::Untracked;
        }
        files.push(file);
    }
    files.extend(by_path.into_values());
    files.sort_by(|a, b| natural_cmp(&a.path, &b.path));
    GitDiff {
        files,
        is_truncated: truncated,
        base_label: None,
    }
}

/// Source-line indexes for one aligned side-by-side row. A missing side is a spacer,
/// never a fabricated empty line; context lines occur on both sides.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SplitLine {
    pub before: Option<usize>,
    pub after: Option<usize>,
}

/// Aligns each contiguous replacement block in source order. End-of-file markers stay
/// with their preceding line, including when a marker separates deletions from additions.
pub fn align(lines: &[DiffLine]) -> Vec<SplitLine> {
    #[derive(Default)]
    struct Entry {
        line: usize,
        markers: Vec<usize>,
    }
    let mut result = Vec::new();
    let mut index = 0;
    while index < lines.len() {
        match lines[index].kind {
            LineKind::Context | LineKind::NoNewline => {
                result.push(SplitLine {
                    before: Some(index),
                    after: Some(index),
                });
                index += 1;
            }
            LineKind::Deletion | LineKind::Addition => {
                let mut old: Vec<Entry> = Vec::new();
                let mut new: Vec<Entry> = Vec::new();
                let mut previous_was_deletion = false;
                while index < lines.len() && lines[index].kind != LineKind::Context {
                    match lines[index].kind {
                        LineKind::Deletion => {
                            old.push(Entry {
                                line: index,
                                ..Entry::default()
                            });
                            previous_was_deletion = true;
                        }
                        LineKind::Addition => {
                            new.push(Entry {
                                line: index,
                                ..Entry::default()
                            });
                            previous_was_deletion = false;
                        }
                        LineKind::NoNewline => {
                            if previous_was_deletion && let Some(last) = old.last_mut() {
                                last.markers.push(index);
                            } else if let Some(last) = new.last_mut() {
                                last.markers.push(index);
                            }
                        }
                        LineKind::Context => {}
                    }
                    index += 1;
                }
                for offset in 0..old.len().max(new.len()) {
                    let left = old.get(offset);
                    let right = new.get(offset);
                    result.push(SplitLine {
                        before: left.map(|entry| entry.line),
                        after: right.map(|entry| entry.line),
                    });
                    let none = Vec::new();
                    let old_markers = left.map_or(&none, |entry| &entry.markers);
                    let new_markers = right.map_or(&none, |entry| &entry.markers);
                    for marker in 0..old_markers.len().max(new_markers.len()) {
                        result.push(SplitLine {
                            before: old_markers.get(marker).copied(),
                            after: new_markers.get(marker).copied(),
                        });
                    }
                }
            }
        }
    }
    result
}

/// The differing middles of two lines as byte ranges, or `None` when they barely
/// overlap (highlighting the whole line would only add noise).
pub fn changed_ranges(old: &str, new: &str) -> Option<(Range<usize>, Range<usize>)> {
    let a: Vec<(usize, char)> = old.char_indices().collect();
    let b: Vec<(usize, char)> = new.char_indices().collect();
    if a.len() >= 2_000 || b.len() >= 2_000 || (a.is_empty() && b.is_empty()) {
        return None;
    }
    let mut prefix = 0;
    while prefix < a.len() && prefix < b.len() && a[prefix].1 == b[prefix].1 {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < a.len() - prefix
        && suffix < b.len() - prefix
        && a[a.len() - 1 - suffix].1 == b[b.len() - 1 - suffix].1
    {
        suffix += 1;
    }
    let shared = prefix + suffix;
    if shared == 0 || shared * 3 < a.len().max(b.len()) {
        return None;
    }
    let byte = |chars: &[(usize, char)], text: &str, index: usize| {
        chars.get(index).map_or(text.len(), |(offset, _)| *offset)
    };
    Some((
        byte(&a, old, prefix)..byte(&a, old, a.len() - suffix),
        byte(&b, new, prefix)..byte(&b, new, b.len() - suffix),
    ))
}

/// Facts about a diff that don't depend on which files are collapsed, made off the UI thread.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Presentation {
    /// Side-by-side rows of each hunk, by file then hunk.
    pub split_lines: Vec<Vec<Vec<SplitLine>>>,
    /// The changed part of a replaced line as a byte range, keyed by file, hunk and line.
    pub highlights: HashMap<(usize, usize, usize), Range<usize>>,
    /// The widest line in character cells, a tab counting as four.
    pub max_columns: usize,
    pub max_line_number: usize,
}

/// Longer lines are cut when drawn, so a minified file can't stall drawing.
pub const MAX_DRAWN_LENGTH: usize = 3_000;

impl Presentation {
    pub fn make(diff: &GitDiff) -> Self {
        let mut presentation = Self {
            max_line_number: 1,
            ..Self::default()
        };
        for (file_index, file) in diff.files.iter().enumerate() {
            let mut file_lines = Vec::with_capacity(file.hunks.len());
            for (hunk_index, hunk) in file.hunks.iter().enumerate() {
                presentation.max_line_number = presentation
                    .max_line_number
                    .max(hunk.old_start.saturating_add(hunk.old_count))
                    .max(hunk.new_start.saturating_add(hunk.new_count));
                let lines = &hunk.lines;
                for line in lines {
                    let tabs = line.text.bytes().filter(|byte| *byte == b'\t').count();
                    let columns = line.text.chars().count().min(MAX_DRAWN_LENGTH) + tabs * 3;
                    presentation.max_columns = presentation.max_columns.max(columns);
                }
                let pairs = align(lines);
                for pair in &pairs {
                    let (Some(old), Some(new)) = (pair.before, pair.after) else {
                        continue;
                    };
                    if lines[old].kind != LineKind::Deletion
                        || lines[new].kind != LineKind::Addition
                    {
                        continue;
                    }
                    if let Some((before, after)) =
                        changed_ranges(&lines[old].text, &lines[new].text)
                    {
                        presentation
                            .highlights
                            .insert((file_index, hunk_index, old), before);
                        presentation
                            .highlights
                            .insert((file_index, hunk_index, new), after);
                    }
                }
                file_lines.push(pairs);
            }
            presentation.split_lines.push(file_lines);
        }
        presentation
    }
}

/// A loaded review: a diff from the repository at `root`, or no repository at all.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Review {
    NotRepository,
    Diff { root: PathBuf, diff: GitDiff },
}

/// Decodes `review`'s reply into a diff; parsing runs wherever this is called.
pub fn decode(value: &Value) -> Result<Review> {
    if value["notRepository"] == true {
        return Ok(Review::NotRepository);
    }
    let root = PathBuf::from(value["root"].as_str().context("Missing repository root")?);
    let patch = value["patch"].as_str().context("Missing patch")?;
    let mut stats = Vec::new();
    for stat in value["numstat"].as_array().context("Missing numstat")? {
        stats.push(Numstat {
            path: stat["path"]
                .as_str()
                .context("Missing numstat path")?
                .to_owned(),
            old_path: stat["oldPath"].as_str().map(str::to_owned),
            additions: stat["additions"].as_u64().unwrap_or(0) as usize,
            deletions: stat["deletions"].as_u64().unwrap_or(0) as usize,
            is_binary: stat["binary"] == true,
        });
    }
    let untracked: HashSet<String> = value["untracked"]
        .as_array()
        .context("Missing untracked files")?
        .iter()
        .filter_map(|path| path.as_str().map(str::to_owned))
        .collect();
    let mut diff = if stats.is_empty() {
        GitDiff::default()
    } else {
        assemble(patch, &stats, &untracked)
    };
    diff.base_label = value["baseLabel"].as_str().map(str::to_owned);
    diff.is_truncated |= value["truncated"] == true;
    Ok(Review::Diff { root, diff })
}

fn text(directory: &Path, args: &[&str]) -> Option<String> {
    let bytes = git(directory, args).ok()?;
    let value = String::from_utf8_lossy(&bytes).trim().to_owned();
    (!value.is_empty()).then_some(value)
}

fn ref_exists(directory: &Path, reference: &str) -> bool {
    git(directory, &["show-ref", "--verify", "--quiet", reference]).is_ok()
}

struct BaseRef {
    /// Short name for display, such as `origin/main` or `main`.
    name: String,
    /// Full ref to compare against, such as `refs/remotes/origin/main`.
    comparison: String,
}

/// The branch's base: the base recorded when its worktree was created, then the remote's
/// default branch, then `main` / `master`. A branch may compare with its own remote copy.
fn base_ref(root: &Path, branch: &str, remotes: &[String]) -> Option<BaseRef> {
    let primary = if remotes.iter().any(|remote| remote == "origin") {
        Some("origin")
    } else {
        remotes.first().map(String::as_str)
    };
    let default = text(root, &["symbolic-ref", "refs/remotes/origin/HEAD"])
        .and_then(|value| {
            value
                .strip_prefix("refs/remotes/origin/")
                .map(str::to_owned)
        })
        .filter(|name| !name.is_empty());
    let mut candidates = Vec::new();
    if let Some(configured) = text(
        root,
        &[
            "config",
            "--get",
            &format!("branch.{branch}.coincide-merge-base"),
        ],
    ) {
        candidates.push(configured);
    }
    candidates.extend(default);
    candidates.extend(["main".to_owned(), "master".to_owned()]);
    for candidate in candidates {
        let mut name = candidate.as_str();
        name = name.strip_prefix("refs/heads/").unwrap_or(name);
        name = name.strip_prefix("refs/remotes/").unwrap_or(name);
        let mut name = name.to_owned();
        if let Some(remote) = remotes
            .iter()
            .find(|remote| name.starts_with(&format!("{remote}/")))
        {
            let remote_ref = format!("refs/remotes/{name}");
            if ref_exists(root, &remote_ref) {
                return Some(BaseRef {
                    name,
                    comparison: remote_ref,
                });
            }
            name = name[remote.len() + 1..].to_owned();
        }
        if name.is_empty() {
            continue;
        }
        if let Some(primary) = primary {
            let remote_ref = format!("refs/remotes/{primary}/{name}");
            if ref_exists(root, &remote_ref) {
                return Some(BaseRef {
                    name: format!("{primary}/{name}"),
                    comparison: remote_ref,
                });
            }
        }
        if name == branch {
            continue;
        }
        let local = format!("refs/heads/{name}");
        if ref_exists(root, &local) {
            return Some(BaseRef {
                name,
                comparison: local,
            });
        }
    }
    None
}

fn diff_arguments(ignore_whitespace: bool) -> Vec<&'static str> {
    let mut arguments = vec![
        "-c",
        "core.quotePath=false",
        "diff",
        "--find-renames",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--minimal",
    ];
    if ignore_whitespace {
        arguments.push("--ignore-all-space");
    }
    arguments
}

/// A private copy of the index with untracked files added as intent-to-add, so `git diff`
/// shows them without changing the user's index. Removed when dropped.
struct ReviewIndex {
    directory: PathBuf,
    index: PathBuf,
}

impl Drop for ReviewIndex {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

impl ReviewIndex {
    fn prepare(root: &Path, untracked: &[String]) -> Result<Option<Self>> {
        let deletions = git(
            root,
            &[
                "diff",
                "--cached",
                "--name-only",
                "--diff-filter=D",
                "-z",
                "HEAD",
                "--",
            ],
        )
        .map(|bytes| nul_fields(&String::from_utf8_lossy(&bytes)))
        .unwrap_or_default();
        let staged_deletions: HashSet<&str> = deletions.iter().map(String::as_str).collect();
        let paths: Vec<&str> = untracked
            .iter()
            .map(String::as_str)
            .filter(|path| !staged_deletions.contains(path))
            .collect();
        if paths.is_empty() {
            return Ok(None);
        }
        let current = text(
            root,
            &["rev-parse", "--path-format=absolute", "--git-path", "index"],
        )
        .map(PathBuf::from);
        let directory =
            std::env::temp_dir().join(format!("coincide-review-index-{}", uuid::Uuid::new_v4()));
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder
            .create(&directory)
            .context("Could not prepare the diff.")?;
        let review = Self {
            index: directory.join("index"),
            directory,
        };
        let options = GitOptions {
            index_file: Some(&review.index),
            ..GitOptions::default()
        };
        match current.filter(|path| path.is_file()) {
            Some(current) => copy_index(&current, &review.index)?,
            None => {
                git_with(root, &["read-tree", "--empty"], &options)
                    .context("Could not prepare the diff.")?;
            }
        }
        let config = [
            "-c",
            "core.splitIndex=false",
            "-c",
            "splitIndex.sharedIndexExpire=never",
        ];
        let mut update = config.to_vec();
        update.extend(["update-index", "--no-split-index"]);
        git_with(root, &update, &options).context("Could not prepare the diff.")?;
        let mut input = paths.join("\0");
        input.push('\0');
        let mut add = config.to_vec();
        add.extend([
            "-c",
            "core.preloadIndex=false",
            "add",
            "--intent-to-add",
            "--pathspec-from-file=-",
            "--pathspec-file-nul",
        ]);
        git_with(
            root,
            &add,
            &GitOptions {
                input: Some(input.as_bytes()),
                timeout: Duration::from_secs(60),
                ..options
            },
        )
        .context("Could not prepare the diff.")?;
        Ok(Some(review))
    }
}

/// Copies an index keeping its timestamp, floored to whole seconds, so Git's
/// racy-clean check still works on the copy.
fn copy_index(source: &Path, destination: &Path) -> Result<()> {
    let modified = std::fs::metadata(source)?.modified()?;
    std::fs::copy(source, destination).context("Could not prepare the diff.")?;
    let seconds = modified
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    std::fs::OpenOptions::new()
        .write(true)
        .open(destination)?
        .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(seconds))?;
    Ok(())
}

/// Reads the changes in `scope` for the repository containing `directory`, for `decode`.
pub fn review(directory: &Path, scope: Scope, ignore_whitespace: bool) -> Result<Value> {
    let root = match git(directory, &["rev-parse", "--show-toplevel"]) {
        Ok(bytes) => PathBuf::from(String::from_utf8_lossy(&bytes).trim_end_matches(['\n', '\r'])),
        Err(error) if error.to_string().starts_with("Unable to start git") => return Err(error),
        Err(_) => return Ok(json!({"notRepository":true})),
    };
    let root = root
        .canonicalize()
        .context("The repository folder is unavailable.")?;
    ensure!(
        directory.canonicalize()?.starts_with(&root),
        "The repository root does not contain the working directory"
    );
    let head = text(
        &root,
        &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
    );
    let mut reference = "HEAD".to_owned();
    let mut base_label = Some("HEAD".to_owned());
    if scope == Scope::Branch
        && head.is_some()
        && let Some(branch) = text(&root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
    {
        let remotes: Vec<String> = text(&root, &["remote"])
            .map(|value| value.lines().map(|line| line.trim().to_owned()).collect())
            .unwrap_or_default();
        if let Some(base) = base_ref(&root, &branch, &remotes)
            && let Some(commit) = text(
                &root,
                &["merge-base", "--end-of-options", &base.comparison, "HEAD"],
            )
        {
            reference = commit;
            base_label = Some(base.name);
        }
    }
    if head.is_none() {
        // An unborn HEAD compares with the empty tree of the repository's object format.
        let (bytes, _) = git_with(
            &root,
            &["hash-object", "-t", "tree", "--stdin"],
            &GitOptions {
                input: Some(b""),
                ..GitOptions::default()
            },
        )?;
        reference = String::from_utf8_lossy(&bytes).trim().to_owned();
    }
    let (listing, listing_cut) = git_with(
        &root,
        &["ls-files", "--others", "--exclude-standard", "-z"],
        &GitOptions {
            max_output: MAX_UNTRACKED_LIST_BYTES,
            truncate: true,
            ..GitOptions::default()
        },
    )
    .unwrap_or_default();
    let untracked = nul_fields(&String::from_utf8_lossy(&listing));
    // A listing cut at the read limit has too many files to preview, like one over the count.
    let too_many_untracked = listing_cut || untracked.len() > MAX_UNTRACKED_FILES;
    let review_index = if !untracked.is_empty() && !too_many_untracked {
        ReviewIndex::prepare(&root, &untracked)?
    } else {
        None
    };
    let index = review_index.as_ref().map(|review| review.index.as_path());
    let mut arguments = diff_arguments(ignore_whitespace);
    arguments.extend(["--numstat", "-z", reference.as_str(), "--"]);
    let (numstat, _) = git_with(
        &root,
        &arguments,
        &GitOptions {
            index_file: index,
            timeout: Duration::from_secs(60),
            ..GitOptions::default()
        },
    )
    .context("Could not read the changes.")?;
    let stats = parse_numstat(&String::from_utf8_lossy(&numstat));
    let root_text = external_git_path(&root)?.to_string_lossy().into_owned();
    if stats.is_empty() {
        return Ok(
            json!({"root":root_text,"patch":"","numstat":[],"untracked":[],"baseLabel":base_label,"truncated":false}),
        );
    }
    let mut arguments = diff_arguments(ignore_whitespace);
    arguments.extend(["--patch", reference.as_str(), "--"]);
    let (patch, patch_cut) = git_with(
        &root,
        &arguments,
        &GitOptions {
            index_file: index,
            timeout: Duration::from_secs(120),
            max_output: MAX_PATCH_BYTES + 1,
            truncate: true,
            ..GitOptions::default()
        },
    )
    .context("Could not read the changes.")?;
    drop(review_index);
    let untracked: Vec<&String> = untracked
        .iter()
        .filter(|path| stats.iter().any(|stat| &stat.path == *path))
        .collect();
    Ok(json!({
        "root": root_text,
        "patch": String::from_utf8_lossy(&patch),
        "numstat": stats.iter().map(|stat| json!({
            "path": stat.path,
            "oldPath": stat.old_path,
            "additions": stat.additions,
            "deletions": stat.deletions,
            "binary": stat.is_binary,
        })).collect::<Vec<_>>(),
        "untracked": untracked,
        "baseLabel": base_label,
        "truncated": patch_cut || too_many_untracked,
    }))
}

/// Validates review parameters before an operation is reserved.
pub fn parse_request(p: &Value) -> Result<(Scope, bool)> {
    let scope = match &p["scope"] {
        Value::Null => Scope::Uncommitted,
        Value::String(value) => Scope::parse(value).context("Unknown diff scope")?,
        _ => bail!("Unknown diff scope"),
    };
    let ignore_whitespace = match &p["ignoreWhitespace"] {
        Value::Null => false,
        Value::Bool(value) => *value,
        _ => bail!("ignoreWhitespace must be a boolean"),
    };
    Ok((scope, ignore_whitespace))
}

#[cfg(test)]
#[path = "workspace_diff_tests.rs"]
mod tests;
