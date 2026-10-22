import Foundation
import Testing
@testable import CoincideCore

private func unscoped(_ event: ProviderEvent) -> ProviderEvent {
    if case .context(_, let event) = event { return unscoped(event) }
    return event
}
private func nextMatching(_ iterator: inout AsyncStream<ProviderEvent>.Iterator,
                          _ predicate: (ProviderEvent) -> Bool) async throws {
    while let event = await iterator.next() {
        if case .failure(let message) = unscoped(event) { throw CoincideError(message) }
        if predicate(unscoped(event)) { return }
    }
    throw CoincideError("Provider stream ended before the expected event.")
}

private func expectCompletedTurnReference(_ iterator: inout AsyncStream<ProviderEvent>.Iterator, expected: String) async throws {
    var references: [String] = []
    while let event = await iterator.next() {
        switch unscoped(event) {
        case .failure(let message): throw CoincideError(message)
        case .turn(let reference): references.append(reference)
        case .completed(.idle): #expect(references == [expected]); return
        default: break
        }
    }
    throw CoincideError("Provider stream ended before the completed turn reference.")
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codexLateStartAcknowledgementsDoNotReplaceCurrentTurn(completionOnly: Bool) async throws {
    let fixture = Bundle.module.url(forResource: "codex_pipeline", withExtension: "py", subdirectory: "Fixtures")!
    let session = try CodexSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: FileManager.default.temporaryDirectory,
                                   arguments: [fixture.path] + (completionOnly ? ["completion-only"] : []))
    let project = WorkspaceProject(path: FileManager.default.temporaryDirectory.path)
    var first = CodingThread(project: project)
    first.activeRun = .init(id: UUID(), configuration: .init(thread: first), startedAt: Date())
    var second = first; second.activeRun?.id = UUID()
    var third = first; third.activeRun?.id = UUID()
    var iterator = session.events.makeAsyncIterator()
    do {
        let a = Task { try await session.send(text: "first", thread: first) }
        try await expectCompletedTurnReference(&iterator, expected: "turn-1")
        let b = Task { try await session.send(text: "second", thread: second) }
        try await expectCompletedTurnReference(&iterator, expected: "turn-2")
        let c = Task { try await session.send(text: "third", thread: third) }
        try await nextMatching(&iterator) { if case .delta(_, _, "ACKS_DONE") = $0 { true } else { false } }
        try await a.value; try await b.value; try await c.value
        try await session.interrupt()
        try await nextMatching(&iterator) { if case .completed(.interrupted) = $0 { true } else { false } }
        await session.close()
    } catch { await session.close(); throw error }
}
