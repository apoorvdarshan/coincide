//! Pure X11 authority bounds. Native handles/Permit are never constructed here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Identity {
    pub root: u32,
    pub window: u32,
    pub client: u32,
    pub mask: u32,
    pub pid: u32,
    pub start: u64,
    pub proc_inode: u64,
    pub exe_device: u64,
    pub exe_inode: u64,
}
impl Identity {
    pub fn matches(self, current: Self) -> bool {
        self.root != 0
            && self.window != 0
            && self.window != self.root
            && self.pid != 0
            && self.start != 0
            && self.proc_inode != 0
            && self.exe_inode != 0
            && self.client != 0
            && self == current
            && self.window & !self.mask == self.client
    }
}
pub(super) fn process_start(stat: &str, pid: u32) -> Option<u64> {
    // comm may contain spaces and parentheses; fields after its LAST ')' are fixed.
    let (head, tail) = stat.rsplit_once(')')?;
    if head.split_once('(')?.0.trim().parse::<u32>().ok()? != pid {
        return None;
    }
    let fields: Vec<_> = tail.split_whitespace().collect();
    if matches!(*fields.first()?, "Z" | "X" | "x") {
        return None;
    }
    fields
        .get(19)?
        .parse::<u64>()
        .ok()
        .filter(|value| *value != 0)
}
pub(super) fn restricted_executable(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path).to_ascii_lowercase();
    matches!(
        name.as_str(),
        "chrome"
            | "google-chrome"
            | "google-chrome-stable"
            | "chromium"
            | "chromium-browser"
            | "firefox"
            | "firefox-bin"
            | "brave"
            | "brave-browser"
            | "opera"
            | "msedge"
            | "epiphany"
            | "falkon"
            | "qutebrowser"
            | "swaylock"
            | "i3lock"
            | "gnome-shell"
            | "kscreenlocker_greet"
            | "gdm-password"
            | "gdm-session-worker"
            | "polkit-gnome-authentication-agent-1"
            | "polkit-kde-authentication-agent-1"
    )
}
pub(super) fn point(frame: [i32; 4], x: f64, y: f64) -> Option<(i16, i16)> {
    if !x.is_finite()
        || !y.is_finite()
        || x < 0.0
        || y < 0.0
        || x >= f64::from(frame[2])
        || y >= f64::from(frame[3])
    {
        return None;
    }
    Some((
        i16::try_from(i64::from(frame[0]) + x.floor() as i64).ok()?,
        i16::try_from(i64::from(frame[1]) + y.floor() as i64).ok()?,
    ))
}
/// After a possibly delivered down, matching release is always attempted once,
/// even if the reply fails or the operation loses authority. No retries.
pub(super) fn paired_input<E>(
    validate: impl FnOnce() -> Result<(), E>,
    down: impl FnOnce() -> Result<(), E>,
    up: impl FnOnce() -> Result<(), E>,
) -> Result<(), E> {
    validate()?;
    let result = down();
    let cleanup = up();
    result.and(cleanup)
}
#[cfg(test)]
mod tests {
    use super::{Identity, point, process_start, restricted_executable};
    #[test]
    fn linux_cu_process_stat_and_reused_resource_are_not_authority() {
        let stat = format!(
            "42 (synthetic ) child) S {} 876 0 0",
            vec!["0"; 18].join(" ")
        );
        assert_eq!(process_start(&stat, 42), Some(876));
        assert_eq!(process_start(&stat, 43), None);
        assert_eq!(process_start(&stat.replace(") S", ") Z"), 42), None);
        let id = Identity {
            root: 1,
            window: 0x200003,
            client: 0x200000,
            mask: 0x1fffff,
            pid: 42,
            start: 876,
            proc_inode: 8,
            exe_device: 2,
            exe_inode: 9,
        };
        assert!(id.matches(id));
        for next in [
            Identity { start: 877, ..id },
            Identity {
                client: 0x400000,
                ..id
            },
            Identity { root: 2, ..id },
            Identity {
                proc_inode: 10,
                ..id
            },
            Identity {
                exe_inode: 11,
                ..id
            },
        ] {
            assert!(!id.matches(next));
        }
        assert!(!Identity { window: 1, ..id }.matches(Identity { window: 1, ..id }));
    }
    #[test]
    fn linux_cu_window_points_and_restricted_apps_fail_closed() {
        assert_eq!(point([10, 20, 100, 80], 99.9, 79.9), Some((109, 99)));
        for (x, y) in [
            (100.0, 0.0),
            (-1.0, 0.0),
            (0.0, 80.0),
            (f64::NAN, 0.0),
            (0.0, f64::INFINITY),
        ] {
            assert_eq!(point([10, 20, 100, 80], x, y), None);
        }
        assert_eq!(point([i32::MAX, 0, 10, 10], 0.0, 0.0), None);
        for path in ["/usr/bin/firefox", "/opt/google/chrome", "/usr/bin/i3lock"] {
            assert!(restricted_executable(path));
        }
        assert!(!restricted_executable("/synthetic/owned-test-editor"));
    }
    #[test]
    fn linux_cu_owned_release_survives_uncertain_down_and_revocation_without_retry() {
        use std::cell::RefCell;
        let trace = RefCell::new(Vec::new());
        let result = super::paired_input(
            || Ok(()),
            || {
                trace.borrow_mut().push("down uncertain");
                Err("revoked")
            },
            || {
                trace.borrow_mut().push("up returned");
                Ok(())
            },
        );
        assert_eq!(result, Err("revoked"));
        assert_eq!(*trace.borrow(), ["down uncertain", "up returned"]);
        trace.borrow_mut().clear();
        let result = super::paired_input(
            || Err("stale"),
            || {
                trace.borrow_mut().push("down");
                Ok(())
            },
            || {
                trace.borrow_mut().push("up");
                Ok(())
            },
        );
        assert_eq!(result, Err("stale"));
        assert!(trace.borrow().is_empty());
        assert_eq!(
            super::paired_input(|| Ok(()), || Ok(()), || Err("release uncertain")),
            Err("release uncertain")
        );
    }
}
