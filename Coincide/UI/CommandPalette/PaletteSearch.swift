import Foundation

/// Word-start search with typo tolerance, ported from T3's palette ranking
/// (`packages/shared/src/paletteSearch.ts`). Every query word must start a word somewhere
/// ("sid" finds "Fix sidebar"), may run words together ("vscode" finds "VS Code"), and,
/// when nothing matches exactly, may contain one typo. Inside-word hits need four letters
/// and only count in titles, so "del" does not find "model".
enum PaletteSearch {
    /// A searchable string, folded once and cached.
    struct Field {
        /// Case- and accent-folded, one entry per character of the source.
        let text: [Character]
        let wordStarts: [Bool]
        /// UTF-16 offset of each character in the source, plus the total length, for highlighting.
        let utf16Offsets: [Int]
    }

    /// A query folded and split into words once per keystroke.
    struct Query {
        /// Folded, with whitespace collapsed; empty when there is nothing to match.
        let text: String
        let characters: [Character]
        let tokens: [[Character]]
        /// Under four meaningful letters, so hidden keywords must match whole words.
        let isShort: Bool

        init(_ raw: String) {
            text = PaletteSearch.normalize(raw)
            characters = Array(text)
            tokens = text.split(separator: " ").map { Array($0) }
            // Filler words ("the ci") do not make a short query long.
            let meaningful = tokens.filter { !PaletteSearch.fillerWords.contains(String($0)) }
            let words = meaningful.isEmpty ? tokens : meaningful
            isShort = words.map(\.count).reduce(0, +) + max(0, words.count - 1) < 4
        }

        var isEmpty: Bool { tokens.isEmpty }
    }

    struct WeightedField {
        var value: String
        var weight: Double
        /// Only a whole-word match counts.
        var wholeWords = false
        /// Only a word-start match counts, without typos: hidden keywords must not match loosely.
        var keyword = false
        /// Where the item lives (its project): helps a match but never makes it strong.
        var context = false
        /// A word of four or more letters may match inside a word. Titles only.
        var midWord = false
    }

    struct Match {
        /// Roughly 0.3 (inside a word) to 1.5 (the whole name).
        var quality: Double
        /// What results sort by within a match class: quality times recent use.
        var score: Double
        /// The class the item's group ranks by, when lower than its own.
        var groupQuality: Double?
        /// Every word matched at a word start, without a typo.
        var strong: Bool
        /// Matched ranges in the first field, for highlighting.
        var ranges: [NSRange]
    }

    private static let wholeWord = 1.0
    private static let wholeName = 1.5
    private static let midWordScore = 0.3
    private static let typoScore = 0.45
    private static let joinedWordsScore = 0.6
    fileprivate static let fillerWords: Set<String> = ["a", "an", "and", "for", "in", "of", "on", "the", "to", "with"]
    private static let recencyHalfLife: TimeInterval = 14 * 24 * 3600

    // MARK: Folding

    private static var cache: [String: Field] = [:]

    static func field(_ source: String) -> Field {
        if let cached = cache[source] { return cached }
        if cache.count > 50_000 { cache.removeAll(keepingCapacity: true) }
        let characters = Array(source)
        var text: [Character] = []
        var starts: [Bool] = []
        var offsets: [Int] = []
        text.reserveCapacity(characters.count)
        starts.reserveCapacity(characters.count)
        offsets.reserveCapacity(characters.count + 1)
        var offset = 0
        for (index, character) in characters.enumerated() {
            text.append(fold(character))
            starts.append(
                isWordStart(
                    beforePrevious: index > 1 ? characters[index - 2] : nil, previous: index > 0 ? characters[index - 1] : nil,
                    character: character, next: index + 1 < characters.count ? characters[index + 1] : nil))
            offsets.append(offset)
            offset += character.utf16.count
        }
        offsets.append(offset)
        let field = Field(text: text, wordStarts: starts, utf16Offsets: offsets)
        cache[source] = field
        return field
    }

    /// The query folded and with whitespace collapsed; empty when there is nothing to match.
    static func normalize(_ query: String) -> String {
        let quotes = CharacterSet(charactersIn: "\"'`“”‘’")
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: quotes)
        let folded = String(trimmed.precomposedStringWithCanonicalMapping.map(fold))
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func fold(_ character: Character) -> Character {
        if let ascii = character.asciiValue {
            return ascii >= 65 && ascii <= 90 ? Character(Unicode.Scalar(ascii + 32)) : character
        }
        if character == "‘" || character == "’" { return "'" }
        // Letters that fold to more than one character ("ß") stay as they are, so offsets still line up.
        let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if folded.count == 1, let first = folded.first { return first }
        let lowered = character.lowercased()
        return lowered.count == 1 ? lowered.first ?? character : character
    }

    private static func isAlphanumeric(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    private static func isOtherSymbol(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.generalCategory == .otherSymbol
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }

    /// After a non-letter, at a camelCase or digit boundary, or at any Chinese or Japanese character.
    private static func isWordStart(
        beforePrevious: Character?, previous: Character?, character: Character, next: Character?
    ) -> Bool {
        guard isAlphanumeric(character) || isOtherSymbol(character) else { return false }
        // "Julius’s": a possessive does not start a word.
        if let previous, previous == "'" || previous == "’", isAlphanumeric(beforePrevious) { return false }
        guard let previous, isAlphanumeric(previous) else { return true }
        if previous.isLowercase && character.isUppercase { return true }
        if previous.isUppercase && character.isUppercase && next?.isLowercase == true { return true }
        if previous.isNumber != character.isNumber { return true }
        return isCJK(character)
    }

    // MARK: Token matching

    private struct TokenMatch {
        var score: Double
        var start: Int
        var end: Int
        /// Separate ranges, for words typed together.
        var letters: [Range<Int>]?
    }

    /// Where `token` next occurs in `text` at or after `start`.
    private static func occurrence(of token: [Character], in text: [Character], from start: Int = 0) -> Int? {
        guard !token.isEmpty, token.count <= text.count, start <= text.count - token.count else { return nil }
        let first = token[0]
        search: for index in start...(text.count - token.count) where text[index] == first {
            for offset in 1..<token.count where text[index + offset] != token[offset] { continue search }
            return index
        }
        return nil
    }

    private static func matchToken(
        _ field: Field, _ token: [Character], typos: Bool, isPrimary: Bool, midWord: Bool
    ) -> TokenMatch? {
        guard let first = token.first else { return nil }
        let text = field.text
        var best: TokenMatch?
        // A token that opens with punctuation (".ts") brings its own boundary.
        let ownBoundary = !isAlphanumeric(first) && !isOtherSymbol(first)
        var next = occurrence(of: token, in: text)
        while let index = next {
            next = occurrence(of: token, in: text, from: index + 1)
            let end = index + token.count
            if field.wordStarts[index] || ownBoundary {
                let whole = end >= text.count || field.wordStarts[end] || !isAlphanumeric(text[end])
                var runEnd = end
                while runEnd < text.count && isAlphanumeric(text[runEnd]) { runEnd += 1 }
                let score = whole ? wholeWord : 0.7 + 0.2 * Double(token.count) / Double(runEnd - index)
                if best == nil || score > best!.score { best = TokenMatch(score: score, start: index, end: end) }
                if score == wholeWord { return best }
            } else if midWord && token.count >= 4 && best == nil {
                best = TokenMatch(score: midWordScore, start: index, end: end)
            }
        }
        if (best == nil || best!.score <= midWordScore) && isPrimary, let joined = matchJoinedWords(field, token) {
            return joined
        }
        if let best, best.score > midWordScore { return best }
        guard typos, token.count >= 3, token.contains(where: \.isLetter) else { return best }
        // A typo keeps the first letter, unless it swaps the first two of a longer word.
        for index in text.indices where field.wordStarts[index] {
            let firstKept =
                text[index] == token[0]
                || (token.count > 3 && text[index] == token[1] && index + 1 < text.count && text[index + 1] == token[0])
            guard firstKept else { continue }
            var runEnd = index + 1
            while runEnd < text.count && isAlphanumeric(text[runEnd]) { runEnd += 1 }
            let short = token.count <= 4
            let lengths = short ? [token.count, token.count + 1] : [token.count, token.count - 1, token.count + 1]
            for length in lengths where length <= runEnd - index {
                if withinOneEdit(token[...], text[index..<(index + length)], swapOnly: short && length == token.count) {
                    return TokenMatch(score: typoScore, start: index, end: index + length)
                }
            }
        }
        return best
    }

    /// One substitution, insertion, deletion or swap of neighbours; with `swapOnly`, only a swap.
    private static func withinOneEdit(_ left: ArraySlice<Character>, _ right: ArraySlice<Character>, swapOnly: Bool) -> Bool {
        if abs(left.count - right.count) > (swapOnly ? 0 : 1) { return false }
        let common = zip(left, right).prefix { $0 == $1 }.count
        let restLeft = left.dropFirst(common)
        let restRight = right.dropFirst(common)
        let swapped =
            restLeft.count > 1 && restRight.count > 1
            && restLeft[restLeft.startIndex] == restRight[restRight.startIndex + 1]
            && restLeft[restLeft.startIndex + 1] == restRight[restRight.startIndex]
            && restLeft.dropFirst(2).elementsEqual(restRight.dropFirst(2))
        if swapOnly { return swapped }
        return swapped || restLeft.elementsEqual(restRight) || restLeft.dropFirst().elementsEqual(restRight.dropFirst())
            || restLeft.dropFirst().elementsEqual(restRight) || restLeft.elementsEqual(restRight.dropFirst())
    }

    private static func wordEnd(_ field: Field, _ index: Int) -> Int {
        var end = index + 1
        while end < field.text.count && !field.wordStarts[end] && isAlphanumeric(field.text[end]) { end += 1 }
        return end
    }

    /// Words typed together: "vscode" for "VS Code". Short fragments only count at the start of the
    /// name, before three letters, or as a whole word, so "inth" does not find "in thread".
    private static func matchJoinedWords(_ field: Field, _ token: [Character]) -> TokenMatch? {
        let text = field.text
        let firstWord = field.wordStarts.firstIndex(of: true)
        for start in text.indices where field.wordStarts[start] && text[start] == token[0] {
            var runs: [Range<Int>] = []
            var at = start
            var rest = token[...]
            while !rest.isEmpty && at < text.count {
                let end = wordEnd(field, at)
                if rest.count <= end - at && text[at..<(at + rest.count)].elementsEqual(rest) {
                    runs.append(at..<(at + rest.count))
                    rest = []
                } else if rest.starts(with: text[at..<end]) {
                    runs.append(at..<end)
                    rest = rest.dropFirst(end - at)
                    at = end
                    while at < text.count && !field.wordStarts[at] { at += 1 }
                } else {
                    break
                }
            }
            guard rest.isEmpty, let last = runs.last, runs.count >= 2 else { continue }
            if last.upperBound == wordEnd(field, last.lowerBound) || last.count >= 3 || start == firstWord
                || runs.dropLast().allSatisfy({ $0.count >= 3 })
            {
                return TokenMatch(score: joinedWordsScore, start: start, end: last.upperBound, letters: runs)
            }
        }
        return nil
    }

    // MARK: Fields

    /// Every query word must match some field. Quality is the mean of each word's best weighted
    /// match, plus a bonus when the first field equals or contains the whole query.
    static func match(_ query: Query, fields: [WeightedField], typos: Bool) -> Match? {
        let tokens = query.tokens
        guard !tokens.isEmpty else { return nil }
        let prepared = fields.filter { !$0.value.isEmpty }.map { (field: field($0.value), spec: $0) }
        let hasPrimary = !(fields.first?.value.isEmpty ?? true)
        let fillerOptional = tokens.contains { !fillerWords.contains(String($0)) }
        var ranges: [Range<Int>] = []
        var total = 0.0
        var counted = 0
        var strong = true
        for token in tokens {
            var best = 0.0
            var bestPrimary: TokenMatch?
            var atWordStart = false
            for (index, entry) in prepared.enumerated() {
                let isPrimary = hasPrimary && index == 0
                if best >= entry.spec.weight && !isPrimary && atWordStart { continue }
                guard
                    let match = matchToken(
                        entry.field, token, typos: typos && !entry.spec.keyword, isPrimary: isPrimary,
                        midWord: entry.spec.midWord)
                else { continue }
                let minimum = entry.spec.wholeWords ? wholeWord : entry.spec.keyword ? 0.7 : 0
                if match.score < minimum { continue }
                if isPrimary { bestPrimary = match }
                if match.score >= 0.7 && !entry.spec.context { atWordStart = true }
                best = max(best, match.score * entry.spec.weight)
            }
            if best == 0 {
                if fillerOptional && fillerWords.contains(String(token)) { continue }
                return nil
            }
            strong = strong && atWordStart
            if let bestPrimary { ranges += bestPrimary.letters ?? [bestPrimary.start..<bestPrimary.end] }
            total += best
            counted += 1
        }
        guard counted > 0 else { return nil }
        var quality = total / Double(counted)
        if hasPrimary, let primary = prepared.first?.field {
            if primary.text == query.characters {
                quality += wholeName - wholeWord
            } else if tokens.count > 1 && occurrence(of: query.characters, in: primary.text) != nil {
                quality += 0.25
            }
        }
        let primaryField = hasPrimary ? prepared.first?.field : nil
        return Match(
            quality: quality, score: quality, groupQuality: nil, strong: strong,
            ranges: primaryField.map { nsRanges(merge(ranges), in: $0) } ?? [])
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func nsRanges(_ ranges: [Range<Int>], in field: Field) -> [NSRange] {
        ranges.map { range in
            let start = field.utf16Offsets[range.lowerBound]
            return NSRange(location: start, length: field.utf16Offsets[range.upperBound] - start)
        }
    }

    // MARK: Scoring

    /// A thread: its title counts fully, its branch less, its project least.
    /// Recently active threads rank higher among matches of the same quality.
    static func scoreThread(
        _ query: Query, title: String, branch: String?, project: String?, updatedAt: Date, typos: Bool,
        branchPrefix: String = "", now: Date = Date()
    ) -> Match? {
        var fields = [WeightedField(value: title, weight: 1, midWord: true)]
        if var branch, !branch.isEmpty {
            if !branchPrefix.isEmpty, branch.hasPrefix(branchPrefix), branch.count > branchPrefix.count {
                branch.removeFirst(branchPrefix.count)
            }
            fields.append(WeightedField(value: branch, weight: 0.6))
        }
        if let project, !project.isEmpty { fields.append(WeightedField(value: project, weight: 0.25, context: true)) }
        guard var match = match(query, fields: fields, typos: typos) else { return nil }
        let recency = pow(2, -max(0, now.timeIntervalSince(updatedAt)) / recencyHalfLife)
        match.score = match.quality * min(3, 1 + recency)
        // A thread titled like a command never lifts its group above that command.
        match.groupQuality = min(match.quality, wholeName - 0.01)
        return match
    }

    /// A command or project: its name, plus keywords that count less.
    static func scoreTerms(_ query: Query, name: String, keywords: [String], typos: Bool) -> Match? {
        // Short queries need whole keywords, or "co" would list most commands.
        let short = query.isShort
        let fields =
            [WeightedField(value: name, weight: 1)]
            + keywords.map { WeightedField(value: $0, weight: short ? 0.8 : 0.6, wholeWords: short, keyword: true) }
        guard var match = match(query, fields: fields, typos: typos) else { return nil }
        if match.ranges.isEmpty { match.groupQuality = min(match.quality, 0.65) }
        return match
    }

    /// Whole names, word starts, typos and inside-word hits.
    static func matchClass(_ quality: Double) -> Int {
        quality >= wholeName ? 3 : quality >= 0.7 ? 2 : quality >= 0.4 ? 1 : 0
    }

    /// Ranks every group's items and orders the groups by their best match class, keeping their
    /// given order on ties. Typos are only tried when nothing matches at a word start.
    static func rank<Group, Item>(
        _ groups: [(group: Group, items: [Item])], score: (Item, _ typos: Bool) -> Match?
    ) -> [(group: Group, items: [(item: Item, match: Match)])] {
        func run(typos: Bool) -> [(group: Group, items: [(item: Item, match: Match)])] {
            groups.map { entry in
                (entry.group, entry.items.compactMap { item in score(item, typos).map { (item, $0) } })
            }
        }
        var ranked = run(typos: false)
        if !ranked.contains(where: { $0.items.contains { $0.match.strong } }) { ranked = run(typos: true) }
        let ordered = ranked.enumerated().compactMap { order, entry -> (Int, Int, Group, [(item: Item, match: Match)])? in
            guard !entry.items.isEmpty else { return nil }
            let sorted = entry.items.sorted { left, right in
                let leftClass = matchClass(left.match.quality)
                let rightClass = matchClass(right.match.quality)
                if min(leftClass, 2) != min(rightClass, 2) { return min(leftClass, 2) > min(rightClass, 2) }
                if leftClass != rightClass { return leftClass > rightClass }
                return left.match.score > right.match.score
            }
            let best = entry.items.map { matchClass($0.match.groupQuality ?? $0.match.quality) }.max() ?? 0
            return (best, order, entry.group, sorted)
        }
        return ordered.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map { ($0.2, $0.3) }
    }
}
