import Foundation
import Testing
@testable import Coincide

@Test func conversationExportFileIsPrivateAndNeverReplacesExistingFilesOrLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-export-file-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("conversation.md")
    let original = Data("Synthetic public conversation".utf8)
    try ConversationExportFile.writeNew(original, to: target)
    #expect(try Data(contentsOf: target) == original)
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(throws: (any Error).self) { try ConversationExportFile.writeNew(Data("replacement".utf8), to: target) }
    let link = root.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) { try ConversationExportFile.writeNew(Data("replacement".utf8), to: link) }
    #expect(try Data(contentsOf: target) == original)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
}
