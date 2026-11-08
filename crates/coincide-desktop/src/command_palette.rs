//! Snapshot-only native command palette with Swift's interaction model
//! (`CommandPaletteController`/`PaletteViewController`): grouped results ranked
//! by `coincide_core::palette_search`, nested lists (Escape, or Backspace in an
//! empty field, goes back), a ">" prefix for actions only, "/" or "~" folder
//! browsing with Tab completion, Page Up/Down and bold match highlighting.
//! The parent binds Cmd/Ctrl-K, supplies snapshots, runs the searches the
//! palette requests and executes typed events after checking current
//! revision/IDs. This module never touches Engine, files, provider state or
//! composer drafts.
use anyhow::{Result, ensure};
use coincide_core::palette_search::{self, Field, Query};
use gpui_kit::{
    assets::IconName,
    component::input::{Input, InputEvent, InputState},
    prelude::FluentBuilder,
    *,
};
use std::{collections::HashSet, ops::Range, time::Duration};

const MAX_ENTRIES: usize = 10_000;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_LISTS: usize = 64;
const QUERY_CHARS: usize = 256;
const PATH_BYTES: usize = 4096;
/// Swift `PaletteCatalog.recentThreadLimit`, `threadLimit` and `secondaryLimit`.
const RECENT_THREADS: usize = 12;
const THREAD_LIMIT: usize = 20;
const SECONDARY_LIMIT: usize = 3;
/// Rows Page Up/Down moves, as Swift.
const PAGE: isize = 8;
/// A nested list's own search waits for typing to pause, as Swift.
const SEARCH_DELAY: Duration = Duration::from_millis(120);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum PaletteCommand {
    OpenThread {
        thread_id: String,
    },
    /// None means ALL projects, not projectless.
    SelectProject {
        project_id: Option<String>,
    },
    /// None means explicitly projectless, never the current project.
    NewThread {
        project_id: Option<String>,
    },
    OpenSettings,
    ShowSchedules,
    /// An app action the parent resolves by its stable ID (Swift's palette
    /// item IDs such as `action:diff`, `setting:keyboard` or `help:…`).
    Action {
        id: String,
    },
    /// Pushes the snapshot's nested list with this ID. Handled by the palette
    /// itself and never emitted.
    OpenMenu {
        id: String,
    },
    /// A folder a "/" or "~" query found, to add as a project.
    AddProject {
        path: String,
    },
    /// A file Go to File or Search in Project found under `root`.
    OpenFile {
        root: String,
        path: String,
        line: Option<usize>,
    },
}
impl PaletteCommand {
    fn id(&self) -> Option<&str> {
        match self {
            Self::OpenThread { thread_id } => Some(thread_id),
            Self::SelectProject { project_id } | Self::NewThread { project_id } => {
                project_id.as_deref()
            }
            Self::Action { id } | Self::OpenMenu { id } => Some(id),
            _ => None,
        }
    }
    fn paths(&self) -> Vec<&str> {
        match self {
            Self::AddProject { path } => vec![path],
            Self::OpenFile { root, path, .. } => vec![root, path],
            _ => Vec::new(),
        }
    }
    fn key(&self) -> String {
        match self {
            Self::OpenThread { thread_id } => format!("thread/{}:{thread_id}", thread_id.len()),
            Self::SelectProject { project_id } => match project_id {
                Some(id) => format!("project/{}:{id}", id.len()),
                None => "project/all".into(),
            },
            Self::NewThread { project_id } => match project_id {
                Some(id) => format!("new-thread/{}:{id}", id.len()),
                None => "new-thread/projectless".into(),
            },
            Self::OpenSettings => "action/settings".into(),
            Self::ShowSchedules => "action/schedules".into(),
            Self::Action { id } => format!("run/{}:{id}", id.len()),
            Self::OpenMenu { id } => format!("menu/{}:{id}", id.len()),
            Self::AddProject { path } => format!("folder/{}:{path}", path.len()),
            Self::OpenFile { root, path, line } => format!(
                "file/{}:{root}/{}:{path}:{}",
                root.len(),
                path.len(),
                line.unwrap_or(0)
            ),
        }
    }
    fn allocated_bytes(&self) -> usize {
        match self {
            Self::OpenThread { thread_id: id }
            | Self::Action { id }
            | Self::OpenMenu { id }
            | Self::AddProject { path: id } => id.capacity(),
            Self::SelectProject { project_id } | Self::NewThread { project_id } => {
                project_id.as_ref().map_or(0, String::capacity)
            }
            Self::OpenFile { root, path, .. } => root.capacity() + path.capacity(),
            _ => 0,
        }
    }
}

/// Where a root entry is listed, as Swift's palette groups.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaletteGroup {
    /// The everyday actions, listed above the recent threads.
    Actions,
    /// The other actions, listed below them; searched together with Actions.
    MoreActions,
    Threads,
    Projects,
    Settings,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PaletteIcon {
    Symbol(IconName),
    /// An agent's logo (`chat_layout::provider_logo`).
    Provider(String),
}

/// What a thread row is searched by besides its title.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ThreadFacts {
    pub branch: String,
    pub project: String,
    /// Swift reference-date seconds, as the snapshot's `now`.
    pub updated_at: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PaletteEntry {
    pub command: PaletteCommand,
    pub title: String,
    pub subtitle: Option<String>,
    pub keywords: Vec<String>,
    /// A shortcut ("⌘N", the user's for a menu command) or an age ("5m").
    pub trailing: Option<String>,
    pub icon: Option<PaletteIcon>,
    pub group: PaletteGroup,
    /// Set for threads, which rank by title, branch, project and recency.
    pub thread: Option<ThreadFacts>,
    /// Listed last in its group and never decides where the group sits (the
    /// open thread).
    pub secondary: bool,
    /// What Tab puts in the search field: a folder's path, to browse into it.
    pub completion: Option<String>,
    pub enabled: bool,
    pub disabled_reason: Option<String>,
}
impl PaletteEntry {
    pub fn new(command: PaletteCommand, title: impl Into<String>, group: PaletteGroup) -> Self {
        Self {
            command,
            title: title.into(),
            subtitle: None,
            keywords: Vec::new(),
            trailing: None,
            icon: None,
            group,
            thread: None,
            secondary: false,
            completion: None,
            enabled: true,
            disabled_reason: None,
        }
    }
    pub fn subtitle(mut self, subtitle: impl Into<String>) -> Self {
        let subtitle = subtitle.into();
        self.subtitle = (!subtitle.is_empty()).then_some(subtitle);
        self
    }
    pub fn keywords(mut self, keywords: &[&str]) -> Self {
        self.keywords
            .extend(keywords.iter().map(|word| (*word).to_owned()));
        self
    }
    pub fn icon(mut self, icon: IconName) -> Self {
        self.icon = Some(PaletteIcon::Symbol(icon));
        self
    }
}

/// A titled list of entries: a nested list's group or one group of results.
#[derive(Clone, Debug, PartialEq)]
pub struct PaletteList {
    pub title: String,
    pub entries: Vec<PaletteEntry>,
}

/// What a folder search covers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SearchKind {
    /// Folders a "/" or "~" query lists to add as projects.
    Folders,
    /// Go to File over a thread's folder.
    Files { root: String },
    /// Search in Project over a thread's folder.
    Text { root: String },
}

#[derive(Clone, Debug, PartialEq)]
pub enum MenuContent {
    /// Lists the palette filters as the query changes.
    Lists(Vec<PaletteList>),
    /// A search the parent runs for each query; its results are shown as they are.
    Search(SearchKind),
}

/// A nested list pushed onto the palette, as Swift's `PaletteMenu`.
#[derive(Clone, Debug, PartialEq)]
pub struct PaletteMenu {
    pub id: String,
    pub title: String,
    pub placeholder: String,
    pub content: MenuContent,
}

#[derive(Clone, Debug)]
pub struct PaletteSnapshot {
    pub revision: u64,
    pub entries: Vec<PaletteEntry>,
    pub menus: Vec<PaletteMenu>,
    /// The worktree branch prefix threads are searched without.
    pub branch_prefix: String,
    /// Now, on the clock of `ThreadFacts::updated_at`.
    pub now: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchRequest {
    pub generation: u64,
    pub kind: SearchKind,
    pub query: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PaletteEvent {
    Activated {
        revision: u64,
        command: PaletteCommand,
    },
    /// Run this search and hand its lists to `CommandPalette::set_results`.
    Search(SearchRequest),
    Dismissed,
    SearchInvalidated,
}

fn bounded_string(s: &str, max: usize) -> bool {
    s.len() <= max * 4 && s.chars().count() <= max && !s.contains('\0')
}
fn validate_entries<'a>(
    entries: impl IntoIterator<Item = &'a PaletteEntry>,
    bytes: &mut usize,
) -> Result<()> {
    let mut ids = HashSet::new();
    let mut count = 0;
    for entry in entries {
        count += 1;
        ensure!(
            count <= MAX_ENTRIES,
            "Palette supports at most 10000 entries"
        );
        ensure!(
            bounded_string(&entry.title, 512) && !entry.title.trim().is_empty(),
            "Palette title must be nonblank and at most 512 characters"
        );
        ensure!(
            entry
                .subtitle
                .as_ref()
                .is_none_or(|s| bounded_string(s, 1024))
                && entry
                    .disabled_reason
                    .as_ref()
                    .is_none_or(|s| bounded_string(s, 512))
                && entry
                    .trailing
                    .as_ref()
                    .is_none_or(|s| bounded_string(s, 64))
                && entry
                    .completion
                    .as_ref()
                    .is_none_or(|s| s.len() <= PATH_BYTES && !s.contains('\0')),
            "Palette subtitle/reason/shortcut/completion exceeds bounds"
        );
        ensure!(
            entry.keywords.len() <= 32 && entry.keywords.iter().all(|s| bounded_string(s, 128)),
            "Palette keywords exceed 32 x 128 characters"
        );
        ensure!(
            entry
                .command
                .id()
                .is_none_or(|id| !id.trim().is_empty() && bounded_string(id, 128)),
            "Invalid stable palette ID"
        );
        ensure!(
            entry
                .command
                .paths()
                .iter()
                .all(|path| !path.is_empty() && path.len() <= PATH_BYTES && !path.contains('\0')),
            "Invalid palette path"
        );
        ensure!(
            entry.thread.as_ref().is_none_or(|facts| {
                bounded_string(&facts.branch, 512)
                    && bounded_string(&facts.project, 512)
                    && facts.updated_at.is_finite()
            }),
            "Palette thread details exceed bounds"
        );
        ensure!(
            ids.insert(&entry.command),
            "Duplicate palette command identity"
        );
        for size in [
            std::mem::size_of::<PaletteEntry>(),
            entry.title.capacity(),
            entry.subtitle.as_ref().map_or(0, String::capacity),
            entry.disabled_reason.as_ref().map_or(0, String::capacity),
            entry.trailing.as_ref().map_or(0, String::capacity),
            entry.completion.as_ref().map_or(0, String::capacity),
            entry.thread.as_ref().map_or(0, |facts| {
                facts.branch.capacity() + facts.project.capacity()
            }),
            entry.command.allocated_bytes(),
            entry
                .keywords
                .capacity()
                .saturating_mul(std::mem::size_of::<String>()),
        ]
        .into_iter()
        .chain(entry.keywords.iter().map(String::capacity))
        {
            *bytes = bytes.checked_add(size).unwrap_or(MAX_BYTES + 1);
            ensure!(
                *bytes <= MAX_BYTES,
                "Palette snapshot exceeds 16 MiB allocated storage"
            );
        }
    }
    Ok(())
}
fn validate_lists(lists: &[PaletteList], bytes: &mut usize) -> Result<()> {
    ensure!(
        lists.len() <= MAX_LISTS,
        "Palette supports at most 64 lists"
    );
    for list in lists {
        ensure!(
            bounded_string(&list.title, 512),
            "Palette list title exceeds bounds"
        );
    }
    validate_entries(lists.iter().flat_map(|list| &list.entries), bytes)
}
fn validate(snapshot: &PaletteSnapshot) -> Result<()> {
    ensure!(
        snapshot.entries.len() <= MAX_ENTRIES,
        "Palette supports at most 10000 entries"
    );
    ensure!(
        snapshot.now.is_finite() && bounded_string(&snapshot.branch_prefix, 256),
        "Invalid palette clock or branch prefix"
    );
    let mut bytes = snapshot
        .entries
        .capacity()
        .checked_mul(std::mem::size_of::<PaletteEntry>())
        .unwrap_or(MAX_BYTES + 1);
    ensure!(
        bytes <= MAX_BYTES,
        "Palette snapshot exceeds 16 MiB allocated storage"
    );
    validate_entries(&snapshot.entries, &mut bytes)?;
    ensure!(snapshot.menus.len() <= MAX_LISTS, "Too many palette menus");
    let mut menus = HashSet::new();
    for menu in &snapshot.menus {
        ensure!(
            !menu.id.trim().is_empty()
                && bounded_string(&menu.id, 128)
                && menus.insert(menu.id.as_str()),
            "Invalid or duplicate palette menu ID"
        );
        ensure!(
            bounded_string(&menu.title, 512) && bounded_string(&menu.placeholder, 512),
            "Palette menu title exceeds bounds"
        );
        match &menu.content {
            MenuContent::Lists(lists) => validate_lists(lists, &mut bytes)?,
            MenuContent::Search(SearchKind::Files { root } | SearchKind::Text { root }) => ensure!(
                !root.is_empty() && root.len() <= PATH_BYTES && !root.contains('\0'),
                "Invalid palette search folder"
            ),
            MenuContent::Search(SearchKind::Folders) => {}
        }
    }
    for entry in &snapshot.entries {
        if let PaletteCommand::OpenMenu { id } = &entry.command {
            ensure!(menus.contains(id.as_str()), "Palette menu is missing");
        }
    }
    Ok(())
}

/// Whether an open nested list may stay open across a snapshot: the same
/// search, or lists the palette filters.
fn same_kind(new: &MenuContent, old: &MenuContent) -> bool {
    match (new, old) {
        (MenuContent::Lists(_), MenuContent::Lists(_)) => true,
        (MenuContent::Search(new), MenuContent::Search(old)) => new == old,
        _ => false,
    }
}

/// Folded search fields, prepared once per snapshot or list.
struct Prepared {
    title: Field,
    keywords: Vec<Field>,
    branch: Field,
    project: Field,
}
impl Prepared {
    fn new(entry: &PaletteEntry, branch_prefix: &str) -> Self {
        let (branch, project) = entry
            .thread
            .as_ref()
            .map_or_else(Default::default, |facts| {
                (
                    Field::new(palette_search::searchable_branch(
                        &facts.branch,
                        branch_prefix,
                    )),
                    Field::new(&facts.project),
                )
            });
        Self {
            title: Field::new(&entry.title),
            keywords: entry.keywords.iter().map(|word| Field::new(word)).collect(),
            branch,
            project,
        }
    }
    fn score(
        &self,
        entry: &PaletteEntry,
        query: &Query,
        now: f64,
        typos: bool,
    ) -> Option<palette_search::Match> {
        let mut found = match &entry.thread {
            Some(facts) => palette_search::score_thread(
                query,
                &self.title,
                &self.branch,
                &self.project,
                facts.updated_at,
                now,
                typos,
            ),
            None => palette_search::score_terms(query, &self.title, &self.keywords, typos),
        }?;
        if entry.secondary {
            found.group_quality = Some(0.0);
        }
        Some(found)
    }
}
fn prepare(entries: &[PaletteEntry], prefix: &str) -> Vec<Prepared> {
    entries
        .iter()
        .map(|entry| Prepared::new(entry, prefix))
        .collect()
}

/// Where a listed entry lives.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Source {
    Root(usize),
    /// Menu, list and entry.
    Menu(usize, usize, usize),
    /// Result list and entry.
    Result(usize, usize),
}
#[derive(Clone, Debug, PartialEq)]
enum Row {
    Header(String),
    Item {
        source: Source,
        ranges: Vec<Range<usize>>,
    },
}

/// What activating a row did.
#[derive(Debug, PartialEq)]
enum Activation {
    Event(PaletteEvent),
    /// A nested list opened; the search field is now empty.
    Opened,
}

struct Results {
    generation: u64,
    lists: Vec<PaletteList>,
}

struct Model {
    snapshot: PaletteSnapshot,
    prepared: Vec<Prepared>,
    /// Per menu, per list, for menus that filter their own lists.
    menu_prepared: Vec<Vec<Vec<Prepared>>>,
    /// Open nested lists with the query to restore when leaving each.
    stack: Vec<(usize, String)>,
    query: String,
    generation: u64,
    results: Option<Results>,
    request: Option<SearchRequest>,
    rows: Vec<Row>,
    selected: Option<PaletteCommand>,
    open: bool,
}
impl Model {
    fn new(snapshot: PaletteSnapshot) -> Result<Self> {
        validate(&snapshot)?;
        let mut m = Self {
            prepared: Vec::new(),
            menu_prepared: Vec::new(),
            snapshot,
            stack: Vec::new(),
            query: String::new(),
            generation: 0,
            results: None,
            request: None,
            rows: Vec::new(),
            selected: None,
            open: true,
        };
        m.prepare();
        m.search_changed();
        m.rebuild();
        Ok(m)
    }
    // Keep request identities unique across openings as well as queries.
    fn continue_generation(&mut self, previous: u64) {
        self.generation += previous;
        if let Some(request) = &mut self.request {
            request.generation = self.generation;
        }
    }
    fn prepare(&mut self) {
        let prefix = self.snapshot.branch_prefix.clone();
        self.prepared = prepare(&self.snapshot.entries, &prefix);
        self.menu_prepared = self
            .snapshot
            .menus
            .iter()
            .map(|menu| match &menu.content {
                MenuContent::Lists(lists) => lists
                    .iter()
                    .map(|list| prepare(&list.entries, &prefix))
                    .collect(),
                MenuContent::Search(_) => Vec::new(),
            })
            .collect();
    }
    fn menu(&self) -> Option<&PaletteMenu> {
        self.stack
            .last()
            .map(|(index, _)| &self.snapshot.menus[*index])
    }
    /// The search the current list needs, if it searches for itself.
    fn search_kind(&self) -> Option<SearchKind> {
        match self.menu() {
            Some(menu) => match &menu.content {
                MenuContent::Search(kind) => Some(kind.clone()),
                MenuContent::Lists(_) => None,
            },
            None => coincide_core::project_search::is_path_query(&self.query)
                .then_some(SearchKind::Folders),
        }
    }
    /// Old results never show for a new query or list.
    fn search_changed(&mut self) {
        self.generation += 1;
        self.results = None;
        self.request = self.search_kind().map(|kind| SearchRequest {
            generation: self.generation,
            kind,
            query: self.query.clone(),
        });
    }
    fn take_request(&mut self) -> Option<SearchRequest> {
        self.request.take()
    }
    fn set_results(&mut self, generation: u64, lists: Vec<PaletteList>) -> Result<bool> {
        if generation != self.generation || self.search_kind().is_none() {
            return Ok(false);
        }
        validate_lists(&lists, &mut 0)?;
        self.results = Some(Results { generation, lists });
        self.selected = None;
        self.rebuild();
        Ok(true)
    }
    fn entry(&self, source: Source) -> &PaletteEntry {
        match source {
            Source::Root(index) => &self.snapshot.entries[index],
            Source::Menu(menu, list, index) => match &self.snapshot.menus[menu].content {
                MenuContent::Lists(lists) => &lists[list].entries[index],
                MenuContent::Search(_) => unreachable!("search menus list results"),
            },
            Source::Result(list, index) => {
                &self.results.as_ref().expect("listed results").lists[list].entries[index]
            }
        }
    }
    fn items(&self) -> impl Iterator<Item = (&PaletteEntry, &[Range<usize>])> {
        self.rows.iter().filter_map(|row| match row {
            Row::Item { source, ranges } => Some((self.entry(*source), ranges.as_slice())),
            Row::Header(_) => None,
        })
    }
    #[cfg(test)]
    fn total(&self) -> usize {
        self.items().count()
    }
    fn rebuild(&mut self) {
        let mut groups: Vec<(String, Vec<(Source, Vec<Range<usize>>)>)> = Vec::new();
        if self.search_kind().is_some() {
            if let Some(results) = self
                .results
                .as_ref()
                .filter(|results| results.generation == self.generation)
            {
                for (list_index, list) in results.lists.iter().enumerate() {
                    groups.push((
                        list.title.clone(),
                        (0..list.entries.len())
                            .map(|index| (Source::Result(list_index, index), Vec::new()))
                            .collect(),
                    ));
                }
            }
        } else if let Some(&(menu, _)) = self.stack.last() {
            let MenuContent::Lists(lists) = &self.snapshot.menus[menu].content else {
                unreachable!("search menus list results");
            };
            let candidates = lists
                .iter()
                .enumerate()
                .map(|(list, entries)| {
                    (
                        entries.title.clone(),
                        (0..entries.entries.len())
                            .map(|index| Source::Menu(menu, list, index))
                            .collect(),
                    )
                })
                .collect();
            groups = self.filter(candidates, &Query::new(&self.query), false);
        } else {
            groups = self.root_groups();
        }
        self.rows = groups
            .into_iter()
            .filter(|(_, items)| !items.is_empty())
            .flat_map(|(title, items)| {
                std::iter::once(Row::Header(title)).chain(
                    items
                        .into_iter()
                        .map(|(source, ranges)| Row::Item { source, ranges }),
                )
            })
            .collect();
        let selected = self.selected.clone();
        if !selected.as_ref().is_some_and(|selected| {
            self.items()
                .any(|(entry, _)| entry.enabled && &entry.command == selected)
        }) {
            let first = self
                .items()
                .find(|(entry, _)| entry.enabled)
                .map(|(entry, _)| entry.command.clone());
            self.selected = first;
        }
    }
    fn root_groups(&self) -> Vec<(String, Vec<(Source, Vec<Range<usize>>)>)> {
        let by_group = |group: PaletteGroup| {
            self.snapshot
                .entries
                .iter()
                .enumerate()
                .filter(move |(_, entry)| entry.group == group)
                .map(|(index, _)| Source::Root(index))
                .collect::<Vec<_>>()
        };
        let actions_only = self.query.starts_with('>');
        let search = Query::new(if actions_only {
            &self.query[1..]
        } else {
            &self.query
        });
        let (core, more) = (
            by_group(PaletteGroup::Actions),
            by_group(PaletteGroup::MoreActions),
        );
        let actions = core.iter().chain(&more).copied().collect::<Vec<_>>();
        let plain = |sources: Vec<Source>| {
            sources
                .into_iter()
                .map(|source| (source, Vec::new()))
                .collect::<Vec<_>>()
        };
        if search.is_empty() && actions_only {
            return vec![("Actions".into(), plain(actions))];
        }
        if search.is_empty() {
            // Recent threads sit right under the everyday actions, as in T3;
            // picking the open thread does nothing, so it goes last.
            let recent = by_group(PaletteGroup::Threads)
                .into_iter()
                .take(RECENT_THREADS)
                .collect::<Vec<_>>();
            let (secondary, first): (Vec<_>, Vec<_>) = recent
                .into_iter()
                .partition(|source| self.entry(*source).secondary);
            return vec![
                ("Actions".into(), plain(core)),
                (
                    "Recent Threads".into(),
                    plain(first.into_iter().chain(secondary).collect()),
                ),
                ("More Actions".into(), plain(more)),
            ];
        }
        let mut candidates = vec![("Actions".to_owned(), actions)];
        if !actions_only {
            candidates.extend([
                ("Threads".to_owned(), by_group(PaletteGroup::Threads)),
                ("Projects".to_owned(), by_group(PaletteGroup::Projects)),
                ("Settings".to_owned(), by_group(PaletteGroup::Settings)),
            ]);
        }
        self.filter(candidates, &search, !actions_only)
    }
    fn prepared(&self, source: Source) -> &Prepared {
        match source {
            Source::Root(index) => &self.prepared[index],
            Source::Menu(menu, list, index) => &self.menu_prepared[menu][list][index],
            Source::Result(..) => unreachable!("results are not ranked"),
        }
    }
    /// Ranks every group's items for the query, keeping the groups and items
    /// that match. Next to matching threads, other groups show only their best
    /// few, as in T3.
    fn filter(
        &self,
        groups: Vec<(String, Vec<Source>)>,
        query: &Query,
        limit_secondary: bool,
    ) -> Vec<(String, Vec<(Source, Vec<Range<usize>>)>)> {
        if query.is_empty() {
            return groups
                .into_iter()
                .map(|(title, sources)| {
                    (
                        title,
                        sources
                            .into_iter()
                            .map(|source| (source, Vec::new()))
                            .collect(),
                    )
                })
                .collect();
        }
        let sizes = groups
            .iter()
            .map(|(_, items)| items.len())
            .collect::<Vec<_>>();
        let ranked = palette_search::rank(&sizes, |group, item, typos| {
            let source = groups[group].1[item];
            self.prepared(source)
                .score(self.entry(source), query, self.snapshot.now, typos)
        });
        let threads_match = ranked
            .iter()
            .any(|(group, _)| groups[*group].0 == "Threads");
        ranked
            .into_iter()
            .map(|(group, items)| {
                let (title, sources) = &groups[group];
                let limit = if title == "Threads" {
                    THREAD_LIMIT
                } else if limit_secondary && threads_match {
                    SECONDARY_LIMIT
                } else {
                    usize::MAX
                };
                let (secondary, first): (Vec<_>, Vec<_>) = items
                    .into_iter()
                    .map(|(item, found)| (sources[item], found.ranges))
                    .partition(|(source, _)| self.entry(*source).secondary);
                (
                    title.clone(),
                    first.into_iter().chain(secondary).take(limit).collect(),
                )
            })
            .collect()
    }
    fn query(&mut self, query: &str) {
        let query = query
            .chars()
            .filter(|ch| *ch != '\0')
            .take(QUERY_CHARS)
            .collect::<String>();
        if query == self.query {
            return;
        }
        self.query = query;
        self.selected = None;
        self.search_changed();
        self.rebuild();
    }
    fn replace(&mut self, snapshot: PaletteSnapshot) -> Result<()> {
        ensure!(
            snapshot.revision > self.snapshot.revision,
            "Palette snapshot revision must advance"
        );
        validate(&snapshot)?;
        // Open nested lists follow their identity; one that changed or went
        // away closes back to the root, with the query it was opened from.
        let mut stack = Vec::new();
        for (index, parent) in &self.stack {
            let old = &self.snapshot.menus[*index];
            match snapshot.menus.iter().position(|menu| menu.id == old.id) {
                Some(found) if same_kind(&snapshot.menus[found].content, &old.content) => {
                    stack.push((found, parent.clone()))
                }
                _ => {
                    self.query = parent.clone();
                    break;
                }
            }
        }
        let searched = self.search_kind();
        self.stack = stack;
        self.snapshot = snapshot;
        self.prepare();
        if self.search_kind() != searched || searched.is_none() {
            self.search_changed();
        }
        self.rebuild();
        Ok(())
    }
    fn move_by(&mut self, steps: isize) {
        let enabled = self
            .items()
            .filter(|(entry, _)| entry.enabled)
            .map(|(entry, _)| entry.command.clone())
            .collect::<Vec<_>>();
        if enabled.is_empty() {
            self.selected = None;
            return;
        }
        let position = self
            .selected
            .as_ref()
            .and_then(|s| enabled.iter().position(|c| c == s));
        let next = match position {
            None => 0,
            Some(i) => i.saturating_add_signed(steps).min(enabled.len() - 1),
        };
        self.selected = Some(enabled[next].clone());
    }
    fn select(&mut self, command: &PaletteCommand) {
        if self
            .items()
            .any(|(entry, _)| entry.enabled && &entry.command == command)
        {
            self.selected = Some(command.clone());
        }
    }
    fn activate(&mut self, command: &PaletteCommand) -> Option<Activation> {
        if !self.open
            || !self
                .items()
                .any(|(entry, _)| entry.enabled && &entry.command == command)
        {
            return None;
        }
        if let PaletteCommand::OpenMenu { id } = command {
            let index = self.snapshot.menus.iter().position(|menu| &menu.id == id)?;
            self.stack.push((index, self.query.clone()));
            self.query.clear();
            self.selected = None;
            self.search_changed();
            self.rebuild();
            return Some(Activation::Opened);
        }
        self.open = false;
        Some(Activation::Event(PaletteEvent::Activated {
            revision: self.snapshot.revision,
            command: command.clone(),
        }))
    }
    /// Leaves the open nested list, returning the query to restore.
    fn back(&mut self) -> Option<String> {
        let (_, parent) = self.stack.pop()?;
        self.query = parent.clone();
        self.selected = None;
        self.search_changed();
        self.rebuild();
        Some(parent)
    }
    /// What Tab puts in the field: the selected folder's path.
    fn completion(&self) -> Option<String> {
        let selected = self.selected.as_ref()?;
        self.items()
            .find(|(entry, _)| &entry.command == selected)
            .and_then(|(entry, _)| entry.completion.clone())
    }
    fn dismiss(&mut self) -> Option<PaletteEvent> {
        if !self.open {
            return None;
        }
        self.open = false;
        Some(PaletteEvent::Dismissed)
    }
    fn path_query(&self) -> bool {
        self.stack.is_empty() && coincide_core::project_search::is_path_query(&self.query)
    }
    fn placeholder(&self) -> String {
        match self.menu() {
            Some(menu) => menu.placeholder.clone(),
            None if self.path_query() => "Enter a folder path, e.g. ~/projects/my-app".into(),
            None => "Search commands, projects, and threads…".into(),
        }
    }
    fn empty_label(&self) -> &'static str {
        if self.path_query() {
            "No folders match this path."
        } else if self.stack.is_empty() && self.query.starts_with('>') {
            "No matching actions."
        } else {
            "No matching commands, projects, or threads."
        }
    }
    fn hints(&self) -> Vec<&'static str> {
        let mac = cfg!(target_os = "macos");
        let mut hints = vec!["↑↓ Navigate"];
        if self.path_query() {
            hints.extend(if mac {
                ["⇥ Complete", "↩ Add Project"]
            } else {
                ["Tab Complete", "Enter Add Project"]
            });
        } else {
            hints.push(if mac { "↩ Open" } else { "Enter Open" });
        }
        if !self.stack.is_empty() {
            hints.push(if mac { "⌫ Back" } else { "Backspace Back" });
        }
        hints.push(match (self.stack.is_empty(), mac) {
            (true, true) => "⎋ Close",
            (true, false) => "Esc Close",
            (false, true) => "⎋ Back",
            (false, false) => "Esc Back",
        });
        hints
    }
}

/// Colors the parent's theme supplies, as 0xRRGGBB.
#[derive(Clone, Copy, Debug)]
pub struct PaletteColors {
    pub surface: u32,
    pub selection: u32,
    pub border: u32,
    pub ink: u32,
}
impl Default for PaletteColors {
    fn default() -> Self {
        Self {
            surface: 0x181d28,
            selection: 0x2b3549,
            border: 0x29303d,
            ink: 0xe4e9f2,
        }
    }
}

pub struct CommandPalette {
    model: Option<Model>,
    input: Entity<InputState>,
    restore: Option<FocusHandle>,
    scroll: ScrollHandle,
    colors: PaletteColors,
    placeholder: String,
    search: Option<Task<()>>,
    _subscription: Subscription,
}
impl EventEmitter<PaletteEvent> for CommandPalette {}
impl CommandPalette {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder("Search commands, projects, and threads…")
        });
        let subscription =
            cx.subscribe_in(&input, window, |this, _, event, window, cx| match event {
                InputEvent::Change => {
                    if !this.is_open() {
                        return;
                    }
                    let value = this.input.read(cx).value().to_string();
                    let bounded = value
                        .chars()
                        .filter(|ch| *ch != '\0')
                        .take(QUERY_CHARS)
                        .collect::<String>();
                    if value != bounded {
                        this.input
                            .update(cx, |input, cx| input.set_value(bounded.clone(), window, cx));
                    }
                    if let Some(model) = &mut this.model {
                        model.query(&bounded);
                    }
                    this.changed(window, cx);
                }
                InputEvent::PressEnter {
                    secondary: false,
                    shift: false,
                } => this.activate_selected(window, cx),
                _ => {}
            });
        Self {
            model: None,
            input,
            restore: None,
            scroll: ScrollHandle::new(),
            colors: PaletteColors::default(),
            placeholder: String::new(),
            search: None,
            _subscription: subscription,
        }
    }
    pub fn is_open(&self) -> bool {
        self.model.as_ref().is_some_and(|m| m.open)
    }
    pub fn set_colors(&mut self, colors: PaletteColors) {
        self.colors = colors;
    }
    /// Validate before changing focus or state. Parent must preserve its draft
    /// normally; the palette never accesses/edits that draft or sends messages.
    pub fn open(
        &mut self,
        snapshot: PaletteSnapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        let mut model = Model::new(snapshot)?;
        model.continue_generation(self.model.as_ref().map_or(0, |model| model.generation));
        if !self.is_open() {
            self.restore = window.focused(cx);
        }
        self.model = Some(model);
        self.input
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.input.read(cx).focus_handle(cx).focus(window, cx);
        self.changed(window, cx);
        Ok(())
    }
    pub fn replace_snapshot(
        &mut self,
        snapshot: PaletteSnapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        let Some(model) = &mut self.model else {
            anyhow::bail!("Palette has not been opened");
        };
        let query = model.query.clone();
        model.replace(snapshot)?;
        if model.query != query {
            let restored = model.query.clone();
            self.input
                .update(cx, |input, cx| input.set_value(restored, window, cx));
        }
        self.changed(window, cx);
        Ok(())
    }
    /// The lists a requested search found. Results for an older query or
    /// list are ignored.
    pub fn set_results(
        &mut self,
        generation: u64,
        lists: Vec<PaletteList>,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        if let Some(model) = &mut self.model
            && model.set_results(generation, lists)?
        {
            self.scroll_selected();
            cx.notify();
        }
        Ok(())
    }
    pub fn dismiss(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(event) = self.model.as_mut().and_then(Model::dismiss) {
            self.search = None;
            self.finish(event, window, cx);
        }
    }
    /// After the query or list changed: placeholder, scroll and any search the
    /// new list needs, once typing pauses (folder paths list at once).
    fn changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        cx.emit(PaletteEvent::SearchInvalidated);
        let Some(model) = &mut self.model else {
            return;
        };
        let placeholder = model.placeholder();
        if let Some(request) = model.take_request() {
            let delay = (request.kind != SearchKind::Folders).then_some(SEARCH_DELAY);
            self.search = Some(cx.spawn(async move |this, cx| {
                if let Some(delay) = delay {
                    cx.background_executor().timer(delay).await;
                }
                let _ =
                    this.update(cx, |this, cx| {
                        if this.model.as_ref().is_some_and(|model| {
                            model.open && model.generation == request.generation
                        }) {
                            cx.emit(PaletteEvent::Search(request));
                        }
                    });
            }));
        }
        if placeholder != self.placeholder {
            self.placeholder = placeholder.clone();
            self.input.update(cx, |input, cx| {
                input.set_placeholder(placeholder, window, cx)
            });
        }
        self.scroll_selected();
        cx.notify();
    }
    fn finish(&mut self, event: PaletteEvent, window: &mut Window, cx: &mut Context<Self>) {
        // Restore BEFORE emitting. Parent may then move focus to the destination
        // of its validated command; Escape never emits an Activated event.
        if let Some(focus) = self.restore.take() {
            focus.focus(window, cx);
        }
        cx.notify();
        cx.emit(event);
    }
    fn activate(&mut self, command: &PaletteCommand, window: &mut Window, cx: &mut Context<Self>) {
        match self
            .model
            .as_mut()
            .and_then(|model| model.activate(command))
        {
            Some(Activation::Event(event)) => {
                self.search = None;
                self.finish(event, window, cx);
            }
            Some(Activation::Opened) => {
                self.input
                    .update(cx, |input, cx| input.set_value("", window, cx));
                self.changed(window, cx);
            }
            None => {}
        }
    }
    fn activate_selected(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let selected = self.model.as_ref().and_then(|m| m.selected.clone());
        if let Some(selected) = selected {
            self.activate(&selected, window, cx);
        }
    }
    fn back(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(query) = self.model.as_mut().and_then(Model::back) {
            self.input
                .update(cx, |input, cx| input.set_value(query, window, cx));
            self.changed(window, cx);
        }
    }
    fn set_query(&mut self, query: String, window: &mut Window, cx: &mut Context<Self>) {
        self.input
            .update(cx, |input, cx| input.set_value(query.clone(), window, cx));
        if let Some(model) = &mut self.model {
            model.query(&query);
        }
        self.changed(window, cx);
    }
    fn scroll_selected(&self) {
        let Some(model) = &self.model else {
            return;
        };
        let Some(row) = model.rows.iter().position(|row| match row {
            Row::Item { source, .. } => {
                Some(&model.entry(*source).command) == model.selected.as_ref()
            }
            Row::Header(_) => false,
        }) else {
            return;
        };
        // Keep the group title above the first result visible.
        let header = row > 0 && matches!(model.rows[row - 1], Row::Header(_));
        self.scroll
            .scroll_to_item(if header { row - 1 } else { row });
    }
    fn key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if !self.is_open() {
            return;
        }
        let key = &event.keystroke;
        if key.modifiers.control
            || key.modifiers.platform
            || key.modifiers.alt
            || key.modifiers.shift
        {
            return;
        }
        let Some(model) = &mut self.model else {
            return;
        };
        match key.key.as_str() {
            "up" | "down" | "pageup" | "pagedown" => {
                model.move_by(match key.key.as_str() {
                    "up" => -1,
                    "down" => 1,
                    "pageup" => -PAGE,
                    _ => PAGE,
                });
                self.scroll_selected();
                cx.notify();
            }
            "escape" if !model.stack.is_empty() => self.back(window, cx),
            "escape" => self.dismiss(window, cx),
            "tab" => {
                if let Some(completion) = model.completion() {
                    self.set_query(completion, window, cx);
                }
            }
            // Backspace in an empty nested list goes back, as in T3.
            "backspace" if model.query.is_empty() && !model.stack.is_empty() => {
                self.back(window, cx)
            }
            // Enter stays in native InputState and reaches PressEnter only after
            // input processing. Other text/editing keys are not intercepted.
            _ => return,
        }
        cx.stop_propagation();
    }
}

fn hex(color: u32, alpha: f32) -> Hsla {
    let mut color: Hsla = rgb(color).into();
    color.a = alpha;
    color
}

impl Render for CommandPalette {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(model) = self.model.as_ref().filter(|model| model.open) else {
            return div().into_any_element();
        };
        let colors = self.colors;
        let ink = hex(colors.ink, 1.0);
        let secondary = hex(colors.ink, 0.62);
        let tertiary = hex(colors.ink, 0.42);
        let menu = model.menu();
        let search_row = div()
            .flex()
            .items_center()
            .gap_2()
            .h(px(52.))
            .px_4()
            .flex_shrink_0()
            .when(menu.is_none(), |row| {
                row.child(div().text_color(secondary).child(IconName::Search))
            })
            .when_some(menu, |row, menu| {
                row.child(
                    div()
                        .id("palette-back")
                        .cursor_pointer()
                        .text_color(secondary)
                        .child(IconName::ChevronLeft)
                        .on_click(cx.listener(|this, _, window, cx| this.back(window, cx))),
                )
                .child(
                    div()
                        .flex_shrink_0()
                        .text_color(secondary)
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(menu.title.clone()),
                )
            })
            .child(
                div().flex_1().child(
                    Input::new(&self.input)
                        .appearance(false)
                        .aria_label("Search commands, projects, and threads"),
                ),
            );
        let mut list = div()
            .id("command-palette-results")
            .flex_1()
            .min_h_0()
            .max_h(px(440.))
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .flex()
            .flex_col()
            .py_1();
        let selected = model.selected.clone();
        let mut first_header = true;
        for row in &model.rows {
            match row {
                Row::Header(title) => {
                    list = list.child(
                        div()
                            .px(px(14.))
                            .pt(px(if first_header { 6. } else { 12. }))
                            .pb_1()
                            .text_xs()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(secondary)
                            .child(title.clone()),
                    );
                    first_header = false;
                }
                Row::Item { source, ranges } => {
                    let entry = model.entry(*source);
                    list = list.child(self.item(
                        entry,
                        ranges,
                        selected.as_ref() == Some(&entry.command),
                        (ink, secondary, tertiary),
                        cx,
                    ));
                }
            }
        }
        if model.rows.is_empty() {
            list = list.child(
                div()
                    .h(px(68.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_sm()
                    .text_color(secondary)
                    .child(model.empty_label()),
            );
        }
        div()
            .id("command-palette")
            .w_full()
            .max_w(px(640.))
            .flex()
            .flex_col()
            .rounded(px(18.))
            .border_1()
            .border_color(hex(colors.border, 1.0))
            .bg(hex(colors.surface, 1.0))
            .shadow_lg()
            .overflow_hidden()
            .text_color(ink)
            .capture_key_down(cx.listener(|this, event, window, cx| this.key(event, window, cx)))
            .child(search_row)
            .child(div().h(px(1.)).bg(hex(colors.border, 1.0)))
            .child(list)
            .child(div().h(px(1.)).bg(hex(colors.border, 1.0)))
            .child(
                div()
                    .h(px(30.))
                    .px_4()
                    .flex()
                    .items_center()
                    .text_xs()
                    .text_color(tertiary)
                    .child(model.hints().join("    ")),
            )
            .into_any_element()
    }
}
impl CommandPalette {
    fn item(
        &self,
        entry: &PaletteEntry,
        ranges: &[Range<usize>],
        selected: bool,
        (ink, secondary, tertiary): (Hsla, Hsla, Hsla),
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let command = entry.command.clone();
        let hovered = command.clone();
        let bold = HighlightStyle {
            font_weight: Some(FontWeight::BOLD),
            ..Default::default()
        };
        let title = StyledText::new(entry.title.clone()).with_highlights(
            ranges
                .iter()
                .filter(|range| {
                    range.end <= entry.title.len()
                        && entry.title.is_char_boundary(range.start)
                        && entry.title.is_char_boundary(range.end)
                })
                .map(|range| (range.clone(), bold)),
        );
        let icon = match &entry.icon {
            Some(PaletteIcon::Symbol(icon)) => div().text_color(secondary).child(*icon),
            Some(PaletteIcon::Provider(provider)) => {
                match super::chat_layout::provider_logo(provider) {
                    Some(logo) => {
                        div().child(img(logo).size(px(15.)).rounded(px(3.)).bg(rgb(0x2b2b2b)))
                    }
                    None => div().text_color(secondary).child(IconName::MessagesSquare),
                }
            }
            None => div(),
        };
        let mut label = entry.title.clone();
        if let Some(subtitle) = &entry.subtitle {
            label.push_str(", ");
            label.push_str(subtitle);
        }
        if !entry.enabled {
            label.push_str(", ");
            label.push_str(entry.disabled_reason.as_deref().unwrap_or("Unavailable"));
        }
        div()
            .id(SharedString::from(format!(
                "palette-{}",
                entry.command.key()
            )))
            .role(Role::Button)
            .aria_label(SharedString::from(label))
            .mx(px(6.))
            .px(px(6.))
            .h(px(if entry.subtitle.is_some() { 42. } else { 32. }))
            .flex_shrink_0()
            .flex()
            .items_center()
            .gap(px(10.))
            .rounded(px(8.))
            .when(selected, |row| row.bg(hex(self.colors.selection, 1.0)))
            .when(!entry.enabled, |row| row.opacity(0.5))
            .when(entry.enabled, |row| row.cursor_pointer())
            .on_mouse_move(cx.listener(move |this, _, _, cx| {
                if let Some(model) = &mut this.model
                    && model.selected.as_ref() != Some(&hovered)
                {
                    model.select(&hovered);
                    cx.notify();
                }
            }))
            .on_click(cx.listener(move |this, _, window, cx| this.activate(&command, window, cx)))
            .child(
                div()
                    .w(px(20.))
                    .flex_shrink_0()
                    .flex()
                    .justify_center()
                    .child(icon),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(div().text_sm().text_color(ink).truncate().child(title))
                    .when_some(entry.subtitle.clone(), |text, subtitle| {
                        text.child(
                            div()
                                .text_xs()
                                .text_color(secondary)
                                .truncate()
                                .child(subtitle),
                        )
                    })
                    .when(!entry.enabled, |text| {
                        text.child(
                            div().text_xs().text_color(secondary).child(
                                entry
                                    .disabled_reason
                                    .clone()
                                    .unwrap_or_else(|| "Unavailable".into()),
                            ),
                        )
                    }),
            )
            .when_some(entry.trailing.clone(), |row, trailing| {
                row.child(
                    div()
                        .flex_shrink_0()
                        .pr_2()
                        .text_xs()
                        .text_color(if selected { secondary } else { tertiary })
                        .child(trailing),
                )
            })
            .into_any_element()
    }
}

#[cfg(test)]
#[path = "command_palette_tests.rs"]
mod tests;
