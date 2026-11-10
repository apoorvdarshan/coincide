//! Swift's `AppStore.workingDirectory(for:)`, shared by the panels that ask for
//! a conversation's folder. The order is the thread's worktree, then a bot
//! conversation's own folder (its stand-in for a project, home when unset), then
//! the project's folder. Reading it never creates or changes anything.
use anyhow::{Context as _, Result};
use serde_json::{Value, json};
use std::path::PathBuf;

/// The folder the thread works in, as stored. `None` when nothing names one;
/// a path that no longer exists is returned as stored, so the caller can say so.
pub(super) fn working_directory(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    thread: &str,
) -> Result<Option<PathBuf>> {
    let value = api("threads.read", json!({"threadId":thread,"itemLimit":0}))?;
    if let Some(path) = value["worktreePath"]
        .as_str()
        .filter(|path| !path.is_empty())
    {
        return Ok(Some(PathBuf::from(path)));
    }
    if let Some(bot) = value["botID"].as_str().filter(|bot| !bot.is_empty()) {
        return Ok(Some(bot_directory(api, bot)));
    }
    let projects = api("projects.list", json!({}))?;
    Ok(projects
        .as_array()
        .context("Invalid projects")?
        .iter()
        .find(|project| project["id"] == value["projectID"])
        .and_then(|project| project["path"].as_str())
        .filter(|path| !path.is_empty())
        .map(PathBuf::from))
}

/// A bot's folder, home when it set none. An unreadable bot document is also
/// home: a conversation must still open its folder.
fn bot_directory(api: &mut impl FnMut(&str, Value) -> Result<Value>, bot: &str) -> PathBuf {
    api("bots.read", json!({"botId":bot}))
        .ok()
        .and_then(|bot| {
            bot["folder"]
                .as_str()
                .filter(|folder| !folder.is_empty())
                .map(PathBuf::from)
                .filter(|folder| folder.is_absolute())
        })
        .unwrap_or_else(home)
}

fn home() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(if cfg!(windows) { "C:\\" } else { "/" }))
}

#[cfg(test)]
mod tests {
    use super::working_directory;
    use serde_json::{Value, json};

    #[::core::prelude::v1::test]
    fn a_worktree_wins_then_a_bots_folder_then_the_project() {
        let folder = std::env::temp_dir();
        let mut methods = Vec::new();
        let mut api = |method: &str, params: Value| {
            methods.push((method.to_owned(), params));
            Ok(match method {
                "threads.read" => json!({"worktreePath":folder,"projectID":"p"}),
                _ => anyhow::bail!("unexpected {method}"),
            })
        };
        assert_eq!(
            working_directory(&mut api, "thread").unwrap(),
            Some(folder.clone())
        );
        assert_eq!(methods.len(), 1);
    }

    #[::core::prelude::v1::test]
    fn a_bot_conversation_without_a_worktree_uses_the_bots_folder() {
        let folder = std::env::temp_dir();
        let mut api = |method: &str, _params: Value| {
            Ok(match method {
                "threads.read" => {
                    json!({"botID":"bot","projectID":"B0B5B0B5-C01C-4D1E-B075-000000000001"})
                }
                "bots.read" => json!({"id":"bot","folder":folder}),
                _ => anyhow::bail!("unexpected {method}"),
            })
        };
        assert_eq!(
            working_directory(&mut api, "thread").unwrap(),
            Some(folder.clone())
        );
    }

    #[::core::prelude::v1::test]
    fn a_deleted_bot_or_missing_folder_falls_back_to_home() {
        let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
            .map(std::path::PathBuf::from)
            .unwrap();
        let mut api = |method: &str, _params: Value| match method {
            "threads.read" => Ok(json!({"botID":"gone"})),
            "bots.read" => anyhow::bail!("Unknown bot"),
            _ => anyhow::bail!("unexpected {method}"),
        };
        assert_eq!(working_directory(&mut api, "thread").unwrap(), Some(home));
    }

    #[::core::prelude::v1::test]
    fn a_project_thread_without_a_worktree_uses_the_project_folder() {
        let folder = std::env::temp_dir();
        let mut api = |method: &str, _params: Value| {
            Ok(match method {
                "threads.read" => json!({"projectID":"p"}),
                "projects.list" => {
                    json!([{"id":"other","path":"/elsewhere"},{"id":"p","path":folder}])
                }
                _ => anyhow::bail!("unexpected {method}"),
            })
        };
        assert_eq!(
            working_directory(&mut api, "thread").unwrap(),
            Some(folder.clone())
        );
    }
}
