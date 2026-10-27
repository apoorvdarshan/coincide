import FuzzSupport

// Fuzzes CoincideKit/Support/JSONValue.swift, which decodes every agent wire protocol (Claude
// stream-json, Codex and ACP JSON-RPC, OpenCode, Pi).

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzJSONValue(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    fuzzOneInput(start, count, JSONValueChecks.run)
    return 0
}

// Without libFuzzer (any toolchain, no COINCIDE_FUZZING), the executable replays saved inputs.
#if !COINCIDE_FUZZING
@main
enum ReplayEntry {
    static func main() {
        Replay.main(name: "JSONValueFuzzer", JSONValueChecks.run)
    }
}
#endif
