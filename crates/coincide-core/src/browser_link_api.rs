//! Admission of user-clicked links into the owning conversation's browser.
use super::*;
use crate::browser_protocol::{BrowserAction, BrowserRequest};

/// Both operations belong to the same thread and must be collected by the UI.
pub struct QueuedBrowserLink {
    pub thread: String,
    pub tab_operation: String,
    pub show_operation: String,
}

impl Engine {
    /// Queue the new tab before showing the browser, atomically. Showing first
    /// would create an extra blank tab when the conversation has no tabs yet.
    pub fn open_browser_link_in_new_tab(
        &mut self,
        thread_id: &str,
        url: &str,
    ) -> Result<QueuedBrowserLink> {
        self.require_admissions()?;
        ensure!(self.ui_available, "Links open in the desktop browser");
        ensure!(
            !self.store.is_closed(),
            "Store is closed; link was not opened"
        );
        let thread = text(&self.store.thread(thread_id)?, "id");
        let tab_operation = Uuid::new_v4().to_string();
        let show_operation = Uuid::new_v4().to_string();
        let requests = [
            BrowserRequest {
                id: tab_operation.clone(),
                thread_id: thread.clone(),
                tab: None,
                frame: None,
                action: BrowserAction::NewTab {
                    url: Some(url.to_owned()),
                },
            },
            BrowserRequest {
                id: show_operation.clone(),
                thread_id: thread.clone(),
                tab: None,
                frame: None,
                action: BrowserAction::Show,
            },
        ];
        for request in &requests {
            request.validate()?;
        }
        ensure!(
            self.browser_pending.len() <= 126,
            "Browser queue is busy; link was not opened"
        );
        let revision = self
            .revision
            .checked_add(2)
            .context("Browser revision exhausted")?;
        for request in requests {
            self.browser_pending
                .insert(request.id.clone(), (thread.clone(), Instant::now()));
            self.browser_requests.push_back(request);
        }
        self.revision = revision;
        Ok(QueuedBrowserLink {
            thread,
            tab_operation,
            show_operation,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clicks_queue_separate_tabs_for_their_own_threads_before_showing() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let a = engine.execute("threads.create", &json!({})).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let b = engine.execute("threads.create", &json!({})).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        engine.ui_available = true;
        for (thread, url) in [
            (&a, "https://example.com/one"),
            (&a, "https://example.com/two"),
            (&b, "https://example.org/other"),
        ] {
            let queued = engine.open_browser_link_in_new_tab(thread, url).unwrap();
            assert_eq!(&queued.thread, thread);
            assert_ne!(queued.tab_operation, queued.show_operation);
        }
        let requests: Vec<_> = engine.browser_requests.iter().collect();
        assert_eq!(requests.len(), 6);
        for (pair, (thread, url)) in requests.as_chunks::<2>().0.iter().zip([
            (&a, "https://example.com/one"),
            (&a, "https://example.com/two"),
            (&b, "https://example.org/other"),
        ]) {
            assert_eq!(&pair[0].thread_id, thread);
            assert_eq!(&pair[1].thread_id, thread);
            assert!(
                matches!(&pair[0].action, BrowserAction::NewTab { url: Some(actual) } if actual == url)
            );
            assert!(matches!(pair[1].action, BrowserAction::Show));
        }
    }

    #[test]
    fn unavailable_invalid_or_full_queue_never_admits_half_a_link() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let id = engine.execute("threads.create", &json!({})).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(
            engine
                .open_browser_link_in_new_tab(&id, "https://example.com")
                .is_err()
        );
        engine.ui_available = true;
        assert!(
            engine
                .open_browser_link_in_new_tab(&id, "file:///private/data")
                .is_err()
        );
        assert!(engine.browser_requests.is_empty());
        for _ in 0..127 {
            engine
                .execute("browser.request", &json!({"threadId":id,"action":"tabs"}))
                .unwrap();
        }
        assert!(
            engine
                .open_browser_link_in_new_tab(&id, "https://example.com")
                .is_err()
        );
        assert_eq!(engine.browser_requests.len(), 127);
    }
}
