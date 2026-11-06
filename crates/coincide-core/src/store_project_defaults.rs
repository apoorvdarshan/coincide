//! A native Defaults form edits one reviewed project, never its conversations.
use super::*;

fn target_index(projects: &Value, id: &str) -> Result<usize> {
    let id = Uuid::parse_str(id).context("Project identity must be a UUID")?;
    ensure!(
        !id.is_nil() && id.to_string() != crate::bot_runtime::BOTS_PROJECT_ID.to_lowercase(),
        "Only folder projects have local defaults"
    );
    let projects = projects.as_array().context("Projects must be an array")?;
    let matches: Vec<_> = projects
        .iter()
        .enumerate()
        .filter(|(_, project)| {
            project["id"]
                .as_str()
                .and_then(|id| Uuid::parse_str(id).ok())
                == Some(id)
        })
        .collect();
    ensure!(
        matches.len() == 1,
        "Project is missing or has a duplicate identity"
    );
    let (index, project) = matches[0];
    ensure!(
        project.is_object()
            && project["isChats"] != true
            && project["isBots"] != true
            && project["path"]
                .as_str()
                .is_some_and(|path| !path.is_empty()),
        "Only folder projects have local defaults"
    );
    Ok(index)
}

impl Store {
    pub(crate) fn project_defaults_target(&self, id: &str) -> Result<Value> {
        let projects = self.projects()?;
        Ok(projects[target_index(&projects, id)?].clone())
    }

    pub(crate) fn save_project_defaults_if_unchanged(
        &mut self,
        expected: &Value,
        defaults: Option<&Value>,
    ) -> Result<Value> {
        let id = expected["id"]
            .as_str()
            .context("Missing reviewed project identity")?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let local: Option<String> = tx
            .query_row(
                "SELECT document FROM documents WHERE name='projects.json'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        let raw = if let Some(local) = local {
            local
        } else {
            let original: Option<Vec<u8>> = tx
                .query_row(
                    "SELECT data FROM original_files WHERE path='projects.json'",
                    [],
                    |row| row.get(0),
                )
                .optional()?;
            String::from_utf8(original.context("Projects no longer exist")?)?
        };
        let mut projects: Value = serde_json::from_str(&raw).context("Projects are malformed")?;
        let index = target_index(&projects, id)?;
        ensure!(
            &projects[index] == expected,
            "Project changed; reload its defaults before saving"
        );
        let project = projects[index].as_object_mut().context("Invalid project")?;
        if let Some(defaults) = defaults {
            project.insert("threadDefaults".into(), defaults.clone());
        } else {
            project.remove("threadDefaults");
        }
        let result = projects[index].clone();
        tx.execute("INSERT INTO documents(name,document) VALUES ('projects.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document", [projects.to_string()])?;
        tx.commit()?;
        Ok(result)
    }
}
