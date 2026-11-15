//! Bounded, off-window-thread indexing for long conversations. The native
//! Markdown parser supplies the same plain text used by the highlight view.
use super::transcript_find::{FindItem, Match, TranscriptFind, match_ranges};
use gpui_kit::{Context, Task};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
};

const MAX_MATCHES: usize = 10_000;
type Indexed = (String, Arc<str>, Arc<str>);
struct IndexResult {
    entries: Vec<Indexed>,
    incomplete: bool,
}

struct Job<T> {
    receiver: mpsc::Receiver<T>,
    cancel: Arc<AtomicBool>,
    _task: Task<()>,
}
impl<T> Drop for Job<T> {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
    }
}

struct SearchResult {
    query: String,
    version: u64,
    sources: HashMap<String, Arc<str>>,
    matches: Vec<Match>,
    truncated: bool,
}
pub(super) struct ReadySearch {
    pub matches: Vec<Match>,
    pub truncated: bool,
}

pub(super) struct LargeFind {
    pub items: Vec<FindItem>,
    plain: Vec<Option<Arc<str>>>,
    index: Option<Job<IndexResult>>,
    search: Option<Job<SearchResult>>,
    version: u64,
    searched_version: Option<u64>,
    searched_query: String,
    incomplete: bool,
    index_failed: bool,
    search_failed: bool,
}
impl LargeFind {
    pub fn new(items: Vec<FindItem>) -> Self {
        Self {
            plain: vec![None; items.len()],
            items,
            index: None,
            search: None,
            version: 0,
            searched_version: None,
            searched_query: String::new(),
            incomplete: false,
            index_failed: false,
            search_failed: false,
        }
    }
    /// Keep parsed text for unchanged items, even while the last response is
    /// streaming. An in-flight index may finish and is checked against each
    /// current source before any of its results are accepted.
    pub fn replace(&mut self, items: Vec<FindItem>) {
        let old = std::mem::take(&mut self.items);
        let old_plain = std::mem::take(&mut self.plain);
        let mut by_id: HashMap<_, _> = old
            .into_iter()
            .zip(old_plain)
            .map(|(item, plain)| (item.item_id, (item.source, plain)))
            .collect();
        self.plain = items
            .iter()
            .map(|item| {
                by_id
                    .remove(&item.item_id)
                    .and_then(|(source, plain)| (source == item.source).then_some(plain).flatten())
            })
            .collect();
        self.items = items;
        self.version = self.version.wrapping_add(1);
    }
    pub fn pending(&self) -> usize {
        self.plain.iter().filter(|text| text.is_none()).count()
    }
    pub fn searching(&self) -> bool {
        self.search.is_some()
    }
    pub fn error(&self) -> Option<&'static str> {
        if self.index_failed || self.search_failed {
            Some("Search stopped unexpectedly. Close and reopen Find to retry.")
        } else if self.incomplete {
            Some("Some messages could not be searched.")
        } else {
            None
        }
    }
    pub fn source(&self, id: &str) -> Option<&Arc<str>> {
        self.items
            .iter()
            .find(|item| item.item_id == id)
            .map(|item| &item.source)
    }
    pub fn plain(&self, id: &str) -> Option<&str> {
        let index = self.items.iter().position(|item| item.item_id == id)?;
        self.plain[index].as_deref()
    }
    pub fn start_index(&mut self, cx: &mut Context<TranscriptFind>) {
        if self.index.is_some() || self.index_failed {
            return;
        }
        let entries: Vec<_> = self
            .items
            .iter()
            .zip(&self.plain)
            .filter(|(_, text)| text.is_none())
            .map(|(item, _)| (item.item_id.clone(), item.source.clone()))
            .collect();
        if entries.is_empty() {
            return;
        }
        let (sender, receiver) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        let stopped = cancel.clone();
        let task = cx.background_executor().spawn(async move {
            let mut parsed = Vec::with_capacity(entries.len());
            let mut cache: HashMap<Arc<str>, Arc<str>> = HashMap::new();
            let mut incomplete = false;
            for (id, source) in entries {
                if stopped.load(Ordering::Relaxed) {
                    return;
                }
                let text = if let Some(text) = cache.get(&source) {
                    text.clone()
                } else {
                    let text: Arc<str> = match gpui_kit::base::text::markdown_plain_text(&source) {
                        Ok(text) => text,
                        Err(_) => {
                            incomplete = true;
                            String::new()
                        }
                    }
                    .into();
                    cache.insert(source.clone(), text.clone());
                    text
                };
                parsed.push((id, source, text));
            }
            let _ = sender.send(IndexResult {
                entries: parsed,
                incomplete,
            });
        });
        self.index = Some(Job {
            receiver,
            cancel,
            _task: task,
        });
    }
    pub fn poll_index(&mut self) -> bool {
        let Some(job) = &self.index else {
            return false;
        };
        let result = match job.receiver.try_recv() {
            Ok(result) => result,
            Err(mpsc::TryRecvError::Empty) => return false,
            Err(mpsc::TryRecvError::Disconnected) => {
                self.index = None;
                self.index_failed = true;
                return true;
            }
        };
        self.index = None;
        let positions: HashMap<_, _> = self
            .items
            .iter()
            .enumerate()
            .map(|(i, item)| (item.item_id.as_str(), i))
            .collect();
        self.incomplete |= result.incomplete;
        for (id, source, plain) in result.entries {
            if let Some(&index) = positions.get(id.as_str())
                && self.items[index].source == source
            {
                self.plain[index] = Some(plain);
            }
        }
        self.version = self.version.wrapping_add(1);
        true
    }
    pub fn cancel_search(&mut self) {
        self.search = None;
        self.searched_version = None;
        self.searched_query.clear();
        self.search_failed = false;
    }
    pub fn start_search(&mut self, query: &str, cx: &mut Context<TranscriptFind>) {
        if query.is_empty()
            || self.search_failed
            || self.search.is_some()
            || (self.searched_version == Some(self.version) && self.searched_query == query)
        {
            return;
        }
        let entries: Vec<_> = self
            .items
            .iter()
            .zip(&self.plain)
            .filter_map(|(item, plain)| {
                plain
                    .as_ref()
                    .map(|plain| (item.item_id.clone(), item.source.clone(), plain.clone()))
            })
            .collect();
        if entries.is_empty() {
            return;
        }
        let (sender, receiver) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        let stopped = cancel.clone();
        let query = query.to_owned();
        let version = self.version;
        let task = cx.background_executor().spawn(async move {
            let mut sources = HashMap::with_capacity(entries.len());
            let mut matches = Vec::new();
            let mut truncated = false;
            for (id, source, plain) in entries {
                if stopped.load(Ordering::Relaxed) {
                    return;
                }
                let (ranges, limited) = match_ranges(&plain, &query, MAX_MATCHES - matches.len());
                matches.extend(ranges.into_iter().map(|range| Match {
                    item: id.clone(),
                    range,
                }));
                sources.insert(id, source);
                if limited {
                    truncated = true;
                    break;
                }
            }
            let _ = sender.send(SearchResult {
                query,
                version,
                sources,
                matches,
                truncated,
            });
        });
        self.search = Some(Job {
            receiver,
            cancel,
            _task: task,
        });
    }
    pub fn poll_search(&mut self, query: &str) -> Option<ReadySearch> {
        let job = self.search.as_ref()?;
        let result = match job.receiver.try_recv() {
            Ok(result) => result,
            Err(mpsc::TryRecvError::Empty) => return None,
            Err(mpsc::TryRecvError::Disconnected) => {
                self.search = None;
                self.search_failed = true;
                return None;
            }
        };
        self.search = None;
        if result.query != query {
            return None;
        }
        self.searched_version = Some(result.version);
        self.searched_query = result.query;
        let positions: HashMap<_, _> = self
            .items
            .iter()
            .enumerate()
            .map(|(i, item)| (item.item_id.as_str(), (i, &item.source)))
            .collect();
        let mut matches: Vec<_> = result
            .matches
            .into_iter()
            .filter(|matched| {
                positions
                    .get(matched.item.as_str())
                    .is_some_and(|(_, current)| {
                        result
                            .sources
                            .get(&matched.item)
                            .is_some_and(|source| source == *current)
                    })
            })
            .collect();
        matches.sort_by_key(|matched| {
            positions
                .get(matched.item.as_str())
                .map(|(i, _)| *i)
                .unwrap_or(usize::MAX)
        });
        Some(ReadySearch {
            matches,
            truncated: result.truncated,
        })
    }
}
