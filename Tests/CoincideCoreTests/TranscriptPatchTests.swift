import Foundation
import Testing
@testable import CoincideCore

@Test func transcriptPatchParsesMultiFileGitDiffsWithRenamesAdditionsDeletionsBinaryAndNoNewlineMarkers() throws {
    let patch = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1,3 +1,4 @@
     import SwiftUI
    -let value = 1
    +let value = 2
    +let other = 3
     print(value)
    \\ No newline at end of file
    diff --git a/old name.txt b/new name.txt
    similarity index 90%
    rename from old name.txt
    rename to new name.txt
    --- a/old name.txt
    +++ b/new name.txt
    @@ -2 +2 @@
    -before
    +after
    diff --git a/added.md b/added.md
    new file mode 100644
    --- /dev/null
    +++ b/added.md
    @@ -0,0 +1,2 @@
    +# Title
    +
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/image.png b/image.png
    Binary files a/image.png and b/image.png differ
    """
    let files = try #require(TranscriptPatch.parse(patch))
    #expect(files.map(\.path) == ["Sources/App.swift", "new name.txt", "added.md", "gone.txt", "image.png"])
    let app = files[0]
    #expect(app.kind == .modified && app.additions == 2 && app.deletions == 1)
    #expect(app.hunks.count == 1 && app.hunks[0].lines.last?.kind == .note)
    #expect(app.hunks[0].lines.first == TranscriptDiffLine(.context, "import SwiftUI", old: 1, new: 1))
    #expect(app.hunks[0].lines.first(where: { $0.kind == .addition })?.newLine == 2)
    #expect(files[1].kind == .renamed && files[1].previousPath == "old name.txt" && files[1].additions == 1 && files[1].deletions == 1)
    #expect(files[2].kind == .added && files[2].additions == 2 && files[2].hunks[0].lines.last?.text == "")
    #expect(files[3].kind == .deleted && files[3].path == "gone.txt" && files[3].deletions == 1)
    #expect(files[4].isBinary && files[4].hunks.isEmpty)
    #expect(TranscriptDiffStat(files) == .init(files: 5, additions: 5, deletions: 3))
}

@Test func transcriptPatchHandlesCRLFPlainHunksAndRejectsMalformedText() throws {
    let crlf = "--- a/a.txt\r\n+++ b/a.txt\r\n@@ -1,2 +1,2 @@\r\n one\r\n-two\r\n+zwei\r\n"
    let file = try #require(TranscriptPatch.parse(crlf)?.first)
    #expect(file.path == "a.txt" && file.previousPath == nil && file.kind == .modified)
    #expect(file.hunks[0].lines.map(\.text) == ["one", "two", "zwei"])
    let bare = try #require(TranscriptPatch.parse("@@ -3,1 +3,2 @@\n-a\n+b\n+c", fallbackPath: "x.swift")?.first)
    #expect(bare.path == "x.swift" && bare.additions == 2 && bare.deletions == 1 && bare.hunks[0].lines[0].oldLine == 3)
    #expect(TranscriptPatch.parse("Just some command output\n+ not a diff") == nil)
    #expect(TranscriptPatch.parse("@@ broken header @@\n+x") == nil)
    #expect(TranscriptPatch.parse("") == nil)
    #expect(TranscriptPatch.hunkHeader("@@ -10 +12,3 @@ func") == .init(oldStart: 10, oldCount: 1, newStart: 12, newCount: 3))
}

@Test func transcriptLineDiffBuildsContextHunksForInsertDeleteReplaceIdenticalAndUnicode() {
    let replaced = TranscriptLineDiff.change(path: "a.swift", old: "a\nb\nc\nd\ne\nf\ng\nh\ni\nj", new: "a\nb\nc\nd\nE\nf\ng\nh\ni\nj")
    #expect(replaced.additions == 1 && replaced.deletions == 1 && replaced.hunks.count == 1)
    #expect(replaced.hunks[0].header == "@@ -2,7 +2,7 @@")
    #expect(replaced.hunks[0].lines.filter { $0.kind == .context }.count == 6)
    let inserted = TranscriptLineDiff.change(path: "a", old: "one\ntwo", new: "one\nnew\ntwo")
    #expect(inserted.additions == 1 && inserted.deletions == 0 && inserted.hunks[0].lines.map(\.kind) == [.context, .addition, .context, .note])
    let deleted = TranscriptLineDiff.change(path: "a", old: "one\ntwo\nthree", new: "one\nthree")
    #expect(deleted.deletions == 1 && deleted.hunks[0].lines.first(where: { $0.kind == .deletion })?.text == "two")
    let identical = TranscriptLineDiff.change(path: "a", old: "same\n", new: "same\n")
    #expect(identical.hunks.isEmpty && identical.additions == 0 && identical.deletions == 0)
    let unicode = TranscriptLineDiff.change(path: "ü.txt", old: "café 👋🏽", new: "café 👋🏾\nñ")
    #expect(unicode.additions == 2 && unicode.deletions == 1)
    let created = TranscriptLineDiff.change(path: "new", old: nil, new: "x\ny\n", numbered: true)
    #expect(created.kind == .added && created.additions == 2 && created.hunks[0].header == "@@ -0,0 +1,2 @@" && created.hunks[0].lines[1].newLine == 2)
    let originalLines: [String] = (1...40).map { String($0) }
    let changedLines: [String] = (1...40).map { number in
        if number == 2 || number == 39 { return "x" }
        return String(number)
    }
    let far = TranscriptLineDiff.change(path: "a", old: originalLines.joined(separator: "\n"),
                                       new: changedLines.joined(separator: "\n"))
    #expect(far.hunks.count == 2)
}

@Test func codexFileChangeItemsProduceStatsForAddDeleteUpdateAndMoves() throws {
    let json = """
    [{"path":"/w/new.txt","kind":{"type":"add"},"diff":"hello\\nworld\\n"},
     {"path":"/w/old.txt","kind":{"type":"delete"},"diff":"bye\\n"},
     {"path":"/w/a.swift","kind":{"type":"update","move_path":null},"diff":"@@ -1,2 +1,2 @@\\n-let a = 1\\n+let a = 2\\n context\\n"},
     {"path":"/w/b.swift","kind":{"type":"update","move_path":"/w/c.swift"},"diff":"@@ -1 +1 @@\\n-x\\n+y\\n"}]
    """
    let changes = TranscriptPatch.codexChanges(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    #expect(changes.map(\.path) == ["/w/new.txt", "/w/old.txt", "/w/a.swift", "/w/c.swift"])
    #expect(changes.map(\.kind) == [.added, .deleted, .modified, .renamed])
    #expect(changes.map(\.additions) == [2, 0, 1, 1] && changes.map(\.deletions) == [0, 1, 1, 1])
    #expect(changes[3].previousPath == "/w/b.swift")
}

@Test func transcriptOutputWindowsBoundMultiMegabyteOutputWithoutSplittingCharacters() {
    let big = String(repeating: "line é\n", count: 800_000) // ~6 MB
    let tail = TranscriptOutputTail.tail(big, maxLines: 200, maxBytes: 65_536)
    #expect(tail.truncated && tail.text.utf8.count <= 65_536)
    #expect(tail.text.split(separator: "\n").count == 200 && tail.text.hasPrefix("line é"))
    let head = TranscriptOutputTail.head(big, maxLines: 10)
    #expect(head.truncated && head.text.split(separator: "\n").count == 10)
    let short = TranscriptOutputTail.tail("a\nb\n")
    #expect(!short.truncated && short.text == "a\nb\n")
    let bytes = TranscriptOutputTail.head(String(repeating: "é", count: 100), maxBytes: 51)
    #expect(bytes.truncated && bytes.text == String(repeating: "é", count: 25))
}

@Test func transcriptPatchRejectsOverflowIncompleteAndOversizedSourceBeforeManufacturingChanges() {
    for patch in ["@@ -\(Int.max),1 +1,1 @@\n-a\n+b", "@@ -1,1 +\(Int.max),1 @@\n-a\n+b",
                  "@@ -1,2 +1,2 @@\n-a\n+b", "@@ -1,1 +1,1 @@\n\n-a\n+b"] {
        #expect(TranscriptPatch.parse(patch, fallbackPath: "file") == nil)
    }
    let many = "@@ -0,0 +1,\(TranscriptPatch.maximumLines) @@\n" + String(repeating: "+x\n", count: TranscriptPatch.maximumLines)
    #expect(TranscriptPatch.parse(many, fallbackPath: "file") == nil)
    let huge = TranscriptLineDiff.change(path: "file", old: "old", new: String(repeating: "x", count: TranscriptLineDiff.maximumBytes + 1))
    #expect(huge.isTruncated && !huge.countsComplete && huge.hunks.isEmpty)
    let lines = TranscriptLineDiff.change(path: "file", old: nil, new: String(repeating: "x\n", count: TranscriptLineDiff.maximumLines + 1))
    #expect(lines.isTruncated && !lines.countsComplete)
}

@Test func transcriptLineDiffRetainsCanonicalUnicodeEditsAndBoundsWorstCaseReplacementWork() {
    let original = "café", revised = "cafe\u{301}"
    #expect(original == revised && !original.utf8.elementsEqual(revised.utf8))
    let exact = TranscriptLineDiff.change(path: "file", old: original, new: revised)
    #expect(exact.additions == 1 && exact.deletions == 1)
    let changed = exact.hunks.flatMap(\.lines).filter { $0.kind == .addition || $0.kind == .deletion }
    #expect(changed.first?.text.utf8.elementsEqual(original.utf8) == true && changed.last?.text.utf8.elementsEqual(revised.utf8) == true)
    let old = (0..<1_100).map { "old-\($0)" }.joined(separator: "\n")
    let new = (0..<1_100).map { "new-\($0)" }.joined(separator: "\n")
    let bounded = TranscriptLineDiff.change(path: "file", old: old, new: new)
    #expect(bounded.additions == 1_100 && bounded.deletions == 1_100 && bounded.countsComplete && !bounded.isTruncated)
    #expect(bounded.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text).joined(separator: "\n").utf8.elementsEqual(new.utf8))
}

@Test func transcriptLineDiffPreservesFinalNewlineAndCRLFBytesWithUnnumberedNotes() throws {
    let cases = [("a\n", "a"), ("a", "a\n"), ("a\r\n", "a\n"), ("a\n", "a\r\n"), ("café\r\n", "cafe\u{301}")]
    for (old, new) in cases {
        let change = TranscriptLineDiff.change(path: "file", old: old, new: new, numbered: true)
        #expect(change.countsComplete && !change.isTruncated && change.additions == 1 && change.deletions == 1)
        let hunk = try #require(change.hunks.first)
        #expect(hunk.header == "@@ -1,1 +1,1 @@")
        var oldBytes = Data(), newBytes = Data()
        var previous: TranscriptDiffLine.Kind?
        for line in hunk.lines {
            switch line.kind {
            case .deletion: oldBytes.append(contentsOf: line.text.utf8); oldBytes.append(10)
            case .addition: newBytes.append(contentsOf: line.text.utf8); newBytes.append(10)
            case .context:
                oldBytes.append(contentsOf: line.text.utf8); oldBytes.append(10)
                newBytes.append(contentsOf: line.text.utf8); newBytes.append(10)
            case .note:
                #expect(line.oldLine == nil && line.newLine == nil && line.text == "No newline at end of file")
                if previous == .deletion || previous == .context { oldBytes.removeLast() }
                if previous == .addition || previous == .context { newBytes.removeLast() }
            }
            if line.kind != .note { previous = line.kind }
        }
        #expect(oldBytes == Data(old.utf8) && newBytes == Data(new.utf8), "The displayed hunk reconstructs both original byte sequences, including EOL.")
        let identical = TranscriptLineDiff.change(path: "file", old: old, new: old)
        #expect(identical.hunks.isEmpty && identical.additions == 0 && identical.deletions == 0)
    }
}

@Test func transcriptLFFramedPatchKeepsLiteralCarriageReturnFileBytes() throws {
    let patch = "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\r\n+new\r\n"
    let change = try #require(TranscriptPatch.parse(patch)?.first)
    let lines = try #require(change.hunks.first).lines
    let old = lines.filter { $0.kind == .deletion }.map { $0.text + "\n" }.joined()
    let new = lines.filter { $0.kind == .addition }.map { $0.text + "\n" }.joined()
    #expect(Data(old.utf8) == Data("old\r\n".utf8))
    #expect(Data(new.utf8) == Data("new\r\n".utf8))
}
