import CoincideCore
import Foundation
import Testing
@testable import Coincide

private actor PreviewOwnershipGate {
    private var waiting = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func probe() async -> Bool {
        waiting = true; observers.forEach { $0.resume() }; observers.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return true // Deliberately ignores cancellation until explicitly released.
    }
    func entered() async { if !waiting { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
@MainActor private final class PreviewOwnershipOpener: PreviewOpening {
    var urls: [URL] = []
    func openPreview(_ url: URL) -> Bool { urls.append(url); return true }
}
@MainActor private final class PreviewOwnershipSource { var current = true }

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["replaced", "source", "cancelled", "disabled", "shutdown"])
func scriptPreviewWaitCannotOpenAfterItsTokenSourceOrLifecycleIsRetired(mode: String) async throws {
    let gate = PreviewOwnershipGate(), opener = PreviewOwnershipOpener(), source = PreviewOwnershipSource(), id = UUID()
    let launcher = ScriptPreviewLauncher(opener: opener, probe: { _ in await gate.probe() }, timeout: .seconds(5), interval: .milliseconds(10))
    let script = try ProjectScript(name: "Private dev", command: "never executed", previewURL: "http://localhost:5173", autoOpenPreview: true)
    let scheduled = launcher.scheduleAutoOpen(script, id: id, isRunning: { true }, sourceIsCurrent: { source.current })
    let first = try #require(scheduled)
    await gate.entered()
    var shutdown: Task<Void, Never>?
    switch mode {
    case "replaced":
        let replacement = try ProjectScript(name: "Replacement", command: "never executed", previewURL: "https://preview.example.invalid/new", autoOpenPreview: true)
        await launcher.scheduleAutoOpen(replacement, id: id, isRunning: { true })?.value
    case "source": source.current = false
    case "cancelled": launcher.cancel(id)
    case "disabled":
        let disabled = try ProjectScript(name: "Disabled", command: "never executed", previewURL: "http://localhost:5173", autoOpenPreview: false)
        #expect(launcher.scheduleAutoOpen(disabled, id: id, isRunning: { true }) == nil)
    default:
        launcher.cancelAll()
        shutdown = Task { await launcher.shutdown() }
    }
    await gate.release(); await first.value; await shutdown?.value
    #expect(opener.urls == (mode == "replaced" ? [URL(string: "https://preview.example.invalid/new")!] : []))
    #expect(launcher.pendingCount == 0)
    #expect(throws: CancellationError.self) { try launcher.open("https://preview.example.invalid/refused", sourceIsCurrent: { false }) }
    await launcher.shutdown()
    #expect(launcher.scheduleAutoOpen(script, id: UUID(), isRunning: { true }) == nil)
}
