import Foundation

/// Installation verification uses only initialization in a fresh owned profile.
/// It never authenticates, opens a browser, lists models or sends a prompt.
public enum AntigravityInstallationVerifier {
    public static func verify(release: AntigravityManagedRelease, pair: AntigravityExecutablePair, scratch: URL) async throws {
        try release.validate(); try Task.checkCancellation()
        let manager = FileManager.default
        let work = scratch.appendingPathComponent("verify-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        let cwd = work.appendingPathComponent("workspace", isDirectory: true)
        try manager.createDirectory(at: cwd, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = AntigravityConfiguration(instanceID: UUID(), executable: pair.executable.path,
            harnessPath: pair.harness.path, authGeneration: UUID())
        let runtime: AntigravityRuntime
        do {
            runtime = try AntigravityRuntime(validatedPair: pair, lease: nil, configuration: configuration,
                cwd: cwd, stateRoot: work.appendingPathComponent("state", isDirectory: true))
        } catch { throw AntigravityInstallationError(.verificationFailed) }
        let connection = try AntigravityConnection(runtime: runtime)
        let reader = Task {
            for await event in connection.events {
                switch event {
                case .callback(let callback): await callback()
                case .serverRequest(let id, _, _): try? await connection.reject(id: id)
                default: break
                }
            }
        }
        do {
            try await withTaskCancellationHandler {
                let value = try await connection.initialize(timeout: .seconds(90))
                try validate(value, release: release)
                try Task.checkCancellation()
            } onCancel: { Task { await connection.close() } }
            await connection.close(); await runtime.close(); reader.cancel(); await reader.value
            try Task.checkCancellation()
        } catch {
            await connection.close(); await runtime.close(); reader.cancel(); await reader.value
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AntigravityInstallationError(.verificationFailed)
        }
    }
    static func validate(_ value: JSONValue, release: AntigravityManagedRelease) throws {
        guard value["agentInfo"]["name"] == .string("antigravity-acp"),
              value["agentInfo"]["version"] == .string(release.version),
              [JSONValue.number(1), .number(2)].contains(value["protocolVersion"]),
              value["agentCapabilities"]["loadSession"] == .bool(true),
              capability(value["agentCapabilities"]["sessionCapabilities"]["resume"]),
              capability(value["agentCapabilities"]["auth"]["logout"]),
              value["authMethods"].array?.contains(where: { $0["id"] == .string("oauth-personal") }) == true else {
            throw AntigravityInstallationError(.verificationFailed)
        }
    }
    private static func capability(_ value: JSONValue) -> Bool {
        value.object != nil || value == .bool(true)
    }
}
