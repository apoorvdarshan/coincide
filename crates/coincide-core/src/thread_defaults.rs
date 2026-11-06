//! Ordinary new-thread defaults. Project/global documents are read only;
//! bot creation, import/history and existing conversation snapshots are separate.
use super::*;

#[cfg(test)]
#[path = "thread_create_options_tests.rs"]
mod creation_tests;
#[cfg(test)]
#[path = "thread_defaults_tests.rs"]
mod tests;

fn same_id(left: &str, right: &str) -> bool {
    match (Uuid::parse_str(left), Uuid::parse_str(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}
fn project_defaults<'a>(projects: &'a Value, project_id: &str) -> Result<Option<&'a Value>> {
    let projects = projects
        .as_array()
        .context("Stored projects document is not an array")?;
    // The Rust projectless sentinel never acquires project-local defaults.
    if project_id.is_empty() || Uuid::parse_str(project_id).is_ok_and(|id| id.is_nil()) {
        return Ok(None);
    }
    let matches = projects
        .iter()
        .filter(|project| {
            project["id"]
                .as_str()
                .is_some_and(|id| same_id(id, project_id))
        })
        .collect::<Vec<_>>();
    ensure!(
        matches.len() <= 1,
        "Ambiguous project defaults: duplicate project identity"
    );
    let Some(project) = matches.first() else {
        return Ok(None);
    };
    if project["isChats"] == true {
        return Ok(None);
    }
    Ok(project
        .get("threadDefaults")
        .filter(|value| !value.is_null()))
}
fn global_defaults(settings: Option<&Value>, fallback: &Value) -> Result<Option<Value>> {
    let Some(settings) = settings.filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    let fields = settings
        .as_object()
        .context("Stored settings document is not an object")?;
    let selection = fields
        .get("defaultSelection")
        .filter(|value| !value.is_null());
    let access = fields
        .get("defaultAccessMode")
        .filter(|value| !value.is_null());
    if selection.is_none() && access.is_none() {
        return Ok(None);
    }
    // Swift's global ProjectThreadDefaults constructor uses build; there is no
    // persisted global interaction-mode key in AppSettings.
    Ok(Some(
        json!({"selection":selection.unwrap_or(&fallback["selection"]),
        "accessMode":access.unwrap_or(&fallback["accessMode"]),"interactionMode":"build"}),
    ))
}
impl Engine {
    pub(super) fn create_ordinary_thread(&mut self, params: &Value) -> Result<Value> {
        self.require_admissions()?;
        let fields = params
            .as_object()
            .context("New-thread request must be an object")?;
        ensure!(
            fields.keys().all(|key| matches!(
                key.as_str(),
                "cwd"
                    | "projectId"
                    | "title"
                    | "draft"
                    | "selection"
                    | "accessMode"
                    | "interactionMode"
            )),
            "New-thread request contains unsupported options"
        );
        let cwd = fields
            .get("cwd")
            .filter(|value| !value.is_null())
            .map(|value| {
                value
                    .as_str()
                    .context("Working directory must be text or null")
            })
            .transpose()?;
        if let Some(cwd) = cwd {
            ensure!(
                PathBuf::from(cwd).is_dir(),
                "Working directory does not exist"
            );
        }
        let project = fields
            .get("projectId")
            .filter(|value| !value.is_null())
            .map(|value| value.as_str().context("Project ID must be text or null"))
            .transpose()?
            .unwrap_or("00000000-0000-0000-0000-000000000000");
        if let Some(title) = fields.get("title") {
            let title = title.as_str().context("Title must be text")?;
            ensure!(
                !title.trim().is_empty()
                    && title.len() <= 512
                    && !title.chars().any(char::is_control),
                "Title must be nonblank, at most 512 UTF-8 bytes and contain no control characters"
            );
        }
        if let Some(draft) = fields.get("draft") {
            ensure!(
                draft.as_str().is_some_and(|text| text.len() <= 1024 * 1024),
                "Draft must be text of at most 1 MiB"
            );
        }
        let mut thread = self.store.prepare_new_thread(project)?;
        // Preserve the ordinary API's historical fallback when no defaults are
        // configured; Store::new_thread retains its separate existing contract.
        thread["selection"] = json!({"provider":"codex","modelID":"default"});
        let projects = self.store.projects()?;
        let defaults = if let Some(defaults) = project_defaults(&projects, project)? {
            Some(
                self.validate_composer_defaults(defaults)
                    .context("Project composer defaults are unsupported")?,
            )
        } else {
            // Deliberately lazy: a valid project override must not read/validate
            // unrelated global defaults, including a bad captured settings file.
            let settings = self.store.document("settings.json")?;
            global_defaults(settings.as_ref(), &thread)?
                .map(|defaults| {
                    self.validate_composer_defaults(&defaults)
                        .context("Global composer defaults are unsupported")
                })
                .transpose()?
        };
        if let Some(defaults) = defaults {
            for key in ["selection", "accessMode", "interactionMode"] {
                thread[key] = defaults[key].clone();
            }
            if thread["selection"]["provider"] == "antigravity" {
                let runtime = crate::composer_selection::launch_selection(&thread["selection"])?;
                self.antigravity_selection(&runtime)?;
            }
        }
        if fields
            .keys()
            .any(|key| matches!(key.as_str(), "selection" | "accessMode" | "interactionMode"))
        {
            let mut target = json!({"selection":thread["selection"],"accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"]});
            if let Some(selection) = fields.get("selection") {
                let overrides = selection
                    .as_object()
                    .context("Selection overrides must be an object")?;
                ensure!(
                    overrides.keys().all(|key| matches!(
                        key.as_str(),
                        "provider" | "modelID" | "accountID" | "effort" | "speed"
                    )),
                    "Selection overrides contain unsupported options"
                );
                if let Some(provider) = overrides.get("provider") {
                    let provider = provider.as_str().context("Provider must be text")?;
                    ensure!(
                        target["selection"]["provider"] == provider
                            || overrides.contains_key("modelID"),
                        "Changing provider requires an explicit modelID; no model was guessed"
                    );
                }
                for (key, value) in overrides {
                    target["selection"][key] = value.clone();
                }
            }
            for key in ["accessMode", "interactionMode"] {
                if let Some(value) = fields.get(key) {
                    ensure!(value.is_string(), "{key} must be text");
                    target[key] = value.clone();
                }
            }
            let target = self
                .validate_composer_defaults(&target)
                .context("New-thread composer options are unsupported")?;
            if target["selection"]["provider"] == "antigravity" {
                self.antigravity_selection(&crate::composer_selection::launch_selection(
                    &target["selection"],
                )?)?;
            }
            for key in ["selection", "accessMode", "interactionMode"] {
                thread[key] = target[key].clone();
            }
        }
        for key in ["title", "draft"] {
            if let Some(value) = fields.get(key) {
                thread[key] = value.clone();
            }
        }
        if let Some(cwd) = cwd {
            thread["worktreePath"] = json!(cwd);
        }
        // All validation, account policy and cwd checks precede the first write.
        self.store.save(&thread)?;
        self.revision += 1;
        Ok(thread)
    }
}
