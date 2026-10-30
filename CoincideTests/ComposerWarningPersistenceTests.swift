import AppKit
import CoincideKit
import Testing
@testable import Coincide

@MainActor @Suite(.serialized)
struct ComposerWarningPersistenceTests {
    private final class Provider: AgentProvider {
        let kind: ProviderKind
        let executableNames = ["sh"]
        let setupHint = ""
        var percent: Double = 100
        var reset = Date().addingTimeInterval(3_600)
        init(_ kind: ProviderKind) { self.kind = kind }
        func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
            .init(state: .ready, usageLimits: UsageLimits(windows: [.init(id: "primary", kind: .session, label: "Session",
                usedPercent: percent, resetsAt: reset, continuesOnCredits: true)], checkedAt: Date()))
        }
        func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] { [] }
        func makeSession(_ launch: AgentLaunch) -> AgentSession { fatalError("Warning tests must never send a turn") }
    }

    @Test(arguments: ProviderKind.allCases)
    func dismissOnceHidesItInAnotherThreadAndAfterRestart(provider kind: ProviderKind) async throws {
        let folder = TemporaryDirectory("composer-warning-memory")
        let store = AppStore(directory: folder.url)
        let provider = Provider(kind)
        let registry = ProviderRegistry(store: store, providers: [provider])
        await registry.refresh()
        let runner = ThreadRunner(store: store, registry: registry)
        let project = store.addProject(at: folder.url)
        let first = store.createThread(in: project.id, selection: .init(provider: kind, modelID: "default"))
        let second = store.createThread(in: project.id, selection: .init(provider: kind, modelID: "default"))
        let composer = ComposerViewController(store: store, registry: registry, runner: runner)
        _ = composer.view
        composer.threadID = first.id
        #expect(!composer.usageBanner.isHidden, "The fixture must actually show a warning for \(kind)")
        composer.usageBanner.dismissButton.performClick(nil)
        #expect(composer.usageBanner.isHidden)
        composer.threadID = second.id
        #expect(composer.usageBanner.isHidden)
        provider.reset = Date().addingTimeInterval(7 * 86_400)
        await registry.refresh()
        #expect(composer.usageBanner.isHidden)
        store.flush()
        let reopened = AppStore(directory: folder.url)
        let freshRegistry = ProviderRegistry(store: reopened, providers: [provider])
        await freshRegistry.refresh()
        let fresh = ComposerViewController(store: reopened, registry: freshRegistry, runner: ThreadRunner(store: reopened, registry: freshRegistry))
        _ = fresh.view
        fresh.threadID = second.id
        #expect(fresh.usageBanner.isHidden, "The dismissal must survive an app/store reconstruction for \(kind)")
        #expect(!fresh.footer.usageMeter.isHidden, "Dismissal keeps usage details available")
    }
}
