//! Script edits change only the `scripts` array of one reviewed project. Other
//! project fields, other scripts' unknown fields and conversations stay intact.
use super::*;
use crate::project_scripts::{self, MAX_SCRIPTS, ScriptDraft};

/// One change the toolbar's menu or the script editor makes.
#[derive(Clone, Debug)]
pub enum ScriptEdit {
    /// Replaces the listed script with this id, or adds one without an id.
    Save {
        id: Option<Uuid>,
        draft: ScriptDraft,
    },
    Delete(Uuid),
    /// Adds the project's `t3.json` scripts it lacks, read again now.
    ImportT3,
}

fn read_projects(db: &Connection) -> Result<Value> {
    let local: Option<String> = db
        .query_row(
            "SELECT document FROM documents WHERE name='projects.json'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let raw = if let Some(local) = local {
        local
    } else {
        let original: Option<Vec<u8>> = db
            .query_row(
                "SELECT data FROM original_files WHERE path='projects.json'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        String::from_utf8(original.context("Projects no longer exist")?)?
    };
    serde_json::from_str(&raw).context("Projects are malformed")
}

fn target_index(projects: &Value, id: &str) -> Result<usize> {
    let id = Uuid::parse_str(id).context("Project identity must be a UUID")?;
    ensure!(
        !id.is_nil() && Uuid::parse_str(crate::bot_runtime::BOTS_PROJECT_ID).ok() != Some(id),
        "Only saved projects have scripts"
    );
    let matches: Vec<_> = projects
        .as_array()
        .context("Projects must be an array")?
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
        project.is_object() && project["isBots"] != true,
        "Only saved projects have scripts"
    );
    Ok(index)
}

fn new_entry(draft: &ScriptDraft) -> Value {
    let mut entry = serde_json::Map::new();
    entry.insert(
        "id".into(),
        json!(Uuid::new_v4().hyphenated().to_string().to_uppercase()),
    );
    draft.write_into(&mut entry);
    Value::Object(entry)
}

/// `importable` is the `t3.json` read for an import, before the transaction.
fn apply(project: &mut Value, edit: &ScriptEdit, importable: Vec<ScriptDraft>) -> Result<()> {
    let fields = project.as_object_mut().context("Invalid project")?;
    let scripts = fields.entry("scripts").or_insert_with(|| json!([]));
    if scripts.is_null() {
        *scripts = json!([]);
    }
    let entries = scripts
        .as_array_mut()
        .context("Saved scripts have an unsupported shape")?;
    match edit {
        ScriptEdit::Save {
            id: Some(id),
            draft,
        } => {
            let draft = draft.normalized()?;
            let index = project_scripts::entry_index(entries, *id)
                .context("Script no longer exists; reopen the menu")?;
            let entry = entries[index]
                .as_object_mut()
                .context("Invalid saved script")?;
            draft.write_into(entry);
        }
        ScriptEdit::Save { id: None, draft } => {
            ensure!(
                entries.len() < MAX_SCRIPTS,
                "A project keeps at most 200 scripts"
            );
            entries.push(new_entry(&draft.normalized()?));
        }
        ScriptEdit::Delete(id) => {
            let index = project_scripts::entry_index(entries, *id)
                .context("Script no longer exists; reopen the menu")?;
            entries.remove(index);
        }
        ScriptEdit::ImportT3 => {
            ensure!(!importable.is_empty(), "t3.json has no scripts to import");
            ensure!(
                entries.len() + importable.len() <= MAX_SCRIPTS,
                "A project keeps at most 200 scripts"
            );
            entries.extend(importable.iter().map(new_entry));
        }
    }
    Ok(())
}

impl Store {
    pub(crate) fn project_scripts_target(&self, id: &str) -> Result<Value> {
        let projects = self.projects()?;
        Ok(projects[target_index(&projects, id)?].clone())
    }

    /// Applies `edit` when the project still equals the copy the menu showed.
    pub(crate) fn save_project_scripts_if_unchanged(
        &mut self,
        expected: &Value,
        edit: &ScriptEdit,
    ) -> Result<Value> {
        let id = expected["id"]
            .as_str()
            .context("Missing reviewed project identity")?;
        // The file is read outside the write transaction; the project it was
        // compared with is checked against the saved one inside it.
        let importable = if matches!(edit, ScriptEdit::ImportT3) {
            project_scripts::importable_t3_scripts(expected)
        } else {
            Vec::new()
        };
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut projects = read_projects(&tx)?;
        let index = target_index(&projects, id)?;
        ensure!(
            &projects[index] == expected,
            "Project changed; reopen its scripts before saving"
        );
        apply(&mut projects[index], edit, importable)?;
        let result = projects[index].clone();
        tx.execute("INSERT INTO documents(name,document) VALUES ('projects.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document", [projects.to_string()])?;
        tx.commit()?;
        Ok(result)
    }

    /// Swift UIState `lastScripts`, keyed and valued by upper-case UUIDs. Other
    /// window state is kept; an older key for the same project is replaced.
    pub(crate) fn remember_last_project_script(
        &mut self,
        project: Uuid,
        script: Uuid,
    ) -> Result<()> {
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let current = inspector_preferences::read_ui_state(&tx)?;
        let mut document = current.clone().unwrap_or_else(|| json!({}));
        let fields = document
            .as_object_mut()
            .context("Saved window state is not an object")?;
        let last = fields.entry("lastScripts").or_insert_with(|| json!({}));
        if !last.is_object() {
            *last = json!({});
        }
        let last = last.as_object_mut().context("Invalid last scripts")?;
        last.retain(|key, _| Uuid::parse_str(key).ok() != Some(project));
        ensure!(last.len() < 4096, "Saved last scripts exceed safe limit");
        last.insert(
            project.hyphenated().to_string().to_uppercase(),
            json!(script.hyphenated().to_string().to_uppercase()),
        );
        ensure!(
            serde_json::to_vec(&document)?.len() <= 2 * 1024 * 1024,
            "Saved window state exceeds safe metadata limits"
        );
        if current.as_ref() != Some(&document) {
            tx.execute("INSERT INTO documents(name,document) VALUES ('ui-state.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document", [document.to_string()])?;
        }
        tx.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project_scripts::{ScriptIcon, scripts};

    fn fixture() -> (tempfile::TempDir, Store, Value) {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let project = store
            .create_project(dir.path(), Some("Synthetic project"))
            .unwrap();
        (dir, store, project)
    }
    fn draft(name: &str, command: &str) -> ScriptDraft {
        ScriptDraft {
            name: name.into(),
            command: command.into(),
            ..Default::default()
        }
    }

    #[test]
    fn add_edit_and_delete_keep_unknown_fields_and_neighbors() {
        let (_dir, mut store, mut project) = fixture();
        project["future"] = json!({"keep":[1,2]});
        let kept = json!({"id":"0A5C0A5C-1111-4111-8111-000000000001","name":"Kept","command":"true","future":"script field"});
        project["scripts"] = json!([kept, {"name":"No id","command":"x"}]);
        let neighbor = json!({"id":Uuid::new_v4().to_string().to_uppercase(),"path":"synthetic-neighbor","scripts":[{"opaque":1}]});
        store
            .save_document("projects.json", &json!([project, neighbor]))
            .unwrap();
        let added = store
            .save_project_scripts_if_unchanged(
                &project,
                &ScriptEdit::Save {
                    id: None,
                    draft: ScriptDraft {
                        icon: ScriptIcon::Test,
                        run_on_worktree_create: true,
                        ..draft(" Tests ", " npm test ")
                    },
                },
            )
            .unwrap();
        let listed = scripts(&added);
        assert_eq!(listed.len(), 2);
        let new = &listed[1];
        assert_eq!(
            (new.name.as_str(), new.command.as_str(), new.icon),
            ("Tests", "npm test", ScriptIcon::Test)
        );
        assert!(new.run_on_worktree_create);
        assert_eq!(new.id, new.id.to_uppercase());
        assert_eq!(added["scripts"][1], json!({"name":"No id","command":"x"}));
        assert_eq!(added["future"], project["future"]);

        let edited = store
            .save_project_scripts_if_unchanged(
                &added,
                &ScriptEdit::Save {
                    id: Some(listed[0].uuid()),
                    draft: draft("Renamed", "make"),
                },
            )
            .unwrap();
        assert_eq!(edited["scripts"][0]["future"], "script field");
        assert_eq!(edited["scripts"][0]["name"], "Renamed");
        assert_eq!(edited["scripts"][0]["icon"], "play");

        let deleted = store
            .save_project_scripts_if_unchanged(&edited, &ScriptEdit::Delete(new.uuid()))
            .unwrap();
        assert_eq!(scripts(&deleted).len(), 1);
        assert_eq!(deleted["scripts"].as_array().unwrap().len(), 2);
        let saved = store.projects().unwrap();
        assert_eq!(saved[0], deleted);
        assert_eq!(saved[1], neighbor);
    }

    #[test]
    fn stale_review_invalid_drafts_and_missing_scripts_change_nothing() {
        let (dir, mut store, project) = fixture();
        let mut other = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let mut changed = other.projects().unwrap();
        changed[0]["name"] = json!("Renamed elsewhere");
        other.save_document("projects.json", &changed).unwrap();
        let add = ScriptEdit::Save {
            id: None,
            draft: draft("Dev", "npm run dev"),
        };
        assert!(
            store
                .save_project_scripts_if_unchanged(&project, &add)
                .is_err()
        );
        assert_eq!(store.projects().unwrap(), changed);
        let current = changed[0].clone();
        for edit in [
            ScriptEdit::Save {
                id: None,
                draft: draft("", "npm run dev"),
            },
            ScriptEdit::Save {
                id: Some(Uuid::new_v4()),
                draft: draft("Dev", "npm run dev"),
            },
            ScriptEdit::Delete(Uuid::new_v4()),
            ScriptEdit::ImportT3,
        ] {
            assert!(
                store
                    .save_project_scripts_if_unchanged(&current, &edit)
                    .is_err()
            );
            assert_eq!(store.projects().unwrap(), changed);
        }
        let mut malformed = current.clone();
        malformed["scripts"] = json!({"not":"an array"});
        store
            .save_document("projects.json", &json!([malformed]))
            .unwrap();
        assert!(
            store
                .save_project_scripts_if_unchanged(&malformed, &add)
                .is_err()
        );
        let bots = json!({"id":crate::bot_runtime::BOTS_PROJECT_ID});
        assert!(
            store
                .project_scripts_target(crate::bot_runtime::BOTS_PROJECT_ID)
                .is_err()
        );
        assert!(
            store
                .save_project_scripts_if_unchanged(&bots, &add)
                .is_err()
        );
    }

    #[test]
    fn import_reads_t3_file_again_and_adds_only_missing_names() {
        let (dir, mut store, project) = fixture();
        std::fs::write(
            dir.path().join("t3.json"),
            r#"{"scripts":[{"name":"Dev","command":"bun dev","icon":"build"},{"name":"Lint","command":"bun lint","runOnWorktreeCreate":true}]}"#,
        )
        .unwrap();
        let first = store
            .save_project_scripts_if_unchanged(
                &project,
                &ScriptEdit::Save {
                    id: None,
                    draft: draft("Dev", "npm run dev"),
                },
            )
            .unwrap();
        let imported = store
            .save_project_scripts_if_unchanged(&first, &ScriptEdit::ImportT3)
            .unwrap();
        let listed = scripts(&imported);
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].command, "npm run dev");
        assert_eq!(listed[1].name, "Lint");
        assert!(listed[1].run_on_worktree_create);
        assert!(
            store
                .save_project_scripts_if_unchanged(&imported, &ScriptEdit::ImportT3)
                .is_err()
        );
    }

    #[test]
    fn last_script_replaces_same_project_key_and_keeps_window_state() {
        let (_dir, mut store, _project) = fixture();
        let project = Uuid::new_v4();
        let other = Uuid::new_v4();
        let script = Uuid::new_v4();
        store
            .save_document(
                "ui-state.json",
                &json!({"windowFrame":"frame","lastScripts":{
                    project.to_string(): "0A5C0A5C-1111-4111-8111-000000000001",
                    other.to_string().to_uppercase(): "kept"
                }}),
            )
            .unwrap();
        store.remember_last_project_script(project, script).unwrap();
        let document = store.document("ui-state.json").unwrap().unwrap();
        assert_eq!(document["windowFrame"], "frame");
        let last = document["lastScripts"].as_object().unwrap();
        assert_eq!(last.len(), 2);
        assert_eq!(
            last[&project.to_string().to_uppercase()],
            script.to_string().to_uppercase()
        );
        assert_eq!(last[&other.to_string().to_uppercase()], "kept");
        store
            .save_document("ui-state.json", &json!({"lastScripts":[1]}))
            .unwrap();
        store.remember_last_project_script(project, script).unwrap();
        assert_eq!(
            crate::project_scripts::last_scripts(
                &store.document("ui-state.json").unwrap().unwrap()
            )[&project],
            script
        );
        store.save_document("ui-state.json", &json!([])).unwrap();
        assert!(store.remember_last_project_script(project, script).is_err());
    }
}
