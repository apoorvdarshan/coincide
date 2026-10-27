import Foundation

/// A session that can tell when its agent runs work of its own between turns, such as background
/// commands or subagents, which ending the session would kill. `ThreadRunner` does not shut such a
/// session down for being idle; its idle time counts from when that work ends.
@MainActor
public protocol BackgroundWorkReporting: AgentSession {
    /// True while the agent runs work of its own that shutting the session down would stop.
    var hasBackgroundWork: Bool { get }
}
