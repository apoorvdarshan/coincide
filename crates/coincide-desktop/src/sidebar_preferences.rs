//! Swift-compatible interface preferences. Every write merges one field into
//! ui-state.json; unknown keys and sections survive this version's controls.
use super::*;
pub(super) const SECTIONS: [&str; 4] = ["bots", "pinned", "projects", "chats"];
#[derive(Clone)]
pub(super) struct Preferences {
    pub document: Value,
}
impl Preferences {
    pub fn load(engine: &SharedEngine) -> Self {
        let document = try_state(engine)
            .and_then(|engine| Ok(engine.store.document("ui-state.json")?.unwrap_or(json!({}))))
            .unwrap_or(Value::Null);
        Self { document }
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
                self.thread_bulk.invalidate();
                self.expanded_sidebar_lists.clear();
            }
            Err(error) => self.status = format!("Sidebar preference could not be saved: {error}"),
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
