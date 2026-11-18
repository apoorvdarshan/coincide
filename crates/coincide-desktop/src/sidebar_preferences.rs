//! Swift-compatible interface preferences. Every write merges one field into
//! ui-state.json; unknown keys and sections survive this version's controls.
use super::*;
use std::collections::BTreeMap;
pub(super) const SECTIONS: [&str; 4] = ["bots", "pinned", "projects", "chats"];
#[derive(Clone)]
pub(super) struct Preferences {
    pub document: Value,
    pub pending: bool,
    pub error: Option<String>,
    expansion: Expansion,
}
#[derive(Clone, Default)]
struct Expansion {
    project_expansion: BTreeMap<String, bool>,
    section_collapse: BTreeMap<String, bool>,
}
impl Preferences {
    pub fn load(engine: &SharedEngine) -> Self {
        let mut state = Self {
            document: json!({}),
            pending: true,
            error: None,
            expansion: Expansion::default(),
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
        self.expansion
            .section_collapse
            .get(section)
            .copied()
            .unwrap_or_else(|| {
                self.document["collapsedSections"]
                    .as_array()
                    .is_some_and(|ids| ids.iter().any(|id| id == section))
            })
    }
    pub fn toggle_section(&mut self, section: &str) {
        let collapsed = !self.collapsed(section);
        self.expansion
            .section_collapse
            .insert(section.into(), collapsed);
    }
    pub fn set_project_expanded(&mut self, id: &str, expanded: bool) {
        self.expansion.project_expansion.insert(id.into(), expanded);
    }
    pub fn project_expanded(&self, project: &Value) -> bool {
        project["id"]
            .as_str()
            .and_then(|id| self.expansion.project_expansion.get(id))
            .copied()
            .unwrap_or(project["isExpanded"] != false)
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

impl Expansion {
    fn is_empty(&self) -> bool {
        self.project_expansion.is_empty() && self.section_collapse.is_empty()
    }

    fn save(&self, engine: &SharedEngine) -> Result<Option<Value>> {
        let mut engine = try_state(engine)?;
        anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
        let sections = if self.section_collapse.is_empty() {
            None
        } else {
            let current = engine.store.document("ui-state.json")?.unwrap_or(json!({}));
            anyhow::ensure!(current.is_object(), "Interface preferences are invalid");
            let mut collapsed = current["collapsedSections"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            for (id, closed) in &self.section_collapse {
                collapsed.retain(|entry| entry != id);
                if *closed {
                    collapsed.push(json!(id));
                }
            }
            let mut document = engine
                .store
                .patch_document("ui-state.json", &json!({"collapsedSections": collapsed}))?;
            Some(document["collapsedSections"].take())
        };
        if !self.project_expansion.is_empty() {
            let mut document = engine.store.projects()?;
            let projects = document.as_array_mut().context("Invalid projects")?;
            self.apply_projects(projects);
            engine.store.save_document("projects.json", &document)?;
            engine.revision += 1;
        }
        Ok(sections)
    }

    fn apply_projects(&self, projects: &mut [Value]) {
        for project in projects {
            if let Some(expanded) = project["id"]
                .as_str()
                .and_then(|id| self.project_expansion.get(id))
            {
                project["isExpanded"] = json!(expanded);
            }
        }
    }

    fn remove_saved(&mut self, saved: &Self) {
        self.project_expansion
            .retain(|id, value| saved.project_expansion.get(id) != Some(value));
        self.section_collapse
            .retain(|id, value| saved.section_collapse.get(id) != Some(value));
    }
}
/// Numeric runs compare by value, matching the sidebar's natural name order.
pub(super) fn name_order(left: &str, right: &str) -> std::cmp::Ordering {
    let left = left.to_lowercase();
    let right = right.to_lowercase();
    let mut left = left.chars().peekable();
    let mut right = right.chars().peekable();
    loop {
        match (left.peek(), right.peek()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, _) => return std::cmp::Ordering::Less,
            (_, None) => return std::cmp::Ordering::Greater,
            (Some(a), Some(b)) if a.is_ascii_digit() && b.is_ascii_digit() => {
                let mut a = String::new();
                while left.peek().is_some_and(char::is_ascii_digit) {
                    a.push(left.next().unwrap());
                }
                let mut b = String::new();
                while right.peek().is_some_and(char::is_ascii_digit) {
                    b.push(right.next().unwrap());
                }
                let a = a.trim_start_matches('0');
                let b = b.trim_start_matches('0');
                let order = a.len().cmp(&b.len()).then_with(|| a.cmp(b));
                if order != std::cmp::Ordering::Equal {
                    return order;
                }
            }
            _ => {
                let order = left.next().cmp(&right.next());
                if order != std::cmp::Ordering::Equal {
                    return order;
                }
            }
        }
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
    if before == Some(item) {
        return saved.to_vec();
    }
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
        self.sidebar_thread_markers(key, &[(id.to_owned(), value)], cx);
    }
    /// Several conversations' markers in one saved change, so a bulk action
    /// and its Undo never leave part of a selection changed.
    pub(super) fn sidebar_thread_markers(
        &mut self,
        key: &str,
        values: &[(String, Option<Value>)],
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
            let current = engine.store.document("ui-state.json")?.unwrap_or(json!({}));
            anyhow::ensure!(current.is_object(), "Invalid interface preferences");
            let mut entries = current[key].as_object().cloned().unwrap_or_default();
            for (id, value) in values {
                if let Some(value) = value {
                    entries.insert(id.clone(), value.clone());
                } else {
                    entries.remove(id);
                }
            }
            let mut patch = json!({});
            patch[key] = json!(entries);
            let document = engine.store.patch_document("ui-state.json", &patch)?;
            if key == "unseen" {
                engine.revision += 1;
            }
            Ok(document)
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
        self.sidebar_preferences.toggle_section(section);
        self.thread_bulk.invalidate();
        self.expanded_sidebar_lists.clear();
        cx.notify();
    }

    pub(super) fn flush_sidebar_expansion(&mut self, cx: &mut Context<Self>) -> bool {
        if self.sidebar_expansion_saving {
            return false;
        }
        if self.sidebar_preferences.expansion.is_empty() {
            return true;
        }
        // A small SQLite write can still wait on a checkpoint. Keep it, and
        // the engine lock attempt, off the input and rendering thread.
        self.sidebar_expansion_saving = true;
        let expansion = self.sidebar_preferences.expansion.clone();
        let engine = self.engine.clone();
        let work = cx.background_executor().spawn(async move {
            let result = expansion.save(&engine);
            (expansion, result)
        });
        cx.spawn(async move |this, cx| {
            let (attempt, result) = work.await;
            this.update(cx, |this, cx| {
                this.sidebar_expansion_saving = false;
                if let Err(error) = &result
                    && engine_busy(error)
                {
                    return;
                }
                this.sidebar_preferences.expansion.remove_saved(&attempt);
                match result {
                    Ok(sections) => {
                        if let Some(sections) = sections {
                            this.sidebar_preferences.document["collapsedSections"] = sections;
                        }
                        if !attempt.project_expansion.is_empty() {
                            attempt.apply_projects(&mut this.projects);
                            this.sync_collapsed_projects();
                        }
                    }
                    Err(error) => {
                        this.sidebar_preferences.error =
                            Some(format!("Sidebar expansion could not be saved: {error}"));
                        this.sync_collapsed_projects();
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        false
    }

    pub(super) fn sidebar_preferences_notice(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let error = self.sidebar_preferences.error.as_ref()?;
        Some(
            div()
                .id("sidebar-preferences-notice")
                .w(px(360.))
                .max_w_full()
                .p_3()
                .rounded(px(10.))
                .border_1()
                .border_color(self.color(0x29303d))
                .bg(self.color(0x151922))
                .flex()
                .items_center()
                .gap_2()
                .child(div().flex_1().min_w_0().text_sm().child(error.clone()))
                .child(
                    Button::new("sidebar-preferences-dismiss")
                        .ghost()
                        .compact()
                        .icon(gpui_kit::assets::IconName::X)
                        .accessibility_label("Dismiss notification")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.sidebar_preferences.error = None;
                            cx.notify();
                        })),
                )
                .into_any_element(),
        )
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn dropping_section_on_itself_preserves_exact_order_and_unknown_entries() {
        let saved = vec![
            "chats".into(),
            "future-section".into(),
            "bots".into(),
            "projects".into(),
        ];
        assert_eq!(moved(&saved, "bots", Some("bots")), saved);
    }
    #[::core::prelude::v1::test]
    fn numeric_names_order_naturally_and_case_ties_remain_available_to_activity_ordering() {
        assert!(name_order("Project 2", "project 10").is_lt());
        assert_eq!(name_order("AGENT 02", "agent 2"), std::cmp::Ordering::Equal);
        assert!(
            name_order(
                "Thread 999999999999999999999999999999",
                "Thread 1000000000000000000000000000000"
            )
            .is_lt()
        );
    }
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
    fn expansion_updates_during_contention_and_merges_with_newer_saved_fields() {
        let root = tempfile::tempdir().unwrap();
        let mut store = Store::open(&root.path().join("ui.sqlite")).unwrap();
        let mut projects = json!([
            {"id":"one","name":"One","isExpanded":true},
            {"id":"two","name":"Two","isExpanded":true},
        ]);
        store.save_document("projects.json", &projects).unwrap();
        let engine = Arc::new(Mutex::new(coincide_core::api::Engine::new(store)));
        let mut preferences = Preferences::load(&engine);
        let mut busy = engine.lock().unwrap();
        preferences.set_project_expanded("one", false);
        preferences.toggle_section("chats");
        assert!(!preferences.project_expanded(&projects[0]));
        assert!(preferences.collapsed("chats"));
        let first_attempt = preferences.expansion.clone();
        assert!(
            first_attempt
                .save(&engine)
                .is_err_and(|error| engine_busy(&error))
        );

        // A second click supersedes the pending write while another owner
        // changes other parts of the same saved documents.
        preferences.set_project_expanded("one", true);
        preferences.set_project_expanded("two", false);
        projects[0]["name"] = json!("Renamed");
        busy.store
            .save_document("projects.json", &projects)
            .unwrap();
        busy.store
            .save_document(
                "ui-state.json",
                &json!({
                    "collapsedSections":["future-section"], "future":{"keep":true}
                }),
            )
            .unwrap();
        drop(busy);
        first_attempt.save(&engine).unwrap();
        preferences.expansion.remove_saved(&first_attempt);
        let old_projects = engine.lock().unwrap().store.projects().unwrap();
        assert_eq!(old_projects[0]["isExpanded"], false);
        assert!(preferences.project_expanded(&old_projects[0]));
        let latest_attempt = preferences.expansion.clone();
        latest_attempt.save(&engine).unwrap();
        preferences.expansion.remove_saved(&latest_attempt);
        let owner = engine.lock().unwrap();
        let saved = owner.store.projects().unwrap();
        assert_eq!(saved[0]["name"], "Renamed");
        assert_eq!(saved[0]["isExpanded"], true);
        assert_eq!(saved[1]["isExpanded"], false);
        preferences.document = owner.store.document("ui-state.json").unwrap().unwrap();
        assert!(preferences.collapsed("chats"));
        assert!(preferences.collapsed("future-section"));
        assert_eq!(preferences.document["future"]["keep"], true);
        assert!(preferences.expansion.is_empty());
    }

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
