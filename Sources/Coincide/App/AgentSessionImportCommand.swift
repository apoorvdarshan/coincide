import SwiftUI

private struct AgentSessionImportPresentationKey: FocusedValueKey { typealias Value = Binding<Bool> }
extension FocusedValues {
    var agentSessionImportPresentation: Binding<Bool>? {
        get { self[AgentSessionImportPresentationKey.self] }
        set { self[AgentSessionImportPresentationKey.self] = newValue }
    }
}
