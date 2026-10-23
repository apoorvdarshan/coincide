import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func shellFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-login-shell-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func executable(_ root: URL, _ name: String, _ body: String) throws -> String {
    let url = root.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

@Test func loginShellParsingIgnoresStartupNoiseAndKeepsOnlyAllowlistedNames() throws {
    let markers = LoginShellEnvironment.sentinels()
    var output = Data("rc noise \(markers.end)\nwithout a start\n".utf8)
    output.append(Data("noise-before\(markers.start)\n".utf8))
    output.append(Data("PATH=/shell/bin:/usr/bin\0SECRET_TOKEN=do-not-keep\0LANG=en_GB.UTF-8\0MULTI=line\none\0SSH_AUTH_SOCK=/tmp/agent=sock\0".utf8))
    output.append(Data("\n\(markers.end)\nPATH=/trailing/noise\0".utf8))
    let values = try #require(LoginShellEnvironment.parse(output, start: markers.start, end: markers.end))
    #expect(values == ["PATH": "/shell/bin:/usr/bin", "LANG": "en_GB.UTF-8", "SSH_AUTH_SOCK": "/tmp/agent=sock"])
    #expect(LoginShellEnvironment.parse(Data("PATH=/x\0".utf8), start: markers.start, end: markers.end) == nil)
    #expect(LoginShellEnvironment.parse(Data("\(markers.start)\nPATH=/x\0".utf8), start: markers.start, end: markers.end) == nil)
}

@Test func loginShellPathMergePreservesOrderAndRemovesDuplicatesAndEmptyEntries() {
    #expect(LoginShellEnvironment.mergePaths(["/a:/b::/c", nil, "/b:/d", ":/a:/e:"]) == "/a:/b:/c:/d:/e")
    #expect(LoginShellEnvironment.mergePaths([nil, ""]) == nil)
    #expect(LoginShellEnvironment.candidates(shellVariable: " /opt/homebrew/bin/fish ", userShell: "/bin/zsh") == ["/opt/homebrew/bin/fish", "/bin/zsh"])
    #expect(LoginShellEnvironment.candidates(shellVariable: "zsh", userShell: nil) == ["/bin/zsh"])
}

@Test func loginShellSnapshotFillsOnlyMissingValuesAndTreatsLocaleAsOneGroup() {
    let snapshot = LoginShellEnvironment.Snapshot(source: .loginShell("/bin/zsh"), values: [
        "PATH": "/Users/me/.nvm/bin:/usr/bin", "SSH_AUTH_SOCK": "/shell/agent", "HOMEBREW_PREFIX": "/opt/homebrew",
        "LANG": "fr_FR.UTF-8", "__MISE_DIFF": "shell-diff", "SSL_CERT_FILE": "/shell/cert.pem", "UNLISTED": "dropped",
    ])
    #expect(snapshot.values["UNLISTED"] == nil && snapshot.pathEntryCount == 2)
    let inherited = ["PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/launchd/agent", "LC_CTYPE": "UTF-8", "__MISE_DIFF": "old", "HOME": "/Users/me"]
    let applied = snapshot.applied(to: inherited, extraPaths: ["/opt/homebrew/bin", "/bin"])
    #expect(applied["PATH"] == "/Users/me/.nvm/bin:/usr/bin:/bin:/opt/homebrew/bin")
    #expect(applied["SSH_AUTH_SOCK"] == "/launchd/agent" && applied["HOMEBREW_PREFIX"] == "/opt/homebrew")
    #expect(applied["__MISE_DIFF"] == "shell-diff" && applied["SSL_CERT_FILE"] == "/shell/cert.pem" && applied["HOME"] == "/Users/me")
    #expect(applied["LANG"] == nil && applied["LC_CTYPE"] == "UTF-8", "An inherited locale variable keeps the whole group.")
    let bare = snapshot.applied(to: ["PATH": "/usr/bin"], extraPaths: [])
    #expect(bare["LANG"] == "fr_FR.UTF-8" && bare["LC_CTYPE"] == nil && bare["SSH_AUTH_SOCK"] == "/shell/agent")
    let none = LoginShellEnvironment.Snapshot(source: .none, values: [:]).applied(to: [:], extraPaths: ["/usr/bin"])
    #expect(none["LC_CTYPE"] == "en_US.UTF-8" && none["PATH"] == "/usr/bin")
}

@Test(.timeLimit(.minutes(1)))
func loginShellCaptureReadsAFakeShellAndIgnoresItsOutputAroundTheSentinels() async throws {
    let root = try shellFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let shell = try executable(root, "fake-zsh", """
    printf 'Welcome from rc files\\n'
    [ "$1" = "-ilc" ] || exit 9
    PATH="/fixture/nvm/bin:$PATH"; export PATH
    SECRET_TOKEN=not-captured; export SECRET_TOKEN
    HOMEBREW_PREFIX=/fixture/brew; export HOMEBREW_PREFIX
    /bin/sh -c "$2"
    printf 'logout noise\\n'
    """)
    let launchctl = try executable(root, "launchctl", "exit 7")
    let snapshot = await LoginShellEnvironment.capture(.init(candidates: [shell], inherited: ["PATH": "/usr/bin:/bin", "HOME": root.path],
                                                             shellTimeout: .seconds(10), launchctl: launchctl))
    #expect(snapshot.source == .loginShell(shell) && snapshot.failure == nil)
    #expect(snapshot.values["PATH"] == "/fixture/nvm/bin:/usr/bin:/bin" && snapshot.values["HOMEBREW_PREFIX"] == "/fixture/brew")
    #expect(snapshot.values["SECRET_TOKEN"] == nil)
}

@Test(.timeLimit(.minutes(1)))
func loginShellCaptureFallsBackToLaunchctlAfterAFailingShell() async throws {
    let root = try shellFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let failing = try executable(root, "broken-shell", "printf 'PATH=/not/trusted\\n'; exit 3")
    let launchctl = try executable(root, "launchctl", "[ \"$1 $2\" = 'getenv PATH' ] && printf '/launchd/bin:/usr/bin\\n'")
    let snapshot = await LoginShellEnvironment.capture(.init(candidates: [failing, root.appendingPathComponent("missing").path],
                                                             inherited: ["PATH": "/usr/bin"], launchctl: launchctl))
    #expect(snapshot.source == .launchctl && snapshot.values["PATH"] == "/launchd/bin:/usr/bin")
    #expect(snapshot.failure?.contains("broken-shell exited with status 3") == true && snapshot.failure?.contains("not executable") == true)
    let nothing = await LoginShellEnvironment.capture(.init(candidates: [failing], inherited: [:], launchctl: try executable(root, "launchctl-empty", "exit 0")))
    #expect(nothing.source == .none && nothing.values["PATH"] == nil && nothing.failure != nil)
}

@Test(.timeLimit(.minutes(1)))
func loginShellCaptureKillsAHangingShellGroupAtTheTimeoutAndStopsTryingShells() async throws {
    let root = try shellFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appendingPathComponent("child.pid")
    let hanging = try executable(root, "hanging-shell", "/bin/sleep 60 &\nprintf '%s' \"$!\" > '\(pidFile.path)'\nwait")
    let marker = root.appendingPathComponent("second-shell-ran")
    let second = try executable(root, "second-shell", "touch '\(marker.path)'")
    let launchctl = try executable(root, "launchctl", "printf '/fallback/bin\\n'")
    let started = ContinuousClock.now
    let snapshot = await LoginShellEnvironment.capture(.init(candidates: [hanging, second], inherited: ["PATH": "/usr/bin:/bin"],
                                                             shellTimeout: .milliseconds(600), launchctl: launchctl))
    #expect(started.duration(to: .now) < .seconds(5))
    #expect(snapshot.source == .launchctl && snapshot.failure?.contains("did not finish") == true)
    #expect(!FileManager.default.fileExists(atPath: marker.path), "A timed-out shell is not followed by more shells.")
    let child = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
    let deadline = ContinuousClock.now + .seconds(3)
    while kill(child, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(kill(child, 0) == -1 && errno == ESRCH, "The shell's process group, including its background child, is killed.")
}

@Test(.timeLimit(.minutes(1)))
func boundedProcessCapsOutputAndReportsExitStatus() async throws {
    let flood = await BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "while :; do printf 'xxxxxxxxxxxxxxxx'; done"], environment: [:],
                                         timeout: .seconds(10), outputLimit: 4_096)
    #expect(flood.overflowed && flood.output.isEmpty && flood.status == nil)
    let normal = await BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 4"], environment: [:],
                                          timeout: .seconds(10), outputLimit: 4_096)
    #expect(normal.status == 4 && normal.output == Data("out".utf8))
    let merged = await BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2"], environment: [:],
                                          timeout: .seconds(10), outputLimit: 4_096, mergeStandardError: true)
    #expect(merged.status == 0 && String(decoding: merged.output, as: UTF8.self).contains("err"))
    let missing = await BoundedProcess.run(executable: "/nonexistent/coincide", arguments: [], environment: [:], timeout: .seconds(1), outputLimit: 16)
    #expect(missing.launchError != nil)
}

@Test func loginShellSnapshotReachesProcessEnvironmentAndExecutableLookup() throws {
    let root = try shellFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("only-in-shell-path", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let tool = "coincide-shell-only-\(UUID().uuidString.prefix(8))"
    _ = try executable(bin, tool, "exit 0")
    // The injected form avoids changing the process-wide snapshot other tests read.
    let without = try #require(ProcessChannel.environment(loginShell: nil)["PATH"])
    #expect(ProcessChannel.findExecutable(tool, searchPath: without) == nil)
    let environment = ProcessChannel.environment(loginShell: .init(source: .loginShell("/bin/zsh"), values: ["PATH": bin.path]))
    let path = try #require(environment["PATH"])
    #expect(path.hasPrefix(bin.path + ":") && path.contains("/usr/bin") && environment["CODEX_THREAD_ID"] == nil)
    #expect(ProcessChannel.findExecutable(tool, searchPath: path)?.path == bin.appendingPathComponent(tool).path)
}
