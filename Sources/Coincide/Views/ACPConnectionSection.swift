import CoincideCore
import SwiftUI

struct ACPConnectionSection: View {
    let agent: ACPAgentConfiguration
    let connections: ACPConnectionStore
    let refresh: @MainActor () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Check Connection") { Task { await refresh() } }
                    .disabled(connections.isRefreshing(agent: agent))
                    .accessibilityIdentifier("acp-check-connection-\(agent.id.uuidString)")
                if connections.isRefreshing(agent: agent) {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking agent connection")
                }
            }
            if let observation = connections.observation(for: agent) {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Protocol", value: "ACP v\(observation.info.protocolVersion)")
                    if let name = observation.info.agentName { LabeledContent("Agent", value: name) }
                    if let version = observation.info.agentVersion { LabeledContent("Version", value: version) }
                    LabeledContent("Resume", value: observation.info.supportsResume ? "Advertised" : "Not advertised")
                    LabeledContent("Images", value: observation.info.supportsImages ? "Advertised" : "Not advertised")
                    LabeledContent(connections.errorMessage(for: agent) == nil ? "Last checked" : "Previous check") {
                        Text(observation.checkedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                }.font(.caption).textSelection(.enabled)
            }
            if let error = connections.errorMessage(for: agent) {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Checks initialization only. A connection does not confirm sign-in, model access, or full ACP compatibility.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let integration = agent.integration {
                ACPIntegrationGuidance(integration: integration)
            }
        }
    }
}

struct ACPIntegrationGuidance: View {
    let integration: ACPIntegration

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coincide reuses this CLI’s existing sign-in and provider settings. To sign in or configure it, run \(integration.signInCommand) in Terminal.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("\(integration.name) ACP documentation", destination: integration.documentationURL).font(.caption)
        }
    }
}
