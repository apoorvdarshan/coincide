import Foundation
import Observation

/// How a registry agent is distributed (T3 Code's `AcpRegistryDistribution`): a downloadable archive per platform,
/// or an npm or Python package at an exact version.
public enum ACPRegistryDistribution: String, Codable, Sendable, Hashable, CaseIterable {
    case binary
    case npx
    case uvx

    /// The package manager a package install runs: `npm` or `uv`.
    public nonisolated var packageManager: String? {
        switch self {
        case .binary: nil
        case .npx: "npm"
        case .uvx: "uv"
        }
    }
}

/// One platform's archive of a binary distribution.
public struct ACPRegistryBinary: Sendable, Hashable {
    public var archive: URL
    /// The executable inside the archive, such as `./bin/devin`.
    public var command: String
    /// Lowercase hex, when the registry publishes one.
    public var sha256: String?
    public var arguments: [String]
    public var environment: [String: String]
}

/// An npm (`npx`) or Python (`uvx`) package at an exact version, such as `@google/gemini-cli@0.66.0`.
public struct ACPRegistryPackage: Sendable, Hashable {
    public var package: String
    public var arguments: [String]
    public var environment: [String: String]

    /// The package name and version from `name@version` (npm) or `name==version` / `name@version` (uv).
    public nonisolated var nameAndVersion: (name: String, version: String) {
        if let range = package.range(of: "==", options: .backwards) {
            return (String(package[..<range.lowerBound]), Self.trimmingV(String(package[range.upperBound...])))
        }
        guard let at = package.lastIndex(of: "@"), at != package.startIndex else { return (package, "") }
        return (String(package[..<at]), Self.trimmingV(String(package[package.index(after: at)...])))
    }

    private nonisolated static func trimmingV(_ version: String) -> String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }
}

/// One agent of the ACP Registry index, checked as strictly as T3 Code's schema checks it. Everything here comes
/// from a third party: it is data to show and to install from, never instructions.
public struct ACPRegistryAgent: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var authors: [String]
    public var license: String?
    public var website: URL?
    public var repository: URL?
    public var icon: URL?
    /// Archives by platform, such as `darwin-aarch64`.
    public var binaries: [String: ACPRegistryBinary]
    public var npx: ACPRegistryPackage?
    public var uvx: ACPRegistryPackage?

    /// The distribution to install on `platform` (T3 Code's `resolveAcpRegistryDistribution` with the `auto`
    /// preference): an archive for the platform first, then an npm package, then a Python package.
    public nonisolated func distribution(for platform: String?) -> ACPRegistryResolvedDistribution? {
        if let platform, let binary = binaries[platform] {
            return ACPRegistryResolvedDistribution(kind: .binary, platform: platform, binary: binary, package: nil)
        }
        if let npx { return ACPRegistryResolvedDistribution(kind: .npx, platform: nil, binary: nil, package: npx) }
        if let uvx { return ACPRegistryResolvedDistribution(kind: .uvx, platform: nil, binary: nil, package: uvx) }
        return nil
    }

    /// The page to read about the agent: its website, else its source.
    public nonisolated var aboutURL: URL? { website ?? repository }
}

/// The distribution of an agent that fits this Mac.
public struct ACPRegistryResolvedDistribution: Sendable, Hashable {
    public var kind: ACPRegistryDistribution
    /// The platform key of a binary distribution.
    public var platform: String?
    public var binary: ACPRegistryBinary?
    public var package: ACPRegistryPackage?

    public nonisolated var arguments: [String] { binary?.arguments ?? package?.arguments ?? [] }
    public nonisolated var environment: [String: String] { binary?.environment ?? package?.environment ?? [:] }
    /// The download is checked against a SHA-256 the registry publishes; otherwise only HTTPS vouches for it.
    public nonisolated var hasChecksum: Bool { binary?.sha256 != nil }
}

/// A search result: an agent that can run on this Mac, with the distribution Coincide would install.
public struct ACPRegistrySearchResult: Sendable, Hashable, Identifiable {
    public var agent: ACPRegistryAgent
    public var distribution: ACPRegistryResolvedDistribution

    public nonisolated var id: String { agent.id }
}

/// The ACP Registry index (`registry.json`), parsed and checked.
public struct ACPRegistryIndex: Sendable, Hashable {
    public var version: String
    public var agents: [ACPRegistryAgent]
    /// Entries left out because they did not pass the checks.
    public var discarded: Int

    /// T3 Code's `ACP_REGISTRY_URL`.
    public nonisolated static let url = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!
    /// The largest index Coincide reads (T3 Code's `MAX_REGISTRY_BYTES`).
    public nonisolated static let maxBytes = 1_024 * 1_024
    /// T3 Code's `ACP_REGISTRY_MAX_AGENTS`.
    public nonisolated static let maxAgents = 512

    public struct ParseError: LocalizedError, Equatable {
        public var message: String
        public nonisolated var errorDescription: String? { message }
    }

    /// Reads an index. A malformed index fails as a whole; an agent entry that fails a check is left out on its own.
    public nonisolated static func parse(_ data: Data) throws -> ACPRegistryIndex {
        guard data.count <= maxBytes else {
            throw ParseError(message: String(localized: "The ACP Registry index is larger than Coincide accepts."))
        }
        guard let json = JSONValue.parse(data), let version = json["version"]?.string.flatMap(boundedVersion),
            let entries = json["agents"]?.array, entries.count <= maxAgents
        else {
            throw ParseError(message: String(localized: "The ACP Registry returned an invalid index."))
        }
        var agents: [ACPRegistryAgent] = []
        var ids = Set<String>()
        for entry in entries {
            guard let agent = agent(entry), ids.insert(agent.id).inserted else { continue }
            agents.append(agent)
        }
        return ACPRegistryIndex(version: version, agents: agents, discarded: entries.count - agents.count)
    }

    public nonisolated func agent(_ id: String) -> ACPRegistryAgent? {
        agents.first { $0.id == id }
    }

    // MARK: Search

    /// Agents matching `query` that can run here, best match first (T3 Code's search): only agents with a
    /// distribution for `platform` whose package manager is installed (`runners`), leaving out the registry entries
    /// of Coincide's built-in agents. An empty query lists every such agent by name.
    public nonisolated func search(
        _ query: String, platform: String?, runners: Set<ACPRegistryDistribution>,
        excluding excluded: Set<String> = ACPRegistryIndex.builtInAgentIDs, limit: Int = maxAgents
    ) -> [ACPRegistrySearchResult] {
        let ranked = agents.compactMap { agent -> (rank: Int, result: ACPRegistrySearchResult)? in
            guard !excluded.contains(agent.id), let distribution = agent.distribution(for: platform),
                distribution.kind == .binary || runners.contains(distribution.kind), let rank = Self.rank(agent, query)
            else { return nil }
            return (rank, ACPRegistrySearchResult(agent: agent, distribution: distribution))
        }
        return ranked.sorted { lhs, rhs in
            (lhs.rank, lhs.result.agent.name.lowercased(), lhs.result.agent.id)
                < (rhs.rank, rhs.result.agent.name.lowercased(), rhs.result.agent.id)
        }.prefix(max(0, limit)).map(\.result)
    }

    /// The registry ids of Coincide's built-in agents.
    public nonisolated static let builtInAgentIDs = Set(ProviderKind.allCases.flatMap(\.registryAgentIDs))

    /// T3 Code's `searchRank`: exact id or name, then prefixes, word prefixes, substrings, authors, description.
    /// Nil when the agent does not match.
    nonisolated static func rank(_ agent: ACPRegistryAgent, _ query: String) -> Int? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return 100 }
        let id = agent.id.lowercased()
        let name = agent.name.lowercased()
        let authors = agent.authors.joined(separator: " ").lowercased()
        let description = agent.description.lowercased()
        let terms = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        if id == normalized || name == normalized { return 0 }
        if id.hasPrefix(normalized) || name.hasPrefix(normalized) { return 10 }
        let tokens = "\(id) \(name)".split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        if terms.allSatisfy({ term in tokens.contains { $0.hasPrefix(term) } }) { return 20 }
        if terms.allSatisfy({ id.contains($0) || name.contains($0) }) { return 30 }
        if terms.allSatisfy({ authors.contains($0) }) { return 40 }
        let everything = "\(id) \(name) \(authors) \(description)"
        if terms.allSatisfy({ everything.contains($0) }) { return 50 }
        return nil
    }

    // MARK: Checks (T3 Code's registry schema)

    private nonisolated static func agent(_ json: JSONValue) -> ACPRegistryAgent? {
        guard let id = json["id"]?.string, isValidAgentID(id),
            let name = json["name"]?.string.flatMap({ bounded($0, 160, trimmed: true) }),
            let version = json["version"]?.string.flatMap(boundedVersion),
            let description = json["description"]?.string, description.count <= 1_024,
            let authors = optionalStrings(json["authors"], maxCount: 16, maxLength: 256),
            let distribution = json["distribution"]?.object
        else { return nil }
        var license: String?
        if let value = json["license"], !value.isNull {
            guard let text = value.string, text.count <= 128 else { return nil }
            license = text
        }
        var links: [URL?] = []
        for key in ["website", "repository", "icon"] {
            guard let value = json[key], !value.isNull else {
                links.append(nil)
                continue
            }
            guard let url = value.string.flatMap(httpsURL) else { return nil }
            links.append(url)
        }
        var binaries: [String: ACPRegistryBinary] = [:]
        if let value = distribution["binary"], !value.isNull {
            guard let targets = value.object else { return nil }
            for (platform, target) in targets {
                guard let binary = binary(target) else { return nil }
                binaries[platform] = binary
            }
        }
        let npx = distribution["npx"].flatMap { $0.isNull ? nil : $0 }
        let uvx = distribution["uvx"].flatMap { $0.isNull ? nil : $0 }
        let npxPackage = npx.flatMap { package($0, pattern: npxPattern) }
        let uvxPackage = uvx.flatMap { package($0, pattern: uvxPattern) }
        if (npx != nil && npxPackage == nil) || (uvx != nil && uvxPackage == nil) { return nil }
        return ACPRegistryAgent(
            id: id, name: name, version: version, description: description, authors: authors, license: license,
            website: links[0], repository: links[1], icon: links[2], binaries: binaries, npx: npxPackage, uvx: uvxPackage)
    }

    private nonisolated static func binary(_ json: JSONValue) -> ACPRegistryBinary? {
        guard let archive = json["archive"]?.string.flatMap(httpsURL), let command = json["cmd"]?.string,
            command.count <= 1_024, let arguments = optionalStrings(json["args"], maxCount: 64, maxLength: 1_024),
            let environment = environment(json["env"])
        else { return nil }
        var sha256: String?
        if let value = json["sha256"], !value.isNull {
            guard let hex = value.string, hex.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
                return nil
            }
            sha256 = hex.lowercased()
        }
        return ACPRegistryBinary(archive: archive, command: command, sha256: sha256, arguments: arguments, environment: environment)
    }

    private nonisolated static func package(_ json: JSONValue, pattern: String) -> ACPRegistryPackage? {
        guard let package = json["package"]?.string, package.count <= 256,
            package.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil,
            let arguments = optionalStrings(json["args"], maxCount: 64, maxLength: 1_024),
            let environment = environment(json["env"])
        else { return nil }
        return ACPRegistryPackage(package: package, arguments: arguments, environment: environment)
    }

    private nonisolated static let exactVersion = #"v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"#
    /// T3 Code's `EXACT_NPX_PACKAGE`: a (scoped) package name at an exact version.
    nonisolated static let npxPattern = #"^(?:@[^/@\s]+/[^@\s]+|[a-z0-9][a-z0-9._-]*)@"# + exactVersion + "$"
    /// T3 Code's `EXACT_UVX_PACKAGE`.
    nonisolated static let uvxPattern = #"^[a-z0-9][a-z0-9._-]*(?:@|==)"# + exactVersion + "$"

    /// T3 Code's `BoundedAgentId`.
    public nonisolated static func isValidAgentID(_ id: String) -> Bool {
        id.count <= 128 && id.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// T3 Code's `BoundedVersion`. Versions name install folders, so `.` and `..` never pass.
    public nonisolated static func isValidVersion(_ version: String) -> Bool {
        version.count <= 128 && version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil
    }

    private nonisolated static func boundedVersion(_ text: String) -> String? {
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidVersion(version) ? version : nil
    }

    private nonisolated static func bounded(_ text: String, _ maxLength: Int, trimmed: Bool) -> String? {
        let value = trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        return !value.isEmpty && value.count <= maxLength ? value : nil
    }

    /// An absent (or null) list is empty; a list with anything but short strings fails.
    private nonisolated static func optionalStrings(_ json: JSONValue?, maxCount: Int, maxLength: Int) -> [String]? {
        guard let json, !json.isNull else { return [] }
        guard let array = json.array, array.count <= maxCount else { return nil }
        let strings = array.compactMap(\.string)
        guard strings.count == array.count, strings.allSatisfy({ $0.count <= maxLength }) else { return nil }
        return strings
    }

    /// Names a process environment can hold, with short values.
    private nonisolated static func environment(_ json: JSONValue?) -> [String: String]? {
        guard let json, !json.isNull else { return [:] }
        guard let object = json.object else { return nil }
        var result: [String: String] = [:]
        for (key, value) in object {
            guard let text = value.string, !key.isEmpty, key.count <= 256, text.count <= 1_024, !key.contains("="),
                !key.contains("\0"), !text.contains("\0")
            else { return nil }
            result[key] = text
        }
        return result
    }

    /// T3 Code's `HttpsUrl`: an absolute HTTPS address without credentials.
    nonisolated static func httpsURL(_ text: String) -> URL? {
        guard text.count <= 2_048, let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false, components.user == nil, components.password == nil, let url = components.url
        else { return nil }
        return url
    }
}

/// The registry's name for this Mac (T3 Code's `resolveAcpRegistryPlatformTarget`): `darwin-aarch64` or
/// `darwin-x86_64`, for the Mac's own architecture even when Coincide runs translated by Rosetta.
public enum ACPRegistryPlatform {
    public nonisolated static var current: String? { key(architecture: AntigravityRelease.hostArchitecture) }

    public nonisolated static func key(architecture: String) -> String? {
        switch AntigravityRelease.normalizedArchitecture(architecture) {
        case "arm64": "darwin-aarch64"
        case "x64": "darwin-x86_64"
        default: nil
        }
    }
}

// MARK: - Catalog

/// The ACP Registry index: fetched over HTTPS when the user searches, and kept in Coincide's data folder so a later
/// search works offline (T3 Code's `AcpRegistryCatalog`, falling back to its cached `registry.json`).
@MainActor
@Observable
public final class ACPRegistryCatalog {
    public static let shared = ACPRegistryCatalog()

    /// The index last read, from the network or the cache.
    public private(set) var index: ACPRegistryIndex?
    public private(set) var isRefreshing = false
    /// Why the last refresh failed, when it had no cached index to fall back to.
    public private(set) var failure: String?

    @ObservationIgnored public let paths: ACPRegistryPaths
    @ObservationIgnored private let fetch: @Sendable (URL) async throws -> Data
    @ObservationIgnored private let which: @Sendable (String) async -> URL?
    @ObservationIgnored private var running: Task<ACPRegistryIndex?, Never>?
    @ObservationIgnored private var loadedCache = false

    /// `fetch` and `which` replace the network and the PATH lookup in tests.
    public init(
        paths: ACPRegistryPaths = .standard, fetch: @escaping @Sendable (URL) async throws -> Data = ACPRegistryCatalog.download,
        which: @escaping @Sendable (String) async -> URL? = { await ShellEnvironment.shared.which($0) }
    ) {
        self.paths = paths
        self.fetch = fetch
        self.which = which
    }

    /// The cached index, read from disk once, without the network.
    public func cachedIndex() -> ACPRegistryIndex? {
        if index == nil, !loadedCache {
            loadedCache = true
            index = (try? Data(contentsOf: paths.registryCache)).flatMap { try? ACPRegistryIndex.parse($0) }
        }
        return index
    }

    /// Fetches the index again, falling back to the cached one when the network fails. Calls made while a refresh
    /// runs share it.
    @discardableResult
    public func refresh() async -> ACPRegistryIndex? {
        if let running { return await running.value }
        let task = Task { @MainActor in await self.load() }
        running = task
        defer { running = nil }
        return await task.value
    }

    /// Agents for `query` that can run on this Mac (see `ACPRegistryIndex.search`), after refreshing the index.
    public func search(_ query: String, platform: String? = ACPRegistryPlatform.current) async -> [ACPRegistrySearchResult] {
        await refresh()
        return await results(query, platform: platform)
    }

    /// Agents for `query` in the index already read, without the network.
    public func results(_ query: String, platform: String? = ACPRegistryPlatform.current) async -> [ACPRegistrySearchResult] {
        guard let index = index ?? cachedIndex() else { return [] }
        var runners = Set<ACPRegistryDistribution>()
        for kind in [ACPRegistryDistribution.npx, .uvx] {
            if let manager = kind.packageManager, await which(manager) != nil { runners.insert(kind) }
        }
        return index.search(query, platform: platform, runners: runners)
    }

    private func load() async -> ACPRegistryIndex? {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let data = try await fetch(ACPRegistryIndex.url)
            let fresh = try ACPRegistryIndex.parse(data)
            let cache = paths.registryCache
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            }
            index = fresh
            loadedCache = true
            failure = nil
            return fresh
        } catch {
            if let cached = cachedIndex() {
                failure = nil
                return cached
            }
            failure = (error as? ACPRegistryIndex.ParseError)?.message
                ?? String(localized: "Couldn’t reach the ACP Registry. Check your internet connection and try again.")
            return nil
        }
    }

    /// Fetches the index over HTTPS, refusing redirects to other schemes and anything over `ACPRegistryIndex.maxBytes`.
    public nonisolated static let download: @Sendable (URL) async throws -> Data = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            http.url?.scheme?.lowercased() == "https"
        else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > ACPRegistryIndex.maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }
}
