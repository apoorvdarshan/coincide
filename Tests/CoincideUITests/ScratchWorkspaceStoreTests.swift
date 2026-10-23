import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor ScratchUIRecorder {
    private(set) var sends = 0
    func sent() { sends += 1 }
}
private actor ScratchUIPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let recorder: ScratchUIRecorder
    init(_ recorder: ScratchUIRecorder) { self.recorder = recorder; let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async { await recorder.sent() }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}
@MainActor private struct ScratchUIFixture {
    let root: URL
    let store: WorkspaceStore
    let engine: WorkspaceEngine
    let recorder: ScratchUIRecorder
    static func make() async throws -> Self {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-scratch-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = realpath(candidate.path, nil) else { throw ScratchWorkspaceError("The owned fixture root could not be resolved.") }
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer))
        let recorder = ScratchUIRecorder(), home = root.appendingPathComponent("PrivateClaudeHome")
        let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in ScratchUIPeer(recorder) }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, claudeRuntimeCapture: { path in
            try ClaudeRuntimeConfiguration.capture(workspacePath: path, executable: "/usr/bin/false", configurationDirectory: home.path,
                environment: ["HOME": root.path])
        })
        await store.load()
        return .init(root: root, store: store, engine: engine, recorder: recorder)
    }
    func close() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func scratchNativeStoreCapturesActualFolderKeepsLiteralDraftAndUsesOneSingletonWithUniqueConversations() async throws {
    let f = try await ScratchUIFixture.make()
    do {
        let draft = "  Keep literal cafe\u{301}\n "
        let id = try await f.store.openScratchDraft(draft: draft, requestedProvider: .claude)
        let thread = try #require(f.store.thread(id)), receipt = try #require(thread.scratchWorkspace)
        #expect(f.store.snapshot.projects.count == 1 && f.store.snapshot.projects[0].name == "No project")
        #expect(thread.workspacePath.utf8.elementsEqual(receipt.workspacePath.utf8))
        #expect(thread.claudeRuntimeConfiguration?.registeredWorkspacePath.utf8.elementsEqual(thread.workspacePath.utf8) == true)
        #expect(thread.claudeRuntimeConfiguration?.configurationDirectory == f.root.appendingPathComponent("PrivateClaudeHome").path)
        #expect(thread.draft.utf8.elementsEqual(draft.utf8) && thread.messages.isEmpty && thread.activeRun == nil && thread.workspacePreparation == nil)
        #expect(f.store.workspaceReady(for: thread) && f.store.canOpenTerminal(for: thread))
        let next = try await f.store.openScratchDraft(draft: "Second task")
        let second = try #require(f.store.thread(next))
        #expect(second.projectID == thread.projectID && second.workspacePath != thread.workspacePath && second.scratchWorkspace != nil)
        #expect(f.store.thread(id)?.draft.utf8.elementsEqual(draft.utf8) == true)
        #expect(f.store.selectedThreadID == next && !f.store.isCreatingScratchConversation)
        #expect(await f.recorder.sends == 0)
        let old = URL(fileURLWithPath: thread.workspacePath), retained = old.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: old, to: retained)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let foreign = old.appendingPathComponent("foreign.txt"); try Data("keep foreign bytes".utf8).write(to: foreign)
        #expect(!f.store.workspaceReady(for: thread) && !f.store.canOpenTerminal(for: thread) && !f.store.canAccessWorkspaceFiles(thread.workspacePath))
        #expect(try String(contentsOf: foreign, encoding: .utf8) == "keep foreign bytes")
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func scratchRecoverySheetFitsSmallLightAndDarkWindowsWithoutStartingAnyProviderInput() async throws {
    _ = NSApplication.shared
    let f = try await ScratchUIFixture.make()
    do {
        _ = try await f.store.openScratchDraft(draft: "Visible draft")
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(480), 720] {
                let controller = NSHostingController(rootView: ScratchWorkspaceRecoverySheet(store: f.store).environment(\.colorScheme, scheme))
                let size = controller.sizeThatFits(in: .init(width: width, height: 680))
                #expect(size.width.isFinite && size.height.isFinite && size.width <= width + 1 && size.height >= 420 && size.height <= 680)
            }
        }
        #expect(await f.recorder.sends == 0)
        #expect(f.store.snapshot.threads.count == 1 && f.store.snapshot.threads[0].draft == "Visible draft")
    } catch { await f.close(); throw error }
    await f.close()
}
