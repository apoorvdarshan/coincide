import Foundation

/// A validated script preview target. Only http(s) URLs without embedded credentials are opened;
/// the endpoint is used solely to wait for a local development server before opening it.
public struct PreviewTarget: Sendable, Equatable {
    public let url: URL
    public let host: String
    public let port: UInt16
    /// Loopback names are probed before opening; other hosts open immediately.
    public var isLoopback: Bool { ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host.lowercased()) || host.lowercased().hasSuffix(".localhost") }
}

public enum PreviewURLPolicy {
    public static let maximumLength = 2_048
    public static func validate(_ value: String) throws -> PreviewTarget {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maximumLength, !text.contains("\0"),
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let rawHost = components.host, !rawHost.isEmpty, let url = components.url else { throw ProjectActionError(.invalidPreviewURL) }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let explicit: UInt16? = components.port.flatMap { UInt16(exactly: $0) }
        guard components.port == nil || explicit != nil else { throw ProjectActionError(.invalidPreviewURL) }
        let port = explicit ?? (scheme == "https" ? 443 : 80)
        guard port > 0 else { throw ProjectActionError(.invalidPreviewURL) }
        return .init(url: url, host: host, port: port)
    }
}
