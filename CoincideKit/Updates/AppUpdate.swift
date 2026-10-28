import CryptoKit
import Foundation
import Security

public enum AppUpdateError: Error, LocalizedError {
    case metadata, archive, verification, incompatible, signing, network, installation, running
    public var errorDescription: String? {
        switch self {
        case .metadata: String(localized: "The release does not contain a supported update with a SHA-256 checksum.")
        case .archive: String(localized: "The update archive is damaged or contains unsafe paths.")
        case .verification: String(localized: "The update failed integrity or signature verification.")
        case .incompatible: String(localized: "The update is incompatible with this app or Mac.")
        case .signing: String(localized: "Updates can only be installed by a verified Developer ID build.")
        case .network: String(localized: "The update request failed. Try again later.")
        case .installation: String(localized: "The update could not be installed. The previous app has been kept.")
        case .running: String(localized: "Coincide is running. The update has not been installed.")
        }
    }
}

public struct UpdateVersion: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }
    public var description: String { components.map(String.init).joined(separator: ".") }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

public struct AppUpdateRelease: Codable, Hashable, Sendable {
    public let version: String
    public let url: URL
    public let sha256: String
    public let size: Int64
    public static let repository = "https://github.com/apoorvdarshan/coincide"
    public static let feed = URL(string: "https://api.github.com/repos/apoorvdarshan/coincide/releases/latest")!
    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    public static func parse(_ data: Data, newerThan current: String, architecture: String = architecture) throws -> Self? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String?; let size: Int64 }
        struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset] }
        guard data.count <= 2 * 1024 * 1024, let known = UpdateVersion(current),
              let release = try? JSONDecoder().decode(Release.self, from: data), !release.draft, !release.prerelease,
              let version = UpdateVersion(release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name) else { throw AppUpdateError.metadata }
        guard version > known else { return nil }
        let names = ["Coincide-macos-\(architecture).zip", "Coincide-macos-universal.zip"]
        guard let asset = names.lazy.compactMap({ name in release.assets.first { $0.name == name } }).first,
              asset.size > 0, asset.size <= 512 * 1024 * 1024,
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.dropFirst(7).count == 64, digest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.user == nil, asset.browser_download_url.password == nil,
              asset.browser_download_url.port == nil, asset.browser_download_url.query == nil, asset.browser_download_url.fragment == nil,
              asset.browser_download_url.path == "/apoorvdarshan/coincide/releases/download/\(release.tag_name)/\(asset.name)" else { throw AppUpdateError.metadata }
        return Self(version: version.description, url: asset.browser_download_url, sha256: String(digest.dropFirst(7)).lowercased(), size: asset.size)
    }
}

public enum AppUpdateSecurity {
    public static let bundleID = "com.apoorvdarshan.coincide"
    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Derive trust from this installed build, never from release metadata or a mutable receipt.
    public static func signingTeam(at url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw AppUpdateError.signing }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw AppUpdateError.signing }
        try validateSignature(at: url, team: team, identifier: nil)
        return team
    }

    public static func validateSignature(at url: URL, team: String, identifier: String?) throws {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw AppUpdateError.verification }
        var code: SecStaticCode?, requirement: SecRequirement?
        let identity = identifier.map { " and identifier \"\($0)\"" } ?? ""
        let rule = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\"" + identity
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else { throw AppUpdateError.verification }
    }

    public static func verifyBundle(_ url: URL, release: AppUpdateRelease, team: String, currentVersion: String) throws {
        guard let expected = UpdateVersion(release.version), let current = UpdateVersion(currentVersion), expected > current,
              let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              let executable = bundle.executableURL,
              executable.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/Contents/MacOS/") else { throw AppUpdateError.incompatible }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            guard !parts.isEmpty, parts.count <= 3 else { throw AppUpdateError.incompatible }
            let version = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(version) else { throw AppUpdateError.incompatible }
        }
        try validateSignature(at: url, team: team, identifier: bundleID)
        try command("/usr/bin/lipo", ["-verify_arch", AppUpdateRelease.architecture, executable.path])
        // Gatekeeper also assesses Developer ID trust and notarization; a valid ad-hoc signature never qualifies.
        try command("/usr/sbin/spctl", ["--assess", "--type", "execute", url.path])
    }

    private static func command(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw AppUpdateError.verification }
    }
}

/// A fresh session for each bounded HTTPS request; redirects stay on GitHub's download infrastructure.
private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    init(maximum: Int64) { self.maximum = maximum }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url.map { $0.scheme == "https" && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "api.github.com"].contains($0.host ?? "") && $0.user == nil && $0.password == nil && $0.port == nil } ?? false
        completionHandler(allowed ? request : nil)
    }
}

public enum AppUpdateDownload {
    public static func fetch(_ url: URL, maximum: Int64) async throws -> (URL, Int) {
        guard url.scheme == "https", ["github.com", "api.github.com"].contains(url.host ?? ""), url.user == nil, url.password == nil else { throw AppUpdateError.network }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["Accept": "application/vnd.github+json", "User-Agent": "Coincide-Updater"]
        let session = URLSession(configuration: configuration, delegate: UpdateDownloadDelegate(maximum: maximum), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(from: url)
        guard let response = response as? HTTPURLResponse,
              let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize, size <= maximum else { try? FileManager.default.removeItem(at: file); throw AppUpdateError.network }
        return (file, response.statusCode)
    }
}
