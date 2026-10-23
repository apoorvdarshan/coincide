import AppKit
import CoreGraphics
import Darwin
import SQLite3
import Vision
import XCTest

final class CoincideDesktopUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testRemoteWindowValidatesConnectionBeforeSSHAndPreservesLocalWorkspace() throws {
        let f = try prepareApplication(appearance: "light", diagnosticPrefix: "remote-connections")
        let app = f.app
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let initial = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            (snapshot["projects"] as? [Any])?.isEmpty == true && (snapshot["threads"] as? [Any])?.isEmpty == true
        }
        let original = try claudeGUIJSON(initial)
        app.menuBars.menuBarItems["Remote"].click()
        let menuItem = app.menuItems["Remote Workspaces…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5)); menuItem.click()
        let window = app.windows["Remote Workspaces"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Thread"].click()
        XCTAssertFalse(app.menuItems["Stop Turn"].isEnabled)
        XCTAssertTrue(app.menuItems["Resume Queue"].exists)
        XCTAssertTrue(app.menuItems["Toggle Inspector"].isEnabled, "The remote window owns its Files/Changes inspector control.")
        app.typeKey(.escape, modifierFlags: [])
        let add = window.buttons["remote-add-connection"]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.click()
        let target = app.textFields["remote-connection-target"]
        let port = app.textFields["remote-connection-port"]
        let directory = app.textFields["remote-connection-directory"]
        let inspect = app.buttons["remote-connection-inspect"]
        XCTAssertTrue(target.waitForExistence(timeout: 5)); XCTAssertFalse(inspect.isEnabled)
        target.click(); target.typeText("example.invalid")
        directory.click(); directory.typeText("/Users/remote/Coincide")
        port.click(); port.typeText("70000")
        XCTAssertTrue(inspect.isEnabled); inspect.click()
        let validation = app.staticTexts["remote-connection-error"]
        XCTAssertTrue(validation.waitForExistence(timeout: 5))
        let validationText = (validation.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? validation.label
        XCTAssertEqual(validationText, "Enter a port between 1 and 65535.")
        XCTAssertTrue(target.exists, "Invalid values must leave the form open without starting SSH.")
        port.click(); port.typeKey("a", modifierFlags: .command); port.typeKey(.delete, modifierFlags: [])
        target.click(); target.typeKey("a", modifierFlags: .command); target.typeText("-invalid-target")
        inspect.click()
        let invalidTarget = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (value CONTAINS %@ OR label CONTAINS %@)", "valid SSH alias", "valid SSH alias"), object: validation)
        XCTAssertEqual(XCTWaiter.wait(for: [invalidTarget], timeout: 5), .completed)
        XCTAssertTrue(target.exists)
        capture(app, name: "remote-connection-native-validation")
        app.buttons["remote-connection-cancel"].click()
        XCTAssertTrue(waitForAbsence(target, timeout: 5))
        window.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForAbsence(window, timeout: 5)); XCTAssertEqual(app.windows.count, 1)
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(try claudeGUIJSON(privateWorkspaceSnapshot(f.root)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("RemoteEnvironments/connections.json").path))
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testRemoteReviewedSettleScriptRequiresFullCommandApprovalAndStopDrainsOwnedJobs() throws {
        let f = try prepareApplication(appearance: "light", diagnosticPrefix: "remote-settle-script")
        let app = f.app, manager = FileManager.default
        let source = f.root.appendingPathComponent("Remote Script Source"), workspace = f.root.appendingPathComponent("Remote Script Worktree")
        try manager.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let command = """
        printf 'one\\n' >> remote-script-executions
        pwd -P > remote-script-cwd
        printf '%s\\n' "$$" > remote-script-pids
        /bin/sh -c 'trap "" HUP TERM; /bin/sleep 60 & child=$!; printf "%s\\n" "$$" "$child" >> remote-script-pids; wait' &
        printf 'remote-reviewed-output😀\\n'
        wait
        """ + "\n" + String(repeating: "# Immutable full-command Unicode audit 🌍\n", count: 250) + "# remote-command-tail-after-preview-boundary\n"
        XCTAssertGreaterThan(command.utf8.count, 8_192, "This workflow must hydrate the referenced command, beyond its preview.")
        let script = ["name": "Reviewed Remote Cleanup", "command": command, "runOnSettle": true, "async": false] as [String: Any]
        let config = source.appendingPathComponent("t3.json"), readme = source.appendingPathComponent("README.md")
        let configuration = try JSONSerialization.data(withJSONObject: ["scripts": [script]], options: [.sortedKeys, .prettyPrinted])
        let readmeBytes = Data("Private remote settle source stays untouched.\n".utf8)
        try configuration.write(to: config); try readmeBytes.write(to: readme)
        for arguments in [["init", "--initial-branch", "main"], ["add", "t3.json", "README.md"], ["commit", "--message", "Private remote settle fixture"],
                          ["worktree", "add", "-b", "ui-remote-reviewed-cleanup", workspace.path, "main"]] {
            _ = try runGit(["-C", source.path] + arguments, gitPath: f.gitPath, configuration: f.configuration, name: "remote-settle-" + arguments[0])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        let head = try verifyHead(gitPath: f.gitPath, project: source, configuration: f.configuration, name: "remote-settle-source-head")
        let headBytes = try Data(contentsOf: source.appendingPathComponent(".git/HEAD"))
        app.launchEnvironment["COINCIDE_UI_TEST_REMOTE_SCRIPT"] = "1"
        app.launchEnvironment["PATH"] = URL(fileURLWithPath: f.gitPath).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let draft = "Unsent remote draft stays literal through reviewed cleanup and Stop 🌍"
        let seeded = try seedRemoteScriptUIFixture(f.root, source: source, workspace: workspace, draft: draft, app: app)
        let threadID = try XCTUnwrap(seeded["threadID"] as? String)
        let remoteRoot = f.root.appendingPathComponent("coincide-ui-testing-remote-script-host")
        let original = try claudeGUIThread(privateWorkspaceSnapshot(remoteRoot), id: threadID)
        let originalMessages = try claudeGUIJSON(original["messages"]), originalHistory = try claudeGUIJSON(original["runHistory"])
        let expectedWorkspace = try XCTUnwrap(seeded["workspacePath"] as? String)
        let executions = workspace.appendingPathComponent("remote-script-executions"), pidFile = workspace.appendingPathComponent("remote-script-pids")
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let localLoaded = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            (snapshot["projects"] as? [Any])?.isEmpty == true && (snapshot["threads"] as? [Any])?.isEmpty == true
        }
        let localBefore = try claudeGUIJSON(localLoaded)
        app.menuBars.menuBarItems["Remote"].click(); app.menuItems["Remote Workspaces…"].click()
        let window = app.windows["Remote Workspaces"]
        XCTAssertTrue(window.waitForExistence(timeout: 10)); window.buttons["remote-add-connection"].click()
        for (identifier, value) in [("remote-connection-name", "Private Native Script Host"), ("remote-connection-target", "coincide-ui-script"),
                                    ("remote-connection-helper", "/coincide-ui-testing/CoincideEnvironment"),
                                    ("remote-connection-directory", "/coincide-ui-testing/RemoteScriptData")] {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(value)
        }
        app.buttons["remote-connection-inspect"].click()
        let trust = window.buttons["Trust and Connect"]
        XCTAssertTrue(trust.waitForExistence(timeout: 10)); trust.click()
        let row = window.buttons["remote-thread-" + threadID]
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.click()
        let composer = window.textViews["Remote message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        let settle = window.buttons["remote-lifecycle-settle"]
        XCTAssertTrue(settle.waitForExistence(timeout: 10)); XCTAssertTrue(settle.isEnabled && settle.isHittable); settle.click()
        let confirm = app.buttons["Settle and Review Script"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
        let reviewButton = window.buttons["remote-settle-script-review"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 15))
        XCTAssertFalse(manager.fileExists(atPath: executions.path), "Normal Settle and discovery must not execute the repository command.")
        reviewButton.click()
        let review = app.sheets.containing(.button, identifier: "remote-settle-script-approve").element
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        let fullCommand = review.textViews["remote-settle-script-review-command"]
        XCTAssertTrue(fullCommand.waitForExistence(timeout: 5))
        let commandValue = (fullCommand.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fullCommand.label
        XCTAssertEqual(commandValue, command, "The native review must contain the complete verified command, including its omitted preview tail.")
        for value in ["/bin/sh", expectedWorkspace] {
            XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", value, value)).element.exists)
        }
        let approve = review.buttons["remote-settle-script-approve"]
        XCTAssertTrue(approve.isEnabled && approve.isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "remote-settle-full-command-native-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click(); XCTAssertTrue(waitForAbsence(review, timeout: 5))
        XCTAssertFalse(manager.fileExists(atPath: executions.path), "Cancelling full-command review must not authorize execution.")
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        reviewButton.click(); XCTAssertTrue(review.waitForExistence(timeout: 10)); approve.click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        _ = try waitForPrivateWorkspace(remoteRoot, timeout: 15) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID),
                  let settlement = thread["settlement"] as? [String: Any], let script = settlement["script"] as? [String: Any] else { return false }
            return script["phase"] as? String == "running"
        }
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return false }
            let pids = text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
            return pids.count == 3 && Set(pids).count == 3 && pids.allSatisfy { $0 > 1 && Darwin.kill($0, 0) == 0 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed, "The exact leader, child and grandchild must be alive before Stop.")
        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 3)
        XCTAssertEqual(try String(contentsOf: executions, encoding: .utf8), "one\n")
        let disclosure = window.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (identifier == %@ OR label == %@ OR title == %@)",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.disclosureTriangle.rawValue,
            "remote-settle-script-output-disclosure", "Settle Script Output", "Settle Script Output")).element
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5)); expandScriptOutputDisclosure(disclosure)
        let output = window.staticTexts["remote-settle-script-output"]
        let actualOutput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (value CONTAINS %@ OR label CONTAINS %@)", "remote-reviewed-output😀", "remote-reviewed-output😀"), object: output)
        XCTAssertEqual(XCTWaiter.wait(for: [actualOutput], timeout: 10), .completed)
        let stop = window.buttons["remote-settle-script-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); XCTAssertTrue(stop.isEnabled && stop.isHittable); stop.click()
        let drained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [drained], timeout: 10), .completed, "Stop must drain this fixture's recorded process tree.")
        let after = try waitForPrivateWorkspace(remoteRoot, timeout: 10) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID),
                  let settlement = thread["settlement"] as? [String: Any], let script = settlement["script"] as? [String: Any] else { return false }
            return settlement["phase"] as? String == "settled" && script["phase"] as? String == "cancelled"
        }
        let thread = try claudeGUIThread(after, id: threadID)
        XCTAssertEqual(try claudeGUIJSON(thread["messages"]), originalMessages); XCTAssertEqual(try claudeGUIJSON(thread["runHistory"]), originalHistory)
        XCTAssertEqual(thread["draft"] as? String, draft); XCTAssertEqual(thread["workspacePath"] as? String, expectedWorkspace)
        XCTAssertNil(thread["activeRun"]); XCTAssertTrue((thread["queuedTurns"] as? [Any])?.isEmpty == true)
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        XCTAssertEqual(try String(contentsOf: executions, encoding: .utf8), "one\n", "Metadata/output refresh and Stop must not repeat execution.")
        let scriptCWD = try String(contentsOf: workspace.appendingPathComponent("remote-script-cwd"), encoding: .utf8).trimmingCharacters(in: .newlines)
        let observedNode = try manager.attributesOfItem(atPath: scriptCWD), expectedNode = try manager.attributesOfItem(atPath: workspace.path)
        XCTAssertEqual(observedNode[.systemNumber] as? NSNumber, expectedNode[.systemNumber] as? NSNumber)
        XCTAssertEqual(observedNode[.systemFileNumber] as? NSNumber, expectedNode[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try Data(contentsOf: readme), readmeBytes); XCTAssertEqual(try Data(contentsOf: config), configuration)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".git/HEAD")), headBytes)
        XCTAssertEqual(try verifyHead(gitPath: f.gitPath, project: source, configuration: f.configuration, name: "remote-settle-source-final-head"), head)
        XCTAssertEqual(try verifyHead(gitPath: f.gitPath, project: workspace, configuration: f.configuration, name: "remote-settle-worktree-final-head"), head)
        XCTAssertFalse(manager.fileExists(atPath: source.appendingPathComponent("remote-script-executions").path))
        XCTAssertEqual(try claudeGUIJSON(privateWorkspaceSnapshot(f.root)), localBefore)
        let image = XCTAttachment(screenshot: window.screenshot()); image.name = "remote-settle-stopped-with-output-and-preserved-draft"; image.lifetime = .keepAlways; add(image)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        XCTAssertTrue(pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
    }

    @MainActor private func seedRemoteScriptUIFixture(_ root: URL, source: URL, workspace: URL, draft: String, app: XCUIApplication) throws -> [String: Any] {
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        let appPath = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_APP_PATH"])
        let helper = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Helpers/CoincideEnvironment")
        let peer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "remote_script_seed_ui", withExtension: "py"))
        let process = Process(), output = Pipe(), errors = Pipe(), exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-S", peer.path, root.path, helper.path, source.path, workspace.path, draft]
        process.environment = app.launchEnvironment; process.currentDirectoryURL = root
        process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let completed = exited.wait(timeout: .now() + 45) == .success
        if !completed { process.terminate(); if exited.wait(timeout: .now() + 5) != .success { Darwin.kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 5) } }
        let bytes = output.fileHandleForReading.readDataToEndOfFile(), diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        let evidence = XCTAttachment(string: "Private native-helper seed completed=\(completed) exit=\(process.terminationStatus)\n" + String(decoding: diagnostic.prefix(2_048), as: UTF8.self))
        evidence.name = "remote-script-native-seed-lifecycle"; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertTrue(completed); XCTAssertEqual(process.terminationStatus, 0)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(value["hostExit"] as? Int, 0)
        return value
    }

    @MainActor func testNativeMainWindowCloseNewWindowAndReopenPreserveUnsentWorkspace() throws {
        let f = try prepareApplication(appearance: "light", diagnosticPrefix: "main-window")
        let app = f.app, root = f.root, manager = FileManager.default
        let appPath = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_APP_PATH"])
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        let project = root.appendingPathComponent("Window Workspace"), bin = root.appendingPathComponent("private-bin")
        let home = root.appendingPathComponent("private-codex-home")
        for directory in [project, bin, home] { try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let file = project.appendingPathComponent("README.md"), bytes = Data("Window recovery preserves workspace bytes.\n".utf8)
        try bytes.write(to: file)
        let state = root.appendingPathComponent("window-metadata.json"), wire = root.appendingPathComponent("window-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "generation": 1]).write(to: state, options: .atomic)
        let peer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "codex_models_ui", withExtension: "py"))
        let executable = try installOfflineCLI(tool: "codex", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"; app.launchEnvironment["CODEX_HOME"] = home.path
        try preflightOfflineHistoryProvider(executable, cwd: project, environment: app.launchEnvironment, name: "main-window")
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app); app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"], draft = "Unsent draft across native main window recovery"
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.click(); composer.typeText(draft)
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        let threadID = try selectedThreadIdentifier(in: app)
        let saved = try waitForPrivateWorkspace(root, timeout: 5) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID) else { return false }
            return thread["draft"] as? String == draft && (thread["messages"] as? [Any])?.isEmpty == true
        }
        let savedThreads = try claudeGUIJSON(saved["threads"])
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apoorvdarshan.coincide.uitesting")
            .filter { $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: appPath).standardizedFileURL.path }
        XCTAssertEqual(running.count, 1)
        let pid = try XCTUnwrap(running.first?.processIdentifier)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForAbsence(app.windows.firstMatch, timeout: 10))
        XCTAssertNotEqual(app.state, .notRunning)
        app.menuBars.menuBarItems["File"].click()
        let newWindow = app.menuItems["New Window"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5)); XCTAssertTrue(newWindow.isEnabled); newWindow.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10)); XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try claudeGUIJSON(privateWorkspaceSnapshot(root)["threads"]), savedThreads)
        capture(app, name: "main-window-new-window-retains-draft")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForAbsence(app.windows.firstMatch, timeout: 10))
        let opened = XCTestExpectation(description: "The exact running disposable app receives native reopen")
        let options = NSWorkspace.OpenConfiguration(); options.activates = true; options.createsNewApplicationInstance = false
        options.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: options) { running, error in
            XCTAssertNil(error); XCTAssertEqual(running?.processIdentifier, pid)
            XCTAssertEqual(running?.bundleURL?.standardizedFileURL.path, URL(fileURLWithPath: appPath).standardizedFileURL.path)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 10), .completed)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10)); XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try claudeGUIJSON(privateWorkspaceSnapshot(root)["threads"]), savedThreads)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let allowed: Set<String> = ["initialize", "model/list", "config/read", "account/read", "account/rateLimits/read"]
        XCTAssertTrue(try historyWire(wire).allSatisfy { allowed.contains($0["method"] as? String ?? "") })
        capture(app, name: "main-window-native-reopen-retains-draft")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testLightCodexSkillsKeyboardInsertionRefreshAndUnsentDraftRestoration() throws {
        try exerciseCodexSkills(appearance: "light")
    }

    @MainActor func testDarkCodexSkillsKeyboardInsertionRefreshAndUnsentDraftRestoration() throws {
        try exerciseCodexSkills(appearance: "dark")
    }

    @MainActor private func exerciseCodexSkills(appearance: String) throws {
        let prefix = "codex-skills-" + appearance
        let fixture = try prepareApplication(appearance: appearance, diagnosticPrefix: prefix)
        let app = fixture.app, root = fixture.root
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        XCTAssertTrue(python.hasPrefix("/") && python != "/usr/bin/python3" && FileManager.default.isExecutableFile(atPath: python))
        let project = root.appendingPathComponent("Skills Workspace", isDirectory: true)
        let bin = root.appendingPathComponent("private-bin", isDirectory: true)
        let home = root.appendingPathComponent("private-codex-home", isDirectory: true)
        for directory in [project, bin, home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let document = project.appendingPathComponent("README.md"), original = Data("Skill selection must preserve this working file.\n".utf8)
        try original.write(to: document)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Native skills fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: prefix + "-git-" + arguments[0])
        }
        let originalHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: prefix + "-original-head")
        let state = root.appendingPathComponent("skills-peer.json"), wire = root.appendingPathComponent("skills-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "generation": 1, "skillsUI": true]).write(to: state, options: .atomic)
        let peer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "codex_models_ui", withExtension: "py"))
        let executable = try installOfflineCLI(tool: "codex", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"; app.launchEnvironment["CODEX_HOME"] = home.path
        try preflightOfflineHistoryProvider(executable, cwd: project, environment: app.launchEnvironment, name: prefix)
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app); app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let threadID = try selectedThreadIdentifier(in: app)
        var ownedClipboardValues = Set<String>()
        defer { if let value = NSPasteboard.general.string(forType: .string), ownedClipboardValues.contains(value) { NSPasteboard.general.clearContents() } }
        func replaceDraft(_ value: String) {
            ownedClipboardValues.insert(value)
            NSPasteboard.general.clearContents(); XCTAssertTrue(NSPasteboard.general.setString(value, forType: .string))
            composer.click(); composer.typeKey("a", modifierFlags: .command); composer.typeKey("v", modifierFlags: .command)
            XCTAssertTrue(waitForValue(composer, value: value, timeout: 5))
        }
        let typed = "Preserve this Unicode draft 😀 $rev"
        replaceDraft(typed)
        let review = app.buttons["composer-skill-review-changes"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); XCTAssertTrue(review.isEnabled && review.isHittable)
        XCTAssertFalse(app.buttons["composer-skill-disabled-skill"].exists)
        XCTAssertFalse(app.buttons["composer-skill-7k"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer-skills-partial").firstMatch.exists)
        XCTAssertFalse(app.debugDescription.contains("PRIVATE_SKILL_DIAGNOSTIC_CANARY"))
        capture(app, name: prefix + "-typed-picker-native-appearance")
        composer.typeKey(.downArrow, modifierFlags: []); composer.typeKey(.return, modifierFlags: [])
        let inserted = "Preserve this Unicode draft 😀 $review-changes "
        XCTAssertTrue(waitForValue(composer, value: inserted, timeout: 5))
        XCTAssertTrue(waitForAbsence(review, timeout: 5), "Return inserts the selected literal mention and closes the chooser.")
        _ = try waitForPrivateWorkspace(root, timeout: 5) { snapshot in
            guard let threads = snapshot["threads"] as? [[String: Any]], threads.count == 1 else { return false }
            return threads[0]["draft"] as? String == inserted && (threads[0]["messages"] as? [[String: Any]])?.isEmpty == true
        }

        let dismissed = "Keep this unsent selection $shi"
        replaceDraft(dismissed)
        let ship = app.buttons["composer-skill-ship-check"]
        XCTAssertTrue(ship.waitForExistence(timeout: 5)); composer.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForAbsence(ship, timeout: 5)); XCTAssertTrue(waitForValue(composer, value: dismissed, timeout: 5))
        replaceDraft("Keep a second draft: ")
        let choose = app.buttons["composer-skills"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); XCTAssertTrue(choose.isEnabled); choose.click()
        let search = app.textFields["composer-skills-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.click(); search.typeText("ship")
        XCTAssertTrue(ship.waitForExistence(timeout: 5)); search.typeKey(.return, modifierFlags: [])
        let manual = "Keep a second draft: $ship-check "
        XCTAssertTrue(waitForValue(composer, value: manual, timeout: 5)); XCTAssertTrue(waitForAbsence(search, timeout: 5))

        choose.click(); XCTAssertTrue(search.waitForExistence(timeout: 5))
        let fresh = app.buttons["composer-skill-fresh-check"]
        XCTAssertFalse(fresh.exists)
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "generation": 2, "skillsUI": true]).write(to: state, options: .atomic)
        let refresh = app.buttons["composer-skills-refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); XCTAssertTrue(refresh.isEnabled); refresh.click()
        XCTAssertTrue(fresh.waitForExistence(timeout: 10)); XCTAssertTrue(fresh.isHittable)
        XCTAssertFalse(app.buttons["composer-skill-disabled-skill"].exists)
        capture(app, name: prefix + "-explicit-native-refresh")
        fresh.click()
        let finalDraft = manual + "$fresh-check "
        XCTAssertTrue(waitForValue(composer, value: finalDraft, timeout: 5))
        let saved = try waitForPrivateWorkspace(root, timeout: 5) { snapshot in
            guard let thread = (snapshot["threads"] as? [[String: Any]])?.first else { return false }
            return thread["draft"] as? String == finalDraft && (thread["messages"] as? [[String: Any]])?.isEmpty == true
        }
        let savedThreads = try JSONSerialization.data(withJSONObject: XCTUnwrap(saved["threads"]), options: .sortedKeys)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: finalDraft, timeout: 10)); XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(privateWorkspaceSnapshot(root)["threads"]), options: .sortedKeys), savedThreads)
        let frames = try historyWire(wire), skills = frames.filter { $0["method"] as? String == "skills/list" }
        let allowed: Set<String> = ["initialize", "model/list", "config/read", "account/read", "account/rateLimits/read", "skills/list"]
        XCTAssertTrue(frames.allSatisfy { allowed.contains($0["method"] as? String ?? "") }, "Skill selection must never send input or create/resume a provider thread.")
        XCTAssertEqual(skills.count, 2, "Typing and reopening cached suggestions reuse the scoped inventory; only explicit refresh reads again.")
        for (index, frame) in skills.enumerated() {
            let params = try XCTUnwrap(frame["params"] as? [String: Any])
            XCTAssertEqual(Set(params.keys), ["cwds", "forceReload"])
            XCTAssertEqual(params["cwds"] as? [String], [project.path]); XCTAssertEqual(params["forceReload"] as? Bool, index == 1)
        }
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: prefix + "-preserved-head"), originalHead)
        capture(app, name: prefix + "-restored-unsent-draft")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testLightCodexOwnedAuthenticationSettingsPreserveUnsentConversation() throws {
        try exerciseCodexAuthenticationSettings(appearance: "light")
    }

    @MainActor func testDarkCodexOwnedAuthenticationSettingsPreserveUnsentConversation() throws {
        try exerciseCodexAuthenticationSettings(appearance: "dark")
    }

    @MainActor private func exerciseCodexAuthenticationSettings(appearance: String) throws {
        let prefix = "codex-auth-" + appearance
        let fixture = try prepareApplication(appearance: appearance, diagnosticPrefix: prefix)
        let app = fixture.app, root = fixture.root
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        XCTAssertTrue(python.hasPrefix("/") && python != "/usr/bin/python3" && FileManager.default.isExecutableFile(atPath: python))
        let project = root.appendingPathComponent("Authentication Workspace", isDirectory: true)
        let bin = root.appendingPathComponent("private-bin", isDirectory: true)
        let cliHome = root.appendingPathComponent("private-cli-home", isDirectory: true)
        let sharedHome = root.appendingPathComponent("explicit-shared-home", isDirectory: true)
        for directory in [project, bin, cliHome, sharedHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let document = project.appendingPathComponent("README.md"), original = Data("Preserve the existing conversation and working files.\n".utf8)
        try original.write(to: document)
        let cliSentinel = cliHome.appendingPathComponent("existing-cli-sentinel"), sharedSentinel = sharedHome.appendingPathComponent("shared-home-sentinel")
        try Data("Synthetic existing CLI state.\n".utf8).write(to: cliSentinel)
        try Data("Synthetic shared history state.\n".utf8).write(to: sharedSentinel)
        let cliBytes = try Data(contentsOf: cliSentinel), sharedBytes = try Data(contentsOf: sharedSentinel)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Native authentication fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: prefix + "-git-" + arguments[0])
        }
        let originalHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: prefix + "-original-head")
        let state = root.appendingPathComponent("auth-metadata-peer.json"), wire = root.appendingPathComponent("auth-metadata-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "generation": 1]).write(to: state, options: .atomic)
        let peer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "codex_models_ui", withExtension: "py"))
        let executable = try installOfflineCLI(tool: "codex", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        app.launchEnvironment["CODEX_HOME"] = cliHome.path
        try preflightOfflineHistoryProvider(executable, cwd: project, environment: app.launchEnvironment, name: prefix)
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app); app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let threadID = try selectedThreadIdentifier(in: app), draft = "Preserve this unsent draft while explicitly choosing ChatGPT authentication."
        composer.click(); composer.typeText(draft); XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        let before = try waitForPrivateWorkspace(root, timeout: 5) { snapshot in
            guard let threads = snapshot["threads"] as? [[String: Any]], threads.count == 1 else { return false }
            return threads[0]["draft"] as? String == draft
        }
        let originalThreads = try JSONSerialization.data(withJSONObject: XCTUnwrap(before["threads"]), options: .sortedKeys)

        app.typeKey(",", modifierFlags: .command)
        var settings = app.windows.containing(.any, identifier: "codex-authentication-mode").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let picker = settings.descendants(matching: .any).matching(identifier: "codex-authentication-mode").firstMatch
        revealAuthenticationControl(picker, in: settings)
        picker.click()
        let ownedChoice = app.menuItems["ChatGPT through Coincide"]
        XCTAssertTrue(ownedChoice.waitForExistence(timeout: 5)); ownedChoice.click()
        let home = settings.textFields["codex-authentication-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5)); revealAuthenticationControl(home, in: settings)
        let apply = settings.buttons["codex-authentication-apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5)); XCTAssertFalse(apply.isEnabled, "Owned mode requires an explicit shared home before it can be saved.")
        XCTAssertFalse(settings.buttons["codex-authentication-sign-in"].exists, "Editing an unsaved mode must not initiate or expose an active account flow.")
        home.click(); home.typeKey("a", modifierFlags: .command); home.typeText(sharedHome.path)
        XCTAssertTrue(waitForValue(home, value: sharedHome.path, timeout: 5))
        revealAuthenticationControl(apply, in: settings); XCTAssertTrue(apply.isEnabled); apply.click()
        let saved = try waitForCodexAuthenticationPreference(root, mode: "ownedChatGPT", home: sharedHome.path)
        XCTAssertEqual(saved["selection"] as? String, "existingCLI"); XCTAssertEqual(saved["executable"] as? String, "codex")
        XCTAssertNil(saved["accountBinding"], "Choosing owned authentication must never fabricate a signed-in account.")
        try assertUnsignedOwnedAuthenticationControls(in: settings, name: prefix + "-explicit-owned-mode")
        settings.typeKey("w", modifierFlags: .command); XCTAssertTrue(waitForAbsence(settings, timeout: 5))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(privateWorkspaceSnapshot(root)["threads"]), options: .sortedKeys), originalThreads)
        let beforeRestart = try JSONSerialization.data(withJSONObject: historyWire(wire), options: .sortedKeys)

        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        app.typeKey(",", modifierFlags: .command)
        settings = app.windows.containing(.any, identifier: "codex-authentication-mode").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let restoredHome = settings.textFields["codex-authentication-home"]
        XCTAssertTrue(restoredHome.waitForExistence(timeout: 5)); XCTAssertEqual(restoredHome.value as? String, sharedHome.path)
        try assertUnsignedOwnedAuthenticationControls(in: settings, name: prefix + "-reopened-owned-mode")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: historyWire(wire), options: .sortedKeys), beforeRestart,
                       "Reopening saved owned mode must not launch a CLI probe, sign in, read saved credentials or submit input.")

        let restoredPicker = settings.descendants(matching: .any).matching(identifier: "codex-authentication-mode").firstMatch
        revealAuthenticationControl(restoredPicker, in: settings); restoredPicker.click()
        let cliChoice = app.menuItems["Existing CLI account"]
        XCTAssertTrue(cliChoice.waitForExistence(timeout: 5)); cliChoice.click()
        let restore = settings.buttons["codex-authentication-apply"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5)); revealAuthenticationControl(restore, in: settings)
        XCTAssertTrue(restore.isEnabled); restore.click()
        let restored = try waitForCodexAuthenticationPreference(root, mode: "cliDefault", home: sharedHome.path)
        XCTAssertNil(restored["accountBinding"])
        XCTAssertTrue(waitForAbsence(settings.buttons["codex-authentication-sign-in"], timeout: 5))
        XCTAssertFalse(settings.buttons["codex-authentication-open-browser"].exists)
        settings.typeKey("w", modifierFlags: .command); XCTAssertTrue(waitForAbsence(settings, timeout: 5))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5)); XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(privateWorkspaceSnapshot(root)["threads"]), options: .sortedKeys), originalThreads,
                       "Global authentication preferences must not retarget, recapture, enqueue or rewrite an existing conversation.")
        let frames = try historyWire(wire), allowed: Set<String> = ["initialize", "account/read", "account/rateLimits/read"]
        XCTAssertTrue(frames.allSatisfy { allowed.contains($0["method"] as? String ?? "") }, "Only closed-world read-only CLI metadata is allowed; no native turn, auth or configuration mutation may occur.")
        for frame in frames where frame["method"] as? String == "account/read" {
            let params = try XCTUnwrap(frame["params"] as? [String: Any])
            XCTAssertEqual(Set(params.keys), ["refreshToken"]); XCTAssertEqual(params["refreshToken"] as? Bool, false)
        }
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertEqual(try Data(contentsOf: cliSentinel), cliBytes); XCTAssertEqual(try Data(contentsOf: sharedSentinel), sharedBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sharedHome.path), [sharedSentinel.lastPathComponent], "Saving a mode must not initialize, migrate or overwrite the selected shared home.")
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: prefix + "-preserved-head"), originalHead)
        capture(app, name: prefix + "-cli-restored-conversation-and-draft")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func revealAuthenticationControl(_ control: XCUIElement, in settings: XCUIElement) {
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        let area = settings.scrollViews.firstMatch, scroll = area.exists ? area : settings
        if control.isHittable && scroll.frame.contains(control.frame) { return }
        scroll.scroll(byDeltaX: 0, deltaY: 1_200)
        for _ in 0..<8 {
            if control.isHittable && scroll.frame.contains(control.frame) { break }
            scroll.scroll(byDeltaX: 0, deltaY: -150)
        }
        XCTAssertTrue(control.isEnabled && control.isHittable && scroll.frame.contains(control.frame),
                      "The semantic account control must fit and remain reachable in the native Settings form: \(control.identifier).")
    }

    @MainActor private func assertUnsignedOwnedAuthenticationControls(in settings: XCUIElement, name: String) throws {
        let status = settings.descendants(matching: .any).matching(identifier: "codex-authentication-status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let unsigned = "Sign in or refresh the saved ChatGPT accounts."
        let currentStatus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", unsigned, unsigned), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [currentStatus], timeout: 5), .completed)
        let signIn = settings.buttons["codex-authentication-sign-in"], refresh = settings.buttons["codex-authentication-refresh"]
        revealAuthenticationControl(signIn, in: settings); revealAuthenticationControl(refresh, in: settings)
        XCTAssertTrue(signIn.isEnabled && refresh.isEnabled)
        let usage = settings.descendants(matching: .any).matching(identifier: "codex-authentication-usage-unsupported").firstMatch
        XCTAssertTrue(usage.exists)
        XCTAssertFalse(settings.buttons["codex-authentication-open-browser"].exists)
        XCTAssertFalse(settings.buttons["codex-authentication-cancel"].exists)
        XCTAssertFalse(settings.descendants(matching: .any).matching(identifier: "codex-authentication-reveal-email").firstMatch.exists)
        XCTAssertFalse(settings.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex-authentication-sign-out-")).firstMatch.exists)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(settings.frame))
        let screenshot = XCTAttachment(screenshot: settings.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: settings.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
        // Deliberately do not activate Sign In or Refresh Saved Accounts: these
        // are real auth/storage actions, outside this offline Settings scenario.
    }

    @MainActor private func waitForCodexAuthenticationPreference(_ root: URL, mode: String, home: String) throws -> [String: Any] {
        let path = root.appendingPathComponent("CodexSettings/runtime.json")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let bytes = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            return value["authenticationMode"] as? String == mode && value["homeDirectory"] as? String == home
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Only the explicit Apply action may save the selected account mode and shared home.")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    }

    @MainActor func testNativeModelReasoningMenusResolveAdvertisedAndCLIDefaultsWithoutSending() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "models")
        let app = fixture.app, root = fixture.root
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        XCTAssertTrue(python.hasPrefix("/") && python != "/usr/bin/python3" && FileManager.default.isExecutableFile(atPath: python))
        let project = root.appendingPathComponent("Native Models", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let document = project.appendingPathComponent("README.md"), original = Data("Model selection must leave files unchanged\n".utf8)
        try original.write(to: document)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Native model fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "models-git-\(arguments[0])")
        }
        let originalHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "models-original-head")
        let state = root.appendingPathComponent("models-peer.json"), wire = root.appendingPathComponent("models-peer-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "generation": 1]).write(to: state, options: .atomic)
        let bundled = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "codex_models_ui", withExtension: "py"))
        let peer = bundled
        let bin = root.appendingPathComponent("private-bin", isDirectory: true), home = root.appendingPathComponent("private-codex-home", isDirectory: true)
        for directory in [bin, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let executable = try installOfflineCLI(tool: "codex", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"; app.launchEnvironment["CODEX_HOME"] = home.path
        addTeardownBlock { @MainActor [weak self] in
            if let data = try? Data(contentsOf: wire), let text = String(data: data, encoding: .utf8) {
                let audit = XCTAttachment(string: text); audit.name = "models-offline-metadata-wire"; audit.lifetime = .keepAlways; self?.add(audit)
            }
        }
        try preflightOfflineHistoryProvider(executable, cwd: project, environment: app.launchEnvironment, name: "models")
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app); app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let threadID = try selectedThreadIdentifier(in: app), draft = "Keep this unsent discussion while choosing model reasoning"
        composer.click(); composer.typeText(draft); XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        openNativeProviderMenu(in: app)
        let refresh = app.menuItems["Refresh Models"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); XCTAssertTrue(refresh.isEnabled); refresh.click()
        try chooseNativeProviderModel("gpt-6-astra", in: app)
        _ = try waitForNativeModel(root, model: "gpt-6-astra", effort: "medium")
        try chooseNativeReasoning("high", in: app)
        _ = try waitForNativeModel(root, model: "gpt-6-astra", effort: "high")
        try chooseNativeProviderModel("future-native-model", in: app)
        _ = try waitForNativeModel(root, model: "future-native-model", effort: "light")
        try chooseNativeReasoning("experimental-effort", in: app)
        _ = try waitForNativeModel(root, model: "future-native-model", effort: "experimental-effort")
        try chooseNativeProviderModel("gpt-6-astra", in: app)
        _ = try waitForNativeModel(root, model: "gpt-6-astra", effort: "high")
        try chooseNativeReasoning(nil, in: app)
        let reset = try waitForNativeModel(root, model: "gpt-6-astra", effort: "medium")
        XCTAssertEqual((reset["codexReasoningPreferences"] as? [String: String]), ["future-native-model": "experimental-effort"])
        try chooseNativeProviderModel("future-native-model", in: app)
        _ = try waitForNativeModel(root, model: "future-native-model", effort: "experimental-effort")
        XCTAssertEqual(composer.value as? String, draft)
        capture(app, name: "models-per-model-effort-restored-without-sending")

        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "generation": 2]).write(to: state, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        openNativeProviderMenu(in: app); app.menuItems["Refresh Models"].click()
        let modelSummary = app.menuButtons["provider-model-menu"]
        let refreshedSummary = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND value CONTAINS %@", "Offline Future Refreshed"), object: modelSummary)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshedSummary], timeout: 10), .completed,
                       "The current model menu's exposed summary must reflect the refreshed catalog before opening its new effort menu.")
        openNativeProviderMenu(in: app)
        let reasoning = app.menuItems["codex-reasoning-menu"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 10)); reasoning.click()
        XCTAssertFalse(app.menuItems["codex-reasoning-experimental-effort"].exists, "Refresh must remove an effort no longer advertised for the same wire model.")
        let currentDefault = app.menuItems["codex-reasoning-default"]
        XCTAssertTrue(currentDefault.waitForExistence(timeout: 5)); XCTAssertTrue(currentDefault.isEnabled); currentDefault.click()
        _ = try waitForNativeModel(root, model: "future-native-model", effort: "deep")
        openNativeProviderMenu(in: app)
        let cliDefault = app.menuItems["codex-model-default"]
        XCTAssertTrue(cliDefault.waitForExistence(timeout: 5)); XCTAssertTrue(cliDefault.isEnabled); cliDefault.click()
        let selected = try waitForNativeModel(root, model: "future-cwd-model", effort: "deep")
        XCTAssertEqual(selected["codexModelSelectionSource"] as? String, "cliDefault")
        XCTAssertTrue((selected["codexReasoningPreferences"] as? [String: String] ?? [:]).isEmpty)
        XCTAssertTrue((selected["messages"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue((selected["queuedTurns"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue((selected["runHistory"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertEqual(composer.value as? String, draft)
        try assertNativeReadOnlyCodexAccount(in: app, wire: wire)
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        let beforeRestart = try historyWire(wire)
        XCTAssertTrue(beforeRestart.filter { $0["method"] as? String == "config/read" }.count >= 2, "CLI defaults require a stable cwd-config observation before and after the catalog read.")
        XCTAssertFalse(beforeRestart.contains { ($0["method"] as? String ?? "").hasPrefix("turn/") || ($0["method"] as? String ?? "").hasPrefix("thread/") })
        let allowedReads: Set<String> = ["initialize", "model/list", "config/read", "account/read", "account/rateLimits/read"]
        XCTAssertTrue(beforeRestart.allSatisfy { allowedReads.contains($0["method"] as? String ?? "") }, "The model and account panels must never sign in, sign out, refresh credentials, write configuration, or submit input.")
        capture(app, name: "models-cwd-cli-default-preserves-unsent-draft")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        let restored = try waitForNativeModel(root, model: "future-cwd-model", effort: "deep")
        XCTAssertEqual(restored["codexModelSelectionSource"] as? String, "cliDefault")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: historyWire(wire), options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: beforeRestart, options: .sortedKeys), "Relaunch must preserve concrete defaults without rereading config or sending input.")
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "models-reopened-head"), originalHead)
        capture(app, name: "models-reopened-concrete-reasoning-and-draft")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func assertNativeReadOnlyCodexAccount(in app: XCUIApplication, wire: URL) throws {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "codex-account-reveal-email").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let kind = settings.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR value == %@)", "codex-account-kind", "ChatGPT", "ChatGPT")).firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 10))
        let plan = settings.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Offline Hosted Plus", "Offline Hosted Plus")).firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        let email = settings.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR value == %@)", "codex-account-email", "Hidden", "Hidden")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        let reveal = settings.descendants(matching: .any).matching(identifier: "codex-account-reveal-email").firstMatch
        XCTAssertTrue(reveal.exists)
        XCTAssertTrue((reveal.value as? String) == "0" || (reveal.value as? NSNumber)?.intValue == 0)
        XCTAssertFalse(settings.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "native-ui@example.invalid", "native-ui@example.invalid")).firstMatch.exists)
        let remaining = settings.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "75% remaining", "75% remaining")).firstMatch
        let refresh = settings.buttons["codex-account-refresh"]
        // Native grouped Forms can flatten their scroll container out of AX.
        // Keep the actual control visible within its owning window in that case.
        let area = settings.scrollViews.firstMatch
        let scroll = area.exists ? area : settings
        for _ in 0..<8 {
            if remaining.exists && refresh.exists && refresh.isHittable && scroll.frame.contains(refresh.frame) { break }
            scroll.scroll(byDeltaX: 0, deltaY: -150)
        }
        XCTAssertTrue(remaining.exists, "The primary allowance must show 75% remaining from the synthetic 25%-used response.")
        XCTAssertTrue(refresh.exists && refresh.isEnabled && refresh.isHittable && scroll.frame.contains(refresh.frame), "Refresh Account must remain reachable in the native Settings form.")
        let before = try historyWire(wire)
        let accountReads = before.filter { $0["method"] as? String == "account/read" }.count
        let usageReads = before.filter { $0["method"] as? String == "account/rateLimits/read" }.count
        XCTAssertGreaterThanOrEqual(accountReads, 2); XCTAssertGreaterThanOrEqual(usageReads, 1)
        refresh.click()
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let frames = try? historyWire(wire) else { return false }
            return frames.filter { $0["method"] as? String == "account/read" }.count >= accountReads + 2
                && frames.filter { $0["method"] as? String == "account/rateLimits/read" }.count >= usageReads + 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 10), .completed)
        XCTAssertTrue(remaining.exists)
        let frames = try historyWire(wire)
        for frame in frames where frame["method"] as? String == "account/read" {
            let params = try XCTUnwrap(frame["params"] as? [String: Any])
            XCTAssertEqual(Set(params.keys), ["refreshToken"])
            XCTAssertEqual(params["refreshToken"] as? Bool, false)
        }
        for frame in frames where frame["method"] as? String == "account/rateLimits/read" {
            XCTAssertTrue(try XCTUnwrap(frame["params"] as? [String: Any]).isEmpty)
        }
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(settings.frame))
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "models-read-only-account-hidden-email-and-remaining-allowance"; screenshot.lifetime = .keepAlways; add(screenshot)
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForAbsence(settings, timeout: 5))
    }

    @MainActor private func openNativeProviderMenu(in app: XCUIApplication) {
        let menu = app.descendants(matching: .any).matching(identifier: "provider-model-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); XCTAssertTrue(menu.isEnabled && menu.isHittable); menu.click()
    }
    @MainActor private func chooseNativeProviderModel(_ model: String, in app: XCUIApplication) throws {
        openNativeProviderMenu(in: app)
        let item = app.menuItems["provider-model-" + model]
        XCTAssertTrue(item.waitForExistence(timeout: 10)); XCTAssertTrue(item.isEnabled && item.isHittable); item.click()
    }
    @MainActor private func chooseNativeReasoning(_ effort: String?, in app: XCUIApplication) throws {
        openNativeProviderMenu(in: app)
        let menu = app.menuItems["codex-reasoning-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.click()
        let item = app.menuItems[effort.map { "codex-reasoning-" + $0 } ?? "codex-reasoning-default"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); XCTAssertTrue(item.isEnabled && item.isHittable); item.click()
    }
    @MainActor private func waitForNativeModel(_ root: URL, model: String, effort: String) throws -> [String: Any] {
        let snapshot = try waitForPrivateWorkspace(root, timeout: 15) { snapshot in
            guard let thread = (snapshot["threads"] as? [[String: Any]])?.first else { return false }
            return thread["model"] as? String == model && thread["reasoningEffort"] as? String == effort
        }
        return try XCTUnwrap((snapshot["threads"] as? [[String: Any]])?.first)
    }

    @MainActor func testNativeSteeringTargetsRunningTurnAndPreservesReceiptAcrossRestart() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "steering")
        let app = fixture.app, root = fixture.root
        app.launchArguments += ["-followUpBehavior", "queue"]
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        XCTAssertTrue(python.hasPrefix("/") && python != "/usr/bin/python3" && FileManager.default.isExecutableFile(atPath: python))
        let project = root.appendingPathComponent("Native Steering", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let readme = project.appendingPathComponent("README.md"), original = Data("Native steering leaves workspace files unchanged\n".utf8)
        try original.write(to: readme)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Native steering fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "steering-git-\(arguments[0])")
        }
        let originalHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "steering-original-head")
        let firstPrompt = "Keep this native turn running until its explicit steering input"
        let literal = "Literal steering: café λ 👩🏽‍💻 '$(not executed)' \\n stays text"
        let queuedPrompt = "Keep this temporary input queued until I explicitly remove it"
        let state = root.appendingPathComponent("steering-peer.json"), wire = root.appendingPathComponent("steering-peer-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "firstPrompt": firstPrompt, "steeringPrompt": literal]).write(to: state)
        let bundledPeer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "codex_steering_ui", withExtension: "py"))
        let peer = bundledPeer
        let bin = root.appendingPathComponent("private-bin", isDirectory: true), home = root.appendingPathComponent("private-codex-home", isDirectory: true)
        for directory in [bin, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let executable = try installOfflineCLI(tool: "codex", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        app.launchEnvironment["CODEX_HOME"] = home.path
        addTeardownBlock { @MainActor [weak self] in
            for (path, name) in [(wire, "steering-offline-provider-wire"), (state, "steering-offline-provider-state")] {
                if let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8) {
                    let receipt = XCTAttachment(string: text); receipt.name = name; receipt.lifetime = .keepAlways; self?.add(receipt)
                }
            }
        }
        // The same strict wrapper initialize preflight applies to every offline provider workflow.
        try preflightOfflineHistoryProvider(executable, cwd: project, environment: app.launchEnvironment, name: "steering")
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app); app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"], send = app.buttons["composer-send"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let threadIdentifier = try selectedThreadIdentifier(in: app)
        composer.click(); composer.typeText(firstPrompt)
        XCTAssertTrue(waitForValue(composer, value: firstPrompt, timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Offline steering turn is running"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 5))
        XCTAssertTrue(send.waitForExistence(timeout: 5)); XCTAssertEqual(send.label, "Queue message")

        // Plain Return retains the default queue behavior while the original native turn is held.
        composer.click(); composer.typeText(queuedPrompt)
        XCTAssertTrue(waitForValue(composer, value: queuedPrompt, timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        let removeQueued = app.buttons["Remove queued message"]
        XCTAssertTrue(removeQueued.waitForExistence(timeout: 10))
        let queued = try waitForPrivateWorkspace(root, timeout: 10) { snapshot in
            guard let thread = (snapshot["threads"] as? [[String: Any]])?.first else { return false }
            return (thread["queuedTurns"] as? [[String: Any]])?.first?["text"] as? String == queuedPrompt
        }
        let queuedThread = try XCTUnwrap((queued["threads"] as? [[String: Any]])?.first)
        XCTAssertEqual((queuedThread["queuedTurns"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((queuedThread["runHistory"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try historyWire(wire).filter { $0["method"] as? String == "turn/start" }.count, 1)
        XCTAssertEqual(try historyWire(wire).filter { $0["method"] as? String == "turn/steer" }.count, 0)
        capture(app, name: "steering-default-return-retains-queued-input")
        XCTAssertTrue(removeQueued.isEnabled && removeQueued.isHittable); removeQueued.click()
        XCTAssertTrue(waitForAbsence(removeQueued, timeout: 5))
        _ = try waitForPrivateWorkspace(root, timeout: 5) { snapshot in
            ((snapshot["threads"] as? [[String: Any]])?.first?["queuedTurns"] as? [[String: Any]])?.isEmpty == true
        }

        // Paste preserves literal Unicode; only the disposable hosted runner's clipboard is used.
        NSPasteboard.general.clearContents(); XCTAssertTrue(NSPasteboard.general.setString(literal, forType: .string))
        defer { if NSPasteboard.general.string(forType: .string) == literal { NSPasteboard.general.clearContents() } }
        composer.click(); composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitForValue(composer, value: literal, timeout: 5))
        let delivery = app.descendants(matching: .any).matching(identifier: "composer-delivery").firstMatch
        XCTAssertTrue(delivery.waitForExistence(timeout: 5)); XCTAssertTrue(delivery.isHittable); delivery.click()
        let steer = app.menuItems["Steer Current Turn"], queue = app.menuItems["Queue Message"]
        let canSteer = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: steer)
        XCTAssertEqual(XCTWaiter.wait(for: [canSteer], timeout: 10), .completed)
        XCTAssertTrue(queue.exists && queue.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(send.label, "Queue message", "The alternate shortcut must not change the saved Queue preference.")
        composer.click(); app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Offline steering acknowledged the literal follow-up"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
        XCTAssertFalse(removeQueued.exists)
        let transcript = app.scrollViews.containing(.staticText, identifier: "Offline steering acknowledged the literal follow-up").firstMatch
        XCTAssertTrue(transcript.exists)
        for prompt in [firstPrompt, literal] {
            XCTAssertEqual(transcript.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", prompt, prompt)).count, 1)
        }
        XCTAssertFalse(transcript.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", queuedPrompt, queuedPrompt)).firstMatch.exists)
        let completed = try waitForPrivateWorkspace(root, timeout: 20) { snapshot in
            guard let thread = (snapshot["threads"] as? [[String: Any]])?.first,
                  let run = (thread["runHistory"] as? [[String: Any]])?.first,
                  let checkpoint = run["checkpoints"] as? [String: Any],
                  let post = checkpoint["postRun"] as? [String: Any] else { return false }
            return run["status"] as? String == "completed" && post["phase"] as? String == "ready"
                && (snapshot["promptSteerings"] as? [[String: Any]])?.first?["phase"] as? String == "delivered"
        }
        let operationID = try assertSteeringSnapshot(completed, firstPrompt: firstPrompt, literal: literal, name: "steering-delivered-private-snapshot")
        let frames = try historyWire(wire)
        try assertSteeringWire(frames, literal: literal, snapshot: completed)
        let mutationFrames = frames.filter { ["thread/start", "turn/start", "turn/steer"].contains($0["method"] as? String ?? "") }
        let latestDraft = "Retain this unsent draft after steering and restart"
        composer.click(); composer.typeText(latestDraft)
        XCTAssertTrue(waitForValue(composer, value: latestDraft, timeout: 5))
        capture(app, name: "steering-one-completed-turn-two-user-inputs")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: latestDraft, timeout: 10))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadIdentifier)
        XCTAssertTrue(app.staticTexts["Offline steering acknowledged the literal follow-up"].exists)
        let reopened = try privateWorkspaceSnapshot(root)
        XCTAssertEqual(try assertSteeringSnapshot(reopened, firstPrompt: firstPrompt, literal: literal, name: "steering-reopened-private-snapshot"), operationID)
        try assertSteeringWire(historyWire(wire), literal: literal, snapshot: reopened)
        let reopenedMutations = try historyWire(wire).filter { ["thread/start", "turn/start", "turn/steer"].contains($0["method"] as? String ?? "") }
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: reopenedMutations, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: mutationFrames, options: .sortedKeys), "Reopening must not repeat or synthesize a native input RPC.")
        XCTAssertEqual(try Data(contentsOf: readme), original)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "steering-reopened-head"), originalHead)
        capture(app, name: "steering-reopened-receipt-and-unsent-draft")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testLightAppearanceFileMenuProjectWorkflow() throws {
        try exerciseProjectWorkflow(appearance: "light", useKeyboard: false)
    }

    @MainActor func testDarkAppearanceKeyboardProjectWorkflow() throws {
        try exerciseProjectWorkflow(appearance: "dark", useKeyboard: true)
    }

    @MainActor func testFilesEditorSearchReferencesAndQuitPreserveDisk() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "files")
        let app = fixture.app
        let project = fixture.root.appendingPathComponent("Native Files", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let document = project.appendingPathComponent("Notes.swift")
        let original = "// Synthetic native editor fixture\nlet nativeNeedle = 7\n"
        let saved = "// Saved by the native editor\nlet nativeNeedle = 11\n"
        let unsaved = "// Unsaved native editor buffer\nlet nativeNeedle = 99\n"
        try original.write(to: document, atomically: true, encoding: .utf8)
        for arguments in [["init", "--initial-branch", "main"], ["add", "Notes.swift"], ["commit", "--message", "Synthetic editor fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration,
                           name: "files-fixture-\(arguments[0])")
        }
        let initialHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "files-initial-head")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        XCTAssertTrue(app.buttons["Collapse Native Files"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let draft = "Keep this unsent file discussion"
        composer.click(); composer.typeText(draft)
        toggleInspector(in: app)
        selectSegment("Files", in: app)
        let file = app.buttons["workspace-entry-Notes.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 10)); XCTAssertTrue(file.isHittable); file.click()
        let editor = app.textViews["File editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(editor, value: original, timeout: 5))
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText(saved)
        XCTAssertEqual(editor.value as? String, saved)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), original, "Typing in the editor must retain an unsaved buffer.")
        toggleInspector(in: app)
        XCTAssertTrue(waitForAbsence(editor, timeout: 5))
        toggleInspector(in: app)
        selectSegment("Files", in: app)
        XCTAssertTrue(waitForValue(editor, value: saved, timeout: 10), "Hiding the inspector must preserve unsaved file edits.")
        let save = app.buttons["workspace-file-save"]
        XCTAssertTrue(save.exists && save.isEnabled); save.click()
        let savedExpectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: document, encoding: .utf8)) == saved
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [savedExpectation], timeout: 10), .completed)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), saved)
        selectSegment("Contents", in: app)
        let search = app.textFields["workspace-file-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.click(); search.typeText("nativeNeedle")
        let match = app.buttons["workspace-match-Notes.swift-2"]
        XCTAssertTrue(match.waitForExistence(timeout: 10)); XCTAssertTrue(match.isHittable); match.click()
        XCTAssertTrue(waitForValue(editor, value: saved, timeout: 5), "A content match must open its file without changing the saved text.")
        capture(app, name: "files-content-match-native-editor")
        let matchTree = XCTAttachment(string: app.debugDescription); matchTree.name = "files-content-match-accessibility-tree"; matchTree.lifetime = .keepAlways; add(matchTree)
        XCTAssertEqual(composer.value as? String, draft)
        app.buttons["composer-reference-file"].click()
        let picker = app.sheets.containing(.textField, identifier: "composer-file-search").element
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let referenceSearch = picker.textFields["composer-file-search"]
        referenceSearch.click(); referenceSearch.typeText("Notes.swift")
        let reference = picker.buttons["composer-file-Notes.swift"]
        XCTAssertTrue(reference.waitForExistence(timeout: 10)); reference.click()
        let referencedDraft = draft + " [Notes.swift](Notes.swift) "
        XCTAssertTrue(waitForValue(composer, value: referencedDraft, timeout: 5), "Referencing a file must preserve the existing unsent draft.")
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText(unsaved)
        XCTAssertEqual(editor.value as? String, unsaved)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), saved)
        app.typeKey("q", modifierFlags: .command)
        let review = quitReview(in: app)
        XCTAssertTrue(review.buttons["Cancel"].isHittable)
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "files-quit-unsaved-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(review.buttons["Quit and Discard"], timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(waitForValue(editor, value: unsaved, timeout: 5))
        XCTAssertEqual(composer.value as? String, referencedDraft)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), saved)
        app.typeKey("q", modifierFlags: .command)
        let confirmedReview = quitReview(in: app)
        XCTAssertTrue(confirmedReview.buttons["Quit and Discard"].isHittable)
        confirmedReview.buttons["Quit and Discard"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), saved, "Explicit Quit and Discard must not overwrite saved file bytes.")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: referencedDraft, timeout: 10))
        toggleInspector(in: app)
        selectSegment("Files", in: app)
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.click()
        XCTAssertTrue(waitForValue(editor, value: saved, timeout: 10))
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "files-final-head"), initialHead)
        capture(app, name: "files-reopened-saved-editor-and-reference")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testProjectScriptsRequireReviewedLaunchAndPreserveDrafts() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "scripts")
        let app = fixture.app
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["T3CODE_PROJECT_ROOT"] = "/synthetic-inherited-project"
        app.launchEnvironment["T3CODE_WORKTREE_PATH"] = "/synthetic-inherited-worktree"
        let project = fixture.root.appendingPathComponent("Native Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let configuration = project.appendingPathComponent("t3.json")
        let staleCommand = "printf 'stale\\n' > script-stale.txt; exit 3"
        let inspectedCommand = "printf 'inspect\\n' >> script-invocations.txt; pwd -P > script-cwd.txt; printf '%s\\n' \"$T3CODE_PROJECT_ROOT\" > script-root.txt; printf '%s\\n' \"${T3CODE_WORKTREE_PATH-unset}\" > script-worktree.txt; printf 'native-script-find-early-marker\\n'; i=0; while [ \"$i\" -lt 80 ]; do printf 'native-script-padding-%s\\n' \"$i\"; i=$((i+1)); done; printf 'native-script-finished\\n'; exit 7"
        let holdingCommand = "printf 'hold\\n' >> script-invocations.txt; printf 'running\\n' > script-holding.txt; exec /bin/sleep 120"
        func writeConfiguration(_ command: String) throws {
            let scripts: [[String: Any]] = [
                ["name": "Inspect Workspace", "command": command, "runOnWorktreeCreate": true, "runOnSettle": true],
                ["name": "Hold Workspace", "command": holdingCommand]
            ]
            try JSONSerialization.data(withJSONObject: ["scripts": scripts], options: [.sortedKeys, .prettyPrinted]).write(to: configuration, options: .atomic)
        }
        try writeConfiguration(staleCommand)
        for arguments in [["init", "--initial-branch", "main"], ["add", "t3.json"], ["commit", "--message", "Synthetic script fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration,
                           name: "scripts-fixture-\(arguments[0])")
        }
        let initialHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "scripts-initial-head")
        let receiptNames = ["script-stale.txt", "script-cwd.txt", "script-root.txt", "script-worktree.txt", "script-holding.txt", "script-invocations.txt"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        XCTAssertTrue(app.buttons["Collapse Native Scripts"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let draft = "Keep this unsent discussion while running project scripts"
        composer.click(); composer.typeText(draft)
        openProjectScripts(in: app)
        let review = app.sheets.containing(.button, identifier: "run-project-script").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let cwd = review.staticTexts["project-script-cwd"]
        XCTAssertTrue(waitForValue(cwd, value: project.path, timeout: 10))
        let command = review.descendants(matching: .any).matching(identifier: "project-script-command").element
        XCTAssertTrue(command.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", staleCommand, staleCommand)).element.waitForExistence(timeout: 10))
        for name in receiptNames { XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path), "Discovery must not run project scripts, including setup/settle roles.") }
        XCTAssertTrue(review.buttons["run-project-script"].isHittable && CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let discovery = XCTAttachment(screenshot: review.screenshot()); discovery.name = "scripts-discovery-without-execution"; discovery.lifetime = .keepAlways; add(discovery)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5)); XCTAssertEqual(composer.value as? String, draft)
        openProjectScripts(in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(command.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", staleCommand, staleCommand)).element.waitForExistence(timeout: 10))
        try writeConfiguration(inspectedCommand)
        review.buttons["run-project-script"].click()
        let changed = review.staticTexts["project-script-error"]
        XCTAssertTrue(changed.waitForExistence(timeout: 10))
        let changedText = [changed.label, (changed.value as? String) ?? ""].joined(separator: " ")
        XCTAssertTrue(changedText.contains("The project scripts changed. Reload the list before running a script."))
        for name in receiptNames { XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path), "Run must reject both the stale and unreviewed replacement script.") }
        review.buttons["Reload"].click()
        XCTAssertTrue(command.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", inspectedCommand, inspectedCommand)).element.waitForExistence(timeout: 10))
        let run = review.buttons["run-project-script"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: run)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed); run.click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let inspectedTab = app.buttons["Inspect Workspace"]
        XCTAssertTrue(inspectedTab.waitForExistence(timeout: 10))
        let terminal = app.textViews["Workspace terminal"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value CONTAINS %@", "native-script-finished"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        let exitStatus = "Command exited (7)."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", exitStatus, exitStatus)).element.waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("script-cwd.txt"), encoding: .utf8), project.path + "\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("script-root.txt"), encoding: .utf8), project.path + "\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("script-worktree.txt"), encoding: .utf8), "unset\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("script-stale.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("script-holding.txt").path))
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("script-invocations.txt"), encoding: .utf8), "inspect\n")
        XCTAssertEqual(composer.value as? String, draft)
        capture(app, name: "scripts-reviewed-command-cwd-and-exit-status")
        openProjectScripts(in: app); XCTAssertTrue(review.waitForExistence(timeout: 5))
        let picker = review.descendants(matching: .any).matching(identifier: "project-script-picker").element
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.click()
        let holdChoice = app.menuItems["Hold Workspace"]
        XCTAssertTrue(holdChoice.waitForExistence(timeout: 5)); holdChoice.click()
        XCTAssertTrue(command.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", holdingCommand, holdingCommand)).element.waitForExistence(timeout: 5))
        run.click(); XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let holdingTab = app.buttons["Hold Workspace"]
        XCTAssertTrue(holdingTab.waitForExistence(timeout: 10))
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: project.appendingPathComponent("script-holding.txt"), encoding: .utf8)) == "running\n"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed)
        let close = app.buttons["Close Hold Workspace"]
        XCTAssertTrue(close.isHittable); close.click()
        let confirmation = terminalCloseReview(in: app)
        let closeImage = XCTAttachment(screenshot: confirmation.screenshot()); closeImage.name = "scripts-close-running-command-review"; closeImage.lifetime = .keepAlways; add(closeImage)
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(confirmation.buttons["Close Terminal"], timeout: 5))
        XCTAssertTrue(holdingTab.exists && inspectedTab.exists)
        XCTAssertEqual(composer.value as? String, draft)
        close.click()
        let confirmed = terminalCloseReview(in: app)
        confirmed.buttons["Close Terminal"].click()
        XCTAssertTrue(waitForAbsence(holdingTab, timeout: 10))
        XCTAssertTrue(inspectedTab.exists)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("script-invocations.txt"), encoding: .utf8), "inspect\nhold\n")
        let threadID = try selectedThreadIdentifier(in: app)
        let originalConfiguration = try Data(contentsOf: configuration)
        let originalReceipts = try Dictionary(uniqueKeysWithValues: receiptNames.filter { $0 != "script-stale.txt" }.map {
            ($0, try Data(contentsOf: project.appendingPathComponent($0)))
        })
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "scripts-final-head"), initialHead)
        capture(app, name: "scripts-running-tab-closed-draft-retained")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertTrue(inspectedTab.waitForExistence(timeout: 10))
        XCTAssertFalse(holdingTab.exists, "A terminal explicitly closed before Quit must stay closed after relaunch.")
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value CONTAINS %@", "native-script-finished"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        let disconnected = "Saved output. The previous shell is no longer connected."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", disconnected, disconnected)).element.waitForExistence(timeout: 10))
        XCTAssertFalse((terminal.value as? String ?? "").contains("native-script-find-early-marker"), "The search target starts outside the restored viewport.")
        let find = app.buttons["Find in terminal"]
        XCTAssertTrue(find.isHittable); find.click()
        let search = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", "Find")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeKey("a", modifierFlags: .command); search.typeText("native-script-find-early-marker")
        search.typeKey(.return, modifierFlags: [])
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value CONTAINS %@", "native-script-find-early-marker"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 5), .completed)
        XCTAssertEqual(search.value as? String, "native-script-find-early-marker")
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertFalse(holdingTab.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("script-stale.txt").path))
        for (name, contents) in originalReceipts {
            XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(name)), contents, "Restoring saved output must not rerun a script or change its receipts: \(name)")
        }
        XCTAssertEqual(try Data(contentsOf: configuration), originalConfiguration)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "scripts-restored-head"), initialHead)
        capture(app, name: "scripts-cold-output-restored-and-searched-without-replay")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testRepositoryGroupingKeepsCheckoutDrafts() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "grouping")
        let app = fixture.app
        let first = fixture.root.appendingPathComponent("Checkout One", isDirectory: true)
        let second = fixture.root.appendingPathComponent("Checkout Two", isDirectory: true)
        for checkout in [first, second] {
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false)
            try "Synthetic local checkout: \(checkout.lastPathComponent)\n".write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            for arguments in [["init", "--initial-branch", "main"], ["remote", "add", "origin", "https://example.invalid/Team/Repo.git"], ["add", "README.md"], ["commit", "--message", "Synthetic UI fixture"]] {
                _ = try runGit(["-C", checkout.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration,
                               name: "grouping-\(checkout.lastPathComponent)-\(arguments[0])")
            }
        }
        let firstHead = try verifyHead(gitPath: fixture.gitPath, project: first, configuration: fixture.configuration, name: "grouping-first-initial-head")
        let secondHead = try verifyHead(gitPath: fixture.gitPath, project: second, configuration: fixture.configuration, name: "grouping-second-initial-head")
        var originalFiles: [URL: Data] = [:]
        for checkout in [first, second] {
            for relativePath in ["README.md", ".git/HEAD"] {
                let file = checkout.appendingPathComponent(relativePath)
                originalFiles[file] = try Data(contentsOf: file)
            }
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(first, in: app)
        XCTAssertTrue(app.buttons["Collapse Checkout One"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let firstDraft = "Draft belonging only to checkout one"
        composer.click(); composer.typeText(firstDraft)
        XCTAssertEqual(composer.value as? String, firstDraft)
        assertConversationWorkspace(app, path: first.path)
        let firstThreadID = try selectedThreadIdentifier(in: app)

        try openProject(second, in: app)
        let groupedHeader = app.buttons["Collapse Team/Repo"]
        XCTAssertTrue(groupedHeader.waitForExistence(timeout: 15), "Equivalent local Git remotes must form one repository group.")
        XCTAssertEqual(projectHeaders(in: app).count, 1)
        groupedHeader.rightClick()
        let createInCheckout = app.menuItems["New Thread in Checkout"]
        XCTAssertTrue(createInCheckout.waitForExistence(timeout: 5)); createInCheckout.click()
        let secondCheckout = createInCheckout.menuItems.matching(NSPredicate(format: "title == %@", second.path)).element
        XCTAssertTrue(secondCheckout.waitForExistence(timeout: 5)); secondCheckout.click()
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
        assertConversationWorkspace(app, path: second.path)
        let secondDraft = "Draft belonging only to checkout two"
        composer.click(); composer.typeText(secondDraft)
        XCTAssertEqual(composer.value as? String, secondDraft)
        let secondThreadID = try selectedThreadIdentifier(in: app)
        XCTAssertNotEqual(firstThreadID, secondThreadID)

        groupedHeader.rightClick()
        let checkouts = app.menuItems["Checkouts"]
        XCTAssertTrue(checkouts.waitForExistence(timeout: 5)); checkouts.click()
        XCTAssertTrue(checkouts.menuItems.matching(NSPredicate(format: "title == %@", first.path)).element.waitForExistence(timeout: 5))
        XCTAssertTrue(checkouts.menuItems.matching(NSPredicate(format: "title == %@", second.path)).element.exists, "The native checkout menu must expose both physical paths.")
        app.typeKey(.escape, modifierFlags: []); app.typeKey(.escape, modifierFlags: [])
        let checkoutPreference = app.descendants(matching: .any).matching(identifier: "new-conversation-checkout").element
        XCTAssertTrue(checkoutPreference.waitForExistence(timeout: 5)); checkoutPreference.click()
        let firstChoice = app.menuItems.matching(NSPredicate(format: "title == %@", first.path)).element
        XCTAssertTrue(firstChoice.waitForExistence(timeout: 5)); firstChoice.click()
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, secondDraft, "Choosing a future checkout must preserve the selected conversation's draft.")
        assertConversationWorkspace(app, path: second.path)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
        assertConversationWorkspace(app, path: first.path)
        let futureThreadID = try selectedThreadIdentifier(in: app)
        XCTAssertNotEqual(futureThreadID, firstThreadID); XCTAssertNotEqual(futureThreadID, secondThreadID)
        XCTAssertEqual(threadRows(in: app).count, 3)
        let futureDraft = "Distinct draft in the preferred checkout one"
        composer.click(); composer.typeText(futureDraft)
        XCTAssertEqual(composer.value as? String, futureDraft)

        selectThread(firstThreadID, in: app)
        XCTAssertTrue(waitForValue(composer, value: firstDraft, timeout: 5))
        assertConversationWorkspace(app, path: first.path)
        selectThread(secondThreadID, in: app)
        XCTAssertTrue(waitForValue(composer, value: secondDraft, timeout: 5))
        assertConversationWorkspace(app, path: second.path)
        assertSidebarFitsDisplay(app, projectHeader: groupedHeader, selectedConversation: threadRow(secondThreadID, in: app))
        capture(app, name: "grouping-repository-with-checkout-drafts")

        setGroupingMode("Separate Checkouts", in: app)
        let firstHeader = app.buttons["Collapse Checkout One"], secondHeader = app.buttons["Collapse Checkout Two"]
        XCTAssertTrue(firstHeader.waitForExistence(timeout: 5) && secondHeader.exists)
        XCTAssertEqual(projectHeaders(in: app).count, 2)
        XCTAssertEqual(threadRows(in: app).count, 3)
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, secondDraft)
        assertConversationWorkspace(app, path: second.path)
        assertSidebarFitsDisplay(app, projectHeader: firstHeader, selectedConversation: threadRow(secondThreadID, in: app))
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(secondHeader.frame))
        capture(app, name: "grouping-separate-checkouts")
        setGroupingMode("Repository", in: app)
        XCTAssertTrue(groupedHeader.waitForExistence(timeout: 5))
        XCTAssertEqual(projectHeaders(in: app).count, 1)
        XCTAssertEqual(threadRows(in: app).count, 3)
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, secondDraft)
        capture(app, name: "grouping-repository-restored")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(groupedHeader.waitForExistence(timeout: 10))
        XCTAssertEqual(projectHeaders(in: app).count, 1)
        XCTAssertEqual(threadRows(in: app).count, 3)
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        XCTAssertTrue(waitForValue(composer, value: secondDraft, timeout: 5))
        assertConversationWorkspace(app, path: second.path)
        capture(app, name: "grouping-reopened")
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: first, configuration: fixture.configuration, name: "grouping-first-final-head"), firstHead)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: second, configuration: fixture.configuration, name: "grouping-second-final-head"), secondHead)

        groupedHeader.rightClick()
        let renameGroup = app.menuItems["Rename Group…"]
        XCTAssertTrue(renameGroup.waitForExistence(timeout: 5)); renameGroup.click()
        let renameSheet = app.sheets.containing(.button, identifier: "sidebar-rename-save").element
        XCTAssertTrue(renameSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(renameSheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Rename Group", "Rename Group")).element.exists)
        XCTAssertEqual(renameSheet.textFields.count, 1)
        let renameField = renameSheet.textFields.element
        XCTAssertEqual(renameField.value as? String, "Team/Repo")
        renameField.click(); renameField.typeKey("a", modifierFlags: .command)
        let renamedGroup = "Native UI Group Renamed"
        renameField.typeText(renamedGroup); renameSheet.buttons["sidebar-rename-save"].click()
        let renamedHeader = app.buttons["Collapse \(renamedGroup)"]
        XCTAssertTrue(renamedHeader.waitForExistence(timeout: 5))
        setGroupingMode("Separate Checkouts", in: app)
        let renamedPhysicalHeaders = app.buttons.matching(NSPredicate(format: "label == %@", "Collapse \(renamedGroup)"))
        XCTAssertTrue(renamedPhysicalHeaders.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(renamedPhysicalHeaders.count, 2, "Renaming the group must rename both registered checkouts.")
        setGroupingMode("Repository", in: app)
        XCTAssertTrue(renamedHeader.waitForExistence(timeout: 5))
        XCTAssertEqual(projectHeaders(in: app).count, 1)
        renamedHeader.rightClick()
        let removeGroup = app.menuItems["Remove Group…"]
        XCTAssertTrue(removeGroup.waitForExistence(timeout: 5)); removeGroup.click()
        let review = assertGroupRemovalReview(in: app, name: renamedGroup, paths: [first.path, second.path])
        let remove = review.buttons["remove-project-group"]
        XCTAssertTrue(remove.isHittable && app.state == .runningForeground && CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "grouping-remove-group-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(remove, timeout: 5))
        XCTAssertTrue(renamedHeader.exists)
        XCTAssertEqual(threadRows(in: app).count, 3)
        let drafts = [(firstThreadID, firstDraft, first.path), (futureThreadID, futureDraft, first.path), (secondThreadID, secondDraft, second.path)]
        for (identifier, draft, path) in drafts {
            let row = threadRow(identifier, in: app)
            XCTAssertTrue(row.exists); selectThread(identifier, in: app)
            XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5), "Cancelling group removal must preserve every conversation's draft.")
            assertConversationWorkspace(app, path: path)
        }
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        renamedHeader.rightClick()
        XCTAssertTrue(removeGroup.waitForExistence(timeout: 5)); removeGroup.click()
        let confirmedReview = assertGroupRemovalReview(in: app, name: renamedGroup, paths: [first.path, second.path])
        confirmedReview.buttons["remove-project-group"].click()
        XCTAssertTrue(waitForAbsence(renamedHeader, timeout: 10))
        XCTAssertTrue(waitForAbsence(composer, timeout: 5))
        XCTAssertEqual(projectHeaders(in: app).count, 0)
        XCTAssertEqual(threadRows(in: app).count, 0)
        for (file, bytes) in originalFiles {
            XCTAssertEqual(try Data(contentsOf: file), bytes, "Removing a group must preserve existing checkout file bytes: \(file.lastPathComponent).")
        }
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: first, configuration: fixture.configuration, name: "grouping-first-removed-head"), firstHead)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: second, configuration: fixture.configuration, name: "grouping-second-removed-head"), secondHead)
        let emptyDescription = "Your projects and coding agents, in a native Mac workspace."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", emptyDescription, emptyDescription)).element.waitForExistence(timeout: 5))
        capture(app, name: "grouping-removed-empty-workspace")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testReviewedBlockingSetupKeepsDraftUntilExplicitContinue() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "setup")
        let app = fixture.app
        app.launchEnvironment["SHELL"] = "/bin/sh"
        let project = fixture.root.appendingPathComponent("Native Setup", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let command = "pwd -P > setup-cwd.txt; printf 'native-blocking-setup-output\\n'; exit 7"
        let scripts: [[String: Any]] = [
            ["name": "Reviewed Blocking Setup", "command": command, "runOnWorktreeCreate": true, "async": false],
            ["name": "Unselected Setup", "command": "printf 'unexpected\\n' > setup-unselected.txt", "runOnWorktreeCreate": true]
        ]
        let configuration = project.appendingPathComponent("t3.json")
        try JSONSerialization.data(withJSONObject: ["scripts": scripts], options: [.sortedKeys, .prettyPrinted]).write(to: configuration, options: .atomic)
        let readme = project.appendingPathComponent("README.md"), readmeBytes = Data("Synthetic reviewed checkout setup\n".utf8)
        try readmeBytes.write(to: readme)
        for arguments in [["init", "--initial-branch", "main"], ["add", "t3.json", "README.md"], ["commit", "--message", "Reviewed setup fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "setup-fixture-\(arguments[0])")
        }
        let sourceHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "setup-source-head")
        let sourceHeadBytes = try Data(contentsOf: project.appendingPathComponent(".git/HEAD"))
        let configurationBytes = try Data(contentsOf: configuration)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        XCTAssertTrue(app.buttons["Collapse Native Setup"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"], draft = "Keep this unsent discussion through reviewed setup"
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.click(); composer.typeText(draft)
        let threadID = try selectedThreadIdentifier(in: app)
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        workspace.click()
        let choose = app.menuItems["Choose Worktree…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.click()
        let checkout = app.sheets.containing(.textField, identifier: "worktree-new-branch").element
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        let branch = checkout.textFields["worktree-new-branch"]
        branch.click(); branch.typeText("ui-reviewed-setup")
        let reviewChoice = checkout.checkBoxes["worktree-review-setup"]
        XCTAssertTrue(reviewChoice.exists)
        XCTAssertEqual((reviewChoice.value as? NSNumber)?.intValue ?? Int((reviewChoice.value as? String) ?? ""), 1, "Reviewing checkout setup must be the default choice.")
        let prepare = checkout.buttons["Prepare Worktree"]
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(checkout.frame))
        prepare.click()
        XCTAssertTrue(waitForAbsence(checkout, timeout: 5))
        let reviewSetup = app.buttons["workspace-setup-review"]
        XCTAssertTrue(reviewSetup.waitForExistence(timeout: 20), "A declared setup command must wait for explicit review after checkout.")
        assertWorkspaceReady(in: app) // Files and Terminal stay available while provider messages wait for setup.
        let worktreePath = try XCTUnwrap(workspace.value as? String)
        XCTAssertTrue(worktreePath.hasPrefix(fixture.root.appendingPathComponent("Worktrees").path + "/"))
        let worktree = URL(fileURLWithPath: worktreePath, isDirectory: true)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-cwd.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-unselected.txt").path))
        reviewSetup.click()
        let review = app.sheets.containing(.button, identifier: "workspace-setup-run").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(review.staticTexts["workspace-setup-review-cwd"], value: worktreePath, timeout: 5))
        let reviewedCommand = review.descendants(matching: .any).matching(identifier: "workspace-setup-review-command").element
        XCTAssertTrue(reviewedCommand.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", command, command)).element.exists)
        let blockingNotice = "Messages wait for this command to exit successfully. Background jobs may keep running afterward."
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", blockingNotice, blockingNotice)).element.exists)
        XCTAssertTrue(review.buttons["workspace-setup-run"].isHittable && review.buttons["Cancel"].isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "setup-explicit-blocking-command-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        XCTAssertTrue(reviewSetup.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-cwd.txt").path), "Cancelling review must never start setup.")
        XCTAssertEqual(composer.value as? String, draft)
        reviewSetup.click(); XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.buttons["workspace-setup-run"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let status = app.staticTexts["workspace-setup-status"]
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Checkout setup needs attention", "Checkout setup needs attention"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 15), .completed)
        let exitDetail = "Command exited with status 7."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", exitDetail, exitDetail)).element.exists)
        let outputDisclosure = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (identifier == %@ OR label == %@ OR title == %@)",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.disclosureTriangle.rawValue,
            "workspace-setup-output-disclosure", "Setup Output", "Setup Output"
        )).element
        XCTAssertTrue(outputDisclosure.waitForExistence(timeout: 10)); expandScriptOutputDisclosure(outputDisclosure)
        let output = app.staticTexts["workspace-setup-output"]
        let receivedOutput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label CONTAINS %@ OR value CONTAINS %@)", "native-blocking-setup-output", "native-blocking-setup-output"), object: output)
        XCTAssertEqual(XCTWaiter.wait(for: [receivedOutput], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("setup-cwd.txt"), encoding: .utf8), worktreePath + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-unselected.txt").path), "Only the reviewed first setup role may run.")
        XCTAssertTrue(app.buttons["workspace-setup-retry"].exists)
        let continueWithoutSetup = app.buttons["workspace-setup-skip"]
        XCTAssertTrue(continueWithoutSetup.exists && continueWithoutSetup.isEnabled && continueWithoutSetup.isHittable)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        capture(app, name: "setup-failed-with-exit-output-and-retained-draft")
        continueWithoutSetup.click()
        XCTAssertTrue(waitForAbsence(status, timeout: 10))
        assertWorkspaceReady(in: app)
        XCTAssertEqual(composer.value as? String, draft)
        assertConversationWorkspace(app, path: worktreePath)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try Data(contentsOf: readme), readmeBytes)
        XCTAssertEqual(try Data(contentsOf: configuration), configurationBytes)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(".git/HEAD")), sourceHeadBytes)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "setup-source-final-head"), sourceHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("setup-cwd.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("setup-unselected.txt").path))
        capture(app, name: "setup-explicitly-continued-without-changing-source")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testSettleScriptReviewAndExplicitResumeKeepDraftAndCheckout() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "settle")
        let app = fixture.app
        app.launchEnvironment["SHELL"] = "/bin/sh"
        let project = fixture.root.appendingPathComponent("Native Settle", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let command = "pwd -P > settle-cwd.txt; printf 'native-settle-output\\n'; exit 0"
        let scripts: [[String: Any]] = [
            ["name": "Reviewed Settle Script", "command": command, "runOnSettle": true, "async": false],
            ["name": "Unselected Settle Script", "command": "printf 'unexpected\\n' > settle-unselected.txt", "runOnSettle": true]
        ]
        let configuration = project.appendingPathComponent("t3.json")
        try JSONSerialization.data(withJSONObject: ["scripts": scripts], options: [.sortedKeys, .prettyPrinted]).write(to: configuration, options: .atomic)
        let readme = project.appendingPathComponent("README.md"), readmeBytes = Data("Synthetic explicit settle fixture\n".utf8)
        try readmeBytes.write(to: readme)
        for arguments in [["init", "--initial-branch", "main"], ["add", "t3.json", "README.md"], ["commit", "--message", "Explicit settle fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "settle-fixture-\(arguments[0])")
        }
        let sourceHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "settle-source-head")
        let sourceHeadBytes = try Data(contentsOf: project.appendingPathComponent(".git/HEAD")), configurationBytes = try Data(contentsOf: configuration)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        XCTAssertTrue(app.buttons["Collapse Native Settle"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"], draft = "Keep this unsent discussion through settle and resume"
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.click(); composer.typeText(draft)
        let threadID = try selectedThreadIdentifier(in: app)
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        workspace.click()
        let choose = app.menuItems["Choose Worktree…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.click()
        let checkout = app.sheets.containing(.textField, identifier: "worktree-new-branch").element
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        let branch = checkout.textFields["worktree-new-branch"]
        branch.click(); branch.typeText("ui-reviewed-settle")
        let prepare = checkout.buttons["Prepare Worktree"]
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed); prepare.click()
        XCTAssertTrue(waitForAbsence(checkout, timeout: 5))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value BEGINSWITH %@", fixture.root.appendingPathComponent("Worktrees").path + "/"), object: workspace)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 20), .completed)
        assertWorkspaceReady(in: app)
        let worktreePath = try XCTUnwrap(workspace.value as? String), worktree = URL(fileURLWithPath: worktreePath, isDirectory: true)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(composer.value as? String, draft)
        app.menuBars.menuBarItems["Thread"].click()
        let settle = app.menuItems["Settle Conversation…"]
        XCTAssertTrue(settle.waitForExistence(timeout: 5)); XCTAssertTrue(settle.isEnabled); settle.click()
        let confirmation = app.sheets.containing(.button, identifier: "settlement-confirm").element
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let reviewChoice = confirmation.checkBoxes["settlement-review-script"]
        XCTAssertTrue(reviewChoice.exists)
        XCTAssertEqual((reviewChoice.value as? NSNumber)?.intValue ?? Int((reviewChoice.value as? String) ?? ""), 1)
        XCTAssertTrue(confirmation.buttons["settlement-confirm"].isHittable && confirmation.buttons["Cancel"].isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(confirmation.frame))
        let confirmationImage = XCTAttachment(screenshot: confirmation.screenshot()); confirmationImage.name = "settle-native-confirmation-default-review"; confirmationImage.lifetime = .keepAlways; add(confirmationImage)
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(confirmation, timeout: 5))
        XCTAssertFalse(app.staticTexts["settlement-status"].exists)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("settle-cwd.txt").path))
        app.menuBars.menuBarItems["Thread"].click(); XCTAssertTrue(settle.waitForExistence(timeout: 5)); settle.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.buttons["settlement-confirm"].click()
        XCTAssertTrue(waitForAbsence(confirmation, timeout: 5))
        let settled = app.staticTexts["settlement-status"]
        let isSettled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Conversation settled", "Conversation settled"), object: settled)
        XCTAssertEqual(XCTWaiter.wait(for: [isSettled], timeout: 15), .completed)
        let reviewScript = app.buttons["workspace-settle-script-review"]
        XCTAssertTrue(reviewScript.waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("settle-cwd.txt").path), "Settling and script discovery must not execute a command.")
        reviewScript.click()
        let review = app.sheets.containing(.button, identifier: "workspace-settle-script-run").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(review.staticTexts["workspace-settle-script-review-cwd"], value: worktreePath, timeout: 5))
        let reviewedCommand = review.descendants(matching: .any).matching(identifier: "workspace-settle-script-review-command").element
        XCTAssertTrue(reviewedCommand.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", command, command)).element.exists)
        let notice = "The conversation stays settled after this command finishes. Resuming stops its background jobs before messages continue."
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", notice, notice)).element.exists)
        XCTAssertTrue(review.buttons["workspace-settle-script-run"].isHittable && CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "settle-explicit-command-and-cwd-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        XCTAssertTrue(settled.exists && reviewScript.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("settle-cwd.txt").path), "Cancelling script review must never run the command.")
        XCTAssertEqual(composer.value as? String, draft)
        reviewScript.click(); XCTAssertTrue(review.waitForExistence(timeout: 5)); review.buttons["workspace-settle-script-run"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let scriptStatus = app.staticTexts["workspace-settle-script-status"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Settle script finished", "Settle script finished"), object: scriptStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        let exitDetail = "Command exited with status 0."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", exitDetail, exitDetail)).element.exists)
        let outputDisclosure = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (identifier == %@ OR label == %@ OR title == %@)",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.disclosureTriangle.rawValue,
            "workspace-settle-script-output-disclosure", "Settle Script Output", "Settle Script Output"
        )).element
        XCTAssertTrue(outputDisclosure.waitForExistence(timeout: 10)); expandScriptOutputDisclosure(outputDisclosure)
        let output = app.staticTexts["workspace-settle-script-output"]
        let received = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label CONTAINS %@ OR value CONTAINS %@)", "native-settle-output", "native-settle-output"), object: output)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("settle-cwd.txt"), encoding: .utf8), worktreePath + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("settle-unselected.txt").path))
        XCTAssertTrue(settled.exists, "Successful script completion must not resume the conversation implicitly.")
        XCTAssertEqual(composer.value as? String, draft)
        capture(app, name: "settle-completed-script-still-settled-with-draft")
        let resume = app.buttons["settlement-resume"]
        XCTAssertTrue(resume.exists && resume.isEnabled && resume.isHittable); resume.click()
        XCTAssertTrue(waitForAbsence(settled, timeout: 10))
        XCTAssertTrue(waitForAbsence(scriptStatus, timeout: 5))
        assertWorkspaceReady(in: app)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(composer.value as? String, draft)
        assertConversationWorkspace(app, path: worktreePath)
        XCTAssertEqual(try Data(contentsOf: readme), readmeBytes)
        XCTAssertEqual(try Data(contentsOf: configuration), configurationBytes)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(".git/HEAD")), sourceHeadBytes)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "settle-source-final-head"), sourceHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("settle-cwd.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("settle-unselected.txt").path))
        capture(app, name: "settle-explicit-resume-keeps-draft-checkout-and-source")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testWorktreePreparationKeepsExplicitBaseDraftAndSourceFiles() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "worktree")
        let app = fixture.app
        let project = fixture.root.appendingPathComponent("Native Worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let readme = project.appendingPathComponent("README.md")
        let baseContents = "Committed explicit local base\n"
        try baseContents.write(to: readme, atomically: true, encoding: .utf8)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Explicit base fixture"], ["branch", "ui-base"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "worktree-base-\(arguments[0])")
        }
        let baseHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "worktree-base-head")
        try "Newer committed source checkout\n".write(to: readme, atomically: true, encoding: .utf8)
        for arguments in [["add", "README.md"], ["commit", "--message", "Newer source fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "worktree-source-\(arguments[0])")
        }
        let sourceHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "worktree-source-head")
        XCTAssertNotEqual(sourceHead, baseHead)
        let dirtyContents = "Keep these uncommitted source edits\n"
        try dirtyContents.write(to: readme, atomically: true, encoding: .utf8)
        let sentinel = project.appendingPathComponent("untracked-sentinel.txt"), sentinelBytes = Data("Keep this untracked source file\n".utf8)
        try sentinelBytes.write(to: sentinel)
        let sourceHeadFile = project.appendingPathComponent(".git/HEAD"), sourceHeadBytes = try Data(contentsOf: sourceHeadFile)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        let header = app.buttons["Collapse Native Worktree"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let draft = "Keep this unsent draft while preparing a separate checkout"
        composer.click(); composer.typeText(draft)
        let identifier = try selectedThreadIdentifier(in: app)
        assertConversationWorkspace(app, path: project.path)
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        workspace.click()
        let choose = app.menuItems["Choose Worktree…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.click()
        let review = app.sheets.containing(.textField, identifier: "worktree-new-branch").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let branch = review.textFields["worktree-new-branch"], base = review.textFields["worktree-base-ref"]
        XCTAssertTrue(branch.waitForExistence(timeout: 5)); branch.click(); branch.typeText("ui-native-worktree")
        XCTAssertEqual(base.value as? String, "HEAD")
        base.click(); base.typeKey("a", modifierFlags: .command); base.typeText("ui-base")
        let submodules = review.descendants(matching: .any).matching(identifier: "worktree-submodules").element
        XCTAssertTrue(submodules.waitForExistence(timeout: 5))
        XCTAssertEqual(submodules.value as? String, "None", "Submodule downloads must require an explicit choice.")
        let prepare = review.buttons["Prepare Worktree"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let display = CGDisplayBounds(CGMainDisplayID())
        XCTAssertTrue(display.contains(review.frame), "The taller native worktree sheet must fit the hosted display: \(review.frame).")
        for control in [branch, base, submodules, prepare, review.buttons["Cancel"]] {
            XCTAssertTrue(control.isHittable && review.frame.contains(control.frame) && display.contains(control.frame), "Every worktree choice must remain visible and interactive.")
        }
        submodules.click()
        for title in ["None", "Top level", "Recursive"] {
            let option = app.menuItems[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            XCTAssertTrue(option.isHittable && display.contains(option.frame), "Submodule options must fit the display.")
        }
        app.menuItems["None"].click()
        XCTAssertEqual(submodules.value as? String, "None")
        XCTAssertEqual(branch.value as? String, "ui-native-worktree"); XCTAssertEqual(base.value as? String, "ui-base")
        let choices = XCTAttachment(screenshot: review.screenshot()); choices.name = "worktree-explicit-base-and-safe-submodule-choice"; choices.lifetime = .keepAlways; add(choices)
        prepare.click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let managedRoot = fixture.root.appendingPathComponent("Worktrees", isDirectory: true)
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value BEGINSWITH %@", managedRoot.path + "/"), object: workspace)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 20), .completed)
        let checkoutPath = try XCTUnwrap(workspace.value as? String)
        XCTAssertTrue(checkoutPath.hasPrefix(managedRoot.path + "/"))
        let checkout = URL(fileURLWithPath: checkoutPath)
        XCTAssertNotEqual(checkout.path, project.path)
        assertWorkspaceReady(in: app)
        XCTAssertTrue(threadRow(identifier, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: checkout, configuration: fixture.configuration, name: "worktree-prepared-head"), baseHead)
        XCTAssertEqual(try runGit(["-C", checkout.path, "symbolic-ref", "--short", "HEAD"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "worktree-prepared-branch").trimmingCharacters(in: .whitespacesAndNewlines), "ui-native-worktree")
        XCTAssertEqual(try String(contentsOf: checkout.appendingPathComponent("README.md"), encoding: .utf8), baseContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("untracked-sentinel.txt").path))
        assertSidebarFitsDisplay(app, projectHeader: header, selectedConversation: threadRow(identifier, in: app))
        capture(app, name: "worktree-prepared-checkout-retains-draft")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10))
        assertConversationWorkspace(app, path: checkout.path)
        assertWorkspaceReady(in: app)
        XCTAssertTrue(threadRow(identifier, in: app).isSelected)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: checkout, configuration: fixture.configuration, name: "worktree-reopened-head"), baseHead)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "worktree-preserved-source-head"), sourceHead)
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), dirtyContents)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertEqual(try Data(contentsOf: sourceHeadFile), sourceHeadBytes)
        let inventory = try runGit(["-C", project.path, "worktree", "list", "--porcelain"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "worktree-reopened-inventory")
        let paths = inventory.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) }
        XCTAssertEqual(Set(paths), [project.path, checkout.path], "Restart must reuse the completed checkout without creating another worktree.")
        assertSidebarFitsDisplay(app, projectHeader: header, selectedConversation: threadRow(identifier, in: app))
        capture(app, name: "worktree-reopened-cwd-and-draft")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testNativePiHistoryQuestionsUseExactWorkerAndCancellationNeverSendsDraft() throws {
        let f = try preparePiHistoryGUI(mode: "controls", appearance: "light", name: "pi-history-controls")
        let sourceID = try seedPiHistoryGUI(f), source = try claudeGUIThread(privateWorkspaceSnapshot(f.root), id: sourceID)
        let native = URL(fileURLWithPath: try XCTUnwrap(source["providerThreadID"] as? String)), before = try Data(contentsOf: native)
        replaceClaudeGUIDraft("Keep the latest Pi draft 工作 😀", in: f.app)
        let sheet = try beginPiGUIRewind(f, prompt: Self.piBetaPrompt)
        let picker = try revealPiHistoryControl("pi-extension-choice", in: sheet)
        capture(f.app, name: "pi-history-native-select-question")
        picker.click(); let offered = f.app.menuItems["Keep inherited context"]
        XCTAssertTrue(offered.waitForExistence(timeout: 5)); offered.click()
        let submit = try revealPiHistoryControl("pi-extension-submit", in: sheet)
        XCTAssertTrue(submit.isEnabled); submit.click()
        XCTAssertTrue(sheet.staticTexts["Pi GUI final branch confirmation"].waitForExistence(timeout: 10))
        let held = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            guard let operation = self.latestPiGUIOperation(snapshot), let controls = operation["piControls"] as? [String: Any],
                  let requests = controls["requests"] as? [[String: Any]] else { return false }
            return operation["phase"] as? String == "dispatching" && requests.count == 1 &&
                ((requests[0]["request"] as? [String: Any])?["params"] as? [String: Any])?["title"] as? String == "Pi GUI final branch confirmation"
        }
        let generation = try XCTUnwrap((latestPiGUIOperation(held)?["piControls"] as? [String: Any])?["sessionID"] as? String)
        XCTAssertNotNil(UUID(uuidString: generation))
        let cancel = try revealPiHistoryControl("conversation-history-pi-cancel", in: sheet)
        XCTAssertTrue(cancel.isEnabled); cancel.click()
        _ = try waitForPrivateWorkspace(f.root, timeout: 20) { self.latestPiGUIOperation($0)?["phase"] as? String == "unconfirmed" }
        try waitForClaudeGUIEnabled(sheet.buttons["conversation-history-close"], timeout: 10)
        capture(f.app, name: "pi-history-cancelled-without-native-copy")
        let keep = try revealPiHistoryControl("conversation-history-pi-keep-original", in: sheet); keep.click()
        let confirm = f.app.sheets.containing(.button, identifier: "conversation-history-pi-keep-original-confirm").firstMatch.buttons["conversation-history-pi-keep-original-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
        _ = try waitForPrivateWorkspace(f.root, timeout: 20) { self.latestPiGUIOperation($0)?["phase"] as? String == "failed" }
        sheet.buttons["conversation-history-close"].click(); try nativeHistoryDone(in: f.app).click()
        XCTAssertTrue(waitForValue(f.app.textViews["composer-input"], value: "Keep the latest Pi draft 工作 😀", timeout: 10))
        let frames = try historyWire(f.wire)
        let answers = frames.filter { $0["type"] as? String == "extension_ui_response" }
        XCTAssertEqual(answers.count, 1); XCTAssertEqual(answers[0]["id"] as? String, "pi-gui-select")
        XCTAssertEqual(answers[0]["value"] as? String, "Keep inherited context")
        XCTAssertEqual(frames.filter { $0["type"] as? String == "fork" }.count, 1)
        XCTAssertTrue(frames.filter { $0["kind"] as? String == "fork-result" }.isEmpty)
        XCTAssertEqual(try piGUIPrompts(f), [Self.piAlphaPrompt, Self.piBetaPrompt])
        XCTAssertEqual(try Data(contentsOf: native), before)
        try assertPiGUIWorkspaceUnchanged(f)
    }

    @MainActor func testNativePiUnknownHistoryKeepsOriginalAcrossRestartWithoutRepeatingNativeFork() throws {
        let f = try preparePiHistoryGUI(mode: "publish-and-disconnect", appearance: "dark", name: "pi-history-unknown")
        let sourceID = try seedPiHistoryGUI(f), original = try claudeGUIThread(privateWorkspaceSnapshot(f.root), id: sourceID)
        let path = try XCTUnwrap(original["providerThreadID"] as? String), before = try Data(contentsOf: URL(fileURLWithPath: path))
        replaceClaudeGUIDraft("Keep original Pi draft after lost reply", in: f.app)
        let sheet = try beginPiGUIRewind(f, prompt: Self.piBetaPrompt)
        let unknown = try waitForPrivateWorkspace(f.root, timeout: 20) { self.latestPiGUIOperation($0)?["phase"] as? String == "unconfirmed" }
        XCTAssertNil(latestPiGUIOperation(unknown)?["piCandidates"], "A lost fork reply cannot invent a candidate identity.")
        let orphan = try XCTUnwrap(historyWire(f.wire).last { $0["kind"] as? String == "fork-result" })
        let orphanFile = URL(fileURLWithPath: try XCTUnwrap(orphan["candidateFile"] as? String))
        XCTAssertNotEqual(orphanFile.path, path); XCTAssertTrue(FileManager.default.fileExists(atPath: orphanFile.path))
        let orphanBytes = try Data(contentsOf: orphanFile)
        try waitForClaudeGUIEnabled(sheet.buttons["conversation-history-close"], timeout: 10)
        sheet.buttons["conversation-history-close"].click(); try nativeHistoryDone(in: f.app).click()
        XCTAssertEqual(try claudeGUIJSON(latestPiGUIOperation(privateWorkspaceSnapshot(f.root))), try claudeGUIJSON(latestPiGUIOperation(unknown)))
        f.app.typeKey("q", modifierFlags: .command); XCTAssertTrue(f.app.wait(for: .notRunning, timeout: 15))
        f.app.launch(); XCTAssertTrue(f.app.wait(for: .runningForeground, timeout: 15))
        XCTAssertEqual(try selectedThreadIdentifier(in: f.app), sourceID)
        let keep = f.app.buttons["conversation-history-pi-keep-original"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10)); keep.click()
        let confirm = f.app.sheets.containing(.button, identifier: "conversation-history-pi-keep-original-confirm").firstMatch.buttons["conversation-history-pi-keep-original-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
        let kept = try waitForPrivateWorkspace(f.root, timeout: 20) { self.latestPiGUIOperation($0)?["phase"] as? String == "failed" }
        let current = try claudeGUIThread(kept, id: sourceID), operation = try XCTUnwrap(latestPiGUIOperation(kept))
        XCTAssertTrue((operation["error"] as? String)?.contains("unrecorded result") == true)
        XCTAssertNil(operation["recalledAt"]); XCTAssertEqual(current["providerThreadID"] as? String, path)
        XCTAssertEqual(try claudeGUIJSON(current["messages"]), try claudeGUIJSON(original["messages"]))
        XCTAssertEqual(try claudeGUIJSON(current["runHistory"]), try claudeGUIJSON(original["runHistory"]))
        XCTAssertTrue(waitForValue(f.app.textViews["composer-input"], value: "Keep original Pi draft after lost reply", timeout: 10))
        XCTAssertEqual(try historyWire(f.wire).filter { $0["type"] as? String == "fork" }.count, 1)
        XCTAssertEqual(try piGUIPrompts(f), [Self.piAlphaPrompt, Self.piBetaPrompt])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertEqual(try Data(contentsOf: orphanFile), orphanBytes, "Keep Original cannot delete or rewrite an unrecorded native copy.")
        capture(f.app, name: "pi-history-original-kept-unrecorded-orphan-warning")
        try assertPiGUIWorkspaceUnchanged(f)
    }

    @MainActor func testNativePiEmptyContextRecoveryRequiresExplicitAcknowledgementAndNeverReplaysUnknownInput() throws {
        let f = try preparePiHistoryGUI(mode: "normal", appearance: "light", name: "pi-history-fresh")
        let sourceID = try seedPiHistoryGUI(f), original = try claudeGUIThread(privateWorkspaceSnapshot(f.root), id: sourceID)
        let originalFile = URL(fileURLWithPath: try XCTUnwrap(original["providerThreadID"] as? String)), before = try Data(contentsOf: originalFile)
        replaceClaudeGUIDraft("Latest Pi reset draft", in: f.app)
        let sheet = try beginPiGUIRewind(f, prompt: Self.piAlphaPrompt)
        let selected = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: sourceID) else { return false }
            return self.latestPiGUIOperation(snapshot)?["phase"] as? String == "applied" && thread["piFreshSessionIntent"] != nil
        }
        sheet.buttons["conversation-history-close"].click(); try nativeHistoryDone(in: f.app).click()
        let intent = try XCTUnwrap(claudeGUIThread(selected, id: sourceID)["piFreshSessionIntent"] as? [String: Any])
        let target = URL(fileURLWithPath: try XCTUnwrap(intent["nativeSessionFile"] as? String))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(waitForValue(f.app.textViews["composer-input"], value: "Latest Pi reset draft\n\n" + Self.piAlphaPrompt, timeout: 10))
        XCTAssertEqual(try piGUIPrompts(f), [Self.piAlphaPrompt, Self.piBetaPrompt])
        f.app.typeKey("q", modifierFlags: .command); XCTAssertTrue(f.app.wait(for: .notRunning, timeout: 15))
        f.app.launch(); XCTAssertTrue(f.app.wait(for: .runningForeground, timeout: 15))
        XCTAssertEqual(try claudeGUIJSON(claudeGUIThread(privateWorkspaceSnapshot(f.root), id: sourceID)["piFreshSessionIntent"]), try claudeGUIJSON(intent))
        try submitClaudeGUI(Self.piUnwrittenPrompt, in: f.app)
        let failed = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: sourceID), let run = self.findClaudeGUIRun(thread, prompt: Self.piUnwrittenPrompt) else { return false }
            return thread["activeRun"] == nil && thread["piFreshConsumerRunID"] as? String == run["id"] as? String && run["status"] as? String != "completed"
        }
        let failedThread = try claudeGUIThread(failed, id: sourceID), failedRun = try claudeGUIRun(failedThread, prompt: Self.piUnwrittenPrompt)
        let failedID = try XCTUnwrap(failedRun["id"] as? String), priorStatus = try XCTUnwrap(failedRun["status"] as? String)
        XCTAssertTrue(["failed", "unknown", "interrupted"].contains(priorStatus)); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        replaceClaudeGUIDraft("Keep typing after unknown Pi input", in: f.app)
        let inspect = f.app.buttons["conversation-history-pi-inspect-fresh"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 10)); inspect.click()
        let keep = f.app.buttons["conversation-history-pi-keep-empty"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10)); keep.click()
        let alert = f.app.sheets.containing(.button, identifier: "conversation-history-pi-keep-empty-confirm").firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "may have been processed", "may have been processed")).firstMatch.exists)
        let confirm = alert.buttons["conversation-history-pi-keep-empty-confirm"]
        XCTAssertTrue(confirm.exists); confirm.click()
        let acknowledged = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: sourceID), let audit = thread["piFreshContextResolutions"] as? [[String: Any]] else { return false }
            return thread["piFreshConsumerRunID"] == nil && audit.last?["consumerRunID"] as? String == failedID
        }
        let acknowledgedThread = try claudeGUIThread(acknowledged, id: sourceID)
        XCTAssertEqual(try claudeGUIJSON(acknowledgedThread["piFreshSessionIntent"]), try claudeGUIJSON(intent))
        XCTAssertEqual(acknowledgedThread["queuePaused"] as? Bool, true)
        XCTAssertEqual(try claudeGUIRun(acknowledgedThread, prompt: Self.piUnwrittenPrompt)["status"] as? String, priorStatus)
        XCTAssertTrue(waitForValue(f.app.textViews["composer-input"], value: "Keep typing after unknown Pi input", timeout: 10))
        XCTAssertEqual(try piGUIPrompts(f), [Self.piAlphaPrompt, Self.piBetaPrompt, Self.piUnwrittenPrompt])
        capture(f.app, name: "pi-fresh-unknown-explicit-empty-context-kept-no-replay")
        try submitClaudeGUI(Self.piNewPrompt, in: f.app)
        let completed = try completedPiGUI(f, threadID: sourceID, prompt: Self.piNewPrompt)
        XCTAssertNil(completed["piFreshSessionIntent"]); XCTAssertNil(completed["piFreshConsumerRunID"])
        let run = try claudeGUIRun(completed, prompt: Self.piNewPrompt), proof = try XCTUnwrap(run["pi"] as? [String: Any])
        let records = try Data(contentsOf: target).split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        XCTAssertEqual(records.count, 3); XCTAssertEqual(records[0]["id"] as? String, (proof["preparation"] as? [String: Any])?["nativeSessionID"] as? String)
        XCTAssertNotEqual(records[0]["id"] as? String, intent["originalNativeSessionID"] as? String)
        XCTAssertEqual(((records[1]["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String, Self.piNewPrompt)
        XCTAssertEqual(try piGUIPrompts(f), [Self.piAlphaPrompt, Self.piBetaPrompt, Self.piUnwrittenPrompt, Self.piNewPrompt])
        XCTAssertEqual(try Data(contentsOf: originalFile), before)
        try assertPiGUIWorkspaceUnchanged(f)
    }

    private static let piAlphaPrompt = "Pi GUI remember ALPHA 工作"
    private static let piBetaPrompt = "Pi GUI remember BETA مرحباً"
    private static let piUnwrittenPrompt = "Pi GUI explicit input with missing result"
    private static let piNewPrompt = "Pi GUI new explicit input after acknowledgement"
    private struct PiHistoryGUIFixture {
        let app: XCUIApplication, root: URL, project: URL, wire: URL, document: URL, original: Data, head: String, gitPath: String, gitConfiguration: URL
    }
    @MainActor private func preparePiHistoryGUI(mode: String, appearance: String, name: String) throws -> PiHistoryGUIFixture {
        let base = try prepareApplication(appearance: appearance, diagnosticPrefix: name), app = base.app, root = base.root
        let manager = FileManager.default, python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        let project = root.appendingPathComponent("Pi Native History"), bin = root.appendingPathComponent("private-bin")
        for directory in [project, bin] + ["private-pi-home", "private-pi-agent", "private-pi-sessions"].map({ root.appendingPathComponent($0) }) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let document = project.appendingPathComponent("README.md"), original = Data("Private Pi UI workspace remains unchanged\n".utf8)
        try original.write(to: document)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Pi native GUI fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: base.gitPath, configuration: base.configuration, name: name + "-git-" + arguments[0])
        }
        let head = try verifyHead(gitPath: base.gitPath, project: project, configuration: base.configuration, name: name + "-head")
        let state = root.appendingPathComponent("pi-peer.json"), wire = root.appendingPathComponent("pi-wire.jsonl")
        let actions = [Self.piAlphaPrompt: ["mode": "normal", "label": "ALPHA"], Self.piBetaPrompt: ["mode": "normal", "label": "BETA"],
            Self.piUnwrittenPrompt: ["mode": "before-write-disconnect", "label": "UNWRITTEN"], Self.piNewPrompt: ["mode": "normal", "label": "NEW"]]
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "historyMode": mode, "actions": actions], options: .sortedKeys).write(to: state, options: .atomic)
        let peer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "pi_history_ui", withExtension: "py"))
        let executable = try installOfflineCLI(tool: "pi", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        for (key, name) in [("HOME", "private-pi-home"), ("PI_CODING_AGENT_DIR", "private-pi-agent"), ("PI_CODING_AGENT_SESSION_DIR", "private-pi-sessions")] {
            app.launchEnvironment[key] = root.appendingPathComponent(name).path
        }
        try preflightPiGUI(executable, environment: app.launchEnvironment, cwd: project)
        addTeardownBlock { @MainActor [weak self] in
            if let data = try? Data(contentsOf: wire), data.count <= 131_072 {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = name + "-bounded-synthetic-wire"; attachment.lifetime = .keepAlways; self?.add(attachment)
            }
        }
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15)); try openProject(project, in: app)
        app.typeKey("n", modifierFlags: .command); XCTAssertTrue(app.textViews["composer-input"].waitForExistence(timeout: 10))
        return .init(app: app, root: root, project: project, wire: wire, document: document, original: original,
            head: head, gitPath: base.gitPath, gitConfiguration: base.configuration)
    }
    @MainActor private func seedPiHistoryGUI(_ f: PiHistoryGUIFixture) throws -> String {
        let provider = f.app.descendants(matching: .any).matching(identifier: "provider-model-menu").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10)); provider.click()
        let pi = f.app.menuItems["Pi"]; XCTAssertTrue(pi.waitForExistence(timeout: 5)); XCTAssertTrue(pi.isEnabled); pi.click()
        let id = try selectedThreadIdentifier(in: f.app)
        _ = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: id) else { return false }
            return thread["provider"] as? String == "pi" && (thread["piConfiguration"] as? [String: Any])?["runtime"] != nil
        }
        f.app.descendants(matching: .any).matching(identifier: "conversation-workspace").firstMatch.click()
        let checkpoints = f.app.menuItems["conversation-run-checkpoints"]
        XCTAssertTrue(checkpoints.waitForExistence(timeout: 5)); XCTAssertTrue(checkpoints.isEnabled); checkpoints.click()
        _ = try waitForPrivateWorkspace(f.root, timeout: 10) { self.findClaudeGUIThread($0, id: id)?["checkpointPolicy"] as? String == "disabled" }
        for prompt in [Self.piAlphaPrompt, Self.piBetaPrompt] { try submitClaudeGUI(prompt, in: f.app); _ = try completedPiGUI(f, threadID: id, prompt: prompt) }
        XCTAssertTrue(f.app.staticTexts["Pi GUI saved BETA"].waitForExistence(timeout: 10))
        return id
    }
    @MainActor private func completedPiGUI(_ f: PiHistoryGUIFixture, threadID: String, prompt: String) throws -> [String: Any] {
        let snapshot = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID), thread["activeRun"] == nil,
                  let run = self.findClaudeGUIRun(thread, prompt: prompt), let proof = run["pi"] as? [String: Any] else { return false }
            return run["status"] as? String == "completed" && proof["captureStatus"] as? String == "proven" && proof["terminalStatus"] as? String == "completed"
        }
        let thread = try claudeGUIThread(snapshot, id: threadID), run = try claudeGUIRun(thread, prompt: prompt)
        XCTAssertEqual((run["turnIDs"] as? [String])?.count, 0); XCTAssertNil(thread["activeRun"])
        XCTAssertEqual((run["pi"] as? [String: Any])?["openingUserEntryID"] as? String,
            ((run["pi"] as? [String: Any])?["nativeUserEntryIDs"] as? [String])?.first)
        return thread
    }
    @MainActor private func beginPiGUIRewind(_ f: PiHistoryGUIFixture, prompt: String) throws -> XCUIElement {
        try openNativeRunHistory(in: f.app)
        let run = try revealNativeHistoryRun(prompt: prompt, in: f.app), sheet = try openNativeHistoryAction(runID: run, kind: "rewind", in: f.app)
        let confirm = sheet.buttons["conversation-history-confirm"]
        try waitForClaudeGUIEnabled(confirm, timeout: 10); XCTAssertEqual(confirm.label, "Revert and Keep Changes"); confirm.click()
        return sheet
    }
    private func latestPiGUIOperation(_ snapshot: [String: Any]) -> [String: Any]? {
        (snapshot["conversationHistoryOperations"] as? [[String: Any]])?.last { ($0["review"] as? [String: Any])?["pi"] != nil }
    }
    private func piGUIPrompts(_ f: PiHistoryGUIFixture) throws -> [String] {
        try historyWire(f.wire).filter { $0["type"] as? String == "prompt" }.compactMap { $0["message"] as? String }
    }
    @MainActor private func revealPiHistoryControl(_ identifier: String, in sheet: XCUIElement) throws -> XCUIElement {
        let control = sheet.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        for _ in 0..<5 where !control.isHittable { sheet.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(control.isHittable); return control
    }
    @MainActor private func assertPiGUIWorkspaceUnchanged(_ f: PiHistoryGUIFixture) throws {
        XCTAssertEqual(try Data(contentsOf: f.document), f.original)
        XCTAssertEqual(try verifyHead(gitPath: f.gitPath, project: f.project, configuration: f.gitConfiguration, name: "pi-history-preserved-head"), f.head)
        let status = try runGit(["-C", f.project.path, "status", "--porcelain=v1"], gitPath: f.gitPath, configuration: f.gitConfiguration, name: "pi-history-preserved-index")
        XCTAssertTrue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    @MainActor private func preflightPiGUI(_ executable: URL, environment: [String: String], cwd: URL) throws {
        let version = try runPiGUIPreflight(executable, arguments: ["--version"], environment: environment, cwd: cwd, input: Data())
        XCTAssertEqual(String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "0.80.5")
        let frames: [[String: Any]] = [["type": "get_state", "id": "gui-preflight-state"], ["type": "get_entries", "id": "gui-preflight-entries"]]
        var input = Data()
        for frame in frames { input.append(try JSONSerialization.data(withJSONObject: frame)); input.append(10) }
        let output = try runPiGUIPreflight(executable, arguments: ["--mode", "rpc"], environment: environment, cwd: cwd, input: input)
        let replies = try output.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        XCTAssertEqual(replies.compactMap { $0["id"] as? String }, ["gui-preflight-state", "gui-preflight-entries"])
        XCTAssertTrue(replies.allSatisfy { $0["success"] as? Bool == true })
        let entries = try XCTUnwrap(replies.last?["data"] as? [String: Any])
        XCTAssertEqual((entries["entries"] as? [[String: Any]])?.count, 0); XCTAssertTrue(entries["leafId"] is NSNull)
    }
    @MainActor private func runPiGUIPreflight(_ executable: URL, arguments: [String], environment: [String: String], cwd: URL, input payload: Data) throws -> Data {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment; process.currentDirectoryURL = cwd
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        var stage = "configure-pipe"
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        do {
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            stage = "process-run"; try process.run()
            stage = "stdin-write"; if !payload.isEmpty { try input.fileHandleForWriting.write(contentsOf: payload) }
            try input.fileHandleForWriting.close()
            stage = "wait-for-eof"
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !process.isRunning }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 5), .completed, "The exact Pi fixture must exit after preflight EOF.")
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            stage = "read-response"
            let data = try output.fileHandleForReading.readToEnd() ?? Data(), stderr = try errors.fileHandleForReading.readToEnd() ?? Data()
            XCTAssertLessThanOrEqual(data.count, 65_536); XCTAssertLessThanOrEqual(stderr.count, 65_536)
            let evidence = XCTAttachment(string: "Exact immutable Pi helper preflight. stage=\(stage) exit=\(process.terminationStatus) stdoutBytes=\(data.count) stderrBytes=\(stderr.count)\nstderr:\n\(String(decoding: stderr.prefix(512), as: UTF8.self))")
            evidence.name = "pi-immutable-helper-\(arguments == ["--version"] ? "version" : "idle")-preflight"; evidence.lifetime = .keepAlways; add(evidence)
            XCTAssertEqual(process.terminationStatus, 0); return data
        } catch {
            let failure = error as NSError
            let evidence = XCTAttachment(string: "Exact immutable Pi helper failed with the fixture environment. stage=\(stage) NSError domain=\(failure.domain) code=\(failure.code)")
            evidence.name = "pi-immutable-helper-preflight-failure"; evidence.lifetime = .keepAlways; add(evidence)
            throw error
        }
    }

    @MainActor func testNativeClaudeForkAndDeferredRewindPreserveSourceWithoutSendingAcrossRestart() throws {
        let f = try prepareClaudeHistoryGUI(appearance: "light", name: "claude-history")
        let sourceID = try seedClaudeHistoryGUI(f)
        let source = try claudeGUIThread(privateWorkspaceSnapshot(f.root), id: sourceID)
        let nativeID = try XCTUnwrap(source["providerThreadID"] as? String)
        let sourceURL = try claudeGUITranscript(f, nativeID: nativeID)
        let originalDraft = "Keep my unsent Claude source draft"
        replaceClaudeGUIDraft(originalDraft, in: f.app)
        try openNativeRunHistory(in: f.app)
        let firstRun = try revealNativeHistoryRun(prompt: Self.claudeAlphaPrompt, in: f.app)
        var sheet = try openNativeHistoryAction(runID: firstRun, kind: "fork", in: f.app)
        XCTAssertTrue(sheet.buttons["conversation-history-confirm"].waitForExistence(timeout: 10))
        // A review drains its owned peer before capturing this exact baseline.
        let sourceBytes = try Data(contentsOf: sourceURL)
        let inputCount = try claudeGUIWire(f, method: "user").count
        sheet.buttons["conversation-history-close"].click()
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        XCTAssertEqual(try claudeGUIWire(f, method: "user").count, inputCount)
        sheet = try openNativeHistoryAction(runID: firstRun, kind: "fork", in: f.app)
        let title = sheet.textFields["conversation-history-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click(); title.typeKey("a", modifierFlags: .command)
        title.typeText("Claude native ALPHA fork")
        let confirm = sheet.buttons["conversation-history-confirm"]
        try waitForClaudeGUIEnabled(confirm, timeout: 10)
        capture(f.app, name: "claude-history-native-fork-glass-review")
        confirm.click()
        XCTAssertTrue(waitForAbsence(sheet.buttons["conversation-history-close"], timeout: 20))
        let forkID = try selectedThreadIdentifier(in: f.app)
        XCTAssertNotEqual(forkID, sourceID)
        let forkSnapshot = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
            guard let target = self.findClaudeGUIThread(snapshot, id: forkID) else { return false }
            return target["claudeInheritedHead"] as? [String: Any] != nil && target["forkedFromHistoryOperationID"] as? String != nil
        }
        let target = try claudeGUIThread(forkSnapshot, id: forkID)
        let operationID = try XCTUnwrap(target["forkedFromHistoryOperationID"] as? String)
        let operation = try XCTUnwrap((forkSnapshot["conversationHistoryOperations"] as? [[String: Any]])?.first {
            ($0["review"] as? [String: Any])?["id"] as? String == operationID
        })
        XCTAssertEqual(operation["phase"] as? String, "applied")
        let publication = try XCTUnwrap(operation["claudeForkPublication"] as? [String: Any])
        let mapping = try XCTUnwrap(publication["sourceToForkMessageIDs"] as? [String: String])
        let forkNativeID = try XCTUnwrap(target["providerThreadID"] as? String)
        XCTAssertNotEqual(forkNativeID, nativeID)
        let originalRecords = try claudeGUIRecords(sourceURL)
        let copied = try claudeGUIRecords(claudeGUITranscript(f, nativeID: forkNativeID))
        XCTAssertEqual(copied.count, 2, "Fork after ALPHA copies exactly its actual native root user and assistant.")
        for (original, copy) in zip(originalRecords.prefix(2), copied) {
            let originalID = try XCTUnwrap(original["uuid"] as? String)
            XCTAssertEqual(copy["uuid"] as? String, mapping[originalID])
            XCTAssertNotEqual(copy["uuid"] as? String, originalID)
            XCTAssertEqual(copy["sessionId"] as? String, forkNativeID)
            XCTAssertEqual(try claudeGUIJSON(copy["message"]), try claudeGUIJSON(original["message"]))
        }
        XCTAssertEqual((target["claudeInheritedHead"] as? [String: Any])?["cursor"] as? String, copied.last?["uuid"] as? String)
        XCTAssertTrue(f.app.staticTexts["Claude GUI saved ALPHA"].exists)
        XCTAssertFalse(f.app.staticTexts["Claude GUI saved BETA"].exists)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        XCTAssertEqual(try claudeGUIWire(f, method: "user").count, 2, "Opening a fork must not send a model input.")
        selectThread(sourceID, in: f.app)
        XCTAssertTrue(waitForValue(f.app.textViews["composer-input"], value: originalDraft, timeout: 10))
        let selection = try saveClaudeGUIResume(f, threadID: sourceID)
        XCTAssertEqual(selection["nativeSessionID"] as? String, nativeID)
        XCTAssertEqual(selection["kind"] as? String, "resumeAt")
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        let expectedDraft = originalDraft + "\n\n" + Self.claudeBetaPrompt
        XCTAssertTrue(waitForValue(f.app.textViews["composer-input"], value: expectedDraft, timeout: 10))
        let selectionBytes = try claudeGUIJSON(selection)
        let launches = try claudeGUIWire(f, method: "launch").count
        capture(f.app, name: "claude-history-deferred-native-context-no-send")
        f.app.typeKey("q", modifierFlags: .command); XCTAssertTrue(f.app.wait(for: .notRunning, timeout: 15))
        f.app.launch(); XCTAssertTrue(f.app.wait(for: .runningForeground, timeout: 15))
        XCTAssertEqual(try selectedThreadIdentifier(in: f.app), sourceID)
        XCTAssertTrue(waitForValue(f.app.textViews["composer-input"], value: expectedDraft, timeout: 10))
        try assertClaudeGUIPendingBanner(f.app)
        let reopened = try claudeGUIThread(privateWorkspaceSnapshot(f.root), id: sourceID)
        XCTAssertEqual(try claudeGUIJSON(reopened["claudeResumeSelection"]), selectionBytes)
        XCTAssertNil(reopened["claudeResumeConsumerRunID"])
        XCTAssertEqual(try claudeGUIWire(f, method: "user").count, 2)
        XCTAssertEqual(try claudeGUIWire(f, method: "launch").count, launches)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        selectThread(forkID, in: f.app)
        XCTAssertTrue(f.app.staticTexts["Claude GUI saved ALPHA"].waitForExistence(timeout: 5))
        XCTAssertFalse(f.app.staticTexts["Claude GUI saved BETA"].exists)
        XCTAssertNil(try claudeGUIThread(privateWorkspaceSnapshot(f.root), id: forkID)["claudeResumeSelection"])
        try assertClaudeGUIWorkspaceUnchanged(f)
    }

    @MainActor func testNativeClaudeSelectedContextIsConsumedOnceBeforeQueuedSuccessor() throws {
        let f = try prepareClaudeHistoryGUI(appearance: "dark", name: "claude-selected-fifo")
        let sourceID = try seedClaudeHistoryGUI(f)
        let selection = try saveClaudeGUIResume(f, threadID: sourceID)
        let selectionID = try XCTUnwrap(selection["id"] as? String), cursor = try XCTUnwrap(selection["cursor"] as? String)
        try submitClaudeGUI(Self.claudeProbePrompt, in: f.app)
        let held = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: sourceID),
                  let active = thread["activeRun"] as? [String: Any],
                  let config = active["configuration"] as? [String: Any] else { return false }
            return (config["claudeLaunchSelection"] as? [String: Any])?["id"] as? String == selectionID &&
                thread["claudeResumeConsumerRunID"] as? String == active["id"] as? String
        }
        let heldThread = try claudeGUIThread(held, id: sourceID)
        let firstRunID = try XCTUnwrap((heldThread["activeRun"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(f.app.staticTexts["Claude GUI probe context ALPHA"].waitForExistence(timeout: 20))
        XCTAssertFalse(f.app.staticTexts["Claude GUI probe context ALPHA BETA"].exists)
        XCTAssertTrue(f.app.staticTexts["This Claude turn is using the saved context. Its selection remains recorded until the matching turn is confirmed."].exists)
        replaceClaudeGUIDraft(Self.claudeQueuedPrompt, in: f.app)
        let delivery = f.app.descendants(matching: .any).matching(identifier: "composer-delivery").firstMatch
        XCTAssertTrue(delivery.waitForExistence(timeout: 5)); XCTAssertTrue(delivery.isHittable); delivery.click()
        let queue = f.app.menuItems["Queue Message"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5)); XCTAssertTrue(queue.isEnabled && queue.isHittable); queue.click()
        let queued = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: sourceID),
                  let rows = thread["queuedTurns"] as? [[String: Any]], rows.count == 1 else { return false }
            return rows[0]["text"] as? String == Self.claudeQueuedPrompt
        }
        let queuedThread = try claudeGUIThread(queued, id: sourceID)
        let accepted = try XCTUnwrap((queuedThread["queuedTurns"] as? [[String: Any]])?.first)
        let queuedConfiguration = try XCTUnwrap(accepted["configuration"] as? [String: Any])
        XCTAssertNil(queuedConfiguration["claudeLaunchSelection"])
        XCTAssertEqual(queuedConfiguration["provider"] as? String, "claude")
        XCTAssertEqual(queuedConfiguration["permission"] as? String, "supervised")
        XCTAssertEqual(queuedConfiguration["workspacePath"] as? String, f.project.path)
        XCTAssertEqual(accepted["checkpointPolicy"] as? String, "disabled")
        XCTAssertEqual((queuedThread["activeRun"] as? [String: Any])?["id"] as? String, firstRunID)
        XCTAssertTrue(f.app.staticTexts["1 queued"].exists)
        XCTAssertEqual(try claudeGUIWire(f, method: "user").filter { $0["action"] as? String == "queued" }.count, 0)
        let probe = try XCTUnwrap(claudeGUIWire(f, method: "user").first { $0["action"] as? String == "probe" })
        XCTAssertEqual(probe["parentID"] as? String, cursor)
        XCTAssertEqual(probe["inputID"] as? String, firstRunID.lowercased())
        XCTAssertEqual(probe["contextAlpha"] as? Bool, true); XCTAssertEqual(probe["contextBeta"] as? Bool, false)
        let selectedLaunches = try claudeGUIWire(f, method: "launch").filter { $0["selection"] as? String == "resumeAt" }
        XCTAssertEqual(selectedLaunches.count, 1); XCTAssertEqual(selectedLaunches.first?["cursor"] as? String, cursor)
        capture(f.app, name: "claude-selected-fifo-held-exact-native-terminal")
        let releaseTemporary = f.root.appendingPathComponent("selected-release-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: releaseTemporary) }
        try Data("release\n".utf8).write(to: releaseTemporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: releaseTemporary.path)
        try FileManager.default.moveItem(at: releaseTemporary, to: f.root.appendingPathComponent("release-selected"))
        let finished = try completedClaudeGUI(f, threadID: sourceID, prompt: Self.claudeQueuedPrompt)
        XCTAssertNil(finished["claudeResumeSelection"]); XCTAssertNil(finished["claudeResumeConsumerRunID"])
        XCTAssertTrue((finished["queuedTurns"] as? [[String: Any]])?.isEmpty == true)
        let first = try claudeGUIRun(finished, prompt: Self.claudeProbePrompt)
        XCTAssertEqual(first["status"] as? String, "completed")
        XCTAssertEqual((first["claude"] as? [String: Any])?["terminalStatus"] as? String, "completed")
        XCTAssertEqual(try claudeGUIJSON((first["configuration"] as? [String: Any])?["claudeLaunchSelection"]), try claudeGUIJSON(selection))
        let second = try claudeGUIRun(finished, prompt: Self.claudeQueuedPrompt)
        XCTAssertNil((second["configuration"] as? [String: Any])?["claudeLaunchSelection"])
        let consumedQueueConfiguration = try XCTUnwrap(second["configuration"] as? [String: Any])
        XCTAssertEqual(try claudeGUIJSON(consumedQueueConfiguration["claudeRuntimeConfiguration"]),
                       try claudeGUIJSON(queuedConfiguration["claudeRuntimeConfiguration"]))
        for key in ["model", "permission", "workspacePath"] {
            XCTAssertEqual(try claudeGUIJSON(consumedQueueConfiguration[key]), try claudeGUIJSON(queuedConfiguration[key]))
        }
        let frames = try historyWire(f.wire), users = frames.filter { $0["method"] as? String == "user" }
        XCTAssertEqual(users.count, 4)
        XCTAssertEqual(users.map { $0["action"] as? String }, ["alpha", "beta", "probe", "queued"])
        let terminalIndex = try XCTUnwrap(frames.firstIndex { $0["method"] as? String == "result" && $0["inputID"] as? String == firstRunID.lowercased() })
        let queuedIndex = try XCTUnwrap(frames.firstIndex { $0["method"] as? String == "user" && $0["action"] as? String == "queued" })
        XCTAssertLessThan(terminalIndex, queuedIndex)
        let secondUser = try XCTUnwrap(users.last)
        let secondLaunch = try XCTUnwrap(frames.first { $0["method"] as? String == "launch" && $0["launchID"] as? String == secondUser["launchID"] as? String })
        XCTAssertEqual(secondLaunch["selection"] as? String, "resume"); XCTAssertNil(secondLaunch["cursor"] as? String)
        let firstAssistant = try XCTUnwrap((first["claude"] as? [String: Any])?["rootAssistantMessageIDs"] as? [String]).last
        XCTAssertEqual(secondUser["parentID"] as? String, firstAssistant)
        XCTAssertEqual(try claudeGUIWire(f, method: "launch").filter { $0["selection"] as? String == "resumeAt" }.count, 1)
        XCTAssertTrue(f.app.staticTexts["Claude GUI queued context ALPHA"].waitForExistence(timeout: 10))
        try assertClaudeGUIWorkspaceUnchanged(f)
    }

    @MainActor func testNativeClaudeContextInspectionIsReadOnlyAndNeverReplaysConsumedOrUnwrittenInput() throws {
        let f = try prepareClaudeHistoryGUI(appearance: "light", name: "claude-context-inspection")
        for consumed in [true, false] {
            let threadID = try seedClaudeHistoryGUI(f, newThread: !consumed)
            let selection = try saveClaudeGUIResume(f, threadID: threadID)
            let prompt = consumed ? Self.claudeConsumedPrompt : Self.claudeUnwrittenPrompt
            try submitClaudeGUI(prompt, in: f.app)
            let failed = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
                guard let thread = self.findClaudeGUIThread(snapshot, id: threadID), thread["activeRun"] == nil,
                      let run = self.findClaudeGUIRun(thread, prompt: prompt) else { return false }
                return run["status"] as? String == "failed" && thread["claudeResumeConsumerRunID"] as? String == run["id"] as? String
            }
            let failedThread = try claudeGUIThread(failed, id: threadID)
            XCTAssertEqual(try claudeGUIJSON(failedThread["claudeResumeSelection"]), try claudeGUIJSON(selection))
            let nativeID = try XCTUnwrap(failedThread["providerThreadID"] as? String)
            let transcript = try claudeGUITranscript(f, nativeID: nativeID), bytes = try Data(contentsOf: transcript)
            let records = try claudeGUIRecords(transcript), run = try claudeGUIRun(failedThread, prompt: prompt)
            let opening = try XCTUnwrap((run["claude"] as? [String: Any])?["openingInputID"] as? String)
            XCTAssertEqual(records.contains { $0["type"] as? String == "user" && $0["uuid"] as? String == opening }, consumed)
            if consumed {
                // A fresh app must reconstruct the same persisted consumer hold.
                f.app.typeKey("q", modifierFlags: .command); XCTAssertTrue(f.app.wait(for: .notRunning, timeout: 15))
                f.app.launch(); XCTAssertTrue(f.app.wait(for: .runningForeground, timeout: 15))
            }
            let inspect = f.app.buttons["conversation-history-inspect-claude-context"]
            XCTAssertTrue(inspect.waitForExistence(timeout: 10)); XCTAssertTrue(inspect.isEnabled && inspect.isHittable)
            XCTAssertTrue(f.app.staticTexts["Claude’s use of the selected context could not be confirmed. Inspect it before starting another turn. No input will be replayed."].exists)
            let inputs = try claudeGUIWire(f, method: "user").count, launches = try claudeGUIWire(f, method: "launch").count
            let unsent = "Keep this nonempty draft until read-only Claude inspection"
            replaceClaudeGUIDraft(unsent, in: f.app)
            XCTAssertFalse(f.app.buttons["composer-send"].isEnabled, "A nonempty explicit draft remains held until the exact consumer is inspected.")
            capture(f.app, name: consumed ? "claude-context-consumed-inspection-hold" : "claude-context-unwritten-inspection-hold")
            inspect.click()
            let inspected = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
                guard let thread = self.findClaudeGUIThread(snapshot, id: threadID) else { return false }
                return thread["claudeResumeConsumerRunID"] == nil &&
                    (consumed ? thread["claudeResumeSelection"] == nil : thread["claudeResumeSelection"] as? [String: Any] != nil)
            }
            XCTAssertTrue(waitForAbsence(inspect, timeout: 10))
            let current = try claudeGUIThread(inspected, id: threadID)
            XCTAssertEqual(try Data(contentsOf: transcript), bytes)
            XCTAssertEqual(try claudeGUIWire(f, method: "user").count, inputs)
            XCTAssertEqual(try claudeGUIWire(f, method: "launch").count, launches, "Inspect reads native files and must not construct another provider.")
            XCTAssertEqual((current["runHistory"] as? [[String: Any]])?.count, 3)
            XCTAssertTrue(waitForValue(f.app.textViews["composer-input"], value: unsent, timeout: 5))
            if consumed {
                XCTAssertNil(current["claudeResumeSelection"])
            } else {
                XCTAssertEqual(try claudeGUIJSON(current["claudeResumeSelection"]), try claudeGUIJSON(selection))
                try assertClaudeGUIPendingBanner(f.app)
                try submitClaudeGUI(Self.claudeRetryPrompt, in: f.app)
                let retried = try completedClaudeGUI(f, threadID: threadID, prompt: Self.claudeRetryPrompt)
                XCTAssertNil(retried["claudeResumeSelection"]); XCTAssertNil(retried["claudeResumeConsumerRunID"])
                let retry = try XCTUnwrap(claudeGUIWire(f, method: "user").last)
                XCTAssertEqual(retry["action"] as? String, "retry")
                XCTAssertNotEqual(retry["inputID"] as? String, opening)
                XCTAssertEqual(retry["parentID"] as? String, selection["cursor"] as? String)
                XCTAssertEqual(try claudeGUIWire(f, method: "user").count, inputs + 1)
                XCTAssertEqual(try claudeGUIRecords(transcript).filter { $0["uuid"] as? String == opening }.count, 0)
            }
        }
        XCTAssertEqual(try claudeGUIWire(f, method: "user").filter { $0["action"] as? String == "consumed" }.count, 1)
        XCTAssertEqual(try claudeGUIWire(f, method: "user").filter { $0["action"] as? String == "unwritten" }.count, 1)
        try assertClaudeGUIWorkspaceUnchanged(f)
    }

    private static let claudeAlphaPrompt = "Remember the native marker ALPHA."
    private static let claudeBetaPrompt = "Remember the native marker BETA."
    private static let claudeProbePrompt = "Probe the selected native context."
    private static let claudeQueuedPrompt = "Continue the queued native context."
    private static let claudeConsumedPrompt = "Inspect consumed native context."
    private static let claudeUnwrittenPrompt = "Inspect unconsumed native context."
    private static let claudeRetryPrompt = "Retry selected native context explicitly."
    private struct ClaudeHistoryGUIFixture {
        let app: XCUIApplication
        let root: URL
        let project: URL
        let configuration: URL
        let wire: URL
        let document: URL
        let original: Data
        let head: String
        let gitPath: String
        let gitConfiguration: URL
    }
    @MainActor func testNativeClaudeQuestionSingleMultiCustomNotesAndCancellationPersistExactAnswers() throws {
        let f = try prepareClaudeHistoryGUI(appearance: "light", name: "claude-questions", questionWorkflow: true)
        let app = f.app
        let provider = app.descendants(matching: .any).matching(identifier: "provider-model-menu").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10)); provider.click()
        let claude = app.menuItems["Claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5) && claude.isEnabled); claude.click()
        let threadID = try selectedThreadIdentifier(in: app)
        _ = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID) else { return false }
            return thread["provider"] as? String == "claude" && thread["claudeRuntimeConfiguration"] != nil
        }
        app.descendants(matching: .any).matching(identifier: "conversation-workspace").firstMatch.click()
        let checkpoints = app.menuItems["conversation-run-checkpoints"]
        XCTAssertTrue(checkpoints.waitForExistence(timeout: 5) && checkpoints.isEnabled); checkpoints.click()
        _ = try waitForPrivateWorkspace(f.root, timeout: 10) { self.findClaudeGUIThread($0, id: threadID)?["checkpointPolicy"] as? String == "disabled" }
        for label in ["single", "multi", "cancel"] {
            let prompt = "Exercise native Claude question " + label
            try submitClaudeGUI(prompt, in: app)
            let submit = app.buttons["claude-question-submit"], cancel = app.buttons["claude-question-cancel"]
            XCTAssertTrue(submit.waitForExistence(timeout: 10)); XCTAssertFalse(submit.isEnabled)
            XCTAssertTrue(cancel.isHittable)
            if label == "cancel" { cancel.click() }
            else {
                let alpha = app.checkBoxes["Alpha"], beta = app.checkBoxes["Beta"]
                XCTAssertTrue(alpha.waitForExistence(timeout: 5) && beta.exists)
                try revealClaudeGUIQuestionControl(beta, in: app); beta.click()
                let initiallyChecked = (beta.value as? NSNumber)?.intValue ?? Int((beta.value as? String) ?? "")
                XCTAssertEqual(initiallyChecked, 1)
                try revealClaudeGUIQuestionControl(alpha, in: app); alpha.click()
                let betaChecked = (beta.value as? NSNumber)?.intValue ?? Int((beta.value as? String) ?? "")
                XCTAssertEqual(betaChecked, label == "single" ? 0 : 1)
                try enterClaudeGUIQuestionText("Other literal answer", label: "Other answer for Answer", in: app)
                try enterClaudeGUIQuestionText("Exact native notes", label: "Notes for Answer", in: app)
                try waitForClaudeGUIEnabled(submit, timeout: 5); XCTAssertTrue(submit.isHittable)
                capture(app, name: "claude-question-" + label + "-explicit-controls")
                submit.click()
            }
            _ = try completedClaudeGUI(f, threadID: threadID, prompt: prompt)
            XCTAssertTrue(waitForAbsence(submit, timeout: 5))
            let receipt = try XCTUnwrap(claudeGUIWire(f, method: "question_answer").last)
            XCTAssertEqual(receipt["label"] as? String, label)
            let decision = try XCTUnwrap(receipt["decision"] as? [String: Any])
            XCTAssertEqual(decision["behavior"] as? String, label == "cancel" ? "deny" : "allow")
            if label != "cancel" {
                let input = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
                XCTAssertEqual(input["answers"] as? [String: String], ["Which literal choices?": label == "single" ? "Other literal answer" : "Alpha, Beta, Other literal answer"])
                XCTAssertEqual((input["annotations"] as? [String: [String: String]])?["Which literal choices?"]?["notes"], "Exact native notes")
            }
        }
        XCTAssertEqual(try claudeGUIWire(f, method: "question_answer").count, 3)
        let before = try claudeGUIThread(privateWorkspaceSnapshot(f.root), id: threadID)
        let history = try claudeGUIJSON(before["runHistory"])
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.textViews["composer-input"].waitForExistence(timeout: 10))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        _ = try waitForPrivateWorkspace(f.root, timeout: 10) { self.findClaudeGUIThread($0, id: threadID)?["activeRun"] == nil }
        XCTAssertEqual(try claudeGUIJSON(claudeGUIThread(privateWorkspaceSnapshot(f.root), id: threadID)["runHistory"]), history)
        XCTAssertEqual(try claudeGUIWire(f, method: "question_answer").count, 3)
        try assertClaudeGUIWorkspaceUnchanged(f)
    }

    @MainActor private func revealClaudeGUIQuestionControl(_ control: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        let matches = app.scrollViews.containing(.checkBox, identifier: "Alpha")
        XCTAssertEqual(matches.count, 1)
        let scroll = matches.element
        for _ in 0..<8 {
            // SwiftUI can report a clipped descendant hittable at its layout
            // frame, even when that point belongs to the composer underneath.
            // Allow only the native control border's one-point frame overhang,
            // including the final field at the bottom scroll limit.
            let viewport = scroll.frame.insetBy(dx: -2, dy: -2), frame = control.frame
            if control.isEnabled && control.isHittable && frame.width > 0 && frame.height > 0 && viewport.contains(frame) { return }
            let delta: CGFloat
            if frame.minY < viewport.minY { delta = min(80, viewport.minY - frame.minY + 4) }
            else { delta = -min(80, max(4, frame.maxY - viewport.maxY + 4)) }
            scroll.scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTFail("The exact Claude question control must be visible inside its question viewport before interaction.")
        throw NSError(domain: "CoincideDesktopUITests", code: 2)
    }

    @MainActor private func enterClaudeGUIQuestionText(_ text: String, label: String, in app: XCUIApplication) throws {
        let field = app.textFields.matching(NSPredicate(format: "label == %@", label)).element
        try revealClaudeGUIQuestionControl(field, in: app)
        field.click()
        let keyboardFocus = NSPredicate(format: "hasKeyboardFocus == true")
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            keyboardFocus.evaluate(with: field) || field.descendants(matching: .any).matching(keyboardFocus).count > 0
        }, object: field)
        guard XCTWaiter.wait(for: [focused], timeout: 5) == .completed else {
            XCTFail("The revealed Claude question field must own keyboard focus before typing.")
            throw NSError(domain: "CoincideDesktopUITests", code: 2)
        }
        field.typeText(text)
        XCTAssertTrue(waitForValue(field, value: text, timeout: 5))
    }

    @MainActor private func prepareClaudeHistoryGUI(appearance: String, name: String, questionWorkflow: Bool = false) throws -> ClaudeHistoryGUIFixture {
        let base = try prepareApplication(appearance: appearance, diagnosticPrefix: name)
        let app = base.app, root = base.root, manager = FileManager.default
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        let project = root.appendingPathComponent("Claude Native History", isDirectory: true)
        let bin = root.appendingPathComponent("private-bin", isDirectory: true)
        let config = root.appendingPathComponent("private-claude-config", isDirectory: true)
        let home = root.appendingPathComponent("private-claude-home", isDirectory: true)
        for directory in [project, bin, config, home] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let document = project.appendingPathComponent("README.md"), original = Data("Synthetic Claude GUI history must preserve this checkout.\n".utf8)
        try original.write(to: document)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Claude native GUI fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: base.gitPath, configuration: base.configuration, name: name + "-git-" + arguments[0])
        }
        let head = try verifyHead(gitPath: base.gitPath, project: project, configuration: base.configuration, name: name + "-head")
        let state = root.appendingPathComponent("claude-peer.json"), wire = root.appendingPathComponent("claude-wire.jsonl")
        var actions: [String: [String: String]] = [
            Self.claudeAlphaPrompt: ["mode": "normal", "label": "alpha"], Self.claudeBetaPrompt: ["mode": "normal", "label": "beta"],
            Self.claudeProbePrompt: ["mode": "hold-result", "label": "probe", "gate": "release-selected"],
            Self.claudeQueuedPrompt: ["mode": "normal", "label": "queued"],
            Self.claudeConsumedPrompt: ["mode": "consume-then-disconnect", "label": "consumed"],
            Self.claudeUnwrittenPrompt: ["mode": "before-write-disconnect", "label": "unwritten"],
            Self.claudeRetryPrompt: ["mode": "normal", "label": "retry"]]
        if questionWorkflow {
            for label in ["single", "multi", "cancel"] {
                actions["Exercise native Claude question " + label] = ["mode": "questions", "label": label]
            }
        }
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "configurationDirectory": config.path, "actions": actions], options: .sortedKeys)
            .write(to: state, options: .atomic)
        let peer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "claude_history_ui", withExtension: "py"))
        _ = try installOfflineCLI(tool: "claude", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        app.launchEnvironment["HOME"] = home.path; app.launchEnvironment["CLAUDE_CONFIG_DIR"] = config.path
        app.launchEnvironment["CLAUDE_CODE_PROJECT_DIR_NAME"] = "coincide-claude-ui"
        app.launchEnvironment["CLAUDE_CODE_DISABLE_PRECOMPACT_SKIP"] = ""
        addTeardownBlock { @MainActor [weak self] in
            if let data = try? Data(contentsOf: wire), data.count <= 131_072 {
                let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                receipt.name = name + "-bounded-synthetic-wire"; receipt.lifetime = .keepAlways; self?.add(receipt)
            }
        }
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app); app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textViews["composer-input"].waitForExistence(timeout: 10))
        return .init(app: app, root: root, project: project, configuration: config, wire: wire,
                     document: document, original: original, head: head, gitPath: base.gitPath, gitConfiguration: base.configuration)
    }
    @MainActor private func seedClaudeHistoryGUI(_ f: ClaudeHistoryGUIFixture, newThread: Bool = false) throws -> String {
        let app = f.app
        if newThread {
            let previous = try selectedThreadIdentifier(in: app)
            app.typeKey("n", modifierFlags: .command)
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let rows = self.threadRows(in: app).allElementsBoundByIndex.filter { $0.isSelected }
                guard rows.count == 1 else { return false }
                let ids = rows[0].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "thread-")).allElementsBoundByIndex.map(\.identifier)
                return !ids.isEmpty && !ids.contains(previous)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        }
        let provider = app.descendants(matching: .any).matching(identifier: "provider-model-menu").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10)); provider.click()
        let claude = app.menuItems["Claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5)); XCTAssertTrue(claude.isEnabled); claude.click()
        let threadID = try selectedThreadIdentifier(in: app)
        _ = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID) else { return false }
            return thread["provider"] as? String == "claude" && thread["claudeRuntimeConfiguration"] as? [String: Any] != nil
        }
        app.descendants(matching: .any).matching(identifier: "conversation-workspace").firstMatch.click()
        let checkpoints = app.menuItems["conversation-run-checkpoints"]
        XCTAssertTrue(checkpoints.waitForExistence(timeout: 5)); XCTAssertTrue(checkpoints.isEnabled); checkpoints.click()
        _ = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID) else { return false }
            return thread["checkpointPolicy"] as? String == "disabled" && thread["permission"] as? String == "supervised"
        }
        for prompt in [Self.claudeAlphaPrompt, Self.claudeBetaPrompt] {
            try submitClaudeGUI(prompt, in: app)
            _ = try completedClaudeGUI(f, threadID: threadID, prompt: prompt)
        }
        XCTAssertTrue(app.staticTexts["Claude GUI saved BETA"].waitForExistence(timeout: 10))
        return threadID
    }
    @MainActor private func saveClaudeGUIResume(_ f: ClaudeHistoryGUIFixture, threadID: String) throws -> [String: Any] {
        try openNativeRunHistory(in: f.app)
        let runID = try revealNativeHistoryRun(prompt: Self.claudeBetaPrompt, in: f.app)
        let sheet = try openNativeHistoryAction(runID: runID, kind: "rewind", in: f.app)
        let confirm = sheet.buttons["conversation-history-confirm"]
        try waitForClaudeGUIEnabled(confirm, timeout: 10); XCTAssertEqual(confirm.label, "Save Resume Point")
        XCTAssertTrue(sheet.descendants(matching: .any).matching(identifier: "conversation-history-claude-context-selection").firstMatch.exists)
        let native = try XCTUnwrap(claudeGUIThread(privateWorkspaceSnapshot(f.root), id: threadID)["providerThreadID"] as? String)
        let source = try claudeGUITranscript(f, nativeID: native), bytes = try Data(contentsOf: source)
        let inputs = try claudeGUIWire(f, method: "user").count
        confirm.click()
        let applied = sheet.staticTexts.matching(identifier: "conversation-history-operation-status")
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Claude resume point saved", "Claude resume point saved")).firstMatch
        XCTAssertTrue(applied.waitForExistence(timeout: 20))
        sheet.buttons["conversation-history-close"].click(); try nativeHistoryDone(in: f.app).click()
        let snapshot = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID) else { return false }
            return thread["claudeResumeSelection"] as? [String: Any] != nil && thread["claudeResumeConsumerRunID"] == nil
        }
        let thread = try claudeGUIThread(snapshot, id: threadID)
        let selection = try XCTUnwrap(thread["claudeResumeSelection"] as? [String: Any])
        let operation = try XCTUnwrap((snapshot["conversationHistoryOperations"] as? [[String: Any]])?.first {
            ($0["review"] as? [String: Any])?["id"] as? String == selection["id"] as? String
        })
        XCTAssertEqual(operation["phase"] as? String, "applied")
        XCTAssertEqual((operation["review"] as? [String: Any])?["sourceThreadID"] as? String, String(threadID.dropFirst("thread-".count)))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try claudeGUIWire(f, method: "user").count, inputs)
        XCTAssertEqual(try claudeGUIRun(thread, prompt: Self.claudeBetaPrompt)["removedByHistoryOperationID"] as? String, selection["id"] as? String)
        try assertClaudeGUIPendingBanner(f.app)
        return selection
    }
    @MainActor private func assertClaudeGUIPendingBanner(_ app: XCUIApplication) throws {
        let pendingText = "Your next explicit message will use the saved Claude context. Existing native transcripts are retained; this selection did not send a message."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", pendingText, pendingText)).firstMatch.waitForExistence(timeout: 10))
    }
    @MainActor private func replaceClaudeGUIDraft(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.click(); composer.typeKey("a", modifierFlags: .command); composer.typeText(text)
        XCTAssertTrue(waitForValue(composer, value: text, timeout: 5))
    }
    @MainActor private func submitClaudeGUI(_ text: String, in app: XCUIApplication) throws {
        replaceClaudeGUIDraft(text, in: app)
        let send = app.buttons["composer-send"]
        try waitForClaudeGUIEnabled(send, timeout: 10); XCTAssertTrue(send.isHittable); send.click()
    }
    @MainActor private func waitForClaudeGUIEnabled(_ element: XCUIElement, timeout: TimeInterval) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
    }
    @MainActor private func completedClaudeGUI(_ f: ClaudeHistoryGUIFixture, threadID: String, prompt: String) throws -> [String: Any] {
        let snapshot = try waitForPrivateWorkspace(f.root, timeout: 20) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID), thread["activeRun"] == nil,
                  let run = self.findClaudeGUIRun(thread, prompt: prompt) else { return false }
            return run["status"] as? String == "completed" && (run["claude"] as? [String: Any])?["terminalStatus"] as? String == "completed"
        }
        let thread = try claudeGUIThread(snapshot, id: threadID), run = try claudeGUIRun(thread, prompt: prompt)
        XCTAssertEqual((run["claude"] as? [String: Any])?["openingInputID"] as? String, (run["id"] as? String)?.lowercased())
        XCTAssertEqual((thread["runtimeRequests"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse((thread["messages"] as? [[String: Any]])?.contains { $0["role"] as? String == "tool" } == true)
        return thread
    }
    private func findClaudeGUIThread(_ snapshot: [String: Any], id: String) -> [String: Any]? {
        let native = id.hasPrefix("thread-") ? String(id.dropFirst("thread-".count)) : id
        return (snapshot["threads"] as? [[String: Any]])?.first { ($0["id"] as? String)?.lowercased() == native.lowercased() }
    }
    private func claudeGUIThread(_ snapshot: [String: Any], id: String) throws -> [String: Any] {
        try XCTUnwrap(findClaudeGUIThread(snapshot, id: id))
    }
    private func findClaudeGUIRun(_ thread: [String: Any], prompt: String) -> [String: Any]? {
        guard let message = (thread["messages"] as? [[String: Any]])?.first(where: { $0["role"] as? String == "user" && $0["text"] as? String == prompt }),
              let messageID = message["id"] as? String else { return nil }
        return (thread["runHistory"] as? [[String: Any]])?.first { $0["userMessageID"] as? String == messageID }
    }
    private func claudeGUIRun(_ thread: [String: Any], prompt: String) throws -> [String: Any] {
        try XCTUnwrap(findClaudeGUIRun(thread, prompt: prompt))
    }
    private func claudeGUIJSON(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
    }
    private func claudeGUIWire(_ f: ClaudeHistoryGUIFixture, method: String) throws -> [[String: Any]] {
        try historyWire(f.wire).filter { $0["method"] as? String == method }
    }
    private func claudeGUITranscript(_ f: ClaudeHistoryGUIFixture, nativeID: String) throws -> URL {
        XCTAssertNotNil(UUID(uuidString: nativeID)); XCTAssertEqual(nativeID.utf8.count, 36)
        let file = f.configuration.appendingPathComponent("projects/coincide-claude-ui").appendingPathComponent(nativeID + ".jsonl")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        XCTAssertEqual(values.isRegularFile, true); XCTAssertNotEqual(values.isSymbolicLink, true)
        XCTAssertLessThanOrEqual(values.fileSize ?? Int.max, 4_194_304)
        return file
    }
    private func claudeGUIRecords(_ file: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(data.count, 4_194_304)
        return try data.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
            .filter { ["user", "assistant"].contains($0["type"] as? String ?? "") }
    }
    @MainActor private func assertClaudeGUIWorkspaceUnchanged(_ f: ClaudeHistoryGUIFixture) throws {
        XCTAssertEqual(try Data(contentsOf: f.document), f.original)
        XCTAssertEqual(try verifyHead(gitPath: f.gitPath, project: f.project, configuration: f.gitConfiguration, name: "claude-history-preserved-head"), f.head)
        let status = try runGit(["-C", f.project.path, "status", "--porcelain=v1"], gitPath: f.gitPath, configuration: f.gitConfiguration, name: "claude-history-preserved-index")
        XCTAssertTrue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: f.configuration.path)
        XCTAssertEqual(files, ["projects"], "Synthetic history must not create or read auth/settings files.")
    }

    @MainActor func testNativeRunHistoryForkRewindAndRecallPreserveSourceDraftAndFiles() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "history")
        let app = fixture.app, root = fixture.root
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        XCTAssertTrue(python.hasPrefix("/") && python != "/usr/bin/python3" && FileManager.default.isExecutableFile(atPath: python))
        let project = root.appendingPathComponent("Native History", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let readme = project.appendingPathComponent("README.md"), bytes = Data("Synthetic native conversation history fixture\n".utf8)
        try bytes.write(to: readme)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Native history fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "history-git-\(arguments[0])")
        }
        let originalHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "history-original-head")
        let headURL = project.appendingPathComponent(".git/HEAD"), headBytes = try Data(contentsOf: headURL)
        let state = root.appendingPathComponent("history-peer.json"), wire = root.appendingPathComponent("history-peer-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "threads": [:], "nextTurn": 0]).write(to: state)
        let bundledPeer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "codex_history_ui", withExtension: "py"))
        let peer = bundledPeer
        let bin = root.appendingPathComponent("private-bin", isDirectory: true), home = root.appendingPathComponent("private-codex-home", isDirectory: true)
        for directory in [bin, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let executable = try installOfflineCLI(tool: "codex", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        app.launchEnvironment["CODEX_HOME"] = home.path
        addTeardownBlock { @MainActor [weak self] in
            if let data = try? Data(contentsOf: wire), let text = String(data: data, encoding: .utf8) {
                let receipt = XCTAttachment(string: text); receipt.name = "history-offline-provider-wire"; receipt.lifetime = .keepAlways; self?.add(receipt)
            }
        }
        try preflightOfflineHistoryProvider(executable, cwd: project, environment: app.launchEnvironment, name: "history")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app)
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let sourceIdentifier = try selectedThreadIdentifier(in: app)
        let prompts = (1...3).map { "Offline history prompt \($0)" }
        for (index, prompt) in prompts.enumerated() {
            XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
            composer.click(); composer.typeText(prompt)
            XCTAssertTrue(waitForValue(composer, value: prompt, timeout: 5))
            app.typeKey(.return, modifierFlags: .command)
            XCTAssertTrue(app.staticTexts["Offline history reply \(index + 1)"].waitForExistence(timeout: 20))
        }
        let originalDraft = "Keep this source draft during a native fork"
        composer.click(); composer.typeText(originalDraft)
        try openNativeRunHistory(in: app)
        let thirdRun = try revealNativeHistoryRun(prompt: prompts[2], in: app)
        let secondRun = try revealNativeHistoryRun(prompt: prompts[1], in: app)
        let firstRun = try revealNativeHistoryRun(prompt: prompts[0], in: app)
        XCTAssertEqual(Set([firstRun, secondRun, thirdRun]).count, 3)
        capture(app, name: "history-three-completed-owned-runs")
        try nativeHistoryDone(in: app).click()
        try openNativeRunHistory(in: app)
        _ = try revealNativeHistoryRun(prompt: prompts[1], in: app)
        var reviewOwner = try openNativeHistoryAction(runID: secondRun, kind: "fork", in: app)
        var confirm = reviewOwner.buttons["conversation-history-confirm"], close = reviewOwner.buttons["conversation-history-close"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Workspace files and staging stay as they are."].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", prompts[1], prompts[1])).firstMatch.exists)
        XCTAssertTrue(close.isEnabled && close.isHittable)
        close.click() // Cancel performs only reads.
        XCTAssertEqual(try historyWire(wire).filter { $0["method"] as? String == "thread/fork" }.count, 0)
        reviewOwner = try openNativeHistoryAction(runID: secondRun, kind: "fork", in: app)
        confirm = reviewOwner.buttons["conversation-history-confirm"]; close = reviewOwner.buttons["conversation-history-close"]
        let title = reviewOwner.textFields["conversation-history-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click(); title.typeKey("a", modifierFlags: .command); title.typeText("GUI reviewed fork")
        XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
        let forkReview = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); forkReview.name = "history-native-fork-review"; forkReview.lifetime = .keepAlways; add(forkReview)
        let sourceHistoryDone = try nativeHistoryDone(in: app)
        confirm.click()
        XCTAssertTrue(waitForAbsence(sourceHistoryDone, timeout: 20), "An applied fork navigates to its new target and closes the source history.")
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
        let targetIdentifier = try selectedThreadIdentifier(in: app)
        XCTAssertNotEqual(sourceIdentifier, targetIdentifier)
        XCTAssertTrue(app.staticTexts["Offline history reply 2"].exists)
        XCTAssertFalse(app.staticTexts["Offline history reply 3"].exists)
        assertConversationWorkspace(app, path: project.path)
        capture(app, name: "history-fork-target-keeps-reviewed-prefix")
        selectThread(sourceIdentifier, in: app)
        XCTAssertTrue(waitForValue(composer, value: originalDraft, timeout: 10))
        XCTAssertTrue(app.staticTexts["Offline history reply 3"].waitForExistence(timeout: 5))
        try openNativeRunHistory(in: app)
        _ = try revealNativeHistoryRun(prompt: prompts[1], in: app)
        reviewOwner = try openNativeHistoryAction(runID: secondRun, kind: "rewind", in: app)
        confirm = reviewOwner.buttons["conversation-history-confirm"]; close = reviewOwner.buttons["conversation-history-close"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertEqual(confirm.label, "Revert and Keep Changes")
        XCTAssertTrue(reviewOwner.buttons["conversation-history-revert-files"].exists)
        XCTAssertTrue(close.isEnabled); close.click()
        XCTAssertEqual(try historyWire(wire).filter { $0["method"] as? String == "thread/revert" }.count, 0)
        try nativeHistoryDone(in: app).click()
        let newerDraft = "Newer source draft before explicit rewind"
        composer.click(); composer.typeKey("a", modifierFlags: .command); composer.typeText(newerDraft)
        try openNativeRunHistory(in: app)
        _ = try revealNativeHistoryRun(prompt: prompts[1], in: app)
        reviewOwner = try openNativeHistoryAction(runID: secondRun, kind: "rewind", in: app)
        confirm = reviewOwner.buttons["conversation-history-confirm"]; close = reviewOwner.buttons["conversation-history-close"]
        let reviewed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [reviewed], timeout: 10), .completed)
        XCTAssertTrue(confirm.isHittable)
        capture(app, name: "history-native-rewind-review-keeps-files-and-draft")
        confirm.click()
        let rewound = app.staticTexts.matching(identifier: "conversation-history-operation-status")
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Conversation rewound", "Conversation rewound")).firstMatch
        XCTAssertTrue(rewound.waitForExistence(timeout: 20))
        XCTAssertTrue(close.isEnabled && close.isHittable); close.click()
        for (run, prompt) in [(thirdRun, prompts[2]), (secondRun, prompts[1]), (firstRun, prompts[0])] {
            _ = try revealNativeHistoryRun(prompt: prompt, in: app)
            let removed = app.staticTexts["run-history-removed-\(run)"]
            XCTAssertEqual(removed.exists, run != firstRun)
            if run != firstRun { XCTAssertFalse(app.menuButtons["run-history-actions-\(run)"].isEnabled) }
        }
        capture(app, name: "history-rewind-retains-removed-run-audit")
        try nativeHistoryDone(in: app).click()
        XCTAssertEqual(try selectedThreadIdentifier(in: app), sourceIdentifier)
        let recalledDraft = newerDraft + "\n\n" + prompts[1]
        XCTAssertTrue(waitForValue(composer, value: recalledDraft, timeout: 10), "A confirmed keep-files rewind automatically appends the original input to the latest draft.")
        XCTAssertTrue(app.staticTexts["Offline history reply 1"].exists)
        XCTAssertFalse(app.staticTexts["Offline history reply 2"].exists)
        XCTAssertFalse(app.staticTexts["Offline history reply 3"].exists)
        let recall = app.buttons["conversation-history-recall"]
        XCTAssertTrue(waitForAbsence(recall, timeout: 5))
        capture(app, name: "history-automatic-recall-appends-to-latest-composer")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15)); app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: recalledDraft, timeout: 10))
        XCTAssertTrue(waitForAbsence(recall, timeout: 5), "A consumed recall cannot append again after relaunch.")
        XCTAssertEqual(try selectedThreadIdentifier(in: app), sourceIdentifier)
        XCTAssertTrue(app.staticTexts["Offline history reply 1"].exists)
        XCTAssertFalse(app.staticTexts["Offline history reply 2"].exists)
        selectThread(targetIdentifier, in: app)
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 5))
        XCTAssertTrue(app.staticTexts["Offline history reply 2"].exists)
        XCTAssertFalse(app.staticTexts["Offline history reply 3"].exists)
        selectThread(sourceIdentifier, in: app)
        try openNativeRunHistory(in: app)
        _ = try revealNativeHistoryRun(prompt: prompts[1], in: app)
        XCTAssertTrue(app.staticTexts["run-history-removed-\(secondRun)"].exists)
        try nativeHistoryDone(in: app).click()
        assertSidebarFitsDisplay(app, projectHeader: app.buttons["Collapse Native History"], selectedConversation: threadRow(sourceIdentifier, in: app))
        capture(app, name: "history-reopen-preserves-fork-source-audit-and-draft")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        let frames = try historyWire(wire)
        XCTAssertEqual(frames.filter { $0["method"] as? String == "turn/start" }.count, 3)
        let forks = frames.filter { $0["method"] as? String == "thread/fork" }, rewinds = frames.filter { $0["method"] as? String == "thread/revert" }
        XCTAssertEqual(forks.count, 1); XCTAssertEqual(rewinds.count, 1)
        XCTAssertEqual((forks.first?["params"] as? [String: Any])?["lastTurnId"] as? String, "ui-turn-2")
        XCTAssertEqual((rewinds.first?["params"] as? [String: Any])?["beforeTurnId"] as? String, "ui-turn-2")
        XCTAssertEqual(try Data(contentsOf: readme), bytes)
        XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "history-preserved-final-head"), originalHead)
    }

    @MainActor func testNativeCheckpointRestoreReviewsRealGitLossAndPreservesConversationAndSource() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "restore")
        let app = fixture.app, root = fixture.root
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        XCTAssertTrue(python.hasPrefix("/") && python != "/usr/bin/python3" && FileManager.default.isExecutableFile(atPath: python))
        let project = root.appendingPathComponent("Native Restore", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let before = "Before synthetic provider run\n", after = "After synthetic provider run\n"
        let sourceReadme = project.appendingPathComponent("README.md")
        try before.write(to: sourceReadme, atomically: true, encoding: .utf8)
        try "keep-ignored.txt\n".write(to: project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md", ".gitignore"], ["commit", "--message", "Real checkpoint restoration fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "restore-fixture-\(arguments[0])")
        }
        let originalHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "restore-source-head")
        let sourceHeadFile = project.appendingPathComponent(".git/HEAD"), sourceHeadBytes = try Data(contentsOf: sourceHeadFile)
        let state = root.appendingPathComponent("history-peer.json"), wire = root.appendingPathComponent("history-peer-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "threads": [:], "nextTurn": 0, "restoreFixture": true]).write(to: state)
        let bundledPeer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "codex_history_ui", withExtension: "py"))
        let peer = bundledPeer
        let bin = root.appendingPathComponent("private-bin", isDirectory: true), home = root.appendingPathComponent("private-codex-home", isDirectory: true)
        for directory in [bin, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let executable = try installOfflineCLI(tool: "codex", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        app.launchEnvironment["CODEX_HOME"] = home.path
        addTeardownBlock { @MainActor [weak self] in
            if let data = try? Data(contentsOf: wire), let text = String(data: data, encoding: .utf8) {
                let receipt = XCTAttachment(string: text); receipt.name = "restore-offline-provider-wire"; receipt.lifetime = .keepAlways; self?.add(receipt)
            }
        }
        try preflightOfflineHistoryProvider(executable, cwd: project, environment: app.launchEnvironment, name: "restore")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app)
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let preparingDraft = "Keep this draft while selecting an isolated restore worktree"
        composer.click(); composer.typeText(preparingDraft)
        let identifier = try selectedThreadIdentifier(in: app)
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        workspace.click(); app.menuItems["Choose Worktree…"].click()
        let preparation = app.sheets.containing(.textField, identifier: "worktree-new-branch").element
        XCTAssertTrue(preparation.waitForExistence(timeout: 5))
        let branch = preparation.textFields["worktree-new-branch"], base = preparation.textFields["worktree-base-ref"]
        branch.click(); branch.typeText("ui-checkpoint-restore")
        base.click(); base.typeKey("a", modifierFlags: .command); base.typeText("main")
        let submodules = preparation.descendants(matching: .any).matching(identifier: "worktree-submodules").element
        XCTAssertEqual(submodules.value as? String, "None")
        let prepare = preparation.buttons["Prepare Worktree"]
        let preparingReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [preparingReady], timeout: 10), .completed); prepare.click()
        XCTAssertTrue(waitForAbsence(preparation, timeout: 5))
        let managedRoot = root.appendingPathComponent("Worktrees", isDirectory: true)
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value BEGINSWITH %@", managedRoot.path + "/"), object: workspace)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 20), .completed)
        let checkout = URL(fileURLWithPath: try XCTUnwrap(workspace.value as? String))
        XCTAssertEqual(checkout.deletingLastPathComponent().path, managedRoot.path)
        assertWorkspaceReady(in: app)
        XCTAssertTrue(threadRow(identifier, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, preparingDraft)
        // Stop all metadata peers before updating their private fixture cwd.
        // Relaunch must use the persisted actual worktree before the first turn.
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        var stateValue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        XCTAssertEqual(stateValue["nextTurn"] as? Int, 0)
        stateValue["cwd"] = checkout.path
        try JSONSerialization.data(withJSONObject: stateValue).write(to: state, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: preparingDraft, timeout: 10))
        assertConversationWorkspace(app, path: checkout.path); assertWorkspaceReady(in: app)
        let prompt = "Make the synthetic local checkpoint change"
        composer.click(); composer.typeKey("a", modifierFlags: .command); composer.typeText(prompt)
        XCTAssertTrue(waitForValue(composer, value: prompt, timeout: 5))
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Offline history reply 1"].waitForExistence(timeout: 20))
        let readme = checkout.appendingPathComponent("README.md")
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), after)
        try openNativeRunHistory(in: app)
        let runID = try revealNativeHistoryRun(prompt: prompt, in: app)
        XCTAssertTrue(app.buttons["run-history-changes-\(runID)"].waitForExistence(timeout: 20), "Production Git must save both real checkpoint receipts before restoration.")
        try nativeHistoryDone(in: app).click()
        let staged = "User staged edits after the run\n", working = "User working edits after staging\n"
        try staged.write(to: readme, atomically: true, encoding: .utf8)
        _ = try runGit(["-C", checkout.path, "add", "README.md"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "restore-user-staging")
        try working.write(to: readme, atomically: true, encoding: .utf8)
        let newFile = checkout.appendingPathComponent("new-untracked.txt"), newBytes = Data("User file created after checkpoint\n".utf8)
        let ignored = checkout.appendingPathComponent("keep-ignored.txt"), ignoredBytes = Data("Keep this ignored user file\n".utf8)
        try newBytes.write(to: newFile); try ignoredBytes.write(to: ignored)
        let stagedBefore = try runGit(["-C", checkout.path, "diff", "--cached", "--binary", "--no-ext-diff"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "restore-before-staged-diff")
        let workingBefore = try runGit(["-C", checkout.path, "diff", "--binary", "--no-ext-diff"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "restore-before-working-diff")
        XCTAssertTrue(stagedBefore.contains(staged.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(workingBefore.contains(working.trimmingCharacters(in: .newlines)))
        let currentDraft = "Keep this latest unsent draft while replacing files"
        composer.click(); composer.typeText(currentDraft)
        try openNativeRunHistory(in: app)
        var restoreTarget = try revealBaselineRestoreTarget(in: app)
        let targetID = restoreTarget.identifier
        XCTAssertTrue(targetID.hasPrefix("run-history-restore-"))
        XCTAssertNotNil(UUID(uuidString: String(targetID.dropFirst("run-history-restore-".count))))
        restoreTarget.click()
        var review = try nativeRestoreReview(in: app)
        let warning = review.staticTexts["checkpoint-restore-loss-warning"]
        let warningText = warning.value as? String ?? warning.label
        XCTAssertTrue(warningText.contains("Working edits and staging will be lost"))
        XCTAssertTrue(warningText.contains("New files that are not ignored may be deleted"))
        let reviewedWorkspace = review.staticTexts["checkpoint-restore-workspace"]
        XCTAssertEqual(reviewedWorkspace.value as? String ?? reviewedWorkspace.label, checkout.path)
        let display = CGDisplayBounds(CGMainDisplayID())
        XCTAssertTrue(display.contains(review.frame), "The native destructive review must fit the hosted screen.")
        for control in [review.buttons["checkpoint-restore-confirm"], review.buttons["checkpoint-restore-close"]] {
            XCTAssertTrue(control.isHittable && review.frame.contains(control.frame) && display.contains(control.frame))
        }
        capture(app, name: "restore-reviewed-real-files-and-staging-loss")
        review.buttons["checkpoint-restore-close"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), working)
        XCTAssertEqual(try Data(contentsOf: newFile), newBytes); XCTAssertEqual(try Data(contentsOf: ignored), ignoredBytes)
        XCTAssertEqual(try runGit(["-C", checkout.path, "diff", "--cached", "--binary", "--no-ext-diff"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "restore-cancel-staged-diff"), stagedBefore)
        XCTAssertEqual(try runGit(["-C", checkout.path, "diff", "--binary", "--no-ext-diff"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "restore-cancel-working-diff"), workingBefore)
        try nativeHistoryDone(in: app).click()
        XCTAssertTrue(waitForValue(composer, value: currentDraft, timeout: 5))
        XCTAssertTrue(threadRow(identifier, in: app).isSelected)
        try openNativeRunHistory(in: app)
        restoreTarget = try revealBaselineRestoreTarget(in: app)
        XCTAssertEqual(restoreTarget.identifier, targetID); restoreTarget.click()
        review = try nativeRestoreReview(in: app)
        review.buttons["checkpoint-restore-confirm"].click()
        let status = review.staticTexts["checkpoint-restore-status"]
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Workspace files restored", "Workspace files restored"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 30), .completed)
        capture(app, name: "restore-real-git-applied-with-preserved-conversation")
        review.buttons["checkpoint-restore-close"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        try nativeHistoryDone(in: app).click()
        XCTAssertTrue(waitForValue(composer, value: currentDraft, timeout: 10))
        XCTAssertTrue(threadRow(identifier, in: app).isSelected)
        assertRestoreConversation(prompt: prompt, in: app)
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFile.path))
        XCTAssertEqual(try Data(contentsOf: ignored), ignoredBytes)
        XCTAssertEqual(try runGit(["-C", checkout.path, "diff", "--cached", "--no-ext-diff"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "restore-cleared-staging"), "")
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: checkout, configuration: fixture.configuration, name: "restore-unchanged-checkout-head"), originalHead)
        XCTAssertEqual(try runGit(["-C", checkout.path, "symbolic-ref", "--short", "HEAD"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "restore-unchanged-branch").trimmingCharacters(in: .whitespacesAndNewlines), "ui-checkpoint-restore")
        XCTAssertEqual(try String(contentsOf: sourceReadme, encoding: .utf8), before)
        XCTAssertEqual(try Data(contentsOf: sourceHeadFile), sourceHeadBytes)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "restore-unchanged-source-head"), originalHead)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: currentDraft, timeout: 10))
        assertConversationWorkspace(app, path: checkout.path); assertWorkspaceReady(in: app)
        XCTAssertTrue(threadRow(identifier, in: app).isSelected)
        assertRestoreConversation(prompt: prompt, in: app)
        try openNativeRunHistory(in: app)
        let historyOwner = try nativeHistorySheet(owning: "run-history-done", in: app)
        let audit = historyOwner.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND label == %@",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.disclosureTriangle.rawValue, "File restorations")).firstMatch
        XCTAssertTrue(audit.waitForExistence(timeout: 10)); expandScriptOutputDisclosure(audit)
        XCTAssertTrue(historyOwner.staticTexts["Workspace files restored"].waitForExistence(timeout: 5))
        capture(app, name: "restore-reopened-draft-conversation-and-file-audit")
        try nativeHistoryDone(in: app).click()
        let frames = try historyWire(wire)
        XCTAssertEqual(frames.filter { $0["method"] as? String == "turn/start" }.count, 1)
        XCTAssertEqual(frames.filter { ["thread/fork", "thread/revert"].contains($0["method"] as? String ?? "") }.count, 0)
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), before)
        XCTAssertEqual(try Data(contentsOf: ignored), ignoredBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFile.path))
        XCTAssertEqual(try Data(contentsOf: sourceHeadFile), sourceHeadBytes)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func revealBaselineRestoreTarget(in app: XCUIApplication) throws -> XCUIElement {
        let scroll = app.scrollViews["run-history-records"]
        XCTAssertTrue(scroll.exists); scroll.scroll(byDeltaX: 0, deltaY: 10_000)
        let targets = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "run-history-restore-", "Restore Files to Before Run…"))
        for _ in 0..<8 {
            if let target = targets.allElementsBoundByIndex.first(where: { $0.frame.width > 0 && scroll.frame.contains($0.frame) && $0.isHittable }) {
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: target)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
                return target
            }
            scroll.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTFail("The exact ready baseline must expose native file restoration in Run History.")
        throw NSError(domain: "CoincideDesktopUITests", code: 2)
    }

    @MainActor private func nativeRestoreReview(in app: XCUIApplication) throws -> XCUIElement {
        XCTAssertTrue(app.sheets.containing(.button, identifier: "checkpoint-restore-close").firstMatch.waitForExistence(timeout: 10))
        let review = try nativeHistorySheet(owning: "checkpoint-restore-close", in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: review.buttons["checkpoint-restore-confirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        return review
    }

    @MainActor private func assertRestoreConversation(prompt: String, in app: XCUIApplication) {
        // The accepted prompt can also become the sidebar conversation title.
        // Only the transcript scroll view containing its unique reply proves
        // both original messages survived this Files-only operation.
        let transcript = app.scrollViews.containing(.staticText, identifier: "Offline history reply 1").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", prompt, prompt)).firstMatch.exists)
        XCTAssertTrue(transcript.staticTexts["Offline history reply 1"].exists)
    }

    @MainActor func testNativePullRequestReviewLostReplyAndReadOnlyInspectionPreserveDraftAndPublishedGit() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "pull-request")
        let app = fixture.app, root = fixture.root
        let project = root.appendingPathComponent("Native Pull Requests", isDirectory: true)
        let bare = root.appendingPathComponent("Published fixture.git", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let readme = project.appendingPathComponent("README.md")
        try "Main branch contents\n".write(to: readme, atomically: true, encoding: .utf8)
        _ = try runGit(["init", "--bare", "--initial-branch", "main", bare.path], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-private-bare")
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Private PR base"],
                          ["remote", "add", "origin", bare.path], ["push", "--set-upstream", "origin", "main"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-base-\(arguments[0])")
        }
        let base = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "pr-base-head")
        _ = try runGit(["-C", project.path, "checkout", "-b", "topic"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-topic-branch")
        let contents = Data("Published private topic contents\n".utf8)
        try contents.write(to: readme)
        for arguments in [["add", "README.md"], ["commit", "--message", "Private PR feature"], ["push", "--set-upstream", "origin", "topic"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-topic-\(arguments[0])")
        }
        let head = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "pr-published-head")
        let headFile = project.appendingPathComponent(".git/HEAD"), headBytes = try Data(contentsOf: headFile)
        // Publication happened to the real private bare repository above. From
        // here onward all remote metadata comes from the closed-world fake gh;
        // no fetch, push or public request is allowed or needed.
        _ = try runGit(["-C", project.path, "remote", "set-url", "origin", "https://github.com/fixture/native-pr.git"],
            gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-fixture-repository-identity")
        let state = root.appendingPathComponent("github-peer.json"), wire = root.appendingPathComponent("github-peer-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "repository": "fixture/native-pr",
            "published": ["main": base, "topic": head], "creates": 0, "loseCreateReply": true]).write(to: state)
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        XCTAssertTrue(python.hasPrefix("/") && python != "/usr/bin/python3" && FileManager.default.isExecutableFile(atPath: python))
        let bundledPeer = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: "github_pr_ui", withExtension: "py"))
        let peer = bundledPeer
        let bin = root.appendingPathComponent("private-github-bin", isDirectory: true)
        let config = root.appendingPathComponent("private-gh-config", isDirectory: true)
        for directory in [bin, config] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        _ = try installOfflineCLI(tool: "gh", python: python, peer: peer, state: state, wire: wire, root: root, bin: bin, in: app)
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        app.launchEnvironment["GH_CONFIG_DIR"] = config.path
        app.launchEnvironment["GH_REPO"] = "github.com/unrelated/ignored"
        addTeardownBlock { @MainActor [weak self] in
            if let data = try? Data(contentsOf: wire), let text = String(data: data, encoding: .utf8) {
                let receipt = XCTAttachment(string: text); receipt.name = "pull-request-offline-gh-wire"; receipt.lifetime = .keepAlways; self?.add(receipt)
            }
        }
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app); app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let draft = "Keep this unsent discussion while reviewing a pull request"
        composer.click(); composer.typeText(draft)
        let identifier = try selectedThreadIdentifier(in: app)
        try openNativePullRequests(in: app)
        let title = "Offline native PR review", body = "Keep this exact description.\n\n- Native reviewed request\n"
        var sheet = try enterNativePullRequest(title: title, body: body, in: app)
        XCTAssertTrue(sheet.staticTexts["pull-request-reviewed-title"].waitForExistence(timeout: 20))
        let titleValue = sheet.staticTexts["pull-request-reviewed-title"]
        XCTAssertEqual((titleValue.value as? String) ?? titleValue.label, title)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", head, head)).firstMatch.exists)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", base, base)).firstMatch.exists)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(sheet.frame))
        capture(app, name: "pull-request-exact-create-review")
        sheet.buttons["pull-requests-close"].click()
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        XCTAssertEqual(try githubCreateReceipts(wire).count, 0, "Review and Cancel must never create a remote request.")
        try openNativePullRequests(in: app)
        sheet = try enterNativePullRequest(title: title, body: body, in: app)
        XCTAssertTrue(sheet.staticTexts["pull-request-reviewed-title"].waitForExistence(timeout: 20))
        let edit = sheet.buttons["pull-request-edit-review"]
        XCTAssertTrue(edit.isEnabled && edit.isHittable); edit.click()
        XCTAssertTrue(waitForValue(sheet.textViews["pull-request-body"], value: body, timeout: 5))
        sheet.buttons["pull-request-create"].click()
        XCTAssertTrue(sheet.staticTexts["pull-request-reviewed-title"].waitForExistence(timeout: 20))
        let create = sheet.buttons["pull-request-create"]
        XCTAssertEqual(create.label, "Create Pull Request"); XCTAssertTrue(create.isEnabled && create.isHittable); create.click()
        let status = sheet.staticTexts["pull-request-creation-status"]
        let unconfirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Pull request creation unconfirmed", "Pull request creation unconfirmed"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [unconfirmed], timeout: 20), .completed)
        XCTAssertTrue(sheet.buttons["pull-request-inspect-creation"].exists)
        XCTAssertEqual(try githubCreateReceipts(wire).count, 1)
        capture(app, name: "pull-request-lost-reply-held-without-retry")
        sheet.buttons["pull-requests-close"].click()
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        XCTAssertFalse(app.buttons["Push…"].isEnabled, "An uncertain PR holds its checkout across windows and native Git controls.")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), identifier)
        try openNativePullRequests(in: app)
        sheet = try nativeHistorySheet(owning: "pull-requests-close", in: app)
        XCTAssertTrue(sheet.staticTexts["pull-request-creation-status"].waitForExistence(timeout: 10))
        XCTAssertEqual(try githubCreateReceipts(wire).count, 1, "Restart and refresh inspect only; they cannot replay creation.")
        let inspect = sheet.buttons["pull-request-inspect-creation"]
        XCTAssertTrue(inspect.isEnabled && inspect.isHittable); inspect.click()
        let view = sheet.buttons["pull-request-view-result"]
        XCTAssertTrue(view.waitForExistence(timeout: 20)); XCTAssertTrue(view.isEnabled && view.isHittable); view.click()
        XCTAssertTrue(sheet.descendants(matching: .any).matching(identifier: "pull-request-description").firstMatch.waitForExistence(timeout: 10))
        for paragraph in ["Keep this exact description.", "Native reviewed request"] {
            // Native Markdown exposes each paragraph itself with the description identifier.
            XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "pull-request-description", paragraph, paragraph)).firstMatch.waitForExistence(timeout: 5))
        }
        capture(app, name: "pull-request-read-only-inspection-finds-exact-result")
        sheet.buttons["pull-requests-back"].click()
        let row = sheet.buttons["pull-request-select-42"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); XCTAssertTrue(row.isHittable); row.click()
        XCTAssertTrue(sheet.descendants(matching: .any).matching(identifier: "pull-request-description").firstMatch.waitForExistence(timeout: 10))
        sheet.buttons["pull-requests-close"].click()
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        XCTAssertEqual(try githubCreateReceipts(wire).count, 1)
        let receipt = try XCTUnwrap(try githubCreateReceipts(wire).first)
        XCTAssertEqual(receipt["body"] as? String, body)
        let arguments = try XCTUnwrap(receipt["arguments"] as? [String])
        for expected in ["--repo=github.com/fixture/native-pr", "--head=topic", "--base=main", "--title=" + title, "--draft", "--body-file=-"] { XCTAssertTrue(arguments.contains(expected)) }
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        XCTAssertEqual(saved["creates"] as? Int, 1)
        let remote = try XCTUnwrap(saved["pullRequest"] as? [String: Any])
        XCTAssertEqual(remote["url"] as? String, "https://github.com/fixture/native-pr/pull/42")
        XCTAssertEqual(remote["headRefOid"] as? String, head); XCTAssertEqual(remote["baseRefOid"] as? String, base)
        XCTAssertEqual(try Data(contentsOf: readme), contents); XCTAssertEqual(try Data(contentsOf: headFile), headBytes)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "pr-preserved-head"), head)
        let published = try runGit(["--git-dir=" + bare.path, "rev-parse", "refs/heads/topic"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-private-published-head")
        XCTAssertEqual(published.trimmingCharacters(in: .whitespacesAndNewlines), head)
        assertSidebarFitsDisplay(app, projectHeader: app.buttons["Collapse Native Pull Requests"], selectedConversation: threadRow(identifier, in: app))
        capture(app, name: "pull-request-recovered-draft-and-published-checkout")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testNativePullRequestCheckoutCreatesBlankWorktreeConversationAndPreservesSourceAcrossRestart() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "pr-checkout")
        let app = fixture.app, root = fixture.root, manager = FileManager.default
        let project = root.appendingPathComponent("Native PR Checkout", isDirectory: true)
        let bare = root.appendingPathComponent("Private PR remote.git", isDirectory: true)
        try manager.createDirectory(at: project, withIntermediateDirectories: false)
        let readme = project.appendingPathComponent("README.md")
        let sourceBytes = Data("Source checkout stays on main\n".utf8), topicBytes = Data("Reviewed private PR topic contents\n".utf8)
        try sourceBytes.write(to: readme)
        _ = try runGit(["init", "--bare", "--initial-branch", "main", bare.path], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-checkout-private-bare")
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Private checkout base"],
                          ["remote", "add", "origin", bare.path], ["push", "--set-upstream", "origin", "main"], ["checkout", "-b", "topic"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-checkout-base-\(arguments[0])")
        }
        let base = try runGit(["-C", project.path, "rev-parse", "main"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-checkout-base-head")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try topicBytes.write(to: readme)
        for arguments in [["add", "README.md"], ["commit", "--message", "Reviewed private PR head"], ["push", "--set-upstream", "origin", "topic"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-checkout-topic-\(arguments[0])")
        }
        let head = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "pr-checkout-reviewed-head")
        _ = try runGit(["--git-dir=" + bare.path, "update-ref", "refs/pull/42/head", head], gitPath: fixture.gitPath,
                       configuration: fixture.configuration, name: "pr-checkout-private-pull-ref")
        _ = try runGit(["-C", project.path, "checkout", "main"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-checkout-source-main")
        let sourceHeadFile = project.appendingPathComponent(".git/HEAD"), sourceHeadBytes = try Data(contentsOf: sourceHeadFile)
        _ = try runGit(["-C", project.path, "remote", "set-url", "origin", "https://github.com/fixture/native-pr.git"],
                       gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-checkout-canonical-remote")
        // Only this fixture's canonical URL is rewritten to the owned bare Git
        // repository. All other transports are denied; the peer performs no I/O.
        let bareURL = bare.absoluteString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let originalConfiguration = try String(contentsOf: fixture.configuration, encoding: .utf8)
        try (originalConfiguration + "\n[url \"" + bareURL + "\"]\n insteadOf = https://github.com/fixture/native-pr.git\n[protocol]\n allow = never\n[protocol \"file\"]\n allow = always\n")
            .write(to: fixture.configuration, atomically: true, encoding: .utf8)
        let state = root.appendingPathComponent("github-checkout-peer.json"), wire = root.appendingPathComponent("github-checkout-wire.jsonl")
        let pullRequest: [String: Any] = ["number": 42, "title": "Open the exact published PR in an empty conversation", "body": "Seeded read-only pull request for native checkout.",
            "url": "https://github.com/fixture/native-pr/pull/42", "state": "OPEN", "isDraft": false,
            "headRefName": "topic", "baseRefName": "main", "headRefOid": head, "baseRefOid": base,
            "headRepository": ["name": "native-pr", "nameWithOwner": "fixture/native-pr"], "headRepositoryOwner": ["login": "fixture"],
            "isCrossRepository": false, "author": ["login": "fixture"], "updatedAt": "2026-10-22T00:00:00Z", "createdAt": "2026-10-22T00:00:00Z",
            "reviewDecision": "REVIEW_REQUIRED", "statusCheckRollup": [], "additions": 1, "deletions": 1, "changedFiles": 1, "reviewRequests": [], "labels": []]
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "repository": "fixture/native-pr", "published": ["main": base, "topic": head],
            "creates": 0, "checkoutFixture": true, "pullRequest": pullRequest]).write(to: state)
        let providerState = root.appendingPathComponent("checkout-provider.json"), providerWire = root.appendingPathComponent("checkout-provider-wire.jsonl")
        try JSONSerialization.data(withJSONObject: ["cwd": project.path, "threads": [:], "nextTurn": 0]).write(to: providerState)
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["COINCIDE_UI_PYTHON_PATH"])
        XCTAssertTrue(python.hasPrefix("/") && python != "/usr/bin/python3" && manager.isExecutableFile(atPath: python))
        let bin = root.appendingPathComponent("private-checkout-bin", isDirectory: true)
        let codexHome = root.appendingPathComponent("private-checkout-codex-home", isDirectory: true)
        let ghHome = root.appendingPathComponent("private-checkout-gh-home", isDirectory: true)
        for directory in [bin, codexHome, ghHome] { try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        for (name, resource, peerState, peerWire) in [("gh", "github_pr_ui", state, wire), ("codex", "codex_history_ui", providerState, providerWire)] {
            let bundled = try XCTUnwrap(Bundle(for: CoincideDesktopUITests.self).url(forResource: resource, withExtension: "py"))
            let peer = bundled
            _ = try installOfflineCLI(tool: name, python: python, peer: peer, state: peerState, wire: peerWire, root: root, bin: bin, in: app)
        }
        app.launchEnvironment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        app.launchEnvironment["CODEX_HOME"] = codexHome.path; app.launchEnvironment["GH_CONFIG_DIR"] = ghHome.path
        app.launchEnvironment["GIT_ALLOW_PROTOCOL"] = "file"
        addTeardownBlock { @MainActor [weak self] in
            for (name, path) in [("pr-checkout-offline-gh-wire", wire), ("pr-checkout-offline-provider-wire", providerWire)] {
                if let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8) {
                    let attachment = XCTAttachment(string: text); attachment.name = name; attachment.lifetime = .keepAlways; self?.add(attachment)
                }
            }
        }
        try preflightOfflineHistoryProvider(bin.appendingPathComponent("codex"), cwd: project, environment: app.launchEnvironment, name: "pr-checkout")
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try openProject(project, in: app); app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let sourceIdentifier = try selectedThreadIdentifier(in: app), prompt = "Keep this source history before opening a separate pull request checkout"
        composer.click(); composer.typeText(prompt)
        XCTAssertTrue(waitForValue(composer, value: prompt, timeout: 5)); app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Offline history reply 1"].waitForExistence(timeout: 20))
        let draft = "Retain this source draft across PR checkout and restart"
        composer.click(); composer.typeText(draft); XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        try openNativePullRequests(in: app)
        var sheet = try nativeHistorySheet(owning: "pull-requests-close", in: app)
        let row = sheet.buttons["pull-request-select-42"]
        XCTAssertTrue(row.waitForExistence(timeout: 15)); XCTAssertTrue(row.isHittable); row.click()
        let open = sheet.buttons["pull-request-checkout"]
        let canOpen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [canOpen], timeout: 15), .completed); XCTAssertTrue(open.isHittable); open.click()
        let worktree = sheet.radioButtons["Separate worktree"]
        XCTAssertTrue(worktree.waitForExistence(timeout: 10))
        XCTAssertEqual((worktree.value as? NSNumber)?.intValue ?? Int((worktree.value as? String) ?? ""), 1)
        let submodules = sheet.descendants(matching: .any).matching(identifier: "pull-request-checkout-submodules").element
        XCTAssertTrue(submodules.exists); XCTAssertTrue((submodules.value as? String)?.contains("None") == true)
        let reviewSetup = sheet.checkBoxes["pull-request-checkout-review-setup"]
        revealNativePullRequestControl(reviewSetup, in: sheet)
        XCTAssertEqual((reviewSetup.value as? NSNumber)?.intValue ?? Int((reviewSetup.value as? String) ?? ""), 1)
        let confirm = sheet.buttons["pull-request-checkout-confirm"]
        XCTAssertEqual(confirm.label, "Review Checkout…"); XCTAssertTrue(confirm.isEnabled && confirm.isHittable); confirm.click()
        XCTAssertTrue(sheet.descendants(matching: .any).matching(identifier: "pull-request-checkout-captured-review").firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(confirm.label, "Open New Conversation")
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", head, head)).firstMatch.exists)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(sheet.frame))
        capture(app, name: "pr-checkout-exact-worktree-review-before-opening")
        XCTAssertTrue(confirm.isEnabled && confirm.isHittable); confirm.click()
        XCTAssertTrue(waitForAbsence(sheet.buttons["pull-requests-close"], timeout: 20), "Confirmed completion should open the new worktree conversation.")
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
        let targetIdentifier = try selectedThreadIdentifier(in: app)
        XCTAssertNotEqual(targetIdentifier, sourceIdentifier)
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        let managedRoot = root.appendingPathComponent("Worktrees", isDirectory: true)
        let destination = URL(fileURLWithPath: try XCTUnwrap(workspace.value as? String))
        XCTAssertEqual(destination.deletingLastPathComponent().path, managedRoot.path)
        assertWorkspaceReady(in: app)
        XCTAssertTrue(app.staticTexts["What are we building?"].exists)
        XCTAssertFalse(app.staticTexts["Offline history reply 1"].exists)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: destination, configuration: fixture.configuration, name: "pr-checkout-actual-target-head"), head)
        let actualBranch = try runGit(["-C", destination.path, "branch", "--show-current"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-checkout-actual-target-branch")
        XCTAssertEqual(actualBranch.trimmingCharacters(in: .whitespacesAndNewlines), "topic")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("README.md")), topicBytes)
        capture(app, name: "pr-checkout-new-blank-conversation-at-reviewed-head")
        selectThread(sourceIdentifier, in: app)
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10)); assertConversationWorkspace(app, path: project.path)
        let transcript = app.scrollViews.containing(.staticText, identifier: "Offline history reply 1").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", prompt, prompt)).firstMatch.exists)
        try openNativePullRequests(in: app)
        sheet = try nativeHistorySheet(owning: "pull-requests-close", in: app)
        let status = sheet.staticTexts["pull-request-checkout-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual((status.value as? String) ?? status.label, "Pull request conversation ready")
        let openTarget = sheet.buttons["pull-request-checkout-open-conversation"]
        revealNativePullRequestControl(openTarget, in: sheet)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", head, head)).firstMatch.exists)
        capture(app, name: "pr-checkout-durable-result-shows-actual-head")
        sheet.buttons["pull-requests-close"].click()
        selectThread(targetIdentifier, in: app)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // Foreground activation can precede the persisted workspace and sidebar selection loading.
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), targetIdentifier)
        assertConversationWorkspace(app, path: destination.path)
        assertWorkspaceReady(in: app); XCTAssertTrue(app.staticTexts["What are we building?"].exists)
        selectThread(sourceIdentifier, in: app)
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10)); assertConversationWorkspace(app, path: project.path)
        XCTAssertTrue(app.staticTexts["Offline history reply 1"].exists)
        let frames = try historyWire(providerWire)
        XCTAssertEqual(frames.filter { $0["method"] as? String == "turn/start" }.count, 1, "Opening or reopening the PR conversation must not send another prompt.")
        XCTAssertEqual(frames.filter { $0["method"] as? String == "thread/start" }.count, 1)
        XCTAssertEqual(try githubCreateReceipts(wire).count, 0)
        XCTAssertEqual(try Data(contentsOf: readme), sourceBytes); XCTAssertEqual(try Data(contentsOf: sourceHeadFile), sourceHeadBytes)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "pr-checkout-source-main-preserved"), base)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: destination, configuration: fixture.configuration, name: "pr-checkout-reopened-target-head"), head)
        let inventory = try runGit(["-C", project.path, "worktree", "list", "--porcelain"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "pr-checkout-reopened-inventory")
        let paths = inventory.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) }
        XCTAssertEqual(Set(paths), [project.path, destination.path], "Restart must retain the same two worktrees without creating another.")
        capture(app, name: "pr-checkout-reopened-source-history-and-draft-preserved")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func githubCreateReceipts(_ wire: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: wire.path) else { return [] }
        return try historyWire(wire).filter { ($0["arguments"] as? [String]).map { Array($0.prefix(2)) == ["pr", "create"] } == true }
    }

    @MainActor private func openNativePullRequests(in app: XCUIApplication) throws {
        let changes = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (label == %@ OR title == %@)",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.radioButton.rawValue, "Changes", "Changes")).firstMatch
        if !changes.exists { toggleInspector(in: app) }
        selectSegment("Changes", in: app)
        let open = app.buttons["pull-requests-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); XCTAssertTrue(open.isEnabled && open.isHittable); open.click()
        XCTAssertTrue(app.sheets.containing(.button, identifier: "pull-requests-close").firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor private func enterNativePullRequest(title: String, body: String, in app: XCUIApplication) throws -> XCUIElement {
        let sheet = try nativeHistorySheet(owning: "pull-requests-close", in: app)
        let new = sheet.buttons["pull-request-new"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: new)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertTrue(new.isEnabled && new.isHittable); new.click()
        XCTAssertTrue(sheet.descendants(matching: .any).matching(identifier: "pull-request-title").firstMatch.waitForExistence(timeout: 10))
        let titleField = sheet.textFields["pull-request-title"].exists ? sheet.textFields["pull-request-title"] : sheet.textViews["pull-request-title"]
        revealNativePullRequestControl(titleField, in: sheet); titleField.click(); titleField.typeText(title)
        let description = sheet.textViews["pull-request-body"]
        revealNativePullRequestControl(description, in: sheet); description.click(); description.typeText(body)
        let draft = sheet.checkBoxes["pull-request-draft"]
        revealNativePullRequestControl(draft, in: sheet); draft.click()
        XCTAssertEqual((draft.value as? NSNumber)?.intValue ?? Int((draft.value as? String) ?? ""), 1)
        let review = sheet.buttons["pull-request-create"]
        XCTAssertTrue(review.isEnabled && review.isHittable); review.click()
        return sheet
    }

    @MainActor private func revealNativePullRequestControl(_ control: XCUIElement, in sheet: XCUIElement) {
        let scroll = sheet.scrollViews.firstMatch
        for _ in 0..<5 {
            if control.exists && control.isHittable && scroll.frame.contains(control.frame) { return }
            XCTAssertTrue(scroll.exists); scroll.scroll(byDeltaX: 0, deltaY: -150)
        }
        XCTAssertTrue(control.exists && control.isHittable && scroll.frame.contains(control.frame), "The native PR input must be visible inside its scrollable form.")
    }

    @MainActor private func openNativeRunHistory(in app: XCUIApplication) throws {
        app.descendants(matching: .any).matching(identifier: "conversation-workspace").element.click()
        let history = app.menuItems["Run History…"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); XCTAssertTrue(history.isEnabled); history.click()
        XCTAssertTrue(app.sheets.containing(.scrollView, identifier: "run-history-records").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(try nativeHistoryDone(in: app).exists)
    }

    @MainActor private func revealNativeHistoryRun(prompt: String, in app: XCUIApplication) throws -> String {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "run-history-record-"))
        let scroll = app.scrollViews["run-history-records"]
        XCTAssertTrue(scroll.exists); scroll.scroll(byDeltaX: 0, deltaY: 10_000)
        var matchedIDs: [String] = []
        for _ in 0..<5 {
            let matches = rows.allElementsBoundByAccessibilityElement.filter {
                $0.children(matching: .staticText).matching(NSPredicate(
                    format: "label == %@ OR value == %@", prompt, prompt)).count == 1
            }
            matchedIDs = matches.map(\.identifier)
            guard matches.count <= 1 else {
                let diagnostic = XCTAttachment(string: "Requested prompt: \(prompt)\nMatching record IDs: \(matchedIDs)\n\(app.debugDescription)")
                diagnostic.name = "history-ambiguous-run-accessibility-tree"; diagnostic.lifetime = .keepAlways; add(diagnostic)
                XCTFail("The native Run History must associate the exact prompt with one owned run.")
                throw NSError(domain: "CoincideDesktopUITests", code: 1)
            }
            if let row = matches.first {
                let id = String(row.identifier.dropFirst("run-history-record-".count))
                let actions = app.menuButtons["run-history-actions-\(id)"]
                let frame = actions.frame
                // The prompt can be visible while this row's lower action menu
                // is still clipped. Removed-run menus remain visible but disabled.
                if frame.width > 0 && frame.height > 0 && scroll.frame.contains(frame) { return id }
            }
            XCTAssertTrue(scroll.exists); scroll.scroll(byDeltaX: 0, deltaY: -150)
        }
        let tree = XCTAttachment(string: "Requested prompt: \(prompt)\nMatching record IDs: \(matchedIDs)\n\(app.debugDescription)"); tree.name = "history-missing-run-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
        XCTFail("The native Run History must expose the owned run for \(prompt).")
        throw NSError(domain: "CoincideDesktopUITests", code: 1)
    }

    @MainActor private func openNativeHistoryAction(runID: String, kind: String, in app: XCUIApplication) throws -> XCUIElement {
        let actions = app.menuButtons["run-history-actions-\(runID)"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: actions)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        XCTAssertTrue(actions.isHittable); actions.click()
        let item = app.menuItems["run-history-\(kind)-\(runID)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); XCTAssertTrue(item.isEnabled && item.isHittable); item.click()
        XCTAssertTrue(app.sheets.containing(.button, identifier: "conversation-history-close").firstMatch.waitForExistence(timeout: 10))
        return try nativeHistorySheet(owning: "conversation-history-close", in: app)
    }

    @MainActor private func nativeHistoryDone(in app: XCUIApplication) throws -> XCUIElement {
        try nativeHistorySheet(owning: "run-history-done", in: app).buttons["run-history-done"]
    }

    @MainActor private func nativeHistorySheet(owning identifier: String, in app: XCUIApplication) throws -> XCUIElement {
        // Native default buttons can also appear in the Touch Bar. A nested
        // review can match both its own sheet and the outer history ancestor.
        let candidates = app.sheets.containing(.button, identifier: identifier).allElementsBoundByIndex
        let owners = candidates.filter { $0.sheets.containing(.button, identifier: identifier).count == 0 }
        XCTAssertEqual(owners.count, 1, "The control must belong to one innermost native sheet: \(identifier).")
        return try XCTUnwrap(owners.first)
    }

    /// Read only the canonical projection in this test's isolated database, including its WAL.
    /// This does not seed or mutate production state and does not require app-only test hooks.
    private func privateWorkspaceSnapshot(_ root: URL) throws -> [String: Any] {
        let database = root.appendingPathComponent("workspace.sqlite")
        guard root.lastPathComponent.hasPrefix("coincide-ui-testing-"), root.path.hasPrefix("/"),
              try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try database.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw NSError(domain: "CoincideDesktopUITests.PrivateSnapshot", code: 1)
        }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard opened == SQLITE_OK, let handle else { throw NSError(domain: "CoincideDesktopUITests.PrivateSnapshot", code: 2) }
        sqlite3_busy_timeout(handle, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT payload FROM workspace WHERE id=1", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "CoincideDesktopUITests.PrivateSnapshot", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw NSError(domain: "CoincideDesktopUITests.PrivateSnapshot", code: 4)
        }
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0, length <= 4_194_304,
              let snapshot = try JSONSerialization.jsonObject(with: Data(bytes: bytes, count: length)) as? [String: Any] else {
            throw NSError(domain: "CoincideDesktopUITests.PrivateSnapshot", code: 5)
        }
        return snapshot
    }

    @MainActor private func waitForPrivateWorkspace(_ root: URL, timeout: TimeInterval,
                                                   matching predicate: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let snapshot = try? privateWorkspaceSnapshot(root) else { return false }
            return predicate(snapshot)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, "The private canonical workspace must reach the exact asserted boundary.")
        return try privateWorkspaceSnapshot(root)
    }

    @MainActor private func assertSteeringSnapshot(_ snapshot: [String: Any], firstPrompt: String,
                                                  literal: String, name: String) throws -> String {
        let threads = try XCTUnwrap(snapshot["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.count, 1)
        let thread = try XCTUnwrap(threads.first)
        XCTAssertNil(thread["activeRun"] as? [String: Any])
        XCTAssertEqual((thread["queuedTurns"] as? [[String: Any]])?.count, 0)
        let users = try XCTUnwrap(thread["messages"] as? [[String: Any]]).filter { $0["role"] as? String == "user" }
        XCTAssertEqual(users.compactMap { $0["text"] as? String }, [firstPrompt, literal], "Queued-and-removed input must not become a transcript row.")
        let runs = try XCTUnwrap(thread["runHistory"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first), runID = try XCTUnwrap(run["id"] as? String)
        XCTAssertEqual(run["status"] as? String, "completed")
        XCTAssertEqual(run["providerThreadID"] as? String, "ui-native-steering-thread")
        XCTAssertEqual(run["turnIDs"] as? [String], ["ui-native-steering-turn"])
        let operations = try XCTUnwrap(snapshot["promptSteerings"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 1)
        let operation = try XCTUnwrap(operations.first), id = try XCTUnwrap(operation["id"] as? String)
        XCTAssertNotNil(UUID(uuidString: id)); XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(operation["sourceIncarnation"] as? String)))
        XCTAssertEqual(operation["phase"] as? String, "delivered")
        XCTAssertEqual(operation["threadID"] as? String, thread["id"] as? String)
        XCTAssertEqual(operation["runID"] as? String, runID)
        XCTAssertEqual(operation["nativeThreadID"] as? String, "ui-native-steering-thread")
        XCTAssertEqual(operation["nativeTurnID"] as? String, "ui-native-steering-turn")
        XCTAssertEqual((operation["input"] as? [String: Any])?["text"] as? String, literal)
        let receipt = try XCTUnwrap(operation["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["turnID"] as? String, "ui-native-steering-turn")
        XCTAssertEqual(receipt["delivery"] as? String, "acknowledged")
        let row = try XCTUnwrap(users.last)
        XCTAssertEqual(row["id"] as? String, operation["messageID"] as? String)
        XCTAssertEqual(row["promptSteeringID"] as? String, id)
        for user in users {
            XCTAssertEqual((user["runReference"] as? [String: Any])?["runID"] as? String, runID)
            XCTAssertNil(user["submissionError"] as? String)
        }
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(operation["configuration"]), options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: XCTUnwrap(run["configuration"]), options: .sortedKeys), "Steering must retain the original run's immutable configuration.")
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        let audit = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        audit.name = name; audit.lifetime = .keepAlways; add(audit)
        return id
    }

    @MainActor private func assertSteeringWire(_ frames: [[String: Any]], literal: String,
                                              snapshot: [String: Any]) throws {
        XCTAssertEqual(frames.filter { $0["method"] as? String == "thread/start" }.count, 1)
        XCTAssertEqual(frames.filter { $0["method"] as? String == "turn/start" }.count, 1)
        let calls = frames.filter { $0["method"] as? String == "turn/steer" }
        XCTAssertEqual(calls.count, 1)
        let params = try XCTUnwrap(calls.first?["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["threadId", "expectedTurnId", "input", "clientUserMessageId"])
        XCTAssertEqual(params["threadId"] as? String, "ui-native-steering-thread")
        XCTAssertEqual(params["expectedTurnId"] as? String, "ui-native-steering-turn")
        let items = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["text"] as? String, literal)
        XCTAssertEqual(items.first?["type"] as? String, "text")
        XCTAssertEqual((items.first?["text_elements"] as? [Any])?.count, 0)
        let operation = try XCTUnwrap((snapshot["promptSteerings"] as? [[String: Any]])?.first)
        XCTAssertEqual(params["clientUserMessageId"] as? String, operation["messageID"] as? String)
        XCTAssertFalse(frames.contains { ["thread/fork", "thread/revert", "turn/interrupt"].contains($0["method"] as? String ?? "") })
    }

    private func historyWire(_ path: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try Data(contentsOf: path).split(separator: 10).map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }

    @MainActor private func preflightOfflineHistoryProvider(_ executable: URL, cwd: URL,
                                                           environment: [String: String], name: String) throws {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        func stopOwnedProcess() -> Bool {
            guard process.isRunning else { return true }
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .success { return true }
            Darwin.kill(process.processIdentifier, SIGKILL)
            return exited.wait(timeout: .now() + 1) == .success
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { _ = stopOwnedProcess() }
        }
        let request: [String: Any] = ["id": "native-ui-launch-preflight", "method": "initialize",
            "params": ["clientInfo": ["name": "coincide-ui-launch-preflight", "version": "1"]]]
        var payload = try JSONSerialization.data(withJSONObject: request); payload.append(10)
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "unavailable"
        let wrapper = try? Data(contentsOf: executable)
        let prefix = wrapper?.prefix(24).map { String(format: "%02x", $0) }.joined() ?? "unavailable"
        let identity = "wrapperMode=\(permissions) wrapperBytes=\(wrapper?.count ?? -1) wrapperPrefixHex=\(prefix)"
        var stage = "fcntl(F_SETNOSIGPIPE)"
        var pipeSignalResult: Int32 = -1
        var pipeSignalErrno: Int32 = 0
        do {
            pipeSignalResult = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            pipeSignalErrno = errno
            guard pipeSignalResult == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(pipeSignalErrno))
            }
            stage = "Process.run"
            try process.run()
        }
        catch {
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            let failure = error as NSError
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(16_384), as: UTF8.self)
            let diagnostic = XCTAttachment(string: "Exact offline wrapper preflight failed with the fixture environment.\nstage=\(stage)\nfcntlResult=\(pipeSignalResult) fcntlErrno=\(pipeSignalErrno)\n\(identity)\nNSError domain=\(failure.domain) code=\(failure.code)\nstderr:\n\(stderr)")
            diagnostic.name = name + "-offline-provider-launch-preflight"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            throw error
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
        } catch {
            let stopped = stopOwnedProcess()
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            let stderr = stopped ? String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(16_384), as: UTF8.self) : "Owned process did not drain after TERM/KILL."
            let failure = error as NSError
            let diagnostic = XCTAttachment(string: "Exact offline wrapper initialize input failed with the fixture environment.\nNSError domain=\(failure.domain) code=\(failure.code)\nstderr:\n\(stderr)")
            diagnostic.name = name + "-offline-provider-launch-preflight"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            throw error
        }
        let completed = exited.wait(timeout: .now() + 5) == .success
        if !completed {
            guard stopOwnedProcess() else {
                let diagnostic = XCTAttachment(string: "Exact offline wrapper did not exit after initialize and EOF; its owned process was sent SIGKILL.")
                diagnostic.name = name + "-offline-provider-launch-preflight"; diagnostic.lifetime = .keepAlways; add(diagnostic)
                throw NSError(domain: "CoincideDesktopUITests.ProviderPreflight", code: 2)
            }
        }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(16_384), as: UTF8.self)
        let diagnostic = XCTAttachment(string: "Exact offline wrapper initialize-only launch with the fixture environment.\nexit=\(process.terminationStatus), completed=\(completed)\nstdout:\n\(String(decoding: stdout.prefix(16_384), as: UTF8.self))\nstderr:\n\(stderr)")
        diagnostic.name = name + "-offline-provider-launch-preflight"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        XCTAssertTrue(completed, "The offline peer must finish its initialize-only preflight after stdin EOF.")
        XCTAssertEqual(process.terminationStatus, 0, "The exact offline wrapper must launch before testing native provider actions.")
        let frame = try XCTUnwrap(stdout.split(separator: 10).first)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame)) as? [String: Any])
        XCTAssertEqual(reply["id"] as? String, "native-ui-launch-preflight")
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["userAgent"] as? String, "coincide/0.163.0 (macos; fixture)")
    }

    @MainActor private func installOfflineCLI(tool: String, python: String, peer: URL, state: URL, wire: URL,
                                              root: URL, bin: URL, in app: XCUIApplication) throws -> URL {
        let manager = FileManager.default
        let allowed = ["codex": ["codex_history_ui.py", "codex_steering_ui.py", "codex_models_ui.py"], "gh": ["github_pr_ui.py"], "claude": ["claude_history_ui.py"], "pi": ["pi_history_ui.py"]]
        XCTAssertTrue(allowed[tool]?.contains(peer.lastPathComponent) == true)
        let bundle = Bundle(for: CoincideDesktopUITests.self)
        let helper = try XCTUnwrap(bundle.url(forResource: "CoincideOfflineCLI", withExtension: nil))
        XCTAssertTrue(manager.isExecutableFile(atPath: helper.path))
        XCTAssertNotEqual(helper.deletingLastPathComponent(), root)
        _ = try XCTUnwrap(bundle.url(forResource: peer.deletingPathExtension().lastPathComponent, withExtension: "py"))
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        let descriptor = root.appendingPathComponent(tool + ".offline.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "tool": tool, "root": root.path, "python": python,
            "peer": peer.lastPathComponent, "state": state.path, "wire": wire.path], options: .sortedKeys).write(to: descriptor, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor.path)
        app.launchEnvironment["COINCIDE_UI_PYTHON_PATH"] = python
        let executable = bin.appendingPathComponent(tool)
        // Creating a symlink does not create executable bytes in the sandbox's
        // quarantined temporary directory. The sealed helper remains immutable.
        try manager.createSymbolicLink(at: executable, withDestinationURL: helper)
        XCTAssertEqual(executable.resolvingSymlinksInPath(), helper.resolvingSymlinksInPath())
        return executable
    }

    @MainActor private func prepareApplication(appearance: String, diagnosticPrefix: String? = nil) throws -> (app: XCUIApplication, root: URL, gitPath: String, configuration: URL) {
        let environment = ProcessInfo.processInfo.environment
        let appPath = try XCTUnwrap(environment["COINCIDE_UI_APP_PATH"], "The CI harness must supply the staged app.")
        let gitPath = try XCTUnwrap(environment["COINCIDE_UI_GIT_PATH"], "The CI harness must resolve the developer Git executable outside the sandbox.")
        let manager = FileManager.default
        XCTAssertTrue(gitPath.hasPrefix("/") && gitPath != "/usr/bin/git" && manager.isExecutableFile(atPath: gitPath))
        // Xcode sandboxes its generated runner, even with ENABLE_APP_SANDBOX=NO.
        // Foundation supplies writable temporary storage belonging to that runner.
        let requestedRoot = manager.temporaryDirectory.appendingPathComponent("coincide-ui-testing-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: requestedRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = requestedRoot.resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent("empty-hooks", isDirectory: true)
        try manager.createDirectory(at: hooks, withIntermediateDirectories: false)
        let configuration = root.appendingPathComponent("gitconfig")
        let quotedHooks = hooks.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try "[user]\n name = Coincide UI Test\n email = ui-test@example.invalid\n[commit]\n gpgSign = false\n[core]\n hooksPath = \"\(quotedHooks)\"\n"
            .write(to: configuration, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        let app = XCUIApplication(url: URL(fileURLWithPath: appPath))
        app.launchEnvironment["COINCIDE_UI_TESTING"] = "1"
        app.launchEnvironment["COINCIDE_UI_TEST_ROOT"] = root.path
        // Supply a private config to this disposable app's Git children; never change the runner's config.
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = configuration.path
        app.launchEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        app.launchArguments = ["-appearance", appearance]
        let prefix = diagnosticPrefix ?? appearance
        // XCTest invokes teardown blocks even when a failed assertion aborts a test.
        addTeardownBlock { @MainActor [weak self] in
            if app.state != .notRunning {
                let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(prefix)-final-accessibility-tree"; tree.lifetime = .keepAlways; self?.add(tree)
                if app.windows.firstMatch.exists {
                    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                    screenshot.name = "\(prefix)-final-window"; screenshot.lifetime = .keepAlways; self?.add(screenshot)
                }
                app.terminate()
            }
        }
        return (app, root, gitPath, configuration)
    }

    @MainActor private func exerciseProjectWorkflow(appearance: String, useKeyboard: Bool) throws {
        let (app, root, gitPath, configuration) = try prepareApplication(appearance: appearance)
        let manager = FileManager.default
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "The native app must have a foreground window.")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let projectName = "GUI \(appearance.capitalized) Project"
        if useKeyboard {
            app.typeKey("n", modifierFlags: [.command, .shift])
        } else {
            app.menuBars.menuBarItems["File"].click()
            let item = app.menuItems["New Project…"]
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        }
        let name = app.textFields["new-project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.click(); name.typeText(projectName)
        let create = app.buttons["create-project"]
        XCTAssertTrue(create.waitForExistence(timeout: 5) && create.isEnabled); create.click()
        XCTAssertTrue(waitForAbsence(create, timeout: 20), "Creation must settle without leaving the modal busy.")
        let done = app.buttons["project-created-done"]
        if done.exists {
            let warning = XCTAttachment(string: app.debugDescription); warning.name = "\(appearance)-initial-commit-warning"; warning.lifetime = .keepAlways; add(warning)
            done.click() // A nonfatal initial-commit warning still means project creation succeeded.
        }
        let header = app.buttons["Collapse \(projectName)"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let layout = XCTAttachment(string: "Display frame: \(CGDisplayBounds(CGMainDisplayID()))\nWindow frame: \(app.windows.firstMatch.frame)\n\n\(app.debugDescription)")
        layout.name = "\(appearance)-created-layout-and-accessibility"; layout.lifetime = .keepAlways; add(layout)
        assertSidebarFitsDisplay(app, projectHeader: header)
        capture(app, name: "\(appearance)-created")
        let projectFolders = try manager.contentsOfDirectory(at: root.appendingPathComponent("Projects"), includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertEqual(projectFolders.count, 1)
        let projectFolder = try XCTUnwrap(projectFolders.first)
        let initialHead = try verifyHead(gitPath: gitPath, project: projectFolder, configuration: configuration, name: "\(appearance)-initial-git-head")
        let preservedPaths = ["README.md", "assets/icon.svg", ".git/HEAD"]
        let preservedFiles = try Dictionary(uniqueKeysWithValues: preservedPaths.map { ($0, try Data(contentsOf: projectFolder.appendingPathComponent($0))) })
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10) && composer.isHittable)
        let draft = "Synthetic draft retained through sidebar changes"
        composer.click(); composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)

        header.rightClick()
        let rename = app.menuItems["Rename Project…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.click()
        // Native SwiftUI alert text fields preserve their placeholder/value, but
        // macOS does not bridge this field's SwiftUI accessibility identifier.
        let renameSheet = app.sheets.containing(.button, identifier: "sidebar-rename-save").element
        XCTAssertTrue(renameSheet.waitForExistence(timeout: 5))
        XCTAssertEqual(renameSheet.textFields.count, 1)
        let renameField = renameSheet.textFields.element
        XCTAssertTrue(renameField.waitForExistence(timeout: 5)); renameField.click()
        XCTAssertEqual(renameField.value as? String, projectName)
        renameField.typeKey("a", modifierFlags: .command)
        let renamed = projectName + " Renamed"
        renameField.typeText(renamed); app.buttons["sidebar-rename-save"].click()
        let renamedHeader = app.buttons["Collapse \(renamed)"]
        XCTAssertTrue(renamedHeader.waitForExistence(timeout: 5)); renamedHeader.click()
        XCTAssertTrue(app.buttons["Expand \(renamed)"].waitForExistence(timeout: 5))
        let selected = app.outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "thread-")).element
        XCTAssertTrue(selected.waitForExistence(timeout: 5) && selected.isSelected, "Collapsing must keep the selected conversation visible.")
        XCTAssertEqual(composer.value as? String, draft)
        assertSidebarFitsDisplay(app, projectHeader: app.buttons["Expand \(renamed)"])
        capture(app, name: "\(appearance)-collapsed-selected")

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Graceful quit must flush the composer draft.")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["Expand \(renamed)"].waitForExistence(timeout: 10), "The renamed project and collapsed state must persist.")
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(selected.exists && selected.isSelected)
        assertSidebarFitsDisplay(app, projectHeader: app.buttons["Expand \(renamed)"])
        capture(app, name: "\(appearance)-reopened")
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(appearance)-reopened-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)

        let collapsedHeader = app.buttons["Expand \(renamed)"]
        collapsedHeader.rightClick()
        let removeItem = app.menuItems["Remove Project…"]
        XCTAssertTrue(removeItem.waitForExistence(timeout: 5)); removeItem.click()
        let confirmation = app.sheets.containing(NSPredicate(format: "label == %@", "Remove Project")).element
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let removalTitle = "Remove “\(renamed)” from Coincide?"
        let confirmationTitle = confirmation.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", removalTitle, removalTitle)).element
        let confirmRemove = confirmation.buttons["Remove Project"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5) && confirmRemove.exists)
        try assertRemovalCaveats(confirmation, name: "\(appearance)-removal-cancel-review")
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(confirmRemove, timeout: 5))
        XCTAssertTrue(collapsedHeader.exists && composer.exists)
        XCTAssertEqual(composer.value as? String, draft, "Cancelling removal must preserve the selected conversation and its draft.")

        collapsedHeader.rightClick()
        XCTAssertTrue(removeItem.waitForExistence(timeout: 5)); removeItem.click()
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5) && confirmRemove.exists)
        try assertRemovalCaveats(confirmation, name: "\(appearance)-removal-confirm-review")
        confirmRemove.click()
        XCTAssertTrue(waitForAbsence(collapsedHeader, timeout: 10), "Confirmed removal must remove the project from the sidebar.")
        XCTAssertTrue(waitForAbsence(composer, timeout: 5), "Confirmed removal must clear the removed conversation.")
        for path in preservedPaths {
            XCTAssertEqual(try Data(contentsOf: projectFolder.appendingPathComponent(path)), preservedFiles[path], "Removing a registered project must preserve its existing \(path) bytes.")
        }
        XCTAssertEqual(try verifyHead(gitPath: gitPath, project: projectFolder, configuration: configuration, name: "\(appearance)-removed-git-head"), initialHead)
        let emptyDescription = "Your projects and coding agents, in a native Mac workspace."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", emptyDescription, emptyDescription)).element.waitForExistence(timeout: 5))
        capture(app, name: "\(appearance)-removed-empty-workspace")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func verifyHead(gitPath: String, project: URL, configuration: URL, name: String) throws -> String {
        let stdout = try runGit(["-C", project.path, "rev-parse", "--verify", "HEAD"], gitPath: gitPath, configuration: configuration, name: name,
                                failure: "The created native project must contain its initial Git commit.")
        let head = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(head.isEmpty)
        return head
    }

    @MainActor private func runGit(_ arguments: [String], gitPath: String, configuration: URL, name: String, failure: String = "The synthetic local Git fixture command must succeed.") throws -> String {
        let git = Process(); git.executableURL = URL(fileURLWithPath: gitPath)
        git.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = configuration.path; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        git.environment = environment
        let output = Pipe(), errors = Pipe(); git.standardOutput = output; git.standardError = errors
        try git.run(); git.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let diagnostic = XCTAttachment(string: "Git: \(gitPath)\nArguments: \(arguments.joined(separator: " "))\nExit: \(git.terminationStatus)\nstdout:\n\(stdout)\nstderr:\n\(stderr)")
        diagnostic.name = name; diagnostic.lifetime = .keepAlways; add(diagnostic)
        XCTAssertEqual(git.terminationStatus, 0, "\(failure) Git stderr: \(stderr)")
        return stdout
    }

    @MainActor private func openProject(_ directory: URL, in app: XCUIApplication) throws {
        app.menuBars.menuBarItems["File"].click()
        let open = app.menuItems["Add Project…"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.click()
        let panel = app.windows["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let add = panel.buttons["OKButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertEqual(add.title, "Add Project")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(directory.path)
        app.typeKey(.return, modifierFlags: [])
        // Wait for folder navigation, then make each expensive hit-test assertion once.
        // A combined readiness predicate can exceed its deadline inside one AX evaluation.
        let location = panel.popUpButtons["where popup"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", directory.lastPathComponent), object: location)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        let diagnostic = XCTAttachment(string: "Requested checkout: \(directory.path)\nPanel frame: \(panel.frame)\nConfirm frame: \(add.frame)\nEnabled: \(add.isEnabled)\nHittable: \(add.isHittable)\n\n\(panel.debugDescription)")
        diagnostic.name = "open-panel-\(directory.lastPathComponent)"; diagnostic.lifetime = .keepAlways; self.add(diagnostic)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(add.isEnabled && add.isHittable)
        add.click()
        XCTAssertTrue(waitForAbsence(add, timeout: 10), "The native folder panel must accept the chosen local checkout.")
    }

    @MainActor private func threadRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "thread-"))
    }

    @MainActor private func projectHeaders(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Collapse ", "Expand "))
    }

    @MainActor private func openProjectScripts(in app: XCUIApplication) {
        let launcher = app.buttons["project-scripts"]
        if launcher.exists {
            XCTAssertTrue(launcher.isEnabled && launcher.isHittable); launcher.click()
        } else {
            let overflow = app.toolbars.popUpButtons["more toolbar items"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 5)); XCTAssertTrue(overflow.isHittable); overflow.click()
            let script = app.menuItems["Run Script…"]
            XCTAssertTrue(script.waitForExistence(timeout: 5)); XCTAssertTrue(script.isEnabled && script.isHittable); script.click()
        }
    }

    @MainActor private func toggleInspector(in app: XCUIApplication) {
        app.menuBars.menuBarItems["Thread"].click()
        let toggle = app.menuItems["Toggle Inspector"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.click()
    }

    @MainActor private func assertWorkspaceReady(in app: XCUIApplication) {
        // The cwd changes at durable intent. Native controls remain disabled until checkout is ready.
        let terminal = app.buttons["Terminal"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        app.descendants(matching: .any).matching(identifier: "conversation-workspace").element.click()
        let reveal = app.menuItems["Reveal Workspace"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5)); XCTAssertTrue(reveal.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor private func expandScriptOutputDisclosure(_ disclosure: XCUIElement) {
        XCTAssertTrue(disclosure.isHittable)
        // The native AX frame includes a 24pt leading gutter; its center is label text.
        // Retained CI video shows that clicking the label does not open this control.
        let triangle = disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 26, dy: 0))
        XCTAssertTrue(disclosure.frame.contains(triangle.screenPoint))
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(triangle.screenPoint))
        triangle.click()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = disclosure.value
            return (value as? NSNumber)?.intValue == 1 || (value as? String) == "1"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed,
                       "The native output disclosure must expand before its output can be inspected.")
    }

    @MainActor private func selectSegment(_ title: String, in app: XCUIApplication) {
        let segment = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (label == %@ OR title == %@)",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.radioButton.rawValue, title, title
        )).element
        XCTAssertTrue(segment.waitForExistence(timeout: 5)); XCTAssertTrue(segment.isHittable); segment.click()
    }

    @MainActor private func quitReview(in app: XCUIApplication) -> XCUIElement {
        let review = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d OR elementType == %d",
            XCUIElement.ElementType.dialog.rawValue, XCUIElement.ElementType.sheet.rawValue, XCUIElement.ElementType.window.rawValue
        )).containing(.button, identifier: "Quit and Discard").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let title = "Quit with unsaved file edits?"
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).element.exists)
        let warning = "Unsaved file edits and commit messages will be discarded. Cancel to return to your work and save it before quitting. Unconfirmed remote operation records remain available after restart."
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", warning, warning)).element.exists)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        return review
    }

    @MainActor private func terminalCloseReview(in app: XCUIApplication) -> XCUIElement {
        let review = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d OR elementType == %d OR elementType == %d OR elementType == %d",
            XCUIElement.ElementType.dialog.rawValue, XCUIElement.ElementType.sheet.rawValue, XCUIElement.ElementType.window.rawValue,
            XCUIElement.ElementType.popover.rawValue, XCUIElement.ElementType.alert.rawValue
        )).containing(.button, identifier: "Close Terminal").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let text = ([review.label, review.title] + review.staticTexts.allElementsBoundByIndex.flatMap { [$0.label, ($0.value as? String) ?? ""] }).joined(separator: " ")
        XCTAssertTrue(text.contains("Close terminal and stop its running command?"))
        XCTAssertTrue(review.buttons["Close Terminal"].isHittable && review.buttons["Cancel"].isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        return review
    }

    @MainActor private func threadRow(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.outlineRows.containing(NSPredicate(format: "identifier == %@", identifier)).element
    }

    @MainActor private func selectThread(_ identifier: String, in app: XCUIApplication) {
        let row = threadRow(identifier, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // XCTest could not click the visible OutlineRow; target its identified native title.
        let title = row.staticTexts.matching(identifier: identifier).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.isHittable, "The identified conversation title must be visible and interactive.")
        title.click()
        XCTAssertTrue(row.isSelected, "Clicking the conversation title must select its containing row.")
    }

    @MainActor private func selectedThreadIdentifier(in app: XCUIApplication) throws -> String {
        // Foreground activation can precede workspace loading and the native
        // outline's accessibility publication after a graceful relaunch.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.threadRows(in: app).allElementsBoundByIndex.filter { $0.isSelected }.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let selected = threadRows(in: app).allElementsBoundByIndex.filter { $0.isSelected }
        XCTAssertEqual(selected.count, 1)
        let row = try XCTUnwrap(selected.first)
        let identifier = try XCTUnwrap(row.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "thread-")).allElementsBoundByIndex.first?.identifier)
        return identifier
    }

    @MainActor private func assertConversationWorkspace(_ app: XCUIApplication, path: String) {
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(workspace, value: path, timeout: 5), "The selected conversation must keep its own physical checkout: \(path).")
    }

    @MainActor private func setGroupingMode(_ title: String, in app: XCUIApplication) {
        app.menuButtons["project-sort-menu"].click()
        let mode = app.menuItems[title]
        XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.click()
    }

    @MainActor private func assertGroupRemovalReview(in app: XCUIApplication, name: String, paths: [String]) -> XCUIElement {
        let review = app.sheets.containing(.button, identifier: "remove-project-group").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let title = "Remove “\(name)” Group?"
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).element.exists)
        let checkouts = review.descendants(matching: .any).matching(identifier: "group-removal-checkouts").element
        XCTAssertTrue(checkouts.exists)
        for path in paths {
            let text = checkouts.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", path, path)).firstMatch
            XCTAssertTrue(text.exists, "The removal review must name every exact physical checkout path: \(path).")
            XCTAssertTrue(checkouts.frame.contains(text.frame), "Both test checkout paths must be visible in the native review.")
        }
        let caveats = review.staticTexts.matching(NSPredicate(format: "(label CONTAINS %@ OR value CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)", "Git may clean up unfinished files", "Git may clean up unfinished files", "local recovery history", "local recovery history")).element
        XCTAssertTrue(caveats.exists, "Group removal must explain active-Git cleanup and retained recovery history.")
        return review
    }

    @MainActor private func waitForValue(_ element: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor private func assertRemovalCaveats(_ sheet: XCUIElement, name: String) throws {
        let expected = ["Git may clean up unfinished files", "local recovery history"]
        let attributes = sheet.staticTexts.allElementsBoundByIndex.flatMap { [($0.value as? String) ?? "", $0.label, $0.title] }
        let accessibilityText = attributes.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if expected.allSatisfy({ accessibilityText.localizedCaseInsensitiveContains($0) }) { return }
        // The pinned XCTest runtime caps native alert text at 512 UTF-16 units.
        // Check real rendered pixels only for that observed truncation case.
        XCTAssertTrue(sheet.exists && sheet.buttons["Remove Project"].isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(sheet.frame))
        let screenshot = sheet.screenshot()
        let picture = XCTAttachment(screenshot: screenshot); picture.name = name; picture.lifetime = .keepAlways; add(picture)
        let snapshot = XCTAttachment(string: "Attribute UTF-16 lengths: \(attributes.map { $0.utf16.count })\n\n\(accessibilityText)")
        snapshot.name = name + "-accessibility-text"; snapshot.lifetime = .keepAlways; add(snapshot)
        guard attributes.contains(where: { $0.utf16.count == 512 }) else {
            XCTFail("Removal warning concepts are missing without the observed XCTest truncation boundary."); return
        }
        let bitmap = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: bitmap).perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        let recognized = lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let diagnostic = XCTAttachment(string: "On-device Vision text from the native alert:\n\(recognized)")
        diagnostic.name = name + "-recognized-text"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        for phrase in expected {
            XCTAssertTrue(recognized.localizedCaseInsensitiveContains(phrase), "The visible removal warning must include: \(phrase).")
        }
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists && window.isHittable && app.state == .runningForeground)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(window.frame), "The native window must fit entirely on the hosted display: \(window.frame).")
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        // xcresulttool exports the retained PNG outside the sandbox after testing.
    }

    @MainActor private func assertSidebarFitsDisplay(_ app: XCUIApplication, projectHeader: XCUIElement, selectedConversation: XCUIElement? = nil) {
        let display = CGDisplayBounds(CGMainDisplayID())
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(display.contains(window), "The native window must fit the actual display \(display), without clipping: \(window).")
        let controls: [(String, XCUIElement)] = [
            ("New conversation", app.buttons["New conversation"]),
            ("Sort projects", app.menuButtons["project-sort-menu"]),
            ("Search conversations", app.textFields["Search conversations"]),
            ("Project header", projectHeader),
            ("Selected conversation", selectedConversation ?? app.outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "thread-")).element),
            ("Add Project", app.menuButtons.matching(NSPredicate(format: "title == %@", "Add Project")).element),
            ("Settings", app.buttons["gearshape"]),
            ("Archive", app.checkBoxes["Archive"]),
        ]
        for (name, control) in controls {
            XCTAssertTrue(control.exists, "The sidebar must expose its \(name) control.")
            let frame = control.frame
            XCTAssertTrue(frame.width > 0 && frame.height > 0 && window.contains(frame) && display.contains(frame),
                          "The \(name) control must be wholly inside the window and display, without clipping: \(frame).")
        }
    }
}
