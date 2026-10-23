import Foundation
import SwiftTerm

struct TerminalPromptOrigin: Equatable {
    let row: Int, column: Int
}

/// Read the bounded native parser's armed prompt state under its processing
/// lock. Combine it with unchanged activity and owned-process checks rather
/// than guessing prompt suffixes; OSC 133 output establishes this native state.
final class TerminalPromptReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var core: Terminal?
    func bind(_ terminal: Terminal) { lock.withLock { core = terminal } }
    func origin(armedOnly: Bool) -> TerminalPromptOrigin? {
        guard let terminal = lock.withLock({ core }) else { return nil }
        return terminal.terminalLock.withLock {
            if armedOnly {
                let pointer = SemanticPromptPointerSnapshot(selectionWasActive: false, didDrag: false,
                    clickCount: 1, pressWasSemanticEligible: true)
                guard terminal.mightRouteSemanticPromptClick(modifiers: [], snapshot: pointer) else { return nil }
            }
            guard let origin = terminal.activeSemanticPromptOrigin else { return nil }
            return .init(row: origin.row, column: origin.col)
        }
    }
}
