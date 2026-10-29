import Foundation

/// An agent's "your turn" request in one thread's browser: a short message the panel shows with a Done button,
/// which the agent's bridge call waits on. One request is open at a time; a new one replaces the old, which ends as
/// `superseded`.
@MainActor
public final class UserTurnGate {
    public enum Result: String, Sendable, Equatable {
        case done
        case declined
        case timeout
        case superseded
        case cancelled
    }

    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let message: String
    }

    public nonisolated static let maximumMessage = 500
    public nonisolated static let defaultTimeout: TimeInterval = 300
    public nonisolated static let maximumTimeout: TimeInterval = 900

    public private(set) var request: Request?
    public var onChange: (() -> Void)?
    private var continuation: CheckedContinuation<Result, Never>?

    public init() {}

    /// Shows `message` and waits until the user answers, the timeout passes, or another request replaces it.
    public func ask(_ message: String, timeout: TimeInterval) async -> Result {
        finish(.superseded)
        let text = Self.clean(message)
        let id = UUID()
        request = Request(id: id, message: text)
        onChange?()
        let seconds = min(max(timeout, 1), Self.maximumTimeout)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.request?.id == id else { return }
            self.finish(.timeout)
        }
        return await withCheckedContinuation { continuation in
            // A request finished before this point (it can't be, on the main actor) would have no continuation.
            if request?.id == id { self.continuation = continuation } else { continuation.resume(returning: .cancelled) }
        }
    }

    /// The user's answer, or the end of the request for another reason.
    public func finish(_ result: Result) {
        guard request != nil || continuation != nil else { return }
        request = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: result)
        onChange?()
    }

    /// One plain line or paragraph: control characters dropped, bounded, never empty.
    static func clean(_ message: String) -> String {
        let scalars = message.unicodeScalars.map { scalar -> Character in
            scalar == "\n" ? "\n" : CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        var text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumMessage { text = String(text.prefix(maximumMessage - 1)) + "…" }
        return text.isEmpty ? String(localized: "The agent needs you to continue in the browser.") : text
    }
}
