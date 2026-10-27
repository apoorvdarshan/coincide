import FuzzSupport

// Fuzzes DiffParser in CoincideKit/Git/GitParsing.swift, which splits `git diff` patches into files,
// hunks and lines for the diff inspector. The first byte picks the check; see DiffParserChecks.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzDiffParser(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    fuzzOneInput(start, count, DiffParserChecks.run)
    return 0
}

// Without libFuzzer (any toolchain, no COINCIDE_FUZZING), the executable replays saved inputs.
#if !COINCIDE_FUZZING
@main
enum ReplayEntry {
    static func main() {
        Replay.main(name: "DiffParserFuzzer", DiffParserChecks.run)
    }
}
#endif
