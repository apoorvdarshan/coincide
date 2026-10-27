import FuzzSupport

// Fuzzes the unified diffs Coincide writes for agents that report file edits as before and after
// text: UnifiedDiff (ACP agents) and CursorDiff (Cursor). Each diff is read back with DiffParser and
// applied to the old text, which must give the new text.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzDiffGenerator(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    fuzzOneInput(start, count, DiffGeneratorChecks.run)
    return 0
}

// Without libFuzzer (any toolchain, no COINCIDE_FUZZING), the executable replays saved inputs.
#if !COINCIDE_FUZZING
@main
enum ReplayEntry {
    static func main() {
        Replay.main(name: "DiffGeneratorFuzzer", DiffGeneratorChecks.run)
    }
}
#endif
