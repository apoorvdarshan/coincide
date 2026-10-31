import AppKit
import ApplicationServices
import CoincideKit
import CoreGraphics
import Foundation
import Observation

/// Settings › Computer Use, and each thread's private connection to it.
///
/// While Computer Use is on, every message an agent gets carries instructions with its thread's capability
/// (`ComputerUseBridge`), whichever provider runs it. The helper (`ComputerUseRuntime`) starts on the first call as
/// Coincide's child, so macOS counts its Accessibility and Screen Recording use as Coincide's, and stops when no thread
/// has used it for a while (it keeps the display awake while running), when Computer Use turns off or when Coincide
/// quits. Actions that change the screen take the shared desktop for one thread at a time; reading windows never waits.
@MainActor
@Observable
final class ComputerUseController {
    static let shared = ComputerUseController()

    enum Failure: LocalizedError {
        case accessibilityNeeded, desktopBusy

        var errorDescription: String? {
            switch self {
            case .accessibilityNeeded:
                String(localized: "Coincide doesn’t have Accessibility access yet. Ask the user to allow it in Settings › Computer Use.")
            case .desktopBusy:
                String(localized: "Another thread is using this Mac. Wait for it to finish, then try again.")
            }
        }
    }

    /// Tools that only read windows and the screen; every other allowed tool takes the shared desktop.
    static let readOnlyTools: Set<String> = [
        "list_apps", "list_windows", "get_window_state", "get_desktop_state", "verify_state", "zoom",
    ]
    /// How long a thread keeps the desktop after its last action unless it releases it first.
    static let desktopLease: TimeInterval = 60
    /// Screenshots kept in each thread's private folder; older ones are removed.
    static let screenshotLimit = 32
    /// Actions that press at the cursor, shown with a pulse.
    static let pressingTools: Set<String> = ["click", "double_click", "right_click", "drag"]

    @ObservationIgnored let bridge: ComputerUseBridge
    @ObservationIgnored let runtime: ComputerUseRuntime
    /// Draws the agent cursor on whichever display it acts on; tests replace it.
    @ObservationIgnored let cursor: AgentCursorPresenting
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private var observation: ObservationToken?
    @ObservationIgnored private var leaseExpiry: Date?
    /// Checks for Accessibility access; tests replace it.
    @ObservationIgnored var accessibilityCheck: () -> Bool = { AXIsProcessTrusted() }
    @ObservationIgnored var screenRecordingCheck: () -> Bool = { CGPreflightScreenCaptureAccess() }

    private(set) var isEnabled: Bool
    private(set) var isShowingAgentCursor: Bool
    private(set) var accessibilityGranted = false
    private(set) var screenRecordingGranted = false
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Threads with a helper connection, until they release it or lose access.
    private(set) var activeThreads: Set<UUID> = []
    /// The thread whose actions currently own the shared desktop.
    private(set) var desktopOwner: UUID?

    init(store: AppStore = .shared, bridge: ComputerUseBridge = ComputerUseBridge(), runtime: ComputerUseRuntime = ComputerUseRuntime(),
        cursor: AgentCursorPresenting = AgentCursorOverlay())
    {
        self.store = store
        self.bridge = bridge
        self.runtime = runtime
        self.cursor = cursor
        isEnabled = store.settings.computerUseEnabled
        isShowingAgentCursor = store.settings.computerUseShowsAgentCursor
        // An idle helper stopped on purpose: its sessions are gone, and the next request starts a fresh one.
        runtime.onIdleStop = { [weak self] in
            guard let self else { return }
            activeThreads.removeAll()
            releaseDesktop()
            cursor.hide()
            refresh()
        }
    }

    var enabled: Bool {
        get { isEnabled }
        set {
            store.updateSettings { $0.computerUseEnabled = newValue }
            apply()
        }
    }

    var showsAgentCursor: Bool {
        get { isShowingAgentCursor }
        set {
            store.updateSettings { $0.computerUseShowsAgentCursor = newValue }
            apply()
        }
    }

    var backendVersion: String { ComputerUseRuntime.backendVersion }

    var activeThreadTitles: [String] {
        activeThreads.compactMap { store.summary($0)?.title }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var stateDescription: String {
        guard isEnabled else { return String(localized: "Off") }
        if !accessibilityGranted { return String(localized: "Waiting for Accessibility access") }
        if let owner = desktopOwner, let title = store.summary(owner)?.title {
            return String(localized: "In use by “\(title)”")
        }
        return isRunning ? String(localized: "Ready") : String(localized: "Starts when an agent uses it")
    }

    func start() {
        guard observation == nil else { return }
        ThreadRunner.shared.ephemeralRuntimeContexts["computer-use"] = { [weak self] id in self?.runtimeContext(for: id) }
        runtime.onExit = { [weak self] in
            guard let self else { return }
            activeThreads.removeAll()
            releaseDesktop()
            cursor.hide()
            lastError = String(localized: "The computer-use helper stopped unexpectedly. It restarts on the next request.")
            refresh()
        }
        observation = store.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .settings: apply()
            case .threadList:
                for id in activeThreads where store.summary(id) == nil { revoke(id) }
            default: break
            }
        }
        apply()
    }

    func shutdown() {
        ThreadRunner.shared.ephemeralRuntimeContexts.removeValue(forKey: "computer-use")
        observation = nil
        bridge.stop()
        runtime.stop()
        activeThreads.removeAll()
        releaseDesktop()
        cursor.hide()
    }

    /// Follows the saved switch: turning it off ends every thread's access at once.
    private func apply() {
        let enabled = store.settings.computerUseEnabled
        defer { refresh() }
        isShowingAgentCursor = store.settings.computerUseShowsAgentCursor
        if !isShowingAgentCursor { cursor.hide() }
        guard enabled != isEnabled || (enabled && !bridge.isReady) else { return }
        isEnabled = enabled
        if enabled {
            lastError = nil
            Task { [weak self] in
                do { try await self?.bridge.prepare() } catch { self?.lastError = error.localizedDescription }
            }
        } else {
            bridge.stop()
            runtime.stop()
            activeThreads.removeAll()
            releaseDesktop()
            cursor.hide()
            lastError = nil
        }
    }

    func refresh() {
        accessibilityGranted = accessibilityCheck()
        screenRecordingGranted = screenRecordingCheck()
        isRunning = runtime.isRunning
        if let leaseExpiry, leaseExpiry < Date() { releaseDesktop() }
    }

    func restart() {
        runtime.stop()
        activeThreads.removeAll()
        releaseDesktop()
        cursor.hide()
        lastError = nil
        refresh()
        guard isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await runtime.start() } catch { lastError = error.localizedDescription }
            refresh()
        }
    }

    func stop() { enabled = false }

    // MARK: Permissions

    func requestAccessibility() {
        // The option's key, spelled out: the imported constant is a mutable global under strict concurrency.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refresh()
    }

    func requestScreenRecording() {
        // macOS asks once; after that the user changes the answer in System Settings.
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func openAccessibilitySettings() { openPrivacyPane("Privacy_Accessibility") }
    func openScreenRecordingSettings() { openPrivacyPane("Privacy_ScreenCapture") }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Agent access

    /// The instructions added to a message sent in `id`, with its capability; nil while Computer Use is off.
    func runtimeContext(for id: UUID) -> String? {
        guard isEnabled else { return nil }
        return bridge.enableNow(threadID: id, handler: handler(for: id))?.instructions
    }

    /// Grants access now, waiting for the listener if needed. For tests.
    @discardableResult
    func enableAccess(for id: UUID) async throws -> ComputerUseBridge.Access {
        try await bridge.enable(threadID: id, handler: handler(for: id))
    }

    private func handler(for id: UUID) -> ComputerUseBridge.Handler {
        { [weak self] request, directory in
            guard let self else { throw ComputerUseError.unavailable }
            return try await self.perform(request, threadID: id, directory: directory)
        }
    }

    func perform(_ request: ComputerUseRequest, threadID id: UUID, directory: URL) async throws -> JSONValue {
        guard isEnabled else { throw ComputerUseError.unavailable }
        refresh()
        defer { isRunning = runtime.isRunning }
        switch request {
        case .status:
            return status(for: id)
        case .release:
            release(id)
            return ["released": true]
        case .tools:
            let tools = try await recordingFailure { try await runtime.toolCatalog(threadID: id) }
            activeThreads.insert(id)
            return ["tools": .array(tools.compactMap(Self.publicTool))]
        case .call(let name, let arguments):
            guard accessibilityGranted else { throw Failure.accessibilityNeeded }
            let changesScreen = !Self.readOnlyTools.contains(name)
            if changesScreen { try claimDesktop(for: id) }
            let result = try await recordingFailure {
                try await runtime.call(threadID: id, name: name, arguments: .object(arguments))
            }
            // The call may have outlived the thread's access; its lease must not outlive it.
            guard isEnabled, bridge.access(for: id) != nil else { throw ComputerUseError.unavailable }
            activeThreads.insert(id)
            if changesScreen, desktopOwner == id { leaseExpiry = Date().addingTimeInterval(Self.desktopLease) }
            if changesScreen, isShowingAgentCursor, result["isError"]?.bool != true { await showCursor(for: id, after: name) }
            return Self.publicResult(result, directory: directory)
        }
    }

    /// Shows the cursor where the action happened, on that action's display. Never fails the action.
    private func showCursor(for id: UUID, after tool: String) async {
        guard let point = await runtime.cursorPosition(threadID: id), isEnabled, isShowingAgentCursor,
            bridge.access(for: id) != nil
        else { return }
        cursor.move(to: point, pressed: Self.pressingTools.contains(tool))
    }

    private func recordingFailure<T>(_ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            lastError = nil
            return value
        } catch let error as ComputerUseRuntime.Failure {
            if case .unknownTool = error {} else { lastError = error.localizedDescription }
            throw error
        }
    }

    private func status(for id: UUID) -> JSONValue {
        let desktop = desktopOwner == nil ? "free" : desktopOwner == id ? "this thread" : "another thread"
        return [
            "enabled": .bool(isEnabled), "running": .bool(runtime.isRunning), "driverVersion": .string(backendVersion),
            "accessibility": .bool(accessibilityGranted), "screenRecording": .bool(screenRecordingGranted),
            "desktop": .string(desktop),
        ]
    }

    private func claimDesktop(for id: UUID) throws {
        if let owner = desktopOwner, owner != id, let leaseExpiry, leaseExpiry > Date() { throw Failure.desktopBusy }
        desktopOwner = id
        leaseExpiry = Date().addingTimeInterval(Self.desktopLease)
    }

    private func releaseDesktop(_ id: UUID? = nil) {
        guard id == nil || desktopOwner == id else { return }
        desktopOwner = nil
        leaseExpiry = nil
    }

    /// Ends the thread's helper connection and its hold on the desktop; its capability stays valid.
    private func release(_ id: UUID) {
        runtime.end(threadID: id)
        activeThreads.remove(id)
        releaseDesktop(id)
        if activeThreads.isEmpty { cursor.hide() }
    }

    /// For a thread that no longer exists: also revokes its capability.
    private func revoke(_ id: UUID) {
        release(id)
        bridge.disable(threadID: id)
    }

    // MARK: Agent-facing shapes

    /// A tool as agents see it: Coincide owns the session, and options the policy rejects are left out.
    static func publicTool(_ tool: JSONValue) -> JSONValue? {
        guard let name = tool["name"]?.string, ComputerUseToolPolicy.allows(name), var object = tool.object else { return nil }
        let hidden: Set<String> = ["session", "screenshot_out_file", "debug_image_out"]
        if var schema = object["inputSchema"]?.object {
            if var properties = schema["properties"]?.object {
                for key in hidden { properties.removeValue(forKey: key) }
                schema["properties"] = .object(properties)
            }
            if let required = schema["required"]?.array {
                schema["required"] = .array(required.filter { !hidden.contains($0.string ?? "") })
            }
            object["inputSchema"] = .object(schema)
        }
        return .object(object.filter { ["name", "description", "inputSchema", "annotations"].contains($0.key) })
    }

    /// Writes images in a tool result to the thread's private folder and returns their paths in place of the data.
    static func publicResult(_ result: JSONValue, directory: URL) -> JSONValue {
        guard var object = result.object, let content = object["content"]?.array else { return result }
        var written: [URL] = []
        object["content"] = .array(content.map { item in
            guard item["type"]?.string == "image", let encoded = item["data"]?.string,
                let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
            else { return item }
            let mime = item["mimeType"]?.string ?? "image/png"
            let ext = mime == "image/jpeg" ? "jpg" : mime == "image/webp" ? "webp" : "png"
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let url = directory.appendingPathComponent("screenshot-\(stamp)-\(written.count + 1).\(ext)")
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return ["type": "text", "text": .string(String(localized: "A screenshot could not be saved."))]
            }
            written.append(url)
            return ["type": "image", "path": .string(url.path), "mimeType": .string(mime)]
        })
        if !written.isEmpty { pruneScreenshots(in: directory) }
        return .object(object)
    }

    private static func pruneScreenshots(in directory: URL) {
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let screenshots = files.filter { $0.lastPathComponent.hasPrefix("screenshot-") }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (url, _) in screenshots.dropFirst(screenshotLimit) { try? FileManager.default.removeItem(at: url) }
    }
}
