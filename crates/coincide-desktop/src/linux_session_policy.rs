//! Explicit restriction signals only. Absence permits a bounded capability
//! probe; it does not establish complete desktop or older-XWayland coverage.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Restriction {
    Environment,
    Server,
}
pub(crate) fn explicit_restriction(
    session: Option<&str>,
    wayland_display: bool,
    wayland_socket: bool,
    xwayland_extension: Option<bool>,
) -> Option<Restriction> {
    if wayland_display
        || wayland_socket
        || session.is_some_and(|value| value.eq_ignore_ascii_case("wayland"))
    {
        Some(Restriction::Environment)
    } else if xwayland_extension == Some(true) {
        Some(Restriction::Server)
    } else {
        None
    }
}
#[cfg(test)]
mod tests {
    use super::{Restriction, explicit_restriction};
    #[test]
    fn linux_session_explicit_wayland_markers_override_x11_or_missing_server_probe() {
        for extension in [None, Some(false), Some(true)] {
            for session in [None, Some("x11"), Some("tty")] {
                assert_eq!(
                    explicit_restriction(session, true, false, extension),
                    Some(Restriction::Environment)
                );
                assert_eq!(
                    explicit_restriction(session, false, true, extension),
                    Some(Restriction::Environment)
                );
            }
            assert_eq!(
                explicit_restriction(Some("wayland"), false, false, extension),
                Some(Restriction::Environment)
            );
            assert_eq!(
                explicit_restriction(Some("Wayland"), false, false, extension),
                Some(Restriction::Environment)
            );
        }
    }
    #[test]
    fn linux_session_native_xwayland_signal_wins_when_environment_is_stripped() {
        for session in [None, Some("x11"), Some("tty")] {
            assert_eq!(
                explicit_restriction(session, false, false, Some(true)),
                Some(Restriction::Server)
            );
            // No positive desktop-support claim is encoded by None: other
            // native permissions/window/PID/privacy proofs are still required.
            assert_eq!(
                explicit_restriction(session, false, false, Some(false)),
                None
            );
            assert_eq!(explicit_restriction(session, false, false, None), None);
        }
    }
}
