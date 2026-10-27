import Foundation
import Testing

@testable import CoincideKit

/// A long transcript that streams updates must not be rewritten whole several times a second.
@MainActor
struct StoreSaveThrottleTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-throttle-\(UUID().uuidString)")

    private func onDisk(_ id: UUID) -> String {
        let file = directory.appendingPathComponent("threads/\(id.uuidString).json")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private func eventually(timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A store whose thread has been saved once, with `bytesPerSecond` setting its cool-down.
    private func storeWithSavedThread(bytesPerSecond: Double) async -> (AppStore, UUID, UUID) {
        let store = AppStore(directory: directory)
        store.saveDelay = 0
        store.saveBytesPerSecond = bytesPerSecond
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        let item = store.append(TranscriptItem(kind: .assistant, text: "first", status: .running), to: thread.id)
        #expect(await eventually { onDisk(thread.id).contains("first") })
        return (store, thread.id, item)
    }

    @Test func changesWaitForTheCoolDownAfterASave() async throws {
        // The file is a few hundred bytes, so it cools down for a few seconds.
        let (store, threadID, item) = await storeWithSavedThread(bytesPerSecond: 200)
        store.updateItem(item, in: threadID) { $0.text = "second" }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!onDisk(threadID).contains("second"))
        // Once the cool-down is over, the change is written without anything else happening.
        #expect(await eventually { onDisk(threadID).contains("second") })
    }

    @Test func theEndOfATurnIsSavedAtOnce() async throws {
        let (store, threadID, item) = await storeWithSavedThread(bytesPerSecond: 1)
        store.updateItem(item, in: threadID) { $0.text = "second" }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!onDisk(threadID).contains("second"))
        NotificationCenter.default.post(
            name: ThreadRunner.turnFinishedNotification, object: nil, userInfo: ["threadID": threadID])
        #expect(await eventually { onDisk(threadID).contains("second") })
    }

    @Test func quittingSavesWhatIsCoolingDown() async throws {
        let (store, threadID, item) = await storeWithSavedThread(bytesPerSecond: 1)
        store.updateItem(item, in: threadID) { $0.text = "second" }
        store.flush()
        #expect(onDisk(threadID).contains("second"))
    }
}
