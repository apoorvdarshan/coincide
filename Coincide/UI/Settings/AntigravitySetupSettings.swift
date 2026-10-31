import CoincideKit
import SwiftUI

extension AntigravitySetupSections {
    /// The sections wired to Settings: Antigravity's status and custom path, a re-check after each
    /// change, and the executable and environment sessions launch with. The provider page shows them
    /// with `if kind == .antigravity { AntigravitySetupSections(model: model) }`.
    init(model: SettingsModel, registry: ProviderRegistry = .shared) {
        self.init(
            context: AntigravitySetupContext(
                status: model.status(.antigravity), isEnabled: model.isEnabled(.antigravity),
                customPath: model.providerSettings(.antigravity).executablePath,
                recheck: { model.check(.antigravity) },
                launch: {
                    (await registry.executable(for: .antigravity), await registry.environment(for: .antigravity))
                },
                confirmSignIn: { model.antigravityRisk.signIn($0) }))
    }
}
