import Foundation

public struct CodexManagedRelease: Codable, Sendable, Equatable, Hashable {
    public let version: String
    public let target: String
    public let url: URL
    public let archiveBytes: Int64
    public let sha256: String
    public init(version: String, target: String, url: URL, archiveBytes: Int64, sha256: String) throws {
        self.version = version; self.target = target; self.url = url; self.archiveBytes = archiveBytes; self.sha256 = sha256
        try validate()
    }
    public func validate() throws {
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?$"#, options: .regularExpression) != nil,
              version.utf8.count <= 128, Self.targets.contains(target), archiveBytes > 0, archiveBytes <= 1_073_741_824,
              sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              url.absoluteString == "https://github.com/openai/codex/releases/download/rust-v\(version)/codex-package-\(target).tar.gz" else {
            throw CodexInstallationError(.invalidConfiguration)
        }
    }
    public static let targets = ["aarch64-apple-darwin", "x86_64-apple-darwin", "aarch64-unknown-linux-musl", "x86_64-unknown-linux-musl", "aarch64-pc-windows-msvc", "x86_64-pc-windows-msvc"]
    public var executableName: String { target.contains("windows") ? "codex.exe" : "codex" }
    public var requiredExecutablePaths: [String] {
        let suffix = target.contains("windows") ? ".exe" : ""
        return ["bin/codex" + suffix, "bin/codex-code-mode-host" + suffix, "codex-path/rg" + suffix]
    }
    public static var current: Self? {
        #if os(macOS) && arch(arm64)
        pinned.first { $0.target == "aarch64-apple-darwin" }
        #elseif os(macOS) && arch(x86_64)
        pinned.first { $0.target == "x86_64-apple-darwin" }
        #else
        nil
        #endif
    }
    public static let pinned: [Self] = [
        manifest("aarch64-apple-darwin", 127_394_863, "fea42f9625091f011e38f059da974d52e57ba31831648bb1c7f0b1a385fde547"),
        manifest("x86_64-apple-darwin", 138_670_455, "618dbcd55419fa041871f777a14b107ceb3fe2d339ef81e21e6ab5374420dc71"),
        manifest("aarch64-unknown-linux-musl", 136_933_361, "fdd47ed6aade0360796fd3f6f95a45096f327c15e19e8c7339f9dc5633041786"),
        manifest("x86_64-unknown-linux-musl", 145_976_992, "8b711520beddf385467b8da4d2c93736637c6ba1e46811cf0d8606b7c490b6f6"),
        manifest("aarch64-pc-windows-msvc", 142_037_952, "85994caecdc7609c49fd585c1cdb5677fa9d0acbf789650cff23a13afc9505db"),
        manifest("x86_64-pc-windows-msvc", 153_839_991, "a2e017db9807e6a2269a26fea0e1d9546469cef4d472a33016bc9f3ad7d3b733")
    ]
    private static func manifest(_ target: String, _ bytes: Int64, _ sha: String) -> Self {
        try! .init(version: "0.156.1", target: target,
                   url: URL(string: "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-package-\(target).tar.gz")!, archiveBytes: bytes, sha256: sha)
    }
}
