import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct EditorJournalFixture {
    let root: URL
    let service: WorkspaceFileService
    let journal: EditorRecoveryJournal
    init(maximumRecords: Int = 32, maximumBytes: Int = EditorRecoveryJournal.maximumStoredBytes) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-editor-journal-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let checkout = root.appendingPathComponent("Checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("Original e\u{301}\n".utf8).write(to: checkout.appendingPathComponent("notes.txt"))
        service = .init(root: checkout)
        journal = .init(root: root.appendingPathComponent("Recovery"), maximumRecords: maximumRecords, maximumBytes: maximumBytes)
    }
    func record(text: String, id: UUID = UUID()) async throws -> EditorRecoveryRecord {
        let document = try await service.readFile(relativePath: "notes.txt")
        return try .native(workspacePath: service.root.path, document: document, contents: text, id: id)
    }
    func close() async { await service.close(); try? FileManager.default.removeItem(at: root) }
}

@Test func editorRecoveryJournalRestartsExactUnicodeAndUsesCompareAndSwapAcrossWindows() async throws {
    let f = try EditorJournalFixture()
    do {
        let first = try await f.record(text: "  New draft 😀 e\u{301} 工作\n\0\"\\  ")
        try f.journal.save(first, expectedVersion: nil)
        let reopened = EditorRecoveryJournal(root: f.journal.root)
        let saved = try #require(reopened.load().first)
        #expect(Data(saved.contents.utf8) == Data(first.contents.utf8) && saved.nativeDocument?.revision == first.nativeDocument?.revision)
        let second = try await f.record(text: "Newest draft", id: first.id)
        try reopened.save(second, expectedVersion: first.version)
        #expect(throws: EditorRecoveryError(.changed)) { try f.journal.remove(id: first.id, expectedVersion: first.version) }
        #expect(throws: EditorRecoveryError(.changed)) { try f.journal.save(first, expectedVersion: first.version) }
        #expect(try reopened.load() == [second])
        let file = f.journal.root.appendingPathComponent("editor-drafts.json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: f.journal.root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try reopened.remove(id: second.id, expectedVersion: second.version)
        #expect(try reopened.load().isEmpty)
        #expect(throws: EditorRecoveryError(.changed)) { try f.journal.save(first, expectedVersion: first.version) }
    } catch { await f.close(); throw error }; await f.close()
}

@Test func editorRecoveryCapacityAndCorruptionPreserveEveryPreviouslySavedByte() async throws {
    let f = try EditorJournalFixture(maximumRecords: 1)
    do {
        let first = try await f.record(text: "Retain exact first draft"), second = try await f.record(text: "Cannot evict first")
        try f.journal.save(first, expectedVersion: nil)
        let file = f.journal.root.appendingPathComponent("editor-drafts.json"), before = try Data(contentsOf: file)
        #expect(throws: EditorRecoveryError(.capacity)) { try f.journal.save(second, expectedVersion: nil) }
        #expect(try Data(contentsOf: file) == before)
        let bounded = EditorRecoveryJournal(root: f.root.appendingPathComponent("Small"), maximumBytes: 64)
        #expect(throws: EditorRecoveryError(.capacity)) { try bounded.save(first, expectedVersion: nil) }
        #expect(try bounded.load().isEmpty)
        let corrupt = Data("not editor recovery JSON".utf8)
        try corrupt.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(throws: EditorRecoveryError(.invalidData)) { try f.journal.save(first, expectedVersion: first.version) }
        #expect(throws: EditorRecoveryError(.invalidData)) { try f.journal.remove(id: first.id, expectedVersion: first.version) }
        #expect(try Data(contentsOf: file) == corrupt)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(arguments: ["symlink", "hardlink", "fifo", "public-file", "public-directory"])
func editorRecoveryRefusesUnsafeStorageWithoutFollowingOrReplacingIt(kind: String) async throws {
    let f = try EditorJournalFixture()
    do {
        let record = try await f.record(text: "Private draft")
        try FileManager.default.createDirectory(at: f.journal.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = f.journal.root.appendingPathComponent("editor-drafts.json"), outside = f.root.appendingPathComponent("original-private-file")
        let original = Data("preserve unrelated private file".utf8); try original.write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        case "hardlink": try FileManager.default.linkItem(at: outside, to: file)
        case "fifo": #expect(mkfifo(file.path, 0o600) == 0)
        case "public-file": try Data("{}".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        default: try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.journal.root.path)
        }
        #expect(throws: EditorRecoveryError(.unsafeStorage)) { try f.journal.save(record, expectedVersion: nil) }
        #expect(try Data(contentsOf: outside) == original)
    } catch { await f.close(); throw error }; await f.close()
}
