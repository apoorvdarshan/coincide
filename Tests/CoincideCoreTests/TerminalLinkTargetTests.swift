import CoincideCore
import Foundation
import Testing

@Test(arguments: [
    // Compiler and test output: trailing colon, line and column.
    ("src/app/main.swift:42:7:", TerminalLinkTarget.file(path: "/repo/src/app/main.swift", line: 42, column: 7)),
    ("./Sources/Foo.swift:12", .file(path: "/repo/Sources/Foo.swift", line: 12, column: nil)),
    ("../other/readme.md.", .file(path: "/other/readme.md", line: nil, column: nil)),
    ("/tmp/build.log", .file(path: "/tmp/build.log", line: nil, column: nil)),
    ("~/notes/todo.txt:3", .file(path: "/Users/tester/notes/todo.txt", line: 3, column: nil)),
    ("(lib/util.ts:9:1)", .file(path: "/repo/lib/util.ts", line: 9, column: 1)),
    ("\"docs/with space.md\":4", .file(path: "/repo/docs/with space.md", line: 4, column: nil)),
    ("file:///tmp/report.html", .file(path: "/tmp/report.html", line: nil, column: nil)),
    ("https://example.com/a_(b)", .web(URL(string: "https://example.com/a_(b)")!)),
    ("https://example.com/path).", .web(URL(string: "https://example.com/path")!)),
    ("HTTP://localhost:3000/?q=1,", .web(URL(string: "HTTP://localhost:3000/?q=1")!)),
])
func terminalLinksResolveAgainstTheTerminalDirectory(raw: String, expected: TerminalLinkTarget) {
    #expect(TerminalLinkTarget.resolve(raw, currentDirectory: "/repo/", homeDirectory: "/Users/tester") == expected)
}

@Test func terminalLinksRefuseOtherSchemesControlsAndOversizedText() {
    for raw in ["mailto:someone@example.com", "ssh://host/repo", "ftp://example.com/file", "javascript:alert(1)",
                "vscode://file/tmp/x", "", "   ", "src/a\u{1b}[31m.swift", String(repeating: "a/", count: 3_000),
                "https://", "file://remote-host/tmp/x"] {
        #expect(TerminalLinkTarget.resolve(raw, currentDirectory: "/repo") == nil, "\(raw.prefix(40))")
    }
}

@Test func terminalLinkPositionsAndDelimitersFollowT3Rules() {
    #expect(TerminalLinkTarget.splitPosition("a/b.swift:10:2").line == 10)
    #expect(TerminalLinkTarget.splitPosition("a/b.swift:10:2").column == 2)
    #expect(TerminalLinkTarget.splitPosition("a/b.swift:0").line == nil)
    #expect(TerminalLinkTarget.splitPosition("a/b:c.swift").path == "a/b:c.swift")
    #expect(TerminalLinkTarget.trimClosingDelimiters("https://x.dev/(a)).", path: false) == "https://x.dev/(a)")
    #expect(TerminalLinkTarget.trimClosingDelimiters("src/x.ts:1:", path: true) == "src/x.ts:1")
    #expect(TerminalLinkTarget.trimClosingDelimiters("https://x.dev/a:", path: false) == "https://x.dev/a:")
    #expect(TerminalLinkTarget.trimClosingDelimiters("[src/x.ts]", path: true) == "[src/x.ts]")
}

@Test func terminalRuntimeEnvironmentMatchesT3ProjectScriptVariables() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-env-\(UUID())")
    let worktree = root.appendingPathComponent("worktree")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(TerminalRuntimeEnvironment.variables(projectRoot: root.path, workspacePath: root.path) ==
            [TerminalRuntimeEnvironment.projectRootKey: root.standardizedFileURL.path])
    #expect(TerminalRuntimeEnvironment.variables(projectRoot: root.path, workspacePath: worktree.path) ==
            [TerminalRuntimeEnvironment.projectRootKey: root.standardizedFileURL.path,
             TerminalRuntimeEnvironment.worktreePathKey: worktree.standardizedFileURL.path])
    // A symlinked spelling of the same checkout is not a separate worktree.
    let link = root.deletingLastPathComponent().appendingPathComponent("coincide-terminal-env-link-\(UUID())")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    defer { try? FileManager.default.removeItem(at: link) }
    #expect(TerminalRuntimeEnvironment.variables(projectRoot: root.path, workspacePath: link.path)[TerminalRuntimeEnvironment.worktreePathKey] == nil)
    #expect(TerminalRuntimeEnvironment.variables(projectRoot: "relative", workspacePath: root.path).isEmpty)
    #expect(TerminalRuntimeEnvironment.variables(projectRoot: root.path, workspacePath: "/bad\0path").isEmpty)
}
