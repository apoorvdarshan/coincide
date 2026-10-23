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
    #expect(inserted.additions == 1 && inserted.deletions == 0 && inserted.hunks[0].lines.map(\.kind) == [.context, .addition, .context])
    let deleted = TranscriptLineDiff.change(path: "a", old: "one\ntwo\nthree", new: "one\nthree")
    #expect(deleted.deletions == 1 && deleted.hunks[0].lines.first(where: { $0.kind == .deletion })?.text == "two")
    let identical = TranscriptLineDiff.change(path: "a", old: "same\n", new: "same")
    #expect(identical.hunks.isEmpty && identical.additions == 0 && identical.deletions == 0)
    let unicode = TranscriptLineDiff.change(path: "ü.txt", old: "café 👋🏽", new: "café 👋🏾\nñ")
    #expect(unicode.additions == 2 && unicode.deletions == 1)
    let created = TranscriptLineDiff.change(path: "new", old: nil, new: "x\ny\n", numbered: true)
    #expect(created.kind == .added && created.additions == 2 && created.hunks[0].header == "@@ -0,0 +1,2 @@" && created.hunks[0].lines[1].newLine == 2)
    let far = TranscriptLineDiff.change(path: "a", old: (1...40).map(String.init).joined(separator: "\n"),
                                       new: (1...40).map { $0 == 2 || $0 == 39 ? "x" : String($0) }.joined(separator: "\n"))
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
