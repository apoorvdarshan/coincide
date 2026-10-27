import Foundation
import Testing

@testable import CoincideKit

/// Reading the login shell again must not hold up git, terminals or agent launches, and coming back to
/// Coincide must not start a new interactive shell every minute.
@MainActor
struct ShellEnvironmentRefreshTests {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var released = false
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
        func release() { lock.withLock { released = true } }
        var isReleased: Bool { lock.withLock { released } }
    }

    @Test func callersKeepThePreviousEnvironmentWhileTheShellIsReadAgain() async {
        let reads = Reads()
        let shell = ShellEnvironment {
            let read = reads.next()
            // Every read after the first is a slow shell startup that ends only when the test says so.
            while read > 1, !reads.isReleased { try? await Task.sleep(for: .milliseconds(5)) }
            return ["COINCIDE_TEST_READ": "\(read)"]
        }
        #expect(await shell.environment()["COINCIDE_TEST_READ"] == "1")
        shell.invalidate()
        #expect(await shell.environment()["COINCIDE_TEST_READ"] == "1")
        #expect(await shell.which("sh") != nil)
        let fresh = Task { await shell.freshEnvironment() }
        #expect(await shell.environment()["COINCIDE_TEST_READ"] == "1")
        reads.release()
        #expect(await fresh.value["COINCIDE_TEST_READ"] == "2")
        // The new environment replaces the previous one for everyone.
        #expect(await shell.environment()["COINCIDE_TEST_READ"] == "2")
        #expect(reads.count == 2)
    }

    @Test func onlyAnOldEnvironmentIsReadAgain() async throws {
        let reads = Reads()
        let shell = ShellEnvironment {
            _ = reads.next()
            return ["PATH": "/custom/bin"]
        }
        _ = await shell.environment()
        shell.invalidate(olderThan: 3_600)
        _ = await shell.freshEnvironment()
        #expect(reads.count == 1)
        try await Task.sleep(for: .milliseconds(10))
        shell.invalidate(olderThan: 0.001)
        _ = await shell.freshEnvironment()
        #expect(reads.count == 2)
    }

    @Test func comingBackReadsTheShellAgainOnlyWhenItIsOld() async throws {
        let reads = Reads()
        let shell = ShellEnvironment {
            _ = reads.next()
            return ["PATH": "/custom/bin"]
        }
        let provider = ProbedProvider(kind: .cursor)
        provider.states = [.notInstalled]
        let store = AppStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("coincide-reg-\(UUID().uuidString)"))
        let registry = ProviderRegistry(store: store, providers: [provider], shell: shell)
        await registry.refresh()
        #expect(reads.count == 1)
        // A missing CLI is looked for again, in the folders of the environment read moments ago.
        await registry.refreshUnavailable(olderThan: 0)
        #expect(provider.detections == 2)
        #expect(reads.count == 1)
        // Once the environment is old, the check waits for the shell to be read again.
        registry.environmentRereadAge = 0
        try await Task.sleep(for: .milliseconds(10))
        await registry.refreshUnavailable(olderThan: 0)
        #expect(provider.detections == 3)
        #expect(reads.count == 2)
    }
}
