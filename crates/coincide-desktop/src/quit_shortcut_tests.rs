use super::{Action, DOUBLE, Decision, HOLD};
use std::time::Duration;
#[::core::prelude::v1::test]
fn swift_hold_double_press_timeout_and_repeat_boundaries() {
    let mut guard = Decision::default();
    assert_eq!(guard.down(Duration::ZERO, false), Action::ShowHint);
    assert_eq!(guard.tick(HOLD - Duration::from_nanos(1)), Action::None);
    assert!(guard.progress(HOLD / 2) > 0.49 && guard.progress(HOLD / 2) < 0.51);
    assert_eq!(guard.tick(HOLD), Action::Quit);
    assert_eq!(
        guard.down(HOLD + Duration::from_secs(2), true),
        Action::None
    );
    assert!(!guard.shows_hint());
    assert_eq!(guard.up(HOLD + Duration::from_secs(2)), Action::None);
    assert_eq!(guard.down(Duration::from_secs(4), false), Action::ShowHint);
    assert_eq!(guard.up(Duration::from_millis(4100)), Action::None);
    assert_eq!(
        guard.down(Duration::from_secs(4) + DOUBLE, false),
        Action::Quit
    );
    // A refused quit and missed release never allow repeated keys to re-quit;
    // an actual new, nonrepeated press starts a new hold, matching Swift.
    assert_eq!(guard.down(Duration::from_secs(6), true), Action::None);
    assert_eq!(guard.down(Duration::from_secs(6), false), Action::ShowHint);
    assert_eq!(guard.up(Duration::from_millis(6100)), Action::None);
    assert_eq!(
        guard.tick(Duration::from_secs(6) + DOUBLE + Duration::from_nanos(1)),
        Action::HideHint
    );
    assert!(!guard.shows_hint());
}
#[::core::prelude::v1::test]
fn swift_release_after_hold_quits_and_cancellation_discards_previous_press() {
    let mut guard = Decision::default();
    guard.down(Duration::ZERO, false);
    assert_eq!(guard.up(HOLD), Action::Quit);
    guard.down(Duration::from_secs(3), false);
    assert_eq!(guard.cancel(), Action::HideHint);
    assert_eq!(guard.tick(Duration::from_secs(9)), Action::None);
    assert_eq!(guard.down(Duration::from_secs(9), false), Action::ShowHint);
    assert_eq!(guard.down(Duration::from_millis(9100), true), Action::None);
}

#[::core::prelude::v1::test]
fn only_the_exact_platform_primary_q_matches() {
    use gpui_kit::{Keystroke, Modifiers};
    let mut key = Keystroke {
        key: "q".into(),
        key_char: None,
        modifiers: Modifiers::default(),
    };
    if cfg!(target_os = "macos") {
        key.modifiers.platform = true;
    } else {
        key.modifiers.control = true;
    }
    assert!(super::exact_quit(&key));
    for extra in ["shift", "alt", "function", "other-primary"] {
        let mut changed = key.clone();
        match extra {
            "shift" => changed.modifiers.shift = true,
            "alt" => changed.modifiers.alt = true,
            "function" => changed.modifiers.function = true,
            _ => {
                if cfg!(target_os = "macos") {
                    changed.modifiers.control = true;
                } else {
                    changed.modifiers.platform = true;
                }
            }
        }
        assert!(!super::exact_quit(&changed), "{extra}");
    }
    key.key = "w".into();
    assert!(!super::exact_quit(&key));
}

#[path = "quit_shortcut_ui_tests.rs"]
mod native;
