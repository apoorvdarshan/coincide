//! Composer completions for `/` commands, `$` skills and `#` pull requests (Swift's
//! `ComposerTrigger`, `ComposerCommand`, `ProviderCommand` and `PullRequestMention`). The
//! commands and skills are the ones agent sessions reported; nothing here launches an agent,
//! and only `github_repository` runs a process (local `git remote`, never the network).
use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashMap, VecDeque},
    ops::Range,
    path::Path,
};

/// What the word before the caret asks for. `@` paths belong to the file picker.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TriggerKind {
    Command,
    /// The agent's skills (T3 Code's `$` picker).
    Skill,
    /// The repository's open pull requests (T3 Code's `#` picker).
    PullRequest,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Trigger {
    pub kind: TriggerKind,
    /// What follows the `/`, `$` or `#`.
    pub query: String,
    /// Byte range of the whole word, its `/`, `$` or `#` included.
    pub range: Range<usize>,
}

/// Finds the trigger in the word that ends at `cursor`, a byte offset into `text`.
pub fn detect(text: &str, cursor: usize) -> Option<Trigger> {
    if cursor > text.len() || !text.is_char_boundary(cursor) {
        return None;
    }
    let start = text[..cursor]
        .char_indices()
        .rev()
        .find(|(_, c)| c.is_whitespace())
        .map_or(0, |(index, c)| index + c.len_utf8());
    let mut chars = text[start..cursor].chars();
    let token = chars.next()?;
    let query = chars.as_str();
    let kind = match token {
        '/' => {
            // A second slash anywhere in the word makes it a path such as /usr/bin, not a command.
            let end = text[cursor..]
                .find(char::is_whitespace)
                .map_or(text.len(), |offset| cursor + offset);
            if text[start + 1..end].contains('/') {
                return None;
            }
            TriggerKind::Command
        }
        // An amount such as $20 is not a skill.
        '$' if query.chars().next().is_some_and(char::is_numeric) => return None,
        '$' => TriggerKind::Skill,
        // A number or a word (a letter or digit, then letters, digits, `_` and `-`), as in T3
        // Code; `##` and `#!` are left alone.
        '#' => {
            let mut rest = query.chars();
            if let Some(first) = rest.next()
                && (!first.is_alphanumeric()
                    || !rest.all(|c| c.is_alphanumeric() || c == '_' || c == '-'))
            {
                return None;
            }
            TriggerKind::PullRequest
        }
        _ => return None,
    };
    Some(Trigger {
        kind,
        query: query.to_owned(),
        range: start..cursor,
    })
}

/// Replaces `range` with `insertion`. An insertion ending in a space swallows one space
/// already after the word, so completing in the middle of a line leaves no double space.
/// Returns the new text and the byte range that was replaced.
pub fn replacement(text: &str, range: Range<usize>, insertion: &str) -> (String, Range<usize>) {
    let mut range = range;
    if insertion.ends_with(' ') && text[range.end..].starts_with(' ') {
        range.end += 1;
    }
    let mut next = String::with_capacity(text.len() + insertion.len());
    next.push_str(&text[..range.start]);
    next.push_str(insertion);
    next.push_str(&text[range.end..]);
    (next, range)
}

/// Commands typed as `/name` in the composer. They change the thread instead of being sent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BuiltIn {
    Model,
    Plan,
    Build,
    /// Shows the selected agent's subscription limits (T3 Code's `/usage-limits`).
    UsageLimits,
    /// Continues the thread with another agent, such as `/codex`.
    Agent {
        provider: String,
        display_name: String,
    },
}
impl BuiltIn {
    /// The built-in commands followed by one per agent the user can switch to. `/usage-limits`
    /// is offered when the selected agent reported its limits.
    pub fn available(agents: &[(String, String)], usage_limits: bool) -> Vec<Self> {
        let mut commands = vec![Self::Model, Self::Plan, Self::Build];
        if usage_limits {
            commands.push(Self::UsageLimits);
        }
        commands.extend(agents.iter().map(|(provider, display_name)| Self::Agent {
            provider: provider.clone(),
            display_name: display_name.clone(),
        }));
        commands
    }
    pub fn name(&self) -> &str {
        match self {
            Self::Model => "model",
            Self::Plan => "plan",
            Self::Build => "build",
            Self::UsageLimits => "usage-limits",
            Self::Agent { provider, .. } => provider,
        }
    }
    pub fn title(&self) -> String {
        format!("/{}", self.name())
    }
    pub fn summary(&self) -> String {
        match self {
            Self::Model => "Switch the agent or model for this thread".into(),
            Self::Plan => "Switch this thread into plan mode".into(),
            Self::Build => "Switch this thread back to build mode".into(),
            Self::UsageLimits => "Show this agent's usage limits".into(),
            Self::Agent { display_name, .. } => {
                format!("Continue this thread with {display_name}")
            }
        }
    }
    /// The command's name plus aliases; `/default` is T3 Code's name for build mode.
    fn names(&self) -> Vec<&str> {
        match self {
            Self::Build => vec![self.name(), "default"],
            _ => vec![self.name()],
        }
    }
    /// Commands matching `query`, best match first.
    pub fn matching(query: &str, commands: &[Self]) -> Vec<Self> {
        let query = query.to_lowercase();
        if query.is_empty() {
            return commands.to_vec();
        }
        let mut ranked = commands
            .iter()
            .enumerate()
            .filter_map(|(index, command)| {
                let names = command.names();
                let rank = if names.contains(&query.as_str()) {
                    0
                } else if names.iter().any(|name| name.starts_with(&query)) {
                    1
                } else if names.iter().any(|name| name.contains(&query)) {
                    2
                } else if command.summary().to_lowercase().contains(&query) {
                    3
                } else {
                    return None;
                };
                Some((rank, index, command))
            })
            .collect::<Vec<_>>();
        ranked.sort_by_key(|(rank, index, _)| (*rank, *index));
        ranked
            .into_iter()
            .map(|(_, _, command)| command.clone())
            .collect()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CommandKind {
    Command,
    /// Offered under `$` as well as `/`. Claude Code runs skills and custom commands alike as
    /// `/name`.
    Skill,
}

/// Something the user can run in an agent: a slash command such as `/compact` or one they
/// added, or a skill.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCommand {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// What the command takes after its name, such as `[file]`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub argument_hint: Option<String>,
    pub kind: CommandKind,
    /// Part of the agent itself, rather than added by the user, a project or a plugin.
    #[serde(default)]
    pub is_built_in: bool,
    /// The agent runs it as `/name`. Codex's skills run only as `$name`.
    pub is_slash_command: bool,
}
const MAX_COMMANDS: usize = 1000;
fn bounded(value: &Value, limit: usize) -> Option<String> {
    let text = value.as_str()?.trim();
    (!text.is_empty()).then(|| text.chars().take(limit).collect())
}
fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 256 && !name.chars().any(|c| c.is_control())
}
impl ProviderCommand {
    /// Claude's `initialize` command list, deduplicated by name. Claude's own commands are
    /// built in; the rest (skills, custom and plugin commands) are offered as skills too.
    pub fn from_claude(entries: &[Value]) -> Vec<Self> {
        let mut seen = std::collections::HashSet::new();
        entries
            .iter()
            .filter_map(|entry| {
                let name = entry["name"].as_str()?.trim();
                if !valid_name(name) || !seen.insert(name.to_lowercase()) {
                    return None;
                }
                let built_in = entry["builtin"] == true;
                Some(Self {
                    name: name.into(),
                    description: bounded(&entry["description"], 1024),
                    argument_hint: bounded(&entry["argumentHint"], 256),
                    kind: if built_in {
                        CommandKind::Command
                    } else {
                        CommandKind::Skill
                    },
                    is_built_in: built_in,
                    is_slash_command: true,
                })
            })
            .take(MAX_COMMANDS)
            .collect()
    }
    /// An ACP agent's `available_commands_update`.
    pub fn from_acp(entries: &[Value]) -> Vec<Self> {
        let mut seen = std::collections::HashSet::new();
        entries
            .iter()
            .filter_map(|entry| {
                let name = entry["name"].as_str()?;
                if !valid_name(name) || !seen.insert(name.to_owned()) {
                    return None;
                }
                Some(Self {
                    name: name.into(),
                    description: bounded(&entry["description"], 1024),
                    argument_hint: None,
                    kind: CommandKind::Command,
                    is_built_in: false,
                    is_slash_command: true,
                })
            })
            .take(MAX_COMMANDS)
            .collect()
    }
    /// Commands matching a query, best first: name, name prefix, name containing it, then
    /// description.
    pub fn matching<'a>(query: &str, commands: &'a [Self]) -> Vec<&'a Self> {
        let query = query.to_lowercase();
        if query.is_empty() {
            return commands.iter().collect();
        }
        let mut ranked = commands
            .iter()
            .enumerate()
            .filter_map(|(index, command)| {
                let name = command.name.to_lowercase();
                let rank = if name == query {
                    0
                } else if name.starts_with(&query)
                    || name
                        .rsplit(':')
                        .next()
                        .is_some_and(|last| last.starts_with(&query))
                {
                    1
                } else if name.contains(&query) {
                    2
                } else if command
                    .description
                    .as_ref()
                    .is_some_and(|text| text.to_lowercase().contains(&query))
                {
                    3
                } else {
                    return None;
                };
                Some((rank, index, command))
            })
            .collect::<Vec<_>>();
        ranked.sort_by_key(|(rank, index, _)| (*rank, *index));
        ranked.into_iter().map(|(_, _, command)| command).collect()
    }
}

/// The commands a `provider/event` frame reports: Claude's successful `initialize` response
/// (when it lists any) or an ACP `available_commands_update`, which replaces the list.
pub fn reported_commands(params: &Value) -> Option<Vec<ProviderCommand>> {
    let frame = &params["providerFrame"];
    if frame["type"] == "control_response"
        && frame["response"]["request_id"] == "coincide-initialize"
        && frame["response"]["subtype"] == "success"
    {
        let commands =
            ProviderCommand::from_claude(frame["response"]["response"]["commands"].as_array()?);
        return (!commands.is_empty()).then_some(commands);
    }
    let update = &frame["params"]["update"];
    if frame["method"] == "session/update" && update["sessionUpdate"] == "available_commands_update"
    {
        return Some(ProviderCommand::from_acp(
            update["availableCommands"].as_array()?,
        ));
    }
    None
}

/// What each thread's sessions reported, and per agent, account and folder what it reported
/// last, for threads that have not run it yet. In memory only, as in the Swift app; the
/// fallback never crosses folders, so one project's skills are not offered in another.
#[derive(Default)]
pub struct ReportedCommands {
    sessions: HashMap<String, HashMap<String, Vec<ProviderCommand>>>,
    session_order: VecDeque<String>,
    folders: HashMap<(String, String, String), Vec<ProviderCommand>>,
    folder_order: VecDeque<(String, String, String)>,
}
const MAX_THREADS: usize = 256;
const MAX_FOLDERS: usize = 64;
fn account_key(account: &Value) -> String {
    match account.as_str() {
        Some(id) if !id.is_empty() => id.into(),
        _ => "default".into(),
    }
}
impl ReportedCommands {
    pub fn record(
        &mut self,
        thread: &str,
        provider: &str,
        account: &Value,
        folder: Option<&Path>,
        commands: Vec<ProviderCommand>,
    ) {
        if !self.sessions.contains_key(thread) {
            if self.session_order.len() >= MAX_THREADS
                && let Some(oldest) = self.session_order.pop_front()
            {
                self.sessions.remove(&oldest);
            }
            self.session_order.push_back(thread.into());
        }
        if let Some(folder) = folder {
            let key = (
                provider.to_owned(),
                account_key(account),
                folder.to_string_lossy().into_owned(),
            );
            if !self.folders.contains_key(&key) {
                if self.folder_order.len() >= MAX_FOLDERS
                    && let Some(oldest) = self.folder_order.pop_front()
                {
                    self.folders.remove(&oldest);
                }
                self.folder_order.push_back(key.clone());
            }
            self.folders.insert(key, commands.clone());
        }
        self.sessions
            .entry(thread.into())
            .or_default()
            .insert(provider.into(), commands);
    }
    /// The commands and skills `provider` offers in the thread: what its session there
    /// reported, else what it last reported in the same folder with the same account.
    pub fn lookup(
        &self,
        thread: &str,
        provider: &str,
        account: &Value,
        folder: Option<&Path>,
    ) -> (&[ProviderCommand], &'static str) {
        if let Some(commands) = self
            .sessions
            .get(thread)
            .and_then(|providers| providers.get(provider))
        {
            return (commands, "session");
        }
        if let Some(commands) = folder.and_then(|folder| {
            self.folders.get(&(
                provider.to_owned(),
                account_key(account),
                folder.to_string_lossy().into_owned(),
            ))
        }) {
            return (commands, "folder");
        }
        (&[], "none")
    }
}

/// An open pull request as `github.pr.list` reports it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PullRequest {
    pub number: u64,
    pub title: String,
    pub url: String,
    /// The author's login; none for a deleted account or an older list.
    pub author: Option<String>,
    pub head_branch: String,
    pub is_draft: bool,
    pub updated_at: Option<String>,
}
impl PullRequest {
    pub fn from_list(value: &Value) -> Option<Self> {
        Some(Self {
            number: value["number"].as_u64().filter(|number| *number > 0)?,
            title: value["title"].as_str()?.into(),
            url: value["url"].as_str()?.into(),
            author: value["author"]["login"].as_str().map(str::to_owned),
            head_branch: value["headRefName"].as_str().unwrap_or_default().into(),
            is_draft: value["isDraft"] == true,
            updated_at: value["updatedAt"].as_str().map(str::to_owned),
        })
    }
    /// The pull requests the `#` picker lists for `query`, the text after `#`. Digits match
    /// the number, anything else the title, branch or author; the closest matches come
    /// first, then the most recently updated.
    pub fn matching<'a>(query: &str, pulls: &'a [Self], limit: usize) -> Vec<&'a Self> {
        let query = query.trim_matches(|c| c == ' ' || c == '\t');
        let number = !query.is_empty() && query.bytes().all(|b| b.is_ascii_digit());
        let folded = fold(query);
        let mut ranked = pulls
            .iter()
            .filter_map(|pull| {
                let rank = if query.is_empty() {
                    0
                } else if number {
                    let digits = pull.number.to_string();
                    if digits == query {
                        0
                    } else if digits.starts_with(query) {
                        1
                    } else if digits.contains(query) {
                        2
                    } else {
                        return None;
                    }
                } else {
                    let title = fold(&pull.title);
                    if title.starts_with(&folded) {
                        0
                    } else if title.contains(&folded) {
                        1
                    } else if fold(&pull.head_branch).contains(&folded)
                        || pull
                            .author
                            .as_deref()
                            .is_some_and(|author| fold(author).contains(&folded))
                    {
                        2
                    } else {
                        return None;
                    }
                };
                Some((rank, pull))
            })
            .collect::<Vec<_>>();
        // ISO 8601 timestamps from GitHub sort as text; a missing one counts as oldest.
        ranked.sort_by(|(left_rank, left), (right_rank, right)| {
            left_rank
                .cmp(right_rank)
                .then_with(|| right.updated_at.cmp(&left.updated_at))
                .then_with(|| right.number.cmp(&left.number))
        });
        ranked
            .into_iter()
            .take(limit)
            .map(|(_, pull)| pull)
            .collect()
    }
    /// A durable reference, kept in the user's message rather than in an in-memory
    /// completion cache.
    pub fn markdown(&self) -> Option<String> {
        let url = url::Url::parse(&self.url).ok()?;
        if !matches!(url.scheme(), "https" | "http")
            || url.host_str().is_none_or(str::is_empty)
            || !url.username().is_empty()
            || url.password().is_some()
        {
            return None;
        }
        let mut destination = String::new();
        for c in url.as_str().chars() {
            match c {
                '(' => destination.push_str("%28"),
                ')' => destination.push_str("%29"),
                '<' => destination.push_str("%3C"),
                '>' => destination.push_str("%3E"),
                '\\' => destination.push_str("%5C"),
                c => destination.push(c),
            }
        }
        Some(format!("[#{}]({destination})", self.number))
    }
}

/// Case- and diacritic-insensitive form for matching, like Foundation's comparison options:
/// combining marks are dropped and precomposed Latin letters lose their accents.
fn fold(text: &str) -> String {
    const ACCENTED: [(&str, char); 19] = [
        ("àáâãäåāăą", 'a'),
        ("çćĉċč", 'c'),
        ("ďđ", 'd'),
        ("èéêëēĕėęě", 'e'),
        ("ĝğġģ", 'g'),
        ("ĥħ", 'h'),
        ("ìíîïĩīĭįı", 'i'),
        ("ĵ", 'j'),
        ("ķ", 'k'),
        ("ĺļľŀł", 'l'),
        ("ñńņňŉ", 'n'),
        ("òóôõöøōŏő", 'o'),
        ("ŕŗř", 'r'),
        ("śŝşš", 's'),
        ("ţťŧ", 't'),
        ("ùúûüũūŭůűų", 'u'),
        ("ŵ", 'w'),
        ("ýÿŷ", 'y'),
        ("źżž", 'z'),
    ];
    text.chars()
        .flat_map(char::to_lowercase)
        .filter(|c| {
            !matches!(c, '\u{0300}'..='\u{036f}' | '\u{1ab0}'..='\u{1aff}'
                | '\u{1dc0}'..='\u{1dff}' | '\u{20d0}'..='\u{20ff}' | '\u{fe20}'..='\u{fe2f}')
        })
        .map(|c| {
            ACCENTED
                .iter()
                .find(|(letters, _)| letters.contains(c))
                .map_or(c, |(_, base)| *base)
        })
        .collect()
}

/// `owner/name` for a remote on github.com, the only host the read-only GitHub service
/// queries; nil for other hosts, local paths and malformed addresses.
pub fn github_repository_from_remote(remote: &str) -> Option<String> {
    let remote = remote.trim();
    if remote.is_empty() || remote.contains(['\n', '\r']) {
        return None;
    }
    let (host, path) = if let Some((scheme, rest)) = remote.split_once("://") {
        if !matches!(
            scheme.to_ascii_lowercase().as_str(),
            "https" | "http" | "ssh" | "git+ssh" | "ssh+git" | "git"
        ) {
            return None;
        }
        let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let authority = &rest[..authority_end];
        // Credentials end at the last `@`; a password may contain an escaped one.
        let authority = authority
            .rsplit_once('@')
            .map_or(authority, |(_, host)| host);
        let path = &rest[authority_end..];
        (authority, path.split(['?', '#']).next().unwrap_or_default())
    } else {
        // `[user@]host:path`, which git reads as SSH when a colon comes before any slash.
        let (prefix, path) = remote.split_once(':')?;
        if prefix.is_empty() || prefix.contains(['/', '\\']) {
            return None;
        }
        let host = prefix.rsplit_once('@').map_or(prefix, |(_, host)| host);
        // A userless one-letter prefix is a Windows drive, not a host.
        if host.len() == 1 && !prefix.contains('@') {
            return None;
        }
        (host, path)
    };
    let hostname = match host.rsplit_once(':') {
        Some((name, port)) if port.bytes().all(|b| b.is_ascii_digit()) => name,
        _ => host,
    };
    if !hostname.eq_ignore_ascii_case("github.com") {
        return None;
    }
    let segments = path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>();
    let [owner, name] = segments.as_slice() else {
        return None;
    };
    let name = name.strip_suffix(".git").unwrap_or(name);
    let valid = |part: &str| {
        !part.is_empty()
            && part.len() <= 100
            && part != "."
            && part != ".."
            && part.as_bytes()[0].is_ascii_alphanumeric()
            && part
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    };
    (valid(owner) && valid(name)).then(|| format!("{owner}/{name}"))
}

/// The GitHub repository a folder's primary remote (`origin`, else the first) names, read
/// with local `git remote` only. Nil outside a repository, without a remote, or off github.com.
pub fn github_repository(root: &Path) -> Result<Option<String>> {
    let Ok(remotes) = crate::workspace::git(root, &["remote"]) else {
        return Ok(None);
    };
    let remotes = String::from_utf8_lossy(&remotes);
    let names = remotes
        .lines()
        .map(str::trim)
        .filter(|name| !name.is_empty() && !name.starts_with('-'))
        .collect::<Vec<_>>();
    let Some(name) = names
        .iter()
        .find(|name| **name == "origin")
        .or(names.first())
    else {
        return Ok(None);
    };
    let Ok(url) = crate::workspace::git(root, &["remote", "get-url", "--", name]) else {
        return Ok(None);
    };
    Ok(github_repository_from_remote(&String::from_utf8_lossy(
        &url,
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn trigger(text: &str) -> Option<(TriggerKind, String, String)> {
        detect(text, text.len()).map(|t| (t.kind, t.query, text[t.range].to_owned()))
    }

    #[test]
    fn detects_swift_triggers_in_the_word_before_the_caret() {
        assert_eq!(
            trigger("/pl"),
            Some((TriggerKind::Command, "pl".into(), "/pl".into()))
        );
        assert_eq!(
            trigger("fix café /"),
            Some((TriggerKind::Command, String::new(), "/".into()))
        );
        assert_eq!(
            trigger("use $rev"),
            Some((TriggerKind::Skill, "rev".into(), "$rev".into()))
        );
        assert_eq!(
            trigger("see #12"),
            Some((TriggerKind::PullRequest, "12".into(), "#12".into()))
        );
        assert_eq!(
            trigger("#"),
            Some((TriggerKind::PullRequest, String::new(), "#".into()))
        );
        assert_eq!(
            trigger("#fix-login_2"),
            Some((
                TriggerKind::PullRequest,
                "fix-login_2".into(),
                "#fix-login_2".into()
            ))
        );
        assert_eq!(
            trigger("#中文"),
            Some((TriggerKind::PullRequest, "中文".into(), "#中文".into()))
        );
        for text in [
            "",
            "plan",
            "a /usr/bin",
            "/model/x",
            "$20",
            "$½",
            "##",
            "#!",
            "#-x",
            "#a.b",
            "@src",
            "mail me@x",
            "trailing ",
        ] {
            assert_eq!(trigger(text), None, "{text}");
        }
        // The rest of the word after the caret counts for the path check.
        let text = "/us/bin";
        assert_eq!(detect(text, 3), None);
        assert_eq!(detect("/pl an", 3).map(|t| t.range), Some(0..3));
        // Off a character boundary or past the end, nothing is detected.
        assert_eq!(detect("é/", 1), None);
        assert_eq!(detect("/", 2), None);
        // A newline ends the word like a space.
        assert_eq!(trigger("line\n/bu").map(|t| t.2), Some("/bu".into()));
    }

    #[test]
    fn replacement_swallows_one_following_space_only_for_spaced_insertions() {
        assert_eq!(
            replacement("a /pl b", 2..5, "/plan "),
            ("a /plan b".into(), 2..6)
        );
        assert_eq!(replacement("a /pl  b", 2..5, "$x ").0, "a $x  b");
        assert_eq!(replacement("a /pl b", 2..5, "").0, "a  b");
        assert_eq!(replacement("👩🏽‍💻 #1", 16..18, "[#1](u) ").0, "👩🏽‍💻 [#1](u) ");
    }

    fn agents() -> Vec<(String, String)> {
        vec![
            ("claude".into(), "Claude Code".into()),
            ("cursor".into(), "Cursor".into()),
        ]
    }

    #[test]
    fn built_in_catalog_order_wording_and_ranking_match_swift() {
        let all = BuiltIn::available(&agents(), false);
        assert_eq!(
            all.iter().map(BuiltIn::title).collect::<Vec<_>>(),
            ["/model", "/plan", "/build", "/claude", "/cursor"]
        );
        let with_limits = BuiltIn::available(&[], true);
        assert_eq!(with_limits[3], BuiltIn::UsageLimits);
        assert_eq!(with_limits[3].summary(), "Show this agent's usage limits");
        assert_eq!(all[3].summary(), "Continue this thread with Claude Code");
        assert_eq!(BuiltIn::matching("", &all), all);
        // Exact alias first, then prefixes in catalog order, then summary text.
        assert_eq!(BuiltIn::matching("DEFAULT", &all), vec![BuiltIn::Build]);
        // Names first; "Switch" in the mode summaries matches too.
        assert_eq!(
            BuiltIn::matching("c", &all)
                .iter()
                .map(BuiltIn::name)
                .collect::<Vec<_>>(),
            ["claude", "cursor", "model", "plan", "build"]
        );
        assert_eq!(
            BuiltIn::matching("mode", &all)
                .iter()
                .map(BuiltIn::name)
                .collect::<Vec<_>>(),
            ["model", "plan", "build"]
        );
        assert_eq!(
            BuiltIn::matching("thread", &all).len(),
            all.len(),
            "every summary names the thread"
        );
        assert!(BuiltIn::matching("zzz", &all).is_empty());
    }

    #[test]
    fn claude_and_acp_reports_parse_dedupe_and_bound_commands() {
        let claude = json!({"provider":"claude","providerFrame":{"type":"control_response","response":{"request_id":"coincide-initialize","subtype":"success","response":{"commands":[
            {"name":"compact","description":"Clear history","builtin":true},
            {"name":" review ","description":"  Review a PR ","argumentHint":"[pr]"},
            {"name":"Review"},
            {"name":""},
            {"name":"bad\nname"},
            {"description":"no name"}
        ]}}}});
        let commands = reported_commands(&claude).unwrap();
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].kind, CommandKind::Command);
        assert!(commands[0].is_built_in);
        assert_eq!(commands[1].name, "review");
        assert_eq!(commands[1].description.as_deref(), Some("Review a PR"));
        assert_eq!(commands[1].argument_hint.as_deref(), Some("[pr]"));
        assert_eq!(commands[1].kind, CommandKind::Skill);
        assert!(commands.iter().all(|command| command.is_slash_command));
        // A failed or empty initialize, or another response, reports nothing.
        let mut empty = claude.clone();
        empty["providerFrame"]["response"]["response"]["commands"] = json!([]);
        assert_eq!(reported_commands(&empty), None);
        let mut failed = claude.clone();
        failed["providerFrame"]["response"]["subtype"] = json!("error");
        assert_eq!(reported_commands(&failed), None);
        let mut other = claude;
        other["providerFrame"]["response"]["request_id"] = json!("coincide-interrupt");
        assert_eq!(reported_commands(&other), None);

        let acp = json!({"provider":"cursor","providerFrame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[
            {"name":"web","description":"Search the web","input":{"hint":"query"}},
            {"name":"web"},
            {"name":"plan","description":""}
        ]}}}});
        let commands = reported_commands(&acp).unwrap();
        assert_eq!(
            commands.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
            ["web", "plan"]
        );
        assert_eq!(commands[1].description, None);
        // An ACP update replaces the list, even with nothing in it.
        let mut cleared = acp.clone();
        cleared["providerFrame"]["params"]["update"]["availableCommands"] = json!([]);
        assert_eq!(reported_commands(&cleared), Some(vec![]));
        let mut message = acp;
        message["providerFrame"]["params"]["update"]["sessionUpdate"] =
            json!("agent_message_chunk");
        assert_eq!(reported_commands(&message), None);
    }

    fn command(name: &str, description: Option<&str>) -> ProviderCommand {
        ProviderCommand {
            name: name.into(),
            description: description.map(str::to_owned),
            argument_hint: None,
            kind: CommandKind::Skill,
            is_built_in: false,
            is_slash_command: true,
        }
    }

    #[test]
    fn provider_command_ranking_matches_swift_including_plugin_suffixes() {
        let commands = vec![
            command("plugin:review", None),
            command("rev", None),
            command("prereview", None),
            command("other", Some("Review changes")),
            command("review", None),
        ];
        assert_eq!(
            ProviderCommand::matching("REVIEW", &commands)
                .iter()
                .map(|c| c.name.as_str())
                .collect::<Vec<_>>(),
            ["review", "plugin:review", "prereview", "other"]
        );
        assert_eq!(ProviderCommand::matching("rev", &commands)[0].name, "rev");
        assert_eq!(ProviderCommand::matching("", &commands).len(), 5);
    }

    #[test]
    fn reported_commands_stay_in_their_thread_or_same_folder_and_account() {
        let mut reported = ReportedCommands::default();
        let folder = Path::new("/synthetic/project");
        reported.record(
            "one",
            "claude",
            &Value::Null,
            Some(folder),
            vec![command("review", None)],
        );
        assert_eq!(
            reported.lookup("one", "claude", &Value::Null, None).1,
            "session"
        );
        assert_eq!(
            reported
                .lookup("one", "codex", &Value::Null, Some(folder))
                .1,
            "none"
        );
        let (commands, source) = reported.lookup("two", "claude", &json!("default"), Some(folder));
        assert_eq!((commands.len(), source), (1, "folder"));
        assert_eq!(
            reported
                .lookup("two", "claude", &json!("work"), Some(folder))
                .1,
            "none"
        );
        assert_eq!(
            reported
                .lookup(
                    "two",
                    "claude",
                    &Value::Null,
                    Some(Path::new("/synthetic/other"))
                )
                .1,
            "none"
        );
        for index in 0..MAX_THREADS + 4 {
            reported.record(&format!("t{index}"), "claude", &Value::Null, None, vec![]);
        }
        assert!(reported.sessions.len() <= MAX_THREADS);
        assert_eq!(
            reported.lookup("one", "claude", &Value::Null, None).1,
            "none"
        );
    }

    fn pull(
        number: u64,
        title: &str,
        branch: &str,
        author: Option<&str>,
        updated: Option<&str>,
    ) -> PullRequest {
        PullRequest {
            number,
            title: title.into(),
            url: format!("https://github.com/owner/project/pull/{number}"),
            author: author.map(str::to_owned),
            head_branch: branch.into(),
            is_draft: false,
            updated_at: updated.map(str::to_owned),
        }
    }

    #[test]
    fn pull_request_matching_ranks_numbers_titles_branches_and_recency_like_swift() {
        let pulls = vec![
            pull(
                12,
                "Fix login",
                "fix/login",
                Some("ana"),
                Some("2026-01-01T00:00:00Z"),
            ),
            pull(120, "Café menu", "menu", None, Some("2026-03-01T00:00:00Z")),
            pull(3, "Refactor", "login-cleanup", Some("bob"), None),
            pull(
                812,
                "Docs",
                "docs",
                Some("Login-bot"),
                Some("2026-02-01T00:00:00Z"),
            ),
        ];
        let numbers = |query: &str| {
            PullRequest::matching(query, &pulls, 50)
                .iter()
                .map(|p| p.number)
                .collect::<Vec<_>>()
        };
        assert_eq!(numbers(""), [120, 812, 12, 3]);
        assert_eq!(numbers("12"), [12, 120, 812]);
        assert_eq!(numbers("1"), [120, 12, 812]);
        assert_eq!(numbers("LOGIN"), [12, 812, 3]);
        assert_eq!(numbers("cafe"), [120]);
        assert_eq!(numbers("ME"), [120]);
        assert_eq!(numbers("nothing"), Vec::<u64>::new());
        assert_eq!(PullRequest::matching("", &pulls, 2).len(), 2);
    }

    #[test]
    fn pull_request_list_rows_and_markdown_mentions() {
        let row = json!({"number":7,"title":"Synthetic (PR)","url":"https://github.com/owner/project/pull/7","state":"OPEN","isDraft":true,"headRefOid":"a","headRefName":"feature","baseRefName":"main","author":{"login":"ana"},"updatedAt":"2026-01-01T00:00:00Z"});
        let pull = PullRequest::from_list(&row).unwrap();
        assert!(pull.is_draft);
        assert_eq!(pull.author.as_deref(), Some("ana"));
        assert_eq!(
            pull.markdown().as_deref(),
            Some("[#7](https://github.com/owner/project/pull/7)")
        );
        let mut odd = pull.clone();
        odd.url = "https://example.test/a(b)<c>\\d".into();
        assert_eq!(
            odd.markdown().as_deref(),
            Some("[#7](https://example.test/a%28b%29%3Cc%3E/d)")
        );
        for url in [
            "javascript:alert(1)",
            "https://user:secret@github.com/o/r/pull/7",
            "file:///tmp/x",
            "not a url",
        ] {
            odd.url = url.into();
            assert_eq!(odd.markdown(), None, "{url}");
        }
        assert!(PullRequest::from_list(&json!({"number":0,"title":"x","url":"u"})).is_none());
        let older = PullRequest::from_list(
            &json!({"number":8,"title":"x","url":"u","author":null,"updatedAt":null}),
        )
        .unwrap();
        assert_eq!(
            (older.author, older.updated_at, older.head_branch),
            (None, None, String::new())
        );
    }

    #[test]
    fn github_remotes_parse_like_swift_and_only_github_com_is_queried() {
        for (remote, expected) in [
            (
                "https://github.com/owner/project.git\n",
                Some("owner/project"),
            ),
            (
                "https://token@github.com/owner/project",
                Some("owner/project"),
            ),
            ("git@github.com:owner/project.git", Some("owner/project")),
            (
                "ssh://git@github.com:22/owner/project",
                Some("owner/project"),
            ),
            (
                "git+ssh://git@GitHub.com/owner/project.git",
                Some("owner/project"),
            ),
            (
                "https://github.com/owner/project?x#y",
                Some("owner/project"),
            ),
            ("https://gitlab.com/owner/project.git", None),
            ("git@github.example.com:owner/project.git", None),
            ("https://github.com/owner", None),
            ("https://github.com/owner/project/extra", None),
            ("https://github.com/-owner/project", None),
            ("C:/repos/project", None),
            ("/srv/git/project.git", None),
            ("file:///srv/git/project.git", None),
            ("", None),
            ("https://github.com/owner/project\nhttps://evil", None),
        ] {
            assert_eq!(
                github_repository_from_remote(remote).as_deref(),
                expected,
                "{remote}"
            );
        }
    }

    #[test]
    fn github_repository_reads_the_primary_remote_of_a_local_repository() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let git = |args: &[&str]| crate::workspace::git(root, args).map(|_| ());
        if git(&["init", "-q"]).is_err() {
            return; // No git on this runner; parsing is covered above.
        }
        assert_eq!(github_repository(root).unwrap(), None);
        git(&["remote", "add", "upstream", "https://gitlab.com/o/r.git"]).unwrap();
        assert_eq!(github_repository(root).unwrap(), None);
        git(&[
            "remote",
            "add",
            "origin",
            "git@github.com:owner/project.git",
        ])
        .unwrap();
        assert_eq!(
            github_repository(root).unwrap().as_deref(),
            Some("owner/project")
        );
        assert_eq!(github_repository(&root.join("missing")).unwrap(), None);
    }
}
