import CoincideKit

/// Resolve the display preference at the UI boundary so changing it does not rewrite stored numbers or text.
enum AppNumbers {
    static var current: NumberFormatting { NumberFormatting(AppStore.shared.settings.numberFormat) }
}
