import CoincideCore
import Foundation

/// Hosted runners do not install Codex. Store admission only needs a local
/// executable proof; the injected provider peer owns the protocol.
func fixtureCodexInstallation(root: URL) -> CodexInstallation {
    CodexInstallation(rootURL: root.appendingPathComponent("Tools/Codex"), release: nil,
        localResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") })
}
