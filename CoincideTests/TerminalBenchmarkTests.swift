import AppKit
import CoincideKit
import Darwin
import Testing

@testable import Coincide

/// Measures the terminal, for comparing renderers and SwiftTerm versions. Off unless the run sets
/// COINCIDE_TERMINAL_BENCHMARK=1 (TEST_RUNNER_COINCIDE_TERMINAL_BENCHMARK=1 with xcodebuild); COINCIDE_TERMINAL_GPU=0
/// measures Core Graphics. Results print and, with COINCIDE_TERMINAL_BENCHMARK_OUT, are written there as JSON.
///
/// Terminals sit in borderless, transparent windows far offscreen that are never ordered in, so macOS may skip
/// presenting their frames: the numbers cover parsing and frame preparation more than what reaches the display.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COINCIDE_TERMINAL_BENCHMARK"] == "1"))
struct TerminalBenchmarkTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let usesGPU = environment["COINCIDE_TERMINAL_GPU"] != "0"

    private final class Window {
        let window: NSWindow
        init(_ view: NSView) {
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.alphaValue = 0
            window.isReleasedWhenClosed = false
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            window.contentView = view
        }
        deinit { MainActor.assumeIsolated { window.close() } }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Records how late a 5 ms main-thread timer fires while `body` runs.
    private final class StallProbe {
        private var timer: Timer?
        private var last = CACurrentMediaTime()
        private(set) var gaps: [Double] = []

        func start() {
            last = CACurrentMediaTime()
            timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    self.gaps.append((now - self.last) * 1000)
                    self.last = now
                }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }

        func stop() { timer?.invalidate() }

        func percentile(_ fraction: Double) -> Double {
            let sorted = gaps.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
    }

    private static func startSession(in folder: URL) async throws -> TerminalSession {
        let session = TerminalSession(number: 1, directory: folder, missingDirectory: nil)
        session.start()
        for _ in 0..<200 where session.state != .running {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(session.state == .running, "the shell did not start")
        return session
    }

    /// The terminal's text, to see that output was parsed and not only read.
    private static func bufferText(_ session: TerminalSession) -> String {
        String(decoding: session.terminalView.getBufferAsData(), as: UTF8.self)
    }

    /// Runs `command` in a fresh shell in a window, returning the seconds until the terminal has parsed all of its
    /// output (a marker printed after it appears in the buffer) and the main-thread timer's delays.
    private static func timeCommand(_ command: String, in folder: URL) async throws -> (seconds: Double, cpu: Double, probe: StallProbe) {
        let session = try await startSession(in: folder)
        let window = Window(session.paneView)
        defer {
            _ = window
            session.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        let probe = StallProbe()
        probe.start()
        let cpu = cpuSeconds()
        let start = CACurrentMediaTime()
        // The command line holds "%s", so only the printed marker matches.
        session.run(command + "; printf 'COINCIDE-%s\\n' BENCH-DONE")
        var done = false
        for _ in 0..<2_400 where !done {
            try await Task.sleep(for: .milliseconds(50))
            done = bufferText(session).contains("COINCIDE-BENCH-DONE")
        }
        let elapsed = CACurrentMediaTime() - start
        probe.stop()
        try #require(done, "\(command) did not finish in two minutes")
        return (elapsed, cpuSeconds() - cpu, probe)
    }

    @Test func measureTheTerminal() async throws {
        let saved = ShellTerminalView.prefersGPURendering
        ShellTerminalView.prefersGPURendering = { Self.usesGPU }
        defer { ShellTerminalView.prefersGPURendering = saved }
        let folder = TemporaryDirectory("terminal-benchmark")
        var results: [String: Double] = ["gpu": Self.usesGPU ? 1 : 0]

        // A 100 MB log: numbered lines of mixed text, some in color.
        let log = folder.url.appendingPathComponent("flood.txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        var chunk = Data()
        var line = 0
        while (try handle.offset()) < 100 * 1_048_576 {
            chunk.removeAll(keepingCapacity: true)
            for _ in 0..<2_000 {
                line += 1
                let text = line % 7 == 0
                    ? "\u{1b}[32m\(line) ok\u{1b}[0m Compiling Sources/Module\(line % 97)/File\(line % 13).swift in 0.0\(line % 9)s\n"
                    : "\(line) warning: value 'item\(line % 31)' was never used; consider replacing with '_' or removing it\n"
                chunk.append(contentsOf: text.utf8)
            }
            try handle.write(contentsOf: chunk)
        }
        try handle.close()

        // Idle: five shells at their prompts, each drawn in a window.
        let baseline = Self.footprintMB()
        var sessions: [TerminalSession] = []
        var windows: [Window] = []
        for _ in 0..<5 {
            let session = try await Self.startSession(in: folder.url)
            sessions.append(session)
            windows.append(Window(session.paneView))
        }
        try await Task.sleep(for: .seconds(3))
        results["idleFootprintMB"] = Self.footprintMB() - baseline
        let idleCPU = Self.cpuSeconds()
        try await Task.sleep(for: .seconds(10))
        results["idleCPUPercent"] = (Self.cpuSeconds() - idleCPU) / 10 * 100
        for session in sessions { session.close() }
        windows.removeAll()

        // Shell start-up, to take out of the timings below.
        let startup = try await Self.timeCommand("true", in: folder.url)
        results["shellStartupSeconds"] = startup.seconds

        let cat = try await Self.timeCommand("cat flood.txt", in: folder.url)
        results["cat100MBSeconds"] = cat.seconds - startup.seconds
        results["cat100MBCPUSeconds"] = cat.cpu
        results["cat100MBMainStallP99ms"] = cat.probe.percentile(0.99)
        results["cat100MBMainStallMaxms"] = cat.probe.percentile(1)

        let yes = try await Self.timeCommand("yes | head -n 5000000", in: folder.url)
        results["yes5MSeconds"] = yes.seconds - startup.seconds
        results["yes5MCPUSeconds"] = yes.cpu
        results["yes5MMainStallP99ms"] = yes.probe.percentile(0.99)
        results["yes5MMainStallMaxms"] = yes.probe.percentile(1)

        let json = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print("TERMINAL-BENCHMARK " + String(decoding: json, as: UTF8.self))
        if let out = Self.environment["COINCIDE_TERMINAL_BENCHMARK_OUT"] {
            try json.write(to: URL(fileURLWithPath: out))
        }
    }
}
