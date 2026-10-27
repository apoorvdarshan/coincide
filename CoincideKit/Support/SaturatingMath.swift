import Foundation

/// Arithmetic on numbers that come from agent output, which may be anything. Overflowing Int
/// arithmetic traps in Swift, so sums and differences of untrusted values clamp instead.
extension Int {
    public nonisolated func saturatingAdding(_ other: Int) -> Int {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : result
    }

    public nonisolated func saturatingSubtracting(_ other: Int) -> Int {
        let (result, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other > 0 ? .min : .max) : result
    }

    /// The sum of the values, clamped to Int's range.
    public nonisolated static func saturatingSum(_ values: Int...) -> Int {
        values.reduce(0) { $0.saturatingAdding($1) }
    }
}
