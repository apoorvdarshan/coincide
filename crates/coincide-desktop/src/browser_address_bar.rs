//! The browser panel's address field, as Swift's `PreviewViewController`: Enter
//! opens an address, a local file or a search with the user's engine, and
//! typing completes inline from bookmarks and the profile's history.
use coincide_core::api::SharedEngine;
use coincide_core::browser_address::{
    self, CompletionIndex, Destination, SearchEngine, reference_now,
};
use gpui_kit::{App, Entity, Task, Window, component::input::InputState};
use std::{
    path::PathBuf,
    sync::mpsc::{self, Receiver},
};
use uuid::Uuid;

pub const PLACEHOLDER: &str = "Search or enter address";
/// Swift `PreviewError.invalidAddress`.
pub const INVALID_ADDRESS: &str = "Enter an HTTP or HTTPS address without a username or password.";

/// What Enter in the address field opens. Only the user's own typing may open
/// local files; the agent API stays HTTP(S)-only.
pub fn destination(typed: &str, engine: SearchEngine) -> Option<Destination> {
    browser_address::resolve(
        typed,
        engine,
        true,
        &home_directory(),
        browser_address::is_regular_file,
    )
}

fn home_directory() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// Which saved libraries an index was read for: the thread and its persistent
/// profile. Private profiles complete nothing, as in Swift.
type Key = (String, Uuid);

#[derive(Default)]
pub struct Completion {
    key: Option<Key>,
    index: CompletionIndex,
    pending: Option<(Key, Receiver<CompletionIndex>, Task<()>)>,
    /// The length typed before this edit; completion only follows typing that
    /// adds to the end, so deleting never brings the completion back.
    typed_len: usize,
}

impl Completion {
    /// Reads the saved bookmarks and `profile`'s history off the UI thread.
    /// Unreadable libraries leave completion empty; they never block typing.
    pub fn load(&mut self, engine: &SharedEngine, thread: &str, profile: Option<Uuid>, cx: &App) {
        let Some(profile) = profile else {
            self.key = None;
            self.index = CompletionIndex::default();
            self.pending = None;
            return;
        };
        let key = (thread.to_owned(), profile);
        // Never complete from the previous profile while this profile loads.
        if self.key.as_ref() != Some(&key) {
            self.key = None;
            self.index = CompletionIndex::default();
        }
        if self
            .pending
            .as_ref()
            .is_some_and(|(pending, ..)| *pending == key)
        {
            return;
        }
        let engine = engine.clone();
        let (sender, receiver) = mpsc::sync_channel(1);
        let task = cx.background_executor().spawn(async move {
            let index = engine
                .lock()
                .ok()
                .map_or_else(CompletionIndex::default, |engine| {
                    CompletionIndex::from_libraries(
                        engine.saved_browser_bookmarks().ok().as_ref(),
                        engine.saved_browser_history(profile).ok().as_ref(),
                    )
                });
            let _ = sender.send(index);
        });
        self.pending = Some((key, receiver, task));
    }

    pub fn poll(&mut self) {
        let Some((key, receiver, _)) = &self.pending else {
            return;
        };
        match receiver.try_recv() {
            Ok(index) => {
                self.key = Some(key.clone());
                self.index = index;
                self.pending = None;
            }
            Err(mpsc::TryRecvError::Disconnected) => self.pending = None,
            Err(mpsc::TryRecvError::Empty) => {}
        }
    }

    /// The field gained focus with this text, like `controlTextDidBeginEditing`.
    pub fn begin_editing(&mut self, value: &str) {
        self.typed_len = value.len();
    }

    /// After an edit: completes inline when the user added to the end, keeping
    /// what they typed and selecting the added part.
    pub fn changed(
        &mut self,
        input: &Entity<InputState>,
        thread: Option<&str>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let (typed, cursor, selection) = {
            let state = input.read(cx);
            (
                state.value().to_string(),
                state.cursor(),
                state.selected_range(),
            )
        };
        let grew = typed.len() > self.typed_len;
        self.typed_len = typed.len();
        let current = self
            .key
            .as_ref()
            .is_some_and(|(owner, _)| Some(owner.as_str()) == thread);
        if !grew || !current || cursor != typed.len() || !selection.is_empty() {
            return;
        }
        let Some(completion) = self.index.inline_completion(&typed, reference_now()) else {
            return;
        };
        if completion.len() <= typed.len() || !completion.starts_with(typed.as_str()) {
            return;
        }
        let start = typed.len();
        input.update(cx, |state, cx| {
            state.set_value(completion.clone(), window, cx);
            state.set_selected_range(start..completion.len(), cx);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enter_opens_addresses_and_searches_with_the_chosen_engine() {
        assert_eq!(
            destination("localhost:3000", SearchEngine::Google),
            Some(Destination::Web(
                browser_address::Url::parse("http://localhost:3000/").unwrap()
            ))
        );
        let Some(Destination::Search(url)) = destination("rust gpui", SearchEngine::Ecosia) else {
            panic!("words must search");
        };
        assert_eq!(url.as_str(), "https://www.ecosia.org/search?q=rust+gpui");
        assert_eq!(
            destination("https://a:b@example.com", SearchEngine::Google),
            None
        );
    }

    #[test]
    fn typed_existing_files_open_and_missing_ones_search() {
        let folder = tempfile::tempdir().unwrap();
        let page = folder.path().join("index.html");
        std::fs::write(&page, "<p>synthetic</p>").unwrap();
        let typed = browser_address::Url::from_file_path(&page)
            .unwrap()
            .to_string();
        assert_eq!(
            destination(&typed, SearchEngine::Google),
            Some(Destination::File(browser_address::standardize(&page)))
        );
        assert_eq!(
            destination(folder.path().to_str().unwrap(), SearchEngine::Google)
                .map(|d| matches!(d, Destination::Search(_))),
            Some(true),
            "a folder is not a page"
        );
    }
}
