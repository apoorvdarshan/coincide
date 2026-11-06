//! Swift-compatible interface preferences. Every write merges one field into
//! ui-state.json; unknown keys and sections survive this version's controls.
use super::*;
pub(super) const SECTIONS: [&str; 4] = ["bots", "pinned", "projects", "chats"];
#[derive(Clone)]
pub(super) struct Preferences {
    pub document: Value,
    pub pending: bool,
    pub error: Option<String>,
}
impl Preferences {
    pub fn load(engine: &SharedEngine) -> Self {
        let mut state = Self {
            document: json!({}),
            pending: true,
            error: None,
        };
        state.retry(engine);
        state
    }
    pub fn retry(&mut self, engine: &SharedEngine) -> bool {
        if !self.pending {
            return false;
        }
        let result = try_state(engine)
            .and_then(|engine| Ok(engine.store.document("ui-state.json")?.unwrap_or(json!({}))));
        match result {
            Ok(document) => {
                self.document = document;
                self.pending = false;
                self.error = None;
                true
            }
            Err(error) if engine_busy(&error) => false,
            Err(error) => {
                self.pending = false;
                self.error = Some(format!(
                    "Saved sidebar preferences could not be read: {error}"
                ));
                false
            }
        }
    }
    pub fn flag(&self, key: &str) -> bool {
        self.document[key].as_bool().unwrap_or(false)
    }
    pub fn strings(&self, key: &str) -> Vec<String> {
        self.document[key]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    }
    pub fn order(&self) -> Vec<String> {
        normalized_order(&self.strings("sidebarSections"))
    }
    pub fn collapsed(&self, section: &str) -> bool {
        self.strings("collapsedSections")
            .iter()
            .any(|id| id == section)
    }
    pub fn sort(&self, key: &str) -> &str {
        if key == "botSort" && !self.flag("choseBotSort") {
            return "recentActivity";
        }
        self.document[key]
            .as_str()
            .unwrap_or(if key == "projectSort" {
                "manual"
            } else {
                "recentActivity"
            })
    }
    pub fn limit(&self, height: f32) -> usize {
        self.document["sidebarThreadsPerProject"]
            .as_u64()
            .map(|value| value.min(10000) as usize)
            .unwrap_or_else(|| super::navigation::automatic_sidebar_limit(height))
    }
}
pub(super) fn normalized_order(saved: &[String]) -> Vec<String> {
    let mut result = Vec::new();
    for id in saved {
        if SECTIONS.contains(&id.as_str()) && !result.contains(id) {
            result.push(id.clone());
        }
    }
    for id in SECTIONS {
        if !result.iter().any(|known| known == id) {
            result.push(id.into());
        }
    }
    result
}
pub(super) fn moved(saved: &[String], item: &str, before: Option<&str>) -> Vec<String> {
    let mut result = normalized_order(saved);
    result.retain(|id| id != item);
    let index = before
        .and_then(|target| result.iter().position(|id| id == target))
        .unwrap_or(result.len());
    result.insert(index, item.into());
    result.extend(
        saved
            .iter()
            .filter(|id| !SECTIONS.contains(&id.as_str()))
            .cloned(),
    );
    result
}
impl Coincide {
    pub(super) fn sidebar_preference(&mut self, key: &str, value: Value, cx: &mut Context<Self>) {
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
            let current = engine.store.document("ui-state.json")?.unwrap_or(json!({}));
            anyhow::ensure!(
                current.is_object(),
                "Interface preferences are invalid; existing data was retained"
            );
            let mut patch = json!({});
            patch[key] = value;
            engine.store.patch_document("ui-state.json", &patch)
        })();
        match result {
            Ok(document) => {
                self.sidebar_preferences.document = document;
                self.sidebar_preferences.pending = false;
                self.sidebar_preferences.error = None;
                self.thread_bulk.invalidate();
                self.expanded_sidebar_lists.clear();
            }
            Err(error) => self.status = format!("Sidebar preference could not be saved: {error}"),
        }
        cx.notify();
    }
    pub(super) fn sidebar_thread_marker(
        &mut self,
        key: &str,
        id: &str,
        value: Option<Value>,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
            let current = engine.store.document("ui-state.json")?.unwrap_or(json!({}));
            anyhow::ensure!(current.is_object(), "Invalid interface preferences");
            let mut entries = current[key].as_object().cloned().unwrap_or_default();
            if let Some(value) = value {
                entries.insert(id.into(), value);
            } else {
                entries.remove(id);
            }
            let mut patch = json!({});
            patch[key] = json!(entries);
            engine.store.patch_document("ui-state.json", &patch)
        })();
        match result {
            Ok(document) => {
                self.sidebar_preferences.document = document;
                self.sidebar_preferences.pending = false;
                self.sidebar_preferences.error = None;
                self.thread_bulk.invalidate();
            }
            Err(error) => self.status = format!("Conversation marker could not be saved: {error}"),
        }
        cx.notify();
    }
    pub(super) fn toggle_sidebar_section(&mut self, section: &str, cx: &mut Context<Self>) {
        let mut collapsed = self.sidebar_preferences.strings("collapsedSections");
        if self.sidebar_preferences.collapsed(section) {
            collapsed.retain(|id| id != section);
        } else {
            collapsed.push(section.into());
        }
        self.sidebar_preference("collapsedSections", json!(collapsed), cx);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn section_moves_preserve_future_sections_and_deduplicate_known_sections() {
        let saved = vec![
            "chats".into(),
            "future".into(),
            "chats".into(),
            "bots".into(),
        ];
        assert_eq!(
            normalized_order(&saved),
            ["chats", "bots", "pinned", "projects"]
        );
        assert_eq!(
            moved(&saved, "projects", Some("bots")),
            ["chats", "projects", "bots", "pinned", "future"]
        );
    }
}

#[cfg(test)]
mod readiness_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn busy_owner_retains_pending_preferences_and_reloads_saved_values_after_release() {
        let root = std::env::temp_dir().join(format!("sidebar-readiness-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let mut store = Store::open(&root.join("ui.sqlite")).unwrap();
        store.save_document("ui-state.json",&json!({"sidebarSections":["chats","bots"],"collapsedSections":["projects"],"future":{"keep":true}})).unwrap();
        let engine = Arc::new(Mutex::new(coincide_core::api::Engine::new(store)));
        let guard = engine.lock().unwrap();
        let mut preferences = Preferences::load(&engine);
        assert!(preferences.pending);
        assert!(!preferences.retry(&engine));
        drop(guard);
        assert!(preferences.retry(&engine));
        assert!(!preferences.pending);
        assert_eq!(preferences.order(), ["chats", "bots", "pinned", "projects"]);
        assert!(preferences.collapsed("projects"));
        assert_eq!(preferences.document["future"]["keep"], true);
        assert!(!preferences.retry(&engine));
        drop(engine);
        std::fs::remove_dir_all(root).unwrap();
    }
}
