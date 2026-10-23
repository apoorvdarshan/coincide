import AppKit
import CoincideCore
import SwiftUI

/// First-run setup (T3 WelcomeWizard): check Codex and Claude Code, then add or import
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
    @State private var readiness = AgentReadinessModel()
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
        .task { await readiness.checkAll(environment: environment) }
        .sheet(isPresented: $importing) { AgentSessionImportView(store: store.agentSessionImports) }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to Coincide").font(.largeTitle.bold())
            Text("Coincide runs the coding agents already installed on this Mac with their own sign-in. Check Codex and Claude Code here; other agents can be set up later in Settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ProviderReadiness.Agent.allCases) { agent in
                AgentReadinessRow(agent: agent, readiness: readiness.states[agent] ?? .checking, executable: readiness.executables[agent])
            }
            HStack {
                Button("Check Again") { Task { await readiness.checkAll(environment: environment) } }.disabled(readiness.isChecking)
                if readiness.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open Terminal") { Self.openTerminal() }
            }
            Text("Install and sign-in commands run in Terminal, using each vendor's own installer. Coincide never stores your agent credentials.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
                Text("No projects yet. You can also use File → New Project or Clone Repository later.").font(.callout).foregroundStyle(.secondary)
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

struct AgentReadinessRow: View {
    let agent: ProviderReadiness.Agent
    let readiness: ProviderReadiness
    let executable: URL?

    private var status: (text: String, symbol: String, color: Color) {
        switch readiness {
        case .checking: (String(localized: "Checking…"), "hourglass", .secondary)
        case .install: (String(localized: "Not installed"), "arrow.down.circle", .orange)
        case .signIn: (String(localized: "Sign-in needed"), "person.crop.circle.badge.exclamationmark", .orange)
        case .ready(let detail): (detail ?? String(localized: "Ready"), "checkmark.circle.fill", .green)
        case .attention(let detail): (detail, "exclamationmark.triangle", .orange)
        }
    }
    private var command: String? {
        switch readiness {
        case .install: agent.installCommand
        case .signIn, .attention: agent.loginCommand(executable: executable?.path)
        case .checking, .ready: nil
        }
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
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
                        .accessibilityLabel(Text("Copy \(agent.name) command"))
                }
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
    private(set) var states: [ProviderReadiness.Agent: ProviderReadiness] = [:]
    private(set) var executables: [ProviderReadiness.Agent: URL] = [:]
    private(set) var isChecking = false
    @ObservationIgnored private let check: @Sendable (ProviderReadiness.Agent, URL?, [String: String]) async -> ProviderReadiness

    init(check: @escaping @Sendable (ProviderReadiness.Agent, URL?, [String: String]) async -> ProviderReadiness = { await ProviderReadiness.check($0, executable: $1, environment: $2) }) {
        self.check = check
    }

    /// Uses the login-shell PATH once it has been captured, like provider launches.
    func checkAll(environment: ShellEnvironmentController) async {
        guard !isChecking else { return }
        isChecking = true; defer { isChecking = false }
        await environment.waitForCapture(budget: .seconds(6))
        let env = ProcessChannel.environment()
        for agent in ProviderReadiness.Agent.allCases {
            states[agent] = .checking
            let executable = ProcessChannel.findExecutable(agent.executable)
            executables[agent] = executable
            states[agent] = await check(agent, executable, env)
        }
    }
}
