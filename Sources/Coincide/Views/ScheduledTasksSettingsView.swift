import CoincideCore
import SwiftUI

struct ScheduledTasksSettingsView: View {
    @Bindable var store: ScheduledTasksStore
    let navigate: (UUID) -> Void
    @State private var editor: ScheduledTaskEditorTarget?
    @State private var requestedPort = "0"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scheduled Tasks").font(.title2)
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
                Button("New Task…") { editor = .init(definition: nil) }.disabled(store.sources.isEmpty || store.isWorking)
            }
            Text("Saved, enabled tasks run while Coincide is open. Each occurrence uses its saved destination, provider, model, permission and workspace policy. Waking this Mac does not replay missed fixed-time work older than ten minutes.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                Section("Tasks") {
                    if store.ledger.tasks.isEmpty { Text("No scheduled tasks.").foregroundStyle(.secondary) }
                    ForEach(store.ledger.tasks) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(task.title).font(.headline)
                                Spacer()
                                Toggle("Enabled", isOn: .init(get: { task.enabled }, set: { value in Task { await store.setEnabled(task, enabled: value) } })).labelsHidden()
                                Button("Run Now") { Task { await store.runNow(task) } }
                                Button("Edit…") { editor = .init(definition: task) }
                                Button("Delete", role: .destructive) { Task { await store.delete(task) } }
                            }
                            Text("\(task.source.configuration.provider.name) · \(task.source.configuration.model) · \(task.source.configuration.permission.rawValue)").font(.caption)
                            if let next = task.nextRunAt { Text("Next: \(next.formatted())").font(.caption) }
                            if let error = task.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            Text(task.source.configuration.workspacePath).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                            if case .webhook = task.schedule {
                                Text(store.listenerPort.map { "http://127.0.0.1:\($0)/hooks/\(task.id.uuidString)" } ?? "/hooks/\(task.id.uuidString)")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }.disabled(store.isWorking)
                    }
                }
                Section("Original Run History") {
                    ForEach(store.ledger.occurrences.reversed()) { run in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(run.phase.rawValue.capitalized).font(.headline)
                                Text(run.observedAt.formatted()).font(.caption)
                                if let error = run.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                                if run.phase == .uncertain { Text("Inspect the original thread. This input will never be resent automatically.").font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            if let threadID = run.threadID { Button("Open Thread") { navigate(threadID) } }
                            if run.phase != .accepted, run.phase != .waiting, run.acknowledgedAt == nil {
                                Button("Acknowledge") { Task { await store.acknowledge(run) } }.disabled(store.isWorking)
                            }
                        }
                    }
                    Button("Clear Resolved History") { Task { await store.prune() } }.disabled(store.isWorking)
                }
                Section("Local Webhook Listener") {
                    Text("Only 127.0.0.1 is accepted. External hosting, HTTPS and port forwarding require your own setup; Coincide does not configure them. Credentials belong in Authorization and signature headers, never the URL.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Port (0 chooses a free port)", text: $requestedPort).frame(width: 180)
                        Button("Start Listener") { if let port = UInt16(requestedPort) { Task { await store.listener(enabled: true, port: port) } } }
                            .disabled(store.isWorking || UInt16(requestedPort) == nil)
                        Button("Stop Listener") { Task { await store.listener(enabled: false, port: 0) } }.disabled(store.isWorking)
                    }
                    if let port = store.listenerPort { Text("Listening at http://127.0.0.1:\(port)/hooks/<task-id>").font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding()
        .task {
            await store.load()
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .sheet(item: $editor) { target in ScheduledTaskEditor(store: store, original: target.definition, close: { editor = nil }) }
    }
}
private struct ScheduledTaskEditorTarget: Identifiable { let id = UUID(); let definition: ScheduledTaskDefinition? }
private struct ScheduledTaskFilterDraft: Identifiable {
    let id = UUID()
    var value: ScheduledTaskWebhookFilter
    var valuesText: String {
        get { value.values.joined(separator: ",") }
        set { value.values = newValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }
}

private struct ScheduledTaskEditor: View {
    let store: ScheduledTasksStore
    let original: ScheduledTaskDefinition?
    let close: () -> Void
    @State private var definitionID: UUID
    @State private var title: String
    @State private var prompt: String
    @State private var enabled: Bool
    @State private var capturedSource: ScheduledTaskSource?
    @State private var sourceID: UUID?
    @State private var kind: String
    @State private var interval = "60"
    @State private var time = "09:00"
    @State private var weekdays: Set<Int> = []
    @State private var destination = ScheduledTaskDestination.freshThread
    @State private var workspace = "source"
    @State private var baseRef = "HEAD"
    @State private var submodules = ProjectWorktreeSubmoduleMode.none
    @State private var rotateAuthorization = false
    @State private var signatureEnabled = false
    @State private var signatureHeader = "x-hub-signature-256"
    @State private var signaturePrefix = "sha256="
    @State private var signatureEncoding = ScheduledTaskWebhookSignature.Encoding.hex
    @State private var replayKey = ""
    @State private var coalesceKey = ""
    @State private var coalesceSeconds = "120"
    @State private var filters: [ScheduledTaskFilterDraft] = []
    @State private var signingSecret = ""
    @State private var headerAuthorization: String?
    @State private var saved = false
    @State private var error: String?
    @State private var saving = false
    init(store: ScheduledTasksStore, original: ScheduledTaskDefinition?, close: @escaping () -> Void) {
        self.store = store; self.original = original; self.close = close
        _definitionID = .init(initialValue: original?.id ?? UUID())
        _title = .init(initialValue: original?.title ?? ""); _prompt = .init(initialValue: original?.prompt ?? "")
        _enabled = .init(initialValue: original?.enabled ?? false); _sourceID = .init(initialValue: original?.source.threadID ?? store.sources.first?.id)
        _capturedSource = .init(initialValue: original?.source ?? store.sources.first.flatMap { try? store.source(threadID: $0.id) })
        var kind = "interval"
        if let original {
            _destination = .init(initialValue: original.destination ?? .freshThread)
            switch original.schedule {
            case .interval(let value): _interval = .init(initialValue: String(Double(value) / 1000))
            case .fixedTime(let value, let days): kind = "fixed"; _time = .init(initialValue: value); _weekdays = .init(initialValue: Set(days))
            case .webhook(let config):
                kind = "webhook"; _signatureEnabled = .init(initialValue: config.signature != nil)
                _signatureHeader = .init(initialValue: config.signature?.header ?? "x-hub-signature-256")
                _signaturePrefix = .init(initialValue: config.signature?.prefix ?? "sha256=")
                _signatureEncoding = .init(initialValue: config.signature?.encoding ?? .hex)
                _replayKey = .init(initialValue: config.replayKey ?? ""); _coalesceKey = .init(initialValue: config.coalesceKey ?? "")
                _coalesceSeconds = .init(initialValue: String(config.coalesceWindowSeconds)); _filters = .init(initialValue: config.filters.map { .init(value: $0) })
            }
            switch original.workspace {
            case .sourceCheckout: break
            case .projectRoot: _workspace = .init(initialValue: "root")
            case .newWorktree(let base, let mode):
                _workspace = .init(initialValue: "worktree"); _baseRef = .init(initialValue: base); _submodules = .init(initialValue: mode)
            }
        }
        _kind = .init(initialValue: kind)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "New Scheduled Task" : "Edit Scheduled Task").font(.title2)
            Form {
                TextField("Title", text: $title)
                TextEditor(text: $prompt).frame(height: 100).accessibilityLabel("Scheduled prompt")
                Picker("Captured source conversation", selection: $sourceID) {
                    ForEach(store.sources) { thread in Text("\(thread.title) · \(thread.provider.name) · \(thread.model)").tag(Optional(thread.id)) }
                }
                if let source = capturedSource {
                    Text("Captured: \(source.configuration.provider.name) · \(source.configuration.model) · \(source.configuration.permission.rawValue)\n\(source.configuration.workspacePath)").font(.caption).textSelection(.enabled)
                }
                Button("Capture Current Source Settings") { if let sourceID { capturedSource = try? store.source(threadID: sourceID) } }
                Picker("Trigger", selection: $kind) { Text("Interval").tag("interval"); Text("Fixed Local Time").tag("fixed"); Text("Webhook").tag("webhook") }
                if kind == "interval" { TextField("Every (seconds, minimum 60)", text: $interval) }
                if kind == "fixed" {
                    TextField("Time (HH:MM)", text: $time)
                    Text("Timezone: \(TimeZone.current.identifier). Empty weekday selection means every day.").font(.caption)
                    HStack { ForEach(0..<7, id: \.self) { day in Toggle(Calendar.current.shortWeekdaySymbols[day], isOn: .init(get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } })).toggleStyle(.button) } }
                }
                if kind == "webhook" {
                    Text("POST /hooks/<task-id> with an Authorization: Bearer header and a stable Idempotency-Key. Prompt placeholders include {{body.path}}, {{headers.name}}, {{query.name}}, {{body}} and {{request}}. Request values are framed as untrusted data.").font(.caption).textSelection(.enabled)
                    if original != nil { Toggle("Rotate Authorization token when saving", isOn: $rotateAuthorization) }
                    Toggle("Verify HMAC-SHA256 signature", isOn: $signatureEnabled)
                    if signatureEnabled {
                        TextField("Signature header", text: $signatureHeader); TextField("Digest prefix", text: $signaturePrefix)
                        Picker("Signature encoding", selection: $signatureEncoding) { Text("Hex").tag(ScheduledTaskWebhookSignature.Encoding.hex); Text("Base64").tag(ScheduledTaskWebhookSignature.Encoding.base64) }
                        SecureField("Signing secret (blank keeps the existing secret)", text: $signingSecret)
                    }
                }
                if kind == "webhook" {
                    TextField("Replay key template (optional, retained 7 days)", text: $replayKey)
                    TextField("Coalesce key template (optional)", text: $coalesceKey)
                    if !coalesceKey.isEmpty { TextField("Fixed coalescing window (10–3600 seconds)", text: $coalesceSeconds) }
                    Text("Coalescing keeps the latest matching payload within a window measured from the first request. All request filters must match.").font(.caption)
                    ForEach($filters) { $draft in
                        let filterID = draft.id
                        HStack {
                            TextField("body.action or headers.name", text: $draft.value.path)
                            Picker("Match", selection: $draft.value.operation) {
                                Text("equals").tag(ScheduledTaskWebhookFilter.Operation.equals); Text("not equals").tag(ScheduledTaskWebhookFilter.Operation.notEquals)
                                Text("starts with").tag(ScheduledTaskWebhookFilter.Operation.startsWith); Text("in").tag(ScheduledTaskWebhookFilter.Operation.oneOf); Text("exists").tag(ScheduledTaskWebhookFilter.Operation.exists)
                            }.labelsHidden()
                            if draft.value.operation != .exists {
                                TextField("Value (comma-separated for in)", text: $draft.valuesText)
                            }
                            Button("Remove") { filters.removeAll { $0.id == filterID } }
                        }
                    }
                    Button("Add Request Filter") { filters.append(.init(value: .init(path: "body.action", operation: .equals, values: [""]))) }.disabled(filters.count >= 16)
                }
                Picker("Destination", selection: $destination) { Text("New conversation for each run").tag(ScheduledTaskDestination.freshThread); Text("Queue into the captured source conversation").tag(ScheduledTaskDestination.existingThread) }
                Picker("Workspace", selection: $workspace) { Text("Captured source checkout").tag("source"); Text("Project root").tag("root"); Text("New worktree for each run").tag("worktree") }.disabled(destination == .existingThread)
                if workspace == "worktree" {
                    TextField("Local base ref", text: $baseRef)
                    Picker("Initialize submodules", selection: $submodules) {
                        Text("None").tag(ProjectWorktreeSubmoduleMode.none)
                        Text("Top level").tag(ProjectWorktreeSubmoduleMode.topLevel)
                        Text("Recursive").tag(ProjectWorktreeSubmoduleMode.recursive)
                    }.disabled(destination == .existingThread)
                    Text("New worktrees use normal preparation. Discovered setup scripts require review in the new conversation before input is released.").font(.caption)
                }
                Toggle("Enable after saving", isOn: $enabled)
            }.formStyle(.grouped).disabled(saving || saved)
            if let headerAuthorization {
                Text("Save this authorization header privately for your webhook sender. It is stored in Keychain and is not included in task history or URLs.").font(.caption)
                Text(store.listenerPort.map { "http://127.0.0.1:\($0)/hooks/\(definitionID.uuidString)" } ?? "/hooks/\(definitionID.uuidString)")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(headerAuthorization).font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button(saved ? "Done" : "Cancel", action: close); if !saved { Button("Save Task") { Task { await save() } }.disabled(saving) } }
        }.padding(20).frame(width: 620)
        .interactiveDismissDisabled(saving)
        .onChange(of: sourceID) { _, id in capturedSource = id.flatMap { try? store.source(threadID: $0) } }
    }
    private func save() async {
        guard !saving else { return }; saving = true; defer { saving = false }; error = nil
        do {
            guard let source = capturedSource, sourceID == source.threadID else { throw ScheduledTaskError.sourceChanged }
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 1024,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf16.count <= 120_000 else { throw ScheduledTaskError.invalidDefinition }
            try await store.validateSource(source)
            let id = definitionID
            let schedule: ScheduledTaskSchedule
            var authorizationToShow: String?
            switch kind {
            case "interval":
                guard let seconds = Double(interval), seconds.isFinite, seconds >= 60, seconds <= 31_536_000,
                      abs((seconds * 1000).rounded() - seconds * 1000) < 0.0001 else { throw ScheduledTaskError.invalidSchedule }
                schedule = .interval(everyMilliseconds: Int64((seconds * 1000).rounded()))
            case "fixed": schedule = .fixedTime(timeOfDay: time, weekdays: weekdays.sorted())
            default:
                var config: ScheduledTaskWebhookConfiguration
                if let original, case .webhook(let value) = original.schedule { config = value } else { config = .init() }
                config.signature = signatureEnabled ? .init(header: signatureHeader, encoding: signatureEncoding, prefix: signaturePrefix) : nil
                config.replayKey = replayKey.isEmpty ? nil : replayKey; config.coalesceKey = coalesceKey.isEmpty ? nil : coalesceKey
                guard let seconds = Int(coalesceSeconds) else { throw ScheduledTaskError.invalidWebhook }
                config.coalesceWindowSeconds = seconds; config.filters = filters.map(\.value)
                if config.bearerDigest.isEmpty || !signingSecret.isEmpty || rotateAuthorization {
                    let registration = try await store.configureWebhook(taskID: id, configuration: config, signingSecret: signingSecret.isEmpty ? nil : Data(signingSecret.utf8), rotateAuthorization: rotateAuthorization)
                    config = registration.configuration; authorizationToShow = registration.authorizationHeader
                }
                try config.validate(); schedule = .webhook(config)
            }
            let policy: ScheduledTaskWorkspace = destination == .existingThread ? .sourceCheckout : workspace == "root" ? .projectRoot : workspace == "worktree" ? .newWorktree(baseRef: baseRef, submodules: submodules) : .sourceCheckout
            let value = try ScheduledTaskDefinition(id: id, title: title, prompt: prompt, enabled: enabled, schedule: schedule, source: source, workspace: policy, destination: destination)
            try await store.save(value, expectedRevision: original?.revision)
            headerAuthorization = authorizationToShow; signingSecret = ""; saved = true
            if headerAuthorization == nil { close() }
        } catch { self.error = error.localizedDescription }
    }
}
