import FuzzSupport

// Fuzzes the mid-thread handoff in CoincideKit/Providers/Handoff.swift (the recap one agent gets of
// the turns other agents ran) and the lenient thread decoding it relies on in
// CoincideKit/Models/Models.swift and LenientDecoding.swift.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzHandoff(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    fuzzOneInput(start, count, HandoffChecks.run)
    return 0
}

// Without libFuzzer (any toolchain, no COINCIDE_FUZZING), the executable replays saved inputs.
#if !COINCIDE_FUZZING
@main
enum ReplayEntry {
    static func main() {
        Replay.main(name: "HandoffFuzzer", HandoffChecks.run)
    }
}
#endif
