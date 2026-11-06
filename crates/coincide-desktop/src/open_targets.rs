//! Native app handoff. Arguments never pass through a shell; discovery and
//! rendering never launch an app. A user click captures the current folder.
use super::*;
use std::path::{Path, PathBuf};
#[derive(Clone)]
pub(super) struct Target {
    pub id: &'static str,
    pub name: &'static str,
    editor: bool,
    program: PathBuf,
    args: Vec<String>,
}
fn executable(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
}
pub(super) fn installed() -> Vec<Target> {
    let mut targets = Vec::new();
    #[cfg(target_os = "macos")]
    for (id, name, bundle) in [
        ("com.todesktop.230313mzl4w4u92", "Cursor", "Cursor.app"),
        ("com.microsoft.VSCode", "VS Code", "Visual Studio Code.app"),
        (
            "com.microsoft.VSCodeInsiders",
            "VS Code Insiders",
            "Visual Studio Code - Insiders.app",
        ),
        ("com.vscodium", "VSCodium", "VSCodium.app"),
        ("com.exafunction.windsurf", "Windsurf", "Windsurf.app"),
        ("dev.zed.Zed", "Zed", "Zed.app"),
        ("com.google.antigravity", "Antigravity", "Antigravity.app"),
        ("dev.kiro.desktop", "Kiro", "Kiro.app"),
        ("com.apple.dt.Xcode", "Xcode", "Xcode.app"),
        ("com.sublimetext.4", "Sublime Text", "Sublime Text.app"),
        ("com.panic.Nova", "Nova", "Nova.app"),
        ("com.barebones.bbedit", "BBEdit", "BBEdit.app"),
        ("com.apple.Terminal", "Terminal", "Utilities/Terminal.app"),
        ("com.googlecode.iterm2", "iTerm", "iTerm.app"),
        ("com.mitchellh.ghostty", "Ghostty", "Ghostty.app"),
    ] {
        let found = [
            PathBuf::from("/Applications"),
            PathBuf::from("/System/Applications"),
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("Applications"),
        ]
        .into_iter()
        .map(|root| root.join(bundle))
        .find(|path| path.is_dir());
        if let Some(app) = found {
            targets.push(Target {
                id,
                name,
                editor: !matches!(
                    id,
                    "com.apple.Terminal" | "com.googlecode.iterm2" | "com.mitchellh.ghostty"
                ),
                program: "/usr/bin/open".into(),
                args: vec!["-a".into(), app.to_string_lossy().into_owned()],
            });
        }
    }
    #[cfg(not(target_os = "macos"))]
    for (id, name, command) in [
        ("com.todesktop.230313mzl4w4u92", "Cursor", "cursor"),
        ("com.microsoft.VSCode", "VS Code", "code"),
        (
            "com.microsoft.VSCodeInsiders",
            "VS Code Insiders",
            "code-insiders",
        ),
        ("com.vscodium", "VSCodium", "codium"),
        ("com.exafunction.windsurf", "Windsurf", "windsurf"),
        ("dev.zed.Zed", "Zed", "zed"),
        ("dev.kiro.desktop", "Kiro", "kiro"),
        ("com.sublimetext.4", "Sublime Text", "subl"),
    ] {
        // Windows launchers commonly have .exe/.cmd suffixes. .cmd files
        // require a shell, so only native executables are eligible here.
        let program = if cfg!(target_os = "windows") {
            executable(&format!("{command}.exe"))
        } else {
            executable(command)
        };
        if let Some(program) = program {
            targets.push(Target {
                id,
                name,
                editor: true,
                program,
                args: Vec::new(),
            });
        }
    }
    #[cfg(target_os = "windows")]
    for (id, name, folder, binary) in [
        (
            "com.todesktop.230313mzl4w4u92",
            "Cursor",
            "cursor",
            "Cursor.exe",
        ),
        (
            "com.microsoft.VSCode",
            "VS Code",
            "Microsoft VS Code",
            "Code.exe",
        ),
        (
            "com.microsoft.VSCodeInsiders",
            "VS Code Insiders",
            "Microsoft VS Code Insiders",
            "Code - Insiders.exe",
        ),
        ("com.vscodium", "VSCodium", "VSCodium", "VSCodium.exe"),
        (
            "com.exafunction.windsurf",
            "Windsurf",
            "Windsurf",
            "Windsurf.exe",
        ),
    ] {
        if targets.iter().any(|target| target.id == id) {
            continue;
        }
        let roots = [
            std::env::var_os("LOCALAPPDATA").map(|root| PathBuf::from(root).join("Programs")),
            std::env::var_os("PROGRAMFILES").map(PathBuf::from),
        ];
        if let Some(program) = roots
            .into_iter()
            .flatten()
            .map(|root| root.join(folder).join(binary))
            .find(|path| path.is_file())
        {
            targets.push(Target {
                id,
                name,
                editor: true,
                program,
                args: Vec::new(),
            });
        }
    }
    #[cfg(target_os = "macos")]
    targets.push(Target {
        id: "com.apple.finder",
        name: "Finder",
        editor: false,
        program: "/usr/bin/open".into(),
        args: Vec::new(),
    });
    #[cfg(target_os = "windows")]
    targets.push(Target {
        id: "windows.explorer",
        name: "File Explorer",
        editor: false,
        program: PathBuf::from(std::env::var_os("WINDIR").unwrap_or_else(|| "C:\\Windows".into()))
            .join("explorer.exe"),
        args: Vec::new(),
    });
    #[cfg(target_os = "linux")]
    if let Some(program) = executable("xdg-open") {
        targets.push(Target {
            id: "linux.files",
            name: "Files",
            editor: false,
            program,
            args: Vec::new(),
        });
    }
    targets
}
pub(super) fn preferred<'a>(targets: &'a [Target], settings: &Value) -> Option<&'a Target> {
    targets
        .iter()
        .find(|target| settings["preferredOpenTarget"].as_str() == Some(target.id))
        .or_else(|| targets.iter().find(|target| target.editor))
        .or_else(|| {
            targets.iter().find(|target| {
                matches!(
                    target.id,
                    "com.apple.finder" | "windows.explorer" | "linux.files"
                )
            })
        })
}
impl Coincide {
    pub(super) fn open_folder(&self) -> Option<PathBuf> {
        let selected = self.selected.as_ref()?;
        selected["worktreePath"]
            .as_str()
            .filter(|path| !path.is_empty())
            .or_else(|| {
                self.projects
                    .iter()
                    .find(|project| project["id"] == selected["projectID"])
                    .and_then(|project| project["path"].as_str())
                    .filter(|path| !path.is_empty())
            })
            .map(PathBuf::from)
    }
    pub(super) fn open_in_target(
        &mut self,
        target: Target,
        remember: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if remember {
            self.change_setting("preferredOpenTarget", json!(target.id), window, cx);
        }
        let Some(folder) = self.open_folder() else {
            return;
        };
        if !folder.is_absolute() || !folder.is_dir() {
            self.status = "The conversation folder is unavailable.".into();
            cx.notify();
            return;
        }
        let launch = cx.background_executor().spawn(async move {
            // Spawn is the OS application handoff, not a managed agent process.
            // We intentionally do not wait for the user's editor to exit.
            std::process::Command::new(target.program)
                .args(target.args)
                .arg(Path::new(&folder))
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .map(|_| target.name)
                .map_err(|_| "The selected app could not be opened.")
        });
        let completion = cx.spawn(async move |this, cx| {
            let result = launch.await;
            let _ = this.update(cx, |this, cx| {
                if this.media.shutdown_requested {
                    return;
                }
                this.status = match result {
                    Ok(name) => format!("Requested folder opening in {name}."),
                    Err(error) => error.into(),
                };
                cx.notify();
            });
        });
        self.navigation_tasks.push(completion);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn target(id: &'static str) -> Target {
        Target {
            id,
            name: id,
            editor: true,
            program: "test-only-unused".into(),
            args: vec![],
        }
    }
    #[::core::prelude::v1::test]
    fn saved_installed_choice_wins_and_missing_choice_falls_back_without_rewriting_settings() {
        let targets = vec![target("editor"), target("files")];
        let settings = json!({"preferredOpenTarget":"files", "unrelated":true});
        assert_eq!(preferred(&targets, &settings).unwrap().id, "files");
        assert_eq!(settings["unrelated"], true);
        let missing = json!({"preferredOpenTarget":"uninstalled"});
        assert_eq!(preferred(&targets, &missing).unwrap().id, "editor");
        assert_eq!(missing["preferredOpenTarget"], "uninstalled");
        assert!(preferred(&[], &settings).is_none());
    }
}
