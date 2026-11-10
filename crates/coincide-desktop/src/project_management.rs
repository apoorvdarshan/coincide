//! Explicit-target form state. Late native picker completions never retarget a form.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum Mode {
    #[default]
    Manage,
    Add,
    Rename,
    Relocate,
    Remove,
    Recovery,
    Restore,
}
impl Mode {
    pub fn operation(self) -> Option<&'static str> {
        match self {
            Self::Rename => Some("rename"),
            Self::Relocate => Some("relocate"),
            Self::Remove => Some("remove"),
            Self::Restore => Some("restore"),
            _ => None,
        }
    }
}
#[derive(Default)]
pub(super) struct Session {
    pub open: bool,
    pub mode: Mode,
    pub target: Option<String>,
    pub preview: Option<serde_json::Value>,
    pub recoveries: Vec<serde_json::Value>,
    pub error: String,
    pub choosing: bool,
    /// Matching subfolders for the typed path, shown under the field.
    pub completions: Vec<std::path::PathBuf>,
    pub completion_index: usize,
    generation: u64,
}
impl Session {
    pub fn begin(&mut self, mode: Mode, target: Option<String>) {
        self.generation = self.generation.wrapping_add(1);
        self.open = true;
        self.mode = mode;
        self.target = target;
        self.preview = None;
        self.recoveries.clear();
        self.error.clear();
        self.choosing = false;
        self.completions.clear();
        self.completion_index = 0;
    }
    pub fn close(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.open = false;
        self.preview = None;
        self.choosing = false;
        self.completions.clear();
        self.completion_index = 0;
    }
    pub fn choose(&mut self) -> Option<(u64, Mode, Option<String>)> {
        if !self.open || self.choosing || !matches!(self.mode, Mode::Add | Mode::Relocate) {
            return None;
        }
        self.choosing = true;
        Some((self.generation, self.mode, self.target.clone()))
    }
    pub fn chosen(&mut self, stamp: &(u64, Mode, Option<String>)) -> bool {
        let current = self.open
            && self.choosing
            && self.generation == stamp.0
            && self.mode == stamp.1
            && self.target == stamp.2;
        if current {
            self.choosing = false;
        }
        current
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn picker_result_cannot_retarget_after_close_reopen_or_project_change() {
        let mut s = Session::default();
        s.begin(Mode::Relocate, Some("one".into()));
        let old = s.choose().unwrap();
        s.begin(Mode::Relocate, Some("two".into()));
        assert!(!s.chosen(&old));
        let fresh = s.choose().unwrap();
        assert!(s.chosen(&fresh));
        assert!(!s.chosen(&fresh));
        s.begin(Mode::Add, None);
        let old = s.choose().unwrap();
        s.close();
        assert!(!s.chosen(&old));
        s.begin(Mode::Add, None);
        assert!(!s.chosen(&old));
    }
    #[test]
    fn target_and_preview_do_not_survive_a_new_operation() {
        let mut s = Session::default();
        s.begin(Mode::Remove, Some("one".into()));
        s.preview = Some(serde_json::json!({"ticket":"old","threadCount":3}));
        s.begin(Mode::Restore, Some("archive".into()));
        assert!(s.preview.is_none());
        assert_eq!(s.target.as_deref(), Some("archive"));
        assert_eq!(s.mode.operation(), Some("restore"));
    }
}

/// Matching subfolders for a partially typed path, keeping the text the user
/// wrote (so `~` stays `~`). Directory names only, hidden entries only once a
/// dot is typed, sorted, and capped for a short dropdown.
pub(super) fn path_completions(input: &str) -> Vec<std::path::PathBuf> {
    let input = input.trim();
    if input.is_empty() {
        return Vec::new();
    }
    let (typed_dir, prefix) = match input.rfind(['/', '\\']) {
        Some(index) => (&input[..=index], &input[index + 1..]),
        None => ("", input),
    };
    let dir = if typed_dir.is_empty() {
        std::path::PathBuf::from(".")
    } else {
        expand_home(typed_dir)
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut found = entries
        .flatten()
        .take(2_000)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with(prefix) && (!prefix.is_empty() || !name.starts_with('.')) {
                Some(std::path::PathBuf::from(format!("{typed_dir}{name}")))
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    found.sort();
    found.truncate(8);
    found
}

/// `~` and `~/x` resolve against the home folder; anything else is unchanged.
pub(super) fn expand_home(path: &str) -> std::path::PathBuf {
    if path == "~" || path.starts_with("~/") || path.starts_with("~\\") {
        let home =
            std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_default();
        return if path.len() <= 2 {
            std::path::PathBuf::from(home)
        } else {
            std::path::PathBuf::from(home).join(&path[2..])
        };
    }
    std::path::PathBuf::from(path)
}

#[cfg(test)]
mod path_tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn completions_list_matching_folders_only() {
        let root = tempfile::tempdir().unwrap();
        for name in ["alpha", "alphabet", "beta"] {
            std::fs::create_dir(root.path().join(name)).unwrap();
        }
        std::fs::write(root.path().join("alpha.txt"), b"file").unwrap();
        std::fs::write(root.path().join("alpha2"), b"file").unwrap();
        std::fs::create_dir(root.path().join(".hidden")).unwrap();
        let base = root.path().to_string_lossy().into_owned();
        let found = path_completions(&format!("{base}/alph"));
        assert_eq!(
            found,
            vec![
                std::path::PathBuf::from(format!("{base}/alpha")),
                std::path::PathBuf::from(format!("{base}/alphabet")),
            ]
        );
        assert!(
            path_completions(&format!("{base}/"))
                .iter()
                .all(|path| { path.file_name().is_some_and(|name| name != ".hidden") })
        );
        assert!(
            path_completions(&format!("{base}/.h"))
                .iter()
                .any(|path| { path.file_name().is_some_and(|name| name == ".hidden") })
        );
        assert!(path_completions(&format!("{base}/zzz")).is_empty());
    }

    #[::core::prelude::v1::test]
    fn home_expansion_keeps_plain_paths() {
        let home = std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap();
        assert_eq!(expand_home("~"), std::path::PathBuf::from(&home));
        assert_eq!(
            expand_home("~/code"),
            std::path::PathBuf::from(&home).join("code")
        );
        assert_eq!(expand_home("/tmp/x"), std::path::PathBuf::from("/tmp/x"));
    }
}
