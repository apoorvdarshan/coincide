import Foundation

/// A progress report a program printed with OSC 9;4 (ConEmu's sequence, which `brew`, `cargo`, `winget` and others use),
/// shown on the terminal's tab in the header.
struct TerminalProgress: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case normal, error, indeterminate, paused
    }

    var state: State
    /// 0 to 100, or nil while indeterminate.
    var percent: Int?

    /// How long a bar stays without another report, in case the program died mid-task (as SwiftTerm does).
    static let timeout: TimeInterval = 15

    /// The report in an OSC 9 payload ("4;state;progress"): `.some(nil)` removes the bar, nil when it isn't one.
    nonisolated static func parse(_ payload: [UInt8]) -> TerminalProgress?? {
        let fields = String(decoding: payload, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        guard fields.first == "4", fields.count >= 2, let code = Int(fields[1]) else { return nil }
        let value = fields.count > 2 ? Int(fields[2]).map { min(100, max(0, $0)) } : nil
        switch code {
        case 0: return .some(nil)
        case 1: return TerminalProgress(state: .normal, percent: value ?? 0)
        case 2: return TerminalProgress(state: .error, percent: value)
        case 3: return TerminalProgress(state: .indeterminate, percent: nil)
        case 4: return TerminalProgress(state: .paused, percent: value)
        default: return nil
        }
    }

    /// For VoiceOver and the tab's tooltip.
    var description: String {
        switch state {
        case .normal: return percent.map { String(localized: "\($0)% done") } ?? String(localized: "Working")
        case .indeterminate: return String(localized: "Working")
        case .error: return percent.map { String(localized: "Failed at \($0)%") } ?? String(localized: "Failed")
        case .paused: return percent.map { String(localized: "Paused at \($0)%") } ?? String(localized: "Paused")
        }
    }
}
