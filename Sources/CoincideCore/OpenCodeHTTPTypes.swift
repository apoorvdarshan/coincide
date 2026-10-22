import Foundation

/// The HTTP generations have different routes, envelopes and mutation semantics.
public enum OpenCodeGeneration: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case v1, v2

    public var minimumVersion: OpenCodeVersion {
        switch self {
        case .v1: OpenCodeVersion(major: 1, minor: 14, patch: 19)
        case .v2: OpenCodeVersion(major: 2, minor: 0, patch: 18)
        }
    }
}

public struct OpenCodeVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?
    public let build: String?

    init(major: Int, minor: Int, patch: Int, prerelease: String? = nil, build: String? = nil) {
        self.major = major; self.minor = minor; self.patch = patch
        self.prerelease = prerelease; self.build = build
    }

    public init(_ text: String) throws {
        guard text.utf8.count <= 256, !text.isEmpty else { throw OpenCodeProtocolError.invalidVersion }
        var source = text
        if source.hasPrefix("v") { source.removeFirst() }
        let buildParts = source.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { throw OpenCodeProtocolError.invalidVersion }
        let releaseParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { throw OpenCodeProtocolError.invalidVersion }
        func number(_ value: Substring) throws -> Int {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  value.count == 1 || value.first != "0", let result = Int(value) else {
                throw OpenCodeProtocolError.invalidVersion
            }
            return result
        }
        func suffix(_ value: Substring, prerelease: Bool) throws -> String {
            let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ item in
                !item.isEmpty && item.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
                && (!prerelease || !item.utf8.allSatisfy({ (48...57).contains($0) }) || item.count == 1 || item.first != "0")
            }) else { throw OpenCodeProtocolError.invalidVersion }
            return String(value)
        }
        major = try number(numbers[0]); minor = try number(numbers[1]); patch = try number(numbers[2])
        prerelease = releaseParts.count == 2 ? try suffix(releaseParts[1], prerelease: true) : nil
        build = buildParts.count == 2 ? try suffix(buildParts[1], prerelease: false) : nil
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-" + $0 } ?? "") + (build.map { "+" + $0 } ?? "")
    }

    public var supportedGeneration: OpenCodeGeneration? {
        let generation: OpenCodeGeneration
        switch major { case 1: generation = .v1; case 2: generation = .v2; default: return nil }
        return self < generation.minimumVersion ? nil : generation
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        guard let left = lhs.prerelease else { return false }
        guard let right = rhs.prerelease else { return true }
        let a = left.split(separator: "."), b = right.split(separator: ".")
        for (x, y) in zip(a, b) where x != y {
            let xNumeric = x.utf8.allSatisfy { (48...57).contains($0) }
            let yNumeric = y.utf8.allSatisfy { (48...57).contains($0) }
            if xNumeric && yNumeric { return x.count == y.count ? x.lexicographicallyPrecedes(y) : x.count < y.count }
            if xNumeric != yNumeric { return xNumeric }
            return x.lexicographicallyPrecedes(y)
        }
        return a.count < b.count
    }

    // Build metadata does not change semantic version precedence.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }
}

/// Runtime-only Basic authentication. Neither credentials nor an owned server's
/// ephemeral endpoint belong in a conversation, journal, command line or URL.
public final class OpenCodeHTTPCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let authorizationHeader: String

    public init(username: String = "opencode", password: String) throws {
        guard !username.isEmpty, !username.contains(":"), username.utf8.count <= 256,
              !password.isEmpty, password.utf8.count <= 4_096,
              !(username + password).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw OpenCodeProtocolError.invalidCredential
        }
        authorizationHeader = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    public var description: String { "OpenCodeHTTPCredential(<redacted>)" }
    public var debugDescription: String { description }
}

/// Fixed messages intentionally exclude server text, URLs, headers and payloads.
public enum OpenCodeProtocolError: Error, Sendable, Equatable, LocalizedError {
    case invalidVersion, unsupportedVersion, wrongGeneration, invalidCredential
    case unauthorized, unavailable, invalidIdentity, invalidCatalog, wrongDirectory
    case invalidEvent, eventLimitExceeded, closed

    public var errorDescription: String? {
        switch self {
        case .invalidVersion: "OpenCode returned an invalid version."
        case .unsupportedVersion: "This OpenCode HTTP version is not supported."
        case .wrongGeneration: "The OpenCode server does not match the selected HTTP generation."
        case .invalidCredential: "The OpenCode HTTP credential is invalid."
        case .unauthorized: "The OpenCode server rejected authentication."
        case .unavailable: "The OpenCode server is not ready."
        case .invalidIdentity: "The OpenCode server identity could not be verified."
        case .invalidCatalog: "The OpenCode catalog could not be read safely."
        case .wrongDirectory: "The OpenCode response belongs to a different workspace."
        case .invalidEvent: "The OpenCode event stream is invalid."
        case .eventLimitExceeded: "The OpenCode event stream exceeded its buffer limit."
        case .closed: "The OpenCode connection is closed."
        }
    }
}
