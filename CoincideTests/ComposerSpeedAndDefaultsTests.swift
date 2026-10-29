import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
private final class SpeedProvider: AgentProvider {
    let kind = ProviderKind.claude
    let executableNames = ["sh"]
    let setupHint = ""
    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [
            ModelOption(
                provider: .claude, modelID: "opus", displayName: "Opus", efforts: ["low", "high"], defaultEffort: "high",
                speeds: [.fast]),
            ModelOption(provider: .claude, modelID: "haiku", displayName: "Haiku", efforts: ["low", "high"], defaultEffort: "low"),
        ]
    }
    func makeSession(_ launch: AgentLaunch) -> AgentSession { fatalError("Composer tests never start a session") }
}

/// The composer's speed control, and how the last choice in a composer becomes the default for new threads.
@MainActor @Suite(.serialized)
struct ComposerSpeedAndDefaultsTests {
    private let opus = ModelOption(provider: .claude, modelID: "opus", displayName: "Opus", speeds: [.fast])
    private let haiku = ModelOption(provider: .claude, modelID: "haiku", displayName: "Haiku")

    // MARK: Speed control

    @Test func theSpeedControlShowsOnlyForModelsWithAFasterSpeed() {
        #expect(ComposerSpeedControl(model: nil, speed: nil) == nil)
        #expect(ComposerSpeedControl(model: haiku, speed: nil) == nil)
        #expect(ComposerSpeedControl(model: haiku, speed: "fast") == nil)

        let standard = ComposerSpeedControl(model: opus, speed: nil)
        #expect(standard != nil && standard?.selected == nil)
        #expect(standard?.title == "Standard")
        #expect(standard?.symbolName == ComposerSpeedControl.standardSymbol)

        let fast = ComposerSpeedControl(model: opus, speed: "fast")
        #expect(fast?.selected == .fast)
        #expect(fast?.title == "Fast")
        #expect(fast?.symbolName == ComposerSpeedControl.fastSymbol)

        // A speed the model stopped offering runs, and shows, as standard.
        #expect(ComposerSpeedControl(model: opus, speed: "ultrafast")?.selected == nil)
    }

    @Test func switchingModelsKeepsTheSpeedOnlyWhenTheNewModelOffersIt() {
        #expect(ComposerSpeedControl.carried("fast", to: opus) == "fast")
        #expect(ComposerSpeedControl.carried("fast", to: haiku) == nil)
        #expect(ComposerSpeedControl.carried("fast", to: nil) == nil)
        #expect(ComposerSpeedControl.carried(nil, to: opus) == nil)
    }

    @Test func theSpeedMenuListsStandardFirstAndChecksTheCurrentSpeed() {
        let target = NSObject()
        let menu = ComposerMenus.speedMenu(model: opus, current: "fast", target: target, action: #selector(NSObject.copy))
        let items = menu.items.filter { !$0.isSectionHeader }
        #expect(items.map(\.title) == ["Standard", "Fast"])
        #expect(items.map(\.state) == [.off, .on])
        #expect(items[0].representedObject == nil)
        #expect(items[1].representedObject as? String == "fast")
        let standard = ComposerMenus.speedMenu(model: opus, current: nil, target: target, action: #selector(NSObject.copy))
        #expect(standard.items.filter { !$0.isSectionHeader }.map(\.state) == [.on, .off])
    }

    @Test func theFooterSpeedControlFollowsTheModelAndFallsBackToStandard() async throws {
        let setup = try await Setup()
        let thread = setup.store.createThread(in: setup.project.id, selection: ModelSelection(provider: .claude, modelID: "opus"))
        let composer = setup.composer(for: thread.id)
        let speedButton = composer.footer.speedButton
        #expect(!speedButton.isHidden)
        #expect(speedButton.accessibilityLabel() == "Speed: Standard")

        composer.setSpeed("fast")
        #expect(setup.store.thread(thread.id)?.selection.speed == "fast")
        #expect(speedButton.accessibilityLabel() == "Speed: Fast")
        // A speed the model doesn't offer is ignored.
        composer.setSpeed("ultrafast")
        #expect(setup.store.thread(thread.id)?.selection.speed == "fast")

        composer.select(ModelSelection(provider: .claude, modelID: "haiku"))
        #expect(setup.store.thread(thread.id)?.selection.speed == nil)
        #expect(speedButton.isHidden)

        // Back on a model with fast mode, the thread runs at standard until the user picks fast again.
        composer.select(ModelSelection(provider: .claude, modelID: "opus"))
        #expect(setup.store.thread(thread.id)?.selection.speed == nil)
        #expect(!speedButton.isHidden)
        #expect(speedButton.accessibilityLabel() == "Speed: Standard")
    }

    // MARK: Defaults for new threads

    @Test func newThreadsStartWithTheLastChoiceMadeInAComposer() async throws {
        let setup = try await Setup()
        let store = setup.store
        let other = store.createThread(in: setup.project.id)
        let otherSelection = other.selection
        let thread = store.createThread(in: setup.project.id)
        let composer = setup.composer(for: thread.id)

        composer.select(ModelSelection(provider: .claude, modelID: "opus"))
        composer.setEffort("low")
        composer.setSpeed("fast")
        composer.setAccessMode(.approval)
        let chosen = ModelSelection(provider: .claude, modelID: "opus", effort: "low", speed: "fast")
        #expect(store.settings.defaultSelection == chosen)
        #expect(store.settings.defaultAccessMode == .approval)

        // Project threads and projectless chats both start with it.
        let next = store.createThread(in: setup.project.id)
        #expect(next.selection == chosen && next.accessMode == .approval)
        let chat = store.createThread(in: store.ensureChatsProject().id)
        #expect(chat.selection == chosen && chat.accessMode == .approval)

        // Other existing threads keep their own selection.
        #expect(store.thread(other.id)?.selection == otherSelection)
        #expect(store.thread(other.id)?.accessMode == other.accessMode)

        // A later choice moves the default without changing threads made from the earlier one.
        composer.select(ModelSelection(provider: .claude, modelID: "haiku"))
        composer.setAccessMode(.fullAccess)
        #expect(store.settings.defaultSelection.modelID == "haiku")
        #expect(store.settings.defaultSelection.speed == nil)
        #expect(store.settings.defaultAccessMode == .fullAccess)
        #expect(store.thread(next.id)?.selection == chosen && store.thread(next.id)?.accessMode == .approval)
        #expect(store.thread(chat.id)?.selection == chosen && store.thread(chat.id)?.accessMode == .approval)
    }

    @Test func aProjectsOwnDefaultsStillWinOverTheLastChoice() async throws {
        let setup = try await Setup()
        let store = setup.store
        let explicit = ProjectThreadDefaults(
            selection: ModelSelection(provider: .claude, modelID: "haiku", effort: "high"), accessMode: .approval,
            interactionMode: .plan)
        store.updateProject(setup.project.id) { $0.threadDefaults = explicit }
        let thread = store.createThread(in: setup.project.id)
        let composer = setup.composer(for: thread.id)
        composer.select(ModelSelection(provider: .claude, modelID: "opus"))
        composer.setSpeed("fast")
        composer.setAccessMode(.fullAccess)

        #expect(store.newThreadDefaults(in: setup.project.id) == explicit)
        let next = store.createThread(in: setup.project.id)
        #expect(next.selection == explicit.selection && next.accessMode == .approval)
        // Elsewhere the choice is the default.
        let chat = store.createThread(in: store.ensureChatsProject().id)
        #expect(chat.selection.modelID == "opus" && chat.selection.speed == "fast" && chat.accessMode == .fullAccess)
    }

    @Test func changesTheAppMakesOnItsOwnLeaveTheDefaultAlone() async throws {
        let setup = try await Setup()
        let store = setup.store
        let before = (store.settings.defaultSelection, store.settings.defaultAccessMode)
        let thread = store.createThread(in: setup.project.id)
        let composer = setup.composer(for: thread.id)
        // Such as a handoff falling back to another model, or a scheduled run picking a usable one.
        store.updateThread(thread.id) {
            $0.selection = ModelSelection(provider: .claude, modelID: "opus", speed: "fast")
            $0.accessMode = .approval
        }
        #expect(store.settings.defaultSelection == before.0 && store.settings.defaultAccessMode == before.1)
        // Picking what the thread already has changes nothing, so it isn't a new choice either.
        composer.setSpeed("fast")
        composer.setAccessMode(.approval)
        #expect(store.settings.defaultSelection == before.0 && store.settings.defaultAccessMode == before.1)
    }

    // MARK: Setup

    private struct Setup {
        let directory = TemporaryDirectory("composer-speed")
        let store: AppStore
        let registry: ProviderRegistry
        let runner: ThreadRunner
        let project: Project

        init() async throws {
            store = AppStore(directory: directory.url)
            registry = ProviderRegistry(store: store, providers: [SpeedProvider()])
            await registry.refresh()
            runner = ThreadRunner(store: store, registry: registry)
            project = store.addProject(at: directory.url.appendingPathComponent("project"))
        }

        func composer(for threadID: UUID) -> ComposerViewController {
            let composer = ComposerViewController(store: store, registry: registry, runner: runner)
            _ = composer.view
            composer.threadID = threadID
            return composer
        }
    }
}
