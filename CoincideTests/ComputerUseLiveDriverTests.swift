import Darwin
import Foundation
import Testing
@testable import Coincide

/// Against the real bundled Cua Driver: its display-sleep assertion lasts as long as the helper runs, and Coincide stops
/// an idle helper so the display can sleep. Opt-in (`COINCIDE_COMPUTER_USE_LIVE=1`, or `TEST_RUNNER_…` through
/// xcodebuild) because it starts the real driver. It only lists apps: no screen capture, no input, no windows.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COINCIDE_COMPUTER_USE_LIVE"] == "1"))
struct ComputerUseLiveDriverTests {
    private func keepsDisplayAwake(_ pid: Int32) throws -> Bool {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        pmset.standardOutput = pipe
        try pmset.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pmset.waitUntilExit()
        return text.split(separator: "\n").contains { $0.contains("pid \(pid)(") && $0.contains("PreventUserIdleDisplaySleep") }
    }

    private func waitForStop(_ runtime: ComputerUseRuntime) async throws {
        for _ in 0..<200 where runtime.isRunning { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func theDisplayCanSleepOnceTheHelperIsIdle() async throws {
        let runtime = ComputerUseRuntime(idleTimeout: 2, releaseGrace: 0.5)
        defer { runtime.stop() }
        let id = UUID()
        _ = try await runtime.call(threadID: id, name: "list_apps", arguments: [:])
        let pid = try #require(runtime.helperProcessID)
        #expect(try keepsDisplayAwake(pid), "A working session keeps the display awake.")
        try await Task.sleep(for: .seconds(1))
        #expect(runtime.isRunning, "Stopped before the idle timeout.")
        try await waitForStop(runtime)
        #expect(!runtime.isRunning)
        #expect(kill(pid, 0) != 0)
        #expect(try !keepsDisplayAwake(pid))

        // The next request starts a fresh helper; releasing the only thread then stops it after the short grace.
        _ = try await runtime.call(threadID: id, name: "list_apps", arguments: [:])
        let again = try #require(runtime.helperProcessID)
        #expect(again != pid)
        #expect(try keepsDisplayAwake(again))
        runtime.end(threadID: id)
        try await waitForStop(runtime)
        #expect(!runtime.isRunning)
        #expect(try !keepsDisplayAwake(again))
    }
}
