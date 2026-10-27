import AppKit
import CoincideKit

/// Which text of a transcript row a find match is in.
enum TranscriptFindField: Hashable {
    /// A message, reply, thought, plan, error or notice.
    case body
    /// The one-line title of a tool call, approval or question.
    case title
    /// A tool call's input and output, or what an approval asks to run.
    case detail
}

/// One occurrence of the find query in the text a row shows.
struct TranscriptFindMatch: Hashable {
    var itemID: UUID
    var field: TranscriptFindField
    /// In the field's displayed text: rendered Markdown, a tool call's expanded output or a title label.
    var range: NSRange
}

/// The matches one row highlights, and the current match when it is in that row.
struct TranscriptFindHighlights: Equatable {
    var matches: [TranscriptFindMatch] = []
    var current: TranscriptFindMatch?

    func ranges(in field: TranscriptFindField) -> [NSRange] {
        matches.filter { $0.field == field }.map(\.range)
    }

    func currentRange(in field: TranscriptFindField) -> NSRange? {
        current?.field == field ? current?.range : nil
    }
}

/// Where a cell shows a find match, for scrolling to it and pointing it out.
struct TranscriptFindTarget {
    /// In the cell's coordinates.
    var rect: NSRect
    /// The text view that draws the match, for the find indicator. Nil for labels.
    var textView: NSTextView?
    var range: NSRange
}

// MARK: - Look

/// Find highlights, as in Safari and Xcode: every match tinted, the current one in solid find yellow.
@MainActor
enum TranscriptFindStyle {
    static let match = Theme.dynamic(.findHighlightColor, alpha: 0.38)
    static let current = NSColor.findHighlightColor
    /// The current match keeps dark text on its yellow, in dark mode too.
    static let currentText = NSColor.black

    /// A label's text with its matches highlighted.
    static func highlight(_ text: NSAttributedString, ranges: [NSRange], current: NSRange?) -> NSAttributedString {
        guard !ranges.isEmpty || current != nil else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for range in ranges where NSMaxRange(range) <= result.length {
            result.addAttribute(.backgroundColor, value: match, range: range)
        }
        if let current, NSMaxRange(current) <= result.length {
            result.addAttributes([.backgroundColor: Self.current, .foregroundColor: currentText], range: current)
        }
        return result
    }
}

// MARK: - Searchable text

/// The text each row shows, as the find bar searches it. Rows draw exactly these strings, so a match's
/// range is also its range in the row's text view or label.
@MainActor
enum TranscriptFindText {
    static func fields(of item: TranscriptItem, showReasoning: Bool, cache: TranscriptTextCache) -> [(TranscriptFindField, String)] {
        switch item.kind {
        case .user:
            guard item.text.nonBlank != nil else { return [] }
            return [(.body, TranscriptText.markdown(item, .user, cache: cache).string.string)]
        case .assistant:
            guard item.text.nonBlank != nil else { return [] }
            return [(.body, TranscriptText.markdown(item, .assistant, cache: cache).string.string)]
        case .plan:
            guard item.text.nonBlank != nil else { return [] }
            return [(.body, TranscriptText.markdown(item, .plan, cache: cache).string.string)]
        case .reasoning:
            guard showReasoning, item.text.nonBlank != nil else { return [] }
            return [(.body, TranscriptText.markdown(item, .reasoning, cache: cache).string.string)]
        case .tool:
            var fields: [(TranscriptFindField, String)] = [(.title, TranscriptToolCell.title(item).string)]
            if TranscriptToolDetail.hasDetail(item) {
                fields.append((.detail, TranscriptToolDetail.text(for: item, cache: cache).string.string))
            }
            return fields
        case .approval:
            var fields: [(TranscriptFindField, String)] = [(.title, TranscriptApprovalCell.title(item, cache: cache).string.string)]
            if TranscriptApprovalCell.detail(item) != nil {
                fields.append((.detail, TranscriptApprovalCell.detailText(item, cache: cache).string.string))
            }
            return fields
        case .question:
            guard let request = item.questions else { return [] }
            return [(.title, TranscriptQuestionCell.title(request).string)]
        case .error:
            return [(.body, TranscriptErrorCell.text(item, cache: cache).string.string)]
        case .notice:
            return [(.body, TranscriptNoticeCell.label(item))]
        }
    }

    /// What the item's rows are rendered from. Rendering removes Markdown syntax and adds list markers and
    /// labels, but never makes up words, so an item whose sources lack a word of the query cannot show it.
    static func sources(of item: TranscriptItem) -> [String] {
        switch item.kind {
        case .tool:
            [item.title ?? TranscriptLabels.categoryName(item.category ?? .other), item.detail ?? "", item.text]
        case .approval:
            [item.title ?? TranscriptApprovalCell.kindLabel(item.category), item.detail ?? ""]
        case .question:
            [item.questions.map(TranscriptQuestionCell.titleSource) ?? ""]
        default:
            [item.text]
        }
    }
}

// MARK: - Search

/// The find bar's search over one thread: every match in transcript order and which one is current.
/// Like T3 Code's thread find it ignores case but not accents, and counts matches in folded work too.
/// Items are searched again only when they change, so following a streaming reply stays cheap.
@MainActor
final class TranscriptFinder {
    /// Matches past this many are not collected; the count then reads "5000+".
    static let matchLimit = 5000
    static let maxQueryLength = 200

    private(set) var query = ""
    private(set) var matches: [TranscriptFindMatch] = []
    /// More matches exist than `matchLimit`.
    private(set) var isTruncated = false
    private(set) var currentIndex: Int?
    /// Indexes into `matches`, per item.
    private var byItem: [UUID: [Int]] = [:]
    /// Matches per item and the item revision they were found in.
    private var cache: [UUID: (revision: Int, matches: [TranscriptFindMatch])] = [:]
    private var showsReasoning = true

    var current: TranscriptFindMatch? { currentIndex.map { matches[$0] } }

    func highlights(for itemID: UUID) -> TranscriptFindHighlights? {
        guard let indexes = byItem[itemID] else { return nil }
        return TranscriptFindHighlights(
            matches: indexes.map { matches[$0] }, current: current?.itemID == itemID ? current : nil)
    }

    /// Searches `items` for `query`. With `keepingCurrent` the current match stays current while it exists,
    /// as when output streams in; otherwise, or once it is gone, the first match from `start` (an item id,
    /// such as the first one on screen) becomes current, wrapping around to the first match.
    func search(
        _ query: String, in items: [TranscriptItem], revisions: [UUID: Int], showReasoning: Bool,
        textCache: TranscriptTextCache, keepingCurrent: Bool, from start: UUID?
    ) {
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQueryLength))
        let previous = keepingCurrent && query == self.query ? current.map { ($0, occurrence(of: $0)) } : nil
        if query != self.query || showReasoning != showsReasoning { cache.removeAll() }
        self.query = query
        showsReasoning = showReasoning

        var found: [TranscriptFindMatch] = []
        var indexes: [UUID: [Int]] = [:]
        var fresh: [UUID: (revision: Int, matches: [TranscriptFindMatch])] = [:]
        var truncated = false
        if !query.isEmpty {
            let words = Self.words(of: query)
            for item in items {
                let revision = revisions[item.id] ?? 0
                let matches: [TranscriptFindMatch]
                if let cached = cache[item.id], cached.revision == revision {
                    matches = cached.matches
                } else {
                    matches = Self.matches(of: query, words: words, in: item, showReasoning: showReasoning, cache: textCache)
                }
                fresh[item.id] = (revision, matches)
                guard !matches.isEmpty else { continue }
                let room = Self.matchLimit - found.count
                let kept = matches.prefix(room)
                indexes[item.id] = Array(found.count..<(found.count + kept.count))
                found += kept
                if matches.count > room {
                    truncated = true
                    break
                }
            }
        }
        cache = fresh
        matches = found
        byItem = indexes
        isTruncated = truncated

        guard !found.isEmpty else {
            currentIndex = nil
            return
        }
        if let (match, occurrence) = previous, let index = index(of: match, occurrence: occurrence) {
            currentIndex = index
            return
        }
        let anchor = previous?.0.itemID ?? start
        currentIndex = anchor.flatMap { firstMatch(from: $0, in: items) } ?? 0
    }

    /// Moves to the next (1) or previous (-1) match, wrapping around.
    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let index = currentIndex ?? (delta > 0 ? -1 : 0)
        currentIndex = ((index + delta) % matches.count + matches.count) % matches.count
    }

    func reset() {
        query = ""
        matches = []
        byItem = [:]
        cache = [:]
        currentIndex = nil
        isTruncated = false
    }

    // MARK: Helpers

    /// Which occurrence in its item and field the match is, so it can be found again after its text grew.
    private func occurrence(of match: TranscriptFindMatch) -> Int {
        (byItem[match.itemID] ?? []).map { matches[$0] }.filter { $0.field == match.field }.firstIndex(of: match) ?? 0
    }

    private func index(of match: TranscriptFindMatch, occurrence: Int) -> Int? {
        let inField = (byItem[match.itemID] ?? []).filter { matches[$0].field == match.field }
        return inField.indices.contains(occurrence) ? inField[occurrence] : nil
    }

    /// The first match in `itemID` or after it, in transcript order.
    private func firstMatch(from itemID: UUID, in items: [TranscriptItem]) -> Int? {
        guard let start = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        for item in items[start...] {
            if let first = byItem[item.id]?.first { return first }
        }
        return nil
    }

    /// Letters and digits of the query, for skipping items whose sources cannot contain it.
    static func words(of query: String) -> [String] {
        query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func matches(
        of query: String, words: [String], in item: TranscriptItem, showReasoning: Bool, cache: TranscriptTextCache
    ) -> [TranscriptFindMatch] {
        if !words.isEmpty {
            let sources = TranscriptFindText.sources(of: item)
            let possible = words.allSatisfy { word in sources.contains { $0.range(of: word, options: .caseInsensitive) != nil } }
            guard possible else { return [] }
        }
        var matches: [TranscriptFindMatch] = []
        for (field, text) in TranscriptFindText.fields(of: item, showReasoning: showReasoning, cache: cache) {
            for range in ranges(of: query, in: text) {
                matches.append(TranscriptFindMatch(itemID: item.id, field: field, range: range))
            }
        }
        return matches
    }

    /// Every occurrence of `query` in `text`, ignoring case.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let string = text as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let found = string.range(
                of: query, options: .caseInsensitive, range: NSRange(location: location, length: string.length - location))
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            location = NSMaxRange(found)
        }
        return ranges
    }
}
