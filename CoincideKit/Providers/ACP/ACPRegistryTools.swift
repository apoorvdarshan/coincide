import Foundation
import Observation

/// Coincide's installs of registry agents: runs installations (one per agent at a time) and reports their progress,
/// keeps a version in place while a process runs from it, and removes versions no agent uses any more (T3 Code
/// removes an agent's managed files with its last provider instance).
@MainActor
@Observable
public final class ACPRegistryTools {
    public static let shared = ACPRegistryTools()

    /// Where an installation stands.
    public struct InstallState: Sendable, Hashable {
        public enum Phase: Sendable, Hashable {
            case downloading
            case extracting
            case installingPackage
        }

        public var phase: Phase
        public var downloadedBytes: Int64 = 0
        public var totalBytes: Int64?
    }

    /// Installations that run now, by registry agent id.
    public private(set) var installs: [String: InstallState] = [:]

    @ObservationIgnored public let paths: ACPRegistryPaths
    @ObservationIgnored private let installer: ACPRegistryInstaller
    /// Processes running from each version folder.
    @ObservationIgnored private var leases: [String: Int] = [:]
    /// The versions to keep, from a cleanup that waits for processes to end.
    @ObservationIgnored private var pendingCleanup: Set<String>?

    public init(paths: ACPRegistryPaths = .standard, installer: ACPRegistryInstaller? = nil) {
        self.paths = paths
        self.installer = installer ?? ACPRegistryInstaller(paths: paths)
    }

    public func isInstalling(_ agentID: String) -> Bool { installs[agentID] != nil }

    /// Installs `agent` (see `ACPRegistryInstaller`) and returns what sessions launch from. `environment` is the
    /// login shell's.
    public func install(
        _ agent: ACPRegistryAgent, _ distribution: ACPRegistryResolvedDistribution, environment: [String: String]
    ) async throws -> ACPRegistryInstall {
        guard installs[agent.id] == nil else {
            throw ACPRegistryInstallError(String(localized: "\(agent.name) is already being installed."))
        }
        installs[agent.id] = InstallState(phase: distribution.kind == .binary ? .downloading : .installingPackage)
        defer { installs[agent.id] = nil }
        let id = agent.id
        let report: @Sendable (ACPRegistryInstallProgress) -> Void = { progress in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(progress, to: id) } }
        }
        // A version folder being written is in use, so a cleanup meanwhile leaves it alone.
        let folder = paths.versionDirectory(agent.id, agent.version).path
        leases[folder, default: 0] += 1
        defer { release(folder) }
        let install = try await installer.install(agent, distribution, environment: environment, progress: report)
        // A cleanup waiting for processes to end keeps what was just installed for the agent about to use it.
        pendingCleanup?.insert("\(install.agentID)/\(install.version)")
        return install
    }

    /// Keeps the version `executable` runs from until the lease is released. Nil outside Coincide's installs.
    public func lease(for executable: URL) -> ACPLaunchLease? {
        guard let folder = versionFolder(of: executable) else { return nil }
        leases[folder, default: 0] += 1
        return ACPLaunchLease { [weak self] in self?.release(folder) }
    }

    /// Removes installed versions none of `agents` uses, now or once the processes running from them end.
    public func removeUnused(keeping agents: [ACPAgentConfig]) {
        let referenced = Set(agents.compactMap { agent in agent.registry.map { "\($0.agentID)/\($0.version)" } })
        pendingCleanup = referenced
        runCleanup()
    }

    private func runCleanup() {
        guard let referenced = pendingCleanup else { return }
        let inUse = Set(leases.keys)
        // Versions in use are removed by the cleanup that runs when their last lease ends.
        if inUse.isEmpty { pendingCleanup = nil }
        let installer = installer
        DispatchQueue.global(qos: .utility).async { installer.removeUnused(referenced: referenced, inUse: inUse) }
    }

    private func release(_ folder: String) {
        let remaining = (leases[folder] ?? 1) - 1
        leases[folder] = remaining > 0 ? remaining : nil
        if remaining <= 0, pendingCleanup != nil { runCleanup() }
    }

    /// `tools/acp/<agent>/<version>` for a file inside it.
    private func versionFolder(of url: URL) -> String? {
        let tools = AntigravityPaths.canonicalPath(paths.toolsDirectory)
        let path = AntigravityPaths.canonicalPath(url)
        guard path.hasPrefix(tools + "/") else { return nil }
        let components = path.dropFirst(tools.count + 1).split(separator: "/")
        guard components.count >= 3 else { return nil }
        return paths.versionDirectory(String(components[0]), String(components[1])).path
    }

    private func apply(_ progress: ACPRegistryInstallProgress, to agentID: String) {
        guard var state = installs[agentID] else { return }
        switch progress {
        case .downloading(let bytes, let total):
            state.phase = .downloading
            state.downloadedBytes = bytes
            state.totalBytes = total
        case .extracting:
            state.phase = .extracting
        case .installingPackage:
            state.phase = .installingPackage
        }
        installs[agentID] = state
    }
}
