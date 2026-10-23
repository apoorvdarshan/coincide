import CoincideCore
import CoincideTerminal
import Foundation
import Testing

@Test func terminalWorkspaceIdentityRoundTripsAndRejectsDifferentConversationOwnership() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-capture-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: root.path))
    let identity = try TerminalWorkspaceIdentity.capture(thread: thread)
    let decoded = try JSONDecoder().decode(TerminalWorkspaceIdentity.self, from: JSONEncoder().encode(identity))
    #expect(decoded == identity && decoded.matches(thread: thread))
    var reincarnated = thread; reincarnated.createdAt = thread.createdAt.addingTimeInterval(1)
    #expect(!decoded.matches(thread: reincarnated))
    var foreignProject = thread; foreignProject.projectID = UUID()
    #expect(!decoded.matches(thread: foreignProject))
    let alias = root.appendingPathComponent("same-checkout-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    var changedSpelling = thread; changedSpelling.workspacePath = alias.path
    #expect(!decoded.matches(thread: changedSpelling), "An equal inode cannot replace the exact registered checkout spelling.")
}

@Test(arguments: [false, true])
func terminalWorkspaceIdentityRejectsPhysicalWorkspaceOrLaunchDirectoryReplacement(replaceLaunchDirectory: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-node-\(UUID())").resolvingSymlinksInPath()
    let workspace = root.appendingPathComponent("workspace"), directory = workspace.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: workspace.path))
    let identity = try TerminalWorkspaceIdentity.capture(thread: thread, directory: directory)
    #expect(identity.matches(thread: thread) && identity.matchesDirectory(directory.path))
    let replaced = replaceLaunchDirectory ? directory : workspace
    try FileManager.default.moveItem(at: replaced, to: root.appendingPathComponent("original-node"))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(!identity.matches(thread: thread))
    #expect(!identity.matchesDirectory(directory.path))
}
