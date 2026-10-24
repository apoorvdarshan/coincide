import Foundation

/// Observed provider accounting, separate from native transcript/history proof.
/// Each case is boxed so runtime events and retained run frames stay small.
public indirect enum ProviderUsageUpdate: Codable, Sendable, Equatable {
    case claude(ClaudeUsageSnapshot)

    public var provider: ProviderKind {
        switch self { case .claude: .claude }
    }

    public func validate(provider expected: ProviderKind, runID: UUID) throws {
        try validateProjection(provider: expected, runID: runID, live: false)
    }

    public func validateProjection(provider expected: ProviderKind, runID: UUID?, live: Bool) throws {
        guard provider == expected else { throw Self.invalid() }
        switch self {
        case .claude(let value):
            try value.validate()
            guard live && value.runID == nil || (runID != nil && value.runID == runID) else { throw Self.invalid() }
            if live && value.runID == nil { guard value.turn == nil else { throw Self.invalid() } }
        }
    }

    /// Producers publish whole snapshots. Session-cumulative counters must never
    /// be added to earlier snapshots or mistaken for another turn's delta.
    func canReplace(_ previous: Self?) -> Bool {
        guard let previous else { return true }
        switch (previous, self) {
        case (.claude(let old), .claude(let current)):
            return old.runID == current.runID && current.revision > old.revision
        }
    }

    private static func invalid() -> CoincideError {
        .init("Provider usage does not belong to this recorded run.")
    }
}

extension CodingThread {
    /// Latest passive status is separate from immutable completed-run accounting.
    /// A stale active-turn snapshot never becomes the next turn's live meter.
    public var liveProviderUsage: ProviderUsageUpdate? {
        guard provider == .claude, let value = providerMetadata?["claudeUsage"], value != .null,
              let data = try? JSONEncoder().encode(value), data.count <= 1_048_576,
              let snapshot = try? JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data),
              snapshot.runID == nil || snapshot.runID == activeRun?.id,
              snapshot.runID != nil || snapshot.turn == nil else { return nil }
        return .claude(snapshot)
    }
}
