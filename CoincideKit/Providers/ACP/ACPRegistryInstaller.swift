import CryptoKit
import Darwin
import Foundation
import Observation

/// Where registry agents live in Coincide's data folder: `tools/acp/<agent-id>/<version>/`, as T3 Code installs
/// them under `tools/<agent-id>/<version>/` in its home. A binary unpacks into a folder named after its platform; an
/// npm package gets its own prefix (`npm/`) and a Python package its own tool folder (`python/`), so nothing is
/// installed globally.
public struct ACPRegistryPaths: Sendable, Hashable {
    public var dataDirectory: URL

    public nonisolated init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public nonisolated static var standard: ACPRegistryPaths { ACPRegistryPaths(dataDirectory: AntigravityPaths.coincideDataDirectory) }

    public nonisolated var toolsDirectory: URL { dataDirectory.appendingPathComponent("tools/acp", isDirectory: true) }
    /// The last index read, for searching offline.
    public nonisolated var registryCache: URL {
        dataDirectory.appendingPathComponent("caches/acp-registry/registry.json", isDirectory: false)
    }

    public nonisolated func agentDirectory(_ agentID: String) -> URL {
        toolsDirectory.appendingPathComponent(agentID, isDirectory: true)
    }

    public nonisolated func versionDirectory(_ agentID: String, _ version: String) -> URL {
        agentDirectory(agentID).appendingPathComponent(version, isDirectory: true)
    }

    public nonisolated func versionDirectory(for install: ACPRegistryInstall) -> URL {
        versionDirectory(install.agentID, install.version)
    }

    /// The installed executable, when it is still a runnable file inside its version's folder (after resolving
    /// links, as T3 Code's `assertExecutableInRoot` checks).
    public nonisolated func validatedExecutable(for install: ACPRegistryInstall) -> URL? {
        guard let components = Self.relativeComponents(install.executable) else { return nil }
        let root = versionDirectory(for: install)
        let url = components.reduce(root) { $0.appendingPathComponent($1) }
        return Self.isExecutable(url, inside: root) ? url : nil
    }

    /// Whether `url` resolves to a regular executable file inside `root`.
    nonisolated static func isExecutable(_ url: URL, inside root: URL) -> Bool {
        let rootPath = AntigravityPaths.canonicalPath(root)
        let resolved = AntigravityPaths.canonicalPath(url)
        guard resolved.hasPrefix(rootPath + "/") else { return false }
        var info = stat()
        guard stat(resolved, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o111 != 0
    }

    /// Whether `url` is inside Coincide's registry installs, after resolving links.
    public nonisolated func isManaged(_ url: URL) -> Bool {
        AntigravityPaths.canonicalPath(url).hasPrefix(AntigravityPaths.canonicalPath(toolsDirectory) + "/")
    }

    /// A registry command such as `./bin/devin` as path components, or nil for anything that could leave its folder:
    /// an absolute path, a drive letter, `.` or `..` (T3 Code's `normalizeRegistryCommandPath`).
    public nonisolated static func relativeComponents(_ path: String) -> [String]? {
        var normalized = path.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("./") { normalized.removeFirst(2) }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty, !normalized.hasPrefix("/"),
            normalized.range(of: "^[A-Za-z]:", options: .regularExpression) == nil,
            !components.contains(where: { $0 == "." || $0 == ".." || $0.contains("\0") })
        else { return nil }
        return components
    }
}

/// Why an installation failed. `message` is safe to show as it is.
public struct ACPRegistryInstallError: LocalizedError, Equatable {
    public var message: String

    public nonisolated init(_ message: String) {
        self.message = message
    }

    public nonisolated var errorDescription: String? { message }
}

/// What an installation reports while it runs.
public enum ACPRegistryInstallProgress: Sendable, Hashable {
    case downloading(bytes: Int64, total: Int64?)
    case extracting
    /// npm or uv is installing the package.
    case installingPackage
}

/// Installs one version of a registry agent (T3 Code's `installBinary` and `ensureGlobalPackage`). Everything that
/// reaches outside (the network, running `tar`, `npm` or `uv`, free space) is injected, so tests never download or run
/// anything real.
///
/// A binary is downloaded over HTTPS into a staging folder, checked against the registry's SHA-256 when it publishes
/// one (and otherwise kept to the registry's HTTPS guarantee, as T3 Code does), unpacked only after every entry name
/// is checked to stay inside the folder, and published under its version's folder in one rename. Its executable must
/// resolve inside that folder. Packages install at the registry's exact version into prefixes Coincide owns.
public struct ACPRegistryInstaller: Sendable {
    public typealias Runner = @Sendable (
        _ executable: URL, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval
    ) async -> ProcessRunner.Result

    /// T3 Code's `MAX_ARCHIVE_BYTES`.
    nonisolated static let maxArchiveBytes: Int64 = 1_024 * 1_024 * 1_024
    nonisolated static let recordName = ".coincide-install.json"
    nonisolated static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    /// T3 Code's `PACKAGE_INSTALL_TIMEOUT`.
    nonisolated static let packageTimeout: TimeInterval = 20 * 60

    var paths: ACPRegistryPaths
    var download: AntigravityDownloader
    var run: Runner
    var freeSpace: @Sendable (URL) -> Int64?

    public nonisolated init(
        paths: ACPRegistryPaths = .standard, download: @escaping AntigravityDownloader = AntigravityDownload.urlSession,
        run: @escaping Runner = { executable, arguments, environment, timeout in
            await ProcessRunner.run(executable, arguments, environment: environment, timeout: timeout)
        },
        freeSpace: @escaping @Sendable (URL) -> Int64? = AntigravityInstaller.availableSpace
    ) {
        self.paths = paths
        self.download = download
        self.run = run
        self.freeSpace = freeSpace
    }

    /// Installs `agent` with `distribution` (one of its own) and returns the record sessions launch from.
    /// `environment` is the login shell's, which finds `npm` or `uv`.
    public nonisolated func install(
        _ agent: ACPRegistryAgent, _ distribution: ACPRegistryResolvedDistribution, environment: [String: String],
        progress: @escaping @Sendable (ACPRegistryInstallProgress) -> Void = { _ in }
    ) async throws -> ACPRegistryInstall {
        guard ACPRegistryIndex.isValidAgentID(agent.id), ACPRegistryIndex.isValidVersion(agent.version) else {
            throw ACPRegistryInstallError(String(localized: "The ACP Registry entry for this agent is invalid."))
        }
        let installed: (executable: String, binDirectory: String?, sha256: String?)
        switch distribution.kind {
        case .binary:
            guard let platform = distribution.platform, let binary = distribution.binary else {
                throw ACPRegistryInstallError(String(localized: "This agent has no download for this Mac."))
            }
            installed = try await installBinary(agent, platform: platform, binary, progress: progress)
        case .npx, .uvx:
            guard let package = distribution.package else {
                throw ACPRegistryInstallError(String(localized: "This agent has no download for this Mac."))
            }
            progress(.installingPackage)
            installed = try await installPackage(agent, distribution.kind, package, environment: environment)
        }
        return ACPRegistryInstall(
            agentID: agent.id, version: agent.version, distribution: distribution.kind, executable: installed.executable,
            arguments: distribution.arguments, environment: distribution.environment, binDirectory: installed.binDirectory,
            sha256: installed.sha256, website: agent.website, repository: agent.repository, license: agent.license)
    }

    // MARK: Binaries

    /// What a binary install's folder records; written last, so a folder without it is incomplete.
    struct Record: Codable, Equatable {
        var archive: URL
        var sha256: String
        var command: String
    }

    private nonisolated func installBinary(
        _ agent: ACPRegistryAgent, platform: String, _ binary: ACPRegistryBinary,
        progress: @escaping @Sendable (ACPRegistryInstallProgress) -> Void
    ) async throws -> (executable: String, binDirectory: String?, sha256: String?) {
        guard let components = ACPRegistryPaths.relativeComponents(binary.command), !platform.contains("/"),
            platform.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil
        else {
            throw ACPRegistryInstallError(String(localized: "The ACP Registry entry for this agent has an unsafe command path."))
        }
        let versionDirectory = paths.versionDirectory(agent.id, agent.version)
        let root = versionDirectory.appendingPathComponent(platform, isDirectory: true)
        let relative = ([platform] + components).joined(separator: "/")
        let executable = components.reduce(root) { $0.appendingPathComponent($1) }
        if let record = Self.readRecord(in: root), record.archive == binary.archive, record.command == binary.command,
            binary.sha256 == nil || binary.sha256 == record.sha256, ACPRegistryPaths.isExecutable(executable, inside: root)
        {
            return (relative, nil, binary.sha256)
        }

        let manager = FileManager.default
        let agentDirectory = paths.agentDirectory(agent.id)
        let staging = agentDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        do {
            try manager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: extracted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw ACPRegistryInstallError(String(localized: "Couldn’t create the agent’s folder in Coincide’s data folder."))
        }
        defer { try? manager.removeItem(at: staging) }

        let kind = ArchiveKind(binary.archive)
        let archive = staging.appendingPathComponent(kind.fileName)
        let sink = try ACPRegistryArchiveSink(
            file: archive, maxBytes: Self.maxArchiveBytes, freeSpace: { freeSpace(staging) }, progress: progress)
        do {
            try await download(binary.archive, sink)
        } catch {
            sink.close()
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? ACPRegistryInstallError { throw error }
            throw ACPRegistryInstallError(
                String(localized: "Couldn’t download \(agent.name). Check your internet connection and try again."))
        }
        let digest = try sink.finish()
        if let expected = binary.sha256, digest != expected {
            throw ACPRegistryInstallError(
                String(localized: "The download of \(agent.name) didn’t match the SHA-256 the ACP Registry publishes. Nothing was installed."))
        }

        progress(.extracting)
        if kind == .raw {
            let target = components.reduce(extracted) { $0.appendingPathComponent($1) }
            do {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: archive, to: target)
            } catch {
                throw ACPRegistryInstallError(String(localized: "Couldn’t unpack \(agent.name)."))
            }
        } else {
            try await unpack(archive, into: extracted, name: agent.name)
        }
        let staged = components.reduce(extracted) { $0.appendingPathComponent($1) }
        var info = stat()
        guard lstat(staged.path, &info) == 0 else {
            throw ACPRegistryInstallError(String(localized: "The download of \(agent.name) doesn’t contain the command the ACP Registry names."))
        }
        if info.st_mode & S_IFMT == S_IFREG { chmod(staged.path, 0o755) }
        guard ACPRegistryPaths.isExecutable(staged, inside: extracted) else {
            throw ACPRegistryInstallError(String(localized: "The command in the download of \(agent.name) isn’t an executable file inside its folder."))
        }
        let record = Record(archive: binary.archive, sha256: digest, command: binary.command)
        guard let data = try? JSONEncoder().encode(record),
            manager.createFile(atPath: extracted.appendingPathComponent(Self.recordName).path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw ACPRegistryInstallError(String(localized: "Couldn’t record the installation of \(agent.name).")) }
        try? manager.removeItem(at: root)
        guard rename(extracted.path, root.path) == 0, ACPRegistryPaths.isExecutable(executable, inside: root) else {
            throw ACPRegistryInstallError(String(localized: "Couldn’t install \(agent.name). Check free disk space and folder access, then try again."))
        }
        return (relative, nil, binary.sha256)
    }

    /// Lists the archive and refuses it when any entry could land outside the folder (T3 Code's
    /// `validateArchiveEntries`), then unpacks it with the system `tar`, which reads gzip, bzip2 and zip archives and
    /// by default refuses absolute paths, `..` and writing through links.
    private nonisolated func unpack(_ archive: URL, into directory: URL, name: String) async throws {
        let failed = ACPRegistryInstallError(String(localized: "Couldn’t unpack \(name)."))
        let listing = await run(Self.tar, ["-tf", archive.path], [:], 120)
        guard listing.succeeded else { throw failed }
        guard Self.entriesAreSafe(listing.stdout) else {
            throw ACPRegistryInstallError(String(localized: "The download of \(name) contains an unsafe path. Nothing was installed."))
        }
        let extraction = await run(Self.tar, ["-xf", archive.path, "-C", directory.path], [:], 600)
        guard extraction.succeeded else { throw failed }
    }

    nonisolated static func entriesAreSafe(_ listing: String) -> Bool {
        listing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .allSatisfy { $0 == "./" || $0 == "." || ACPRegistryPaths.relativeComponents($0) != nil }
    }

    nonisolated static func readRecord(in root: URL) -> Record? {
        let url = root.appendingPathComponent(recordName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? .max <= 8_192,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    enum ArchiveKind: Equatable {
        case raw, tarGzip, tarBzip2, zip

        nonisolated init(_ url: URL) {
            let path = url.path.lowercased()
            if path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") {
                self = .tarGzip
            } else if path.hasSuffix(".tar.bz2") || path.hasSuffix(".tbz2") {
                self = .tarBzip2
            } else if path.hasSuffix(".zip") {
                self = .zip
            } else {
                self = .raw
            }
        }

        nonisolated var fileName: String {
            switch self {
            case .raw: "agent.bin"
            case .tarGzip: "agent.tar.gz"
            case .tarBzip2: "agent.tar.bz2"
            case .zip: "agent.zip"
            }
        }
    }

    // MARK: Packages

    private nonisolated func installPackage(
        _ agent: ACPRegistryAgent, _ kind: ACPRegistryDistribution, _ package: ACPRegistryPackage,
        environment: [String: String]
    ) async throws -> (executable: String, binDirectory: String?, sha256: String?) {
        guard let managerName = kind.packageManager else { throw ACPRegistryInstallError(String(localized: "Couldn’t install \(agent.name).")) }
        guard let manager = Self.which(managerName, in: environment) else {
            throw ACPRegistryInstallError(
                String(localized: "\(agent.name) installs with \(managerName), which isn’t on your shell’s PATH. Install it, then try again."))
        }
        let folder = kind == .npx ? "npm" : "python"
        let versionDirectory = paths.versionDirectory(agent.id, agent.version)
        let root = versionDirectory.appendingPathComponent(folder, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        } catch {
            throw ACPRegistryInstallError(String(localized: "Couldn’t create the agent’s folder in Coincide’s data folder."))
        }
        var installEnvironment = environment
        installEnvironment["PATH"] = ([Self.managerDirectory(manager).path] + (environment["PATH"] ?? "").split(separator: ":").map(String.init))
            .joined(separator: ":")
        let arguments: [String]
        if kind == .npx {
            // T3 Code's npm prefix: a global install that lands in Coincide's folder.
            installEnvironment["npm_config_prefix"] = root.path
            arguments = ["install", "--global", package.package]
        } else {
            installEnvironment["UV_TOOL_DIR"] = root.path
            installEnvironment["UV_TOOL_BIN_DIR"] = bin.path
            arguments = ["tool", "install", "--force", package.package]
        }
        let identity = package.nameAndVersion
        if let command = installedCommand(agent, kind, identity: identity, root: root, bin: bin) {
            return ("\(folder)/bin/\(command)", "\(folder)/bin", nil)
        }
        let result = await run(manager, arguments, installEnvironment, Self.packageTimeout)
        guard result.succeeded else {
            let detail = Self.lastLine(result.stderr)
            throw ACPRegistryInstallError(
                detail.map { String(localized: "\(managerName) couldn’t install \(package.package): \($0)") }
                    ?? String(localized: "\(managerName) couldn’t install \(package.package)."))
        }
        guard let command = installedCommand(agent, kind, identity: identity, root: root, bin: bin) else {
            throw ACPRegistryInstallError(String(localized: "\(managerName) installed \(package.package), but Coincide couldn’t find its command."))
        }
        return ("\(folder)/bin/\(command)", "\(folder)/bin", nil)
    }

    /// The command an installed package provides, when the install is complete: for npm, the package's manifest names
    /// the expected version and its command (T3 Code's `npmCommandName`); for uv, the first of T3 Code's
    /// `packageCommandCandidates` that exists.
    nonisolated func installedCommand(
        _ agent: ACPRegistryAgent, _ kind: ACPRegistryDistribution, identity: (name: String, version: String), root: URL, bin: URL
    ) -> String? {
        let command: String?
        if kind == .npx {
            let manifestURL = identity.name.split(separator: "/").reduce(root.appendingPathComponent("lib/node_modules")) {
                $0.appendingPathComponent(String($1))
            }.appendingPathComponent("package.json")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
                (attributes[.size] as? NSNumber)?.intValue ?? .max <= 1_024 * 1_024,
                let manifest = (try? Data(contentsOf: manifestURL)).flatMap(JSONValue.parse(_:)),
                manifest["name"]?.string == identity.name, manifest["version"]?.string == identity.version
            else { return nil }
            command = Self.npmCommandName(agentID: agent.id, packageName: identity.name, bin: manifest["bin"])
        } else {
            command = Self.packageCommandCandidates(agentID: agent.id, packageName: identity.name).first {
                ACPRegistryPaths.isExecutable(bin.appendingPathComponent($0), inside: root)
            }
        }
        guard let command, Self.isCommandName(command),
            ACPRegistryPaths.isExecutable(bin.appendingPathComponent(command), inside: root.deletingLastPathComponent())
        else { return nil }
        return command
    }

    /// T3 Code's `npmCommandName`: a `bin` string is the package's own name; of a `bin` map, its only command, the one
    /// named like the package or the agent, or the first when every command runs the same file.
    nonisolated static func npmCommandName(agentID: String, packageName: String, bin: JSONValue?) -> String? {
        let baseName = packageName.split(separator: "/").last.map(String.init) ?? packageName
        if bin?.string != nil { return baseName }
        guard let commands = bin?.object, !commands.isEmpty else { return nil }
        let names = commands.keys.sorted()
        if names.count == 1 { return names[0] }
        if commands[baseName] != nil { return baseName }
        if commands[agentID] != nil { return agentID }
        return Set(commands.values.compactMap(\.string)).count == 1 ? names.first : nil
    }

    /// T3 Code's `packageCommandCandidates`: the agent's id, the package's name, and that name without `-acp`.
    nonisolated static func packageCommandCandidates(agentID: String, packageName: String) -> [String] {
        let unscoped = packageName.split(separator: "/").last.map(String.init) ?? packageName
        var candidates: [String] = []
        for name in [agentID, unscoped, unscoped.hasSuffix("-acp") ? String(unscoped.dropLast(4)) : unscoped]
        where isCommandName(name) && !candidates.contains(name) {
            candidates.append(name)
        }
        return candidates
    }

    /// T3 Code's `PackageCommandName`.
    nonisolated static func isCommandName(_ name: String) -> Bool {
        name.count <= 128 && name.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `name` on the environment's PATH.
    nonisolated static func which(_ name: String, in environment: [String: String]) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The folder of the toolchain a package manager belongs to, for PATH (T3 Code's `managerBinDirectory`): a link
    /// named like its target (a version manager's shim) points at it; otherwise the manager's own folder.
    nonisolated static func managerDirectory(_ manager: URL) -> URL {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: manager.path) else {
            return manager.deletingLastPathComponent()
        }
        let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target) : manager.deletingLastPathComponent().appendingPathComponent(target)
        return resolved.lastPathComponent == manager.lastPathComponent
            ? resolved.deletingLastPathComponent().standardizedFileURL : manager.deletingLastPathComponent()
    }

    private nonisolated static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            .map { String($0.prefix(300)) }
    }

    // MARK: Cleaning up

    /// Removes installed versions no agent uses (`referenced`, as `agent/version`) and no running process holds
    /// (`inUse`, version folders), and staging folders an interrupted install left behind.
    nonisolated func removeUnused(referenced: Set<String>, inUse: Set<String>, stagingOlderThan age: TimeInterval = 6 * 60 * 60) {
        let manager = FileManager.default
        let inUse = Set(inUse.map { AntigravityPaths.canonicalPath(URL(fileURLWithPath: $0)) })
        for agent in (try? manager.contentsOfDirectory(atPath: paths.toolsDirectory.path)) ?? [] where ACPRegistryIndex.isValidAgentID(agent) {
            let agentDirectory = paths.agentDirectory(agent)
            for name in (try? manager.contentsOfDirectory(atPath: agentDirectory.path)) ?? [] {
                let url = agentDirectory.appendingPathComponent(name)
                if name.hasPrefix(".install-") {
                    let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
                    if Date().timeIntervalSince(modified) > age { try? manager.removeItem(at: url) }
                    continue
                }
                guard ACPRegistryIndex.isValidVersion(name), !referenced.contains("\(agent)/\(name)"),
                    !inUse.contains(AntigravityPaths.canonicalPath(url))
                else { continue }
                try? manager.removeItem(at: url)
            }
            if (try? manager.contentsOfDirectory(atPath: agentDirectory.path))?.isEmpty == true {
                try? manager.removeItem(at: agentDirectory)
            }
        }
    }
}

/// Writes a registry download as it streams, hashing it on the way, and refuses one larger than `maxBytes` (also
/// from its Content-Length) or one that won't fit on the disk.
final class ACPRegistryArchiveSink: AntigravityDownloadSink, @unchecked Sendable {
    private let maxBytes: Int64
    private let freeSpace: @Sendable () -> Int64?
    private let progress: @Sendable (ACPRegistryInstallProgress) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var expected: Int64?
    private var lastReport = Date.distantPast

    nonisolated init(
        file: URL, maxBytes: Int64, freeSpace: @escaping @Sendable () -> Int64?,
        progress: @escaping @Sendable (ACPRegistryInstallProgress) -> Void
    ) throws {
        self.maxBytes = maxBytes
        self.freeSpace = freeSpace
        self.progress = progress
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ACPRegistryInstallError(String(localized: "Couldn’t save the download.")) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    nonisolated func receive(response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw ACPRegistryInstallError(String(localized: "The download server answered with HTTP \(response.statusCode). Try again later."))
        }
        let encoding = (response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").trimmingCharacters(in: .whitespaces).lowercased()
        guard encoding.isEmpty || encoding == "identity", let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        else { return }
        guard length <= maxBytes else {
            throw ACPRegistryInstallError(String(localized: "The download is larger than Coincide accepts for an agent."))
        }
        // Room for the archive and what it unpacks to.
        if let available = freeSpace(), available < length * 3 + 64 * 1_024 * 1_024 {
            let megabytes = (length * 3 + 64 * 1_024 * 1_024 + 1_048_575) / 1_048_576
            throw ACPRegistryInstallError(String(localized: "The agent needs at least \(megabytes) MB of free space to install."))
        }
        lock.withLock { expected = length }
    }

    nonisolated func receive(_ data: Data) throws {
        let (total, expected, report) = try lock.withLock { () -> (Int64, Int64?, Bool) in
            received += Int64(data.count)
            guard received <= maxBytes else {
                throw ACPRegistryInstallError(String(localized: "The download is larger than Coincide accepts for an agent."))
            }
            hasher.update(data: data)
            do {
                try handle?.write(contentsOf: data)
            } catch {
                throw ACPRegistryInstallError(String(localized: "Couldn’t save the download. Check free disk space."))
            }
            let now = Date()
            let report = now.timeIntervalSince(lastReport) >= 0.25
            if report { lastReport = now }
            return (received, self.expected, report)
        }
        if report { progress(.downloading(bytes: total, total: expected)) }
    }

    nonisolated func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    /// The download's SHA-256, once it is complete on disk.
    nonisolated func finish() throws -> String {
        try lock.withLock {
            do {
                try handle?.close()
            } catch {
                throw ACPRegistryInstallError(String(localized: "Couldn’t save the download. Check free disk space."))
            }
            handle = nil
            if let expected, received != expected {
                throw ACPRegistryInstallError(String(localized: "The download was incomplete. Try again."))
            }
            return AntigravityInstaller.hex(hasher.finalize())
        }
    }
}
