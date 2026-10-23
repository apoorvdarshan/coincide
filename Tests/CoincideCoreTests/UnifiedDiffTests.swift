import Foundation
import Testing
@testable import CoincideCore

@Test func unifiedDiffParsesModifiedAddedDeletedRenamedModeAndBinaryFiles() {
    let patch = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1,3 +1,4 @@ struct App {
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
     let d = 5
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +first
    +second
    diff --git a/old.txt b/old.txt
    deleted file mode 100644
    index 4444444..0000000
    --- a/old.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    diff --git a/before.md b/after.md
    similarity index 90%
    rename from before.md
    rename to after.md
    index 5555555..6666666 100644
    --- a/before.md
    +++ b/after.md
    @@ -2 +2 @@
    -old line
    +new line
    diff --git a/script.sh b/script.sh
    old mode 100644
    new mode 100755
    diff --git a/image.png b/image.png
    index 7777777..8888888 100644
    Binary files a/image.png and b/image.png differ

    """
    let diff = UnifiedDiff.parse(patch)
    #expect(diff.files.map(\.path) == ["Sources/App.swift", "new.txt", "old.txt", "after.md", "script.sh", "image.png"])
    #expect(diff.files.map(\.status) == [.modified, .added, .deleted, .renamed, .modeChanged, .modified])
    let swift = diff.files[0]
    #expect(swift.additions == 2 && swift.deletions == 1 && swift.hunks.count == 1 && !swift.isTruncated)
    #expect(swift.hunks[0].section == "struct App {" && swift.hunks[0].oldStart == 1 && swift.hunks[0].newCount == 4)
    #expect(swift.hunks[0].lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context])
    #expect(swift.hunks[0].lines.last?.oldLine == 3 && swift.hunks[0].lines.last?.newLine == 4)
    #expect(swift.firstChangedLine == 2 && swift.fileExtension == "swift")
    #expect(diff.files[1].oldPath == nil && diff.files[1].newPath == "new.txt" && diff.files[1].additions == 2)
    #expect(diff.files[2].newPath == nil && diff.files[2].oldPath == "old.txt" && diff.files[2].deletions == 1)
    #expect(diff.files[3].oldPath == "before.md" && diff.files[3].similarity == 90 && diff.files[3].firstChangedLine == 2)
    #expect(diff.files[4].oldMode == "100644" && diff.files[4].newMode == "100755" && diff.files[4].hunks.isEmpty)
    #expect(diff.files[5].isBinary && diff.files[5].hunks.isEmpty)
    #expect(diff.additions == 5 && diff.deletions == 3 && !diff.truncated)
}

@Test func unifiedDiffUsesHunkCountsSoHeaderLikeLinesStayContent() {
    // A deleted line "-- note" is printed as "--- note" and an added "++ x" as "+++ x".
    let patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n--- note\n+++ x\n context\n\\ No newline at end of file\n"
    let diff = UnifiedDiff.parse(patch)
    #expect(diff.files.count == 1)
    let lines = diff.files[0].hunks[0].lines
    #expect(lines.map(\.kind) == [.deletion, .addition, .context, .noNewline])
    #expect(lines[0].text == "-- note" && lines[1].text == "++ x" && lines[3].text == "No newline at end of file")
    #expect(!diff.files[0].isTruncated)
}

@Test func unifiedDiffDecodesQuotedAndSpacedPathsAndMarksTruncatedTails() {
    let quoted = "diff --git \"a/sp ace/\\303\\251t\\303\\251.txt\" \"b/sp ace/\\303\\251t\\303\\251.txt\"\nnew file mode 100644\n--- /dev/null\n+++ \"b/sp ace/\\303\\251t\\303\\251.txt\"\n@@ -0,0 +1 @@\n+été\n"
    #expect(UnifiedDiff.parse(quoted).files.first?.path == "sp ace/été.txt")
    let spaced = "diff --git a/with space.txt b/with space.txt\nold mode 100644\nnew mode 100755\n"
    #expect(UnifiedDiff.parse(spaced).files.first?.path == "with space.txt")
    let cut = "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -1,5 +1,5 @@\n one\n-two\n+TWO\n"
    let truncated = UnifiedDiff.parse(cut)
    #expect(truncated.truncated && truncated.files[0].isTruncated && truncated.files[0].hunks[0].isComplete == false)
    #expect(UnifiedDiff.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", truncated: true).files[0].isTruncated)
}

@Test func unifiedDiffReadsCoincideUntrackedPreviewFormats() {
    let readable = UnifiedDiff.parse("+++ notes/todo.md (untracked)\n+first\n+\n+third\n+")
    #expect(readable.files.count == 1 && readable.files[0].status == .untracked && readable.files[0].path == "notes/todo.md")
    #expect(readable.files[0].hunks[0].lines.map(\.text) == ["first", "", "third"] && readable.files[0].additions == 3)
    let binary = UnifiedDiff.parse("Binary or large untracked file: data.bin")
    #expect(binary.files.first?.isBinary == true && binary.files.first?.status == .untracked && binary.files.first?.note != nil)
    #expect(UnifiedDiff.parse("").files.isEmpty && UnifiedDiff.parse("No changes").files.isEmpty)
}

@Test func unifiedDiffSplitRowsPairUnevenRunsAndKeepContextOnBothSides() {
    let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,5 +1,4 @@\n keep\n-one\n-two\n-three\n+uno\n+dos\n same\n"
    let hunk = UnifiedDiff.parse(patch).files[0].hunks[0]
    let rows = hunk.splitRows
    #expect(rows.count == 5)
    #expect(rows[0].left?.text == "keep" && rows[0].right?.text == "keep")
    #expect(rows[1].left?.text == "one" && rows[1].right?.text == "uno")
    #expect(rows[2].left?.text == "two" && rows[2].right?.text == "dos")
    #expect(rows[3].left?.text == "three" && rows[3].right == nil)
    #expect(rows[4].left?.kind == .context && rows[4].right?.newLine == 4)
    let additionOnly = UnifiedDiff.parse("diff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -1 +1,2 @@\n x\n+y\n\\ No newline at end of file\n").files[0].hunks[0].splitRows
    #expect(additionOnly.count == 3 && additionOnly[1].left == nil && additionOnly[2].right?.kind == .noNewline && additionOnly[2].left == nil)
}
