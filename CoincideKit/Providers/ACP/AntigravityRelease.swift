import Darwin
import Foundation

/// One downloadable Antigravity runtime: Google's zip with the ACP server and its harness.
///
/// Everything Coincide checks is pinned here, as T3 Code pins it: the archive's address, size and
/// SHA-256, and for each file inside its name and size. Coincide also pins each file's SHA-256 and
/// the code-signing identity Google signs it with, so a release folder that is already on disk is
/// checked as strictly as a fresh download before it runs.
public struct AntigravityReleaseAsset: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        public var name: String
        public var bytes: Int64
        /// SHA-256 of the extracted file, as lowercase hex.
        public var sha256: String
        /// The identifier Google's Developer ID signature carries.
        public var signingIdentifier: String

        public nonisolated init(name: String, bytes: Int64, sha256: String, signingIdentifier: String) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
            self.signingIdentifier = signingIdentifier
        }
    }

    public var version: String
    public var url: URL
    /// SHA-256 of the archive, as lowercase hex. It also names the release's folder.
    public var sha256: String
    public var archiveBytes: Int64
    public var executable: File
    public var harness: File

    public nonisolated init(version: String, url: URL, sha256: String, archiveBytes: Int64, executable: File, harness: File) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.archiveBytes = archiveBytes
        self.executable = executable
        self.harness = harness
    }

    public nonisolated var files: [File] { [executable, harness] }

    /// Free space an installation needs: the archive and both files, plus a margin.
    public nonisolated var requiredFreeSpace: Int64 { archiveBytes + executable.bytes + harness.bytes + 256 * 1_024 * 1_024 }
}

/// The Antigravity runtime release Coincide installs (T3 Code's `antigravityRelease.ts`). A newer
/// release arrives with a Coincide update, never from an unpinned download.
public enum AntigravityRelease {
    public nonisolated static let version = "1.3.0"
    /// Google LLC's Developer ID team, which signs both files.
    public nonisolated static let signingTeamID = "EQHXZ8M8AV"
    public nonisolated static let executableName = "agy_acp_server.par"
    public nonisolated static let harnessName = "localharness_external"

    private nonisolated static let assets: [String: AntigravityReleaseAsset] = [
        "darwin-arm64": AntigravityReleaseAsset(
            version: version,
            url: URL(string: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-arm64.zip")!,
            sha256: "7cd97045f7b4fe81175a107cdf16f9c51484e3c78a5162cae415338bb6aa5b88",
            archiveBytes: 111_456_962,
            executable: .init(
                name: executableName, bytes: 278_535_456,
                sha256: "cb1f0725183ed922079ed6cd1d2422b4d8be44c5fb60be3e9a43d8d04f99a18e", signingIdentifier: "agy_acp_server"),
            harness: .init(
                name: harnessName, bytes: 118_611_392,
                sha256: "b04b00662c1821b953a409d43626b86d1229130eeb2078b4e1304c06199aa481",
                signingIdentifier: "localharness_external")),
        "darwin-x64": AntigravityReleaseAsset(
            version: version,
            url: URL(string: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-x86_64.zip")!,
            sha256: "bb23956b89984bf5d354af2c3725e6c57f0cc1b7228e77a0e91c9c2bc1d47646",
            archiveBytes: 117_245_544,
            executable: .init(
                name: executableName, bytes: 282_840_688,
                sha256: "f31bd5797eeb225a5efa12e24573f1f4eb157ec00698dd6a2cda6f0d924705cf", signingIdentifier: "agy_acp_server"),
            harness: .init(
                name: harnessName, bytes: 124_175_392,
                sha256: "d724f49b2c9e440c5d37925b1da203fc204c17dd9c662df45094c641f9806bc6",
                signingIdentifier: "localharness_external")),
    ]

    /// Node's name for an architecture, as T3 Code keys its releases: "arm64" or "x64". Nil for
    /// architectures Google publishes no macOS runtime for.
    public nonisolated static func normalizedArchitecture(_ architecture: String) -> String? {
        switch architecture.lowercased() {
        case "arm64", "aarch64", "arm64e": "arm64"
        case "x86_64", "x64", "amd64": "x64"
        default: nil
        }
    }

    /// "darwin-arm64", the folder name the runtime is unpacked under (T3 Code's `platform-arch`).
    public nonisolated static func platformKey(architecture: String) -> String {
        "darwin-" + (normalizedArchitecture(architecture) ?? architecture.lowercased())
    }

    /// The release for a Mac with `architecture`, or nil when Google publishes none for it.
    public nonisolated static func asset(architecture: String = hostArchitecture) -> AntigravityReleaseAsset? {
        guard normalizedArchitecture(architecture) != nil else { return nil }
        return assets[platformKey(architecture: architecture)]
    }

    /// The Mac's own architecture, even when Coincide runs translated by Rosetta (the native runtime
    /// then runs faster and unpacks the same way).
    public nonisolated static var hostArchitecture: String {
        #if arch(arm64)
            return "arm64"
        #else
            var translated: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 { return "arm64" }
            return "x86_64"
        #endif
    }

    /// The code-signing requirement a pinned file must meet: Google's Developer ID certificate,
    /// issued by Apple, for the file's own identifier.
    public nonisolated static func signingRequirement(for file: AntigravityReleaseAsset.File) -> String {
        "identifier \"\(file.signingIdentifier)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(signingTeamID)\""
    }
}
