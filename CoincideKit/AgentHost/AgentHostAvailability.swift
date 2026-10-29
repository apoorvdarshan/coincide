import Foundation

/// Why agents run in the app instead of the agent host. Agents then work as they always did, stopping when
/// Coincide quits.
public enum AgentHostFallbackReason: Equatable, Sendable {
    /// The user turned the host off in Settings.
    case turnedOff
    /// A Debug build, which would register a LaunchAgent pointing into DerivedData. `COINCIDE_AGENT_HOST=1` opts in.
    case developmentBuild
    /// An ad-hoc or unsigned build: the app and host only trust code signed by the same team.
    case unsignedBuild
    /// The user turned Coincide off under Login Items › Allow in the Background.
    case needsApproval
    /// The LaunchAgent's plist or the host is missing from the app bundle.
    case missingFromBundle
    case registrationFailed(String)
    /// The host was registered but did not answer.
    case unreachable
    /// A host from another version that this app cannot talk to still runs agents. It exits once they finish,
    /// and the next launch uses this version's host.
    case incompatibleHostBusy
}

/// `SMAppService.Status`, without importing ServiceManagement into the kit.
public enum AgentHostRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// What the app does at launch about the agent host.
public enum AgentHostPlan: Equatable, Sendable {
    case connect
    case registerThenConnect
    case runInApp(AgentHostFallbackReason)

    public nonisolated static func decide(
        isTurnedOn: Bool, isDevelopmentBuild: Bool, developmentOptIn: Bool, team: String?,
        status: AgentHostRegistrationStatus
    ) -> AgentHostPlan {
        guard isTurnedOn else { return .runInApp(.turnedOff) }
        if isDevelopmentBuild, !developmentOptIn { return .runInApp(.developmentBuild) }
        guard team != nil else { return .runInApp(.unsignedBuild) }
        switch status {
        case .enabled: return .connect
        case .notRegistered: return .registerThenConnect
        // A registration the user turned off stays off until they turn it on again; registering anew would fail.
        case .requiresApproval: return .runInApp(.needsApproval)
        // `notFound` also describes a plist that was never registered on some systems, so registering decides.
        case .notFound: return .registerThenConnect
        }
    }
}
