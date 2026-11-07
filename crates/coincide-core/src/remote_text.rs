//! The wording Settings › General › Remote shows, as `RemoteSettingsView.swift`
//! words it, kept here so it's tested without a window.
use super::protocol::{Device, HostKind};
use super::server::Status;

/// The status dot's color: green running, yellow starting, orange failed, the
/// border color when off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dot {
    Green,
    Yellow,
    Orange,
    Off,
}

pub fn status_dot(status: &Status) -> Dot {
    match status {
        Status::Running { .. } => Dot::Green,
        Status::Starting => Dot::Yellow,
        Status::Failed(_) => Dot::Orange,
        Status::Off => Dot::Off,
    }
}

pub fn status_title(status: &Status) -> &'static str {
    match status {
        Status::Running { .. } => "Listening for Coincide Remote",
        Status::Starting => "Starting…",
        Status::Failed(_) => "Coincide Remote can’t start",
        Status::Off => "Off",
    }
}

pub fn status_detail(status: &Status, connected: usize) -> String {
    match status {
        Status::Running { port } if connected == 0 => {
            format!("On port {port}. Scan the pairing code with Coincide Remote to add a device.")
        }
        Status::Running { port } => format!("On port {port}. {connected} connected now."),
        Status::Starting => "Preparing the encrypted connection.".into(),
        Status::Failed(message) => message.clone(),
        Status::Off => String::new(),
    }
}

pub fn kind_label(kind: HostKind) -> &'static str {
    match kind {
        HostKind::Lan => "Local network",
        HostKind::LocalName => "Bonjour name",
        HostKind::Tailscale => "Tailscale",
        HostKind::TailscaleName => "MagicDNS",
        HostKind::Manual => "",
    }
}

/// "Connected now", "Last connected 5 minutes ago" or "Paired Jan 2, 2026 at 3:04 PM".
pub fn device_detail(device: &Device, connected: bool, now_ms: f64) -> String {
    if connected {
        return "Connected now".into();
    }
    match device.last_seen_at {
        Some(seen) => format!("Last connected {}", relative(seen, now_ms)),
        None => format!("Paired {}", date_time(device.paired_at)),
    }
}

/// A past moment the way `.relative(presentation: .named)` reads it.
pub fn relative(then_ms: f64, now_ms: f64) -> String {
    let seconds = ((now_ms - then_ms) / 1000.).max(0.) as u64;
    let plural =
        |count: u64, unit: &str| format!("{count} {unit}{} ago", if count == 1 { "" } else { "s" });
    match seconds {
        0..60 => "now".into(),
        60..3_600 => plural(seconds / 60, "minute"),
        3_600..86_400 => plural(seconds / 3_600, "hour"),
        86_400..172_800 => "yesterday".into(),
        172_800..604_800 => plural(seconds / 86_400, "day"),
        604_800..1_209_600 => "last week".into(),
        _ => plural(seconds / 604_800, "week"),
    }
}

fn date_time(ms: f64) -> String {
    chrono::DateTime::from_timestamp_millis(ms as i64)
        .map(|date| {
            date.with_timezone(&chrono::Local)
                .format("%b %-d, %Y at %-I:%M %p")
                .to_string()
        })
        .unwrap_or_default()
}

/// "Works once, for 4:59 more." until the code expires.
pub fn countdown(expires_at_seconds: f64, now_ms: f64) -> (String, bool) {
    let remaining = (expires_at_seconds - now_ms / 1000.).max(0.) as u64;
    if remaining > 0 {
        (
            format!(
                "Works once, for {}:{:02} more.",
                remaining / 60,
                remaining % 60
            ),
            true,
        )
    } else {
        ("This code has expired.".into(), false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statuses_read_as_on_the_mac() {
        let running = Status::Running { port: 47391 };
        assert_eq!(status_title(&running), "Listening for Coincide Remote");
        assert_eq!(
            status_detail(&running, 0),
            "On port 47391. Scan the pairing code with Coincide Remote to add a device."
        );
        assert_eq!(
            status_detail(&running, 2),
            "On port 47391. 2 connected now."
        );
        assert_eq!(
            status_detail(&Status::Starting, 0),
            "Preparing the encrypted connection."
        );
        assert_eq!(
            status_title(&Status::Failed("x".into())),
            "Coincide Remote can’t start"
        );
        assert_eq!(
            status_detail(&Status::Failed("Port busy".into()), 0),
            "Port busy"
        );
        assert_eq!(status_dot(&Status::Off), Dot::Off);
        assert_eq!(kind_label(HostKind::TailscaleName), "MagicDNS");
    }

    #[test]
    fn devices_and_codes_count_down() {
        let now = 1_000_000_000.;
        assert_eq!(relative(now - 10_000., now), "now");
        assert_eq!(relative(now - 60_000., now), "1 minute ago");
        assert_eq!(relative(now - 7_200_000., now), "2 hours ago");
        assert_eq!(relative(now - 90_000_000., now), "yesterday");
        assert_eq!(relative(now - 3. * 86_400_000., now), "3 days ago");
        let device = Device {
            id: "D".into(),
            name: "Phone".into(),
            paired_at: now,
            last_seen_at: Some(now - 120_000.),
        };
        assert_eq!(device_detail(&device, true, now), "Connected now");
        assert_eq!(
            device_detail(&device, false, now),
            "Last connected 2 minutes ago"
        );
        let never = Device {
            last_seen_at: None,
            ..device
        };
        assert!(device_detail(&never, false, now).starts_with("Paired "));
        assert_eq!(
            countdown(now / 1000. + 299.5, now),
            ("Works once, for 4:59 more.".into(), true)
        );
        assert_eq!(
            countdown(now / 1000. + 61., now).0,
            "Works once, for 1:01 more."
        );
        assert_eq!(
            countdown(now / 1000. - 1., now),
            ("This code has expired.".into(), false)
        );
    }
}
