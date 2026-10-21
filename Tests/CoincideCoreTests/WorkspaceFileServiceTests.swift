import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct LocalFileFixture: Sendable {
    let scratch: URL
    let root: URL
    let outside: URL
    let environment: [String: String]
    static func make(git: Bool = false) async throws -> Self {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-local-files-" + UUID().uuidString).resolvingSymlinksInPath()
        let root = scratch.appendingPathComponent("workspace"), outside = scratch.appendingPathComponent("outside"), home = scratch.appendingPathComponent("home")
        for path in [root, outside, home] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        var environment = ProcessChannel.environment()
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["HOME"] = home.path; environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["GIT_CONFIG_GLOBAL"] = home.appendingPathComponent(".gitconfig").path; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"
        let fixture = Self(scratch: scratch, root: root, outside: outside, environment: environment)
        do { if git { try await fixture.git(["init", "--initial-branch=main"]) }; return fixture }
        catch { try? FileManager.default.removeItem(at: scratch); throw error }
    }
    @discardableResult func put(_ relative: String, _ contents: String = "") throws -> URL { try put(relative, Data(contents.utf8)) }
    @discardableResult func put(_ relative: String, _ data: Data) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path); return path
    }
    func git(_ arguments: [String]) async throws {
        let result = try await CommandRunner.run("git", ["-C", root.path] + arguments, cwd: root, environment: environment)
        guard result.status == 0 else { throw CoincideError("The isolated workspace-file Git fixture failed.") }
    }
}

private func withLocalFiles(git: Bool = false, _ body: (LocalFileFixture, WorkspaceFileService) async throws -> Void) async throws {
    let fixture = try await LocalFileFixture.make(git: git)
    defer { try? FileManager.default.removeItem(at: fixture.scratch) }
    let service = WorkspaceFileService(root: fixture.root, environment: fixture.environment)
    do { try await body(fixture, service); await service.close() }
    catch { await service.close(); throw error }
}

@Test(.timeLimit(.minutes(1)))
func localFileListingIncludesHiddenIgnoredAndEmptyEntriesWhileSearchUsesGitIgnoreRules() async throws {
    try await withLocalFiles(git: true) { f, service in
        try f.put("tracked.txt", "Tracked before the ignore rule\n"); try await f.git(["add", "--", "tracked.txt"])
        try f.put(".gitignore", "ignored/\n.env\ntracked.txt\n*.log\n!keep.log\n")
        try f.put(".env", "synthetic fixture value\n"); try f.put("ignored/pkg/index.js", "ignored\n")
        try f.put("src/main.swift", "let native = true\n"); try f.put(".hidden.txt", "visible dotfile\n")
        try f.put("keep.log", "negated\n"); try f.put("drop.log", "ignored\n")
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let page = try await service.listEntries()
        #expect(try await service.listEntries() == page, "Opening a new directory stream must not inherit an exhausted root descriptor offset.")
        let entries = Dictionary(uniqueKeysWithValues: page.entries.map { ($0.path, $0) })
        #expect(!page.truncated && !page.entries.contains { $0.path.contains("/") })
        #expect(entries[".git"] == nil && entries[".gitignore"] != nil && entries[".hidden.txt"] != nil)
        #expect(entries[".env"]?.ignored == true && entries["ignored"]?.ignored == true)
        #expect(entries["tracked.txt"]?.ignored != true && entries["keep.log"]?.ignored != true)
        #expect(entries["empty"]?.isDirectory == true)
        #expect(try await service.listEntries(directoryPath: "empty").entries.isEmpty)
        let ignoredChildren = try await service.listEntries(directoryPath: "ignored/pkg")
        #expect(ignoredChildren.entries.count == 1 && ignoredChildren.entries[0].path == "ignored/pkg/index.js" && ignoredChildren.entries[0].ignored == true)
        let indexed = try await service.searchEntries(query: "", limit: 100)
        let paths = Set(indexed.entries.map(\.path))
        #expect(paths.contains("src/main.swift") && paths.contains(".hidden.txt") && paths.contains("keep.log"))
        #expect(!paths.contains("tracked.txt") && !paths.contains(".env") && !paths.contains("drop.log"))
        #expect(!paths.contains { $0 == "ignored" || $0.hasPrefix("ignored/") || $0 == ".git" || $0.hasPrefix(".git/") })
        #expect(try await service.listEntries() == page, "Search traversal must leave subsequent root listings intact.")
        let inventory = try await service.listIgnoredFiles()
        #expect(!inventory.truncated && Set(inventory.files.map(\.path)) == [".env", "drop.log"])
        #expect(inventory.files.first { $0.path == ".env" }?.byteLength == 24)
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileSearchSupportsKindsImageFilterLimitsAndNonGitFoldersWithoutInventingIgnoreLabels() async throws {
    try await withLocalFiles { f, service in
        try f.put("docs/Guide.md", "Guide\n"); try f.put("Sources/Main.swift", "Swift\n")
        try f.put("icon.svg", "<svg/>\n"); try f.put(".config", "dotfile\n")
        let listed = try await service.listEntries()
        #expect(listed.entries.allSatisfy { $0.ignored != true })
        let search = try await service.searchEntries(query: "main", limit: 20, kind: .file)
        #expect(search.entries.contains { $0.path == "Sources/Main.swift" && !$0.isDirectory })
        let directories = try await service.searchEntries(query: "", limit: 20, kind: .directory)
        #expect(Set(directories.entries.map(\.path)).isSuperset(of: ["docs", "Sources"]) && directories.entries.allSatisfy(\.isDirectory))
        let images = try await service.searchEntries(query: "", limit: 20, imageOnly: true)
        #expect(images.entries.map(\.path) == ["icon.svg"])
        let limited = try await service.searchEntries(query: "", limit: 2)
        #expect(limited.entries.count == 2 && limited.truncated)
        #expect(try await service.listIgnoredFiles().files.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileReadsDistinguishMissingEmptyBinaryAndBoundedUnicodePreviews() async throws {
    try await withLocalFiles { f, service in
        try f.put("empty.txt"); try f.put("unicode.txt", "ab😀tail")
        try f.put("large.txt", Data(repeating: 97, count: 1_048_593))
        try f.put("binary.dat", Data([112, 114, 105, 118, 97, 116, 101, 0, 120]))
        try f.put("invalid-utf8.txt", Data([0xff, 0xfe, 0x61]))
        try f.put("invalid-preview.txt", Data([0x61, 0x62, 0xff, 0x63]))
        let absent = try await service.readFile(relativePath: "optional/nested.txt", allowMissing: true)
        #expect(!absent.exists && absent.contents.isEmpty && absent.byteLength == 0 && !absent.truncated && absent.revision == nil)
        await #expect(throws: WorkspaceFileError.self) { try await service.readFile(relativePath: "optional/nested.txt") }
        let empty = try await service.readFile(relativePath: "empty.txt")
        #expect(empty.exists && empty.contents.isEmpty && empty.byteLength == 0 && !empty.truncated && empty.revision != nil)
        let large = try await service.readFile(relativePath: "large.txt")
        #expect(large.byteLength == 1_048_593 && large.contents.utf8.count == 1_048_576 && large.truncated && large.revision == nil)
        let unicode = try await service.readFile(relativePath: "unicode.txt", maxBytes: 3)
        #expect(unicode.contents == "ab" && unicode.byteLength == 10 && unicode.truncated && unicode.revision == nil)
        for path in ["binary.dat", "invalid-utf8.txt"] {
            do { _ = try await service.readFile(relativePath: path); Issue.record("A binary or malformed UTF-8 file was accepted.") }
            catch let error as WorkspaceFileError { #expect(!error.localizedDescription.contains("private")) }
        }
        do { _ = try await service.readFile(relativePath: "invalid-preview.txt", maxBytes: 3); Issue.record("Malformed bytes were treated as an incomplete valid Unicode suffix.") }
        catch let error as WorkspaceFileError { #expect(error.failure == .invalidUTF8) }
        await #expect(throws: WorkspaceFileError.self) { try await service.readFile(relativePath: "large.txt", maxBytes: Int.max) }
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileInternalSymlinksRemainLinksAndExternalDanglingOrTraversalPathsCannotReadOrWrite() async throws {
    try await withLocalFiles { f, service in
        try f.put("docs/inside.txt", "Before\n")
        let outsideFile = f.outside.appendingPathComponent("outside.txt"), outsideBytes = Data("Keep outside bytes\n".utf8)
        try outsideBytes.write(to: outsideFile)
        for (name, destination) in [("inside-link.txt", "docs/inside.txt"), ("docs-alias", "docs"),
                                    ("outside", f.outside.path), ("dangling", "docs/missing.txt"), ("loop-a", "loop-b"), ("loop-b", "loop-a")] {
            try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent(name).path, withDestinationPath: destination)
        }
        let listed = try await service.listEntries()
        #expect(!listed.entries.contains { ["inside-link.txt", "docs-alias", "outside", "dangling", "loop-a", "loop-b"].contains($0.path) })
        #expect(try await service.listEntries(directoryPath: "docs-alias").entries.map(\.path) == ["docs-alias/inside.txt"])
        let document = try await service.readFile(relativePath: "inside-link.txt"), revision = try #require(document.revision)
        _ = try await service.writeFile(relativePath: "inside-link.txt", contents: "After\n", expected: .matching(revision))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.root.appendingPathComponent("inside-link.txt").path) == "docs/inside.txt")
        #expect(try String(contentsOf: f.root.appendingPathComponent("docs/inside.txt"), encoding: .utf8) == "After\n")
        for path in ["../outside/outside.txt", "docs/../inside-link.txt", outsideFile.path, "outside/outside.txt", "outside/missing/new.txt", "dangling", "loop-a"] {
            await #expect(throws: WorkspaceFileError.self) { try await service.readFile(relativePath: path, allowMissing: true) }
            await #expect(throws: WorkspaceFileError.self) { try await service.writeFile(relativePath: path, contents: "Forbidden", expected: .missing) }
        }
        #expect(try Data(contentsOf: outsideFile) == outsideBytes && !FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("missing").path))
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileSpecialNodesAreExcludedAndCannotBlockReadOrMutation() async throws {
    try await withLocalFiles { f, service in
        let fifo = f.root.appendingPathComponent("named-pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("directory"), withIntermediateDirectories: true)
        let page = try await service.listEntries()
        #expect(!page.entries.contains { $0.path == "named-pipe" })
        for path in ["named-pipe", "directory"] {
            await #expect(throws: WorkspaceFileError.self) { try await service.readFile(relativePath: path) }
            await #expect(throws: WorkspaceFileError.self) { try await service.writeFile(relativePath: path, contents: "Forbidden", expected: .missing) }
        }
        var status = stat(); #expect(lstat(fifo.path, &status) == 0 && status.st_mode & S_IFMT == S_IFIFO)
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileMutationsRejectNamedAndResolvedGitMetadataButAllowNormalDotfiles() async throws {
    try await withLocalFiles { f, service in
        try f.put(".git/config", "Keep Git config\n")
        try f.put(".bare/HEAD", "ref: refs/heads/main\n")
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent(".bare/objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent(".bare/refs"), withIntermediateDirectories: true)
        try f.put(".bare/worktrees/main/HEAD", "ref: refs/heads/main\n"); try f.put(".bare/worktrees/main/commondir", "../..\n")
        try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent("git-alias").path, withDestinationPath: ".bare")
        let config = try Data(contentsOf: f.root.appendingPathComponent(".git/config"))
        for path in [".git/config", "nested/.git/config", ".GIT/config", ".gıt/config", ".git. /config", "GIT~1/config", ".git::$INDEX_ALLOCATION/config", ".bare/config", ".bare/worktrees/main/commondir", "git-alias/hooks/new-hook"] {
            do { _ = try await service.writeFile(relativePath: path, contents: "Forbidden", expected: .missing); Issue.record("A Git metadata mutation was accepted.") }
            catch let error as WorkspaceFileError { #expect(error.failure == .gitMetadata) }
        }
        #expect(try Data(contentsOf: f.root.appendingPathComponent(".git/config")) == config)
        for path in [".gitignore", ".github/workflows/native.yml"] {
            let created = try await service.writeFile(relativePath: path, contents: "Allowed\n", expected: .missing)
            #expect(created.exists && created.contents == "Allowed\n" && created.revision != nil)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".bare/config").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("nested").path))
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileCreateAndSaveUseRevisionsPreserveExecutableModeAndRejectExternalReplacement() async throws {
    try await withLocalFiles { f, service in
        let created = try await service.writeFile(relativePath: "notes/deep/file.txt", contents: "First\n", expected: .missing)
        let initial = try #require(created.revision)
        #expect(created.exists && !created.truncated && created.byteLength == 6)
        await #expect(throws: WorkspaceFileError.self) { try await service.writeFile(relativePath: "notes/deep/file.txt", contents: "Collision", expected: .missing) }
        let saved = try await service.writeFile(relativePath: "notes/deep/file.txt", contents: "Second\n", expected: .matching(initial))
        #expect(saved.contents == "Second\n" && saved.revision != initial)
        await #expect(throws: WorkspaceFileError.self) { try await service.writeFile(relativePath: "notes/deep/file.txt", contents: "Stale", expected: .matching(initial)) }
        let path = f.root.appendingPathComponent("notes/deep/file.txt")
        try Data("Second\n".utf8).write(to: path, options: .atomic)
        await #expect(throws: WorkspaceFileError.self) { try await service.writeFile(relativePath: "notes/deep/file.txt", contents: "Overwrote replacement", expected: .matching(try #require(saved.revision))) }
        #expect(try String(contentsOf: path, encoding: .utf8) == "Second\n")
        let executable = try f.put("run.sh", "#!/bin/sh\nexit 0\n"); #expect(chmod(executable.path, 0o755) == 0)
        let script = try await service.readFile(relativePath: "run.sh")
        _ = try await service.writeFile(relativePath: "run.sh", contents: "#!/bin/sh\nexit 1\n", expected: .matching(try #require(script.revision)))
        var mode = stat(); #expect(lstat(executable.path, &mode) == 0 && mode.st_mode & 0o777 == 0o755)
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileConcurrentCreateHasOneWinnerAndCancelledCreateLeavesNoFile() async throws {
    try await withLocalFiles { f, service in
        let first = Task { try await service.writeFile(relativePath: "race.txt", contents: "First", expected: .missing) }
        let second = Task { try await service.writeFile(relativePath: "race.txt", contents: "Second", expected: .missing) }
        let results = [await first.result, await second.result]
        let winners = results.compactMap { try? $0.get() }
        #expect(winners.count == 1)
        for result in results { if case .failure(let error) = result { #expect(error is WorkspaceFileError) } }
        let persisted = try await service.readFile(relativePath: "race.txt")
        #expect(persisted.contents == winners.first?.contents)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.writeFile(relativePath: "cancelled.txt", contents: "Never publish", expected: .missing)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("cancelled.txt").path))
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileRootReplacementInvalidatesExistingServiceWithoutTouchingEitherDirectory() async throws {
    try await withLocalFiles { f, service in
        let oldFile = try f.put("owned.txt", "Original\n"), original = try await service.readFile(relativePath: "owned.txt")
        let moved = f.scratch.appendingPathComponent("moved-workspace")
        try FileManager.default.moveItem(at: f.root, to: moved)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data("Replacement\n".utf8).write(to: oldFile)
        await #expect(throws: WorkspaceFileError.self) { try await service.listEntries() }
        await #expect(throws: WorkspaceFileError.self) { try await service.readFile(relativePath: "owned.txt") }
        await #expect(throws: WorkspaceFileError.self) { try await service.writeFile(relativePath: "owned.txt", contents: "Forbidden", expected: .matching(try #require(original.revision))) }
        await #expect(throws: WorkspaceFileError.self) { try await service.writeFile(relativePath: "new.txt", contents: "Forbidden", expected: .missing) }
        #expect(try String(contentsOf: moved.appendingPathComponent("owned.txt"), encoding: .utf8) == "Original\n")
        #expect(try String(contentsOf: oldFile, encoding: .utf8) == "Replacement\n")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.txt").path))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("new.txt").path))
    }
}

private actor LocalFileInvalidationProbe {
    private var values: [WorkspaceFileInvalidation] = []
    func append(_ value: WorkspaceFileInvalidation) { values.append(value) }
    func all() -> [WorkspaceFileInvalidation] { values }
}
private func waitLocalFiles(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The local workspace-file fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)))
func localFileInvalidationsObserveExternalWritesMutationsRefreshAndFinishAtClose() async throws {
    try await withLocalFiles { f, service in
        let probe = LocalFileInvalidationProbe(), stream = await service.invalidations()
        let reader = Task { for await value in stream { await probe.append(value) } }
        do {
            for index in 0..<8 { try f.put("external-\(index).txt", "External\n") }
            try await waitLocalFiles { await probe.all().contains { if case .externalChange = $0.reason { true } else { false } } }
            let page = try await service.listEntries()
            #expect(Set(page.entries.map(\.path)).isSuperset(of: (0..<8).map { "external-\($0).txt" }))
            _ = try await service.writeFile(relativePath: "created.txt", contents: "Native mutation\n", expected: .missing)
            try await waitLocalFiles { await probe.all().contains { if case .mutation = $0.reason { true } else { false } } }
            await service.refresh()
            try await waitLocalFiles { await probe.all().contains { if case .refresh = $0.reason { true } else { false } } }
            await service.close(); await reader.value
            let values = await probe.all(), generations = values.map(\.generation)
            #expect(!generations.isEmpty && generations == generations.sorted() && Set(generations).count == generations.count)
            try f.put("after-close.txt", "No owned watcher remains\n"); await service.refresh()
            #expect(await probe.all().count == values.count)
            await #expect(throws: WorkspaceFileError.self) { try await service.listEntries() }
        } catch { await service.close(); await reader.value; throw error }
    }
}

private func localFileFIFOWriter(_ path: String) async throws -> Int32 {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
        let descriptor = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 { return descriptor }
        guard errno == ENXIO, ContinuousClock.now < deadline else { throw CoincideError("The isolated Git ignore query did not begin reading its config pipe.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1)))
func cancellingLocalFileIgnoreClassificationDrainsItsRealGitProcessAndPreservesFiles() async throws {
    try await withLocalFiles(git: true) { f, service in
        let file = try f.put("keep.txt", "Preserve while cancelling\n"), fifo = f.scratch.appendingPathComponent("git-config-pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try await f.git(["config", "--local", "include.path", fifo.path])
        let listing = Task { try await service.listEntries() }
        do {
            let writer = try await localFileFIFOWriter(fifo.path); defer { close(writer) }
            listing.cancel()
            await #expect(throws: CancellationError.self) { try await listing.value }
            let probe = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC), failure = errno
            if probe >= 0 { close(probe) }
            #expect(probe == -1 && failure == ENXIO, "Cancellation must wait until the owned Git config reader exits.")
            #expect(try String(contentsOf: file, encoding: .utf8) == "Preserve while cancelling\n")
        } catch { listing.cancel(); _ = await listing.result; throw error }
    }
}
