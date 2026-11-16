//! User browser actions wait locally when the shared engine is busy. The
//! engine still admits and validates each action exactly once.
use super::*;
use std::collections::{HashSet, VecDeque};

pub(super) fn superseded_show(
    action: &BrowserAction,
    thread: &str,
    native: bool,
    visible: &HashSet<String>,
) -> bool {
    native && matches!(action, BrowserAction::Show) && !visible.contains(thread)
}

#[derive(Clone)]
pub(super) enum Intent {
    Action {
        thread: String,
        action: BrowserAction,
        tab: Option<String>,
    },
    Link {
        thread: String,
        url: String,
    },
}

pub(super) struct Admitted {
    pub id: String,
    pub thread: String,
    pub creates_tab: bool,
}

impl Intent {
    fn superseded(&self, visible: &HashSet<String>) -> bool {
        matches!(self, Self::Action { thread, action: BrowserAction::Show, .. } if !visible.contains(thread))
    }

    fn opens_tab(&self, owner: &str) -> bool {
        match self {
            Self::Action {
                thread,
                action: BrowserAction::NewTab { .. },
                ..
            }
            | Self::Link { thread, .. } => thread == owner,
            _ => false,
        }
    }

    fn admit(&self, engine: &SharedEngine) -> Result<Vec<Admitted>> {
        match self {
            Self::Action {
                thread,
                action,
                tab,
            } => {
                let mut params = serde_json::to_value(action)?;
                params["threadId"] = json!(thread);
                if let Some(tab) = tab {
                    params["tab"] = json!(tab);
                }
                let result = call(engine, "browser.request", params)?;
                Ok(vec![Admitted {
                    id: text(&result, "operationId"),
                    thread: thread.clone(),
                    creates_tab: matches!(action, BrowserAction::NewTab { .. }),
                }])
            }
            Self::Link { thread, url } => {
                let link = try_state(engine)?.open_browser_link_in_new_tab(thread, url)?;
                Ok(vec![
                    Admitted {
                        id: link.tab_operation,
                        thread: link.thread.clone(),
                        creates_tab: true,
                    },
                    Admitted {
                        id: link.show_operation,
                        thread: link.thread,
                        creates_tab: false,
                    },
                ])
            }
        }
    }
}

#[derive(Default)]
pub(super) struct Queue(VecDeque<Intent>);

impl Queue {
    pub(super) fn push(&mut self, intent: Intent) -> Result<()> {
        anyhow::ensure!(self.0.len() < 128, "Browser is busy; try again");
        self.0.push_back(intent);
        Ok(())
    }

    pub(super) fn opens_tab_for(&self, thread: &str) -> bool {
        self.0.iter().any(|intent| intent.opens_tab(thread))
    }

    /// Leave an unadmitted action in place on contention. Each successful
    /// engine admission is removed before another attempt can run.
    pub(super) fn poll(
        &mut self,
        engine: &SharedEngine,
        visible: &HashSet<String>,
    ) -> (Vec<Admitted>, Option<String>) {
        let mut admitted = Vec::new();
        while let Some(intent) = self.0.front() {
            if intent.superseded(visible) {
                self.0.pop_front();
                continue;
            }
            match intent.admit(engine) {
                Ok(operations) => {
                    admitted.extend(operations);
                    self.0.pop_front();
                }
                Err(error) if engine_busy(&error) => break,
                Err(error) => {
                    self.0.pop_front();
                    return (admitted, Some(error.to_string()));
                }
            }
        }
        (admitted, None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::{api::Engine, store::Store};
    use std::sync::{Arc, Mutex};

    #[::core::prelude::v1::test]
    fn busy_engine_keeps_link_and_show_until_they_can_be_admitted_once() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let id = engine.dispatch_desktop(json!({"method":"threads.create","params":{}}))["result"]
            ["id"]
            .as_str()
            .unwrap()
            .to_owned();
        engine.ui_available = true;
        let engine = Arc::new(Mutex::new(engine));
        let mut queue = Queue::default();
        queue
            .push(Intent::Link {
                thread: id.clone(),
                url: "https://example.com/".into(),
            })
            .unwrap();
        queue
            .push(Intent::Action {
                thread: id.clone(),
                action: BrowserAction::Show,
                tab: None,
            })
            .unwrap();
        assert!(queue.opens_tab_for(&id));
        assert!(!queue.opens_tab_for("another-thread"));
        let visible = HashSet::from([id]);
        let lock = engine.lock().unwrap();
        assert!(queue.poll(&engine, &visible).0.is_empty());
        assert_eq!(queue.0.len(), 2);
        drop(lock);
        let (operations, error) = queue.poll(&engine, &visible);
        assert!(error.is_none());
        assert_eq!(operations.len(), 3);
        assert_eq!(operations.iter().filter(|op| op.creates_tab).count(), 1);
        assert!(queue.0.is_empty());
        assert!(queue.poll(&engine, &visible).0.is_empty());
    }

    #[::core::prelude::v1::test]
    fn hidden_show_is_discarded_without_discarding_a_user_link() {
        let mut queue = Queue::default();
        queue
            .push(Intent::Action {
                thread: "one".into(),
                action: BrowserAction::Show,
                tab: None,
            })
            .unwrap();
        queue
            .push(Intent::Link {
                thread: "one".into(),
                url: "https://example.com/".into(),
            })
            .unwrap();
        assert!(queue.0[0].superseded(&HashSet::new()));
        assert!(!queue.0[1].superseded(&HashSet::new()));
        // This also covers a show already admitted before a later panel click.
        assert!(superseded_show(
            &BrowserAction::Show,
            "one",
            true,
            &HashSet::new()
        ));
        assert!(!superseded_show(
            &BrowserAction::Show,
            "one",
            false,
            &HashSet::new()
        ));
        assert!(!superseded_show(
            &BrowserAction::Show,
            "one",
            true,
            &HashSet::from(["one".into()])
        ));
    }
}
