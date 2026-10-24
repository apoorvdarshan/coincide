import AppKit
import CoincideCore
import Darwin

/// Separate local-owner control channel. Its credential is never passed to agents.
/// Reuses the bounded, authenticated loopback transport without granting Engine tools.
@MainActor
final class LocalAppControl {
    private let store: WorkspaceStore
    private let windows: MainWindowCoordinator
    private let root: URL
    private let registry = MCPSessionRegistry()
    private var server: MCPHTTPServer?
    private var credential: MCPSessionCredential?
    private let instance = UUID()
    private let configurationEditor = ProviderConfigurationEditor()
    private var configurationReads: [UUID: (document: ProviderConfigurationDocument, expires: Date)] = [:]

    init(store: WorkspaceStore, windows: MainWindowCoordinator, root: URL) {
        self.store = store; self.windows = windows; self.root = root.appendingPathComponent("Control", isDirectory: true)
    }

    func start() async throws {
        guard server == nil else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CoincideError("The local CLI directory must be private.") }
        let scope = MCPInvocationScope(threadID: instance, projectID: instance, provider: .codex,
            runtimeID: instance, incarnation: instance, providerInstanceID: instance,
            workspacePath: root.path, permission: .fullAccess, capabilities: [.orchestration])
        let credential = try await registry.issue(scope: scope)
        self.credential = credential
        let names = ["status", "projects", "threads", "thread", "providers", "models", "model", "select", "new", "ui", "sort", "screenshot", "export", "send", "compact", "compaction", "compaction-cancel", "integrations", "integration-import", "integration-remove", "integration-use", "sessions", "session-details", "session-stop", "configuration", "configuration-set"]
        let definitions = names.map { name in
            MCPToolDefinition(name: name, description: "Coincide local CLI: " + name,
                inputSchema: .object(["type": .string("object")]), capability: .orchestration,
                readOnly: !["select", "new", "model", "ui", "sort", "screenshot", "export", "send", "compact", "compaction-cancel", "integration-import", "integration-remove", "integration-use", "configuration-set", "session-stop"].contains(name))
        }
        let server = try await MCPHTTPServer.start(registry: registry, tools: definitions) { [weak self] invocation in
            guard let self else { throw MCPError(.unavailable) }
            return try await self.invoke(invocation)
        }
        self.server = server
        do {
            let data = try JSONEncoder().encode(JSONValue.object([
                "endpoint": .string(server.endpoint.absoluteString), "authorization": .string(credential.authorizationHeader),
                "instance": .string(instance.uuidString), "pid": .number(Double(getpid()))]))
            let temporary = root.appendingPathComponent(instance.uuidString + ".json")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CoincideError("Cannot publish the local CLI connection.") }
            defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == data.count, fsync(fd) == 0,
                  rename(temporary.path, root.appendingPathComponent("connection.json").path) == 0 else {
                throw CoincideError("Cannot publish the local CLI connection.")
            }
        } catch { await stop(); throw error }
    }

    func stop() async {
        let url = root.appendingPathComponent("connection.json")
        if let data = try? Data(contentsOf: url), data.count < 4096,
           let record = try? JSONDecoder().decode(JSONValue.self, from: data), record["instance"].string == instance.uuidString {
            try? FileManager.default.removeItem(at: url)
        }
        await registry.shutdown()
        await server?.close()
        server = nil; credential = nil
    }

    private func invoke(_ invocation: MCPInvocation) async throws -> MCPToolResult {
        try Task.checkCancellation()
        guard credential?.sessionID == invocation.scope.sessionID else { throw MCPError(.unauthorized) }
        await registry.touch(sessionID: invocation.scope.sessionID)
        return try await Self.localActionResult(invocation.toolName) {
            try await self.invokeAction(invocation)
        }
    }

    /// Only these local actions have a public recovery contract. Never forward
    /// arbitrary filesystem, provider, or configuration error descriptions.
    static func localActionResult(_ action: String, operation: () async throws -> MCPToolResult) async throws -> MCPToolResult {
        do { return try await operation() }
        catch is CancellationError { throw MCPError(.cancelled) }
        catch let error as MCPError { throw error }
        catch {
            let code: String, message: String
            if action == "configuration" || action == "configuration-set",
               let safe = error as? CoincideError, safeConfigurationErrors.contains(safe.message) {
                if safe.message == "Read configuration first and use its unexpired review ID for one change." {
                    code = "configuration_review_required"
                } else if safe.message == "This configuration changed outside Coincide. Reload it before saving; your provider file has not been overwritten."
                    || safe.message == "The configuration changed while saving. Reload it and try again." {
                    code = "configuration_changed"
                } else { code = "configuration_invalid" }
                message = safe.message + " Read configuration again for the same provider and scope before retrying. Review IDs are single-use."
            } else if ["integrations", "integration-import", "integration-remove", "integration-use"].contains(action) {
                code = "integration_refresh_required"
                message = "The integration action could not be completed. Refresh integrations and review the current workspace and item ID before retrying. Completed imports are retained."
            } else if action == "send" {
                code = "message_not_confirmed"
                message = "The message was not confirmed as sent. Read the conversation before retrying so it is not sent twice. Your draft is unchanged."
            } else if action == "compact" || action == "compaction-cancel" {
                code = "context_compaction_not_confirmed"
                message = "Context compaction was not confirmed. Run compaction for the same conversation to inspect its current status before retrying. Your Coincide conversation and draft are unchanged."
            } else { throw error }
            return .init(content: [message], structuredContent: .object([
                "error": .object(["code": .string(code), "message": .string(message)])
            ]), isError: true)
        }
    }

    private static let safeConfigurationErrors: Set<String> = [
        "Read configuration first and use its unexpired review ID for one change.",
        "The provider configuration directory must be an absolute path.",
        "Select a project to edit its configuration.",
        "Codex has user and project configuration scopes.",
        "This configuration changed outside Coincide. Reload it before saving; your provider file has not been overwritten.",
        "The configuration changed while saving. Reload it and try again.",
        "This setting cannot be changed with the structured editor.",
        "Use the provider's source file for sensitive values. Credentials cannot be entered in this editor.",
        "Choose Enabled, Disabled or Inherit.",
        "Choose a supported setting value.",
        "Enter a single value of at most 512 characters.",
        "Use up to 200 entries, one per line, each at most 512 characters.",
        "Enter a whole number from 100000 to 1000000.",
        "An advanced value occupies this setting. Edit it in the source file.",
        "The provider settings are not a valid JSON object. Correct the source file before editing.",
        "The provider settings have duplicate keys or a structure that cannot be rewritten safely.",
        "This TOML source has syntax or an advanced table layout that the structured editor cannot safely change. Edit it in the provider's source file.",
        "The provider configuration link has no readable target. Repair the link before editing.",
        "The structured editor requires a regular configuration file you own, no larger than 1 MB, without hard links.",
        "This configuration is too large for the structured editor."
    ]

    private func invokeAction(_ invocation: MCPInvocation) async throws -> MCPToolResult {
        let args = invocation.arguments
        let result: JSONValue
        switch invocation.toolName {
        case "status":
            result = .object(["running": .bool(true), "pid": .number(Double(getpid())),
                "selectedThread": store.selectedThread.map(summary) ?? .null,
                "projects": .number(Double(store.snapshot.projects.count)), "threads": .number(Double(store.snapshot.threads.count)),
                "busyThreads": .array(store.snapshot.threads.filter { store.isBusy($0.id) }.map { .string($0.id.uuidString) }),
                "ui": uiState])
        case "projects":
            result = .array(store.orderedProjects.prefix(500).map { .object(["id": .string($0.id.uuidString), "name": .string($0.name), "path": .string($0.path)]) })
        case "threads":
            let project = args["project"].string
            let matches = store.snapshot.threads.filter { thread in
                guard let project else { return true }
                return thread.projectID.uuidString.caseInsensitiveCompare(project) == .orderedSame ||
                    store.snapshot.projects.contains { $0.id == thread.projectID && ($0.name == project || $0.path == project) }
            }.sorted { $0.updatedAt > $1.updatedAt }
            result = .object(["threads": .array(matches.prefix(500).map(summary)), "total": .number(Double(matches.count))])
        case "thread":
            let thread = try target(args)
            let messages = thread.visibleMessages.suffix(20).map { message in
                JSONValue.object(["role": .string(message.role.rawValue), "text": .string(String(message.text.prefix(4000)))])
            }
            result = .object(["thread": summary(thread), "messages": .array(messages), "totalMessages": .number(Double(thread.visibleMessages.count))])
        case "send":
            guard args["confirm"] == .bool(true), let text = args["text"].string, text.utf16.count <= 120_000 else { throw MCPError(.invalidParams) }
            let updated = try await store.sendFromLocalControl(text, threadID: try target(args).id)
            result = .object(["thread": summary(updated), "sent": .bool(true), "draftUnchanged": .bool(true)])
        case "compaction":
            let thread = try target(args)
            result = compactionStatus(threadID: thread.id)
        case "compact":
            guard args["confirm"] == .bool(true) else { throw MCPError(.invalidParams) }
            let thread = try target(args)
            let confirmation = try store.prepareContextCompaction(threadID: thread.id)
            _ = try await store.compactContext(confirmation)
            result = compactionStatus(threadID: thread.id, requestAccepted: true)
        case "compaction-cancel":
            guard args["confirm"] == .bool(true), let value = args["operation"].string,
                  let operationID = UUID(uuidString: value) else { throw MCPError(.invalidParams) }
            let thread = try target(args)
            _ = try await store.cancelContextCompaction(threadID: thread.id, operationID: operationID)
            result = compactionStatus(threadID: thread.id, requestAccepted: true)
        case "providers":
            result = .array(ProviderKind.builtIn.map { provider in
                .object(["id": .string(provider.rawValue), "name": .string(provider.name),
                    "executableFound": .bool(ProcessChannel.findExecutable(provider.executable) != nil),
                    "authentication": .string("not checked"), "modelExecution": .string("not checked")])
            })
        case "models":
            if args["all"] == .bool(true) {
                if args["refresh"] == .bool(true) { await store.refreshPickerModels(force: true) }
                result = .object(["providers": .array(ProviderKind.builtIn.map { provider in
                    .object(["id": .string(provider.rawValue),
                        "models": .array(store.models(for: provider).map { .object(["id": .string($0.id), "name": .string($0.name)]) }),
                        "catalogError": store.modelCatalogErrors[provider].map(JSONValue.string) ?? .null])
                })])
                break
            }
            let thread = try target(args)
            if args["refresh"] == .bool(true) {
                guard store.selectedThreadID == thread.id else { throw CoincideError("Select this conversation before refreshing its models.") }
                await store.refreshModels(provider: thread.provider)
            }
            guard let current = store.thread(thread.id), current.provider == thread.provider else { throw MCPError(.unavailable) }
            result = .object(["provider": .string(thread.provider.rawValue), "selected": .string(current.model),
                "models": .array(store.models(for: current).prefix(500).map {
                    .object(["id": .string($0.id), "name": .string($0.name), "reasoning": .array($0.reasoningEfforts.map { .string($0.id) })])
                }), "note": .string("Catalog availability does not verify authentication or model execution.")])
        case "select":
            let thread = try target(args)
            guard store.selectThread(thread.id) else { throw MCPError(.unavailable) }
            store.search = ""
            result = .object(["selected": .string(thread.id.uuidString)])
        case "integrations":
            let kind = args["kind"].string.flatMap(ProviderIntegrationKind.init(rawValue:))
            let provider = args["provider"].string.flatMap(ProviderKind.init(rawValue:))
            guard args["kind"].string == nil || kind != nil,
                  args["provider"].string == nil || provider != nil else { throw MCPError(.invalidParams) }
            let scope = store.integrationScope
            await store.integrations.refresh(scope: scope)
            guard store.integrationScope == scope, store.integrations.scope == scope else { throw CoincideError("The selected workspace changed. Refresh integrations again.") }
            if let error = store.integrations.errorMessage { throw CoincideError(error) }
            let rows = store.integrations.items.filter { (kind == nil || $0.kind == kind) && (provider == nil || $0.provider == provider) }
            result = .object(["items": .array(try rows.map(encodedValue)), "total": .number(Double(rows.count)),
                "issues": .array(try store.integrations.issues.map(encodedValue)),
                "workspace": scope.workspacePath.map(JSONValue.string) ?? .null])
        case "integration-import", "integration-remove", "integration-use":
            guard let id = args["integration_id"].string, id.count == 64,
                  id.allSatisfy({ $0.isHexDigit }) else { throw MCPError(.invalidParams) }
            let scope = store.integrationScope
            await store.integrations.refresh(scope: scope)
            guard store.integrationScope == scope, store.integrations.scope == scope else { throw CoincideError("The selected workspace changed. Refresh integrations again.") }
            guard let item = store.integrations.items.first(where: { $0.id == id }) else { throw CoincideError("Integration not found. Run integrations to refresh its ID.") }
            switch invocation.toolName {
            case "integration-import": _ = try await store.integrations.importItems([id])
            case "integration-remove": try await store.integrations.removeImport(id)
            default: try await store.useIntegration(item)
            }
            result = .object(["integrationId": .string(id), "action": .string(invocation.toolName), "sent": .bool(false)])
        case "sessions":
            guard let raw = args["provider"].string, let provider = ProviderKind(rawValue: raw) else { throw MCPError(.invalidParams) }
            let snapshot = try await ProviderSessionsService.list(scope: store.providerSessionsScope(provider))
            result = .object(["sessions": .array(snapshot.sessions.map { session in
                .object(["id": .string(session.id), "nativeId": .string(session.nativeID), "provider": .string(session.provider.rawValue),
                    "title": .string(session.title), "directory": .string(session.directory), "kind": .string(session.kind),
                    "state": .string(session.state.rawValue), "canStop": .bool(session.canStop)])
            }), "hasMore": .bool(snapshot.hasMore), "note": .string("Provider-owned sessions; importing creates independent Coincide conversations.")])
        case "configuration":
            guard let raw = args["provider"].string, let provider = ProviderKind(rawValue: raw),
                  let scope = ProviderConfigurationScope(rawValue: args["scope"].string ?? "user") else { throw MCPError(.invalidParams) }
            let source = try ProviderConfigurationEditor.sourceURL(provider: provider, scope: scope,
                codex: store.integrationCodexConfiguration, claude: store.integrationClaudeProfile, workspacePath: store.integrationScope.workspacePath)
            let document = try await configurationEditor.load(provider: provider, scope: scope, sourceURL: source)
            configurationReads = configurationReads.filter { $0.value.expires > Date() }
            if configurationReads.count >= 16 { configurationReads.removeAll() }
            let review = UUID()
            configurationReads[review] = (document, Date().addingTimeInterval(300))
            result = .object(["reviewId": .string(review.uuidString), "expiresInSeconds": .number(300),
                "provider": .string(provider.rawValue), "scope": .string(scope.rawValue), "source": .string(source.path),
                "fields": .array(document.fields.map { field in
                    .object(["id": .string(field.id), "title": .string(field.title), "value": .string(field.value),
                        "editable": .bool(field.isEditable), "description": .string(field.detail),
                        "control": .string(String(describing: field.control))])
                }), "notices": .array(document.notices.map(JSONValue.string))])
        case "configuration-set":
            guard let id = args["review_id"].string.flatMap(UUID.init(uuidString:)),
                  let read = configurationReads.removeValue(forKey: id), read.expires > Date(),
                  let field = args["field"].string, let value = args["value"].string else {
                throw CoincideError("Read configuration first and use its unexpired review ID for one change.")
            }
            // The captured document selects the exact file; the editor rejects
            // changes made by the CLI or another UI since this review.
            let saved = try await configurationEditor.save(read.document, changes: [field: value])
            result = .object(["saved": .bool(true), "provider": .string(saved.provider.rawValue),
                "source": .string(saved.sourceURL.path), "field": .string(field)])
        case "session-details", "session-stop":
            guard let raw = args["provider"].string, let provider = ProviderKind(rawValue: raw) else { throw MCPError(.invalidParams) }
            result = try await ProviderSessionsLocalControl.invoke(action: invocation.toolName, arguments: args, scope: store.providerSessionsScope(provider))
        case "model":
            let thread = try target(args)
            guard let raw = args["provider"].string, let provider = ProviderKind(rawValue: raw),
                  let model = args["model"].string, model.utf8.count <= 512 else { throw MCPError(.invalidParams) }
            guard await store.choosePickerModel(provider: provider, modelID: model, threadID: thread.id),
                  let updated = store.thread(thread.id) else { throw CoincideError("Model selection was not completed. Inspect the current thread before retrying.") }
            result = .object(["thread": summary(updated), "sent": .bool(false)])
        case "new":
            guard let path = args["path"].string, path.hasPrefix("/"), path.utf8.count <= 4096 else { throw MCPError(.invalidParams) }
            let id = try await store.openDraftThread(projectID: nil, folder: URL(fileURLWithPath: path), draft: "")
            store.search = ""
            result = .object(["threadId": .string(id.uuidString), "sent": .bool(false)])
        case "sort":
            let modes = ["newest": "created_at", "active": "updated_at", "priority": "priority", "name": "name", "custom": "manual"]
            let projects = args["projects"].string, chats = args["chats"].string
            let moveChat = args["move_chat"].string, moveProject = args["move_project"].string, direction = args["direction"].string
            let moving = moveChat != nil || moveProject != nil
            guard projects.map({ modes[$0] != nil }) ?? true, chats.map({ modes[$0] != nil }) ?? true,
                  !(moveChat != nil && moveProject != nil),
                  moveChat.map({ UUID(uuidString: $0) != nil }) ?? true,
                  moveProject.map({ UUID(uuidString: $0) != nil }) ?? true,
                  moving ? (direction == "up" || direction == "down") : direction == nil else { throw MCPError(.invalidParams) }
            try await store.setSidebarSorting(projects: projects.flatMap { modes[$0].flatMap(ProjectSortMode.init(rawValue:)) },
                                              chats: chats.flatMap { modes[$0].flatMap(ThreadSortMode.init(rawValue:)) })
            if moving {
                try await store.moveSidebarItem(chat: moveChat.flatMap(UUID.init(uuidString:)), project: moveProject.flatMap(UUID.init(uuidString:)),
                                                by: direction == "up" ? -1 : 1)
            }
            result = .object(["projectSort": .string(store.projectSortMode.rawValue), "chatSort": .string(store.threadSortMode.rawValue),
                "projects": .array(store.orderedProjects.filter { $0.scratch == nil }.map { .string($0.id.uuidString) }),
                "chats": .array(store.visibleThreads.map { .string($0.id.uuidString) })])
        case "ui":
            // Validate the whole request before changing the visible page.
            let settings: SettingsPage?
            if let value = args["settings"].string {
                guard let page = SettingsPage(rawValue: value) else { throw MCPError(.invalidParams) }
                settings = page
            } else { settings = nil }
            let sidebar = args["sidebar"].string
            let display = args["display"].string
            guard sidebar == nil || sidebar == "show" || sidebar == "hide",
                  display == nil || display == "built-in",
                  !(settings != nil && args["chat"] == .bool(true)) else { throw MCPError(.invalidParams) }
            if display != nil {
                guard let screen = NativeWindowLaunch.builtInScreen, let window = windows.currentWindow else {
                    throw CoincideError("A built-in display and an open Coincide window are required.")
                }
                NativeWindowLaunch.place(window, on: screen)
            }
            if let settings { store.showSettings(settings) }
            if args["chat"] == .bool(true) { store.showChat() }
            if let sidebar { store.sidebarVisible = sidebar == "show" }
            if args["model_picker"] == .bool(true) { store.showChat(); store.modelPickerPresented = true }
            else { store.modelPickerPresented = false }
            result = uiState
        case "export":
            let thread = try target(args)
            guard let path = args["path"].string, path.hasPrefix("/"), path.utf8.count <= 4096,
                  let format = ConversationExportFormat(rawValue: args["format"].string ?? "markdown") else { throw MCPError(.invalidParams) }
            let artifact = try await Task.detached(priority: .userInitiated) {
                let artifact = try ConversationExport.make(thread: thread, format: format)
                try ConversationExportFile.writeNew(artifact.data, to: URL(fileURLWithPath: path))
                return artifact
            }.value
            result = .object(["path": .string(path), "format": .string(format.rawValue),
                "messageCount": .number(Double(artifact.messageCount)),
                "truncatedToolMessages": .number(Double(artifact.truncatedToolMessages)), "sent": .bool(false)])
        case "screenshot":
            let popovers = NSApp.windows.filter { $0.isVisible && $0.className.contains("Popover") }
            let targetWindow = args["popover"] == .bool(true) ? (popovers.count == 1 ? popovers.first : nil) : windows.currentWindow
            guard let path = args["path"].string, path.hasPrefix("/"), path.hasSuffix(".png"), path.utf8.count <= 4096,
                  let window = targetWindow,
                  let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MCPError(.unavailable) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw MCPError(.unavailable) }
            try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            result = .object(["path": .string(path), "width": .number(Double(bitmap.pixelsWide)), "height": .number(Double(bitmap.pixelsHigh))])
        default: throw MCPError(.methodNotFound)
        }
        let structured = result.object != nil ? result : .object([invocation.toolName: result])
        return MCPToolResult(content: [], structuredContent: structured)
    }

    private var uiState: JSONValue {
        .object(["sidebarVisible": .bool(store.sidebarVisible),
            "page": .string(store.showingSettings ? "settings" : "chat"),
            "modelPickerVisible": .bool(store.modelPickerPresented),
            "settingsPage": .string(store.settingsPage.rawValue), "modelPicker": .string("composer"),
            "windowCount": .number(Double(windows.visibleWindowCount)),
            "windowFrame": windows.currentWindow.map { .string(NSStringFromRect($0.frame)) } ?? .null,
            "usableScreenFrame": windows.currentWindow?.screen.map { .string(NSStringFromRect($0.visibleFrame)) } ?? .null,
            "fillsUsableScreen": .bool(windows.currentWindow.map { window in
                guard let available = window.screen?.visibleFrame else { return false }
                return abs(window.frame.minX - available.minX) < 1 && abs(window.frame.minY - available.minY) < 1 &&
                    abs(window.frame.width - available.width) < 1 && abs(window.frame.height - available.height) < 1
            } ?? false),
            "display": .string(windows.currentWindow?.screen?.localizedName ?? "Unavailable"),
            "onBuiltInDisplay": .bool(windows.currentWindow.map { window in
                NativeWindowLaunch.builtInScreen.map { $0.visibleFrame.contains(window.frame) } ?? false
            } ?? false)])
    }

    private func target(_ arguments: JSONValue) throws -> CodingThread {
        let id = arguments["id"].string.flatMap(UUID.init(uuidString:)) ?? (arguments["id"] == .null ? store.selectedThreadID : nil)
        guard let id, let thread = store.thread(id) else { throw CoincideError("Conversation not found. Use threads to list IDs.") }
        return thread
    }

    /// Intentionally excludes provider configuration, credentials and private context.
    private func compactionStatus(threadID: UUID, requestAccepted: Bool? = nil) -> JSONValue {
        let reason = store.contextCompactionUnavailableReason(threadID: threadID)
        let operation = store.snapshot.contextCompaction(threadID: threadID)
        return .object([
            "threadID": .string(threadID.uuidString), "available": .bool(reason == nil),
            "requestAccepted": requestAccepted.map(JSONValue.bool) ?? .null,
            "unavailableReason": reason.map(JSONValue.string) ?? .null,
            "operation": operation.map { value in .object([
                "id": .string(value.id.uuidString), "threadID": .string(value.threadID.uuidString),
                "provider": .string(value.provider.rawValue), "phase": .string(value.phase.rawValue),
                "isWorking": .bool(value.isWorking), "error": value.error.map(JSONValue.string) ?? .null,
                "createdAt": .string(value.createdAt.ISO8601Format()), "updatedAt": .string(value.updatedAt.ISO8601Format())
            ]) } ?? .null
        ])
    }

    private func encodedValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func summary(_ thread: CodingThread) -> JSONValue {
        .object(["id": .string(thread.id.uuidString), "projectId": .string(thread.projectID.uuidString),
            "title": .string(String(thread.title.prefix(500))), "provider": .string(thread.provider.rawValue),
            "model": .string(thread.model), "state": .string(thread.state.rawValue), "archived": .bool(thread.isArchived),
            "messageCount": .number(Double(thread.visibleMessages.count)),
            "imported": .bool(store.snapshot.agentSessionImports?.contains(where: { $0.threadID == thread.id }) == true),
            "nativeSessionBound": .bool(thread.providerThreadID != nil),
            "pendingContextTransfers": .number(Double(store.snapshot.pendingContextTransfers(threadID: thread.id).count))])
    }
}
