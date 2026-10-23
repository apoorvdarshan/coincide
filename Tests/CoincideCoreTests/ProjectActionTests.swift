import Darwin
import Foundation
import Testing
@testable import CoincideCore

private func action(_ name: String, _ command: String = "echo ok", setup: Bool = false, wait: Bool = false, settle: Bool = false,
                    preview: String = "", autoOpen: Bool = false, shortcut: ProjectActionShortcut? = nil, in actions: [ProjectAction] = []) throws -> [ProjectAction] {
    try ProjectActions.adding(.init(name: name, command: command, runOnWorktreeCreate: setup, waitForSetup: wait, runOnSettle: settle,
                                    previewURL: preview, autoOpenPreview: autoOpen, shortcut: shortcut), to: actions)
}

@Test func projectActionIDsNormalizeLikeT3AndAvoidCollisions() throws {
    #expect(ProjectActions.nextID(name: "  Run Dev Server! ", existing: []) == "run-dev-server")
    #expect(ProjectActions.nextID(name: "Test", existing: ["test"]) == "test-2")
    #expect(ProjectActions.nextID(name: "Test", existing: ["test", "test-2"]) == "test-3")
    #expect(ProjectActions.nextID(name: "✨", existing: []) == "script")
    let long = ProjectActions.nextID(name: "An extremely long action name for testing", existing: [])
    #expect(long.count <= ProjectAction.maximumIDLength && ProjectActions.isValidID(long) && !long.hasSuffix("-"))
    let suffixed = ProjectActions.nextID(name: "An extremely long action name for testing", existing: [long])
    #expect(suffixed.count <= ProjectAction.maximumIDLength && suffixed.hasSuffix("-2") && ProjectActions.isValidID(suffixed))
    #expect(!ProjectActions.isValidID("Bad ID") && !ProjectActions.isValidID("-a") && !ProjectActions.isValidID(""))
}

@Test func savingASetupOrSettleRoleReleasesItFromOtherActionsAndNormalizesFields() throws {
    var actions = try action("Install", "npm ci", setup: true, wait: true)
    actions = try action("Clean", "rm -rf dist", settle: true, in: actions)
    actions = try action("Bootstrap", "make bootstrap", setup: true, in: actions)
    #expect(actions.map(\.id) == ["install", "clean", "bootstrap"])
    #expect(!actions[0].runOnWorktreeCreate && !actions[0].waitForSetup && actions[2].runOnWorktreeCreate)
    #expect(actions[1].runOnSettle)
    actions = try ProjectActions.updating("install", with: .init(name: "Install", command: "npm ci", runOnSettle: true), in: actions)
    #expect(actions[0].runOnSettle && !actions[1].runOnSettle && actions[2].runOnWorktreeCreate)
    #expect(try actions[2].script().runsAsynchronously, "Setup without waiting starts the agent while it runs.")
    let waiting = try ProjectAction(id: "wait", input: .init(name: "Wait", command: "x", runOnWorktreeCreate: true, waitForSetup: true))
    #expect(try !waiting.script().runsAsynchronously)
    let notSetup = try ProjectAction(id: "nope", input: .init(name: "N", command: "x", waitForSetup: true, previewURL: "  ", autoOpenPreview: true))
    #expect(!notSetup.waitForSetup && notSetup.previewURL == nil && !notSetup.autoOpenPreview)
    let preview = try ProjectAction(id: "dev", input: .init(name: " Dev ", command: " bun dev ", previewURL: "  http://localhost:5173  ", autoOpenPreview: true))
    #expect(preview.name == "Dev" && preview.command == "bun dev" && preview.previewURL == "http://localhost:5173" && preview.autoOpenPreview)
    #expect(throws: ProjectActionError.self) { try ProjectAction(id: "x", input: .init(name: "", command: "x")) }
    #expect(throws: ProjectActionError.self) { try ProjectAction(id: "x", input: .init(name: "x", command: "  ")) }
    #expect(throws: ProjectActionError.self) { try ProjectAction(id: "x", input: .init(name: "x", command: "x", previewURL: "file:///etc/passwd")) }
    #expect(throws: ProjectActionError.self) { try ProjectActions.deleting("missing", from: actions) }
    #expect(try ProjectActions.deleting("clean", from: actions).map(\.id) == ["install", "bootstrap"])
    #expect(ProjectActions.moving(actions, fromOffsets: [2], toOffset: 0).map(\.id) == ["bootstrap", "install", "clean"])
    #expect(ProjectActions.moving(actions, fromOffsets: [0], toOffset: 2).map(\.id) == ["clean", "install", "bootstrap"])
}

@Test func importingFromT3JSONSkipsDuplicateCommandsOrNamesAndKeepsRoles() throws {
    let file = [try ProjectScript(name: "Dev", command: "bun dev", previewURL: "http://localhost:3000", autoOpenPreview: true),
                try ProjectScript(name: "test", command: "bun test", icon: .test),
                try ProjectScript(name: "Setup", command: "bun install", runOnWorktreeCreate: true, runsAsynchronously: false)]
    let existing = try action("TEST", "different")
    let importable = ProjectActions.importable(file, existing: existing)
    #expect(importable.map(\.name) == ["Dev", "Setup"])
    let input = ProjectActionInput(script: file[2])
    #expect(input.runOnWorktreeCreate && input.waitForSetup && input.shortcut == nil)
    let imported = try ProjectActions.adding(.init(script: file[0]), to: existing)
    #expect(imported[1].previewURL == "http://localhost:3000" && imported[1].autoOpenPreview)
    #expect(ProjectActions.importable(file, existing: try ProjectActions.adding(.init(script: file[2]), to: imported)).isEmpty)
}

@Test func actionShortcutsRequireCommandOrControlAndLeaveLiveConflictsToResolver() throws {
    let shortcut = try ProjectActionShortcut(key: "R", command: true, shift: true)
    #expect(shortcut.key == "r" && shortcut.displayLabel == "⇧⌘R")
    #expect(try ProjectActionShortcut(key: "1", option: true, control: true).displayLabel == "⌃⌥1")
    #expect(throws: ProjectActionError.self) { try ProjectActionShortcut(key: "r", option: true) }
    #expect(try ProjectActionShortcut(key: "q", command: true).key == "q")
    #expect(try ProjectActionShortcut(key: "t", command: true, option: true).option)
    #expect(throws: ProjectActionError.self) { try ProjectActionShortcut(key: "ab", command: true) }
    #expect(throws: ProjectActionError.self) { try ProjectActionShortcut(key: " ", command: true) }
    let first = try action("One", shortcut: shortcut)
    #expect(throws: ProjectActionError(.duplicateShortcut)) { try action("Two", shortcut: shortcut, in: first) }
    let decoded = try JSONDecoder().decode(ProjectActionShortcut.self, from: JSONEncoder().encode(shortcut))
    #expect(decoded == shortcut)
    #expect(try JSONDecoder().decode(ProjectActionShortcut.self, from: Data(#"{"key":"w","command":true}"#.utf8)).key == "w")
}

@Test func actionDigestPinsExecutionFieldsButNotTheShortcut() throws {
    let base = try ProjectAction(id: "dev", input: .init(name: "Dev", command: "bun dev"))
    let keyed = try ProjectAction(id: "dev", input: .init(name: "Dev", command: "bun dev", shortcut: try .init(key: "d", command: true, option: true)))
    let changed = try ProjectAction(id: "dev", input: .init(name: "Dev", command: "bun dev --host"))
    let setup = try ProjectAction(id: "dev", input: .init(name: "Dev", command: "bun dev", runOnWorktreeCreate: true))
    #expect(base.digest.count == 32 && base.digest == keyed.digest)
    #expect(base.digest != changed.digest && base.digest != setup.digest)
    #expect(try ProjectAction(id: "other", input: .init(name: "Dev", command: "bun dev")).digest != base.digest)
    #expect(setup.menuLabel == "Dev (setup)")
    #expect(ProjectActions.menuLabel(name: "Clean", setup: true, settle: true) == "Clean (setup, on settle)")
    #expect(try JSONDecoder().decode(ProjectAction.self, from: JSONEncoder().encode(keyed)) == keyed)
}

@Test func catalogPrefersProjectActionsAndChoosesPrimaryLikeT3() throws {
    let file = try ProjectConfiguration(scripts: [
        .init(name: "Setup", command: "bun install", runOnWorktreeCreate: true),
        .init(name: "Dev", command: "bun dev"),
        .init(name: "Clean", command: "rm -rf dist", runOnSettle: true)
    ])
    let fromFile = ProjectScriptCatalog(actions: nil, configuration: file)
    #expect(fromFile.origin == .checkoutFile && fromFile.scripts.map(\.fileIndex) == [0, 1, 2])
    #expect(fromFile.primary(preferredID: nil)?.script.name == "Dev")
    #expect(fromFile.script(for: .setup)?.script.name == "Setup" && fromFile.script(for: .settle)?.script.name == "Clean")
    let remembered = fromFile.scripts[2].id
    let reordered = ProjectScriptCatalog(actions: nil, configuration: try ProjectConfiguration(scripts: file.scripts.reversed()))
    #expect(reordered.primary(preferredID: remembered)?.script.name == "Clean", "A remembered file script survives reordering.")
    let roleOnly = ProjectScriptCatalog(actions: nil, configuration: try ProjectConfiguration(scripts: [file.scripts[2], file.scripts[0]]))
    #expect(roleOnly.primary(preferredID: nil)?.script.name == "Setup", "Falls back to the first script that does not settle.")
    #expect(ProjectScriptCatalog(actions: nil, configuration: try ProjectConfiguration(scripts: [file.scripts[2]])).primary(preferredID: nil) == nil)
    let actions = try action("Lint", "bun lint")
    let owned = ProjectScriptCatalog(actions: actions, configuration: file)
    #expect(owned.origin == .projectActions && owned.scripts.map(\.id) == ["lint"] && owned.scripts[0].action?.id == "lint")
    #expect(owned.importable.count == 3 && owned.script(for: .setup) == nil)
    #expect(ProjectScriptCatalog(actions: [], configuration: file).scripts.isEmpty, "An empty app list overrides t3.json.")
    #expect(ProjectScriptCatalog(actions: nil, configuration: nil).origin == .none)
}

@Test func repositoryBackedDefaultsResolveProjectThenAppThenFileThenBuiltIn() throws {
    let file = try ProjectConfiguration(defaultThreadEnvMode: .worktree, worktreeSubmodules: .topLevel)
    #expect(ProjectDefaultsResolver.worktreeSubmodules(project: nil, app: nil, repository: nil) == .init(value: .recursive, source: .builtIn))
    #expect(ProjectDefaultsResolver.threadEnvironmentMode(project: nil, app: nil, repository: nil) == .init(value: .local, source: .builtIn))
    #expect(ProjectDefaultsResolver.worktreeSubmodules(project: nil, app: nil, repository: file) == .init(value: .topLevel, source: .repository))
    #expect(ProjectDefaultsResolver.worktreeSubmodules(project: nil, app: ProjectWorktreeSubmoduleMode.none, repository: file) == .init(value: ProjectWorktreeSubmoduleMode.none, source: .app))
    #expect(ProjectDefaultsResolver.worktreeSubmodules(project: .recursive, app: ProjectWorktreeSubmoduleMode.none, repository: file) == .init(value: .recursive, source: .project))
    #expect(ProjectDefaultsResolver.threadEnvironmentMode(project: nil, app: nil, repository: file) == .init(value: .worktree, source: .repository))
    #expect(ProjectDefaultsResolver.threadEnvironmentMode(project: .local, app: .worktree, repository: file) == .init(value: .local, source: .project))
    let invalid = try? ProjectConfiguration.parse(#"{"worktreeSubmodules": "sometimes"}"#)
    #expect(invalid == nil)
    #expect(ProjectDefaultsResolver.worktreeSubmodules(project: nil, app: nil, repository: invalid).source == .builtIn)
}

@Test func previewURLsAllowOnlyHTTPWithoutCredentials() throws {
    let local = try PreviewURLPolicy.validate("  http://localhost:5173/app?x=1  ")
    #expect(local.url.absoluteString == "http://localhost:5173/app?x=1" && local.port == 5173 && local.isLoopback)
    #expect(try PreviewURLPolicy.validate("https://example.com").port == 443)
    #expect(try !PreviewURLPolicy.validate("https://example.com").isLoopback)
    #expect(try PreviewURLPolicy.validate("http://[::1]:8080").host == "::1")
    #expect(try PreviewURLPolicy.validate("http://app.localhost:3000").isLoopback)
    for value in ["", "ftp://localhost", "javascript:alert(1)", "file:///tmp/x", "http://user:pass@localhost:3000", "http://user@localhost",
                  "http://localhost:99999", "http://local host", "localhost:3000", "http:///path"] {
        #expect(throws: ProjectActionError.self, "\(value)") { try PreviewURLPolicy.validate(value) }
    }
}

@Test func projectMonogramsMatchT3Examples() {
    #expect(ProjectMonogram(name: "Nebula").text == "NA")
    #expect(ProjectMonogram(name: "Silver Orchard").text == "SO")
    #expect(ProjectMonogram(name: "M7 Forge").text == "M7")
    #expect(ProjectMonogram(name: "  ").text == "PR")
    #expect(ProjectMonogram(name: "x").text == "XX")
    #expect(ProjectMonogram(name: "über-tool").text == "ÜT")
    #expect(ProjectMonogram(name: "Nebula").color == ProjectMonogram(name: " nebula ").color)
    #expect(ProjectIconColor.allCases.count == 18)
}

@Test func projectSettingsKeysShareRepositoryIdentityAndKeepCheckoutFallback() throws {
    var project = WorkspaceProject(path: "/tmp/coincide-key-checkout")
    #expect(ProjectSettingsKey.candidates(for: project) == ["checkout:" + "\(project.path.utf8.count):" + project.path])
    project.repositoryIdentity = try RepositoryIdentity(remote: #require(RepositoryIdentity.normalizedRemote("https://github.com/acme/app.git")),
                                                        remoteName: "origin", rootPath: "/tmp/coincide-key-checkout", projectRelativePath: "")
    let keys = ProjectSettingsKey.candidates(for: project)
    #expect(keys.count == 2 && keys[0].hasPrefix("repository:") && keys[1].hasPrefix("checkout:"))
    var other = WorkspaceProject(path: "/tmp/coincide-key-other"); other.repositoryIdentity = project.repositoryIdentity
    #expect(ProjectSettingsKey.primary(for: other) == keys[0], "Checkouts of one repository share settings.")
}

private func settingsRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-project-settings-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func projectSettingsFilesRoundTripPrivatelyAndPreserveInvalidFiles() throws {
    let base = try settingsRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let root = ProjectSettingsFiles.root(dataRoot: base)
    #expect(try ProjectSettingsFiles.load(root: root, key: "missing") == nil)
    let document = ProjectSettingsDocument(key: "checkout:4:/tmp", actions: try action("Dev", "bun dev"), defaultThreadEnvMode: .worktree,
                                           worktreeSubmodules: .topLevel, icon: .monogram(text: "AB", color: .teal))
    try ProjectSettingsFiles.save(document, root: root)
    let url = ProjectSettingsFiles.fileURL(root: root, key: document.key)
    let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    #expect(mode & 0o777 == 0o600)
    #expect(try ProjectSettingsFiles.load(root: root, key: document.key) == document)
    #expect(try ProjectSettingsFiles.load(root: root, keys: ["other", document.key])?.key == document.key)
    try ProjectSettingsFiles.save(.init(key: document.key), root: root)
    #expect(!FileManager.default.fileExists(atPath: url.path), "Resetting every override returns to inheritance.")
    try Data("{not json".utf8).write(to: url)
    #expect(throws: CoincideError.self) { try ProjectSettingsFiles.load(root: root, key: document.key) }
    #expect(try Data(contentsOf: url) == Data("{not json".utf8))
    try Data(#"{"version": 99, "key": "checkout:4:/tmp"}"#.utf8).write(to: url)
    #expect(throws: CoincideError.self) { try ProjectSettingsFiles.load(root: root, key: document.key) }
    try FileManager.default.removeItem(at: url)
    let elsewhere = base.appendingPathComponent("elsewhere.json")
    try JSONEncoder().encode(document).write(to: elsewhere)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
    #expect(throws: CoincideError.self) { try ProjectSettingsFiles.load(root: root, key: document.key) }
    try FileManager.default.removeItem(at: url)
    try JSONEncoder().encode(ProjectSettingsDocument(key: "another")).write(to: url)
    #expect(throws: CoincideError.self, "A document saved under another key is rejected.") { try ProjectSettingsFiles.load(root: root, key: document.key) }
    #expect(throws: (any Error).self) { try ProjectSettingsFiles.save(.init(key: "k", icon: .image(path: "../escape.png")), root: root) }
}

@Test func legacyCheckoutFilePlansDecodeUnchangedAndActionPlansRoundTrip() async throws {
    let base = try settingsRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let checkout = base.appendingPathComponent("checkout"); try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try JSONEncoder().encode(try ProjectConfiguration(scripts: [.init(name: "Setup", command: "echo file", runOnWorktreeCreate: true)])).write(to: checkout.appendingPathComponent("t3.json"))
    let files = WorkspaceFileService(root: checkout)
    let filePlan = try await ProjectScriptExecutionPlan.capture(scriptIndex: 0, using: files, projectRoot: checkout, shell: URL(fileURLWithPath: "/bin/sh"))
    await files.close()
    let encoded = try JSONEncoder().encode(filePlan)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["projectAction"] == nil && object["configurationRevision"] != nil, "Checkout plans keep their original encoding.")
    #expect(try JSONDecoder().decode(ProjectScriptExecutionPlan.self, from: encoded) == filePlan)
    let root = ProjectSettingsFiles.root(dataRoot: base), key = "checkout:test"
    let actions = try action("Bootstrap", "echo app", setup: true)
    try ProjectSettingsFiles.save(.init(key: key, actions: actions), root: root)
    let actionPlan = try await ProjectScriptExecutionPlan.capture(action: actions[0], index: 0, settingsKey: key, settingsRoot: root, workspace: checkout,
                                                                  projectRoot: checkout, shell: URL(fileURLWithPath: "/bin/sh"))
    #expect(actionPlan.configurationRevision == nil && actionPlan.projectAction?.actionID == "bootstrap" && actionPlan.script.command == "echo app")
    #expect(actionPlan.workspaceIdentity == filePlan.workspaceIdentity && actionPlan.workspacePath == filePlan.workspacePath)
    let actionData = try JSONEncoder().encode(actionPlan)
    #expect(try JSONDecoder().decode(ProjectScriptExecutionPlan.self, from: actionData) == actionPlan)
    #expect(try actionPlan.projectAction?.verify(script: actionPlan.script) == actions[0])
    object["projectAction"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(actionPlan.projectAction))
    #expect(throws: (any Error).self, "A plan cannot pin both sources.") {
        try JSONDecoder().decode(ProjectScriptExecutionPlan.self, from: JSONSerialization.data(withJSONObject: object))
    }
    object.removeValue(forKey: "projectAction"); object.removeValue(forKey: "configurationRevision")
    #expect(throws: (any Error).self, "A plan must pin one source.") {
        try JSONDecoder().decode(ProjectScriptExecutionPlan.self, from: JSONSerialization.data(withJSONObject: object))
    }
    try ProjectSettingsFiles.save(.init(key: key, actions: try ProjectActions.updating("bootstrap", with: .init(name: "Bootstrap", command: "echo edited", runOnWorktreeCreate: true), in: actions)), root: root)
    #expect(throws: ProjectScriptExecutionError(.configurationChanged)) { try actionPlan.projectAction?.verify(script: actionPlan.script) }
}

@Test func setupPlannerHonorsEditedActionRolesOverT3JSONAndNeverExecutes() async throws {
    let base = try settingsRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("source"), worktree = base.appendingPathComponent("worktree")
    for folder in [source, worktree] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try JSONEncoder().encode(try ProjectConfiguration(scripts: [.init(name: "File setup", command: "touch file-ran", runOnWorktreeCreate: true, runOnSettle: true)]))
        .write(to: worktree.appendingPathComponent("t3.json"))
    let root = ProjectSettingsFiles.root(dataRoot: base), project = WorkspaceProject(path: source.path), keys = ProjectSettingsKey.candidates(for: project)
    func plan(_ role: ProjectScriptRole, workspace: URL = worktree, settings: Bool = true) async throws -> ProjectScriptExecutionPlan? {
        try await ProjectScriptSetupPlanner.plan(.init(id: UUID(), projectRoot: source, workspacePath: workspace, role: role,
                                                       settingsRoot: settings ? root : nil, settingsKeys: settings ? keys : []))
    }
    #expect(try await plan(.setup)?.script.name == "File setup", "Without app-owned actions, t3.json roles apply.")
    var actions = try action("Manual", "touch manual-ran")
    actions = try action("App setup", "touch app-ran", setup: true, wait: true, in: actions)
    try ProjectSettingsFiles.save(.init(key: keys[0], actions: actions), root: root)
    let setup = try #require(try await plan(.setup))
    #expect(setup.script.name == "App setup" && setup.scriptIndex == 1 && !setup.script.runsAsynchronously && setup.projectAction?.settingsKey == keys[0])
    #expect(try await plan(.settle) == nil, "The app list has no settle role, so t3.json's settle role no longer applies.")
    actions = try ProjectActions.updating("manual", with: .init(name: "Manual", command: "touch manual-ran", runOnSettle: true), in: actions)
    try ProjectSettingsFiles.save(.init(key: keys[0], actions: actions), root: root)
    #expect(try await plan(.settle)?.script.name == "Manual")
    #expect(try await plan(.settle, workspace: source) == nil, "Settle never runs in the main checkout.")
    #expect(try await plan(.setup, settings: false)?.script.name == "File setup")
    try ProjectSettingsFiles.save(.init(key: keys[0], actions: []), root: root)
    #expect(try await plan(.setup) == nil, "An empty app list is an explicit override.")
    try Data("{".utf8).write(to: ProjectSettingsFiles.fileURL(root: root, key: keys[0]))
    await #expect(throws: CoincideError.self) { try await plan(.setup) }
    for name in ["file-ran", "app-ran", "manual-ran"] {
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent(name).path), "Planning never executes a command.")
    }
}

@Test func iconResolverPrefersIconPathThenCandidatesAndStaysInsideTheCheckout() async throws {
    let base = try settingsRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let checkout = base.appendingPathComponent("checkout")
    try FileManager.default.createDirectory(at: checkout.appendingPathComponent("public"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: checkout.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data("candidate".utf8).write(to: checkout.appendingPathComponent("public/favicon.png"))
    try Data("later".utf8).write(to: checkout.appendingPathComponent("assets/logo.svg"))
    try Data("declared".utf8).write(to: checkout.appendingPathComponent("assets/brand.svg"))
    let outside = base.appendingPathComponent("secret.png"); try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: checkout.appendingPathComponent("favicon.svg"), withDestinationURL: outside)
    try Data(count: ProjectIconResolver.maximumBytes + 1).write(to: checkout.appendingPathComponent("favicon.ico"))
    let files = WorkspaceFileService(root: checkout)
    let candidate = try #require(try await ProjectIconResolver.resolve(using: files))
    #expect(candidate.relativePath == "public/favicon.png" && candidate.data == Data("candidate".utf8), "Escaping links and oversized files are skipped.")
    let declared = try #require(try await ProjectIconResolver.resolve(using: files, preferred: ["assets/brand.svg"]))
    #expect(declared.relativePath == "assets/brand.svg" && declared.fileExtension == "svg")
    #expect(try await ProjectIconResolver.resolve(using: files, preferred: ["../secret.png", "/etc/hosts.png", "README"])?.relativePath == "public/favicon.png")
    await files.close()
    #expect(!ProjectIconResolver.isRelativePath("a/../b.png") && ProjectIconResolver.isRelativePath("a/b.png"))
}

private actor ActionHelperOutput {
    var bytes = Data()
    func append(_ chunk: ProjectScriptOutputChunk) { bytes.append(chunk.data) }
    func text() -> String { String(decoding: bytes, as: UTF8.self) }
}

@Test(.timeLimit(.minutes(1)))
func managedHelperRunsAppOwnedActionsOnlyWhileTheirPinnedSettingsStillMatch() async throws {
    let base = try settingsRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let checkout = base.appendingPathComponent("checkout"); try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    #if DEBUG
    let configurationName = "debug"
    #else
    let configurationName = "release"
    #endif
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/\(configurationName)/CoincideScriptHelper")
    let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": base.path, "LANG": "en_US.UTF-8"]
    let root = ProjectSettingsFiles.root(dataRoot: base), key = "checkout:helper"
    let actions = try action("App setup", #"printf 'app-action:%s\n' "$T3CODE_PROJECT_ROOT"; printf ran > app-ran"#, setup: true)
    try ProjectSettingsFiles.save(.init(key: key, actions: actions), root: root)
    func plan() async throws -> ProjectScriptExecutionPlan {
        try await ProjectScriptExecutionPlan.capture(action: try #require(try ProjectSettingsFiles.load(root: root, key: key)?.actions?.first), index: 0,
            settingsKey: key, settingsRoot: root, workspace: checkout, projectRoot: checkout, shell: URL(fileURLWithPath: "/bin/sh"))
    }
    let session = try NativeProjectScriptExecutionSession(plan: try await plan(), helperURL: helper, environment: environment)
    let output = ActionHelperOutput(), collector = Task { try await session.consumeOutput { await output.append($0) } }
    try await session.prepare()
    #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("app-ran").path), "Preparing never executes.")
    try session.start(); try await session.waitUntilStarted()
    #expect(try await session.waitForCommandExit() == .exited(0))
    await session.close(); _ = await collector.result
    #expect(await output.text().contains("app-action:" + checkout.path))
    try FileManager.default.removeItem(at: checkout.appendingPathComponent("app-ran"))

    let stale = try NativeProjectScriptExecutionSession(plan: try await plan(), helperURL: helper, environment: environment)
    try await stale.prepare()
    let edited = try ProjectActions.updating(actions[0].id, with: .init(name: "App setup", command: "printf edited > app-ran", runOnWorktreeCreate: true), in: actions)
    try ProjectSettingsFiles.save(.init(key: key, actions: edited), root: root)
    try stale.start()
    do { try await stale.waitUntilStarted(); Issue.record("An action edited after review was executed.") }
    catch let error as ProjectScriptExecutionError { #expect(error.failure == .configurationChanged) }
    await stale.close()
    #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("app-ran").path))
}
