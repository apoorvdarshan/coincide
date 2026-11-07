//! Swift ProjectScript/ProjectScripts (T3 Code's project scripts): commands a
//! project runs often, kept in the project's `scripts` array and run in a
//! terminal of a thread. Reading is lenient like Swift's decoder; an entry
//! without a UUID cannot be addressed, so it is listed nowhere and never
//! rewritten.
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{collections::HashMap, io::Read, path::Path};
use uuid::Uuid;

/// Longest name and command a script keeps. A command is typed into a
/// terminal whose single write accepts 32 KiB.
pub const MAX_NAME_BYTES: usize = 1024;
pub const MAX_COMMAND_BYTES: usize = 16 * 1024;
pub const MAX_SCRIPTS: usize = 200;
const MAX_T3_FILE_BYTES: u64 = 1024 * 1024;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum ScriptIcon {
    #[default]
    Play,
    Test,
    Lint,
    Configure,
    Build,
    Debug,
}
impl ScriptIcon {
    /// The editor's order (Swift `ProjectScript.Icon.allCases`).
    pub const ALL: [Self; 6] = [
        Self::Play,
        Self::Test,
        Self::Lint,
        Self::Configure,
        Self::Build,
        Self::Debug,
    ];
    pub fn parse(value: &Value) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|icon| value.as_str() == Some(icon.raw()))
    }
    pub fn raw(self) -> &'static str {
        match self {
            Self::Play => "play",
            Self::Test => "test",
            Self::Lint => "lint",
            Self::Configure => "configure",
            Self::Build => "build",
            Self::Debug => "debug",
        }
    }
    /// What the editor's icon buttons are called.
    pub fn title(self) -> &'static str {
        match self {
            Self::Play => "Run",
            Self::Test => "Test",
            Self::Lint => "Lint",
            Self::Configure => "Configure",
            Self::Build => "Build",
            Self::Debug => "Debug",
        }
    }
}

/// The fields the editor and a `t3.json` file supply.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScriptDraft {
    pub name: String,
    pub command: String,
    pub icon: ScriptIcon,
    pub run_on_worktree_create: bool,
}
impl ScriptDraft {
    /// Trims like Swift's editor and rejects what the toolbar and terminal
    /// cannot carry: an empty field, control characters in the name, and
    /// terminal framing other than tabs and line breaks in the command.
    pub fn normalized(&self) -> Result<Self> {
        let name = self.name.trim();
        let command = self.command.trim();
        ensure!(
            !name.is_empty() && !command.is_empty(),
            "A script needs a name and a command"
        );
        ensure!(
            name.len() <= MAX_NAME_BYTES && command.len() <= MAX_COMMAND_BYTES,
            "Script name or command is too long"
        );
        ensure!(
            !name.chars().any(char::is_control),
            "Script name contains control characters"
        );
        ensure!(
            !command
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\t' | '\n' | '\r')),
            "Script command contains terminal control characters"
        );
        Ok(Self {
            name: name.to_owned(),
            command: command.to_owned(),
            ..self.clone()
        })
    }
    pub(crate) fn write_into(&self, entry: &mut serde_json::Map<String, Value>) {
        entry.insert("name".into(), json!(self.name));
        entry.insert("command".into(), json!(self.command));
        entry.insert("icon".into(), json!(self.icon.raw()));
        entry.insert(
            "runOnWorktreeCreate".into(),
            json!(self.run_on_worktree_create),
        );
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectScript {
    /// The id exactly as saved (Swift writes upper-case UUIDs).
    pub id: String,
    pub name: String,
    pub command: String,
    pub icon: ScriptIcon,
    pub run_on_worktree_create: bool,
}
impl ProjectScript {
    pub fn uuid(&self) -> Uuid {
        Uuid::parse_str(&self.id).unwrap_or_default()
    }
    pub fn draft(&self) -> ScriptDraft {
        ScriptDraft {
            name: self.name.clone(),
            command: self.command.clone(),
            icon: self.icon,
            run_on_worktree_create: self.run_on_worktree_create,
        }
    }
}

fn decode(entry: &Value) -> Option<ProjectScript> {
    let id = entry["id"].as_str()?;
    Uuid::parse_str(id).ok().filter(|id| !id.is_nil())?;
    Some(ProjectScript {
        id: id.to_owned(),
        name: entry["name"].as_str()?.to_owned(),
        command: entry["command"].as_str()?.to_owned(),
        icon: ScriptIcon::parse(&entry["icon"]).unwrap_or_default(),
        run_on_worktree_create: entry["runOnWorktreeCreate"].as_bool().unwrap_or(false),
    })
}

/// A project's scripts in the order the menu lists them. A second entry with
/// an id already listed is ignored, so every listed id is unambiguous.
pub fn scripts(project: &Value) -> Vec<ProjectScript> {
    let mut seen = std::collections::HashSet::new();
    project["scripts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(decode)
        .filter(|script| seen.insert(script.uuid()))
        .take(MAX_SCRIPTS)
        .collect()
}

/// Index of the saved entry a listed script came from.
pub(crate) fn entry_index(entries: &[Value], id: Uuid) -> Option<usize> {
    entries
        .iter()
        .position(|entry| decode(entry).is_some_and(|script| script.uuid() == id))
}

/// Swift UIState `lastScripts`: the script each project ran last, by id.
pub fn last_scripts(ui_state: &Value) -> HashMap<Uuid, Uuid> {
    ui_state["lastScripts"]
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(project, script)| {
            Some((
                Uuid::parse_str(project).ok()?,
                Uuid::parse_str(script.as_str()?).ok()?,
            ))
        })
        .collect()
}

/// The script one click runs: the one run last in the project, else its first.
pub fn primary(scripts: &[ProjectScript], last: Option<Uuid>) -> Option<&ProjectScript> {
    last.and_then(|last| scripts.iter().find(|script| script.uuid() == last))
        .or_else(|| scripts.first())
}

/// The scripts of a T3 Code `t3.json` file, so a project set up for T3 Code
/// brings its scripts along. Entries a script could not hold are skipped.
pub fn scripts_from_t3(data: &[u8]) -> Vec<ScriptDraft> {
    let Ok(json) = serde_json::from_slice::<Value>(data) else {
        return Vec::new();
    };
    json["scripts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            ScriptDraft {
                name: entry["name"].as_str()?.to_owned(),
                command: entry["command"].as_str()?.to_owned(),
                icon: ScriptIcon::parse(&entry["icon"]).unwrap_or_default(),
                run_on_worktree_create: entry["runOnWorktreeCreate"].as_bool().unwrap_or(false),
            }
            .normalized()
            .ok()
        })
        .collect()
}

/// The project's `t3.json` scripts whose names it lacks, in file order. A
/// missing, oversized or unreadable file offers nothing to import.
pub fn importable_t3_scripts(project: &Value) -> Vec<ScriptDraft> {
    let Some(folder) = project["path"].as_str().filter(|path| !path.is_empty()) else {
        return Vec::new();
    };
    let Some(data) = read_bounded(&Path::new(folder).join("t3.json")) else {
        return Vec::new();
    };
    let names: std::collections::HashSet<String> = scripts(project)
        .into_iter()
        .map(|script| script.name)
        .collect();
    scripts_from_t3(&data)
        .into_iter()
        .filter(|draft| !names.contains(&draft.name))
        .collect()
}

fn read_bounded(path: &Path) -> Option<Vec<u8>> {
    let file = std::fs::File::open(path).ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    let mut data = Vec::new();
    file.take(MAX_T3_FILE_BYTES + 1)
        .read_to_end(&mut data)
        .ok()?;
    (data.len() as u64 <= MAX_T3_FILE_BYTES).then_some(data)
}

/// Where the script runs, for commands such as copying `.env` from the main
/// checkout into a worktree. T3 Code's names are set too, so scripts
/// imported from `t3.json` work unchanged.
pub fn environment(project_path: &str, worktree: Option<&str>) -> Vec<(String, String)> {
    let mut environment = vec![
        ("COINCIDE_PROJECT_ROOT".to_owned(), project_path.to_owned()),
        ("T3CODE_PROJECT_ROOT".to_owned(), project_path.to_owned()),
    ];
    if let Some(worktree) = worktree {
        environment.push(("COINCIDE_WORKTREE_PATH".to_owned(), worktree.to_owned()));
        environment.push(("T3CODE_WORKTREE_PATH".to_owned(), worktree.to_owned()));
    }
    environment
}

#[cfg(test)]
mod tests {
    use super::*;
    const A: &str = "0A5C0A5C-1111-4111-8111-000000000001";
    const B: &str = "0A5C0A5C-2222-4222-8222-000000000002";

    #[test]
    fn saved_scripts_decode_leniently_like_swift_and_skip_unaddressable_entries() {
        let project = json!({"scripts":[
            {"id":A,"name":"Dev","command":"npm run dev","icon":"build","runOnWorktreeCreate":true,"future":1},
            {"id":B,"name":"Test","command":"npm test","icon":"unknown"},
            {"name":"No id","command":"true"},
            {"id":"not a uuid","name":"Bad","command":"true"},
            {"id":B.to_lowercase(),"name":"Duplicate","command":"true"},
            {"id":"0A5C0A5C-3333-4333-8333-000000000003","name":1,"command":"true"},
            "garbage"
        ]});
        let scripts = scripts(&project);
        assert_eq!(scripts.len(), 2);
        assert_eq!(scripts[0].icon, ScriptIcon::Build);
        assert!(scripts[0].run_on_worktree_create);
        assert_eq!(scripts[1].icon, ScriptIcon::Play);
        assert!(!scripts[1].run_on_worktree_create);
        assert!(super::scripts(&json!({"scripts":{"id":A}})).is_empty());
        assert!(super::scripts(&json!({})).is_empty());
    }

    #[test]
    fn primary_is_last_run_script_else_first_and_ignores_other_projects() {
        let project = json!({"scripts":[
            {"id":A,"name":"Dev","command":"npm run dev"},
            {"id":B,"name":"Test","command":"npm test"}
        ]});
        let scripts = scripts(&project);
        let project_id = Uuid::new_v4();
        let ui = json!({"lastScripts":{
            project_id.to_string().to_uppercase(): B.to_lowercase(),
            "not a uuid": A,
            Uuid::new_v4().to_string(): 5
        },"future":true});
        let last = last_scripts(&ui);
        assert_eq!(last.len(), 1);
        assert_eq!(
            primary(&scripts, last.get(&project_id).copied())
                .unwrap()
                .id,
            B
        );
        assert_eq!(primary(&scripts, None).unwrap().id, A);
        assert_eq!(primary(&scripts, Some(Uuid::new_v4())).unwrap().id, A);
        assert!(primary(&[], last.get(&project_id).copied()).is_none());
    }

    #[test]
    fn drafts_trim_and_reject_what_the_terminal_cannot_carry() {
        let draft = ScriptDraft {
            name: "  Dev server ".into(),
            command: "\tnpm run dev\n".into(),
            ..Default::default()
        };
        let normalized = draft.normalized().unwrap();
        assert_eq!(normalized.name, "Dev server");
        assert_eq!(normalized.command, "npm run dev");
        for (name, command) in [
            ("", "true"),
            ("Name", "   "),
            ("Line\nbreak", "true"),
            ("Escape", "printf \u{1b}[2J"),
        ] {
            let draft = ScriptDraft {
                name: name.into(),
                command: command.into(),
                ..Default::default()
            };
            assert!(draft.normalized().is_err(), "{name:?} {command:?}");
        }
        let multi = ScriptDraft {
            name: "Setup".into(),
            command: "npm ci\r\nnpm run build".into(),
            ..Default::default()
        };
        assert!(multi.normalized().is_ok());
        let long = ScriptDraft {
            name: "Long".into(),
            command: "x".repeat(MAX_COMMAND_BYTES + 1),
            ..Default::default()
        };
        assert!(long.normalized().is_err());
    }

    #[test]
    fn t3_file_scripts_skip_invalid_entries_and_names_the_project_has() {
        let data = br#"{"scripts":[
            {"name":" Dev ","command":" bun dev ","icon":"debug","runOnWorktreeCreate":true},
            {"name":"","command":"true"},
            {"name":"No command"},
            {"name":"Lint","command":"bun lint","icon":"sparkles"},
            {"name":"Existing","command":"true"}
        ]}"#;
        let drafts = scripts_from_t3(data);
        assert_eq!(drafts.len(), 3);
        assert_eq!(
            drafts[0],
            ScriptDraft {
                name: "Dev".into(),
                command: "bun dev".into(),
                icon: ScriptIcon::Debug,
                run_on_worktree_create: true,
            }
        );
        assert_eq!(drafts[1].icon, ScriptIcon::Play);
        assert!(scripts_from_t3(b"not json").is_empty());
        assert!(scripts_from_t3(br#"{"scripts":{}}"#).is_empty());

        let folder = tempfile::tempdir().unwrap();
        let project =
            json!({"path":folder.path(),"scripts":[{"id":A,"name":"Existing","command":"x"}]});
        assert!(importable_t3_scripts(&project).is_empty());
        std::fs::write(folder.path().join("t3.json"), data).unwrap();
        let names: Vec<_> = importable_t3_scripts(&project)
            .into_iter()
            .map(|draft| draft.name)
            .collect();
        assert_eq!(names, ["Dev", "Lint"]);
        std::fs::write(
            folder.path().join("t3.json"),
            vec![b' '; MAX_T3_FILE_BYTES as usize + 1],
        )
        .unwrap();
        assert!(importable_t3_scripts(&project).is_empty());
        assert!(importable_t3_scripts(&json!({"path":""})).is_empty());
    }

    #[test]
    fn environment_names_project_root_and_only_a_real_worktree() {
        assert_eq!(
            environment("/project", None),
            [
                ("COINCIDE_PROJECT_ROOT".into(), "/project".into()),
                ("T3CODE_PROJECT_ROOT".into(), "/project".into()),
            ]
        );
        let with = environment("/project", Some("/worktree"));
        assert_eq!(with.len(), 4);
        assert!(with.contains(&("COINCIDE_WORKTREE_PATH".into(), "/worktree".into())));
        assert!(with.contains(&("T3CODE_WORKTREE_PATH".into(), "/worktree".into())));
    }
}
