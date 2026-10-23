import CoincideCore
import Foundation
import Observation
import SwiftUI

struct RemoteProviderUsageContentAccess {
    let connected: @MainActor () -> Bool
    let document: @MainActor (RemoteProjectionContentReference, RemoteProjectionBinding) async throws -> Data
    init(store: RemoteProjectionStore) {
        connected = { store.connected }
        document = { reference, binding in try await store.document(reference, binding: binding) }
    }
    init(connected: @escaping @MainActor () -> Bool,
         document: @escaping @MainActor (RemoteProjectionContentReference, RemoteProjectionBinding) async throws -> Data) {
        self.connected = connected; self.document = document
    }
}

struct RemoteProviderUsageCapture: Equatable {
    let binding: RemoteProjectionBinding
    let reference: RemoteProjectionContentReference
    let provider: ProviderKind
    let runID: UUID?
    let live: Bool
    func validate() throws {
        guard reference.kind == .providerUsage, reference.totalBytes > 0, reference.totalBytes <= 1_048_576,
              reference.digest.utf8.count == 64, reference.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              binding.sequence >= 0 else { throw RemoteProjectionFailure(.invalidRequest) }
        switch binding.scope {
        case .catalog: throw RemoteProjectionFailure(.invalidRequest)
        case .control: guard live else { throw RemoteProjectionFailure(.invalidRequest) }
        case .thread: break
        }
        guard live || runID != nil else { throw RemoteProjectionFailure(.invalidRequest) }
    }
}

/// Owns an explicit read from one immutable projection lease. A new selection
/// never supplies the binding for an older reference or a late publication.
@MainActor @Observable final class RemoteProviderUsageReader {
    private(set) var value: ProviderUsageUpdate?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    @ObservationIgnored private(set) var capture: RemoteProviderUsageCapture?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reads: [UUID: Task<ProviderUsageUpdate, any Error>] = [:]
    func load(_ captured: RemoteProviderUsageCapture, access: RemoteProviderUsageContentAccess) async {
        guard !isLoading || capture != captured else { return }
        cancel(); capture = captured
        guard access.connected() else { errorMessage = String(localized: "Reconnect before loading observed usage."); return }
        do { try captured.validate() }
        catch { errorMessage = Self.unavailable; return }
        let owner = generation, token = UUID()
        isLoading = true; errorMessage = nil
        let task = Task<ProviderUsageUpdate, any Error> {
            try Task.checkCancellation()
            let data = try await access.document(captured.reference, captured.binding)
            try Task.checkCancellation()
            guard data.count == captured.reference.totalBytes,
                  RemoteProjectionProtocol.digest(data) == captured.reference.digest else { throw RemoteProjectionFailure(.invalidRequest) }
            let decoded = try JSONDecoder().decode(ProviderUsageUpdate.self, from: data)
            try decoded.validateProjection(provider: captured.provider, runID: captured.runID, live: captured.live)
            return decoded
        }
        reads[token] = task
        defer { reads.removeValue(forKey: token); if owner == generation { isLoading = false } }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard owner == generation, capture == captured, !Task.isCancelled else { return }
            value = result
        } catch {
            guard owner == generation, capture == captured, !Task.isCancelled else { return }
            errorMessage = Self.unavailable
        }
    }
    func cancel() {
        generation = UUID(); for task in reads.values { task.cancel() }
        capture = nil; value = nil; isLoading = false; errorMessage = nil
    }
    func shutdown() async {
        let owned = Array(reads.values); cancel()
        for task in owned { _ = await task.result }
    }
    static var unavailable: String { String(localized: "Observed usage is unavailable for this captured view. Refresh the view and load again.") }
}

struct RemoteProviderUsageView: View {
    let binding: RemoteProjectionBinding
    let contentAccess: RemoteProviderUsageContentAccess
    let provider: ProviderKind
    let runID: UUID?
    let inline: ProviderUsageUpdate?
    let reference: RemoteProjectionContentReference?
    var live = false
    @State private var reader = RemoteProviderUsageReader()
    private var captured: RemoteProviderUsageCapture? {
        reference.map { .init(binding: binding, reference: $0, provider: provider, runID: runID, live: live) }
    }
    private var value: ProviderUsageUpdate? {
        if reference != nil && inline != nil { return nil }
        if let inline {
            guard (try? inline.validateProjection(provider: provider, runID: runID, live: live)) != nil else { return nil }
            return inline
        }
        guard reader.capture == captured else { return nil }
        return reader.value
    }
    private var validReference: Bool { captured.map { (try? $0.validate()) != nil } == true && inline == nil }
    private var showMainAgent: Bool {
        guard live, let value, case .claude(let snapshot) = value else { return true }
        return snapshot.runID != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let value { ProviderUsageView(usage: value, showMainAgent: showMainAgent) }
            else if let captured, validReference {
                Text("The full observed usage report is stored with this captured remote view.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Load Observed Usage") { Task { await reader.load(captured, access: contentAccess) } }
                        .disabled(reader.isLoading || !contentAccess.connected()).accessibilityIdentifier("remote-provider-usage-load")
                    if reader.isLoading { ProgressView().controlSize(.small) }
                }
            } else if inline != nil || reference != nil {
                Text(RemoteProviderUsageReader.unavailable).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Observed usage was not reported for this view.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = reader.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("remote-provider-usage")
            .onChange(of: captured) { _, _ in reader.cancel() }
            .onDisappear { reader.cancel() }
    }
}
