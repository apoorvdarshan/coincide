import AppKit
import CoincideCore
import SwiftUI

/// First-run setup: check Codex and Claude Code, then add or import
/// projects. Closing it at any step finishes setup; Help → Welcome to Coincide reopens it.
struct WelcomeWizardView: View {
    enum Step: Int, CaseIterable, Identifiable {
        case agents, projects, done
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .agents: String(localized: "Agents")
            case .projects: String(localized: "Projects")
            case .done: String(localized: "Done")
            }
        }
    }
    @Bindable var store: WorkspaceStore
    let environment: ShellEnvironmentController
    let finish: () -> Void
    @State private var step = Step.agents
    @State var readiness = AgentReadinessModel()
    @State private var importing = false

    private var importRunning: Bool { store.agentSessionImports.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ForEach(Step.allCases) { item in
                    Button { step = item } label: {
                        Label(item.title, systemImage: item.rawValue < step.rawValue ? "checkmark.circle.fill" : item == step ? "circle.inset.filled" : "circle")
                    }
                    .buttonStyle(.borderless).foregroundStyle(item == step ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .disabled(importRunning)
                    .accessibilityIdentifier("welcome-step-\(item.rawValue)")
                    if item != Step.allCases.last { Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: 40) }
                }
            }
            Group {
                switch step {
                case .agents: agents
                case .projects: projects
                case .done: done
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step != .agents { Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .agents }.disabled(importRunning) }
                Spacer()
                if step == .done {
                    Button("Start Using Coincide") { finish() }.keyboardShortcut(.defaultAction).coincidePrimaryAction()
                        .accessibilityIdentifier("welcome-finish")
                } else {
                    Button("Skip Setup") { finish() }.disabled(importRunning)
                    Button("Continue") { step = Step(rawValue: step.rawValue + 1) ?? .done }.keyboardShortcut(.defaultAction)
                        .disabled(importRunning).accessibilityIdentifier("welcome-continue")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480)
        .task(id: store.firstRunReadinessRevision) { await checkReadiness() }
        .onDisappear { readiness.cancel() }
        .sheet(isPresented: $importing) { AgentSessionImportView(store: store.agentSessionImports) }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to Coincide").font(.largeTitle.bold())
            Text("Coincide runs the coding agents already installed on this Mac with their own sign-in. Check Codex and Claude Code here; agent settings are available in Settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ProviderReadiness.Agent.allCases) { agent in
                let capturedRevision = readiness.capturedRevision[agent]
                AgentReadinessRow(agent: agent, readiness: readiness.states[agent] ?? .checking, executable: readiness.executables[agent],
                                  capturedLoginCommand: readiness.captures[agent]?.loginCommand,
                                  capturedInstallCommand: readiness.captures[agent]?.capturedInstallCommand,
                                  usesCapturedProfile: true,
                                  isCurrent: { capturedRevision == store.firstRunReadinessRevision })
            }
            HStack {
                Button("Check Again") { Task { await checkReadiness() } }.disabled(readiness.isChecking)
                if readiness.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open Terminal") { Self.openTerminal() }
            }
            Text("Install and sign-in commands run in Terminal, using each vendor's own installer. Coincide never stores your agent credentials.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkReadiness() async {
        await readiness.checkAll(environment: environment, capture: store.captureFirstRunReadiness,
                                 isCurrent: store.isCurrentFirstRunReadiness, revision: store.firstRunReadinessRevision)
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your projects").font(.title.bold())
            Text("Add a folder you work in, or import projects that Codex and Claude Code have already used. Import copies recent conversation history and leaves the original files unchanged.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add Project Folder…") { store.addProject() }.accessibilityIdentifier("welcome-add-project")
                Button("Import Agent Projects…") { importing = true }.accessibilityIdentifier("welcome-import-projects")
            }
            if store.snapshot.projects.isEmpty {
                Text("No projects yet. You can also use File → New Project or Add Project later.").font(.callout).foregroundStyle(.secondary)
            } else {
                List(store.snapshot.projects.prefix(8)) { project in
                    Label { VStack(alignment: .leading) { Text(project.name); Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                        icon: { Image(systemName: "folder") }
                }.frame(minHeight: 120, maxHeight: 220)
                if store.snapshot.projects.count > 8 { Text("\(store.snapshot.projects.count) projects").font(.caption).foregroundStyle(.secondary) }
            }
            if importRunning { Label("Importing… setup steps resume when the import finishes.", systemImage: "arrow.down.circle").font(.callout) }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're ready").font(.title.bold())
            Text("Start a conversation with ⌘N. Hold ⌘Q to quit, so a stray keystroke does not stop running agents. Install the coincide command in Settings → General to open folders from Terminal.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !readiness.states.values.contains(where: \.isReady) {
                Label("No agent is ready yet. You can finish setup now and sign in later.", systemImage: "exclamationmark.triangle").font(.callout)
            }
        }
    }

    static func openTerminal() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

extension ProviderReadiness.Capture {
    /// Installing a default CLI cannot repair a selected custom path or a
    /// managed installation. Those selections remain under native Settings.
    var capturedInstallCommand: String? {
        switch scope {
        case .codex(let configuration): configuration.selection == .existingCLI ? agent.installCommand : nil
        case .unavailableClaude(let profile): profile.executable == "claude" ? agent.installCommand : nil
        case .claude: nil
        }
    }
}

struct AgentReadinessRow: View {
    let agent: ProviderReadiness.Agent
    let readiness: ProviderReadiness
    let executable: URL?
    var capturedLoginCommand: String? = nil
    var capturedInstallCommand: String? = nil
    var usesCapturedProfile = false
    var isCurrent: @MainActor () -> Bool = { true }

    private var status: (text: String, symbol: String, color: Color) {
        guard isCurrent() else {
            return (String(localized: "The selected profile changed. Checking again…"), "hourglass", .secondary)
        }
        return switch readiness {
        case .checking: (String(localized: "Checking…"), "hourglass", .secondary)
        case .install: (String(localized: "Not installed"), "arrow.down.circle", .orange)
        case .signIn: (String(localized: "Sign-in needed"), "person.crop.circle.badge.exclamationmark", .orange)
        case .ready(let detail): (detail ?? String(localized: "Ready"), "checkmark.circle.fill", .green)
        case .attention(let detail): (detail, "exclamationmark.triangle", .orange)
        }
    }
    private var command: String? {
        guard isCurrent() else { return nil }
        return switch readiness {
        case .install: usesCapturedProfile ? capturedInstallCommand : agent.installCommand
        case .signIn, .attention: usesCapturedProfile ? capturedLoginCommand : agent.loginCommand(executable: executable?.path)
        case .checking, .ready: nil
        }
    }

    /// The row can outlive the body that created it. Recheck ownership at the
    /// action boundary before calling the system clipboard (or a test writer).
    @discardableResult
    func copyCommand(_ captured: String, write: (String) -> Void) -> Bool {
        guard isCurrent(), let command, command.utf8.elementsEqual(captured.utf8) else { return false }
        write(command)
        return true
    }

    private var canReviewSettings: Bool {
        guard usesCapturedProfile, isCurrent(), command == nil else { return false }
        return switch readiness {
        case .install, .signIn, .attention: true
        case .checking, .ready: false
        }
    }

    @discardableResult
    func reviewSettings(using open: () -> Void) -> Bool {
        guard canReviewSettings else { return false }
        open(); return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: status.symbol).foregroundStyle(status.color).accessibilityHidden(true)
                Text(agent.name).font(.headline)
                Spacer()
                Text(status.text).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
            }
            if let command {
                HStack {
                    Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("Copy") {
                        copyCommand(command) { text in
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                        .accessibilityLabel(Text("Copy \(agent.name) command"))
                }
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else if canReviewSettings {
                Button("Review in Settings") { reviewSettings { DesktopShell.shared.showSettings(page: .providers) } }
            }
        }
        .padding(12)
        .coincideSurface(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome-agent-\(agent.rawValue)")
    }
}

@MainActor @Observable
final class AgentReadinessModel {
    typealias Check = @Sendable (ProviderReadiness.Capture) async -> ProviderReadiness
    private(set) var states: [ProviderReadiness.Agent: ProviderReadiness] = [:]
    private(set) var executables: [ProviderReadiness.Agent: URL] = [:]
    private(set) var captures: [ProviderReadiness.Agent: ProviderReadiness.Capture] = [:]
    private(set) var capturedRevision: [ProviderReadiness.Agent: Data] = [:]
    private(set) var isChecking = false
    @ObservationIgnored private let check: Check
    @ObservationIgnored private var checks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var current: UUID?
    @ObservationIgnored private var closed = false

    init(check: Check? = nil) {
        self.check = check ?? Self.checkCapturedProfile
    }

    nonisolated private static func checkCapturedProfile(_ capture: ProviderReadiness.Capture) async -> ProviderReadiness {
        await ProviderReadiness.check(capture)
    }

    /// The store captures its selected profile after shell discovery; results
    /// publish only while that same profile and workspace remain current.
    func checkAll(environment: ShellEnvironmentController,
                  capture: @escaping @MainActor (ProviderReadiness.Agent) throws -> ProviderReadiness.Capture,
                  isCurrent: @escaping @MainActor (ProviderReadiness.Capture) -> Bool,
                  revision: Data? = nil) async {
        guard !closed, !Task.isCancelled else { return }
        cancel()
        let previous = Array(checks.values), id = UUID()
        current = id; isChecking = true
        let check = check
        let task = Task { [weak self] in
            for task in previous { await task.value }
            guard !Task.isCancelled, self?.current == id, self?.closed == false else { return }
            await environment.waitForCapture(budget: .seconds(6))
            guard !Task.isCancelled, self?.current == id, self?.closed == false else { return }
            for agent in ProviderReadiness.Agent.allCases {
                guard !Task.isCancelled, self?.current == id, self?.closed == false else { return }
                let captured: ProviderReadiness.Capture
                do { captured = try capture(agent) }
                catch {
                    self?.states[agent] = .attention(String(localized: "The selected profile is unavailable. Check its settings and try again."))
                    self?.captures.removeValue(forKey: agent); self?.executables.removeValue(forKey: agent)
                    self?.capturedRevision.removeValue(forKey: agent)
                    continue
                }
                guard captured.agent == agent, isCurrent(captured) else { continue }
                self?.states[agent] = .checking
                self?.captures[agent] = captured; self?.executables[agent] = captured.executable
                self?.capturedRevision[agent] = revision
                let result = await check(captured)
                guard !Task.isCancelled, self?.current == id, self?.closed == false else { return }
                guard isCurrent(captured) else {
                    self?.states[agent] = .attention(String(localized: "The selected profile changed. Check again."))
                    self?.captures.removeValue(forKey: agent); self?.executables.removeValue(forKey: agent)
                    self?.capturedRevision.removeValue(forKey: agent)
                    continue
                }
                self?.states[agent] = result
            }
        }
        checks[id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        checks.removeValue(forKey: id)
        if current == id { current = nil; isChecking = false }
    }

    func cancel() {
        current = nil; isChecking = false
        for task in checks.values { task.cancel() }
        // Captures can own installation leases; only active tasks retain them
        // during their exact process drain.
        captures.removeAll(); executables.removeAll(); capturedRevision.removeAll()
    }

    func shutdown() async {
        closed = true; cancel()
        let owned = Array(checks.values)
        for task in owned { await task.value }
        checks.removeAll()
    }
}
