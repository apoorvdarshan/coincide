import Testing
@testable import CoincideKit

struct SplitDiffTests {
    @Test func replacementBlocksAlignWithoutInventingLines() {
        let kinds: [DiffLine.Kind] = [.context, .deletion, .deletion, .addition, .context, .addition, .addition, .context]
        let rows = SplitDiffLine.align(kinds.map { DiffLine(kind: $0, text: "") })
        #expect(rows == [
            .init(before: 0, after: 0), .init(before: 1, after: 3), .init(before: 2, after: nil),
            .init(before: 4, after: 4), .init(before: nil, after: 5), .init(before: nil, after: 6),
            .init(before: 7, after: 7),
        ])
    }

    @Test func emptyAddedAndDeletedFilesKeepTheirOwnSides() {
        #expect(SplitDiffLine.align([]).isEmpty)
        let added = [DiffLine(kind: .addition, text: "", newLine: 1)]
        #expect(SplitDiffLine.align(added) == [.init(before: nil, after: 0)])
        let deleted = [DiffLine(kind: .deletion, text: "", oldLine: 1)]
        #expect(SplitDiffLine.align(deleted) == [.init(before: 0, after: nil)])
    }

    @Test func endOfFileMarkersRemainOnTheCorrectSideOfTheirLine() {
        let kinds: [DiffLine.Kind] = [.deletion, .noNewline, .addition, .addition, .noNewline]
        #expect(SplitDiffLine.align(kinds.map { DiffLine(kind: $0, text: "") }) == [
            .init(before: 0, after: 2), .init(before: 1, after: nil),
            .init(before: nil, after: 3), .init(before: nil, after: 4),
        ])
        let context: [DiffLine.Kind] = [.context, .noNewline]
        #expect(SplitDiffLine.align(context.map { DiffLine(kind: $0, text: "") }) == [
            .init(before: 0, after: 0), .init(before: 1, after: 1),
        ])
    }

    @Test func arbitraryLineSequencesKeepAllIndexesAndNeverCrossContext() {
        // Exhaust every short sequence, including malformed repeated newline markers and interleaved edits.
        let kinds: [DiffLine.Kind] = [.context, .addition, .deletion, .noNewline]
        for code in 0..<4096 {
            var number = code
            let lines = (0..<6).map { _ -> DiffLine in
                defer { number /= 4 }
                return DiffLine(kind: kinds[number % 4], text: "")
            }
            let rows = SplitDiffLine.align(lines)
            #expect(Set(rows.flatMap { [$0.before, $0.after].compactMap { $0 } }) == Set(lines.indices))
            for row in rows {
                if let before = row.before { #expect(lines[before].kind != .addition) }
                if let after = row.after { #expect(lines[after].kind != .deletion) }
                if let before = row.before, let after = row.after, before != after {
                    #expect(!lines[min(before, after)...max(before, after)].contains { $0.kind == .context })
                }
            }
        }
    }
}
