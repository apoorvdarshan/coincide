import CoincideRemoteKit
import Darwin
import Foundation
import SystemConfiguration

/// Where phones can reach this Mac: its addresses on the local network and on Tailscale, and their names.
nonisolated enum RemoteAddresses {
    /// The Mac's name, as Sharing settings show it.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// `name.local`, for Bonjour name resolution on the local network.
    static var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    /// Addresses in the order a phone should try them: local network, `.local` name, Tailscale address, MagicDNS name.
    static func candidates(tailscaleName: String?) -> [RemoteHostCandidate] {
        var result: [RemoteHostCandidate] = []
        for interface in interfaceAddresses() {
            let kind: RemoteHostCandidate.Kind = isTailscale(interface.address) ? .tailscale : .lan
            if !result.contains(where: { $0.host == interface.address }) {
                result.append(RemoteHostCandidate(host: interface.address, kind: kind))
            }
        }
        if let local = localHostName { result.append(RemoteHostCandidate(host: local, kind: .localName)) }
        if let tailscaleName { result.append(RemoteHostCandidate(host: tailscaleName, kind: .tailscaleName)) }
        return result.sorted { $0.kind < $1.kind }
    }

    /// Tailscale hands out addresses from 100.64.0.0/10 (the carrier-grade NAT range).
    static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return address.lowercased().hasPrefix("fd7a:115c:a1e0:") }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Whether a connection from `address` may reach the server: loopback, private and link-local networks, and
    /// Tailscale. Anything else (a public address, should the Mac have one) is turned away before TLS.
    static func isAllowedPeer(_ address: String) -> Bool {
        let host = address.split(separator: "%").first.map(String.init) ?? address
        if host.contains(":") {
            let lower = host.lowercased()
            if lower == "::1" { return true }
            if lower.hasPrefix("::ffff:") { return isAllowedPeer(String(lower.dropFirst("::ffff:".count))) }
            // fc00::/7 (unique local, Tailscale's fd7a:115c:a1e0::/48 among them) and fe80::/10 (link-local).
            guard let first = UInt16(lower.split(separator: ":", omittingEmptySubsequences: false).first ?? "", radix: 16) else {
                return false
            }
            return first & 0xFE00 == 0xFC00 || first & 0xFFC0 == 0xFE80
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    /// IPv4 addresses of interfaces that are up, leaving out loopback and link-local (169.254/16).
    static func interfaceAddresses() -> [(interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(String, String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let string = String(cString: host)
            guard !string.hasPrefix("169.254.") else { continue }
            result.append((String(cString: entry.ifa_name), string))
        }
        return result
    }

    /// The Mac's MagicDNS name from the Tailscale command-line tool, when Tailscale is installed and connected.
    static func tailscaleDNSName() async -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["status", "--json", "--self=true", "--peers=false"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning {
                process.terminate()
                return nil
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return parseTailscaleStatus(data)
        }.value
    }

    /// `Self.DNSName` of `tailscale status --json`, without its trailing dot, when the backend is running.
    static func parseTailscaleStatus(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let state = json["BackendState"] as? String, state != "Running" { return nil }
        guard let me = json["Self"] as? [String: Any], var name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }
}
