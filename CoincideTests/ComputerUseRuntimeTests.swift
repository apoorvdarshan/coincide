import CoincideKit
import Darwin
import Foundation
import Testing
@testable import Coincide

/// A stand-in for the bundled helper: the real process, stdio and socket lifecycle, without apps, screen capture or TCC.
@MainActor
struct FakeComputerUseDriver {
    let directory: TemporaryDirectory
    let executable: URL

    init() throws {
        directory = TemporaryDirectory("computer-use-driver")
        executable = try directory.file("driver", #"""
            #!/usr/bin/python3
            import json, os, signal, socket, stat, sys, time
            trace = __file__ + '.trace'
            def record(event, **fields):
                with open(trace, 'a') as f:
                    f.write(json.dumps(dict(event=event, pid=os.getpid(), **fields)) + '\n')
            path = sys.argv[sys.argv.index('--socket') + 1]
            if sys.argv[1] == 'serve':
                endpoint = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                endpoint.bind(path)
                endpoint.listen(8)
                record('serve', socket=path, embedded=os.environ.get('CUA_DRIVER_EMBEDDED'),
                       host=os.environ.get('CUA_DRIVER_HOST_BUNDLE_ID'),
                       mode=os.environ.get('CUA_DRIVER_PERMISSION_MODE'),
                       privateToken='CUA_DRIVER_RS_MCP_HTTP_TOKEN' in os.environ)
                while True:
                    peer, _ = endpoint.accept()
                    peer.close()
            else:
                peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                peer.connect(path)
                peer.close()
                record('proxy', socket=path)
                tools = [dict(name=name, inputSchema=dict(type='object', properties=dict(session=dict(type='string'))))
                         for name in ['start_session', 'end_session', 'list_windows', 'get_window_state', 'click',
                                      'set_agent_cursor_enabled', 'get_agent_cursor_state']]
                position = None
                for line in sys.stdin:
                    message = json.loads(line)
                    if 'id' not in message:
                        continue
                    method = message['method']
                    params = message.get('params', {})
                    if method == 'initialize':
                        result = dict(protocolVersion='2024-11-05', capabilities={}, serverInfo=dict(name='fake', version='0.38.0'))
                    elif method == 'tools/list':
                        result = dict(tools=tools)
                    else:
                        name = params['name']
                        arguments = params.get('arguments', {})
                        record('call', name=name, arguments=arguments)
                        if arguments.get('query') == 'hang':
                            continue
                        if arguments.get('query') == 'exit':
                            sys.exit(7)
                        if name == 'get_agent_cursor_state':
                            result = dict(structuredContent=dict(session=arguments.get('session'), position=position))
                        else:
                            if 'x' in arguments and 'y' in arguments:
                                position = dict(x=arguments['x'], y=arguments['y'])
                            result = dict(structuredContent=dict(name=name, session=arguments.get('session'), proxyPID=os.getpid()))
                    print(json.dumps(dict(jsonrpc='2.0', id=message['id'], result=result)), flush=True)
            """#)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    var events: [JSONValue] {
        guard let data = try? String(contentsOf: URL(fileURLWithPath: executable.path + ".trace"), encoding: .utf8) else { return [] }
        return data.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
    }

    func waitFor(_ predicate: ([JSONValue]) -> Bool) async throws {
        for _ in 0..<100 {
            if predicate(events) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The fake computer-use helper did not reach the expected lifecycle checkpoint.")
    }
}

/// Exercises the real process/stdio/socket lifecycle without opening apps, capturing the user's screen or asking TCC.
@MainActor
struct ComputerUseRuntimeTests {
    @Test func startupIsCoalescedAndTheSocketIsPrivate() async throws {
        let helper = try FakeComputerUseDriver()
        let runtime = ComputerUseRuntime(executable: helper.executable)
        defer { runtime.stop() }
        async let first: Void = runtime.start()
        async let second: Void = runtime.start()
        _ = try await (first, second)
        #expect(runtime.isRunning)
        let starts = helper.events.filter { $0["event"]?.string == "serve" }
        #expect(starts.count == 1)
        let start = try #require(starts.first)
        #expect(start["embedded"]?.string == "1")
        #expect(start["host"]?.string == "com.apoorvdarshan.coincide")
        #expect(start["mode"]?.string == "standard")
        #expect(start["privateToken"]?.bool == false)
        let socket = try #require(start["socket"]?.string)
        let socketMode = try FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? NSNumber
        let folderMode = try FileManager.default.attributesOfItem(atPath: (socket as NSString).deletingLastPathComponent)[.posixPermissions] as? NSNumber
        #expect(socketMode?.intValue == 0o600)
        #expect(folderMode?.intValue == 0o700)
        runtime.stop()
        #expect(!runtime.isRunning)
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    @Test func threadsHaveSeparateTransportsAndOwnedSessionLabels() async throws {
        let helper = try FakeComputerUseDriver()
        let runtime = ComputerUseRuntime(executable: helper.executable)
        defer { runtime.stop() }
        let a = UUID(), b = UUID()
        let tools = try await runtime.toolCatalog(threadID: a)
        #expect(tools.contains { $0["name"]?.string == "get_window_state" })
        let first = try await runtime.call(threadID: a, name: "list_windows", arguments: [:])
        let second = try await runtime.call(threadID: b, name: "list_windows", arguments: [:])
        #expect(first.at("structuredContent.session")?.string == "coincide-" + a.uuidString.lowercased())
        #expect(second.at("structuredContent.session")?.string == "coincide-" + b.uuidString.lowercased())
        #expect(first.at("structuredContent.proxyPID") != second.at("structuredContent.proxyPID"))
        runtime.end(threadID: a)
        let stillWorking = try await runtime.call(threadID: b, name: "list_windows", arguments: [:])
        #expect(stillWorking.at("structuredContent.proxyPID") == second.at("structuredContent.proxyPID"))
        try await helper.waitFor { $0.contains { $0["name"]?.string == "end_session" } }
    }

    @Test func coincideHidesTheDriversMainDisplayCursorAndReadsItsPosition() async throws {
        let helper = try FakeComputerUseDriver()
        let runtime = ComputerUseRuntime(executable: helper.executable)
        defer { runtime.stop() }
        let id = UUID()
        let session = "coincide-" + id.uuidString.lowercased()
        _ = try await runtime.toolCatalog(threadID: id)
        let hidden = try #require(helper.events.first { $0["name"]?.string == "set_agent_cursor_enabled" })
        #expect(hidden.at("arguments.enabled")?.bool == false)
        #expect(hidden.at("arguments.session")?.string == session)
        #expect(await runtime.cursorPosition(threadID: id) == nil)
        _ = try await runtime.call(threadID: id, name: "click", arguments: ["pid": 1, "x": 733, "y": -540])
        #expect(await runtime.cursorPosition(threadID: id) == CGPoint(x: 733, y: -540))
        #expect(await runtime.cursorPosition(threadID: UUID()) == nil)
        runtime.stop()
        #expect(await runtime.cursorPosition(threadID: id) == nil)
    }

    @Test func agentSessionAndTransportOverridesAreRejectedBeforeStarting() async throws {
        let helper = try FakeComputerUseDriver()
        let runtime = ComputerUseRuntime(executable: helper.executable)
        defer { runtime.stop() }
        let id = UUID()
        for arguments: JSONValue in [
            ["session": "somebody-else"], ["_session_id": "foreign"], ["permission_mode": "unrestricted"],
        ] {
            do {
                _ = try await runtime.call(threadID: id, name: "list_windows", arguments: arguments)
                Issue.record("An agent-controlled transport override was accepted.")
            } catch {}
        }
        #expect(!runtime.isRunning)
        #expect(helper.events.isEmpty)
    }

    @Test func stoppingFailsPendingCallsAndAProxyExitIsNeverReplayed() async throws {
        let helper = try FakeComputerUseDriver()
        let runtime = ComputerUseRuntime(executable: helper.executable, requestTimeout: 2)
        defer { runtime.stop() }
        let id = UUID()
        let pending = Task {
            try await runtime.call(threadID: id, name: "get_window_state", arguments: ["pid": 1, "window_id": 1, "query": "hang"])
        }
        try await helper.waitFor { $0.contains { $0.at("arguments.query")?.string == "hang" } }
        runtime.stop()
        do {
            _ = try await pending.value
            Issue.record("A stopped computer-use call returned a result.")
        } catch {}
        #expect(!runtime.isRunning)
        do {
            _ = try await runtime.call(threadID: id, name: "get_window_state", arguments: ["pid": 1, "window_id": 1, "query": "exit"])
            Issue.record("A helper that exited returned a successful call.")
        } catch {}
        #expect(helper.events.filter { $0.at("arguments.query")?.string == "exit" }.count == 1)
    }

    @Test func cancellationReleasesOnlyTheCallingThreadsConnection() async throws {
        let helper = try FakeComputerUseDriver()
        let runtime = ComputerUseRuntime(executable: helper.executable, requestTimeout: 2)
        defer { runtime.stop() }
        let id = UUID(), other = UUID()
        _ = try await runtime.call(threadID: other, name: "list_windows", arguments: [:])
        let pending = Task {
            try await runtime.call(threadID: id, name: "get_window_state", arguments: ["pid": 1, "window_id": 1, "query": "hang"])
        }
        try await helper.waitFor { $0.contains { $0.at("arguments.query")?.string == "hang" } }
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("A cancelled computer-use call returned a result.")
        } catch {}
        #expect(runtime.isRunning)
        let response = try await runtime.call(threadID: other, name: "list_windows", arguments: [:])
        #expect(response.at("structuredContent.session")?.string == "coincide-" + other.uuidString.lowercased())
    }
}
