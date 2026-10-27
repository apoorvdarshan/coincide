import Darwin
import Foundation

/// Moves ACP lines between Coincide and an agent. The default runs the agent CLI as a child
/// process; tests use an in-memory one.
@MainActor
public protocol ACPTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onStderr: ((String) -> Void)? { get set }
    var onExit: ((_ status: Int32, _ stderrTail: String) -> Void)? { get set }
    func start() throws
    func write(_ line: String)
    /// Stops the agent and every process it started.
    func terminate()
}

public typealias ACPTransportFactory = @MainActor (
    _ executable: URL, _ arguments: [String], _ workingDirectory: URL, _ environment: [String: String]
) -> ACPTransport

/// Runs the agent with `LineProcess`.
@MainActor
final class ACPProcessTransport: ACPTransport {
    var onLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((_ status: Int32, _ stderrTail: String) -> Void)?
    private let process: LineProcess

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process = LineProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
        process.onLine = { [weak self] line in self?.onLine?(line) }
        process.onStderr = { [weak self] text in self?.onStderr?(text) }
        process.onExit = { [weak self] status, tail in self?.onExit?(status, tail) }
    }

    func start() throws { try process.start() }
    func write(_ line: String) { process.write(line) }

    /// Stops the agent and every process it started (see `LineProcess.terminate`).
    func terminate() {
        guard process.isRunning else { return }
        // Keep the process object until it has exited, so its exit is still reaped once the
        // session lets go of this transport. (An exit already on its way is delivered to the
        // previous handler, so this cycle only forms while the process runs.)
        process.onExit = { [self] _, _ in process.onExit = nil }
        process.terminate()
    }
}
