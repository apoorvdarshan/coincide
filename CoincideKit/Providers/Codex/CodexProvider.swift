import Foundation

/// The Codex CLI, driven through `codex app-server` (JSON-RPC over stdio) as T3 Code does.
/// Detection, sign-in state and the model catalog all come from the app server itself.
@MainActor
public final class CodexProvider: AgentProvider {
    public let kind: ProviderKind = .codex
    public let executableNames = ["codex"]
    public let setupHint = String(localized: "Install the Codex CLI and run `codex login`.")

    /// Models from the last probe, reused by `models` right after `detect`.
    private var probedModels: [ModelOption]?

    public init() {}

    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else { return ProviderStatus(state: .notInstalled, message: setupHint) }
        do {
            let probe = try await CodexProbe.run(executable: executable, environment: environment)
            probedModels = probe.models
            return CodexProtocol.providerStatus(account: probe.account, version: probe.version, executable: executable)
        } catch {
            probedModels = nil
            let output = await ProcessRunner.run(executable, ["--version"], environment: environment, timeout: 20)
            let version = output.succeeded ? CodexProtocol.version(fromVersionOutput: output.stdout) : nil
            if case .unsupported(let message) = CodexProtocol.versionCompatibility(version) {
                return ProviderStatus(state: .error, version: version, executable: executable, message: message)
            }
            return ProviderStatus(
                state: .error, version: version, executable: executable,
                message: String(localized: "Could not start the Codex app server: \(error.localizedDescription)"))
        }
    }

    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        if let probedModels, !probedModels.isEmpty { return probedModels }
        if status.state == .ready, let executable = status.executable,
            let models = try? await CodexProbe.run(executable: executable, environment: environment).models,
            !models.isEmpty
        {
            probedModels = models
            return models
        }
        return CodexProtocol.builtInModels
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        CodexSession(launch: launch)
    }
}

/// A short-lived app server that reports the version, the account and the model catalog.
@MainActor
enum CodexProbe {
    struct Snapshot {
        var version: String?
        /// The `account/read` result.
        var account: JSONValue
        /// Nil when signed out (as in T3 Code) or when the catalog could not be read.
        var models: [ModelOption]?
    }

    static func run(executable: URL, environment: [String: String]) async throws -> Snapshot {
        let transport = CodexProcessTransport(
            executable: executable, workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: environment)
        let connection = CodexConnection(transport: transport)
        try connection.start()
        defer { connection.close() }
        let initialize = try await connection.request("initialize", CodexProtocol.initializeParams(), timeout: .seconds(45))
        connection.notify("initialized")
        let version = initialize["userAgent"]?.string.flatMap(CodexProtocol.version(fromUserAgent:))
        let account = try await connection.request("account/read", [:], timeout: .seconds(30))
        var models: [ModelOption]?
        let signedIn = account["account"].map { !$0.isNull } ?? false
        if signedIn || account["requiresOpenaiAuth"]?.bool == false {
            models = try? await modelList(connection)
        }
        return Snapshot(version: version, account: account, models: models)
    }

    /// Every page of `model/list`, in picker order.
    static func modelList(_ connection: CodexConnection) async throws -> [ModelOption] {
        var entries: [JSONValue] = []
        var cursor: String?
        repeat {
            let params: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
            let page = try await connection.request("model/list", params, timeout: .seconds(15))
            entries += page["data"]?.array ?? []
            cursor = page["nextCursor"]?.string
        } while cursor != nil && entries.count < 1_000
        return CodexProtocol.models(fromEntries: entries)
    }
}
