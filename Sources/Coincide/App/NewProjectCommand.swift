import SwiftUI

private struct NewProjectPresentationKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var newProjectPresentation: Binding<Bool>? {
        get { self[NewProjectPresentationKey.self] }
        set { self[NewProjectPresentationKey.self] = newValue }
    }
}
