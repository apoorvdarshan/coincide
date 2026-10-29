import CoincideKit
import Foundation

/// What the composer's speed control shows: the speed the thread's model runs at, standard or one of the faster
/// speeds it offers (Claude's fast mode, Codex's service tiers). There is no control for a model that runs at one
/// speed. The thread's selection is the one place the speed lives; the model picker's speed chips change it too.
struct ComposerSpeedControl: Equatable {
    /// The faster speed the thread runs at; nil for standard.
    let selected: ModelSpeed?

    static let standardSymbol = "gauge.with.dots.needle.50percent"
    static let fastSymbol = "bolt.fill"
    static var standardTitle: String { String(localized: "Standard") }

    /// Nil, hiding the control, when the model is unknown or runs at one speed. A speed the model no longer offers
    /// shows as standard, as the agent runs it.
    init?(model: ModelOption?, speed: String?) {
        guard let model, !model.speeds.isEmpty else { return nil }
        selected = model.speed(speed)
    }

    var title: String { selected?.name ?? Self.standardTitle }
    var symbolName: String { selected == nil ? Self.standardSymbol : Self.fastSymbol }

    /// The speed a thread keeps when it switches to `model`: the same one when the model offers it, else standard.
    static func carried(_ speed: String?, to model: ModelOption?) -> String? {
        model?.speed(speed)?.id
    }
}
