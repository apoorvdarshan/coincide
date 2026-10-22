import Foundation

extension ProviderConfiguration {
    /// Native launch policy is independent of ACP planning/model options.
    public func resolvedGrokRuntimeMode() throws -> GrokACPRuntimeMode? {
        guard provider == .acp, acpAgent?.integration == .grok else { return nil }
        return try GrokACP.runtimeMode(permission: permission)
    }
    public var effectiveGrokRuntimeMode: GrokACPRuntimeMode? { try? resolvedGrokRuntimeMode() }
    public var permissionSummary: String {
        if provider == .pi { return permission.piTitle }
        if provider == .muse { return permission.museTitle }
        if provider == .antigravity { return permission.antigravityTitle }
        if provider == .acp, acpAgent?.integration == .grok {
            return effectiveGrokRuntimeMode?.name ?? "Unavailable Grok permissions"
        }
        return permission.title
    }
}

enum GrokConfigurationValidation {
    static func invalid() -> CoincideError { .init("The Grok launch policy belongs to a different integration.") }
    static func configuration(_ value: ProviderConfiguration) throws { _ = try value.resolvedGrokRuntimeMode() }
}
