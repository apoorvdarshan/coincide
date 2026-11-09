//! Settings › Browser values the portable engine needs: the address bar's
//! search engine. Kept in `browser.json`, the Swift app's file, so a captured
//! Swift choice carries over and every other Swift field is preserved.
use super::*;
use crate::browser_address::SearchEngine;
use crate::browser_protocol::{BrowserAction, BrowserRequest};

const DOCUMENT: &str = "browser.json";

impl Engine {
    /// The saved engine; a missing, unknown or unreadable value is Google.
    pub fn browser_search_engine(&self) -> SearchEngine {
        SearchEngine::from_settings(self.store.document(DOCUMENT).ok().flatten().as_ref())
    }

    pub fn browser_agent_control_settings(&self) -> Value {
        let document = match self.store.document(DOCUMENT) {
            Ok(Some(document)) if document.is_object() => document,
            Ok(Some(_)) => json!({"agentControlByDefault":false}),
            Ok(None) => json!({}),
            Err(_) => json!({"agentControlByDefault":false}),
        };
        json!({"agentControlByDefault":document.get("agentControlByDefault").cloned().unwrap_or(json!(true)), "agentControl":document.get("agentControl").cloned().unwrap_or(json!({}))})
    }
    /// Native parent only. Agent request JSON cannot supply toolbar provenance.
    pub fn set_browser_agent_control(
        &mut self,
        thread: &str,
        enabled: bool,
        native_operations: &std::collections::HashSet<String>,
    ) -> Result<Value> {
        self.require_admissions()?;
        self.store.thread(thread)?;
        let document = self.store.document(DOCUMENT)?.unwrap_or(json!({}));
        let mut controls = match document.get("agentControl") {
            None => serde_json::Map::new(),
            Some(value) => value
                .as_object()
                .context("Saved Agent Control choices are invalid; nothing changed")?
                .clone(),
        };
        controls.retain(|id, _| !id.eq_ignore_ascii_case(thread));
        controls.insert(thread.into(), json!(enabled));
        let patch = json!({"agentControl":controls});
        self.store.patch_document(DOCUMENT, &patch)?;
        if !enabled {
            self.browser_requests.retain(|request| {
                request.thread_id != thread || native_operations.contains(&request.id)
            });
            for (id, (owner, _)) in &self.browser_pending {
                if owner == thread && !native_operations.contains(id) {
                    self.browser_results.insert(
                        id.clone(),
                        crate::browser_protocol::BrowserReply {
                            id: id.clone(),
                            thread_id: thread.into(),
                            result: json!({"error":"Agent Control was turned off"}),
                        },
                    );
                }
            }
        }
        self.revision += 1;
        Ok(self.browser_agent_control_settings())
    }
    pub fn set_browser_search_engine(&mut self, engine: SearchEngine) -> Result<()> {
        self.store
            .patch_document(DOCUMENT, &json!({"searchEngine":engine.id()}))?;
        self.revision += 1;
        Ok(())
    }

    /// Native Settings action only. The agent API deliberately cannot change
    /// the default permission for controlling a browser.
    pub fn set_browser_default_agent_control(&mut self, enabled: bool) -> Result<()> {
        self.require_admissions()?;
        self.store
            .patch_document(DOCUMENT, &json!({"agentControlByDefault":enabled}))?;
        self.revision += 1;
        Ok(())
    }

    fn browser_settings_reply(&self) -> Value {
        let control = self.browser_agent_control_settings();
        json!({
            "searchEngine": self.browser_search_engine().id(),
            "agentControlByDefault": control["agentControlByDefault"],
            "agentControl": control["agentControl"],
            "searchEngines": SearchEngine::ALL
                .iter()
                .map(|engine| json!({"id":engine.id(),"name":engine.name()}))
                .collect::<Vec<_>>(),
        })
    }

    pub(super) fn browser_settings_command(
        &mut self,
        method: &str,
        params: &Value,
    ) -> Result<Value> {
        let fields = params
            .as_object()
            .context("Browser settings parameters must be an object")?;
        match method {
            "browser.settings.read" => {
                ensure!(
                    fields.is_empty(),
                    "Browser settings read accepts no options"
                );
                Ok(self.browser_settings_reply())
            }
            "browser.settings.patch" => {
                ensure!(
                    fields.keys().all(|key| key == "searchEngine"),
                    "Only searchEngine can be changed here"
                );
                if let Some(value) = fields.get("searchEngine") {
                    let engine = value
                        .as_str()
                        .and_then(SearchEngine::from_id)
                        .context("Unknown search engine")?;
                    self.set_browser_search_engine(engine)?;
                }
                Ok(self.browser_settings_reply())
            }
            _ => anyhow::bail!("Unsupported browser settings method"),
        }
    }

    /// An agent's `search` becomes a navigation to the user's search engine's
    /// results page, so the browser only ever receives an HTTP(S) address.
    pub(super) fn resolve_browser_search(&self, request: &mut BrowserRequest) -> Result<()> {
        if let BrowserAction::Search { query } = &request.action {
            let url = self
                .browser_search_engine()
                .url(query.trim())
                .context("The search could not be prepared")?;
            request.action = BrowserAction::Navigate { url: url.into() };
            request.validate()?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_default_control_preserves_overrides_and_cannot_be_changed_by_the_api() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        engine.store.save_document(DOCUMENT, &json!({"searchEngine":"bing","agentControl":{"thread":true},"profileID":"unchanged"})).unwrap();
        engine.set_browser_default_agent_control(false).unwrap();
        let stored = engine.store.document(DOCUMENT).unwrap().unwrap();
        assert_eq!(stored["agentControlByDefault"], false);
        assert_eq!(stored["agentControl"]["thread"], true);
        assert_eq!(stored["searchEngine"], "bing");
        assert_eq!(stored["profileID"], "unchanged");
        assert!(
            engine
                .execute(
                    "browser.settings.patch",
                    &json!({"agentControlByDefault":true})
                )
                .is_err()
        );
        assert_eq!(
            engine.browser_agent_control_settings()["agentControlByDefault"],
            false
        );
    }

    #[test]
    fn native_control_revokes_pending_agent_replies_but_preserves_native_operations() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        engine.ui_available = true;
        let thread = engine.execute("threads.create", &json!({})).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        engine.store.save_document(DOCUMENT, &json!({"searchEngine":"bing", "agentControlByDefault":false, "agentControl":{thread.clone():true,"other-thread":false}, "profileID":"preserved"})).unwrap();
        let agent = engine
            .execute(
                "browser.request",
                &json!({"threadId":thread,"action":"read"}),
            )
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_owned();
        let native = engine
            .execute(
                "browser.request",
                &json!({"threadId":thread,"action":"show"}),
            )
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_owned();
        let native_operations = std::collections::HashSet::from([native.clone()]);
        let saved = engine
            .set_browser_agent_control(&thread, false, &native_operations)
            .unwrap();
        assert_eq!(saved["agentControl"][&thread], false);
        assert_eq!(saved["agentControl"]["other-thread"], false);
        assert_eq!(engine.browser_requests.len(), 1);
        assert_eq!(engine.browser_requests[0].id, native);
        engine
            .set_browser_agent_control(&thread, true, &native_operations)
            .unwrap();
        engine.browser_reply(crate::browser_protocol::BrowserReply {
            id: agent.clone(),
            thread_id: thread.clone(),
            result: json!({"text":"late renderer data"}),
        });
        let result = engine
            .execute(
                "browser.result",
                &json!({"threadId":thread,"operationId":agent}),
            )
            .unwrap();
        assert_eq!(result["result"]["error"], "Agent Control was turned off");
        assert!(result["result"].get("text").is_none());
        assert_eq!(
            engine.store.document(DOCUMENT).unwrap().unwrap()["profileID"],
            "preserved"
        );
        assert_eq!(engine.browser_search_engine(), SearchEngine::Bing);
        assert!(
            engine
                .execute(
                    "browser.settings.patch",
                    &json!({"agentControl":{thread:false}})
                )
                .is_err()
        );
    }

    #[test]
    fn search_engine_is_saved_beside_swift_fields_and_rewrites_agent_searches() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        assert_eq!(engine.browser_search_engine(), SearchEngine::Google);
        engine
            .store
            .save_document(
                DOCUMENT,
                &json!({"profileID":"opaque","searchEngine":"bing"}),
            )
            .unwrap();
        let read = engine.execute("browser.settings.read", &json!({})).unwrap();
        assert_eq!(read["searchEngine"], "bing");
        assert_eq!(read["searchEngines"].as_array().unwrap().len(), 6);
        assert!(
            engine
                .execute("browser.settings.read", &json!({"x":1}))
                .is_err()
        );
        assert!(
            engine
                .execute("browser.settings.patch", &json!({"searchEngine":"future"}))
                .is_err()
        );
        assert!(
            engine
                .execute("browser.settings.patch", &json!({"profileID":"x"}))
                .is_err()
        );
        let patched = engine
            .execute(
                "browser.settings.patch",
                &json!({"searchEngine":"duckDuckGo"}),
            )
            .unwrap();
        assert_eq!(patched["searchEngine"], "duckDuckGo");
        assert_eq!(
            engine.store.document(DOCUMENT).unwrap().unwrap()["profileID"],
            "opaque"
        );

        let thread = Uuid::new_v4().to_string();
        let mut request: BrowserRequest = serde_json::from_value(
            json!({"id":"s","threadId":thread,"action":"search","query":" rust book "}),
        )
        .unwrap();
        engine.resolve_browser_search(&mut request).unwrap();
        assert!(matches!(
            &request.action,
            BrowserAction::Navigate { url } if url == "https://duckduckgo.com/?q=rust+book"
        ));
    }
}
