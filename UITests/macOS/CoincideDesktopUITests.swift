import AppKit
import CoreGraphics
import Darwin
import SQLite3
import Vision
import XCTest

final class CoincideDesktopUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLightAppearanceFileMenuProjectWorkflow() throws {
        try exerciseProjectWorkflow(appearance: "light", useKeyboard: false)
    }
    @MainActor func testDarkAppearanceKeyboardProjectWorkflow() throws {
        try exerciseProjectWorkflow(appearance: "dark", useKeyboard: true)
    }
    @MainActor func testNativeFileReferencePickerSearchPreservesDraftAndDisk() throws {
        let f = try currentShell(); let project = f.root.appendingPathComponent("Reference Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let file = project.appendingPathComponent("reference.txt"), bytes = Data("Referenced bytes stay unchanged\n".utf8)
        try bytes.write(to: file)
        launch(f.app); try openProject(project, in: f.app); f.app.typeKey("n", modifierFlags: .command)
        let composer = f.app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.click(); composer.typeText("Review this file: ")
        let menu = f.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Add files and tools")).firstMatch
        XCTAssertTrue(menu.exists); menu.click(); f.app.menuItems["composer-reference-file"].click()
        let search = f.app.textFields["composer-file-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.click(); search.typeText("reference")
        let reference = f.app.buttons["composer-file-reference.txt"]
        XCTAssertTrue(reference.waitForExistence(timeout: 10)); reference.click()
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@ AND value CONTAINS %@", "Review this file: ", "reference.txt"), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let id = try selectedThreadIdentifier(in: f.app)
        let saved = try waitForPrivateWorkspace(f.root, timeout: 5) { self.findClaudeGUIThread($0, id: id)?["draft"] as? String == composer.value as? String }
        XCTAssertTrue((try claudeGUIThread(saved, id: id)["messages"] as? [Any])?.isEmpty == true)
    }

    @MainActor func testLightEmbeddedSettingsPreserveDraftWithoutOpeningAnotherWindow() throws {
        try exerciseEmbeddedSettings(appearance: "light")
    }
    @MainActor func testDarkEmbeddedSettingsPreserveDraftWithoutOpeningAnotherWindow() throws {
        try exerciseEmbeddedSettings(appearance: "dark")
    }
    @MainActor func testNativeSettingsSearchFiltersAndRestoresAllPages() throws {
        let f = try currentShell(); launch(f.app)
        f.app.typeKey(",", modifierFlags: .command)
        let search = f.app.textFields["settings-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.click(); search.typeText("sandbox")
        XCTAssertTrue(waitForValue(search, value: "sandbox", timeout: 5))
        XCTAssertTrue(f.app.buttons["settings-page-configuration"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(f.app.buttons["settings-page-about"], timeout: 5))
        f.app.buttons["settings-clear-search"].click()
        XCTAssertTrue(waitForValue(search, value: "", timeout: 5))
        XCTAssertTrue(f.app.buttons["settings-page-about"].exists)
        XCTAssertEqual(f.app.windows.count, 1)
    }
    @MainActor func testNativeSettingsNavigatesEveryIntegrationPageInsideTheChatWindow() throws {
        let f = try currentShell(); launch(f.app)
        f.app.typeKey(",", modifierFlags: .command)
        for page in ["skills", "commands", "mcp", "plugins", "hooks"] {
            try showSettingsPage(page, in: f.app)
            XCTAssertTrue(f.app.textFields["integration-search"].waitForExistence(timeout: 5))
            XCTAssertTrue(f.app.buttons["integration-refresh"].exists)
            XCTAssertEqual(f.app.windows.count, 1)
            XCTAssertEqual(f.app.sheets.count, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("should-not-run").path))
        capture(f.app, name: "native-integrations-in-window")
    }
    @MainActor func testNativeCodexConfigurationSavesOnlyAnExplicitValidatedEdit() throws {
        let f = try currentShell()
        let file = f.codex.appendingPathComponent("config.toml")
        let original = "model = \"original-model\"\n[fixture]\nprivate_value = \"DO_NOT_RENDER_CONFIG_CANARY\"\n"
        try Data(original.utf8).write(to: file)
        launch(f.app); try openConfiguration(in: f.app)
        let field = f.app.textFields["configuration-field-model"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "original-model")
        replace(field, with: "replacement-model")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        XCTAssertFalse(f.app.debugDescription.contains("DO_NOT_RENDER_CONFIG_CANARY"))
        try saveConfiguration(in: f.app)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("model = \"replacement-model\""))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("private_value = \"DO_NOT_RENDER_CONFIG_CANARY\""))
    }
    @MainActor func testNativeClaudeConfigurationPreservesCredentialsAndUnknownHooks() throws {
        let f = try currentShell()
        let file = f.claude.appendingPathComponent("settings.json")
        try writeJSON(["model": "sonnet", "env": ["SYNTHETIC_PRIVATE_VALUE": "DO_NOT_RENDER_CLAUDE_CANARY"], "hooks": ["SessionStart": [["hooks": [["type": "command", "command": "do-not-execute-fixture"]]]]]], to: file)
        launch(f.app); try openConfiguration(in: f.app, provider: "Claude")
        let field = f.app.textFields["configuration-field-model"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); replace(field, with: "opus")
        XCTAssertFalse(f.app.debugDescription.contains("DO_NOT_RENDER_CLAUDE_CANARY"))
        try saveConfiguration(in: f.app)
        let saved = try readJSON(file)
        XCTAssertEqual(saved["model"] as? String, "opus")
        XCTAssertEqual((saved["env"] as? [String: String])?["SYNTHETIC_PRIVATE_VALUE"], "DO_NOT_RENDER_CLAUDE_CANARY")
        XCTAssertNotNil(saved["hooks"])
    }
    @MainActor func testNativeConfigurationRejectsExternalEditsWithoutOverwritingThem() throws {
        let f = try currentShell(); let file = f.codex.appendingPathComponent("config.toml")
        try Data("model = 'original'\n".utf8).write(to: file)
        launch(f.app); try openConfiguration(in: f.app)
        let field = f.app.textFields["configuration-field-model"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); replace(field, with: "draft-model")
        let external = "model = 'external'\n"; try Data(external.utf8).write(to: file)
        try saveConfiguration(in: f.app, expectsError: true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external)
        XCTAssertTrue(f.app.descendants(matching: .any).matching(identifier: "configuration-error").firstMatch.exists)
    }
    @MainActor func testNativeConfigurationRejectsInvalidCompactionAndKeepsTheSource() throws {
        let f = try currentShell(); let file = f.claude.appendingPathComponent("settings.json")
        let original = Data("{\"autoCompactWindow\":200000}".utf8); try original.write(to: file)
        launch(f.app); try openConfiguration(in: f.app, provider: "Claude")
        let field = f.app.textFields["configuration-field-autoCompactWindow"]
        try revealContentControl(field, in: f.app); replace(field, with: "99")
        try saveConfiguration(in: f.app, expectsError: true)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    @MainActor func testNativeConfigurationScopeChangeRequiresDiscardingUnsavedEdits() throws {
        let f = try currentShell(); let file = f.codex.appendingPathComponent("config.toml")
        let original = Data("model = 'original'\n".utf8); try original.write(to: file)
        launch(f.app); try openConfiguration(in: f.app)
        let field = f.app.textFields["configuration-field-model"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); replace(field, with: "unsaved-model")
        try showSettingsPage("appearance", in: f.app)
        try showSettingsPage("configuration", in: f.app)
        try revealContentControl(field, in: f.app)
        XCTAssertTrue(waitForValue(field, value: "unsaved-model", timeout: 5), "Settings navigation must retain the edit for its exact source.")
        XCTAssertEqual(try Data(contentsOf: file), original)
        try chooseConfiguration("configuration-provider", value: "Claude", in: f.app)
        // The dialog's cancel action is also mirrored on the Touch Bar; click the window's.
        let keep = f.app.windows.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Keep editing", "Keep editing")).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5)); keep.click()
        XCTAssertTrue(waitForValue(field, value: "unsaved-model", timeout: 5))
        XCTAssertEqual(try Data(contentsOf: file), original)
        try revealContentControl(f.app.buttons["configuration-discard"], in: f.app)
        f.app.buttons["configuration-discard"].click()
        try revealContentControl(field, in: f.app)
        XCTAssertTrue(waitForValue(field, value: "original", timeout: 5))
    }
    @MainActor func testNativeSkillsLibraryImportsACopyWithoutChangingItsSource() throws {
        let f = try currentShell(); let skill = f.codex.appendingPathComponent("skills/ui-fixture/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("---\nname: ui-fixture\ndescription: Native import fixture\n---\nKeep this literal skill body.\n".utf8)
        try original.write(to: skill)
        launch(f.app); f.app.typeKey(",", modifierFlags: .command); try showSettingsPage("skills", in: f.app)
        let row = f.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "integration-import-")).firstMatch
        try revealContentControl(row, in: f.app); XCTAssertTrue(row.isEnabled); row.click()
        XCTAssertTrue(f.app.staticTexts["In Coincide"].waitForExistence(timeout: 5))
        let importedFiles = try FileManager.default.subpathsOfDirectory(atPath: f.root.appendingPathComponent("Integrations").path)
            .filter { $0.hasSuffix("/content/SKILL.md") }
        XCTAssertEqual(importedFiles.count, 1)
        let copy = try XCTUnwrap(importedFiles.first)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Integrations").appendingPathComponent(copy)), original)
        XCTAssertEqual(try Data(contentsOf: skill), original)
        try revealContentControl(f.app.buttons["integration-refresh"], in: f.app); f.app.buttons["integration-refresh"].click()
        XCTAssertTrue(f.app.staticTexts["ui-fixture"].waitForExistence(timeout: 10))
    }
    @MainActor func testNativeCommandLibraryReadsNamesAndKeepsLiteralSourceUnexecuted() throws {
        let f = try currentShell(); let command = f.claude.appendingPathComponent("commands/ui-review.md")
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("---\ndescription: Offline review command\n---\nReview $ARGUMENTS without executing this fixture.\n".utf8); try original.write(to: command)
        launch(f.app); f.app.typeKey(",", modifierFlags: .command); try showSettingsPage("commands", in: f.app)
        try revealContentControl(f.app.staticTexts["ui-review"], in: f.app)
        let search = f.app.textFields["integration-search"]
        try revealContentControl(search, in: f.app); replace(search, with: "definitely-no-matching-command")
        try revealContentControl(f.app.staticTexts["No matches"], in: f.app)
        XCTAssertEqual(try Data(contentsOf: command), original)
    }
    @MainActor func testNativeMCPSettingsDisplayMetadataWithoutRenderingCredentialValues() throws {
        let f = try currentShell(); let config = f.codex.appendingPathComponent("config.toml")
        let original = Data("[mcp_servers.ui_fixture]\ncommand = 'must-not-run'\nenabled = false\n[mcp_servers.ui_fixture.env]\nAPI_KEY = 'DO_NOT_RENDER_MCP_CANARY'\n".utf8); try original.write(to: config)
        launch(f.app); f.app.typeKey(",", modifierFlags: .command); try showSettingsPage("mcp", in: f.app)
        XCTAssertTrue(f.app.staticTexts["ui_fixture"].waitForExistence(timeout: 10))
        XCTAssertFalse(f.app.debugDescription.contains("DO_NOT_RENDER_MCP_CANARY"))
        XCTAssertEqual(try Data(contentsOf: config), original)
    }
    @MainActor func testNativeHooksPageNeverExecutesDiscoveryCommands() throws {
        let f = try currentShell(); let config = f.claude.appendingPathComponent("settings.json")
        let sentinel = f.root.appendingPathComponent("should-not-run")
        try writeJSON(["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "touch '" + sentinel.path + "'"]]]]]], to: config)
        let original = try Data(contentsOf: config)
        launch(f.app); f.app.typeKey(",", modifierFlags: .command); try showSettingsPage("hooks", in: f.app)
        try revealContentControl(f.app.staticTexts["SessionStart"], in: f.app)
        try revealContentControl(f.app.buttons["integration-refresh"], in: f.app); f.app.buttons["integration-refresh"].click()
        try revealContentControl(f.app.staticTexts["SessionStart"], in: f.app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try Data(contentsOf: config), original)
    }
    @MainActor func testNativePluginEnableControlChangesOnlyItsNamedSetting() throws {
        let f = try currentShell(); let file = f.claude.appendingPathComponent("settings.json")
        try writeJSON(["enabledPlugins": ["fixture@local": true, "other@local": true]], to: file)
        launch(f.app); try openConfiguration(in: f.app, provider: "Claude")
        try chooseConfiguration("configuration-field-enabledPlugins/fixture@local", value: "Disabled", in: f.app)
        try saveConfiguration(in: f.app)
        let plugins = try XCTUnwrap(readJSON(file)["enabledPlugins"] as? [String: Bool])
        XCTAssertEqual(plugins, ["fixture@local": false, "other@local": true])
    }
    @MainActor func testNativeSessionFilteringKeepsUnavailableRuntimeReadOnly() throws {
        let f = try currentShell(); launch(f.app)
        f.app.typeKey(",", modifierFlags: .command); try showSettingsPage("sessions", in: f.app)
        let search = f.app.textFields["provider-session-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); replace(search, with: "no-session")
        let filter = f.app.switches["provider-session-active-filter"]
        if filter.exists { filter.click() }
        else { f.app.checkBoxes["provider-session-active-filter"].click() }
        XCTAssertTrue(waitForValue(search, value: "no-session", timeout: 5))
        XCTAssertEqual(f.app.windows.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.codex.appendingPathComponent("sessions").path))
    }
    @MainActor func testNativeSessionsImportExplainsCopiedOwnershipWithoutScanningAutomatically() throws {
        let f = try currentShell(); launch(f.app)
        f.app.typeKey(",", modifierFlags: .command); try showSettingsPage("sessions", in: f.app)
        let button = f.app.buttons["provider-session-import"]
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.click()
        let sheet = f.app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.buttons["Scan Local Projects"].exists)
        XCTAssertFalse(sheet.buttons["agent-session-import-selected"].isEnabled)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "separate session", "separate session")).firstMatch.exists)
        sheet.buttons["Done"].click(); XCTAssertTrue(waitForAbsence(sheet, timeout: 5))
    }
    @MainActor func testNativeThreadSortModesPreserveTheSelectedDraft() throws {
        let f = try currentShell(); launch(f.app); try startScratchChat(in: f.app)
        let composer = f.app.textViews["composer-input"], draft = "Preserved through every thread sort"
        composer.click(); composer.typeText(draft)
        for mode in ["Newest", "Recently active", "Priority (pinned first)", "Name", "Custom"] {
            let sort = f.app.descendants(matching: .any).matching(identifier: "sidebar-thread-sort").firstMatch
            XCTAssertTrue(sort.exists); sort.click(); f.app.menuItems[mode].click()
            XCTAssertTrue(waitForValue(sort, value: mode, timeout: 5))
            XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        }
        f.app.typeKey("q", modifierFlags: .command); XCTAssertTrue(f.app.wait(for: .notRunning, timeout: 15)); launch(f.app)
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10))
    }
    @MainActor func testNativeProjectSortModesPersistWithoutRewritingProjectFiles() throws {
        let f = try currentShell(); let folder = f.root.appendingPathComponent("Sort Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("README.md"), bytes = Data("Preserved project bytes\n".utf8); try bytes.write(to: file)
        launch(f.app); try openProject(folder, in: f.app)
        for mode in ["Newest", "Recently active", "Priority (pinned first)", "Name", "Custom"] {
            let sort = f.app.descendants(matching: .any).matching(identifier: "sidebar-project-sort").firstMatch
            XCTAssertTrue(sort.exists); sort.click(); f.app.menuItems[mode].click()
            XCTAssertTrue(waitForValue(sort, value: mode, timeout: 5))
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        f.app.typeKey("q", modifierFlags: .command); XCTAssertTrue(f.app.wait(for: .notRunning, timeout: 15)); launch(f.app)
        XCTAssertTrue(waitForValue(f.app.descendants(matching: .any).matching(identifier: "sidebar-project-sort").firstMatch, value: "Custom", timeout: 10))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    @MainActor func testNativeMenusExposeTheCurrentLocalChatSurface() throws {
        let f = try currentShell(); launch(f.app)
        XCTAssertFalse(f.app.menuBars.menuBarItems["Remote"].exists)
        f.app.menuBars.menuBarItems["Chat"].click()
        XCTAssertTrue(f.app.menuItems["Stop Reply"].exists)
        XCTAssertFalse(f.app.menuItems["Toggle Inspector"].exists)
        XCTAssertFalse(f.app.menuItems["Settle Workspace"].exists)
        f.app.typeKey(.escape, modifierFlags: [])
        f.app.typeKey(",", modifierFlags: .command); try showSettingsPage("providers", in: f.app)
        XCTAssertEqual(f.app.windows.count, 1)
    }
    @MainActor func testNativeRenameArchiveAndUnarchiveKeepConversationDraft() throws {
        let f = try currentShell(); launch(f.app); try startScratchChat(in: f.app)
        let composer = f.app.textViews["composer-input"], draft = "Keep my archived draft"
        composer.click(); composer.typeText(draft)
        let identifier = try selectedThreadIdentifier(in: f.app)
        let row = f.app.buttons[identifier]
        XCTAssertTrue(row.exists); row.rightClick(); f.app.menuItems["Rename…"].click()
        let sheet = f.app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5)); replace(sheet.textFields.firstMatch, with: "Native renamed chat")
        sheet.buttons["sidebar-rename-save"].click()
        XCTAssertTrue(waitForAbsence(sheet, timeout: 5))
        row.rightClick(); f.app.menuItems["Archive"].click()
        f.app.buttons["Show archived chats"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        row.rightClick(); f.app.menuItems["Unarchive"].click()
        f.app.buttons["Show recent chats"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
    }

    private struct CurrentShellFixture { let app: XCUIApplication; let root: URL; let codex: URL; let claude: URL }
    @MainActor private func currentShell(appearance: String = "dark") throws -> CurrentShellFixture {
        let base = try prepareApplication(appearance: appearance, diagnosticPrefix: "native-current-shell")
        let home = base.root.appendingPathComponent("current-home"), codex = home.appendingPathComponent(".codex"), claude = home.appendingPathComponent(".claude")
        for folder in [codex, claude] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        base.app.launchEnvironment["HOME"] = home.path
        base.app.launchEnvironment["CODEX_HOME"] = codex.path
        base.app.launchEnvironment["CLAUDE_CONFIG_DIR"] = claude.path
        base.app.launchEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        base.app.launchArguments += ["-loginShellEnvironmentEnabled", "NO"]
        return .init(app: base.app, root: base.root, codex: codex, claude: claude)
    }
    @MainActor private func launch(_ app: XCUIApplication) {
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
    @MainActor private func startScratchChat(in app: XCUIApplication) throws {
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textViews["composer-input"].waitForExistence(timeout: 10))
    }
    @MainActor private func exerciseEmbeddedSettings(appearance: String) throws {
        let f = try currentShell(appearance: appearance); launch(f.app); try startScratchChat(in: f.app)
        let composer = f.app.textViews["composer-input"], draft = "Unsent draft while settings are embedded"
        composer.click(); composer.typeText(draft)
        let id = try selectedThreadIdentifier(in: f.app)
        f.app.typeKey(",", modifierFlags: .command)
        for page in ["general", "appearance", "notifications", "providers", "models", "conversations", "keyboard", "about"] {
            try showSettingsPage(page, in: f.app)
            XCTAssertEqual(f.app.windows.count, 1)
            XCTAssertTrue(f.app.buttons["Back to chat"].exists)
        }
        capture(f.app, name: appearance + "-embedded-settings")
        f.app.buttons["Back to chat"].click()
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        XCTAssertEqual(try selectedThreadIdentifier(in: f.app), id)
        let snapshot = try waitForPrivateWorkspace(f.root, timeout: 5) { self.findClaudeGUIThread($0, id: id)?["draft"] as? String == draft }
        XCTAssertTrue((try claudeGUIThread(snapshot, id: id)["messages"] as? [Any])?.isEmpty == true)
    }
    @MainActor private func showSettingsPage(_ page: String, in app: XCUIApplication) throws {
        let button = app.buttons["settings-page-" + page]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let side = app.scrollViews.allElementsBoundByIndex.min(by: { $0.frame.width < $1.frame.width })
        for _ in 0..<8 {
            if button.isHittable { break }
            side?.scroll(byDeltaX: 0, deltaY: button.frame.minY < (side?.frame.minY ?? 0) ? 200 : -200)
        }
        XCTAssertTrue(button.isHittable); button.click()
    }
    @MainActor private func openConfiguration(in app: XCUIApplication, provider: String = "Codex") throws {
        app.typeKey(",", modifierFlags: .command); try showSettingsPage("configuration", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "configuration-provider").firstMatch.waitForExistence(timeout: 10))
        if provider != "Codex" { try chooseConfiguration("configuration-provider", value: provider, in: app) }
    }
    @MainActor private func chooseConfiguration(_ identifier: String, value: String, in app: XCUIApplication) throws {
        let picker = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        try revealContentControl(picker, in: app); picker.click()
        let option = app.menuItems[value]
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.click()
    }
    @MainActor private func saveConfiguration(in app: XCUIApplication, expectsError: Bool = false) throws {
        let save = app.buttons["configuration-save"]
        try revealContentControl(save, in: app); XCTAssertTrue(save.isEnabled); save.click()
        if expectsError {
            // The result appears under the Save button and can sit just below the viewport.
            let error = app.descendants(matching: .any).matching(identifier: "configuration-error").firstMatch
            if !error.waitForExistence(timeout: 5) { try revealContentControl(error, in: app) }
            XCTAssertTrue(error.exists)
        }
        else {
            // Saving replaces the document and re-renders the form; bring the result into view.
            let saved = app.descendants(matching: .any).matching(identifier: "configuration-saved").firstMatch
            if !saved.waitForExistence(timeout: 5) { try revealContentControl(saved, in: app) }
            XCTAssertTrue(saved.exists)
            XCTAssertFalse(save.isEnabled)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "configuration-error").firstMatch.exists)
        }
    }
    @MainActor private func revealContentControl(_ control: XCUIElement, in app: XCUIApplication) throws {
        let scroll = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.width < $1.frame.width }))
        // Lazy integration rows do not enter the accessibility tree until scrolled
        // into view. Start an absent row search at the top of the content pane.
        if !control.waitForExistence(timeout: 1) { scroll.scroll(byDeltaX: 0, deltaY: 12_000) }
        for _ in 0..<35 {
            if control.exists && control.isHittable && scroll.frame.insetBy(dx: -2, dy: -2).contains(control.frame) { return }
            scroll.scroll(byDeltaX: 0, deltaY: control.exists && control.frame.minY < scroll.frame.minY ? 350 : -350)
        }
        XCTFail("Settings control must fit inside its scroll viewport: " + control.identifier)
    }
    @MainActor private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(text)
        XCTAssertTrue(waitForValue(field, value: text, timeout: 5))
    }
    @MainActor private func openComposerSkills(in app: XCUIApplication) throws {
        let menu = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Add files and tools")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.click()
        let choice = app.menuItems["composer-skills"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.click()
    }
    private func writeJSON(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path)
    }
    private func readJSON(_ path: URL) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]) }

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
        try openComposerSkills(in: app)
        let search = app.textFields["composer-skills-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.click(); search.typeText("ship")
        XCTAssertTrue(ship.waitForExistence(timeout: 5)); search.typeKey(.return, modifierFlags: [])
        let manual = "Keep a second draft: $ship-check "
        XCTAssertTrue(waitForValue(composer, value: manual, timeout: 5)); XCTAssertTrue(waitForAbsence(search, timeout: 5))

        try openComposerSkills(in: app); XCTAssertTrue(search.waitForExistence(timeout: 5))
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
        let threadID = try selectedThreadIdentifier(in: app), draft = "Preserve this unsent draft while reviewing Codex authentication settings."
        composer.click(); composer.typeText(draft); XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        let before = try waitForPrivateWorkspace(root, timeout: 5) { snapshot in
            guard let threads = snapshot["threads"] as? [[String: Any]], threads.count == 1 else { return false }
            return threads[0]["draft"] as? String == draft
        }
        let originalThreads = try JSONSerialization.data(withJSONObject: XCTUnwrap(before["threads"]), options: .sortedKeys)
        let preference = root.appendingPathComponent("CodexSettings/runtime.json")

        // App-managed ChatGPT sign-in is deferred: Settings offers only the
        // existing CLI account, and viewing it never saves a preference.
        app.typeKey(",", modifierFlags: .command)
        try showSettingsPage("providers", in: app)
        var settings = codexAgentSettings(in: app)
        XCTAssertTrue(settings.buttons["codex-account-refresh"].waitForExistence(timeout: 10), "A CLI-default runtime shows the existing CLI account.")
        assertNoAppManagedSignIn(in: settings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preference.path), "Viewing Settings must never save an authentication mode or home.")
        capture(app, name: prefix + "-cli-default-account")
        app.buttons["Back to chat"].click(); XCTAssertTrue(waitForAbsence(app.textFields["settings-search"], timeout: 5))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(privateWorkspaceSnapshot(root)["threads"]), options: .sortedKeys), originalThreads)
        let beforeRestart = try JSONSerialization.data(withJSONObject: historyWire(wire), options: .sortedKeys)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

        // An app-managed mode saved by an earlier version is kept as saved and
        // shown as deferred, without a CLI probe, sign-in or preference rewrite.
        let saved = try saveOwnedCodexPreference(preference, home: sharedHome)
        app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10))
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        app.typeKey(",", modifierFlags: .command)
        try showSettingsPage("providers", in: app)
        settings = codexAgentSettings(in: app)
        let deferred = "This saved runtime uses an app-managed account. New app-managed sign-in is deferred; its existing configuration is unchanged."
        XCTAssertTrue(settings.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", deferred, deferred)).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(settings.buttons["codex-account-refresh"].exists, "An app-managed runtime must not offer the CLI account reader.")
        assertNoAppManagedSignIn(in: settings)
        XCTAssertEqual(try Data(contentsOf: preference), saved, "Opening Settings must not migrate, rewrite or bind an account to the saved mode.")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: historyWire(wire), options: .sortedKeys), beforeRestart,
                       "Reopening saved owned mode must not launch a CLI probe, sign in, read saved credentials or submit input.")
        capture(app, name: prefix + "-saved-owned-mode-deferred")
        app.buttons["Back to chat"].click(); XCTAssertTrue(waitForAbsence(app.textFields["settings-search"], timeout: 5))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5)); XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(privateWorkspaceSnapshot(root)["threads"]), options: .sortedKeys), originalThreads,
                       "Global authentication preferences must not retarget, recapture, enqueue or rewrite an existing conversation.")
        let frames = try historyWire(wire), allowed: Set<String> = ["initialize", "account/read", "account/rateLimits/read"]
        XCTAssertTrue(frames.allSatisfy { allowed.contains($0["method"] as? String ?? "") }, "Only closed-world read-only CLI metadata is allowed; no native turn, auth or configuration mutation may occur.")
        for frame in frames where frame["method"] as? String == "account/read" {
            let params = try XCTUnwrap(frame["params"] as? [String: Any])
            XCTAssertEqual(Set(params.keys), ["refreshToken"]); XCTAssertEqual(params["refreshToken"] as? Bool, false)
        }
        XCTAssertEqual(try Data(contentsOf: preference), saved)
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertEqual(try Data(contentsOf: cliSentinel), cliBytes); XCTAssertEqual(try Data(contentsOf: sharedSentinel), sharedBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sharedHome.path), [sharedSentinel.lastPathComponent], "A saved mode must not initialize, migrate or overwrite its shared home.")
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: prefix + "-preserved-head"), originalHead)
        capture(app, name: prefix + "-conversation-and-draft-preserved")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func codexAgentSettings(in app: XCUIApplication) -> XCUIElement {
        let settings = app.windows.containing(.any, identifier: "codex-runtime-selection").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1, "Codex settings must open inside the chat window.")
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(settings.frame))
        return settings
    }

    @MainActor private func assertNoAppManagedSignIn(in settings: XCUIElement) {
        for identifier in ["codex-authentication-mode", "codex-authentication-home", "codex-authentication-apply", "codex-authentication-sign-in",
                           "codex-authentication-refresh", "codex-authentication-open-browser", "codex-authentication-cancel"] {
            XCTAssertFalse(settings.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists,
                           "App-managed ChatGPT sign-in is deferred and must not be offered: \(identifier).")
        }
        let apply = settings.buttons["codex-runtime-apply"]
        XCTAssertTrue(apply.exists); XCTAssertFalse(apply.isEnabled, "Settings must hold no unapplied runtime or authentication change.")
    }

    /// The owner-only preference an earlier version saved for app-managed
    /// ChatGPT sign-in: default instance, installed CLI and an explicit shared home.
    private func saveOwnedCodexPreference(_ file: URL, home: URL) throws -> Data {
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Only this fixture may create the saved preference.")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let value: [String: Any] = ["instanceID": "246F9D3D-8651-4B80-B1F8-ADBA2CFDF622", "selection": "existingCLI",
                                    "executable": "codex", "homeDirectory": home.path, "authenticationMode": "ownedChatGPT"]
        let bytes = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
        return bytes
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
        let refresh = app.buttons["Refresh models"]
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
        openNativeProviderMenu(in: app); app.buttons["Refresh models"].click()
        let modelSummary = app.buttons["provider-model-menu"]
        let refreshedSummary = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND value CONTAINS %@", "Offline Future Refreshed"), object: modelSummary)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshedSummary], timeout: 10), .completed,
                       "The current model menu's exposed summary must reflect the refreshed catalog before opening its new effort menu.")
        openNativeProviderMenu(in: app)
        openModelOptions(in: app)
        let reasoning = app.menuItems["codex-reasoning-menu"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 10)); reasoning.click()
        XCTAssertFalse(app.menuItems["codex-reasoning-experimental-effort"].exists, "Refresh must remove an effort no longer advertised for the same wire model.")
        let currentDefault = app.menuItems["codex-reasoning-default"]
        XCTAssertTrue(currentDefault.waitForExistence(timeout: 5)); XCTAssertTrue(currentDefault.isEnabled); currentDefault.click()
        _ = try waitForNativeModel(root, model: "future-native-model", effort: "deep")
        openNativeProviderMenu(in: app)
        openModelOptions(in: app)
        let cliDefault = app.menuItems["CLI default model"]
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
        try showSettingsPage("providers", in: app)
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
        let scroll = settings.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.width < $1.frame.width }) ?? settings
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
        app.buttons["Back to chat"].click()
        XCTAssertTrue(waitForAbsence(app.textFields["settings-search"], timeout: 5))
    }

    @MainActor private func openNativeProviderMenu(in app: XCUIApplication) {
        let menu = app.descendants(matching: .any).matching(identifier: "provider-model-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); XCTAssertTrue(menu.isEnabled && menu.isHittable)
        if !app.textFields["Search models"].exists { menu.click() }
    }
    @MainActor private func openModelOptions(in app: XCUIApplication) {
        // The borderless options menu exposes its visible text as the menu button's title.
        let options = app.menuButtons.matching(NSPredicate(format: "label == %@ OR title == %@", "Model options", "Model options")).firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5)); XCTAssertTrue(options.isEnabled && options.isHittable); options.click()
    }
    @MainActor private func chooseNativeProviderModel(_ model: String, in app: XCUIApplication) throws {
        openNativeProviderMenu(in: app)
        let item = app.buttons["provider-model-codex:" + model]
        XCTAssertTrue(item.waitForExistence(timeout: 10)); XCTAssertTrue(item.isEnabled && item.isHittable); item.click()
    }
    @MainActor private func chooseNativeReasoning(_ effort: String?, in app: XCUIApplication) throws {
        openNativeProviderMenu(in: app)
        openModelOptions(in: app)
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
                  let run = (thread["runHistory"] as? [[String: Any]])?.first else { return false }
            return run["status"] as? String == "completed"
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
        let claude = app.buttons["provider-model-claude:claude-ui-model"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5) && claude.isEnabled); claude.click()
        let threadID = try selectedThreadIdentifier(in: app)
        _ = try waitForPrivateWorkspace(f.root, timeout: 10) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID) else { return false }
            return thread["provider"] as? String == "claude" && thread["claudeRuntimeConfiguration"] != nil
        }
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
        // Automatic run checkpoints are captured after each reply. Quitting during a
        // capture records it as interrupted, so compare history once they settle.
        let before = try threadWithSettledRunCheckpoints(f.root, threadID: threadID)
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

    @MainActor private func threadWithSettledRunCheckpoints(_ root: URL, threadID: String) throws -> [String: Any] {
        let running: Set<String> = ["resolving", "capturing"]
        let snapshot = try waitForPrivateWorkspace(root, timeout: 30) { snapshot in
            guard let thread = self.findClaudeGUIThread(snapshot, id: threadID), thread["activeRun"] == nil,
                  let runs = thread["runHistory"] as? [[String: Any]], !runs.isEmpty else { return false }
            return runs.allSatisfy { run in
                guard let checkpoints = run["checkpoints"] as? [String: Any] else { return true }
                let attempts = [checkpoints["baseline"], checkpoints["postRun"]].compactMap { $0 as? [String: Any] }
                return checkpoints["pendingStart"] == nil && !attempts.contains { running.contains($0["phase"] as? String ?? "") }
            }
        }
        return try claudeGUIThread(snapshot, id: threadID)
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
        let claude = app.buttons["provider-model-claude:claude-ui-model"]
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
        let allowed = ["codex": ["codex_history_ui.py", "codex_steering_ui.py", "codex_models_ui.py"], "gh": ["github_pr_ui.py"], "claude": ["claude_history_ui.py"]]
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
        let header = app.buttons["Chats in \(projectName)"]
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
        let rename = app.menuItems["Rename…"]
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
        let renamedHeader = app.buttons["Chats in \(renamed)"]
        XCTAssertTrue(renamedHeader.waitForExistence(timeout: 5)); renamedHeader.click()
        XCTAssertTrue(app.buttons["Chats in \(renamed)"].waitForExistence(timeout: 5))
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "thread-", "Selected")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5) && (selected.value as? String == "Selected"), "Collapsing must keep the selected conversation visible.")
        XCTAssertEqual(composer.value as? String, draft)
        assertSidebarFitsDisplay(app, projectHeader: app.buttons["Chats in \(renamed)"])
        capture(app, name: "\(appearance)-collapsed-selected")

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Graceful quit must flush the composer draft.")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["Chats in \(renamed)"].waitForExistence(timeout: 10), "The renamed project and collapsed state must persist.")
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(selected.exists && (selected.value as? String == "Selected"))
        assertSidebarFitsDisplay(app, projectHeader: app.buttons["Chats in \(renamed)"])
        capture(app, name: "\(appearance)-reopened")
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(appearance)-reopened-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)

        let collapsedHeader = app.buttons["Chats in \(renamed)"]
        collapsedHeader.rightClick()
        let removeItem = app.menuItems["Remove Project…"]
        XCTAssertTrue(removeItem.waitForExistence(timeout: 5)); removeItem.click()
        let confirmation = app.sheets.containing(.button, identifier: "Remove Project").firstMatch
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
        let emptyDescription = "What should we work on?"
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", emptyDescription, emptyDescription)).element.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start a conversation"].exists)
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
        // The project actions control is a split button: its trailing arrow opens the menu with Run Script….
        let actions = app.toolbars.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["project-actions-run", "project-actions-menu"])).firstMatch
        if actions.waitForExistence(timeout: 5), actions.isHittable {
            XCTAssertTrue(actions.isEnabled)
            if actions.identifier == "project-actions-menu" { actions.click() }
            else { actions.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).click() }
        } else {
            let overflow = app.toolbars.popUpButtons["more toolbar items"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 5)); XCTAssertTrue(overflow.isHittable); overflow.click()
        }
        let script = app.menuItems["Run Script…"]
        XCTAssertTrue(script.waitForExistence(timeout: 5)); XCTAssertTrue(script.isEnabled && script.isHittable); script.click()
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
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "thread-", "project-thread-"))
        let selected = NSPredicate(format: "value == %@", "Selected")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in rows.matching(selected).count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let row = try XCTUnwrap(rows.matching(selected).allElementsBoundByIndex.first)
        return row.identifier.replacingOccurrences(of: "project-thread-", with: "thread-")
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
            ("New chat", app.buttons["New chat"]),
            ("Sort projects", app.descendants(matching: .any).matching(identifier: "sidebar-project-sort").firstMatch),
            ("Search chats", app.buttons["Search chats"]),
            ("Project header", projectHeader),
            ("Settings", app.buttons["Settings"]),
            ("Archive", app.buttons["Show archived chats"]),
        ]
        for (name, control) in controls {
            XCTAssertTrue(control.exists, "The sidebar must expose its \(name) control.")
            let frame = control.frame
            XCTAssertTrue(frame.width > 0 && frame.height > 0 && window.contains(frame) && display.contains(frame),
                          "The \(name) control must be wholly inside the window and display, without clipping: \(frame).")
        }
    }
}
