import Foundation

/// Runs one fuzz input. On Apple platforms Foundation autoreleases bridged objects (regular
/// expressions, NSString paths), and libFuzzer's loop never returns to a run loop that would drain
/// them, so each input gets its own autorelease pool.
public func fuzzOneInput(_ start: UnsafeRawPointer, _ count: Int, _ check: ([UInt8]) -> Void) {
    let bytes = Array(UnsafeRawBufferPointer(start: start, count: count))
    #if canImport(ObjectiveC)
    autoreleasepool { check(bytes) }
    #else
    check(bytes)
    #endif
}
