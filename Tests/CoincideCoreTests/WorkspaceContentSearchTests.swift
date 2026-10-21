import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct ContentSearchFixture: Sendable {
    let scratch: URL
    let root: URL
    let environment: [String: String]

    static func make(git: Bool) async throws -> Self {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-content-search-" + UUID().uuidString).resolvingSymlinksInPath()
        let root = scratch.appendingPathComponent("workspace"), home = scratch.appendingPathComponent("home")
        for directory in [root, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var environment = ProcessChannel.environment()
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["HOME"] = home.path; environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["GIT_CONFIG_GLOBAL"] = home.appendingPathComponent(".gitconfig").path; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"
        let fixture = Self(scratch: scratch, root: root, environment: environment)
        do { if git { try await fixture.git(["init", "--initial-branch=main"]) }; return fixture }
        catch { try? FileManager.default.removeItem(at: scratch); throw error }
    }
    @discardableResult func put(_ relative: String, _ text: String) throws -> URL { try put(relative, Data(text.utf8)) }
    @discardableResult func put(_ relative: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url); return url
    }
    func git(_ arguments: [String]) async throws {
        let result = try await CommandRunner.run("git", ["-C", root.path] + arguments, cwd: root, environment: environment)
        guard result.status == 0 else { throw CoincideError("The isolated content-search Git fixture failed.") }
    }
}

private func withContentSearch(git: Bool = false, limits: WorkspaceContentSearchLimits = .init(),
                               _ body: (ContentSearchFixture, WorkspaceFileService) async throws -> Void) async throws {
    let fixture = try await ContentSearchFixture.make(git: git)
    defer { try? FileManager.default.removeItem(at: fixture.scratch) }
    let service = WorkspaceFileService(root: fixture.root, environment: fixture.environment, contentSearchLimits: limits)
    do { try await body(fixture, service); await service.close() }
    catch { await service.close(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchReportsOriginalUTF16RangesAndOneBasedCRLFLines() async throws {
    try await withContentSearch { fixture, service in
        let line = "😀 café cafe\u{301} NEEDLE needle"
        try fixture.put("unicode.txt", "\n" + line + "\r\nβ NEEDLE\n")
        let result = try await service.searchContents(query: "needle")
        #expect(result == .init(matches: [
            .init(path: "unicode.txt", lineNumber: 2, lineContent: line, matchRanges: [.init(start: 14, end: 20), .init(start: 21, end: 27)]),
            .init(path: "unicode.txt", lineNumber: 3, lineContent: "β NEEDLE", matchRanges: [.init(start: 2, end: 8)])
        ], truncated: false))
        let sensitive = try await service.searchContents(query: "NEEDLE", caseSensitive: true)
        #expect(sensitive.matches.map(\.lineNumber) == [2, 3])
        #expect(sensitive.matches.first?.matchRanges == [.init(start: 14, end: 20)])
        try fixture.put("case-fold.txt", "İx x\n")
        let folded = try await service.searchContents(query: "x")
        let match = try #require(folded.matches.first { $0.path == "case-fold.txt" })
        #expect(match.matchRanges == [.init(start: 1, end: 2), .init(start: 3, end: 4)], "Case folding must not move offsets into the transformed string.")
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchPreservesLiteralQueryWhitespaceAndDoesNotTreatItAsAPathQuery() async throws {
    try await withContentSearch { fixture, service in
        try fixture.put("spaces.txt", "foo\n foo \n  foo  \n\t\n  \n@./needle\n")
        let padded = try await service.searchContents(query: " foo ", caseSensitive: true)
        #expect(padded.matches.map(\.lineNumber) == [2, 3])
        #expect(padded.matches.map(\.matchRanges) == [[.init(start: 0, end: 5)], [.init(start: 1, end: 6)]])
        let spaces = try await service.searchContents(query: "  ")
        #expect(spaces.matches.map(\.lineNumber) == [3, 5])
        let pathCharacters = try await service.searchContents(query: "@./needle")
        #expect(pathCharacters.matches.count == 1 && pathCharacters.matches.first?.matchRanges == [.init(start: 0, end: 9)])
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchWholeWordsUseUnicodeScalarsAndContinuePastRejectedRawMatches() async throws {
    try await withContentSearch { fixture, service in
        let rejected = ["needleSuffix", "prefixneedle", "_needle", "needle_", "needle9", "9needle", "needle\u{301}", "\u{301}needle", "𐐀needle", "needle𐐀"]
        try fixture.put("words.txt", (rejected + ["needle needle", "needle😀needle"]).joined(separator: "\n"))
        let result = try await service.searchContents(query: "needle", caseSensitive: true, wholeWord: true)
        #expect(result.matches.map(\.lineNumber) == [11, 12] && !result.truncated)
        #expect(result.matches.map(\.matchRanges) == [[.init(start: 0, end: 6), .init(start: 7, end: 13)], [.init(start: 0, end: 6), .init(start: 8, end: 14)]])
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("words.txt"))
        try fixture.put("late.txt", String(repeating: "prefixneedle\n", count: 110) + "needle\n")
        let late = try await service.searchContents(query: "needle", limit: 1, caseSensitive: true, wholeWord: true)
        #expect(late.matches.first?.path == "late.txt" && late.matches.first?.lineNumber == 111, "Rejected raw matches must not exhaust the per-file matching-line allowance.")
        #expect(late.matches.count == 1 && !late.truncated)
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchPunctuationEdgedWholeWordsRetainAdjacentRanges() async throws {
    try await withContentSearch { fixture, service in
        try fixture.put("punctuation.txt", ".env.env x.env .envX\n")
        let result = try await service.searchContents(query: ".env", caseSensitive: true, wholeWord: true)
        #expect(result == .init(matches: [.init(path: "punctuation.txt", lineNumber: 1, lineContent: ".env.env x.env .envX",
                                             matchRanges: [.init(start: 0, end: 4), .init(start: 4, end: 8), .init(start: 10, end: 14)])], truncated: false))
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchRegexSupportsEscapesFlagsAnchorsAndBoundedZeroWidthMatches() async throws {
    try await withContentSearch { fixture, service in
        try fixture.put("regex.txt", "v1.2 [tag] foo123 foo9\nAA aa\nfoo\n")
        let digits = try await service.searchContents(query: #"foo\d+"#, useRegex: true)
        #expect(digits.matches.count == 1 && digits.matches.first?.matchRanges == [.init(start: 11, end: 17), .init(start: 18, end: 22)])
        let literal = try await service.searchContents(query: #"foo\d+"#)
        #expect(literal.matches.isEmpty && literal.regexFallbackError == nil)
        let escaped = try await service.searchContents(query: #"\[tag\]"#, useRegex: true)
        #expect(escaped.matches.first?.matchRanges == [.init(start: 5, end: 10)])
        let insensitive = try await service.searchContents(query: "a+", useRegex: true)
        #expect(insensitive.matches.first { $0.lineNumber == 2 }?.matchRanges == [.init(start: 0, end: 2), .init(start: 3, end: 5)])
        let sensitive = try await service.searchContents(query: "a+", caseSensitive: true, useRegex: true)
        #expect(sensitive.matches.first { $0.lineNumber == 2 }?.matchRanges == [.init(start: 3, end: 5)])
        let anchored = try await service.searchContents(query: "^foo$", useRegex: true)
        #expect(anchored.matches.map(\.lineNumber) == [3])
        let zeroWidth = try await service.searchContents(query: "(?=foo)", useRegex: true)
        #expect(zeroWidth.matches.map(\.matchRanges) == [[.init(start: 11, end: 11), .init(start: 18, end: 18)], [.init(start: 0, end: 0)]])
        let noEmptyWords = try await service.searchContents(query: "(?=foo)", wholeWord: true, useRegex: true)
        #expect(noEmptyWords.matches.isEmpty && noEmptyWords.regexFallbackError == nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchValidationAndInvalidRegexDoNotExposeThePattern() async throws {
    try await withContentSearch { fixture, service in
        try fixture.put("fixture.txt", "ordinary searchable text\n")
        for query in ["", String(repeating: "x", count: 257), "x\0y", String(repeating: "😀", count: 129)] {
            do { _ = try await service.searchContents(query: query); Issue.record("An invalid content query was accepted.") }
            catch let error as WorkspaceFileError { #expect(error.failure == .invalidQuery) }
        }
        for limit in [0, 501, Int.max] {
            await #expect(throws: WorkspaceFileError.self) { try await service.searchContents(query: "text", limit: limit) }
        }
        let pattern = "synthetic-private-pattern-("
        let invalid = try await service.searchContents(query: pattern, useRegex: true)
        #expect(invalid.matches.isEmpty && !invalid.truncated)
        let message = try #require(invalid.regexFallbackError)
        #expect(!message.isEmpty && !message.contains(pattern) && !message.contains("synthetic-private-pattern"))
        let literal = try await service.searchContents(query: pattern)
        #expect(literal.matches.isEmpty && literal.regexFallbackError == nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchUsesGitIgnoreRulesIncludingTrackedIgnoredFilesAndSkipsLinksMetadataAndPipes() async throws {
    try await withContentSearch(git: true) { fixture, service in
        try fixture.put("tracked.txt", "needle tracked\n"); try await fixture.git(["add", "--", "tracked.txt"])
        try fixture.put(".gitignore", "tracked.txt\nignored/\n*.log\n!keep.log\n")
        try fixture.put("ignored/nested.txt", "needle ignored\n"); try fixture.put("drop.log", "needle ignored\n")
        try fixture.put("keep.log", "needle kept\n"); try fixture.put(".hidden.txt", "needle hidden\n")
        try fixture.put("src/main.swift", "needle source\n")
        try fixture.put(".git/coincide-test-metadata", "needle metadata\n")
        let outside = fixture.scratch.appendingPathComponent("outside.txt")
        try Data("needle outside\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("external.txt").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias.swift").path, withDestinationPath: "src/main.swift")
        #expect(mkfifo(fixture.root.appendingPathComponent("pipe").path, 0o600) == 0)
        let result = try await service.searchContents(query: "needle")
        #expect(Set(result.matches.map(\.path)) == ["keep.log", ".hidden.txt", "src/main.swift"])
        #expect(!result.truncated && result.regexFallbackError == nil)
        let direct = try await service.listEntries()
        #expect(direct.entries.first { $0.path == "tracked.txt" }?.ignored != true, "Direct listing labels retain Git index semantics while search excludes ignored tracked contents.")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "needle outside\n")
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchBoundsMatchingLinesAndRangesWithoutLettingOneFileFillTheResultPage() async throws {
    try await withContentSearch { fixture, service in
        try fixture.put("a-dense.txt", String(repeating: "needle\n", count: 120))
        try fixture.put("b-other.txt", "needle\n")
        let lines = try await service.searchContents(query: "needle")
        #expect(lines.truncated && lines.matches.filter { $0.path == "a-dense.txt" }.count == 100)
        #expect(lines.matches.contains { $0.path == "b-other.txt" })
        try fixture.put("c-ranges.txt", String(repeating: "dot ", count: 101) + "\n")
        let ranges = try await service.searchContents(query: "dot")
        #expect(ranges.truncated && ranges.matches.count == 1 && ranges.matches.first?.matchRanges.count == 100)
        #expect(ranges.matches.first?.matchRanges.last == .init(start: 396, end: 399))
        let limited = try await service.searchContents(query: "needle", limit: 2)
        #expect(limited.matches.count == 2 && limited.truncated)
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchSkipsBinaryMalformedAndOverlongLinesButKeepsCompleteTextMatches() async throws {
    try await withContentSearch { fixture, service in
        try fixture.put("binary.txt", Data("needle\0binary\n".utf8))
        try fixture.put("invalid.txt", Data([0xff]) + Data("needle\n".utf8))
        try fixture.put("long.txt", "needle " + String(repeating: "x", count: 16_384) + "\nneedle after long line\n")
        try fixture.put("visible.txt", "needle visible\n")
        let result = try await service.searchContents(query: "needle")
        #expect(result.truncated)
        #expect(Set(result.matches.map(\.path)) == ["long.txt", "visible.txt"])
        #expect(result.matches.first { $0.path == "long.txt" }?.lineNumber == 2)
        #expect(result.matches.allSatisfy { $0.lineContent.utf16.count <= 16_384 })
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchPerFileAndAggregateBudgetsReturnOnlyCompletePrefixLines() async throws {
    try await withContentSearch(limits: .init(maximumFileBytes: 16)) { fixture, service in
        try fixture.put("bounded.txt", "needle\nneedle\nneedle\n")
        let result = try await service.searchContents(query: "needle")
        #expect(result.truncated && result.matches.map(\.lineNumber) == [1, 2])
        #expect(result.matches.allSatisfy { $0.lineContent == "needle" })
    }
    try await withContentSearch(limits: .init(maximumTotalBytes: 12)) { fixture, service in
        try fixture.put("a.txt", "needle\n"); try fixture.put("b.txt", "needle\n")
        let result = try await service.searchContents(query: "needle")
        #expect(result.truncated && result.matches.count == 1)
        #expect(result.matches.first?.path == "a.txt")
    }
    for excludedBytes in [Data("needle\0\n".utf8), Data([0xff]) + Data("needle\n".utf8)] {
        try await withContentSearch(limits: .init(maximumTotalBytes: 12)) { fixture, service in
            try fixture.put("a-excluded.txt", excludedBytes)
            try fixture.put("b-visible.txt", "needle\n")
            let result = try await service.searchContents(query: "needle")
            #expect(result.matches.isEmpty && result.truncated,
                    "Bytes read before binary or malformed UTF-8 rejection still consume the aggregate budget; the later four-byte prefix has no complete line.")
            #expect(result.regexFallbackError == nil)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchExpiredBudgetsAndPreCancelledCallsStopWithoutChangingFiles() async throws {
    for limits in [WorkspaceContentSearchLimits(discoveryBudget: .zero), .init(matchingBudget: .zero)] {
        try await withContentSearch(limits: limits) { fixture, service in
            let file = try fixture.put("preserved.txt", "needle unchanged\n")
            let result = try await service.searchContents(query: "needle")
            #expect(result.truncated && result.matches.isEmpty)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.searchContents(query: "needle", useRegex: true)
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try String(contentsOf: file, encoding: .utf8) == "needle unchanged\n")
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchBoundsPathologicalRegexAndLeavesWorkspaceUsable() async throws {
    try await withContentSearch(limits: .init(matchingBudget: .milliseconds(2))) { fixture, service in
        let bytes = String(repeating: "a", count: 16_000) + "!\n"
        let source = try fixture.put("adversarial.txt", bytes)
        let interrupted = try await service.searchContents(query: "(a+)+$", useRegex: true)
        #expect(interrupted.matches.isEmpty && interrupted.truncated && interrupted.regexFallbackError == nil)
        #expect(try String(contentsOf: source, encoding: .utf8) == bytes)
        try fixture.put("ordinary.txt", "recovery marker\n")
        let recovered = WorkspaceFileService(root: fixture.root, environment: fixture.environment)
        do {
            let result = try await recovered.searchContents(query: "marker")
            #expect(result.matches.count == 1 && result.matches.first?.path == "ordinary.txt" && !result.truncated)
            await recovered.close()
        } catch { await recovered.close(); throw error }
    }
}

private func contentSearchFIFOWriter(_ path: String) async throws -> Int32 {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
        let descriptor = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 { return descriptor }
        guard errno == ENXIO, ContinuousClock.now < deadline else { throw CoincideError("The content-search Git discovery fixture did not reach its config pipe.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceContentSearchCancellationDrainsGitDiscoveryAndRootReplacementCannotRedirectResults() async throws {
    try await withContentSearch(git: true) { fixture, service in
        try fixture.put("keep.txt", "needle original\n")
        let fifo = fixture.scratch.appendingPathComponent("git-config-pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try await fixture.git(["config", "--local", "include.path", fifo.path])
        let search = Task { try await service.searchContents(query: "needle") }
        do {
            let writer = try await contentSearchFIFOWriter(fifo.path); defer { close(writer) }
            search.cancel()
            await #expect(throws: CancellationError.self) { try await search.value }
            let probe = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC), failure = errno
            if probe >= 0 { close(probe) }
            #expect(probe == -1 && failure == ENXIO, "Cancellation must await the owned Git config reader's exit.")
        } catch { search.cancel(); _ = await search.result; throw error }
        let moved = fixture.scratch.appendingPathComponent("original-workspace")
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try fixture.put("replacement.txt", "needle replacement\n")
        await #expect(throws: WorkspaceFileError.self) { try await service.searchContents(query: "needle") }
        #expect(try String(contentsOf: moved.appendingPathComponent("keep.txt"), encoding: .utf8) == "needle original\n")
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("replacement.txt"), encoding: .utf8) == "needle replacement\n")
    }
}
