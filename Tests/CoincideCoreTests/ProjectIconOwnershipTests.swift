import Foundation
import Testing
@testable import CoincideCore

@Test func projectIconBinaryReadsPreserveExactBytesAndContainedSymlinksWithoutTextDecoding() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-icon-binary-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: base.appendingPathComponent("assets"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0, 0xff, 0xfe])
    try bytes.write(to: base.appendingPathComponent("assets/icon.png"))
    try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"), withIntermediateDirectories: false)
    try bytes.write(to: base.appendingPathComponent(".git/icon.png"))
    try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("favicon.png"), withDestinationURL: base.appendingPathComponent("assets/icon.png"))
    let files = WorkspaceFileService(root: base)
    do {
        let asset = try #require(try await ProjectIconResolver.resolve(using: files))
        #expect(asset.relativePath == "favicon.png" && asset.data == bytes)
        #expect(try await files.readBinary(relativePath: "assets/icon.png", maxBytes: bytes.count) == bytes)
        await #expect(throws: WorkspaceFileError.self) { try await files.readBinary(relativePath: ".git/icon.png") }
        await #expect(throws: WorkspaceFileError.self) { try await files.readBinary(relativePath: "assets/icon.png", maxBytes: bytes.count - 1) }
        await files.close()
        await #expect(throws: WorkspaceFileError.self) { try await files.readBinary(relativePath: "assets/icon.png") }
    } catch { await files.close(); throw error }
}

@Test(arguments: ["ancestor", "leaf", "root"])
func projectIconBinaryReadRejectsAnOwnershipSwapDuringTheOwnedRead(mode: String) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-icon-swap-" + UUID().uuidString).resolvingSymlinksInPath()
    let root = base.appendingPathComponent("Workspace"), assets = root.appendingPathComponent("assets"), outside = base.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    let original = Data(repeating: 0xa5, count: 150_000), secret = Data(repeating: 0x5a, count: 150_000)
    try original.write(to: assets.appendingPathComponent("icon.png")); try secret.write(to: outside.appendingPathComponent("icon.png"))
    let anchor = try WorkspaceFileRoot(root: root); defer { anchor.close() }
    var swapped = false, swapError: (any Error)?
    #expect(throws: WorkspaceFileError.self) {
        try anchor.readBinary("assets/icon.png", maxBytes: 200_000, onRead: { _ in
            guard !swapped else { return }; swapped = true
            do {
                switch mode {
                case "ancestor":
                    try FileManager.default.moveItem(at: assets, to: root.appendingPathComponent("saved-assets"))
                    try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: outside)
                case "leaf":
                    try FileManager.default.moveItem(at: assets.appendingPathComponent("icon.png"), to: assets.appendingPathComponent("saved-icon.png"))
                    try FileManager.default.createSymbolicLink(at: assets.appendingPathComponent("icon.png"), withDestinationURL: outside.appendingPathComponent("icon.png"))
                default:
                    try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("SavedWorkspace"))
                    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
                }
            } catch { swapError = error }
        })
    }
    #expect(swapped && swapError == nil)
    #expect(try Data(contentsOf: outside.appendingPathComponent("icon.png")) == secret)
}
