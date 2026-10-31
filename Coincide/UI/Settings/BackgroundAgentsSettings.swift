import AppKit
import CoincideKit
import SwiftUI

/// Settings › General › Agents: whether agents run in Coincide's background agent host, and if not, why not and
/// what fixes it.
struct BackgroundAgentsRows: View {
    @State private var mode = AgentHostController.shared.mode
    @State private var isOn = AgentHostController.shared.isTurnedOn

    var body: some View {
        Group {
            Toggle(isOn: binding) {
                Text("Keep agents running when Coincide quits")
                Text(
                    "Agents work in Coincide’s background agent host, so quitting, updating or a crash doesn’t stop them. Coincide catches up on what they did when it opens."
                )
            }
            if isOn {
                LabeledContent {
                    if mode == .inApp(.needsApproval) {
                        Button("Open Login Items…") { AgentHostController.shared.openLoginItems() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        SettingsStatusDot(color: dotColor)
                        Text(headline)
                    }
                    Text(detail)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentHostController.modeChanged)) { _ in
            mode = AgentHostController.shared.mode
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from Login Items, where the user may have allowed Coincide.
            AgentHostController.shared.refresh()
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { value in
                isOn = value
                AgentHostController.shared.setTurnedOn(value)
            })
    }

    private var dotColor: Color {
        switch mode {
        case .background: .green
        case .connecting: .yellow
        case .inApp(.needsApproval), .inApp(.unreachable), .inApp(.registrationFailed), .inApp(.missingFromBundle): .orange
        case .inApp: Color(nsColor: Theme.surfaceBorder)
        }
    }

    private var headline: String {
        switch mode {
        case .background: String(localized: "Agents run in the background")
        case .connecting: String(localized: "Connecting to the agent host…")
        case .inApp: String(localized: "Agents run in Coincide")
        }
    }

    private var detail: String {
        switch mode {
        case .background(let version, let isOtherBuild):
            isOtherBuild
                ? String(
                    localized: "The agent host from Coincide \(version) keeps its agents running, and gives way to this version’s once they finish.")
                : String(localized: "They keep working after Coincide quits. The agent host exits once nothing runs.")
        case .connecting:
            String(localized: "New agents wait a few seconds for it to answer before they start in Coincide.")
        case .inApp(let reason):
            switch reason {
            case .turnedOff:
                String(localized: "Agents stop when Coincide quits.")
            case .developmentBuild:
                String(localized: "Development builds run agents in the app. Launch with COINCIDE_AGENT_HOST=1 to use the agent host.")
            case .unsignedBuild:
                String(localized: "This build isn’t signed with a Developer ID, which the agent host needs. Agents stop when Coincide quits.")
            case .needsApproval:
                String(
                    localized: "Coincide is turned off under Allow in the Background in Login Items. Turn it on to keep agents running after Coincide quits.")
            case .missingFromBundle:
                String(localized: "The agent host is missing from this copy of Coincide. Reinstall Coincide to keep agents running after it quits.")
            case .registrationFailed(let message):
                String(localized: "macOS couldn’t start the agent host: \(message)")
            case .unreachable:
                String(
                    localized: "The agent host didn’t answer. Coincide keeps trying; until it gets through, new agents run in Coincide and stop when it quits.")
            case .incompatibleHostBusy:
                String(
                    localized: "An agent host from another version of Coincide still runs agents. New agents run in Coincide until those finish.")
            }
        }
    }
}
