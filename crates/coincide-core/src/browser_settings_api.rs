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

    pub fn set_browser_search_engine(&mut self, engine: SearchEngine) -> Result<()> {
        self.store
            .patch_document(DOCUMENT, &json!({"searchEngine":engine.id()}))?;
        self.revision += 1;
        Ok(())
    }

    fn browser_settings_reply(&self) -> Value {
        json!({
            "searchEngine": self.browser_search_engine().id(),
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
