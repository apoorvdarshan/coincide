//! Bounded key decisions only. Opaque candidates and native edits stay in the picker controller.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Key {
    Up,
    Down,
    Enter,
    Tab,
    Escape,
}
impl Key {
    pub fn named(name: &str) -> Option<Self> {
        match name {
            "up" => Some(Self::Up),
            "down" => Some(Self::Down),
            "enter" => Some(Self::Enter),
            "tab" => Some(Self::Tab),
            "escape" => Some(Self::Escape),
            _ => None,
        }
    }
    fn activation(self) -> Option<usize> {
        match self {
            Self::Enter => Some(0),
            Self::Tab => Some(1),
            _ => None,
        }
    }
}
pub(super) struct Scope<'a> {
    pub thread: &'a str,
    pub route: bool,
    pub focused: bool,
    pub editable: bool,
    pub ime: bool,
    pub modified: bool,
    pub browser: bool,
    pub terminal: bool,
    pub automatic: bool,
    pub opened: bool,
    pub same_trigger: bool,
    pub fresh_results: bool,
    pub busy: bool,
    pub count: usize,
}
impl Scope<'_> {
    pub fn owns_keys(&self) -> bool {
        self.route
            && self.focused
            && self.editable
            && !self.ime
            && !self.modified
            && !self.browser
            && !self.terminal
            && !self.thread.is_empty()
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Decision {
    Pass,
    Consume,
    Select(usize),
    Activate(usize),
    Dismiss,
}
#[derive(Default)]
pub(super) struct Keys {
    pub selected: Option<usize>,
    // Keep physical activation custody through pane hide. Return's native
    // submit action must not receive repeats from the key that chose a file.
    held: [Option<String>; 2],
}
impl Keys {
    pub fn listed(&mut self, count: usize) {
        self.selected = (count > 0).then_some(0);
    }
    pub fn invalidate(&mut self) {
        self.selected = None;
    }
    pub fn release(&mut self, key: Key) {
        if let Some(index) = key.activation() {
            self.held[index] = None;
        }
    }
    pub fn decide(&mut self, key: Key, scope: &Scope<'_>) -> Decision {
        if !scope.owns_keys() {
            return Decision::Pass;
        }
        if let Some(index) = key.activation()
            && self.held[index].as_deref() == Some(scope.thread)
        {
            return Decision::Consume;
        }
        if !scope.automatic || !scope.opened || !scope.same_trigger {
            return Decision::Pass;
        }
        if key == Key::Escape {
            return Decision::Dismiss;
        }
        if scope.busy {
            if let Some(index) = key.activation() {
                self.held[index] = Some(scope.thread.into());
            }
            return Decision::Consume;
        }
        if !scope.fresh_results || scope.count == 0 || scope.count > 80 {
            return Decision::Pass;
        }
        let current = self
            .selected
            .filter(|&index| index < scope.count)
            .unwrap_or(0);
        match key {
            Key::Up | Key::Down => {
                let next = if key == Key::Down {
                    (current + 1) % scope.count
                } else {
                    (current + scope.count - 1) % scope.count
                };
                self.selected = Some(next);
                Decision::Select(next)
            }
            Key::Enter | Key::Tab => {
                self.held[key.activation().unwrap()] = Some(scope.thread.into());
                Decision::Activate(current)
            }
            Key::Escape => Decision::Dismiss,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn current_scope() -> Scope<'static> {
        Scope {
            thread: "one",
            route: true,
            focused: true,
            editable: true,
            ime: false,
            modified: false,
            browser: false,
            terminal: false,
            automatic: true,
            opened: true,
            same_trigger: true,
            fresh_results: true,
            busy: false,
            count: 3,
        }
    }
    // These callbacks stand for the actual controller decision: Pass allows the
    // native Input Enter→PressEnter→Send path; Activate invokes only Attach.
    fn route(
        keys: &mut Keys,
        key: Key,
        scope: &Scope<'_>,
        attached: &mut Vec<usize>,
        sends: &mut usize,
    ) -> Decision {
        let decision = keys.decide(key, scope);
        match decision {
            Decision::Activate(index) => attached.push(index),
            Decision::Pass if key == Key::Enter => *sends += 1,
            _ => {}
        }
        decision
    }
    #[test]
    fn current_candidate_navigation_wraps_bounded_rows_and_never_submits() {
        let mut keys = Keys::default();
        keys.listed(3);
        let scope = current_scope();
        let mut attachments = vec![];
        let mut sends = 0;
        assert_eq!(
            route(&mut keys, Key::Up, &scope, &mut attachments, &mut sends),
            Decision::Select(2)
        );
        assert_eq!(
            route(&mut keys, Key::Down, &scope, &mut attachments, &mut sends),
            Decision::Select(0)
        );
        assert_eq!(
            route(&mut keys, Key::Down, &scope, &mut attachments, &mut sends),
            Decision::Select(1)
        );
        assert_eq!(
            route(&mut keys, Key::Tab, &scope, &mut attachments, &mut sends),
            Decision::Activate(1)
        );
        assert_eq!(attachments, vec![1]);
        assert_eq!(sends, 0);
        keys.invalidate();
        assert!(keys.selected.is_none());
        keys.release(Key::Tab);
        keys.listed(1);
        let one = Scope { count: 1, ..scope };
        assert_eq!(keys.decide(Key::Up, &one), Decision::Select(0));
        let invalid = Scope { count: 81, ..one };
        assert_eq!(keys.decide(Key::Enter, &invalid), Decision::Pass);
    }
    #[test]
    fn held_activation_cannot_reach_send_after_busy_completion_and_pane_hide() {
        let mut keys = Keys::default();
        keys.listed(3);
        let mut scope = current_scope();
        let mut attachments = vec![];
        let mut sends = 0;
        assert_eq!(
            route(&mut keys, Key::Enter, &scope, &mut attachments, &mut sends),
            Decision::Activate(0)
        );
        scope.busy = true;
        for _ in 0..3 {
            assert_eq!(
                route(&mut keys, Key::Enter, &scope, &mut attachments, &mut sends),
                Decision::Consume
            );
        }
        scope.busy = false;
        scope.opened = false;
        scope.automatic = false;
        scope.fresh_results = false;
        scope.count = 0;
        keys.invalidate();
        assert_eq!(
            route(&mut keys, Key::Enter, &scope, &mut attachments, &mut sends),
            Decision::Consume
        );
        assert_eq!(attachments, vec![0]);
        assert_eq!(sends, 0);
        keys.release(Key::Enter);
        assert_eq!(
            route(&mut keys, Key::Enter, &scope, &mut attachments, &mut sends),
            Decision::Pass
        );
        assert_eq!(sends, 1);
        let mut loading = current_scope();
        loading.busy = true;
        loading.fresh_results = false;
        loading.count = 0;
        assert_eq!(
            route(
                &mut keys,
                Key::Enter,
                &loading,
                &mut attachments,
                &mut sends
            ),
            Decision::Consume
        );
        assert_eq!(attachments, vec![0]);
        assert_eq!(sends, 1);
    }
    #[test]
    fn tab_repeat_cannot_insert_text_or_activate_twice_after_completion_hides_the_pane() {
        let mut keys = Keys::default();
        keys.listed(3);
        let mut scope = current_scope();
        let mut attaches = 0;
        let mut native_tabs = 0;
        for phase in 0..4 {
            if phase > 0 {
                scope.opened = false;
                scope.automatic = false;
                scope.fresh_results = false;
                scope.count = 0;
                keys.invalidate();
            }
            match keys.decide(Key::Tab, &scope) {
                Decision::Activate(_) => attaches += 1,
                Decision::Pass => native_tabs += 1,
                Decision::Consume => {}
                other => panic!("Unexpected Tab decision {other:?}"),
            }
        }
        assert_eq!(attaches, 1);
        assert_eq!(native_tabs, 0);
        keys.release(Key::Enter);
        assert_eq!(keys.decide(Key::Tab, &scope), Decision::Consume);
        keys.release(Key::Tab);
        assert_eq!(keys.decide(Key::Tab, &scope), Decision::Pass);
    }
    #[test]
    fn other_routes_ime_modifiers_and_stale_results_never_gain_attach_authority() {
        for case in [
            "route",
            "focus",
            "editable",
            "ime",
            "modifiers",
            "browser",
            "terminal",
            "manual",
            "closed",
            "trigger",
            "results",
            "empty",
        ] {
            let mut scope = current_scope();
            match case {
                "route" => scope.route = false,
                "focus" => scope.focused = false,
                "editable" => scope.editable = false,
                "ime" => scope.ime = true,
                "modifiers" => scope.modified = true,
                "browser" => scope.browser = true,
                "terminal" => scope.terminal = true,
                "manual" => scope.automatic = false,
                "closed" => scope.opened = false,
                "trigger" => scope.same_trigger = false,
                "results" => scope.fresh_results = false,
                "empty" => scope.count = 0,
                _ => unreachable!(),
            }
            let mut keys = Keys::default();
            keys.listed(3);
            let mut attachments = vec![];
            let mut sends = 0;
            assert_eq!(
                route(&mut keys, Key::Enter, &scope, &mut attachments, &mut sends),
                Decision::Pass,
                "{case}"
            );
            assert!(attachments.is_empty());
            assert_eq!(sends, 1);
        }
        let mut keys = Keys::default();
        let mut first = current_scope();
        keys.listed(3);
        assert_eq!(keys.decide(Key::Enter, &first), Decision::Activate(0));
        first.thread = "other";
        first.opened = false;
        assert_eq!(keys.decide(Key::Enter, &first), Decision::Pass);
    }
    #[test]
    fn escape_dismisses_current_owned_trigger_but_not_ime_or_unrelated_input() {
        let mut keys = Keys::default();
        let mut scope = current_scope();
        scope.busy = true;
        scope.fresh_results = false;
        scope.count = 0;
        assert_eq!(keys.decide(Key::Escape, &scope), Decision::Dismiss);
        scope.ime = true;
        assert_eq!(keys.decide(Key::Escape, &scope), Decision::Pass);
        scope.ime = false;
        scope.same_trigger = false;
        assert_eq!(keys.decide(Key::Escape, &scope), Decision::Pass);
        assert_eq!(Key::named("space"), None);
    }
}
