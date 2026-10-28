import Darwin
import Foundation
import Testing

@testable import Coincide

/// Which files count as inside a thread's folder, so links to them open without asking.
struct SafeLinksTests {
    @Test func filesInsideTheFolderAndTheFolderItselfAreInside() throws {
        let scratch = TemporaryDirectory("links")
        let project = try scratch.folder("project")
        let file = try scratch.file("project/src/App.swift")
        #expect(SafeLinks.contains(project, file))
        #expect(SafeLinks.contains(project, project))
        #expect(SafeLinks.contains(URL(fileURLWithPath: project.path + "/"), file))
    }

    @Test func aSiblingSharingTheNamePrefixIsOutside() throws {
        let scratch = TemporaryDirectory("links")
        let project = try scratch.folder("project")
        let sibling = try scratch.file("project2/secret.txt")
        #expect(!SafeLinks.contains(project, sibling))
        #expect(!SafeLinks.contains(project, scratch.url))
    }

    @Test func dotDotSegmentsCannotClimbOut() throws {
        let scratch = TemporaryDirectory("links")
        let project = try scratch.folder("project")
        try scratch.file("other/notes.txt")
        let climbing = URL(fileURLWithPath: project.path + "/../other/notes.txt")
        #expect(!SafeLinks.contains(project, climbing))
        let staying = URL(fileURLWithPath: project.path + "/src/../README.md")
        #expect(SafeLinks.contains(project, staying))
    }

    @Test func symbolicLinksAreJudgedByWhereTheyLead() throws {
        let scratch = TemporaryDirectory("links")
        let project = try scratch.folder("project")
        let outside = try scratch.file("outside/key.pem")
        let escape = project.appendingPathComponent("escape.pem")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        #expect(!SafeLinks.contains(project, escape))

        // A project opened through a link still contains its files.
        let alias = scratch.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let file = try scratch.file("project/main.c")
        #expect(SafeLinks.contains(alias, file))
        #expect(SafeLinks.contains(project, alias.appendingPathComponent("main.c")))
    }

    @Test func theRootFolderContainsEverything() {
        #expect(SafeLinks.contains(URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/usr/bin/true")))
    }
}

/// What a Command-click in a terminal resolves to.
struct TerminalLinksTests {
    @Test func webAndMailLinksAreURLs() throws {
        let directory = URL(fileURLWithPath: "/")
        #expect(TerminalLinks.url(for: "https://example.com/docs", relativeTo: directory)?.absoluteString == "https://example.com/docs")
        #expect(TerminalLinks.url(for: "HTTPS://Example.com", relativeTo: directory)?.scheme == "HTTPS")
        #expect(TerminalLinks.url(for: "mailto:me@example.com", relativeTo: directory)?.scheme == "mailto")
        #expect(TerminalLinks.url(for: "tel:+15551234", relativeTo: directory)?.scheme == "tel")
        #expect(TerminalLinks.url(for: "ssh://host", relativeTo: directory)?.scheme == "ssh")
        #expect(TerminalLinks.url(for: "  https://padded.dev  ", relativeTo: directory)?.host == "padded.dev")
    }

    @Test func aSchemeWithoutSlashesIsAPathUnlessItIsKnown() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        // `localhost:3000` and `javascript:` are not links a program prints for opening.
        #expect(TerminalLinks.url(for: "localhost:3000", relativeTo: directory) == nil)
        #expect(TerminalLinks.url(for: "javascript:alert(1)", relativeTo: directory) == nil)
    }

    @Test func relativePathsResolveAgainstTheShellsFolder() throws {
        let scratch = TemporaryDirectory("terminal")
        try scratch.file("src/main.swift")
        try scratch.file("README.md")
        let src = scratch.url.appendingPathComponent("src")
        #expect(TerminalLinks.url(for: "src/main.swift", relativeTo: scratch.url)?.path == scratch.url.path + "/src/main.swift")
        #expect(TerminalLinks.url(for: "../README.md", relativeTo: src)?.path == scratch.url.path + "/README.md")
        #expect(TerminalLinks.url(for: "./main.swift", relativeTo: src)?.path == src.path + "/main.swift")
        #expect(TerminalLinks.url(for: "missing.swift", relativeTo: scratch.url) == nil)
    }

    @Test func compilerLocationsAfterAPathAreDropped() throws {
        let scratch = TemporaryDirectory("terminal")
        try scratch.file("main.c")
        let expected = scratch.url.path + "/main.c"
        #expect(TerminalLinks.url(for: "main.c:10", relativeTo: scratch.url)?.path == expected)
        #expect(TerminalLinks.url(for: "main.c:10:5", relativeTo: scratch.url)?.path == expected)
        #expect(TerminalLinks.url(for: expected + ":3:7", relativeTo: URL(fileURLWithPath: "/"))?.path == expected)
        #expect(TerminalLinks.url(for: "main.c:x", relativeTo: scratch.url) == nil)
    }

    @Test func absoluteAndHomePathsResolveWherever() {
        let elsewhere = URL(fileURLWithPath: "/nonexistent")
        #expect(TerminalLinks.url(for: "/usr/bin/true", relativeTo: elsewhere)?.path == "/usr/bin/true")
        #expect(TerminalLinks.url(for: "~", relativeTo: elsewhere)?.path == NSHomeDirectory())
        #expect(TerminalLinks.url(for: "file:///usr/bin", relativeTo: elsewhere)?.isFileURL == true)
    }
}

/// What a terminal's shell inherits.
struct TerminalLaunchTests {
    @Test func theTerminalIdentifiesAsCoincideAndDropsTheOuterTerminals() {
        let directory = URL(fileURLWithPath: "/tmp/project")
        let base = [
            "PATH": "/usr/bin", "HOME": "/Users/me", "LANG": "fr_FR.UTF-8", "TERM": "dumb", "TERM_PROGRAM": "iTerm.app",
            "TERM_SESSION_ID": "abc", "ITERM_PROFILE": "Default", "TMUX": "/tmp/tmux", "SHLVL": "3", "OLDPWD": "/",
            "COINCIDE_DATA_DIR": "/tmp/data", "GHOSTTY_RESOURCES_DIR": "/x", "VSCODE_PID": "1", "ZELLIJ_SESSION_NAME": "z",
        ]
        let environment = Dictionary(
            uniqueKeysWithValues: TerminalLaunch.environment(from: base, directory: directory).map { entry -> (String, String) in
                let parts = entry.split(separator: "=", maxSplits: 1)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            })
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["LANG"] == "fr_FR.UTF-8")
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "Coincide")
        #expect(environment["PWD"] == "/tmp/project")
        #expect(environment["SHELL"] == TerminalLaunch.shellPath)
        for key in ["TERM_SESSION_ID", "ITERM_PROFILE", "TMUX", "SHLVL", "OLDPWD", "COINCIDE_DATA_DIR", "GHOSTTY_RESOURCES_DIR", "VSCODE_PID", "ZELLIJ_SESSION_NAME"] {
            #expect(environment[key] == nil, "\(key)")
        }
    }

    @Test func aScriptsOwnVariablesSurviveWhileInheritedOnesAreDropped() {
        let entries = TerminalLaunch.environment(
            from: ["COINCIDE_DATA_DIR": "/tmp/data", "PATH": "/bin"], directory: URL(fileURLWithPath: "/"),
            extra: ["COINCIDE_PROJECT_ROOT": "/work"])
        #expect(entries.contains("COINCIDE_PROJECT_ROOT=/work"))
        #expect(!entries.contains { $0.hasPrefix("COINCIDE_DATA_DIR=") })
    }

    @Test func aUTF8LocaleIsSetWhenNoneIsInherited() {
        let entries = TerminalLaunch.environment(from: ["PATH": "/bin"], directory: URL(fileURLWithPath: "/"))
        let language = entries.first { $0.hasPrefix("LANG=") }
        #expect(language?.hasSuffix(".UTF-8") == true)
        // Any locale variable the shell already has is kept as it is.
        let kept = TerminalLaunch.environment(from: ["LC_ALL": "C"], directory: URL(fileURLWithPath: "/"))
        #expect(!kept.contains { $0.hasPrefix("LANG=") })
        #expect(kept.contains("LC_ALL=C"))
    }

    @Test func theLoginShellIsAnExecutable() {
        #expect(FileManager.default.isExecutableFile(atPath: TerminalLaunch.shellPath))
    }

    @Test func exitCodesComeFromTheWaitStatus() {
        #expect(TerminalProcess.exitCode(fromWaitStatus: 0) == 0)
        #expect(TerminalProcess.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(TerminalProcess.exitCode(fromWaitStatus: 255 << 8) == 255)
        // Killed by a signal: no exit code.
        #expect(TerminalProcess.exitCode(fromWaitStatus: SIGKILL) == nil)
        #expect(TerminalProcess.exitCode(fromWaitStatus: SIGHUP | 0x80) == nil)
    }

    @Test func processQueriesRefuseInvalidIDs() {
        #expect(TerminalProcess.foregroundCommand(shell: 0, terminal: 3) == nil)
        #expect(TerminalProcess.foregroundCommand(shell: 10, terminal: -1) == nil)
        #expect(TerminalProcess.currentDirectory(of: 0) == nil)
        #expect(TerminalProcess.currentDirectory(of: getpid())?.path == FileManager.default.currentDirectoryPath)
    }
}

/// Short time labels in the sidebar, toolbar and palette.
struct FormattingTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func agesUnderAMinuteReadNow() {
        #expect(Formatting.compactAge(of: now, now: now) == "now")
        #expect(Formatting.compactAge(of: now.addingTimeInterval(-59), now: now) == "now")
        // A date in the future, from another Mac's clock, is not negative.
        #expect(Formatting.compactAge(of: now.addingTimeInterval(120), now: now) == "now")
    }

    @Test func olderAgesShowOneUnit() {
        let minutes = Formatting.compactAge(of: now.addingTimeInterval(-5 * 60), now: now)
        let hours = Formatting.compactAge(of: now.addingTimeInterval(-3 * 3600 - 59), now: now)
        let days = Formatting.compactAge(of: now.addingTimeInterval(-2 * 86_400), now: now)
        #expect(minutes.contains("5") && minutes != "now")
        #expect(hours.contains("3") && !hours.contains("59"))
        #expect(days.contains("2"))
        #expect(Set([minutes, hours, days]).count == 3)
    }

    @Test func runningTimesShowMinutesAndSecondsThenHours() {
        let start = now
        func elapsed(_ seconds: TimeInterval) -> String { Formatting.elapsed(since: start, now: start.addingTimeInterval(seconds)) }
        #expect(elapsed(42) == Duration.seconds(42).formatted(.time(pattern: .minuteSecond)))
        #expect(elapsed(725) == Duration.seconds(725).formatted(.time(pattern: .minuteSecond)))
        #expect(elapsed(3729) == Duration.seconds(3729).formatted(.time(pattern: .hourMinuteSecond)))
        #expect(elapsed(-10) == elapsed(0))
        #expect(elapsed(42).contains("42"))
    }

    @Test func homeIsShownAsTilde() {
        #expect(Formatting.abbreviatedPath(NSHomeDirectory() + "/code/app") == "~/code/app")
        #expect(Formatting.abbreviatedPath("/usr/bin") == "/usr/bin")
    }
}
