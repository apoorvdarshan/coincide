import CoincideCore
import Foundation

struct RemoteLifecycleSettingsPresentation: Identifiable {
    let environmentID: UUID
    let policy: WorkspaceLifecyclePolicy
    var id: UUID { environmentID }
}
