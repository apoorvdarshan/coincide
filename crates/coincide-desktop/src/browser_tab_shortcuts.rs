//! Fixed browser-local tab keys. No agent/page command dispatches these keys.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Command {
    New,
    Close,
    Next,
    Previous,
}

pub(crate) fn recognize(
    key: &str,
    primary: bool,
    other_primary: bool,
    alt: bool,
    shift: bool,
) -> Option<Command> {
    if !primary || other_primary || alt {
        return None;
    }
    match (key.to_ascii_lowercase().as_str(), shift) {
        ("t", false) => Some(Command::New),
        ("w", false) => Some(Command::Close),
        ("]" | "}", true) => Some(Command::Next),
        ("[" | "{", true) => Some(Command::Previous),
        _ => None,
    }
}
pub(crate) fn dispatch_focus(
    native: bool,
    current_native_focus: bool,
    current_chrome_focus: bool,
) -> bool {
    if native {
        current_native_focus
    } else {
        current_chrome_focus
    }
}
pub(crate) fn eligible(active_window: bool, shown: bool, focused: bool, blocked: bool) -> bool {
    active_window && shown && focused && !blocked
}
pub(crate) fn adjacent<'a>(tabs: &'a [String], active: &str, forward: bool) -> Option<&'a str> {
    if tabs.len() < 2 {
        return None;
    }
    let index = tabs.iter().position(|tab| tab == active)?;
    let next = if forward {
        (index + 1) % tabs.len()
    } else {
        (index + tabs.len() - 1) % tabs.len()
    };
    Some(&tabs[next])
}
#[derive(Clone)]
pub(crate) struct Source {
    pub thread: String,
    pub tab: String,
    pub epoch: u64,
    pub url: Option<String>,
}
impl Source {
    pub fn matches(&self, thread: &str, tab: &str, epoch: u64, url: Option<&str>) -> bool {
        self.url.as_ref().is_some_and(|url| !url.is_empty())
            && self.thread == thread
            && self.tab == tab
            && self.epoch == epoch
            && self.url.as_deref() == url
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_the_four_fixed_primary_chords_are_claimed() {
        for (key, shift, expected) in [
            ("t", false, Command::New),
            ("W", false, Command::Close),
            ("]", true, Command::Next),
            ("}", true, Command::Next),
            ("[", true, Command::Previous),
            ("{", true, Command::Previous),
        ] {
            assert_eq!(recognize(key, true, false, false, shift), Some(expected));
            assert_eq!(recognize(key, false, false, false, shift), None);
            assert_eq!(recognize(key, true, true, false, shift), None);
            assert_eq!(recognize(key, true, false, true, shift), None);
        }
        for (key, shift) in [
            ("t", true),
            ("w", true),
            ("]", false),
            ("[", false),
            ("n", false),
            ("k", false),
            ("f", false),
        ] {
            assert_eq!(recognize(key, true, false, false, shift), None);
        }
    }
    #[test]
    fn inactive_hidden_unfocused_and_other_routes_keep_their_keys() {
        assert!(eligible(true, true, true, false));
        for args in [
            (false, true, true, false),
            (true, false, true, false),
            (true, true, false, false),
            (true, true, true, true),
        ] {
            assert!(!eligible(args.0, args.1, args.2, args.3));
        }
    }
    #[test]
    fn cycling_wraps_only_with_a_current_source_and_multiple_tabs() {
        let tabs = vec!["a".into(), "b".into(), "c".into()];
        assert_eq!(adjacent(&tabs, "c", true), Some("a"));
        assert_eq!(adjacent(&tabs, "a", false), Some("c"));
        assert_eq!(adjacent(&tabs, "b", true), Some("c"));
        assert_eq!(adjacent(&tabs, "missing", true), None);
        assert_eq!(adjacent(&["a".into()], "a", true), None);
    }
    #[test]
    fn native_keys_cannot_cross_threads_tabs_documents_or_urls() {
        let source = Source {
            thread: "t".into(),
            tab: "a".into(),
            epoch: 4,
            url: Some("https://owned.invalid/".into()),
        };
        assert!(source.matches("t", "a", 4, Some("https://owned.invalid/")));
        assert!(
            !Source {
                url: None,
                ..source.clone()
            }
            .matches("t", "a", 4, None)
        );
        for (thread, tab, epoch, url) in [
            ("other", "a", 4, Some("https://owned.invalid/")),
            ("t", "other", 4, Some("https://owned.invalid/")),
            ("t", "a", 5, Some("https://owned.invalid/")),
            ("t", "a", 4, None),
            ("t", "a", 4, Some("https://other.invalid/")),
        ] {
            assert!(!source.matches(thread, tab, epoch, url));
        }
    }
}

#[cfg(test)]
mod queued_focus_tests {
    use super::*;
    #[test]
    fn queued_native_key_rechecks_focus_after_composer_settings_or_sibling_takes_it() {
        let queued = Source {
            thread: "t".into(),
            tab: "a".into(),
            epoch: 4,
            url: Some("https://owned.invalid/".into()),
        };
        assert!(queued.matches("t", "a", 4, Some("https://owned.invalid/")));
        assert!(dispatch_focus(true, true, false));
        // Document binding stays unchanged; focus is an independent admission.
        for (chrome_focused, blocked) in [(false, false), (false, true), (true, false)] {
            assert!(!eligible(
                true,
                true,
                dispatch_focus(true, false, chrome_focused),
                blocked
            ));
        }
        assert!(dispatch_focus(false, false, true));
    }
}
