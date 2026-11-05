//! Ordinary new-thread defaults. Project/global documents are read only;
//! bot creation, import/history and existing conversation snapshots are separate.
use super::*;

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
        let cwd = params["cwd"].as_str();
        if let Some(cwd) = cwd {
            ensure!(
                PathBuf::from(cwd).is_dir(),
                "Working directory does not exist"
            );
        }
        let project = params["projectId"]
            .as_str()
            .unwrap_or("00000000-0000-0000-0000-000000000000");
        let mut thread = self.store.prepare_new_thread(project)?;
        // Preserve the ordinary API's historical fallback when no defaults are
        // configured; Store::new_thread retains its separate existing contract.
        thread["selection"] = json!({"provider":"codex","modelID":"default"});
        let projects = self.store.projects()?;
        let defaults = if let Some(defaults) = project_defaults(&projects, project)? {
            Some(
                crate::composer_selection::validate_defaults(defaults)
                    .context("Project composer defaults are unsupported")?,
            )
        } else {
            // Deliberately lazy: a valid project override must not read/validate
            // unrelated global defaults, including a bad captured settings file.
            let settings = self.store.document("settings.json")?;
            global_defaults(settings.as_ref(), &thread)?
                .map(|defaults| {
                    crate::composer_selection::validate_defaults(&defaults)
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
        if let Some(cwd) = cwd {
            thread["worktreePath"] = json!(cwd);
        }
        // All validation, account policy and cwd checks precede the first write.
        self.store.save(&thread)?;
        self.revision += 1;
        Ok(thread)
    }
}
