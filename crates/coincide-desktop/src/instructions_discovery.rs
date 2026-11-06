//! Swift-compatible bounded project rule discovery. Directory symlinks are not
//! traversed; native editing still binds each explicitly selected file.
use super::*;
use std::collections::VecDeque;
const SKIPPED: [&str; 15] = [
    "node_modules",
    "build",
    "DerivedData",
    "Pods",
    "Carthage",
    "vendor",
    "dist",
    "venv",
    "target",
    "__pycache__",
    ".build",
    ".venv",
    ".next",
    ".nuxt",
    ".gradle",
];
pub(super) fn project_paths(root: &Path) -> Vec<PathBuf> {
    let mut result = NAMES.iter().map(|name| root.join(name)).collect::<Vec<_>>();
    let mut queue = VecDeque::from([(root.to_owned(), 0usize, false)]);
    let mut visited = 0;
    while let Some((directory, depth, cursor)) = queue.pop_front() {
        if visited >= 4000 || result.len() >= 4096 {
            break;
        }
        visited += 1;
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        let mut entries = entries.flatten().take(16384).collect::<Vec<_>>();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            if result.len() >= 4096 {
                break;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if cursor {
                if !kind.is_dir() && path.extension().is_some_and(|e| e == "mdc") {
                    result.push(path);
                } else if depth < 6 && kind.is_dir() && !kind.is_symlink() {
                    queue.push_back((path, depth + 1, true));
                }
                continue;
            }
            if [
                "AGENTS.md",
                "CLAUDE.md",
                "GEMINI.md",
                "AGENTS.override.md",
                "CLAUDE.local.md",
                ".cursorrules",
            ]
            .contains(&name.as_str())
                && !kind.is_dir()
            {
                if !result.contains(&path) {
                    result.push(path);
                }
                continue;
            }
            if name == ".claude" && kind.is_dir() && !kind.is_symlink() {
                let file = path.join("CLAUDE.md");
                if fs::symlink_metadata(&file).is_ok() {
                    result.push(file);
                }
                continue;
            }
            if name == ".cursor" && kind.is_dir() && !kind.is_symlink() {
                let rules = path.join("rules");
                if fs::symlink_metadata(&rules)
                    .is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
                {
                    queue.push_back((rules, 0, true));
                }
                continue;
            }
            if depth < 6
                && !name.starts_with('.')
                && !SKIPPED.contains(&name.as_str())
                && kind.is_dir()
                && !kind.is_symlink()
            {
                queue.push_back((path, depth + 1, false));
            }
        }
    }
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn nested_known_rules_are_found_while_vendor_hidden_and_symlink_directories_are_not_followed() {
        let root =
            std::env::temp_dir().join(format!("coincide-rule-discovery-{}", uuid::Uuid::new_v4()));
        native_file::private_directory(&root).unwrap();
        for directory in [
            "src/deep",
            "src/.claude",
            ".cursor/rules/nested",
            "vendor/library",
            ".hidden",
        ] {
            fs::create_dir_all(root.join(directory)).unwrap();
        }
        for file in [
            "src/deep/AGENTS.override.md",
            "src/.claude/CLAUDE.md",
            ".cursor/rules/nested/team.mdc",
            "vendor/library/AGENTS.md",
            ".hidden/GEMINI.md",
            "src/deep/random.md",
        ] {
            fs::write(root.join(file), "Synthetic rules").unwrap();
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(root.join("src"), root.join("alias")).unwrap();
        let paths = project_paths(&root);
        for expected in [
            "AGENTS.md",
            "src/deep/AGENTS.override.md",
            "src/.claude/CLAUDE.md",
            ".cursor/rules/nested/team.mdc",
        ] {
            assert!(paths.contains(&root.join(expected)), "{expected}");
        }
        assert!(!paths.iter().any(|p| p.starts_with(root.join("vendor"))
            || p.starts_with(root.join(".hidden"))
            || p.starts_with(root.join("alias"))
            || p.ends_with("random.md")));
        fs::remove_dir_all(root).unwrap();
    }
}
