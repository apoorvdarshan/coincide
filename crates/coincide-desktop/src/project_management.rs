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
    }
    pub fn close(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.open = false;
        self.preview = None;
        self.choosing = false;
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
