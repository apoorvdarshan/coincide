import Foundation
import Observation

/// Google's Antigravity Additional Terms (section 6) call reaching the service with third-party software, tools or
/// services a material breach, and Google has suspended accounts for it, Gemini CLI and Code Assist access included.
/// Coincide keeps Antigravity, and says so plainly: a notice in Settings › Antigravity, a glyph wherever Antigravity is
/// chosen, and a one-time acknowledgement before Google sign-in starts or Antigravity is turned on.
public enum AntigravityAccountRisk {
    /// Google's official Antigravity terms (the Universal Terms, the Antigravity Additional Terms and the Privacy Policy).
    public nonisolated static let termsURL = URL(string: "https://antigravity.google/terms")!

    /// Where the acknowledgement is kept: `AppSettings.dismissedWarnings`, which reads an older or unreadable
    /// settings file as nothing acknowledged without losing the other settings.
    public nonisolated static let acknowledgementKey = WarningDismissalKey.antigravityAccountRisk
}

/// Asks once, before the first Google sign-in or before Antigravity is turned on, whether the user understands the
/// account risk, and remembers the answer in settings. Nothing that already runs is stopped: an Antigravity that is on
/// and signed in keeps working, and its user is asked on their next sign-in.
@MainActor
@Observable
public final class AntigravityRiskGate {
    /// Whether the acknowledgement sheet should show now.
    public private(set) var isAsking = false

    @ObservationIgnored private let store: AppStore
    /// What runs once the user says they understand: the sign-in or the change that asked.
    @ObservationIgnored private var pending: (() -> Void)?

    public init(store: AppStore) {
        self.store = store
    }

    public var isAcknowledged: Bool { store.isWarningDismissed(AntigravityAccountRisk.acknowledgementKey) }

    /// Starts Google sign-in with `start`: at once when the risk was acknowledged, otherwise after the user says they
    /// understand. Cancelling never starts it.
    public func signIn(_ start: @escaping () -> Void) {
        perform(start)
    }

    /// Turns Antigravity on or off with `apply`. Only turning it on from off asks first; turning it off, or a change
    /// that leaves it on, applies at once.
    public func setEnabled(_ isOn: Bool, wasEnabled: Bool, apply: @escaping () -> Void) {
        if isOn && !wasEnabled {
            perform(apply)
        } else {
            apply()
        }
    }

    /// The user understands: saves that before anything else (a quit right after keeps it), then runs what asked.
    public func acknowledge() {
        store.dismissWarning(AntigravityAccountRisk.acknowledgementKey)
        isAsking = false
        let action = pending
        pending = nil
        action?()
    }

    /// The user cancelled, or the sheet closed another way: nothing runs and nothing is saved, so the next sign-in asks
    /// again.
    public func cancel() {
        pending = nil
        isAsking = false
    }

    private func perform(_ action: @escaping () -> Void) {
        if isAcknowledged {
            action()
            return
        }
        // A second request while the sheet shows replaces the first: only what the user did last runs.
        pending = action
        isAsking = true
    }
}
