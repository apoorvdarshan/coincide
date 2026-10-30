import Foundation

/// Native ACP model IDs, scoped to the private account profile. The catalog survives app/agent-host restarts;
/// failed refreshes keep it, and signing out removes it. A refresh creates no prompt or billable turn.
@MainActor
enum AntigravityModelCatalog {
    private struct Saved: Codable {
        var checkedAt: Date
        var models: [ModelOption]
    }
    private static var reads: [String: Task<[ModelOption]?, Never>] = [:]
    private static var generations: [String: UUID] = [:]
    static let lifetime: TimeInterval = 6 * 60 * 60

    static func file(_ profile: AntigravityProfile) -> URL {
        profile.geminiHome.appendingPathComponent("coincide-model-catalog.json")
    }

    private static func saved(_ profile: AntigravityProfile) -> Saved? {
        guard let data = try? Data(contentsOf: file(profile)), data.count <= 1_048_576,
            let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.models.isEmpty,
            saved.models.allSatisfy({ $0.provider == .antigravity }) else { return nil }
        return saved
    }

    static func cached(_ profile: AntigravityProfile) -> [ModelOption]? { saved(profile)?.models }

    static func save(_ models: [ModelOption], profile: AntigravityProfile) {
        guard models.contains(where: { $0.modelID != AntigravityFlavor.defaultModelID }) else { return }
        AntigravityFlavor.knownModels[profile.geminiHome.path] = models
        do {
            try FileManager.default.createDirectory(at: profile.geminiHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Saved(checkedAt: Date(), models: models))
            try data.write(to: file(profile), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(profile).path)
        } catch { /* The live catalog still works if the disk cache cannot be saved. */ }
    }

    static func clear(_ profile: AntigravityProfile) {
        let key = profile.geminiHome.path
        generations[key] = UUID()
        reads.removeValue(forKey: key)?.cancel()
        AntigravityFlavor.knownModels[profile.geminiHome.path] = nil
        try? FileManager.default.removeItem(at: file(profile))
    }

    static func refresh(flavor: AntigravityFlavor, executable: URL, environment: [String: String],
        transport: ACPTransportFactory? = nil) async -> [ModelOption]? {
        let profile = flavor.profile
        if let saved = saved(profile), Date().timeIntervalSince(saved.checkedAt) < lifetime { return saved.models }
        let key = profile.geminiHome.path
        if let pending = reads[key] { return await pending.value }
        let generation = UUID()
        generations[key] = generation
        let read = Task { () -> [ModelOption]? in
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-catalog-" + UUID().uuidString)
            var process: AntigravityAgentProcess?
            var sessionID: String?
            defer {
                process?.stop()
                let finished = process
                let id = sessionID
                Task {
                    await finished?.waitForExit(timeout: 5)
                    if let id { profile.removeSessionFiles(sessionID: id, cwd: workspace) }
                    try? FileManager.default.removeItem(at: workspace)
                }
            }
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                try await profile.prepare(environment: environment)
                let runtime = flavor.runtime ?? (flavor.paths.isManaged(executable) ? AntigravityRuntime.shared : nil)
                let running = AntigravityAgentProcess(executable: executable, workingDirectory: workspace,
                    environment: flavor.environment(environment, executable: executable), transport: transport,
                    lease: runtime?.lease(for: executable))
                process = running
                try running.start()
                let initialized = try await running.client.initialize(capabilities: ACPClientCapabilities(),
                    clientInfo: ACPSession.clientInfo, timeout: flavor.initializeTimeout)
                if let method = flavor.authMethodID(environment: environment) {
                    try await running.client.authenticate(methodID: method, timeout: 45)
                }
                let setup = try await running.client.newSession(cwd: workspace, timeout: 60)
                sessionID = setup.sessionID
                let models = flavor.models(initialize: initialized, setup: setup)
                guard !models.isEmpty, !Task.isCancelled, generations[key] == generation else { return nil }
                save(models, profile: profile)
                return models
            } catch { return nil }
        }
        reads[key] = read
        let models = await read.value
        if generations[key] == generation { reads[key] = nil }
        return models
    }
}
