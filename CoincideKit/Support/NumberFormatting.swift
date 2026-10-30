import Foundation

/// Numeric presentation is independent of the app's language, calendar and date formats.
public enum NumberFormatMode: String, Codable, CaseIterable, Sendable {
    case system
    case international

    public nonisolated var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .international: String(localized: "International")
        }
    }

    public nonisolated func locale(systemLocale: Locale = .autoupdatingCurrent) -> Locale {
        switch self {
        case .system: systemLocale
        case .international: Locale(identifier: "en_US")
        }
    }
}

/// Styles used only when presenting numbers. Provider data and serialized numbers stay locale-independent.
public struct NumberFormatting: Sendable {
    public let locale: Locale

    public nonisolated init(_ mode: NumberFormatMode, systemLocale: Locale = .autoupdatingCurrent) {
        locale = mode.locale(systemLocale: systemLocale)
    }

    public nonisolated func integer(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    public nonisolated func decimal(_ value: Double, fractionDigits: ClosedRange<Int> = 0...2) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    public nonisolated func compact(_ value: Int, significantDigits: ClosedRange<Int>? = nil) -> String {
        var style = IntegerFormatStyle<Int>.number.notation(.compactName).locale(locale)
        if let significantDigits { style = style.precision(.significantDigits(significantDigits)) }
        return value.formatted(style)
    }

    public nonisolated func currency(_ value: Double, code: String = "USD", fractionDigits: Int? = nil) -> String {
        var style = FloatingPointFormatStyle<Double>.Currency(code: code).locale(locale)
        if let fractionDigits { style = style.precision(.fractionLength(fractionDigits)) }
        return value.formatted(style)
    }

    public nonisolated func percent(_ value: Double, fractionDigits: Int = 0) -> String {
        value.formatted(.percent.precision(.fractionLength(fractionDigits)).locale(locale))
    }
}
