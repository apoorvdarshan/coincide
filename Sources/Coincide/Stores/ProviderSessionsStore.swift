import CoincideCore
import Foundation
import Observation

@MainActor @Observable
final class ProviderSessionsStore {
    private(set) var scope: ProviderSessionsScope
    private(set) var snapshot: ProviderSessionsSnapshot?
    private(set) var isRefreshing = false
    private(set) var inspectingID: String?
    private(set) var stoppingID: String?
    private(set) var errorMessage: String?
    var details: ProviderSessionDetails?
    var search = ""
    var activeOnly = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(scope: ProviderSessionsScope) { self.scope = scope }
    var isBusy: Bool { isRefreshing || inspectingID != nil || stoppingID != nil }
    var sessions: [ProviderSessionSummary] {
        (snapshot?.sessions ?? []).filter { session in
            (!activeOnly || session.state.isActive) && (search.isEmpty ||
                session.title.localizedCaseInsensitiveContains(search) ||
                session.directory.localizedCaseInsensitiveContains(search) ||
                session.nativeID.localizedCaseInsensitiveContains(search))
        }
    }
    func configure(_ newScope: ProviderSessionsScope) {
        guard scope != newScope else { return }
        close(); scope = newScope; snapshot = nil; details = nil; errorMessage = nil
    }
    func close() {
        generation = UUID(); operation?.cancel(); operation = nil
        isRefreshing = false; inspectingID = nil; stoppingID = nil
    }
    func refresh() {
        guard !isBusy else { return }
        let token = begin(), captured = scope
        isRefreshing = true
        operation = Task {
            defer { if generation == token { isRefreshing = false; operation = nil } }
            do {
                let result = try await ProviderSessionsService.list(scope: captured)
                guard generation == token, !Task.isCancelled else { return }
                snapshot = result
            } catch is CancellationError { }
            catch { if generation == token { errorMessage = error.localizedDescription } }
        }
    }
    func inspect(_ session: ProviderSessionSummary) {
        guard !isBusy, snapshot?.sessions.contains(where: { $0.id == session.id }) == true else { return }
        let token = begin(), captured = scope
        inspectingID = session.id
        operation = Task {
            defer { if generation == token { inspectingID = nil; operation = nil } }
            do {
                let value = try await ProviderSessionsService.details(scope: captured, session: session)
                guard generation == token, !Task.isCancelled else { return }
                details = value
            } catch is CancellationError { }
            catch { if generation == token { errorMessage = error.localizedDescription } }
        }
    }
    func stop(_ session: ProviderSessionSummary) {
        guard !isBusy, session.canStop, snapshot?.sessions.contains(where: { $0.id == session.id }) == true else { return }
        let token = begin(), captured = scope
        stoppingID = session.id
        operation = Task {
            defer { if generation == token { stoppingID = nil; operation = nil } }
            do {
                try await ProviderSessionsService.stop(scope: captured, session: session)
                let result = try await ProviderSessionsService.list(scope: captured)
                guard generation == token, !Task.isCancelled else { return }
                snapshot = result; details = nil
            } catch is CancellationError { }
            catch { if generation == token { errorMessage = error.localizedDescription } }
        }
    }
    private func begin() -> UUID {
        generation = UUID(); errorMessage = nil
        return generation
    }
}
