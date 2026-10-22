import CoincideCore
import Foundation
import Observation

/// An observer may see another window's installation, but teardown only joins
/// the exact operation this store started. Account setup is a separate owner.
@MainActor @Observable final class AntigravityInstallationStore {
    struct Client: Sendable {
        var state: @Sendable () -> AntigravityInstallationState
        var updates: @Sendable () -> AsyncStream<AntigravityInstallationState>
        var start: @Sendable () throws -> UUID
        var cancel: @Sendable (UUID) async throws -> Void
        var remove: @Sendable ([String]) throws -> Void
        init(installation: AntigravityInstallation) {
            state = { installation.state() }; updates = { installation.updates() }
            start = { try installation.start() }; cancel = { try await installation.cancel(operationID: $0) }
            remove = { try installation.remove(protectedCustomPaths: $0) }
        }
        init(state: @escaping @Sendable () -> AntigravityInstallationState,
             updates: @escaping @Sendable () -> AsyncStream<AntigravityInstallationState>,
             start: @escaping @Sendable () throws -> UUID,
             cancel: @escaping @Sendable (UUID) async throws -> Void,
             remove: @escaping @Sendable ([String]) throws -> Void) {
            self.state = state; self.updates = updates; self.start = start; self.cancel = cancel; self.remove = remove
        }
    }
    private(set) var state: AntigravityInstallationState
    private(set) var errorMessage: String?
    private(set) var isCancelling = false
    @ObservationIgnored private let client: Client
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var ownedOperations: Set<UUID> = []
    @ObservationIgnored private var cancellations: [UUID: Task<Void, any Error>] = [:]
    @ObservationIgnored private var protectedCustomPaths: @MainActor () -> [String] = { [] }
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    convenience init(installation: AntigravityInstallation = .shared) { self.init(client: .init(installation: installation)) }
    init(client: Client) {
        self.client = client; state = client.state()
        observer = Task { [weak self] in
            for await value in client.updates() {
                guard !Task.isCancelled, let self else { return }
                self.state = value
            }
        }
    }
    func bind(protectedCustomPaths: @escaping @MainActor () -> [String]) { self.protectedCustomPaths = protectedCustomPaths }
    var isWorking: Bool { state.phase.isWorking || isCancelling }
    var canStart: Bool { !closed && !isWorking }
    var canRemove: Bool { !closed && !isWorking && state.canRemove }
    var progress: Double? {
        guard let total = state.totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(state.downloadedBytes) / Double(total)))
    }
    var progressText: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: max(0, state.downloadedBytes), countStyle: .file)
        guard let total = state.totalBytes, total > 0 else { return downloaded }
        return String(localized: "\(downloaded) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
    }
    var startTitle: String {
        guard let installed = state.installedVersion else { return String(localized: "Install Runtime") }
        if let target = state.version, target != installed { return String(localized: "Update Runtime") }
        return String(localized: "Verify Installed Runtime")
    }
    var statusText: String {
        if isCancelling { return String(localized: "Stopping runtime installation…") }
        return switch state.phase {
        case .idle: state.installedVersion == nil ? String(localized: "Managed runtime is not installed") : String(localized: "Managed runtime is installed")
        case .downloading: String(localized: "Downloading runtime…")
        case .extracting: String(localized: "Unpacking runtime…")
        case .verifying: String(localized: "Verifying runtime…")
        case .succeeded: String(localized: "Managed runtime verified")
        case .failed: String(localized: "Runtime installation could not finish")
        case .cancelled: String(localized: "Runtime installation cancelled")
        }
    }
    func start() {
        guard canStart else { return }
        errorMessage = nil
        do { let id = try client.start(); ownedOperations.insert(id); state = client.state() }
        catch { errorMessage = String(localized: "The managed runtime could not be installed or verified. Check available disk space and try again.") }
    }
    func cancel() async {
        guard !closed, !isCancelling, isWorking, let id = state.operationID else { return }
        isCancelling = true; defer { isCancelling = false }
        do { try await cancellation(for: id).value; state = client.state() }
        catch { errorMessage = String(localized: "Runtime cancellation could not be confirmed. Wait for the installation to stop before trying again.") }
        cancellations.removeValue(forKey: id)
    }
    func remove() {
        guard canRemove else { return }
        errorMessage = nil
        do { try client.remove(protectedCustomPaths()); state = client.state() }
        catch { errorMessage = String(localized: "The managed runtime could not be removed. Stop runtime verification or conversations using it, and check custom runtime paths before trying again.") }
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true
        let task = Task { [self] in await drainOwnedOperations() }
        shutdownTask = task; await task.value
    }
    private func drainOwnedOperations() async {
        // Explicit cancellation may already be draining the same operation.
        for id in ownedOperations {
            _ = try? await cancellation(for: id).value
            cancellations.removeValue(forKey: id)
        }
        for task in cancellations.values { _ = try? await task.value }
        state = client.state()
        observer?.cancel(); await observer?.value; observer = nil
    }
    private func cancellation(for id: UUID) -> Task<Void, any Error> {
        if let task = cancellations[id] { return task }
        let client = client, task = Task { try await client.cancel(id) }
        cancellations[id] = task; return task
    }
}
