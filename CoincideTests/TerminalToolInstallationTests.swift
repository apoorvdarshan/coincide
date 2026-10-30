import Foundation
import Testing
@testable import Coincide

struct TerminalToolInstallationTests {
    private func tool(in folder: TemporaryDirectory) throws -> URL {
        let tool = try folder.file("Coincide.app/Contents/Helpers/coincide", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    @Test func automaticallyInstallsAndDetectsWithoutRewritingAnExistingLink() throws {
        let folder = TemporaryDirectory("automatic-cli")
        let tool = try tool(in: folder)
        let bin = try folder.folder("homebrew/bin")
        let path = bin.path + ":/usr/bin"
        let first = try TerminalToolInstallation.ensure(tool: tool, home: folder.url, searchPath: path, installDirectories: [bin])
        #expect(first.url == bin.appendingPathComponent("coincide"))
        #expect(first.isOnPath)
        #expect(first.url.resolvingSymlinksInPath() == tool)
        let inode = try FileManager.default.attributesOfItem(atPath: first.url.path)[.systemFileNumber] as? NSNumber
        let next = try TerminalToolInstallation.ensure(tool: tool, home: folder.url, searchPath: path, installDirectories: [bin])
        #expect(next == first)
        #expect(try FileManager.default.attributesOfItem(atPath: first.url.path)[.systemFileNumber] as? NSNumber == inode)
    }

    @Test func repairsAnOldOrBrokenCoincideLink() throws {
        let folder = TemporaryDirectory("stale-cli")
        let tool = try tool(in: folder)
        let bin = try folder.folder("bin")
        let link = bin.appendingPathComponent("coincide")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url.appendingPathComponent("Old.app/Contents/Helpers/coincide"))
        let found = try TerminalToolInstallation.ensure(tool: tool, home: folder.url, searchPath: bin.path, installDirectories: [bin])
        #expect(found.url == link && found.isOnPath)
        #expect(link.resolvingSymlinksInPath() == tool)
    }

    @Test func neverReplacesOrHidesAnotherCommandEarlierOnPath() throws {
        let folder = TemporaryDirectory("occupied-cli")
        let tool = try tool(in: folder)
        let foreign = try folder.file("first/coincide", "#!/bin/sh\necho unrelated\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: foreign.path)
        let bin = try folder.folder("second")
        let path = foreign.deletingLastPathComponent().path + ":" + bin.path
        #expect(throws: CommandLineControl.InstallError.self) {
            try TerminalToolInstallation.ensure(tool: tool, home: folder.url, searchPath: path, installDirectories: [bin])
        }
        #expect(try String(contentsOf: foreign, encoding: .utf8) == "#!/bin/sh\necho unrelated\n")
        #expect(!FileManager.default.fileExists(atPath: bin.appendingPathComponent("coincide").path))
    }

    @Test func bundledAgentPathDoesNotCountAsATerminalInstallation() throws {
        let folder = TemporaryDirectory("bundled-cli")
        let tool = try tool(in: folder)
        let bin = try folder.folder("local/bin")
        let found = try TerminalToolInstallation.ensure(tool: tool, home: folder.url,
            searchPath: tool.deletingLastPathComponent().path + ":/usr/bin", installDirectories: [bin])
        #expect(found.url == bin.appendingPathComponent("coincide"))
        #expect(!found.isOnPath)
    }

    @Test func anUnrelatedBrokenLinkIsPreserved() throws {
        let folder = TemporaryDirectory("foreign-link-cli")
        let tool = try tool(in: folder)
        let bin = try folder.folder("bin")
        let link = bin.appendingPathComponent("coincide")
        let target = folder.url.appendingPathComponent("unrelated/missing")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: CommandLineControl.InstallError.self) {
            try TerminalToolInstallation.ensure(tool: tool, home: folder.url, searchPath: bin.path, installDirectories: [bin])
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }
}
