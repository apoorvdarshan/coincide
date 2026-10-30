import Darwin
import CoincideKit
import CoincideRemoteKit
import Foundation
import Testing

@testable import Coincide

/// `coincide`'s arguments: commands, options anywhere, messages from words or standard input, and clear errors.
struct CLIParserTests {
    private func parse(_ line: [String], stdin: String = "") throws -> CLIInvocation {
        try CLIParser.parse(line) { stdin }
    }

    @Test func commandsAndOptions() throws {
        #expect(try parse([]).command == .help)
        #expect(try parse(["help"]).command == .help)
        let projects = try parse(["projects", "--json"])
        #expect(projects.command == .projects && projects.json)
        #expect(try parse(["--socket=/tmp/c.sock", "projects"]).socket == "/tmp/c.sock")
        #expect(try parse(["threads", "--chats", "--running"]).command == .threads(project: "chats", includeArchived: false, runningOnly: true))

        guard case .new(let new) = try parse(["new", "--chat", "--agent", "claude", "--model", "opus", "--plan", "--wait", "fix", "the", "build"]).command
        else { Issue.record("not new"); return }
        #expect(new.project == nil && new.agent == "claude" && new.model == "opus" && new.plan && new.wait)
        #expect(new.message == "fix the build")
        guard case .new(let inProject) = try parse(["new", "--project", "~/code/app", "--access", "full", "--title", "Fix", "--open"]).command
        else { Issue.record("not new"); return }
        #expect(inProject.project == "~/code/app" && inProject.access == "full" && inProject.title == "Fix" && inProject.open)
        #expect(inProject.message == nil)

        #expect(try parse(["send", "ab12", "hi", "there", "--wait", "--timeout", "30"]).command
            == .send(thread: "ab12", message: "hi there", wait: true, timeout: 30, alternate: false))
        #expect(try parse(["send", "this", "-"], stdin: "from stdin").command
            == .send(thread: "this", message: "from stdin", wait: false, timeout: CLICommand.defaultTimeout, alternate: false))
        #expect(try parse(["send", "t", "--", "--literal", "words"]).command
            == .send(thread: "t", message: "--literal words", wait: false, timeout: CLICommand.defaultTimeout, alternate: false))
        #expect(try parse(["wait", "this", "--timeout", "0"]).command == .wait(thread: "this", timeout: 0))
        #expect(try parse(["read", "t", "--count", "2"]).command == .read(thread: "t", count: 2))
        #expect(try parse(["approve", "t", "--always", "--item", "12ab"]).command == .approve(thread: "t", item: "12ab", always: true))
        #expect(try parse(["deny", "t", "--message", "too risky"]).command == .deny(thread: "t", item: nil, message: "too risky"))
        #expect(try parse(["answer", "t", "--answer", "q1=yes", "--answer", "q1=a=b"]).command
            == .answer(thread: "t", item: nil, text: nil, answers: ["q1": ["yes", "a=b"]]))
        #expect(try parse(["answer", "t", "Use", "Postgres"]).command == .answer(thread: "t", item: nil, text: "Use Postgres", answers: [:]))
        #expect(try parse(["unarchive", "t"]).command == .archive(thread: "t", archived: false))
        #expect(try parse(["open", "t"]).command == .open(thread: "t"))
    }

    @Test func mistakesAreUsageErrors() {
        for line in [
            ["fly"], ["status"], ["status", "a", "b"], ["send", "t"], ["wait", "t", "--timeout", "-1"], ["read", "t", "--count", "0"],
            ["new", "--chat", "--project", "x"], ["new", "--access", "maybe"], ["new", "--wait"], ["answer", "t"],
            ["answer", "t", "--answer", "=x"], ["send", "t", "hi", "--bogus"], ["threads", "--project"],
        ] {
            #expect(throws: CLIUsageError.self, "\(line)") { try CLIParser.parse(line) { "" } }
        }
    }
}

/// The control socket end to end: a real Unix socket, the `coincide` client and its commands, against a temporary
/// store. Nothing here shows a window.
@MainActor
struct CommandLineControlTests {
    private struct Fixture {
        let folder: TemporaryDirectory
        let store: AppStore
        let adapter: RemoteStoreAdapter
        let project: Project
        let server: LocalControlServer
        var path: String { server.path }
    }

    private func fixture(_ name: String) throws -> Fixture {
        let folder = TemporaryDirectory(name)
        let store = AppStore(directory: folder.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let services = RemoteStoreAdapter.Services(
            pending: { [weak store] id in
                let items = store?.thread(id)?.items.filter { $0.status == .waiting } ?? []
                return (items.filter { $0.kind == .approval }.count, items.filter { $0.kind == .question }.count)
            }, unseen: { _ in nil }, markSeen: { _ in }, markUnread: { _ in }, isSettled: { _ in false },
            isHidden: { _ in false },
            archive: { [weak store] ids, archived in for id in ids { store?.updateThread(id) { $0.isArchived = archived } } },
            settle: { _, _ in }, delete: { _ in }, snooze: { _, _ in }, runScript: { _, _ in }, turnChanges: { _ in [:] },
            isPreparingWorktree: { _ in false }, importImage: { _, _ in nil }, diff: { _, _ in RemoteDiff(title: "None", files: []) },
            moveBlocker: { _ in nil }, move: { _, _ in }, layout: { .init() })
        let adapter = RemoteStoreAdapter(store: store, runner: runner, registry: registry, services: services)
        let project = store.addProject(at: try folder.folder("App"))
        // Socket paths are short; a test folder's would be too long.
        let path = "/tmp/coincide-test-\(UUID().uuidString.prefix(8)).sock"
        let server = LocalControlServer(path: path, adapter: adapter) { RemoteServerInfo(serverID: "s", name: "Mac", appVersion: "1") }
        try server.start()
        return Fixture(folder: folder, store: store, adapter: adapter, project: project, server: server)
    }

    /// Runs a command line as the tool would, off the main actor (the server answers on it), and returns its output.
    private func run(_ line: [String], at path: String, environment: [String: String] = [:]) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let invocation = try CLIParser.parse(line) { "" }
            let collected = Collected()
            var runner = CLIRunner(connection: try ControlClient(path: path, timeout: 10), environment: environment)
            runner.json = invocation.json
            runner.output = { collected.append($0) }
            runner.pollInterval = 0.05
            let status = try runner.run(invocation.command)
            return (status, collected.text)
        }.value
    }

    private nonisolated final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var text: String { lock.withLock { lines.joined(separator: "\n") } }
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func theSocketIsOwnerOnlyAndGoesAwayWhenStopped() throws {
        let fixture = try fixture("control-socket")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)
        fixture.server.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        #expect(throws: ControlError.self) { _ = try ControlClient(path: fixture.path) }
    }

    @Test func oversizedLinesCloseWithoutReachingTheSession() async throws {
        let fixture = try fixture("control-size")
        defer { fixture.server.stop() }
        let path = fixture.path
        let closed = await Task.detached {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { return false }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let payload = Data(repeating: 0x20, count: LocalControlServer.maxLineBytes + 1) + Data([0x0A])
            payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            var byte: UInt8 = 0
            return read(fd, &byte, 1) == 0
        }.value
        #expect(closed)
        // Another client still gets a response after the oversized connection was refused.
        #expect(try await run(["projects"], at: fixture.path).status == 0)
    }

    @Test func threadsAreStartedListedReadArchivedAndOpened() async throws {
        let fixture = try fixture("control-threads")
        defer { fixture.server.stop() }
        var opened: [UUID] = []
        fixture.server.onShowThread = { opened.append($0) }

        let projects = try await run(["projects", "--json"], at: fixture.path)
        #expect(projects.output.contains("\"name\":\"App\""))

        let started = try await run(["new", "--project", "App", "--title", "From the CLI", "--open", "--json"], at: fixture.path)
        #expect(started.status == 0)
        let raw = try #require(try json(started.output)["threadID"] as? String)
        let id = try #require(UUID(uuidString: raw))
        #expect(fixture.store.summary(id)?.title == "From the CLI")
        #expect(fixture.store.summary(id)?.projectID == fixture.project.id)
        #expect(opened == [id])

        let listed = try await run(["threads", "--project", "App"], at: fixture.path)
        #expect(listed.output.contains("From the CLI") && listed.output.contains(id.uuidString))

        // Replies of the latest turn; `this` is the calling thread.
        fixture.store.append(TranscriptItem(kind: .user, text: "Earlier question"), to: id)
        fixture.store.append(TranscriptItem(kind: .assistant, text: "Earlier answer"), to: id)
        fixture.store.append(TranscriptItem(kind: .user, text: "What changed?"), to: id)
        fixture.store.append(TranscriptItem(kind: .assistant, text: "The build is fixed."), to: id)
        let read = try await run(["read", "this"], at: fixture.path, environment: ["COINCIDE_THREAD_ID": id.uuidString])
        #expect(read.output == "The build is fixed.")
        let both = try await run(["read", String(id.uuidString.prefix(8)), "--count", "2", "--json"], at: fixture.path)
        #expect(try json(both.output)["replies"] as? [String] == ["Earlier answer", "The build is fixed."])
        #expect(try await run(["wait", id.uuidString, "--timeout", "2"], at: fixture.path).status == 0)

        _ = try await run(["archive", "From the CLI"], at: fixture.path)
        #expect(fixture.store.summary(id)?.isArchived == true)
        _ = try await run(["unarchive", id.uuidString], at: fixture.path)
        #expect(fixture.store.summary(id)?.isArchived == false)

        await #expect(throws: ControlError.self) { _ = try await run(["status", "No such thread"], at: fixture.path) }
        await #expect(throws: ControlError.self) { _ = try await run(["read", "this"], at: fixture.path) }
    }

    @Test func waitingApprovalsAreReportedAndAnswered() async throws {
        let fixture = try fixture("control-approvals")
        defer { fixture.server.stop() }
        let id = fixture.store.createThread(in: fixture.project.id).id
        var request = TranscriptItem(kind: .approval, title: "Run npm install", status: .waiting)
        request.approval = ApprovalInfo(requestID: "r1", options: [
            ApprovalOption(id: "yes", label: "Allow once", kind: .allowOnce), ApprovalOption(id: "no", label: "Deny", kind: .deny),
        ])
        let itemID = fixture.store.append(request, to: id)

        let status = try await run(["status", id.uuidString], at: fixture.path)
        #expect(status.output.contains("Waiting approval \(itemID.uuidString): Run npm install"))
        let waited = try await run(["wait", id.uuidString, "--json"], at: fixture.path)
        #expect(waited.status == CLIRunner.needsInput)
        #expect(try json(waited.output)["state"] as? String == "needsInput")
        let approved = try await run(["approve", id.uuidString], at: fixture.path)
        #expect(approved.output == "Approved: Allow once.")
        await #expect(throws: ControlError.self) { _ = try await run(["deny", id.uuidString, "--item", "ffff"], at: fixture.path) }
    }
}
