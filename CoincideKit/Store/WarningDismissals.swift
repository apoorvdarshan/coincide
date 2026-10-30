import Foundation

/// Stable identities for capability notices. No browsing history or changing countdown text is saved.
public enum WarningDismissalKey {
    public static let passkeysUnavailable = "browser:passkeys-unavailable"
}

@MainActor
extension AppStore {
    public func isWarningDismissed(_ key: String) -> Bool { settings.dismissedWarnings.contains(key) }

    /// Save an acknowledgment before returning, including a subsequent immediate quit or app reconstruction.
    public func dismissWarning(_ key: String) {
        guard !isWarningDismissed(key) else { return }
        updateSettings { $0.dismissedWarnings.insert(key) }
        flush()
    }
}
