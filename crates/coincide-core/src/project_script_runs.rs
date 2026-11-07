//! Swift's ProjectScripts run semantics, apart from the scripts toolbar and
//! editor: which script one click runs, the environment a script gets, the
//! scripts a new worktree runs, which terminal a run reuses, and the scripts
//! a project's T3 Code `t3.json` brings along. Scripts are the stored
//! project's `scripts`, in the shape Swift's ProjectScript encodes.
use serde_json::{Value, json};
use std::collections::BTreeMap;

const ICONS: &[&str] = &["play", "test", "lint", "configure", "build", "debug"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectScript {
    pub id: String,
    pub name: String,
    pub command: String,
    pub icon: String,
    /// Runs on its own in a new worktree as soon as a thread gets one.
    pub run_on_worktree_create: bool,
}
impl ProjectScript {
    /// Swift's lenient decoder: a name and command are required; an unknown
    /// icon reads as play and a missing flag as false.
    pub fn from_stored(value: &Value) -> Option<Self> {
        Some(Self {
            id: value["id"]
                .as_str()
                .filter(|id| uuid::Uuid::parse_str(id).is_ok())
                .map_or_else(
                    || uuid::Uuid::new_v4().to_string().to_uppercase(),
                    str::to_owned,
                ),
            name: value["name"].as_str()?.to_owned(),
            command: value["command"].as_str()?.to_owned(),
            icon: icon(&value["icon"]),
            run_on_worktree_create: value["runOnWorktreeCreate"].as_bool().unwrap_or(false),
        })
    }
    pub fn to_stored(&self) -> Value {
        json!({"id":self.id,"name":self.name,"command":self.command,"icon":self.icon,"runOnWorktreeCreate":self.run_on_worktree_create})
    }
}
fn icon(value: &Value) -> String {
    value
        .as_str()
        .filter(|icon| ICONS.contains(icon))
        .unwrap_or("play")
        .to_owned()
}
/// The scripts of a stored project, in the order its menu lists them.
pub fn scripts(project: &Value) -> Vec<ProjectScript> {
    project["scripts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(ProjectScript::from_stored)
        .collect()
}
/// The script one click runs: the one run last in the project, else its first.
pub fn primary<'a>(scripts: &'a [ProjectScript], last: Option<&str>) -> Option<&'a ProjectScript> {
    last.and_then(|id| {
        scripts
            .iter()
            .find(|script| script.id.eq_ignore_ascii_case(id))
    })
    .or_else(|| scripts.first())
}
/// Where the script runs, for commands such as copying `.env` from the main
/// checkout into a worktree. T3 Code's names are set too, so scripts imported
/// from `t3.json` work unchanged.
pub fn environment(project_root: &str, worktree: Option<&str>) -> BTreeMap<String, String> {
    let mut environment = BTreeMap::from([
        ("COINCIDE_PROJECT_ROOT".to_owned(), project_root.to_owned()),
        ("T3CODE_PROJECT_ROOT".to_owned(), project_root.to_owned()),
    ]);
    if let Some(worktree) = worktree {
        environment.insert("COINCIDE_WORKTREE_PATH".into(), worktree.into());
        environment.insert("T3CODE_WORKTREE_PATH".into(), worktree.into());
    }
    environment
}
/// The only variables a script terminal may add to its shell's environment.
pub fn script_variable(name: &str) -> bool {
    matches!(
        name,
        "COINCIDE_PROJECT_ROOT"
            | "T3CODE_PROJECT_ROOT"
            | "COINCIDE_WORKTREE_PATH"
            | "T3CODE_WORKTREE_PATH"
    )
}
/// The scripts a worktree made for a new thread runs on its own, in order.
pub fn worktree_setup(scripts: &[ProjectScript]) -> Vec<&ProjectScript> {
    scripts
        .iter()
        .filter(|script| script.run_on_worktree_create)
        .collect()
}
/// What the terminal a script ran in last is doing now, if it is still open.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LastTerminal {
    Idle,
    Busy,
    Exited,
}
/// As T3 Code: a script runs again in the terminal it ran in last when that
/// one is idle, else in a new tab.
pub fn reuses_terminal(last: Option<LastTerminal>) -> bool {
    last == Some(LastTerminal::Idle)
}
/// The scripts of a T3 Code `t3.json`, trimmed; entries without a name or a
/// command are skipped. Invalid JSON has none.
pub fn t3_scripts(data: &[u8]) -> Vec<ProjectScript> {
    let Ok(json) = serde_json::from_slice::<Value>(data) else {
        return Vec::new();
    };
    json["scripts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let name = entry["name"].as_str()?.trim();
            let command = entry["command"].as_str()?.trim();
            (!name.is_empty() && !command.is_empty()).then(|| ProjectScript {
                id: uuid::Uuid::new_v4().to_string().to_uppercase(),
                name: name.into(),
                command: command.into(),
                icon: icon(&entry["icon"]),
                run_on_worktree_create: entry["runOnWorktreeCreate"].as_bool().unwrap_or(false),
            })
        })
        .collect()
}
/// The `t3.json` scripts the project lacks, by name, for Import.
pub fn importable_t3_scripts(existing: &[ProjectScript], data: &[u8]) -> Vec<ProjectScript> {
    t3_scripts(data)
        .into_iter()
        .filter(|script| !existing.iter().any(|known| known.name == script.name))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn script(id: &str, name: &str, setup: bool) -> ProjectScript {
        ProjectScript {
            id: id.into(),
            name: name.into(),
            command: format!("run {name}"),
            icon: "play".into(),
            run_on_worktree_create: setup,
        }
    }
    #[test]
    fn stored_scripts_decode_leniently_and_round_trip() {
        let id = "6F9619FF-8B86-D011-B42D-00CF4FC964FF";
        let project = json!({"scripts":[
            {"id":id,"name":"Dev","command":"npm run dev","icon":"debug","runOnWorktreeCreate":true},
            {"name":"Lint","command":"npm run lint","icon":"sparkles"},
            {"name":"No command"}
        ]});
        let scripts = scripts(&project);
        assert_eq!(scripts.len(), 2);
        assert_eq!(
            (
                scripts[0].id.as_str(),
                scripts[0].icon.as_str(),
                scripts[0].run_on_worktree_create
            ),
            (id, "debug", true)
        );
        assert_eq!(
            (scripts[1].icon.as_str(), scripts[1].run_on_worktree_create),
            ("play", false)
        );
        assert!(uuid::Uuid::parse_str(&scripts[1].id).is_ok());
        assert_eq!(
            ProjectScript::from_stored(&scripts[0].to_stored()).unwrap(),
            scripts[0]
        );
    }
    #[test]
    fn one_click_runs_the_last_script_else_the_first() {
        let scripts = [script("A", "Dev", false), script("B", "Test", false)];
        assert_eq!(primary(&scripts, Some("b")).unwrap().name, "Test");
        assert_eq!(primary(&scripts, Some("gone")).unwrap().name, "Dev");
        assert_eq!(primary(&scripts, None).unwrap().name, "Dev");
        assert!(primary(&[], Some("A")).is_none());
    }
    #[test]
    fn environment_names_both_coincide_and_t3_code_variables() {
        let root = environment("/p", None);
        assert_eq!(root.len(), 2);
        assert_eq!(root["T3CODE_PROJECT_ROOT"], "/p");
        let worktree = environment("/p", Some("/w"));
        assert_eq!(worktree["COINCIDE_WORKTREE_PATH"], "/w");
        assert_eq!(worktree["T3CODE_WORKTREE_PATH"], "/w");
        assert!(worktree.keys().all(|name| script_variable(name)));
        assert!(!script_variable("COINCIDE_CONTROL_SOCKET"));
    }
    #[test]
    fn worktree_setup_and_terminal_reuse_follow_swift() {
        let scripts = [
            script("A", "Install", true),
            script("B", "Dev", false),
            script("C", "Env", true),
        ];
        let setup: Vec<_> = worktree_setup(&scripts)
            .into_iter()
            .map(|s| s.name.as_str())
            .collect();
        assert_eq!(setup, ["Install", "Env"]);
        assert!(reuses_terminal(Some(LastTerminal::Idle)));
        for other in [None, Some(LastTerminal::Busy), Some(LastTerminal::Exited)] {
            assert!(!reuses_terminal(other));
        }
    }
    #[test]
    fn t3_json_imports_only_named_commands_the_project_lacks() {
        let data = br#"{"scripts":[
            {"name":" Dev ","command":" bun dev ","icon":"play"},
            {"name":"Test","command":"bun test","icon":"test","runOnWorktreeCreate":true},
            {"name":"","command":"x"},{"name":"Empty","command":"  "}
        ]}"#;
        let found = t3_scripts(data);
        assert_eq!(found.len(), 2);
        assert_eq!(
            (found[0].name.as_str(), found[0].command.as_str()),
            ("Dev", "bun dev")
        );
        assert!(found[1].run_on_worktree_create);
        let importable = importable_t3_scripts(&[script("A", "Dev", false)], data);
        assert_eq!(importable.len(), 1);
        assert_eq!(importable[0].name, "Test");
        assert!(t3_scripts(b"not json").is_empty());
    }
}
