import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct StderrTailTests {
    @Test func theTailKeepsOnlyItsOwnBytes() {
        var tail = Data()
        var written = Data()
        for index in 0..<200 {
            let chunk = Data(repeating: UInt8(index % 251), count: 4_096)
            written.append(chunk)
            LineProcess.appendToTail(&tail, chunk)
        }
        #expect(tail == written.suffix(LineProcess.stderrTailLimit))
        // A slice of the old buffer would start far into it and keep all of it alive.
        #expect(tail.startIndex == 0)
    }

    @Test func theExitReportsTheEndOfALongStderr() async throws {
        let process = LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 1000000 /dev/zero | tr '\\0' x >&2; printf 'the end' >&2"],
            workingDirectory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        var tail: String?
        process.onExit = { _, stderrTail in tail = stderrTail }
        try process.start()
        let deadline = Date().addingTimeInterval(8)
        while tail == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let reported = try #require(tail)
        #expect(reported.hasSuffix("xthe end"))
        #expect(reported.utf8.count == LineProcess.stderrTailLimit)
    }
}
