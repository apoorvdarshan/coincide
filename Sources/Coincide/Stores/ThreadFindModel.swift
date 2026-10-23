import CoincideCore
import Foundation
import Observation

struct ThreadFindMatch: Hashable, Sendable {
    let messageID: String
    /// Zero-based occurrence within the message.
    let occurrence: Int
}

/// `chat.find`: searches every visible user and assistant message in the thread,
/// ignoring case and diacritics. Enter and Shift-Enter step with wraparound.
@MainActor @Observable
final class ThreadFindModel {
    nonisolated static let maxMatches = 2_000
    let threadID: UUID
    var query = "" { didSet { if query != oldValue { recompute(resetPosition: true) } } }
    private(set) var matches: [ThreadFindMatch] = []
    private(set) var currentIndex: Int?
    /// Increments when the field should take focus again (⌘F while open).
    private(set) var focusGeneration = 0
    /// Increments on every explicit step so the transcript scrolls even to the same message.
    private(set) var scrollGeneration = 0
    @ObservationIgnored private var messages: [ChatMessage] = []

    init(threadID: UUID, messages: [ChatMessage] = []) {
        self.threadID = threadID; self.messages = messages
    }

    var current: ThreadFindMatch? { currentIndex.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }
    var matchedMessageIDs: Set<String> { Set(matches.map(\.messageID)) }
    var status: String {
        if query.isEmpty { return "" }
        guard let currentIndex, !matches.isEmpty else { return String(localized: "No results") }
        return String(localized: "\(currentIndex + 1) of \(matches.count)")
    }

    func focus() { focusGeneration += 1 }

    /// Streaming and history changes keep the current match when it still exists.
    func update(messages: [ChatMessage]) {
        guard messages != self.messages else { return }
        self.messages = messages; recompute(resetPosition: false)
    }
    func next() { step(1) }
    func previous() { step(-1) }
    private func step(_ offset: Int) {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? (offset > 0 ? -1 : 0)) + offset + matches.count) % matches.count
        scrollGeneration += 1
    }
    private func recompute(resetPosition: Bool) {
        let previous = current
        matches = Self.matches(in: messages, query: query)
        if !resetPosition, let previous, let index = matches.firstIndex(of: previous) { currentIndex = index }
        else if matches.isEmpty { currentIndex = nil }
        else if resetPosition { currentIndex = 0; scrollGeneration += 1 }
        else { currentIndex = min(currentIndex ?? 0, matches.count - 1) }
    }

    nonisolated static func matches(in messages: [ChatMessage], query: String) -> [ThreadFindMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var result: [ThreadFindMatch] = []
        for message in messages where message.role == .user || message.role == .assistant {
            var searchRange = message.text.startIndex..<message.text.endIndex, occurrence = 0
            while let found = message.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: searchRange) {
                result.append(.init(messageID: message.id, occurrence: occurrence)); occurrence += 1
                guard result.count < maxMatches, found.upperBound < message.text.endIndex else { break }
                searchRange = found.upperBound..<message.text.endIndex
            }
            if result.count >= maxMatches { break }
        }
        return result
    }
}
