import Foundation

/// The bundled open-source notice manifest (docs/third-party-notices.json), copied with
/// the notice texts into the app's Resources/Notices folder by the build script.
public struct ThirdPartyNotices: Codable, Sendable, Equatable {
    public struct Package: Codable, Sendable, Equatable, Identifiable {
        public enum Distribution: String, Codable, Sendable { case bundled, system, onDemand }
        public let id: String
        public let name: String
        public let version: String
        /// An SPDX license expression.
        public let license: String
        public let components: [String]
        public let distribution: Distribution
        public let detail: String?
        public let noticeFiles: [String]
        public let sourceURL: URL
        /// The Package.resolved identity, for dependencies resolved by SwiftPM.
        public let resolvedIdentity: String?

        public func matches(_ query: String) -> Bool {
            let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
            guard !terms.isEmpty else { return true }
            let haystack = ([name, version, license, distribution.rawValue] + components).joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
    public struct ExcludedPin: Codable, Sendable, Equatable {
        public let identity: String
        public let reason: String
    }
    public let version: Int
    public let packages: [Package]
    public let excludedPins: [ExcludedPin]

    public static let manifestName = "third-party-notices.json"

    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, Set(value.packages.map(\.id)).count == value.packages.count,
              value.packages.allSatisfy({ !$0.license.trimmingCharacters(in: .whitespaces).isEmpty && $0.noticeFiles.allSatisfy(Self.isPlainFileName) }) else {
            throw CoincideError("The open-source notice manifest is invalid.")
        }
        return value
    }

    /// Notice files are plain names inside the Notices folder; no paths are followed.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && !name.contains("\0") && name.utf8.count <= 255
    }

    public static func load(directory: URL) throws -> Self {
        try decode(Data(contentsOf: directory.appendingPathComponent(manifestName)))
    }

    public func filtered(_ query: String) -> [Package] { packages.filter { $0.matches(query) } }

    /// Reads a notice text from the Notices folder, bounded to 1 MiB.
    public static func noticeText(_ name: String, directory: URL) throws -> String {
        guard isPlainFileName(name) else { throw CoincideError("This notice file name is invalid.") }
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? .max) <= 1 << 20 else { throw CoincideError("This notice file is unavailable.") }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
