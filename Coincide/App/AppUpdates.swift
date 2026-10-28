import AppKit
import CoincideKit
import Observation

/// Update checks and staging never stop an agent. Only a user-armed helper can install after normal quit.
@Observable
final class AppUpdates {
    static let shared = AppUpdates()
    enum State: Equatable { case idle, checking, current, unpublished, available, downloading, ready, arming, armed, failed(String) }
    private(set) var state: State = .idle
    private(set) var release: AppUpdateRelease?
    private(set) var lastChecked: Date?
    private(set) var canInstall = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var job: URL?
    @ObservationIgnored private var plan: AppUpdatePlan?
    @ObservationIgnored private var helper: Process?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let fetch: @Sendable (URL, Int64) async throws -> (URL, Int)
    @ObservationIgnored private let root: URL
    private var version: String { Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    init(store: AppStore = .shared, bundleURL: URL = Bundle.main.bundleURL, root: URL? = nil,
         fetch: @escaping @Sendable (URL, Int64) async throws -> (URL, Int) = { try await AppUpdateDownload.fetch($0, maximum: $1) }) {
        self.fetch = fetch
        lastChecked = store.settings.lastAppUpdateCheck
        self.store = store
        self.bundleURL = bundleURL
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apoorvdarshan.coincide/Updates", isDirectory: true)
    }

    var busy: Bool { state == .checking || state == .downloading || state == .arming }
    var status: String {
        switch state {
        case .idle: String(localized: "Check for a newer version of Coincide.")
        case .checking: String(localized: "Checking for updates…")
        case .current: String(localized: "Coincide is up to date.")
        case .unpublished: String(localized: "No published release is available yet.")
        case .available: String(localized: "Version \(release?.version ?? "") is available.")
        case .downloading: String(localized: "Downloading and verifying the update…")
        case .ready: String(localized: "The update is verified and ready to install.")
        case .arming: String(localized: "Preparing installation…")
        case .armed: String(localized: "The update will install after you quit. Wait for confirmation, then reopen Coincide yourself.")
        case .failed(let message): message
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.automaticCheck() }
        }
        automaticCheck()
    }

    func automaticCheck(now: Date = Date()) {
        guard store.settings.checksForAppUpdates, now.timeIntervalSince(store.settings.lastAppUpdateCheck ?? .distantPast) >= 24 * 3600,
              state != .armed, !busy, state != .ready else { return }
        store.updateSettings { $0.lastAppUpdateCheck = now }
        check()
    }

    func check() {
        guard !busy, state != .armed else { return }
        state = .checking
        task = Task {
            do {
                let (file, response) = try await fetch(AppUpdateRelease.feed, 2 * 1024 * 1024)
                defer { try? FileManager.default.removeItem(at: file) }
                canInstall = (try? AppUpdateSecurity.signingTeam(at: bundleURL)) != nil
                lastChecked = Date()
                store.updateSettings { $0.lastAppUpdateCheck = lastChecked }
                if response == 404 { release = nil; state = .unpublished; return }
                guard response == 200 else { throw AppUpdateError.network }
                release = try AppUpdateRelease.parse(Data(contentsOf: file), newerThan: version)
                state = release == nil ? .current : .available
            } catch { state = .failed((error as? AppUpdateError)?.localizedDescription ?? AppUpdateError.network.localizedDescription) }
        }
    }

    func download() {
        guard let release, canInstall, !busy, state != .armed else { return }
        state = .downloading
        let root = root, target = bundleURL
        task = Task {
            do {
                let (file, response) = try await fetch(release.url, release.size)
                defer { try? FileManager.default.removeItem(at: file) }
                guard response == 200 else { throw AppUpdateError.network }
                let staged = try await Task.detached {
                    try AppUpdateStaging.prepare(download: file, release: release, root: root, target: target)
                }.value
                if let job { try? FileManager.default.removeItem(at: job) }
                job = staged
                state = .ready
            } catch { state = .failed((error as? AppUpdateError)?.localizedDescription ?? AppUpdateError.network.localizedDescription) }
        }
    }

    func installOnQuit() {
        guard state == .ready, let job, let release else { return }
        state = .arming
        task = Task {
            do {
                let team = try AppUpdateSecurity.signingTeam(at: bundleURL)
                let original = bundleURL.appendingPathComponent("Contents/MacOS/CoincideUpdater")
                try AppUpdateSecurity.validateSignature(at: original, team: team, identifier: "CoincideUpdater")
                let helperURL = job.appendingPathComponent("CoincideUpdater")
                if FileManager.default.fileExists(atPath: helperURL.path) { try FileManager.default.removeItem(at: helperURL) }
                try FileManager.default.copyItem(at: original, to: helperURL)
                try AppUpdateSecurity.validateSignature(at: helperURL, team: team, identifier: "CoincideUpdater")
                let plan = AppUpdatePlan(release: release, target: bundleURL.resolvingSymlinksInPath(), processID: ProcessInfo.processInfo.processIdentifier)
                let planURL = job.appendingPathComponent("plan.json")
                try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
                try? FileManager.default.removeItem(at: job.appendingPathComponent("clean-quit"))
                let process = Process(), pipe = Pipe()
                process.executableURL = helperURL
                process.arguments = [planURL.path]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                helper = process
                // Poll only our helper's readiness pipe off the UI thread, with a bounded timeout.
                let ready = await Task.detached {
                    var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    guard poll(&descriptor, 1, 5000) > 0 else { return false }
                    return (try? pipe.fileHandleForReading.read(upToCount: 6)) == Data("READY\n".utf8)
                }.value
                guard ready, process.isRunning else { if process.isRunning { process.terminate() }; throw AppUpdateError.installation }
                self.plan = plan
                state = .armed
                process.terminationHandler = { [weak updates = self] _ in
                    Task { @MainActor in
                        guard let updates, updates.state == .armed else { return }
                        updates.plan = nil
                        updates.state = .failed(AppUpdateError.installation.localizedDescription)
                    }
                }
            } catch { state = .failed((error as? AppUpdateError)?.localizedDescription ?? AppUpdateError.installation.localizedDescription) }
        }
    }

    func cancelInstallation() {
        guard state == .armed else { return }
        plan = nil
        state = .ready
        if helper?.isRunning == true { helper?.terminate() }
        helper = nil
    }

    /// Called after provider shutdown and store/UI flush in applicationWillTerminate, never during a check or download.
    func authorizeCleanQuit() {
        guard state == .armed, let plan, let job, helper?.isRunning == true else { return }
        try? Data(plan.nonce.uuidString.utf8).write(to: job.appendingPathComponent("clean-quit"), options: .atomic)
    }

    func revealStagedUpdate() {
        guard let job else { return }
        NSWorkspace.shared.activateFileViewerSelecting([job])
    }
}
