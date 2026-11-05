//! Companion policy only: no sockets, discovery, credentials or CloudKit writes.
use std::net::IpAddr;
use uuid::Uuid;

/// Network eligibility is NOT authentication. TLS pinning and explicit pairing
/// must still succeed before accepting presence or commands from an eligible peer.
pub fn allowed_peer(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(ip) => {
            let [a, b, _, _] = ip.octets();
            ip.is_loopback()
                || ip.is_private()
                || ip.is_link_local()
                || (a == 100 && (64..=127).contains(&b))
        }
        IpAddr::V6(ip) => {
            if let Some(v4) = ip.to_ipv4_mapped() {
                return allowed_peer(IpAddr::V4(v4));
            }
            let first = ip.segments()[0];
            ip.is_loopback() || first & 0xfe00 == 0xfc00 || first & 0xffc0 == 0xfe80
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Presence {
    pub device_id: String,
    pub active: bool,
    pub open_thread: Option<Uuid>,
    /// Trusted receiver clock, never an unvalidated remote timestamp.
    pub received_at: u64,
    pub idle_seconds: u64,
}
impl Presence {
    pub fn foreground(&self, now: u64, lifetime: u64) -> bool {
        self.active
            && now
                .checked_sub(self.received_at)
                .is_some_and(|age| age <= lifetime)
    }
    pub fn last_interaction(&self) -> u64 {
        self.received_at.saturating_sub(self.idle_seconds)
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushTarget {
    pub device_id: String,
    pub zone: String,
    pub last_active_at: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn peer_boundaries_and_mapped_ipv6() {
        for address in [
            "127.0.0.1",
            "10.0.0.1",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.1.1",
            "100.64.0.1",
            "100.127.255.255",
            "::1",
            "::ffff:192.168.1.1",
            "fd7a:115c:a1e0::1",
            "fe80::1",
        ] {
            assert!(allowed_peer(address.parse().unwrap()), "{address}");
        }
        for address in [
            "0.0.0.0",
            "8.8.8.8",
            "100.63.255.255",
            "100.128.0.0",
            "172.32.0.1",
            "::",
            "::ffff:8.8.8.8",
            "2001:4860::1",
            "ff02::1",
        ] {
            assert!(!allowed_peer(address.parse().unwrap()), "{address}");
        }
    }
    #[test]
    fn presence_expires_and_future_clock_is_not_trusted() {
        let p = Presence {
            device_id: "fixture".into(),
            active: true,
            open_thread: None,
            received_at: 100,
            idle_seconds: 300,
        };
        assert!(p.foreground(130, 30));
        assert!(!p.foreground(131, 30));
        assert!(!p.foreground(99, 30));
        assert_eq!(p.last_interaction(), 0);
    }
}
