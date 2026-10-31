import CoincideKit
import Foundation
import Testing
@testable import Coincide

/// Records where the controller would draw the agent cursor, instead of opening overlay windows.
@MainActor
final class RecordingAgentCursor: AgentCursorPresenting {
    private(set) var moves: [(point: CGPoint, pressed: Bool)] = []
    private(set) var hides = 0

    func move(to point: CGPoint, pressed: Bool) { moves.append((point, pressed)) }
    func hide() { hides += 1 }
}

/// The controller's switch, desktop lease and agent-facing shapes, against the fake helper. Nothing here opens a
/// window, captures the screen or asks macOS for a permission.
@MainActor
struct ComputerUseControllerTests {
    private let folder = TemporaryDirectory("computer-use-controller")
    private let driver: FakeComputerUseDriver
    private let cursor = RecordingAgentCursor()
    private let controller: ComputerUseController

    init() throws {
        driver = try FakeComputerUseDriver()
        let bridge = ComputerUseBridge(directory: folder.url.appendingPathComponent("bridge", isDirectory: true))
        controller = ComputerUseController(
            store: AppStore(directory: try folder.folder("data")), bridge: bridge,
            runtime: ComputerUseRuntime(executable: driver.executable, requestTimeout: 5), cursor: cursor)
        controller.accessibilityCheck = { true }
        controller.screenRecordingCheck = { false }
    }

    private func call(_ name: String, in id: UUID, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let access = try #require(controller.bridge.access(for: id))
        return try await controller.perform(.call(name: name, arguments: arguments), threadID: id, directory: access.directory)
    }

    @Test func offMeansNoInstructionsAndNoAccess() async throws {
        defer { controller.shutdown() }
        let id = UUID()
        #expect(!controller.enabled)
        #expect(controller.runtimeContext(for: id) == nil)
        do {
            _ = try await controller.perform(.status, threadID: id, directory: folder.url)
            Issue.record("Computer Use answered while it was off.")
        } catch {}
        #expect(driver.events.isEmpty)
    }

    @Test func turningOffRevokesEveryThreadsAccessAndStopsTheHelper() async throws {
        defer { controller.shutdown() }
        controller.enabled = true
        let id = UUID()
        let access = try await controller.enableAccess(for: id)
        let instructions = try #require(controller.runtimeContext(for: id))
        #expect(instructions.contains("<coincide_computer_use>"))
        #expect(instructions.contains(access.configuration.path))
        _ = try await call("list_windows", in: id)
        #expect(controller.activeThreads == [id])
        #expect(controller.runtime.isRunning)

        controller.enabled = false
        #expect(controller.bridge.access(for: id) == nil)
        #expect(controller.runtimeContext(for: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: access.configuration.path))
        #expect(!controller.runtime.isRunning)
        #expect(controller.activeThreads.isEmpty)
        do {
            _ = try await controller.perform(.call(name: "list_windows", arguments: [:]), threadID: id, directory: access.directory)
            Issue.record("A revoked thread kept Computer Use.")
        } catch {}
    }

    @Test func anotherThreadsInputWaitsForTheDesktopButReadingDoesNot() async throws {
        defer { controller.shutdown() }
        controller.enabled = true
        let a = UUID(), b = UUID()
        try await controller.enableAccess(for: a)
        try await controller.enableAccess(for: b)
        _ = try await call("click", in: a, ["pid": 1, "element_token": "x"])
        #expect(controller.desktopOwner == a)
        do {
            _ = try await call("click", in: b, ["pid": 1, "element_token": "y"])
            Issue.record("Two threads drove the desktop at once.")
        } catch let error as ComputerUseController.Failure {
            #expect(error == .desktopBusy)
        }
        let read = try await call("list_windows", in: b)
        #expect(read.at("structuredContent.name")?.string == "list_windows")
        #expect(driver.events.filter { $0["name"]?.string == "click" }.count == 1)

        let access = try #require(controller.bridge.access(for: a))
        _ = try await controller.perform(.release, threadID: a, directory: access.directory)
        #expect(controller.desktopOwner == nil)
        _ = try await call("click", in: b, ["pid": 1, "element_token": "y"])
        #expect(controller.desktopOwner == b)
    }

    @Test func theCursorFollowsActionsButNotReadsAndHidesWhenOff() async throws {
        defer { controller.shutdown() }
        controller.enabled = true
        let id = UUID()
        try await controller.enableAccess(for: id)
        _ = try await call("list_windows", in: id)
        #expect(cursor.moves.isEmpty)
        _ = try await call("click", in: id, ["pid": 1, "x": 733, "y": -540])
        #expect(cursor.moves.count == 1)
        #expect(cursor.moves.last?.point == CGPoint(x: 733, y: -540))
        #expect(cursor.moves.last?.pressed == true)

        let hides = cursor.hides
        controller.showsAgentCursor = false
        #expect(!controller.showsAgentCursor)
        #expect(cursor.hides > hides)
        _ = try await call("click", in: id, ["pid": 1, "x": 10, "y": 10])
        #expect(cursor.moves.count == 1)

        controller.showsAgentCursor = true
        _ = try await call("click", in: id, ["pid": 1, "x": 20, "y": 30])
        #expect(cursor.moves.last?.point == CGPoint(x: 20, y: 30))
        let beforeOff = cursor.hides
        controller.enabled = false
        #expect(cursor.hides > beforeOff)
    }

    @Test func withoutAccessibilityNothingReachesTheHelper() async throws {
        defer { controller.shutdown() }
        controller.accessibilityCheck = { false }
        controller.enabled = true
        let id = UUID()
        try await controller.enableAccess(for: id)
        do {
            _ = try await call("list_windows", in: id)
            Issue.record("A call ran without Accessibility access.")
        } catch let error as ComputerUseController.Failure {
            #expect(error == .accessibilityNeeded)
        }
        #expect(!controller.runtime.isRunning)
        #expect(controller.stateDescription == String(localized: "Waiting for Accessibility access"))
    }

    @Test func toolsHideTheSessionReservedOptionsAndToolsOutsideThePolicy() throws {
        let tool: JSONValue = [
            "name": "get_window_state", "description": "Reads a window.", "internal": "drop me",
            "inputSchema": [
                "type": "object",
                "properties": ["pid": ["type": "integer"], "session": ["type": "string"], "screenshot_out_file": ["type": "string"]],
                "required": ["pid", "session"],
            ],
        ]
        let shown = try #require(ComputerUseController.publicTool(tool))
        #expect(shown["internal"] == nil)
        #expect(shown.at("inputSchema.properties.pid") != nil)
        #expect(shown.at("inputSchema.properties.session") == nil)
        #expect(shown.at("inputSchema.properties.screenshot_out_file") == nil)
        #expect(shown.at("inputSchema.required") == ["pid"])
        for hidden in ["run_script", "page", "browser_navigate", "start_session", "set_config"] {
            #expect(ComputerUseController.publicTool(["name": .string(hidden), "inputSchema": ["type": "object"]]) == nil)
        }
    }

    @Test func screenshotsBecomePrivateFilesAndOldOnesAreRemoved() throws {
        let directory = try folder.folder("thread")
        let old = Date(timeIntervalSinceNow: -3600)
        for index in 0..<40 {
            let file = directory.appendingPathComponent("screenshot-old-\(index).png")
            FileManager.default.createFile(atPath: file.path, contents: Data([1]))
            try FileManager.default.setAttributes([.creationDate: old.addingTimeInterval(Double(index))], ofItemAtPath: file.path)
        }
        try Data("keep".utf8).write(to: directory.appendingPathComponent("computer-use.curl"))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let result: JSONValue = [
            "content": [
                ["type": "text", "text": "Window state"],
                ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"],
            ],
        ]
        let shown = ComputerUseController.publicResult(result, directory: directory)
        let items = try #require(shown["content"]?.array)
        #expect(items[0] == ["type": "text", "text": "Window state"])
        #expect(items[1]["data"] == nil)
        let path = try #require(items[1]["path"]?.string)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.filter { $0.hasPrefix("screenshot-") }.count == ComputerUseController.screenshotLimit)
        #expect(names.contains((path as NSString).lastPathComponent))
        #expect(names.contains("computer-use.curl"))
        #expect(!names.contains("screenshot-old-0.png"))
    }
}
