import Foundation

/// Pinned archive identity. This is a release manifest, never account state.
public struct AntigravityManagedRelease: Codable, Sendable, Equatable, Hashable {
    public let version: String
    public let platform: String
    public let architecture: String
    public let url: URL
    public let archiveBytes: Int64
    public let sha256: String
    public let serverName: String
    public let serverBytes: Int64
    public let harnessName: String
    public let harnessBytes: Int64

    public init(version: String, platform: String, architecture: String, url: URL, archiveBytes: Int64,
                sha256: String, serverName: String, serverBytes: Int64, harnessName: String, harnessBytes: Int64) throws {
        self.version = version; self.platform = platform; self.architecture = architecture; self.url = url
        self.archiveBytes = archiveBytes; self.sha256 = sha256; self.serverName = serverName
        self.serverBytes = serverBytes; self.harnessName = harnessName; self.harnessBytes = harnessBytes
        try validate()
    }
    public func validate() throws {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard !version.isEmpty, version.utf8.count <= 128, !version.unicodeScalars.contains(where: { $0.value < 32 }),
              ["darwin", "linux", "win32"].contains(platform), ["arm64", "x64"].contains(architecture),
              components?.scheme == "https", components?.host?.isEmpty == false,
              components?.user == nil, components?.password == nil, components?.query == nil, components?.fragment == nil,
              archiveBytes > 0, archiveBytes <= 1_073_741_824, serverBytes > 0, serverBytes <= 2_147_483_648,
              harnessBytes > 0, harnessBytes <= 2_147_483_648,
              sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              serverName == (platform == "win32" ? "agy_acp_server.exe" : "agy_acp_server.par"),
              harnessName == (platform == "win32" ? "localharness_external.exe" : "localharness_external") else {
            throw AntigravityInstallationError(.invalidConfiguration)
        }
    }
    public var requiredFreeBytes: Int64 { archiveBytes + serverBytes + harnessBytes + 268_435_456 }
    public static var current: Self? {
        #if os(macOS) && arch(arm64)
        pinned.first { $0.platform == "darwin" && $0.architecture == "arm64" }
        #elseif os(macOS) && arch(x86_64)
        pinned.first { $0.platform == "darwin" && $0.architecture == "x64" }
        #else
        nil
        #endif
    }
    /// Exact T3 680152e manifest. Availability is established by a later download.
    public static let pinned: [Self] = [
        manifest("darwin", "arm64", "macos", "darwin-arm64", 111_456_962,
                 "7cd97045f7b4fe81175a107cdf16f9c51484e3c78a5162cae415338bb6aa5b88", 278_535_456, 118_611_392),
        manifest("darwin", "x64", "macos", "darwin-x86_64", 117_245_544,
                 "bb23956b89984bf5d354af2c3725e6c57f0cc1b7228e77a0e91c9c2bc1d47646", 282_840_688, 124_175_392),
        manifest("linux", "x64", "linux", "linux-x86_64", 333_727_150,
                 "9fb60956af0a9d76220a4db91ca9ac88e2a2372ad68f985ab5fceace6b825b96", 926_533_965, 130_388_040),
        manifest("linux", "arm64", "linux", "linux-arm64", 321_690_363,
                 "500b0bc0fb858e88f4df404d4cedf80bf9298c178291e39e383d6c50b111cbdf", 930_848_992, 123_224_968),
        manifest("win32", "x64", "windows", "windows-x86_64", 124_509_787,
                 "65215e0688681fa3116e048a9eab27ef53af1bbd6f3da3f1c52bd4911d8b17f9", 81_437_336, 145_548_952),
        manifest("win32", "arm64", "windows", "windows-arm64", 124_654_803,
                 "4a0f469720e9beb9438a979f543fdbfad5022ebe0992c052c590bd78b3144ca3", 85_893_472, 135_640_216)
    ]
    private static func manifest(_ platform: String, _ architecture: String, _ directory: String, _ suffix: String,
                                 _ archive: Int64, _ sha: String, _ server: Int64, _ harness: Int64) -> Self {
        // Every literal is validated here; no downloaded value can reach this path.
        try! .init(version: "1.3.0", platform: platform, architecture: architecture,
                   url: URL(string: "https://dl.google.com/agy-extensions/releases/\(directory)/agy-acp-server-1.3.0-\(suffix).zip")!,
                   archiveBytes: archive, sha256: sha, serverName: platform == "win32" ? "agy_acp_server.exe" : "agy_acp_server.par",
                   serverBytes: server, harnessName: platform == "win32" ? "localharness_external.exe" : "localharness_external", harnessBytes: harness)
    }
}
