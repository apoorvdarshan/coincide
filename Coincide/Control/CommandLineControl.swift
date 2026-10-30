import AppKit
import CoincideKit
import CoincideRemoteKit
import Foundation
import Observation

/// The `coincide` command-line tool's side in the app: the control socket while Settings › General › Command-line
/// control is on, the tool on the PATH of every agent Coincide starts, and installing it for Terminal.
@MainActor
@Observable
final class CommandLineControl {
    static let shared = CommandLineControl()

    @ObservationIgnored private var server: LocalControlServer?
    @ObservationIgnored private var observation: ObservationToken?
    private let store: AppStore
    private(set) var terminalInstallation: TerminalToolInstallation.Location?
    private(set) var terminalError: String?
    @ObservationIgnored private var installationTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(store: AppStore = .shared) {
        self.store = store
    }

    isolated deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// The folder holding the tool inside Coincide.app; it holds nothing else that runs.
    nonisolated static var helpersFolder: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }
    nonisolated static var toolURL: URL { helpersFolder.appendingPathComponent("coincide") }

    /// The socket in Coincide's data folder, or in the user's temporary folder when that path is too long for a socket.
    var socketPath: String {
        let path = store.directory.appendingPathComponent("control.sock").path
        guard path.utf8.count >= 100 else { return path }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coincide-control.sock").path
    }

    var isRunning: Bool { server?.isRunning == true }

    func start() {
        guard observation == nil else { return }
        observation = store.observe { [weak self] change in
            if change == .settings { self?.apply() }
        }
        ThreadRunner.shared.launchEnvironments["commandLine"] = { [weak self] threadID in
            MainActor.assumeIsolated { self?.agentEnvironment(for: threadID) ?? [:] }
        }
        apply()
        refreshTerminalInstallation()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshTerminalInstallation() } }
    }

    /// Installs once at startup and checks again when Settings opens or the app becomes active. Off the UI thread;
    /// disabling command-line control leaves the Terminal command installed, but the socket refuses requests.
    func refreshTerminalInstallation() {
        guard !AppDelegate.isHostingTests, installationTask == nil else { return }
        installationTask = Task {
            let path = await ShellEnvironment.shared.terminalSearchPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            let tool = Self.toolURL
            do {
                terminalInstallation = try await Task.detached { try TerminalToolInstallation.ensure(tool: tool, searchPath: path) }.value
                terminalError = nil
            } catch {
                terminalInstallation = nil
                terminalError = error.localizedDescription
            }
            installationTask = nil
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func apply() {
        if store.settings.commandLineControl {
            guard server == nil else { return }
            let adapter = RemoteStoreAdapter()
            let server = LocalControlServer(path: socketPath, adapter: adapter) {
                adapter.serverInfo(serverID: "local", name: RemoteAddresses.computerName)
            }
            server.onShowThread = { id in
                NSApp.activate()
                (NSApp.delegate as? AppDelegate)?.mainWindow?.showWindow(nil)
                AppEvents.openThread(id)
            }
            do {
                try server.start()
                self.server = server
            } catch {
                NSLog("Coincide: command-line control is off: \(error.localizedDescription)")
            }
        } else {
            stop()
        }
    }

    /// What an agent Coincide starts needs to run `coincide`: its folder on the PATH, the socket, and its own thread
    /// for `this`. Nothing while command-line control is off.
    func agentEnvironment(for threadID: UUID) -> [String: String] {
        guard isRunning else { return [:] }
        return [
            "PATH": Self.helpersFolder.path, "COINCIDE_CONTROL_SOCKET": socketPath, "COINCIDE_THREAD_ID": threadID.uuidString,
        ]
    }

    // MARK: Installing

    enum InstallError: LocalizedError {
        case missingTool
        case occupied(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingTool: String(localized: "This copy of Coincide doesn’t include the command-line tool.")
            case .occupied(let path): String(localized: "\(path) already exists and isn’t Coincide’s tool, so it was left alone.")
            case .failed(let reason): reason
            }
        }
    }

}
