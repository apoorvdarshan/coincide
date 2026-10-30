import AppKit
import CoincideRemoteKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
private final class SpeedProvider: AgentProvider {
    let kind: ProviderKind
    init(kind: ProviderKind = .claude) { self.kind = kind }
    let executableNames = ["sh"]
    let setupHint = ""
    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [
            ModelOption(
                provider: kind, modelID: "opus", displayName: "Opus", efforts: ["low", "high"], defaultEffort: "high",
                speeds: [.fast]),
            ModelOption(provider: kind, modelID: "haiku", displayName: "Haiku", efforts: ["low", "high"], defaultEffort: "low"),
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

        // Back on a model with fast mode, the provider's desired speed returns.
        composer.select(ModelSelection(provider: .claude, modelID: "opus"))
        #expect(setup.store.thread(thread.id)?.selection.speed == "fast")
        #expect(!speedButton.isHidden)
        #expect(speedButton.accessibilityLabel() == "Speed: Fast")
        composer.setSpeed(nil)
        composer.select(ModelSelection(provider: .claude, modelID: "haiku"))
        composer.select(ModelSelection(provider: .claude, modelID: "opus"))
        #expect(setup.store.thread(thread.id)?.selection.speed == nil)
        #expect(speedButton.accessibilityLabel() == "Speed: Standard")
    }

    @Test func desktopAndRemoteControlsRestoreTheSameProviderAccountChoices() async throws {
        let setup = try await Setup()
        let store = setup.store
        let thread = store.createThread(
            in: setup.project.id, selection: ModelSelection(provider: .claude, modelID: "opus", effort: "low", speed: "fast"))
        let composer = setup.composer(for: thread.id)
        let remote = RemoteStoreAdapter(
            store: store, runner: setup.runner, registry: setup.registry, services: RemoteSessionTests.services(store: store))
        // The same native tokens on another provider do not make the outgoing provider's choices apply there.
        try remote.updateSettings(RemoteThreadSettings(threadID: thread.id, provider: "codex", modelID: "opus"))
        #expect(store.thread(thread.id)?.selection == ModelSelection(provider: .codex, modelID: "opus", effort: "high"))
        composer.select(ModelSelection(provider: .claude, modelID: "opus"))
        #expect(store.thread(thread.id)?.selection == ModelSelection(provider: .claude, modelID: "opus", effort: "low", speed: "fast"))
        composer.select(ModelSelection(provider: .codex, modelID: "opus"))
        composer.setEffort("low")
        try remote.updateSettings(RemoteThreadSettings(threadID: thread.id, speed: "fast"))
        composer.select(ModelSelection(provider: .codex, modelID: "haiku"))
        #expect(store.thread(thread.id)?.selection.speed == nil)
        // This changes only remembered speed: the fallback was already Standard.
        try remote.updateSettings(RemoteThreadSettings(threadID: thread.id, speed: "standard"))
        composer.select(ModelSelection(provider: .claude, modelID: "opus"))
        try remote.updateSettings(RemoteThreadSettings(threadID: thread.id, provider: "codex", modelID: "opus"))
        #expect(store.thread(thread.id)?.selection == ModelSelection(provider: .codex, modelID: "opus", effort: "low"))
        let before = try #require(store.thread(thread.id))
        #expect(throws: RemoteError.self) {
            try remote.updateSettings(RemoteThreadSettings(threadID: thread.id, provider: "claude", modelID: "opus", effort: "high", speed: "missing"))
        }
        #expect(store.thread(thread.id)?.selection == before.selection)
        #expect(store.thread(thread.id)?.modelPreferences == before.modelPreferences)
    }

    @Test func remoteExplicitEffortStillWorksForACustomModelWithoutACatalog() async throws {
        let setup = try await Setup()
        let thread = setup.store.createThread(in: setup.project.id)
        let remote = RemoteStoreAdapter(
            store: setup.store, runner: setup.runner, registry: setup.registry, services: RemoteSessionTests.services(store: setup.store))
        try remote.updateSettings(RemoteThreadSettings(threadID: thread.id, provider: "codex", modelID: "custom", effort: "high"))
        #expect(setup.store.thread(thread.id)?.selection.effort == "high")
        #expect(setup.store.thread(thread.id)?.modelPreferences?["codex/default"]?.effort == "high")
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

    // MARK: While the agent works

    @Test func eachThreadKeepsItsFollowUpBehaviorAndTheLastChoiceIsTheNewThreadDefault() async throws {
        let setup = try await Setup()
        let store = setup.store
        store.updateSettings {
            $0.followUpBehavior = .steer
            $0.existingThreadsFollowUpBehavior = .queue
        }
        // A thread from before threads kept their own goes on as the app-wide setting had it.
        let legacy = store.createThread(in: setup.project.id)
        store.updateThread(legacy.id) { $0.followUpBehavior = nil }
        let other = store.createThread(in: setup.project.id)
        #expect(other.followUpBehavior == .steer)
        let thread = store.createThread(in: setup.project.id)
        let composer = setup.composer(for: thread.id)
        #expect(composer.footer.followUpButton.accessibilityLabel() == "While the agent works: Steer")

        composer.setFollowUpBehavior(.interrupt)
        #expect(store.thread(thread.id)?.followUpBehavior == .interrupt)
        #expect(store.settings.followUpBehavior == .interrupt)
        #expect(composer.footer.followUpButton.accessibilityLabel() == "While the agent works: Interrupt")
        // New threads, in a project or not, start with it; existing ones keep theirs.
        #expect(store.createThread(in: setup.project.id).followUpBehavior == .interrupt)
        #expect(store.createThread(in: store.ensureChatsProject().id).followUpBehavior == .interrupt)
        #expect(store.thread(other.id)?.followUpBehavior == .steer)
        #expect(store.followUpBehavior(of: try #require(store.thread(legacy.id))) == .queue)

        // The thread keeps its choice when the default moves on from another thread.
        let second = setup.composer(for: other.id)
        second.setFollowUpBehavior(.queue)
        #expect(store.settings.followUpBehavior == .queue)
        #expect(store.thread(thread.id)?.followUpBehavior == .interrupt)
        #expect(store.followUpBehavior(of: try #require(store.thread(legacy.id))) == .queue)
    }

    @Test func steerCantBePickedForAnAgentThatCantTakeMessagesMidTurn() async throws {
        let setup = try await Setup()
        let store = setup.store
        let thread = store.createThread(in: setup.project.id, selection: ModelSelection(provider: .cursor, modelID: "default"))
        store.updateThread(thread.id) { $0.followUpBehavior = .queue }
        let composer = setup.composer(for: thread.id)
        composer.setFollowUpBehavior(.steer)
        #expect(store.thread(thread.id)?.followUpBehavior == .queue)
        // A thread that chose Steer before switching to such an agent queues, and shows it.
        store.updateThread(thread.id) { $0.followUpBehavior = .steer }
        #expect(composer.footer.followUpButton.accessibilityLabel() == "While the agent works: Queue")
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
            registry = ProviderRegistry(store: store, providers: [SpeedProvider(), SpeedProvider(kind: .codex)])
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
