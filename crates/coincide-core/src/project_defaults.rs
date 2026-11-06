//! Trusted native Project Defaults review. This carries display metadata only;
//! it never grants a provider process, account, catalog, or session authority.
use crate::{api::Engine, store::text};
use anyhow::{Result, ensure};
use serde_json::{Value, json};

#[derive(Clone)]
pub struct ProjectDefaultsReview {
    project: Value,
    global: Value,
}
impl ProjectDefaultsReview {
    pub fn project(&self) -> &Value {
        &self.project
    }
    pub fn global(&self) -> &Value {
        &self.global
    }
    pub fn effective(&self) -> &Value {
        if self.project["threadDefaults"].is_null() {
            &self.global
        } else {
            &self.project["threadDefaults"]
        }
    }
    pub fn inherits_global(&self) -> bool {
        self.project["threadDefaults"].is_null()
    }
}

impl Engine {
    pub fn native_project_defaults(&self, id: &str) -> Result<ProjectDefaultsReview> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let project = self.store.project_defaults_target(id)?;
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        ensure!(settings.is_object(), "Saved settings are malformed");
        let selection = settings
            .get("defaultSelection")
            .filter(|value| !value.is_null())
            .cloned()
            .unwrap_or_else(|| json!({"provider":"codex","modelID":"default"}));
        let access = settings
            .get("defaultAccessMode")
            .filter(|value| !value.is_null())
            .cloned()
            .unwrap_or_else(|| json!("approval"));
        Ok(ProjectDefaultsReview {
            project,
            global: json!({"selection":selection,"accessMode":access,"interactionMode":"build"}),
        })
    }

    pub fn native_save_project_defaults(
        &mut self,
        review: &ProjectDefaultsReview,
        defaults: Option<&Value>,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let defaults = defaults
            .map(|defaults| self.validate_composer_defaults(defaults))
            .transpose()?;
        if let Some(defaults) = &defaults {
            let provider = text(&defaults["selection"], "provider");
            self.require_provider_enabled(&provider)?;
            if provider == "antigravity" {
                self.antigravity_selection(&crate::composer_selection::launch_selection(
                    &defaults["selection"],
                )?)?;
            }
        }
        let project = self
            .store
            .save_project_defaults_if_unchanged(&review.project, defaults.as_ref())?;
        self.revision += 1;
        Ok(project)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Store;
    use uuid::Uuid;

    fn fixture() -> (tempfile::TempDir, Engine, String) {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        let project = engine
            .store
            .create_project(root.path(), Some("Synthetic project"))
            .unwrap();
        (root, engine, text(&project, "id"))
    }
    fn defaults() -> Value {
        json!({"selection":{"provider":"claude","modelID":"synthetic-model"},"accessMode":"approval","interactionMode":"build"})
    }

    #[test]
    fn saved_defaults_affect_only_future_threads_and_reset_restores_global_inheritance() {
        let (_root, mut engine, id) = fixture();
        let original = engine.dispatch(
            json!({"method":"threads.create","params":{"projectId":id,"draft":"Keep draft"}}),
        )["result"]
            .clone();
        let original_id = text(&original, "id");
        let review = engine.native_project_defaults(&id).unwrap();
        assert!(review.inherits_global());
        engine
            .native_save_project_defaults(&review, Some(&defaults()))
            .unwrap();
        assert_eq!(engine.store.thread(&original_id).unwrap(), original);
        let next = engine.dispatch(json!({"method":"threads.create","params":{"projectId":id}}));
        assert_eq!(next["result"]["selection"], defaults()["selection"]);
        let review = engine.native_project_defaults(&id).unwrap();
        assert!(!review.inherits_global());
        engine.native_save_project_defaults(&review, None).unwrap();
        let next = engine.dispatch(json!({"method":"threads.create","params":{"projectId":id}}));
        assert_eq!(next["result"]["selection"]["provider"], "codex");
        assert_eq!(engine.store.thread(&original_id).unwrap(), original);
    }

    #[test]
    fn independent_connection_cannot_overwrite_reviewed_project_but_other_projects_survive() {
        let (root, mut engine, id) = fixture();
        let mut other = Store::open(&root.path().join("state.sqlite")).unwrap();
        let review = engine.native_project_defaults(&id).unwrap();
        let mut projects = other.projects().unwrap();
        projects[0]["future"] = json!({"keep":[1,2,3]});
        other.save_document("projects.json", &projects).unwrap();
        assert!(
            engine
                .native_save_project_defaults(&review, Some(&defaults()))
                .is_err()
        );
        assert_eq!(engine.store.projects().unwrap(), projects);
        let review = engine.native_project_defaults(&id).unwrap();
        let neighbor = json!({"id":Uuid::new_v4(),"path":"synthetic-neighbor","future":{"keep":9}});
        projects.as_array_mut().unwrap().push(neighbor.clone());
        other.save_document("projects.json", &projects).unwrap();
        engine
            .native_save_project_defaults(&review, Some(&defaults()))
            .unwrap();
        let after = engine.store.projects().unwrap();
        assert_eq!(after[0]["future"], projects[0]["future"]);
        assert_eq!(after[1], neighbor);
    }

    #[test]
    fn invalid_or_disabled_choices_and_system_projects_leave_everything_unchanged() {
        let (_root, mut engine, id) = fixture();
        let review = engine.native_project_defaults(&id).unwrap();
        let before = engine.store.projects().unwrap();
        let mut invalid = defaults();
        invalid["selection"]["modelID"] = json!("--untrusted-flag");
        assert!(
            engine
                .native_save_project_defaults(&review, Some(&invalid))
                .is_err()
        );
        engine
            .store
            .save_document(
                "settings.json",
                &json!({"providers":{"claude":{"isEnabled":false}}}),
            )
            .unwrap();
        assert!(
            engine
                .native_save_project_defaults(&review, Some(&defaults()))
                .is_err()
        );
        assert_eq!(engine.store.projects().unwrap(), before);
        assert!(
            engine
                .native_project_defaults("00000000-0000-0000-0000-000000000000")
                .is_err()
        );
        assert!(
            engine
                .native_project_defaults(crate::bot_runtime::BOTS_PROJECT_ID)
                .is_err()
        );
        assert!(
            engine
                .native_project_defaults(&Uuid::new_v4().to_string())
                .is_err()
        );
    }
}
