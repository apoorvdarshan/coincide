import Foundation
import Testing
@testable import CoincideKit

@MainActor
struct AntigravityModelCatalogTests {
    @Test func signingOutDiscardsAnInFlightCatalog() async throws {
        let root = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AntigravityProfile(geminiHome: root.appendingPathComponent("profile"), userHome: root.appendingPathComponent("home"))
        let flavor = AntigravityFlavor(paths: AntigravityPaths(dataDirectory: root), profile: profile)
        let agent = ACPFakeAgent()
        agent.handlers["session/new"] = { id, _ in
            AntigravityModelCatalog.clear(profile)
            agent.reply(id, ["sessionId": "late-session", "models": ["availableModels": [["modelId": "late", "name": "Late model"]]]])
        }
        let result = await AntigravityModelCatalog.refresh(flavor: flavor, executable: root.appendingPathComponent("agy_acp_server.par"),
            environment: [:], transport: agent.factory)
        agent.transport.exit(status: 0, stderr: "")
        #expect(result == nil)
        #expect(AntigravityModelCatalog.cached(profile) == nil)
        #expect(AntigravityFlavor.knownModels[profile.geminiHome.path] == nil)
    }

    @Test func nativeModelsSurviveRestartStayAccountScopedAndClearOnSignOut() throws {
        let root = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AntigravityProfile(geminiHome: root.appendingPathComponent("account-one"))
        let other = AntigravityProfile(geminiHome: root.appendingPathComponent("account-two"))
        let models = [ModelOption(provider: .antigravity, modelID: "native-model", displayName: "Native model")]
        AntigravityModelCatalog.save(models, profile: profile)
        AntigravityFlavor.knownModels[profile.geminiHome.path] = nil // a fresh app/agent host
        #expect(AntigravityFlavor(profile: profile).offlineModels(environment: [:]) == models)
        #expect(AntigravityModelCatalog.cached(other) == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: AntigravityModelCatalog.file(profile).path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        AntigravityModelCatalog.clear(profile)
        #expect(AntigravityModelCatalog.cached(profile) == nil)
        #expect(AntigravityFlavor(profile: profile).offlineModels(environment: [:]).map(\.modelID) == ["antigravity-default"])
    }

    @Test func coldRefreshUsesNativeCatalogWithoutSendingAPromptAndThenReusesIt() async throws {
        let root = try acpTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AntigravityProfile(geminiHome: root.appendingPathComponent("profile"), userHome: root.appendingPathComponent("home"))
        let paths = AntigravityPaths(dataDirectory: root)
        let flavor = AntigravityFlavor(paths: paths, profile: profile)
        let agent = ACPFakeAgent()
        agent.sessionResult = ["sessionId": "catalog-session", "models": ["currentModelId": "actual-id",
            "availableModels": [["modelId": "actual-id", "name": "Account model"]]]]
        let executable = root.appendingPathComponent("agy_acp_server.par")
        let loaded = await AntigravityModelCatalog.refresh(flavor: flavor, executable: executable, environment: [:], transport: agent.factory)
        #expect(loaded?.contains(where: { $0.modelID == "actual-id" }) == true)
        #expect(agent.requests.map(\.method) == ["initialize", "authenticate", "session/new"])
        agent.transport.exit(status: 0, stderr: "")
        let requests = agent.requests.count
        AntigravityFlavor.knownModels[profile.geminiHome.path] = nil
        let cached = await AntigravityModelCatalog.refresh(flavor: flavor, executable: executable, environment: [:], transport: agent.factory)
        #expect(cached == loaded)
        #expect(agent.requests.count == requests)
        AntigravityModelCatalog.clear(profile)
    }
}
