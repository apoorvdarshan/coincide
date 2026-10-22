import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// A controlled comparison with the managed-install inspection test. This calls
/// the public verifier directly, without CodexInstallation, its Inspector
/// closure, package publication, extraction or any installed Codex executable.
@Test(.timeLimit(.minutes(1)))
func codexDirectExecutableInspectionChecksPrivateHomeVersionAndHelpWithoutInstallationClosure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("coincide-codex-direct-inspection-\(UUID())", isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    let scratch = root.appendingPathComponent("inspection-scratch", isDirectory: true)
    let executable = root.appendingPathComponent("synthetic-codex")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let script = #"""
    #!/usr/bin/python3 -S
    import json, os, pathlib, sys
    root = pathlib.Path(__file__).resolve().parent
    home = pathlib.Path(os.environ["CODEX_HOME"])
    def record(name, value):
        with (root / name).open("a", encoding="utf8") as out:
            out.write(json.dumps(value) + "\n")
            out.flush()
    record("started.jsonl", {
        "pid": os.getpid(), "argv": sys.argv[1:], "invoked": sys.argv[0],
        "home": str(home), "cwdMatchesScratch": os.path.samefile(pathlib.Path.cwd(), root / "inspection-scratch"),
        "credentialPresent": any(os.environ.get(key) for key in [
            "OPENAI_API_KEY", "OPENAI_BASE_URL", "ACCESS_TOKEN", "CHATGPT_ACCESS_TOKEN", "CODEX_THREAD_ID"]),
        "homePermissions": home.stat().st_mode & 0o777
    })
    # The real verifier closes input before waiting for bounded command output.
    # These private writes prove its supplied home exists and is disposable.
    (home / "owned-inspection-marker").write_text("synthetic metadata only", encoding="utf8")
    eof = sys.stdin.buffer.read() == b""
    record("completed.jsonl", {"pid": os.getpid(), "stdinEOF": eof})
    if not eof:
        sys.exit(90)
    if sys.argv[1:] == ["--version"]:
        print("codex-cli 0.156.1", flush=True)
    elif sys.argv[1:] == ["app-server", "--help"]:
        print("Synthetic app-server help; no server was started", flush=True)
    else:
        sys.exit(91)
    """#
    do {
        try Data((script + "\n").utf8).write(to: executable, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let selected = CodexInstallationExecutable(executable: executable, source: .custom)
        // Keep this direct static call: wrapping it in the installation service
        // or its async Inspector closure would erase the intended comparison.
        let version = try await CodexInstallationVerifier.inspect(executable: selected, scratch: scratch)
        #expect(version == "0.156.1")
        let started = try codexDirectInspectionRows(root.appendingPathComponent("started.jsonl"))
        let completed = try codexDirectInspectionRows(root.appendingPathComponent("completed.jsonl"))
        #expect(started.count == 2 && completed.count == 2)
        #expect(started.map { $0["argv"] } == [
            .array([.string("--version")]), .array([.string("app-server"), .string("--help")])])
        #expect(started.allSatisfy { $0["invoked"] == .string(executable.path) })
        #expect(started.allSatisfy { $0["credentialPresent"] == .bool(false) &&
            $0["cwdMatchesScratch"] == .bool(true) && $0["homePermissions"] == .number(0o700) })
        #expect(completed.allSatisfy { $0["stdinEOF"] == .bool(true) })
        let processIDs = started.compactMap(codexDirectInspectionPID)
        #expect(processIDs.count == 2 && Set(processIDs).count == 2)
        #expect(Set(processIDs) == Set(completed.compactMap(codexDirectInspectionPID)))
        let homes = try started.map { row -> URL in
            let path = try #require(row["home"].string)
            return URL(fileURLWithPath: path)
        }
        #expect(Set(homes).count == 2)
        for home in homes {
            #expect(home.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL)
            #expect(home.lastPathComponent.hasPrefix("home-"))
            #expect(!FileManager.default.fileExists(atPath: home.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        try await codexDirectInspectionWaitForExit(processIDs)
        try FileManager.default.removeItem(at: root)
    } catch {
        // inspect owns, stops and joins its children on failure too. Preserve
        // scratch rather than delete it if an observed exact PID remains alive.
        let rows = (try? codexDirectInspectionRows(root.appendingPathComponent("started.jsonl"))) ?? []
        let ids = rows.compactMap(codexDirectInspectionPID)
        if ids.allSatisfy(codexDirectInspectionStopped) { try? FileManager.default.removeItem(at: root) }
        throw error
    }
}

private func codexDirectInspectionRows(_ file: URL) throws -> [JSONValue] {
    let data = try Data(contentsOf: file)
    guard let newline = data.lastIndex(of: 10) else { return [] }
    return try data[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
}

private func codexDirectInspectionPID(_ value: JSONValue) -> Int32? {
    guard case .number(let pid) = value["pid"], pid.isFinite, pid.rounded(.towardZero) == pid,
          pid > 0, pid < Double(Int32.max) else { return nil }
    return Int32(pid)
}

private func codexDirectInspectionStopped(_ pid: Int32) -> Bool {
    Darwin.kill(pid, 0) == -1 && errno == ESRCH
}

private func codexDirectInspectionWaitForExit(_ processIDs: [Int32]) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !processIDs.allSatisfy(codexDirectInspectionStopped) {
        guard ContinuousClock.now < deadline else { throw CoincideError("A private executable inspection process did not exit.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
