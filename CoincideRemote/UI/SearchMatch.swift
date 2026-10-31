import Foundation

/// What the search field matches, as the Mac sidebar's search does: every word of the query, in any order, ignoring
/// case and accents. Plain text matching, so `CoincideTests/RemoteLayoutTests.swift` tests it on the Mac too.
nonisolated struct SearchMatch {
    let words: [String]

    init(_ query: String) {
        words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { words.isEmpty }

    /// Every word is in one of the texts.
    func matches(_ texts: String...) -> Bool {
        words.allSatisfy { word in texts.contains { $0.localizedStandardContains(word) } }
    }
}
