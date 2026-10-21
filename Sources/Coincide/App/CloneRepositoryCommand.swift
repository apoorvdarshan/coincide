import SwiftUI

private struct CloneRepositoryPresentationKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var cloneRepositoryPresentation: Binding<Bool>? {
        get { self[CloneRepositoryPresentationKey.self] }
        set { self[CloneRepositoryPresentationKey.self] = newValue }
    }
}
