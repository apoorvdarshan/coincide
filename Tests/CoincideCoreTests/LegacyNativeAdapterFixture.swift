import Foundation
import Testing
@testable import CoincideCore

/// Exercise retained adapter/wire contracts against private synthetic peers.
/// The app's production factory must continue to reject these retired providers.
func makeLegacyNativeAdapterFixtureSession(_ thread: CodingThread) throws -> any ProviderSession {
    #expect(throws: CoincideError.self) { try ProviderSessions.make(for: thread) }
    let cwd = URL(fileURLWithPath: thread.workspacePath)
    func executable(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(temporary.path + "/"), FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CoincideError("Legacy adapter fixtures must use an executable inside their private temporary directory.")
        }
        return url
    }
    switch thread.provider {
    case .opencode:
        let configuration = try #require(thread.openCodeConfiguration)
        let target = try executable(configuration.executable)
        if configuration.generation == .v1 { return OpenCodeV1Session(executable: target, cwd: cwd, configuration: configuration) }
        return OpenCodeV2Session(executable: target, cwd: cwd, configuration: configuration)
    case .pi:
        let configuration = try #require(thread.piConfiguration)
        let target = try executable(configuration.runtime?.executable ?? configuration.executable)
        return PiSession(executable: target, cwd: cwd, configuration: configuration, permission: thread.permission,
            freshIntent: thread.activeRun?.configuration.piFreshSessionIntent,
            historyWorkerRootURL: target.deletingLastPathComponent().appendingPathComponent("legacy-history-workers"))
    case .muse:
        let configuration = try #require(thread.museConfiguration)
        return MuseSession(executable: try executable(configuration.executable), cwd: cwd,
                           configuration: configuration, permission: thread.permission)
    default: throw CoincideError("This provider does not belong to the private legacy native fixture factory.")
    }
}
