//! Native app handoff. Arguments never pass through a shell; discovery and
//! rendering never launch an app. A user click captures the current folder.
use super::*;
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use std::path::{Path, PathBuf};
#[derive(Clone)]
pub(super) struct Target {
    pub id: &'static str,
    pub name: &'static str,
    editor: bool,
    program: PathBuf,
    args: Vec<String>,
}
#[cfg(not(target_os = "macos"))]
fn executable(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|path| {
            if !path.is_file() {
                return false;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                path.metadata()
                    .is_ok_and(|metadata| metadata.permissions().mode() & 0o111 != 0)
            }
            #[cfg(not(unix))]
            {
                true
            }
        })
}
#[cfg(target_os = "macos")]
fn mac_application(bundle: &str) -> Option<PathBuf> {
    // NSWorkspace resolves renamed/nonstandard installs by bundle identity,
    // matching Swift. Discovery performs no launch or account operation.
    objc2::rc::autoreleasepool(|_| unsafe {
        let workspace: *mut objc2::runtime::AnyObject =
            objc2::msg_send![objc2::class!(NSWorkspace), sharedWorkspace];
        if workspace.is_null() {
            return None;
        }
        let identifier = objc2_foundation::NSString::from_str(bundle);
        let url: Option<objc2::rc::Retained<objc2_foundation::NSURL>> =
            objc2::msg_send![workspace, URLForApplicationWithBundleIdentifier:&*identifier];
        url.and_then(|url| url.path())
            .map(|path| PathBuf::from(path.to_string()))
    })
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
        ("dev.zed.Zed-Preview", "Zed Preview", "Zed Preview.app"),
        ("com.google.antigravity", "Antigravity", "Antigravity.app"),
        ("com.trae.app", "Trae", "Trae.app"),
        ("dev.kiro.desktop", "Kiro", "Kiro.app"),
        ("com.apple.dt.Xcode", "Xcode", "Xcode.app"),
        ("com.sublimetext.4", "Sublime Text", "Sublime Text.app"),
        ("com.panic.Nova", "Nova", "Nova.app"),
        ("com.barebones.bbedit", "BBEdit", "BBEdit.app"),
        (
            "com.jetbrains.intellij",
            "IntelliJ IDEA",
            "IntelliJ IDEA.app",
        ),
        (
            "com.jetbrains.intellij.ce",
            "IntelliJ IDEA CE",
            "IntelliJ IDEA CE.app",
        ),
        ("com.jetbrains.WebStorm", "WebStorm", "WebStorm.app"),
        ("com.jetbrains.pycharm", "PyCharm", "PyCharm.app"),
        ("com.jetbrains.pycharm.ce", "PyCharm CE", "PyCharm CE.app"),
        ("com.jetbrains.goland", "GoLand", "GoLand.app"),
        ("com.jetbrains.CLion", "CLion", "CLion.app"),
        ("com.jetbrains.rustrover", "RustRover", "RustRover.app"),
        ("com.jetbrains.PhpStorm", "PhpStorm", "PhpStorm.app"),
        ("com.jetbrains.rider", "Rider", "Rider.app"),
        ("com.jetbrains.rubymine", "RubyMine", "RubyMine.app"),
        ("com.jetbrains.datagrip", "DataGrip", "DataGrip.app"),
        (
            "com.google.android.studio",
            "Android Studio",
            "Android Studio.app",
        ),
        ("com.apple.Terminal", "Terminal", "Utilities/Terminal.app"),
        ("com.googlecode.iterm2", "iTerm", "iTerm.app"),
        ("com.mitchellh.ghostty", "Ghostty", "Ghostty.app"),
        ("dev.warp.Warp-Stable", "Warp", "Warp.app"),
        ("com.github.wez.wezterm", "WezTerm", "WezTerm.app"),
        ("net.kovidgoyal.kitty", "kitty", "kitty.app"),
        ("org.alacritty", "Alacritty", "Alacritty.app"),
    ] {
        let found = mac_application(id).or_else(|| {
            [
                PathBuf::from("/Applications"),
                PathBuf::from("/System/Applications"),
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("Applications"),
            ]
            .into_iter()
            .map(|root| root.join(bundle))
            .find(|path| path.is_dir())
        });
        if let Some(app) = found {
            targets.push(Target {
                id,
                name,
                editor: !matches!(
                    id,
                    "com.apple.Terminal"
                        | "com.googlecode.iterm2"
                        | "com.mitchellh.ghostty"
                        | "dev.warp.Warp-Stable"
                        | "com.github.wez.wezterm"
                        | "net.kovidgoyal.kitty"
                        | "org.alacritty"
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
/// The platform file manager, for the branch toolbar's Reveal / Show item. Finder
/// selects the folder in its parent, as Swift's activateFileViewerSelecting does.
pub(super) fn file_manager() -> Option<Target> {
    let mut target = installed().into_iter().find(|target| {
        matches!(
            target.id,
            "com.apple.finder" | "windows.explorer" | "linux.files"
        )
    })?;
    if target.id == "com.apple.finder" {
        target.args = vec!["-R".into()];
    }
    Some(target)
/// A conversation's worktree, else its project's folder.
pub(super) fn folder_of(thread: &Value, projects: &[Value]) -> Option<PathBuf> {
    thread["worktreePath"]
        .as_str()
        .filter(|path| !path.is_empty())
        .or_else(|| {
            projects
                .iter()
                .find(|project| project["id"] == thread["projectID"])
                .and_then(|project| project["path"].as_str())
                .filter(|path| !path.is_empty())
        })
        .map(PathBuf::from)
}
fn is_file_manager(id: &str) -> bool {
    matches!(id, "com.apple.finder" | "windows.explorer" | "linux.files")
}
/// The menu title of Reveal in Finder on this platform.
pub(super) fn reveal_title() -> &'static str {
    if cfg!(target_os = "macos") {
        "Reveal in Finder"
    } else if cfg!(target_os = "windows") {
        "Show in File Explorer"
    } else {
        "Show in Files"
    }
}
/// The file manager's arguments that select `folder`, and the path appended
/// after them: `open -R` and `explorer /select,` select it in its parent.
fn reveal_arguments(id: &str, folder: &Path, parent: PathBuf) -> (Vec<String>, PathBuf) {
    match id {
        "com.apple.finder" => (vec!["-R".into()], folder.to_path_buf()),
        "windows.explorer" => (vec!["/select,".into()], folder.to_path_buf()),
        _ => (Vec::new(), parent),
    }
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
/// The editor linked files open in: the one "Open In" uses when that is an
/// editor, else the first installed. Never a terminal or file manager.
pub(super) fn file_editor(targets: &[Target], settings: &Value) -> Option<Target> {
    targets
        .iter()
        .find(|target| target.editor && settings["preferredOpenTarget"].as_str() == Some(target.id))
        .or_else(|| targets.iter().find(|target| target.editor))
        .cloned()
}
struct PreferenceChoice {
    value: Value,
    label: String,
    group: Option<&'static str>,
    available: bool,
}
fn preference_choices(targets: &[Target], saved: Option<&str>) -> Vec<PreferenceChoice> {
    let mut choices = vec![PreferenceChoice {
        value: Value::Null,
        label: "Automatic (first installed editor)".into(),
        group: None,
        available: true,
    }];
    if let Some(saved) = saved.filter(|id| !targets.iter().any(|target| target.id == *id)) {
        choices.push(PreferenceChoice {
            value: json!(saved),
            label: format!(
                "{} (not installed)",
                saved.chars().take(160).collect::<String>()
            ),
            group: None,
            available: false,
        });
    }
    for group in ["Editors", "Terminals", "File Manager"] {
        for target in targets {
            let category = if target.editor {
                "Editors"
            } else if matches!(
                target.id,
                "com.apple.finder" | "windows.explorer" | "linux.files"
            ) {
                "File Manager"
            } else {
                "Terminals"
            };
            if category == group {
                choices.push(PreferenceChoice {
                    value: json!(target.id),
                    label: target.name.into(),
                    group: Some(group),
                    available: true,
                });
            }
        }
    }
    choices
}
impl Coincide {
    /// Picking a preference never opens an application. The rail/menu captures
    /// the current folder only on its separate explicit Open action.
    pub(super) fn open_target_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let selected = self
            .settings
            .get("preferredOpenTarget")
            .cloned()
            .unwrap_or(Value::Null);
        let choices = preference_choices(&self.open_targets, selected.as_str());
        let caption = if selected.is_null() {
            preferred(&self.open_targets,&json!({})).map(|target|format!("Automatic opens {}. Right-click Open In in the rail to choose another app.",target.name))
                .unwrap_or_else(||"No compatible folder-opening application was found.".into())
        } else {
            "The rail's Open In button and Open in Editor command use this preference. A missing app keeps its saved choice and uses the available fallback.".into()
        };
        let current_label = choices
            .iter()
            .find(|choice| choice.value == selected)
            .map(|choice| choice.label.clone())
            .unwrap_or_else(|| "Automatic (first installed editor)".into());
        let parent = cx.entity().downgrade();
        div()
            .id("open-target-preferences")
            .role(Role::Group)
            .aria_label("Open project folders in")
            .p_3()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .flex()
                    .items_center()
                    .flex_wrap()
                    .gap_3()
                    .child(
                        div()
                            .flex_1()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("Open project folders in"),
                    )
                    .child(
                        Button::new("open-target-preference")
                            .label(current_label)
                            .compact()
                            .accessibility_label("Preferred application for project folders")
                            .dropdown_caret(true)
                            .dropdown_menu(move |mut menu, _, _| {
                                let mut previous = None;
                                for choice in &choices {
                                    if choice.group != previous {
                                        if let Some(group) = choice.group {
                                            menu = menu
                                                .item(PopupMenuItem::separator())
                                                .item(PopupMenuItem::new(group).disabled(true));
                                        }
                                        previous = choice.group;
                                    }
                                    let parent = parent.clone();
                                    let value = choice.value.clone();
                                    menu = menu.item(
                                        PopupMenuItem::new(choice.label.clone())
                                            .checked(selected == value)
                                            .disabled(!choice.available)
                                            .on_click(move |_, window, cx| {
                                                let _ = parent.update(cx, |this, cx| {
                                                    this.change_setting(
                                                        "preferredOpenTarget",
                                                        value.clone(),
                                                        window,
                                                        cx,
                                                    )
                                                });
                                            }),
                                    );
                                }
                                menu
                            }),
                    ),
            )
            .child(div().text_sm().child(caption))
            .into_any_element()
    }
    pub(super) fn open_folder(&self) -> Option<PathBuf> {
        folder_of(self.selected.as_ref()?, &self.projects)
    }
    /// The folder of any conversation, for sidebar actions that leave the open
    /// one open (Swift's `ThreadActions.folder(for:)`).
    pub(super) fn thread_folder(&self, id: &str) -> Option<PathBuf> {
        if self
            .selected
            .as_ref()
            .is_some_and(|thread| thread["id"] == id)
        {
            return self.open_folder();
        }
        let thread = call(&self.engine, "threads.read", json!({"threadId":id})).ok()?;
        folder_of(&thread, &self.projects)
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
        self.open_in_folder(target, folder, cx);
    }
    /// Swift's Reveal in Finder: the folder selected in its parent, never opened
    /// with its default app. Linux has no standard selection request, so the
    /// parent folder opens instead.
    pub(super) fn reveal_in_file_manager(&mut self, folder: PathBuf, cx: &mut Context<Self>) {
        let Some(mut target) = self
            .open_targets
            .iter()
            .find(|target| is_file_manager(target.id))
            .cloned()
        else {
            self.status = "No file manager is available.".into();
            cx.notify();
            return;
        };
        let Some(parent) = folder.parent().map(Path::to_path_buf) else {
            return;
        };
        let (args, opened) = reveal_arguments(target.id, &folder, parent);
        target.args = args;
        self.open_in_folder(target, opened, cx);
    }
    pub(super) fn open_in_folder(
        &mut self,
        target: Target,
        folder: PathBuf,
        cx: &mut Context<Self>,
    ) {
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        if !folder.is_absolute() || !folder.is_dir() {
            self.status = "The conversation folder is unavailable.".into();
            cx.notify();
            return;
        }
        self.launch_target(target, folder, "folder", cx);
    }
    /// A file from a transcript link, in an editor the user installed.
    pub(super) fn open_file_in_editor(
        &mut self,
        target: Target,
        file: PathBuf,
        cx: &mut Context<Self>,
    ) {
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        if !file.is_absolute() || !file.is_file() {
            self.status = "The linked file is unavailable.".into();
            cx.notify();
            return;
        }
        self.launch_target(target, file, "file", cx);
    }
    fn launch_target(
        &mut self,
        target: Target,
        folder: PathBuf,
        noun: &'static str,
        cx: &mut Context<Self>,
    ) {
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
                .map(|child| (target.name, child))
                .map_err(|_| "The selected app could not be opened.")
        });
        let completion = cx.spawn(async move |this, cx| {
            let result = launch.await;
            let _ = this.update(cx, |this, cx| {
                this.status = match result {
                    Ok((name, child)) => {
                        this.open_target_children.push(child);
                        format!("Requested {noun} opening in {name}.")
                    }
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
    fn preferences_retain_missing_saved_identity_and_group_available_targets_without_launching() {
        let mut file = target("linux.files");
        file.editor = false;
        let mut terminal = target("terminal");
        terminal.editor = false;
        let targets = vec![file, target("editor"), terminal];
        let saved = json!({"preferredOpenTarget":"missing-editor","future":{"keep":true}});
        let before = saved.clone();
        let choices = preference_choices(&targets, saved["preferredOpenTarget"].as_str());
        assert_eq!(choices.len(), 5);
        assert_eq!(choices[0].value, Value::Null);
        assert_eq!(choices[1].value, "missing-editor");
        assert!(!choices[1].available);
        assert_eq!(choices[2].group, Some("Editors"));
        assert_eq!(choices[3].group, Some("Terminals"));
        assert_eq!(choices[4].group, Some("File Manager"));
        assert_eq!(preferred(&targets, &saved).unwrap().id, "editor");
        assert_eq!(saved, before);
        assert_eq!(preference_choices(&[], None).len(), 1);
        assert_eq!(preference_choices(&targets, Some("editor")).len(), 4);
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
    #[::core::prelude::v1::test]
    fn reveal_selects_the_folder_in_finder_and_explorer_and_opens_its_parent_elsewhere() {
        let folder = Path::new("/work/project");
        let parent = PathBuf::from("/work");
        assert_eq!(
            reveal_arguments("com.apple.finder", folder, parent.clone()),
            (vec!["-R".to_owned()], folder.to_path_buf())
        );
        assert_eq!(
            reveal_arguments("windows.explorer", folder, parent.clone()),
            (vec!["/select,".to_owned()], folder.to_path_buf())
        );
        assert_eq!(
            reveal_arguments("linux.files", folder, parent.clone()),
            (Vec::new(), parent)
        );
    }
}
