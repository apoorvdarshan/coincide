import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct ProjectDefaultsTests {
    @Test func overridesPersistApplyOnlyToNewThreadsAndResetToCurrentGlobals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-defaults-\(UUID())")
        let store = AppStore(directory: directory)
        defer { store.flush(); try? FileManager.default.removeItem(at: directory) }
        let project = store.addProject(at: directory.appendingPathComponent("project"))
        let other = store.addProject(at: directory.appendingPathComponent("other"))
        let old = store.createThread(in: project.id)
        store.updateThread(old.id) { $0.draft = "Keep this draft" }
        let defaults = ProjectThreadDefaults(
            selection: ModelSelection(provider: .codex, modelID: "model", effort: "high", speed: "priority"),
            accessMode: .approval, interactionMode: .plan)
        store.updateProject(project.id) { $0.threadDefaults = defaults }
        let fresh = store.createThread(in: project.id)
        #expect(fresh.selection == defaults.selection)
        #expect(fresh.accessMode == .approval && fresh.interactionMode == .plan)
        #expect(store.thread(old.id)?.selection == old.selection)
        #expect(store.thread(old.id)?.accessMode == old.accessMode)
        #expect(store.thread(old.id)?.draft == "Keep this draft")
        #expect(store.createThread(in: other.id).selection == store.settings.defaultSelection)
        let explicit = ModelSelection(provider: .claude, modelID: "explicit")
        let supplied = store.createThread(in: project.id, selection: explicit)
        #expect(supplied.selection == explicit && supplied.accessMode == .approval && supplied.interactionMode == .plan)
        store.flush()
        let reopened = AppStore(directory: directory)
        #expect(reopened.project(project.id)?.threadDefaults == defaults)
        #expect(reopened.newThreadDefaults(in: project.id) == defaults)
        store.updateSettings { $0.defaultSelection = explicit }
        #expect(store.newThreadDefaults(in: project.id) == defaults)
        store.updateProject(project.id) { $0.threadDefaults = nil }
        let afterReset = store.createThread(in: project.id)
        #expect(afterReset.selection == explicit)
        #expect(afterReset.accessMode == store.settings.defaultAccessMode && afterReset.interactionMode == .build)
        #expect(store.thread(fresh.id)?.selection == defaults.selection)
    }

    @Test func chatsUseGlobalDefaultsEvenIfAProjectOverrideWasStored() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-defaults-\(UUID())")
        let store = AppStore(directory: directory)
        defer { store.flush(); try? FileManager.default.removeItem(at: directory) }
        let chats = store.ensureChatsProject()
        store.updateProject(chats.id) {
            $0.threadDefaults = ProjectThreadDefaults(selection: ModelSelection(provider: .codex, modelID: "other"), accessMode: .approval, interactionMode: .plan)
        }
        let thread = store.createThread(in: chats.id)
        #expect(thread.selection == store.settings.defaultSelection)
        #expect(thread.accessMode == store.settings.defaultAccessMode && thread.interactionMode == .build)
    }

    @Test func oldProjectsInheritAndUnknownPermissionModesFailClosed() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(Project.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","path":"/tmp/project"}"#.utf8))
        #expect(old.threadDefaults == nil)
        let defaults = try decoder.decode(ProjectThreadDefaults.self, from: Data(#"{"selection":{"provider":"claude","modelID":"default"},"accessMode":"future","interactionMode":"future"}"#.utf8))
        #expect(defaults.accessMode == .approval && defaults.interactionMode == .build)
    }

    @Test func unavailableProjectAndGlobalProvidersUseTheReadyProviderWithoutChangingSavedDefaults() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-default-fallback-\(UUID())")
        let store = AppStore(directory: directory)
        defer { store.flush(); try? FileManager.default.removeItem(at: directory) }
        let project = store.addProject(at: directory)
        let registry = ProviderRegistry(store: store, providers: [ProbedProvider(kind: .codex)])
        await registry.refresh()
        let unavailable = ModelSelection(provider: .claude, modelID: "unavailable", effort: "high", speed: "fast")
        store.updateProject(project.id) {
            $0.threadDefaults = ProjectThreadDefaults(selection: unavailable, accessMode: .approval, interactionMode: .plan)
        }
        let usable = registry.usableSelection(preferring: store.newThreadDefaults(in: project.id).selection)
        let thread = store.createThread(in: project.id, selection: usable)
        #expect(thread.selection.provider == .codex && thread.selection.modelID == "m1")
        #expect(thread.selection.speed == nil)
        #expect(thread.accessMode == .approval && thread.interactionMode == .plan)
        #expect(store.project(project.id)?.threadDefaults?.selection == unavailable)
        store.updateSettings { $0.defaultSelection = unavailable }
        store.updateProject(project.id) { $0.threadDefaults = nil }
        let reset = registry.usableSelection(preferring: store.newThreadDefaults(in: project.id).selection)
        #expect(reset.provider == .codex && reset.modelID == "m1")
        #expect(store.settings.defaultSelection == unavailable)
    }
}
