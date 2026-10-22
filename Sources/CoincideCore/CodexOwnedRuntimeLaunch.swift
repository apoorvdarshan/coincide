import Foundation

public enum CodexOwnedRuntimeLaunchError: Error, Sendable, Equatable, LocalizedError {
    case invalidLayout, invalidCredential, expiredCredential, sharingRequired
    public var errorDescription: String? {
        switch self {
        case .invalidLayout: "The private Codex home has not been prepared safely."
        case .invalidCredential: "The owned ChatGPT credential is invalid. Reconnect before continuing."
        case .expiredCredential: "The owned ChatGPT credential has expired. Renew it before continuing."
        case .sharingRequired: "Enable ChatGPT token sharing before starting owned Codex."
        }
    }
}

/// A transient child-process launch value, never workspace configuration or a command fingerprint.
/// The caller owns credential admission, the already prepared home, and runtime drain/lifetime.
/// Constructing this value performs no filesystem, process, authentication, or network operation.
public struct CodexOwnedRuntimeLaunch: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let arguments: [String]
    public let environment: [String: String]
    public let continuationIdentity: String

    public static func make(layout: CodexHomeLayout.Prepared, credential: CodexOAuthCredential,
                            baseEnvironment: [String: String], now: Date = Date()) throws -> CodexOwnedRuntimeLaunch {
        guard cleanHome(layout.sharedHome), cleanHome(layout.effectiveHome), layout.sharedHome.path != layout.effectiveHome.path,
              layout.continuationIdentity == "codex:home:" + layout.sharedHome.path, layout.continuationIdentity.utf8.count <= 4_107,
              !layout.continuationIdentity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CodexOwnedRuntimeLaunchError.invalidLayout
        }
        guard CodexOAuthParsing.clientID(credential.clientID), credential.issuer.absoluteString == "https://auth.openai.com",
              CodexOAuthParsing.text(credential.accessToken, maximum: 65_536),
              !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credential.refreshToken.map({ CodexOAuthParsing.text($0, maximum: 65_536) }) ?? true,
              credential.idToken.map({ CodexOAuthParsing.text($0, maximum: 65_536) }) ?? true,
              CodexOAuthParsing.text(credential.identity.subject, maximum: 4_096),
              credential.identity.email.map({ CodexOAuthParsing.text($0, maximum: 4_096) }) ?? true,
              credential.expiresAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              credential.earliestRefreshAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              credential.scopes.count <= 128, Set(credential.scopes).count == credential.scopes.count,
              credential.scopes.allSatisfy({ CodexOAuthParsing.text($0, maximum: 256) }) else {
            throw CodexOwnedRuntimeLaunchError.invalidCredential
        }
        guard credential.expiresAt > now else { throw CodexOwnedRuntimeLaunchError.expiredCredential }
        guard credential.permitsDirectUse else { throw CodexOwnedRuntimeLaunchError.sharingRequired }

        // Exact pinned CodexManagedRuntime.ts overrides, represented as literal argv pairs.
        // No shell quoting or ambient launch arguments participate in this destination.
        let overrides = [
            "model_provider=\"openai_token_sharing\"",
            "model_providers.openai_token_sharing.name=\"OpenAI Token Sharing\"",
            "model_providers.openai_token_sharing.base_url=\"https://api.openai.com/v1\"",
            "model_providers.openai_token_sharing.model_catalog_url=\"https://api.openai.com/v1/models\"",
            "features.api_key_model_discovery=true",
            "features.multi_agent=false",
            "features.multi_agent_v2=false",
            "model_providers.openai_token_sharing.env_key=\"ACCESS_TOKEN\"",
            "model_providers.openai_token_sharing.wire_api=\"responses\"",
            "model_providers.openai_token_sharing.requires_openai_auth=false",
            "model_providers.openai_token_sharing.supports_websockets=false",
        ]
        let arguments = ["app-server", "--stdio"] + overrides.flatMap { ["-c", $0] }
        var environment = baseEnvironment
        environment.removeValue(forKey: "T3CODE_CODEX_LAUNCH_ARGS")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "OPENAI_BASE_URL")
        environment["ACCESS_TOKEN"] = credential.accessToken
        environment["CODEX_HOME"] = layout.effectiveHome.path
        return .init(arguments: arguments, environment: environment, continuationIdentity: layout.continuationIdentity)
    }

    private static func cleanHome(_ value: URL) -> Bool {
        guard value.isFileURL, value.host == nil || value.host == "" || value.host == "localhost",
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil else { return false }
        let path = value.path
        return path.hasPrefix("/") && path != "/" && path.utf8.count <= 4_096 &&
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    public var description: String { "CodexOwnedRuntimeLaunch(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
