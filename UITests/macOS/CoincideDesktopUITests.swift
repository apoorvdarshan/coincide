import AppKit
import CoreGraphics
import Darwin
import SQLite3
import Vision
import XCTest

final class CoincideDesktopUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

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
        let settings = app.windows.containing(.checkBox, identifier: "codex-account-reveal-email").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let kind = settings.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR value == %@)", "codex-account-kind", "ChatGPT", "ChatGPT")).firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 10))
        let plan = settings.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Offline Hosted Plus", "Offline Hosted Plus")).firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        let email = settings.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR value == %@)", "codex-account-email", "Hidden", "Hidden")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        let reveal = settings.checkBoxes["codex-account-reveal-email"]
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
        let inspectedCommand = "pwd -P > script-cwd.txt; printf '%s\\n' \"$T3CODE_PROJECT_ROOT\" > script-root.txt; printf '%s\\n' \"${T3CODE_WORKTREE_PATH-unset}\" > script-worktree.txt; printf 'native-script-finished\\n'; exit 7"
        let holdingCommand = "printf 'running\\n' > script-holding.txt; exec /bin/sleep 120"
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
        let receiptNames = ["script-stale.txt", "script-cwd.txt", "script-root.txt", "script-worktree.txt", "script-holding.txt"]
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
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "scripts-final-head"), initialHead)
        capture(app, name: "scripts-running-tab-closed-draft-retained")
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
        let renderedDescription = sheet.descendants(matching: .any).matching(identifier: "pull-request-description").firstMatch
        for paragraph in ["Keep this exact description.", "Native reviewed request"] {
            XCTAssertTrue(renderedDescription.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", paragraph, paragraph)).firstMatch.waitForExistence(timeout: 5))
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
        XCTAssertEqual(try selectedThreadIdentifier(in: app), targetIdentifier)
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10)); assertConversationWorkspace(app, path: destination.path)
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
        for _ in 0..<5 {
            if let row = rows.allElementsBoundByIndex.first(where: { $0.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", prompt, prompt)).firstMatch.exists }) {
                let id = String(row.identifier.dropFirst("run-history-record-".count))
                let actions = app.menuButtons["run-history-actions-\(id)"]
                let frame = actions.frame
                // The prompt can be visible while this row's lower action menu
                // is still clipped. Removed-run menus remain visible but disabled.
                if frame.width > 0 && frame.height > 0 && scroll.frame.contains(frame) { return id }
            }
            XCTAssertTrue(scroll.exists); scroll.scroll(byDeltaX: 0, deltaY: -150)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "history-missing-run-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
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
        let allowed = ["codex": ["codex_history_ui.py", "codex_steering_ui.py", "codex_models_ui.py"], "gh": ["github_pr_ui.py"]]
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
        let warning = "Unsaved file edits will be discarded. Cancel to return to your files and save them before quitting."
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
