/// Invariant checks. A failure traps, which libFuzzer reports as a crash and saves the input as an
/// artifact, so logic bugs are found the same way as memory errors.
public func expect(
    _ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line
) {
    if !condition { fail(message(), file: file, line: line) }
}

public func expectEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ context: @autoclosure () -> String, file: StaticString = #fileID,
    line: UInt = #line
) {
    guard actual != expected else { return }
    fail(
        "\(context())\n  actual:   \(String(reflecting: actual))\n  expected: \(String(reflecting: expected))",
        file: file, line: line)
}

public func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> Never {
    fatalError("Fuzz invariant failed: \(message)", file: file, line: line)
}
