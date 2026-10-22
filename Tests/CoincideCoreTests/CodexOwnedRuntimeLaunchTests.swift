import Foundation
import Testing
@testable import CoincideCore

private let codexLaunchInstant = Date(timeIntervalSince1970: 1_800_000_000)
private func codexLaunchLayout() -> CodexHomeLayout.Prepared {
    // An already prepared value is the input contract. No filesystem is touched by these tests.
    .init(sharedHome: URL(fileURLWithPath: "/task-owned/shared home", isDirectory: true),
          effectiveHome: URL(fileURLWithPath: "/task-owned/private overlay", isDirectory: true),
          continuationIdentity: "codex:home:/task-owned/shared home", preservedRuntimeEntries: [])
}
private func codexLaunchCredential(access: String = "synthetic-owned-access", refresh: String? = "synthetic-owned-refresh",
                                   idToken: String? = "synthetic-owned-id", clientID: String = "oaiapp_synthetic",
                                   issuer: String = "https://auth.openai.com", expiration: Date = codexLaunchInstant.addingTimeInterval(60),
                                   earliest: Date? = nil, scopes: [String] = [CodexOAuthClient.requiredScope], subject: String = "synthetic-subject") -> CodexOAuthCredential {
    .init(clientID: clientID, accessToken: access, refreshToken: refresh, idToken: idToken, issuer: URL(string: issuer)!,
          expiresAt: expiration, earliestRefreshAt: earliest, scopes: scopes,
          identity: .init(subject: subject, email: "synthetic@example.invalid"))
}

@Test func codexOwnedRuntimeLaunchUsesAllElevenExactLiteralPinnedOverrides() throws {
    let layout = codexLaunchLayout(), credential = codexLaunchCredential()
    let launch = try CodexOwnedRuntimeLaunch.make(layout: layout, credential: credential, baseEnvironment: [:], now: codexLaunchInstant)
    let expected = [
        "app-server", "--stdio",
        "-c", "model_provider=\"openai_token_sharing\"",
        "-c", "model_providers.openai_token_sharing.name=\"OpenAI Token Sharing\"",
        "-c", "model_providers.openai_token_sharing.base_url=\"https://api.openai.com/v1\"",
        "-c", "model_providers.openai_token_sharing.model_catalog_url=\"https://api.openai.com/v1/models\"",
        "-c", "features.api_key_model_discovery=true",
        "-c", "features.multi_agent=false",
        "-c", "features.multi_agent_v2=false",
        "-c", "model_providers.openai_token_sharing.env_key=\"ACCESS_TOKEN\"",
        "-c", "model_providers.openai_token_sharing.wire_api=\"responses\"",
        "-c", "model_providers.openai_token_sharing.requires_openai_auth=false",
        "-c", "model_providers.openai_token_sharing.supports_websockets=false",
    ]
    #expect(launch.arguments == expected)
    #expect(launch.arguments.count == 24)
    #expect(launch.environment == ["ACCESS_TOKEN": credential.accessToken, "CODEX_HOME": layout.effectiveHome.path])
    #expect(launch.continuationIdentity == layout.continuationIdentity)
    #expect(!launch.arguments.joined().contains(credential.accessToken) && !launch.arguments.joined().contains(credential.refreshToken!))
    #expect(!launch.arguments.contains { $0.hasPrefix("'") || $0.hasSuffix("'") }, "Shell quoting must not become part of native argv.")
}

@Test func codexOwnedRuntimeLaunchCopiesAndScrubsOnlyTheChildEnvironmentWithoutUsingAmbientLaunchArgs() throws {
    let original = ["PATH": "/synthetic/bin", "HOME": "/synthetic/user", "KEEP": "$(literal); quoted ' content",
                    "ACCESS_TOKEN": "unrelated ambient token", "CODEX_HOME": "/other/home",
                    "T3CODE_CODEX_LAUNCH_ARGS": "-c model_providers.openai_token_sharing.base_url='https://wrong.invalid'",
                    "OPENAI_API_KEY": "synthetic ambient key", "OPENAI_BASE_URL": "https://wrong.invalid"]
    let before = original, layout = codexLaunchLayout()
    let launch = try CodexOwnedRuntimeLaunch.make(layout: layout, credential: codexLaunchCredential(), baseEnvironment: original, now: codexLaunchInstant)
    #expect(original == before)
    #expect(launch.environment["PATH"] == original["PATH"] && launch.environment["HOME"] == original["HOME"] && launch.environment["KEEP"] == original["KEEP"])
    #expect(launch.environment["ACCESS_TOKEN"] == "synthetic-owned-access" && launch.environment["CODEX_HOME"] == layout.effectiveHome.path)
    for name in ["T3CODE_CODEX_LAUNCH_ARGS", "OPENAI_API_KEY", "OPENAI_BASE_URL"] { #expect(launch.environment[name] == nil) }
    #expect(!launch.arguments.joined().contains("wrong.invalid") && !launch.arguments.joined().contains("synthetic ambient key"))
    #expect(!launch.arguments.contains(layout.effectiveHome.path), "Private home belongs in the child's environment.")
    #expect(launch.continuationIdentity.contains(layout.sharedHome.path) && !launch.continuationIdentity.contains(layout.effectiveHome.path))
}

@Test func codexOwnedRuntimeLaunchNeverRevealsEnvironmentOrIdentityThroughDescriptionsOrMirrors() throws {
    let launch = try CodexOwnedRuntimeLaunch.make(layout: codexLaunchLayout(), credential: codexLaunchCredential(),
                                                 baseEnvironment: ["OTHER_SECRET": "synthetic-other-secret"], now: codexLaunchInstant)
    #expect(String(describing: launch) == "CodexOwnedRuntimeLaunch(redacted)")
    #expect(String(reflecting: launch) == "CodexOwnedRuntimeLaunch(redacted)")
    #expect(Mirror(reflecting: launch).children.isEmpty)
    var dumpText = ""; dump(launch, to: &dumpText)
    for privateText in ["synthetic-owned-access", "synthetic-owned-refresh", "synthetic-owned-id", "synthetic-other-secret", "shared home", "private overlay"] {
        #expect(!dumpText.contains(privateText))
    }
}

@Test func codexOwnedRuntimeLaunchRejectsExpiredTokensAtTheExactBoundaryAndMissingSharing() throws {
    for expiration in [codexLaunchInstant.addingTimeInterval(-1), codexLaunchInstant] {
        #expect(throws: CodexOwnedRuntimeLaunchError.expiredCredential) {
            try CodexOwnedRuntimeLaunch.make(layout: codexLaunchLayout(), credential: codexLaunchCredential(expiration: expiration), baseEnvironment: [:], now: codexLaunchInstant)
        }
    }
    #expect(throws: CodexOwnedRuntimeLaunchError.sharingRequired) {
        try CodexOwnedRuntimeLaunch.make(layout: codexLaunchLayout(), credential: codexLaunchCredential(scopes: ["openid", "offline_access"]), baseEnvironment: [:], now: codexLaunchInstant)
    }
    // Refresh eligibility is handled by the vault; valid access remains usable while refresh is delayed.
    let valid = codexLaunchCredential(refresh: nil, idToken: nil, expiration: codexLaunchInstant.addingTimeInterval(1), earliest: codexLaunchInstant.addingTimeInterval(120))
    let launch = try CodexOwnedRuntimeLaunch.make(layout: codexLaunchLayout(), credential: valid, baseEnvironment: [:], now: codexLaunchInstant)
    #expect(launch.environment["ACCESS_TOKEN"] == valid.accessToken)
}

@Test func codexOwnedRuntimeLaunchRejectsMalformedCredentialsBeforeProducingAnEnvironment() throws {
    let invalid = [codexLaunchCredential(access: ""), codexLaunchCredential(access: "   "), codexLaunchCredential(access: "synthetic\nprivate"),
                   codexLaunchCredential(access: String(repeating: "x", count: 65_537)), codexLaunchCredential(clientID: "other-client"),
                   codexLaunchCredential(issuer: "https://wrong.invalid"), codexLaunchCredential(subject: ""),
                   codexLaunchCredential(scopes: [CodexOAuthClient.requiredScope, CodexOAuthClient.requiredScope]),
                   codexLaunchCredential(expiration: Date(timeIntervalSince1970: .infinity)), codexLaunchCredential(earliest: Date(timeIntervalSince1970: .nan))]
    for credential in invalid {
        #expect(throws: CodexOwnedRuntimeLaunchError.invalidCredential) {
            try CodexOwnedRuntimeLaunch.make(layout: codexLaunchLayout(), credential: credential, baseEnvironment: [:], now: codexLaunchInstant)
        }
    }
    #expect(throws: CodexOwnedRuntimeLaunchError.invalidCredential) {
        try CodexOwnedRuntimeLaunch.make(layout: codexLaunchLayout(), credential: codexLaunchCredential(), baseEnvironment: [:], now: Date(timeIntervalSince1970: .nan))
    }
}

@Test func codexOwnedRuntimeLaunchRejectsInvalidLayoutValuesWithoutPerformingFilesystemWork() throws {
    let shared = URL(fileURLWithPath: "/synthetic/shared")
    let invalid = [
        CodexHomeLayout.Prepared(sharedHome: shared, effectiveHome: shared, continuationIdentity: "codex:home:/synthetic/shared", preservedRuntimeEntries: []),
        .init(sharedHome: shared, effectiveHome: URL(string: "https://wrong.invalid/home")!, continuationIdentity: "codex:home:/synthetic/shared", preservedRuntimeEntries: []),
        .init(sharedHome: shared, effectiveHome: URL(fileURLWithPath: "/synthetic/overlay"), continuationIdentity: "not-a-shared-continuation", preservedRuntimeEntries: []),
        .init(sharedHome: shared, effectiveHome: URL(fileURLWithPath: "/synthetic/overlay"), continuationIdentity: "codex:home:/synthetic/another-account", preservedRuntimeEntries: []),
    ]
    for layout in invalid {
        #expect(throws: CodexOwnedRuntimeLaunchError.invalidLayout) {
            try CodexOwnedRuntimeLaunch.make(layout: layout, credential: codexLaunchCredential(), baseEnvironment: [:], now: codexLaunchInstant)
        }
    }
}
