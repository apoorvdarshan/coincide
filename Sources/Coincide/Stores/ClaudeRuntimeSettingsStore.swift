import CoincideCore
import Foundation
import Observation

/// Default profile for future conversations. Existing threads, queued inputs,
/// and historical runs continue using their immutable runtime capture.
@MainActor @Observable final class ClaudeRuntimeSettingsStore {
    private(set) var profile = ClaudeRuntimeProfile()
    private var executableValue = "claude"
    private var directoryValue = ""
    private var thresholdValue = ""
    var executable: String {
        get { executableValue }
        set { if acceptsEdits { executableValue = newValue } }
    }
    var configurationDirectory: String {
        get { directoryValue }
        set { if acceptsEdits { directoryValue = newValue } }
    }
    var autoCompactWindowText: String {
        get { thresholdValue }
        set { if acceptsEdits { thresholdValue = newValue } }
    }
    private(set) var isLoading = false
    private(set) var isApplying = false
    private(set) var errorMessage: String?
    private(set) var isLoaded = false
    private var closed = false
    private var persistenceFailed = false
    @ObservationIgnored private let preferences: ClaudeRuntimeProfilePreferences
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var application: Task<Void, Never>?
    init(rootURL: URL? = nil) {
        let root = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Coincide", isDirectory: true)
        preferences = .init(root: root.appendingPathComponent("ClaudeSettings", isDirectory: true))
    }
    var acceptsEdits: Bool { !closed && !isApplying && !isLoading }
    var draftProfile: ClaudeRuntimeProfile? {
        let threshold: Int?
        if thresholdValue.isEmpty { threshold = nil }
        else {
            guard thresholdValue.utf8.allSatisfy({ (48...57).contains($0) }),
                  thresholdValue.first != "0", thresholdValue.count <= 7,
                  let value = Int(thresholdValue), (100_000...1_000_000).contains(value) else { return nil }
            threshold = value
        }
        return try? profile.editing(executable: executableValue, configurationDirectory: directoryValue.isEmpty ? nil : directoryValue,
            autoCompactWindow: threshold)
    }
    var hasUnappliedChanges: Bool {
        guard let draftProfile else { return true }
        return !draftProfile.executable.utf8.elementsEqual(profile.executable.utf8) ||
            draftProfile.configurationDirectory.map { Array($0.utf8) } != profile.configurationDirectory.map { Array($0.utf8) } ||
            draftProfile.autoCompactWindow != profile.autoCompactWindow
    }
    var hasUnsavedChanges: Bool { persistenceFailed || isApplying || hasUnappliedChanges }
    var canApply: Bool { acceptsEdits && isLoaded && draftProfile != nil && hasUnappliedChanges }
    func load() async {
        if let loading { await loading.value; return }
        guard !closed, !isApplying else { return }
        isLoading = true
        let task = Task { [self] in
            defer { isLoading = false; loading = nil }
            do {
                let loaded = try await preferences.load()
                profile = loaded; restoreFields(); isLoaded = true; persistenceFailed = false; errorMessage = nil
            } catch {
                isLoaded = false; persistenceFailed = true
                errorMessage = String(localized: "The saved Claude profile could not be read safely. Its file has been preserved. Resolve the settings conflict, then reload.")
            }
        }
        loading = task; await task.value
    }
    func applySelection() async {
        guard canApply, let target = draftProfile else { return }
        isApplying = true; errorMessage = nil
        let task = Task { [self] in
            defer { isApplying = false; application = nil }
            do {
                try await preferences.save(target)
                // Publish only after the exact previous preference was replaced
                // durably. A conflict never changes the selected session profile.
                profile = target; restoreFields(); persistenceFailed = false
            } catch {
                persistenceFailed = true; isLoaded = false
                errorMessage = String(localized: "The Claude profile could not be saved safely. The selected profile has not changed. Reload saved settings before applying again.")
            }
        }
        application = task; await task.value
    }
    func useCLIDefaults() {
        guard acceptsEdits else { return }
        executableValue = "claude"; directoryValue = ""; thresholdValue = ""
    }
    func discardEdits() { guard acceptsEdits else { return }; restoreFields() }
    func shutdown() async {
        closed = true
        await loading?.value; await application?.value
    }
    func cancelShutdown() { closed = false }
    private func restoreFields() {
        executableValue = profile.executable; directoryValue = profile.configurationDirectory ?? ""
        thresholdValue = profile.autoCompactWindow.map(String.init) ?? ""
    }
}
