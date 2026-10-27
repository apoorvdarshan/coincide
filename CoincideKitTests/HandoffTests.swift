import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct HandoffTests {
    private func thread(_ items: [TranscriptItem], sessions: [ProviderKind: ProviderSessionRef] = [:]) -> ChatThread {
        ChatThread(
            projectID: UUID(), selection: ModelSelection(provider: .claude, modelID: "default"), items: items,
            sessions: sessions)
    }

    @Test func freshThreadNeedsNoRecap() {
        let empty = thread([])
        #expect(Handoff.prompt(for: "hi", thread: empty, provider: .claude) == "hi")
    }

    @Test func currentSessionNeedsNoRecap() {
        let items = [
            TranscriptItem(kind: .user, text: "fix the bug", provider: .claude),
            TranscriptItem(kind: .assistant, text: "Done.", provider: .claude),
        ]
        let current = thread(items, sessions: [.claude: ProviderSessionRef(sessionID: "a", seenItemCount: 2)])
        #expect(Handoff.prompt(for: "next", thread: current, provider: .claude) == "next")
    }

    @Test func switchingProviderRecapsWhatItMissed() {
        let items = [
            TranscriptItem(kind: .user, text: "fix the bug", provider: .claude),
            TranscriptItem(kind: .assistant, text: "Fixed in App.swift.", provider: .claude, modelID: "opus"),
            TranscriptItem(kind: .tool, text: "ok", title: "Run `swift test`", category: .command, status: .completed, provider: .claude),
        ]
        let switched = thread(items, sessions: [.claude: ProviderSessionRef(sessionID: "a", seenItemCount: 3)])
        let prompt = Handoff.prompt(for: "now add tests", thread: switched, provider: .codex)
        #expect(prompt.contains("<conversation_handoff>"))
        #expect(prompt.contains("fix the bug"))
        #expect(prompt.contains("Claude Code (opus)"))
        #expect(prompt.contains("Run `swift test`"))
        #expect(prompt.hasSuffix("now add tests"))
    }

    @Test func returningProviderOnlyHearsNewTurns() {
        let items = [
            TranscriptItem(kind: .user, text: "first", provider: .claude),
            TranscriptItem(kind: .assistant, text: "claude answer", provider: .claude),
            TranscriptItem(kind: .user, text: "second", provider: .codex),
            TranscriptItem(kind: .assistant, text: "codex answer", provider: .codex),
        ]
        let back = thread(
            items,
            sessions: [
                .claude: ProviderSessionRef(sessionID: "a", seenItemCount: 2),
                .codex: ProviderSessionRef(sessionID: "b", seenItemCount: 4),
            ])
        let prompt = Handoff.prompt(for: "third", thread: back, provider: .claude)
        #expect(prompt.contains("codex answer"))
        #expect(!prompt.contains("claude answer"))
    }

    @Test func recapKeepsMostRecentWithinBudget() {
        let items = (0..<50).map { TranscriptItem(kind: .assistant, text: String(repeating: "x", count: 100) + "\($0)", provider: .codex) }
        let text = Handoff.transcript(items, budget: 1_000)
        #expect(text.contains("earlier entries omitted"))
        #expect(text.contains("x49"))
        #expect(!text.contains("x0\n"))
    }
}

@MainActor
struct StoreTests {
    private func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        return AppStore(directory: dir)
    }

    @Test func threadsPersistAcrossReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.append(TranscriptItem(kind: .user, text: "hello"), to: thread.id)
        store.flush()

        let reloaded = AppStore(directory: dir)
        #expect(reloaded.projects.count == 1)
        #expect(reloaded.thread(thread.id)?.items.first?.text == "hello")
    }

    @Test func runningItemsAreClosedOnReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.append(TranscriptItem(kind: .tool, title: "Run", status: .running), to: thread.id)
        store.flush()

        let reloaded = AppStore(directory: dir)
        #expect(reloaded.thread(thread.id)?.items.first?.status == .failed)
    }

    @Test func pinnedThreadsSortFirst() {
        let store = makeStore()
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let older = store.createThread(in: project.id)
        _ = store.createThread(in: project.id)
        store.updateThread(older.id) { $0.isPinned = true }
        #expect(store.threads(in: project.id).first?.id == older.id)
    }

    @Test func titleComesFromFirstLine() {
        #expect(ThreadRunner.title(from: "Fix the login bug\nmore details") == "Fix the login bug")
        let long = String(repeating: "word ", count: 30)
        #expect(ThreadRunner.title(from: long).count <= 60)
    }
}
