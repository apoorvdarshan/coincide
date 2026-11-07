//! Branch names and the plain commit and pull request text used when no agent
//! writes them (Swift BranchNames and GitWriter's fallbacks).

/// Swift's `fallbackSubject`, also the subject of a blank or unusable message.
pub const FALLBACK_SUBJECT: &str = "Update project files";

/// Git config key recording the branch a worktree branch was started from.
pub fn merge_base_config_key(branch: &str) -> String {
    format!("branch.{branch}.coincide-merge-base")
}

fn is_trim(c: char) -> bool {
    matches!(c, '.' | '/' | '_' | '-')
}

/// Lowercase, hyphenated and ref-safe, at most 64 characters.
pub fn sanitize_fragment(raw: &str) -> String {
    let lower = raw.trim().to_lowercase();
    let mut value = String::with_capacity(lower.len());
    let mut replaced = false;
    for c in lower.chars().filter(|c| !matches!(c, '\'' | '"' | '`')) {
        if c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '/' | '_' | '-') {
            value.push(c);
            replaced = false;
        } else if !replaced {
            value.push('-');
            replaced = true;
        }
    }
    let mut collapsed = String::with_capacity(value.len());
    for c in value.chars() {
        if matches!(c, '/' | '-') && collapsed.ends_with(c) {
            continue;
        }
        collapsed.push(c);
    }
    let trimmed = collapsed.trim_matches(is_trim);
    let limited: String = trimmed.chars().take(64).collect();
    let limited = limited.trim_end_matches(is_trim);
    if limited.is_empty() {
        "update".into()
    } else {
        limited.into()
    }
}

/// `feature/<fragment>` unless the fragment already has a namespace.
pub fn feature_branch_name(raw: &str) -> String {
    let fragment = sanitize_fragment(raw);
    if fragment.contains('/') {
        fragment
    } else {
        format!("feature/{fragment}")
    }
}

/// Whitespace becomes hyphens; anything else is left to `git check-ref-format`.
pub fn sanitize_new_ref_name(raw: &str) -> String {
    let mut name = String::new();
    let mut gap = false;
    for c in raw.trim().chars() {
        if matches!(c, ' ' | '\t' | '\n' | '\r' | '\u{0B}' | '\u{0C}') {
            if !gap {
                name.push('-');
            }
            gap = true;
        } else {
            name.push(c);
            gap = false;
        }
    }
    name
}

/// `origin/feature/x` → `feature/x`.
pub fn local_name_from_remote_ref(name: &str) -> String {
    match name.split_once('/') {
        Some((remote, rest)) if !remote.is_empty() && !rest.is_empty() => rest.into(),
        _ => name.into(),
    }
}

/// Picks `preferred` or the first `-2`, `-3`… variant no existing branch (or branch
/// namespace) uses.
pub fn available_feature_branch_name(preferred: &str, existing: &[String]) -> String {
    let names: Vec<String> = existing.iter().map(|name| name.to_lowercase()).collect();
    let preferred = feature_branch_name(preferred);
    let parts: Vec<&str> = preferred.split('/').filter(|p| !p.is_empty()).collect();
    let mut resolved = String::new();
    for (index, part) in parts.iter().enumerate() {
        let base = if resolved.is_empty() {
            (*part).to_owned()
        } else {
            format!("{resolved}/{part}")
        };
        let mut candidate = base.clone();
        let mut suffix = 2;
        while names.contains(&candidate)
            || (index == parts.len() - 1
                && names
                    .iter()
                    .any(|name| name.starts_with(&format!("{candidate}/"))))
        {
            candidate = format!("{base}-{suffix}");
            suffix += 1;
        }
        resolved = candidate;
    }
    resolved
}

/// A throwaway name for a new worktree, renamed once the thread's first message arrives.
pub fn temporary_worktree_branch(prefix: &str) -> String {
    let token = uuid::Uuid::new_v4().simple().to_string();
    format!("{prefix}{}", &token[..8])
}

/// `prefix/<token>` becomes `prefix-<token>` when a branch named `prefix` blocks nested refs.
pub fn flattened_temporary_branch(branch: &str, prefix: &str) -> String {
    let base = prefix.strip_suffix('/').unwrap_or(prefix);
    let token: String = {
        let chars: Vec<char> = branch.chars().collect();
        chars[chars.len().saturating_sub(8)..].iter().collect()
    };
    format!("{base}-{token}")
}

fn is_token(value: &str) -> bool {
    value.len() == 8
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub fn is_temporary_worktree_branch(branch: &str, prefix: &str) -> bool {
    let base = prefix.strip_suffix('/').unwrap_or(prefix);
    if base.is_empty() {
        return is_token(branch);
    }
    branch.strip_prefix(prefix).is_some_and(is_token)
        || branch
            .strip_prefix(base)
            .and_then(|rest| rest.strip_prefix('-'))
            .is_some_and(is_token)
}

const FILLER_WORDS: &[&str] = &[
    "a", "an", "the", "please", "pls", "can", "could", "would", "you", "i", "we", "me", "us",
    "lets", "let's", "kindly", "just", "hey", "hi",
];

/// A short branch name describing a request, such as `coincide/fix-login-redirect`.
pub fn descriptive_branch(message: &str, prefix: &str) -> String {
    let first = message.lines().next().unwrap_or(message).to_lowercase();
    let mut fragment = String::new();
    for word in first
        .split(|c: char| !c.is_alphanumeric() && c != '\'')
        .filter(|word| !word.is_empty() && !FILLER_WORDS.contains(word))
        .take(5)
    {
        let candidate = if fragment.is_empty() {
            word.to_owned()
        } else {
            format!("{fragment}-{word}")
        };
        if candidate.chars().count() > 40 {
            break;
        }
        fragment = candidate;
    }
    let sanitized = sanitize_fragment(if fragment.is_empty() {
        "update"
    } else {
        &fragment
    })
    .replace('/', "-");
    format!("{prefix}{sanitized}")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommitMessage {
    pub subject: String,
    pub body: String,
    /// A branch fragment for "Commit on New Branch", when one was suggested.
    pub branch: Option<String>,
}

pub fn sanitized_commit_message(subject: &str, body: &str, branch: Option<&str>) -> CommitMessage {
    let first = subject.trim().lines().next().unwrap_or("").trim();
    let cleaned = first.trim_end_matches('.').trim();
    let cleaned: String = cleaned.chars().take(72).collect();
    let cleaned = cleaned.trim();
    CommitMessage {
        subject: if cleaned.is_empty() {
            FALLBACK_SUBJECT.into()
        } else {
            cleaned.into()
        },
        body: body.trim().into(),
        branch: branch
            .map(str::trim)
            .filter(|branch| !branch.is_empty())
            .map(str::to_owned),
    }
}

fn file_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// A message built from `git diff --cached --name-status`.
pub fn fallback_commit_message(summary: &str) -> CommitMessage {
    let entries: Vec<(&str, String)> = summary
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            let code = fields.first()?.chars().next()?;
            if fields.len() < 2 {
                return None;
            }
            Some(match code {
                'A' => ("Add", format!("Add {}", file_name(fields[1]))),
                'D' => ("Remove", format!("Remove {}", file_name(fields[1]))),
                'R' if fields.len() >= 3 => (
                    "Rename",
                    format!(
                        "Rename {} to {}",
                        file_name(fields[1]),
                        file_name(fields[2])
                    ),
                ),
                _ => (
                    "Update",
                    format!("Update {}", file_name(fields.last().unwrap_or(&fields[1]))),
                ),
            })
        })
        .collect();
    match entries.as_slice() {
        [] => CommitMessage {
            subject: FALLBACK_SUBJECT.into(),
            body: String::new(),
            branch: None,
        },
        [(_, only)] => sanitized_commit_message(only, "", None),
        _ => {
            let verb = if entries.iter().all(|(verb, _)| *verb == entries[0].0) {
                entries[0].0
            } else {
                "Update"
            };
            let mut body = entries
                .iter()
                .take(20)
                .map(|(_, description)| format!("- {description}"))
                .collect::<Vec<_>>()
                .join("\n");
            if entries.len() > 20 {
                body.push_str("\n- …");
            }
            CommitMessage {
                subject: format!("{verb} {} files", entries.len()),
                body,
                branch: None,
            }
        }
    }
}

/// `Subject\n\nBody` typed by the user, or None when blank.
pub fn custom_commit_message(raw: Option<&str>) -> Option<CommitMessage> {
    let normalized = raw?.replace("\r\n", "\n");
    let normalized = normalized.trim();
    if normalized.is_empty() {
        return None;
    }
    let (subject, body) = normalized.split_once('\n').unwrap_or((normalized, ""));
    let subject = subject.trim();
    if subject.is_empty() {
        return None;
    }
    Some(CommitMessage {
        subject: subject.into(),
        body: body.trim().into(),
        branch: None,
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PullRequestContent {
    pub title: String,
    pub body: String,
}

/// Title from the only commit or the branch name, body from the commit list.
pub fn fallback_pull_request(head_branch: &str, commits: &str) -> PullRequestContent {
    let subjects: Vec<&str> = commits
        .lines()
        .filter_map(|line| line.split_once(' ').map(|(_, subject)| subject))
        .collect();
    let title = if let [only] = subjects.as_slice() {
        (*only).to_owned()
    } else {
        let fragment = head_branch.rsplit('/').next().unwrap_or(head_branch);
        let mut words = String::new();
        let mut gap = false;
        for c in fragment.chars() {
            if matches!(c, '-' | '_') {
                if !gap {
                    words.push(' ');
                }
                gap = true;
            } else {
                words.push(c);
                gap = false;
            }
        }
        let words = words.trim();
        let mut chars = words.chars();
        match chars.next() {
            None => "Update project changes".into(),
            Some(first) => first.to_uppercase().chain(chars).collect(),
        }
    };
    let summary = if subjects.is_empty() {
        "- Update project changes".to_owned()
    } else {
        subjects
            .iter()
            .take(30)
            .map(|subject| format!("- {subject}"))
            .collect::<Vec<_>>()
            .join("\n")
    };
    PullRequestContent {
        title,
        body: format!("## Summary\n{summary}\n\n## Testing\n- Not run"),
    }
}
