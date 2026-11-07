//! Where phones can reach this computer: its addresses on the local network and
//! on Tailscale, and their names, as `RemoteAddresses.swift` lists them.
use super::protocol::{HostCandidate, HostKind};
use std::net::{IpAddr, Ipv4Addr, UdpSocket};

/// The computer's name as the system shows it ("Apoorv’s MacBook Pro").
pub fn computer_name() -> String {
    #[cfg(target_os = "macos")]
    if let Some(name) = macos::computer_name() {
        return name;
    }
    #[cfg(target_os = "linux")]
    if let Some(name) = std::fs::read_to_string("/etc/machine-info")
        .ok()
        .and_then(|info| pretty_hostname(&info))
    {
        return name;
    }
    #[cfg(windows)]
    if let Some(name) = std::env::var("COMPUTERNAME")
        .ok()
        .filter(|n| !n.trim().is_empty())
    {
        return name;
    }
    host_name().unwrap_or_else(|| "Computer".into())
}

/// `PRETTY_HOSTNAME` from `/etc/machine-info`, which `hostnamectl` sets.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn pretty_hostname(info: &str) -> Option<String> {
    info.lines()
        .find_map(|line| line.strip_prefix("PRETTY_HOSTNAME="))
        .map(|value| value.trim().trim_matches('"').to_owned())
        .filter(|value| !value.is_empty())
}

fn host_name() -> Option<String> {
    #[cfg(unix)]
    {
        let mut buffer = [0u8; 256];
        // SAFETY: the buffer outlives the call and its length is passed.
        let result = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
        if result != 0 {
            return None;
        }
        let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
        let name = String::from_utf8_lossy(&buffer[..end]).into_owned();
        (!name.is_empty()).then_some(name)
    }
    #[cfg(not(unix))]
    {
        std::env::var("COMPUTERNAME").ok()
    }
}

/// `name.local`, for multicast DNS name resolution on the local network.
pub fn local_host_name() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        macos::local_host_name().map(|name| format!("{name}.local"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let name = host_name()?;
        let first = name.split('.').next().unwrap_or(&name).to_owned();
        (!first.is_empty() && first != "localhost").then(|| format!("{first}.local"))
    }
}

/// Tailscale hands out addresses from 100.64.0.0/10 and fd7a:115c:a1e0::/48.
pub fn is_tailscale(address: &str) -> bool {
    match address.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            let [a, b, _, _] = ip.octets();
            a == 100 && (64..=127).contains(&b)
        }
        _ => address.to_lowercase().starts_with("fd7a:115c:a1e0:"),
    }
}

/// Addresses in the order a phone should try them: local network, `.local`
/// name, Tailscale address, MagicDNS name.
pub fn candidates(tailscale_name: Option<&str>) -> Vec<HostCandidate> {
    candidates_from(
        &interface_addresses(),
        local_host_name().as_deref(),
        tailscale_name,
    )
}

pub fn candidates_from(
    addresses: &[Ipv4Addr],
    local_name: Option<&str>,
    tailscale_name: Option<&str>,
) -> Vec<HostCandidate> {
    let mut result: Vec<HostCandidate> = Vec::new();
    for address in addresses {
        let host = address.to_string();
        if !result.iter().any(|c| c.host == host) {
            let kind = if is_tailscale(&host) {
                HostKind::Tailscale
            } else {
                HostKind::Lan
            };
            result.push(HostCandidate { host, kind });
        }
    }
    if let Some(local) = local_name {
        result.push(HostCandidate {
            host: local.into(),
            kind: HostKind::LocalName,
        });
    }
    if let Some(name) = tailscale_name {
        result.push(HostCandidate {
            host: name.into(),
            kind: HostKind::TailscaleName,
        });
    }
    // Stable, so addresses of one kind keep the interfaces' order.
    result.sort_by_key(|candidate| candidate.kind);
    result
}

/// IPv4 addresses of interfaces that are up, leaving out loopback and
/// link-local (169.254/16).
pub fn interface_addresses() -> Vec<Ipv4Addr> {
    #[cfg(unix)]
    let mut found = unix_interface_addresses();
    #[cfg(not(unix))]
    let mut found = Vec::new();
    // Where traffic would leave for the local network and for Tailscale, without
    // sending anything: covers systems without interface enumeration above.
    for probe in ["192.168.0.1:9", "10.0.0.1:9", "100.100.100.100:9"] {
        if let Some(IpAddr::V4(ip)) = UdpSocket::bind("0.0.0.0:0")
            .and_then(|socket| socket.connect(probe).map(|_| socket))
            .and_then(|socket| socket.local_addr())
            .ok()
            .map(|address| address.ip())
            && !found.contains(&ip)
        {
            found.push(ip);
        }
    }
    found.retain(|ip| !ip.is_loopback() && !ip.is_link_local() && !ip.is_unspecified());
    found
}

#[cfg(unix)]
fn unix_interface_addresses() -> Vec<Ipv4Addr> {
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs fills `head` with a list freed below with freeifaddrs.
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Vec::new();
    }
    let mut result = Vec::new();
    let mut cursor = head;
    while !cursor.is_null() {
        // SAFETY: cursor walks the list getifaddrs returned, which is valid until freed.
        let entry = unsafe { &*cursor };
        let flags = entry.ifa_flags as libc::c_int;
        if !entry.ifa_addr.is_null()
            && flags & libc::IFF_UP != 0
            && flags & libc::IFF_LOOPBACK == 0
            // SAFETY: ifa_addr is non-null and points at a sockaddr.
            && i32::from(unsafe { (*entry.ifa_addr).sa_family }) == libc::AF_INET
        {
            // SAFETY: an AF_INET address is a sockaddr_in.
            let address = unsafe { &*(entry.ifa_addr as *const libc::sockaddr_in) };
            let ip = Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr));
            if !ip.is_link_local() {
                result.push(ip);
            }
        }
        cursor = entry.ifa_next;
    }
    // SAFETY: head came from getifaddrs and is freed once.
    unsafe { libc::freeifaddrs(head) };
    result
}

/// The computer's MagicDNS name from the Tailscale command-line tool, when
/// Tailscale is installed and connected. Waits at most four seconds.
pub fn tailscale_dns_name() -> Option<String> {
    let executables: &[&str] = if cfg!(target_os = "macos") {
        &[
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
    } else if cfg!(windows) {
        &[r"C:\Program Files\Tailscale\tailscale.exe"]
    } else {
        &[
            "/usr/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/usr/sbin/tailscale",
        ]
    };
    let executable = executables
        .iter()
        .find(|path| std::path::Path::new(path).is_file())?;
    // Reuse owned process groups/Jobs and bounded nonblocking pipes. A
    // descendant retaining stdout cannot hold Remote's shutdown indefinitely.
    let started = std::time::Instant::now();
    let (success, output, _) = crate::agent::metadata_capture::capture(
        std::path::Path::new(executable),
        &["status", "--json", "--self=true", "--peers=false"],
        &|| started.elapsed() < std::time::Duration::from_secs(4),
    )
    .ok()?;
    if !success {
        return None;
    }
    parse_tailscale_status(&output)
}

/// `Self.DNSName` of `tailscale status --json`, without its trailing dot, when
/// the backend is running.
pub fn parse_tailscale_status(data: &[u8]) -> Option<String> {
    let json: serde_json::Value = serde_json::from_slice(data).ok()?;
    if json["BackendState"]
        .as_str()
        .is_some_and(|state| state != "Running")
    {
        return None;
    }
    let name = json["Self"]["DNSName"].as_str()?.trim_end_matches('.');
    (!name.is_empty()).then(|| name.to_owned())
}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::{CStr, c_char, c_void};
    type CFTypeRef = *const c_void;
    #[link(name = "SystemConfiguration", kind = "framework")]
    unsafe extern "C" {
        fn SCDynamicStoreCopyComputerName(store: CFTypeRef, encoding: *mut u32) -> CFTypeRef;
        fn SCDynamicStoreCopyLocalHostName(store: CFTypeRef) -> CFTypeRef;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringGetCString(
            string: CFTypeRef,
            buffer: *mut c_char,
            size: isize,
            encoding: u32,
        ) -> u8;
        fn CFRelease(value: CFTypeRef);
    }
    const UTF8: u32 = 0x0800_0100;

    fn take(string: CFTypeRef) -> Option<String> {
        if string.is_null() {
            return None;
        }
        let mut buffer = [0 as c_char; 1024];
        // SAFETY: `string` is a CFString we own; the buffer length is passed.
        let ok =
            unsafe { CFStringGetCString(string, buffer.as_mut_ptr(), buffer.len() as isize, UTF8) };
        // SAFETY: released once; the Copy functions return +1 references.
        unsafe { CFRelease(string) };
        // SAFETY: CFStringGetCString NUL-terminates on success.
        (ok != 0).then(|| {
            unsafe { CStr::from_ptr(buffer.as_ptr()) }
                .to_string_lossy()
                .into_owned()
        })
    }
    pub fn computer_name() -> Option<String> {
        // SAFETY: a null store asks for a temporary session.
        take(unsafe { SCDynamicStoreCopyComputerName(std::ptr::null(), std::ptr::null_mut()) })
            .filter(|n| !n.is_empty())
    }
    pub fn local_host_name() -> Option<String> {
        // SAFETY: as above.
        take(unsafe { SCDynamicStoreCopyLocalHostName(std::ptr::null()) }).filter(|n| !n.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_are_ordered_lan_then_names_then_tailscale() {
        let list = candidates_from(
            &[
                "100.101.1.2".parse().unwrap(),
                "192.168.1.20".parse().unwrap(),
                "192.168.1.20".parse().unwrap(),
                "10.0.0.5".parse().unwrap(),
            ],
            Some("Desk.local"),
            Some("desk.tailnet.ts.net"),
        );
        let kinds = list
            .iter()
            .map(|c| (c.host.as_str(), c.kind))
            .collect::<Vec<_>>();
        assert_eq!(
            kinds,
            vec![
                ("192.168.1.20", HostKind::Lan),
                ("10.0.0.5", HostKind::Lan),
                ("Desk.local", HostKind::LocalName),
                ("100.101.1.2", HostKind::Tailscale),
                ("desk.tailnet.ts.net", HostKind::TailscaleName),
            ]
        );
    }

    #[test]
    fn tailscale_ranges_and_status_parsing() {
        assert!(is_tailscale("100.64.0.1"));
        assert!(is_tailscale("100.127.255.255"));
        assert!(!is_tailscale("100.128.0.1"));
        assert!(!is_tailscale("192.168.1.1"));
        assert!(is_tailscale("FD7A:115C:A1E0::1"));
        assert_eq!(
            parse_tailscale_status(
                br#"{"BackendState":"Running","Self":{"DNSName":"desk.tail1.ts.net."}}"#
            ),
            Some("desk.tail1.ts.net".into())
        );
        assert_eq!(
            parse_tailscale_status(
                br#"{"BackendState":"Stopped","Self":{"DNSName":"desk.ts.net."}}"#
            ),
            None
        );
        assert_eq!(parse_tailscale_status(br#"{"Self":{"DNSName":""}}"#), None);
        assert_eq!(parse_tailscale_status(b"nope"), None);
        assert_eq!(
            pretty_hostname("A=1\nPRETTY_HOSTNAME=\"Desk Box\"\n"),
            Some("Desk Box".into())
        );
    }

    #[test]
    fn interface_addresses_never_include_loopback_or_link_local() {
        for address in interface_addresses() {
            assert!(
                !address.is_loopback() && !address.is_link_local(),
                "{address}"
            );
        }
        assert!(!computer_name().is_empty());
    }
}
