import FuzzSupport

// Fuzzes CoincideKit/Support/TerminalText.swift (escape sequence stripping and output tails for what
// agent CLIs print) and CoincideKit/Support/TextClip.swift (bounding long command output).

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTerminalText(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    fuzzOneInput(start, count, TerminalTextChecks.run)
    return 0
}

// Without libFuzzer (any toolchain, no COINCIDE_FUZZING), the executable replays saved inputs.
#if !COINCIDE_FUZZING
@main
enum ReplayEntry {
    static func main() {
        Replay.main(name: "TerminalTextFuzzer", TerminalTextChecks.run)
    }
}
#endif
