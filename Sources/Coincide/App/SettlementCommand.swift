import CoincideCore
import SwiftUI

private struct SettlementPresentationKey: FocusedValueKey {
    typealias Value = Binding<CodingThread?>
}

extension FocusedValues {
    var settlementPresentation: Binding<CodingThread?>? {
        get { self[SettlementPresentationKey.self] }
        set { self[SettlementPresentationKey.self] = newValue }
    }
}
