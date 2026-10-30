import AppKit
import CoincideKit
import CoincideRemoteKit
import Foundation

/// The `coincide` command-line tool's side in the app: the control socket while Settings › General › Command-line
/// control is on, the tool on the PATH of every agent Coincide starts, and installing it for Terminal.
@MainActor
final class CommandLineControl {
    static let shared = CommandLineControl()

    private var server: LocalControlServer?
    private var observation: ObservationToken?
    private let store: AppStore

    init(store: AppStore = .shared) {
        self.store = store
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

    /// Links `coincide` into /usr/local/bin when this user may write there, else ~/.local/bin, replacing only an earlier
    /// link to Coincide's tool. Returns the link.
    nonisolated static func installTool(tool: URL = toolURL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: tool.path) else { throw InstallError.missingTool }
        let system = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        let folder = files.isWritableFile(atPath: system.path) ? system : home.appendingPathComponent(".local/bin", isDirectory: true)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw InstallError.failed(error.localizedDescription)
        }
        let link = folder.appendingPathComponent("coincide")
        if let existing = try? files.destinationOfSymbolicLink(atPath: link.path) {
            guard existing.hasSuffix("/Contents/Helpers/coincide") else { throw InstallError.occupied(link.path) }
            try? files.removeItem(at: link)
        } else if files.fileExists(atPath: link.path) {
            throw InstallError.occupied(link.path)
        }
        do {
            try files.createSymbolicLink(at: link, withDestinationURL: tool)
        } catch {
            throw InstallError.failed(error.localizedDescription)
        }
        return link
    }
}
