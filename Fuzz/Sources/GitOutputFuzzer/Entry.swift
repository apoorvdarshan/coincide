import FuzzSupport

// Fuzzes the git output parsers in CoincideKit/Git/GitParsing.swift: `git status --porcelain=2 -z`,
// `git diff --numstat -z`, `git worktree list --porcelain -z`, C-style path unquoting and branch
// naming. The first byte picks the check; see GitOutputChecks.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzGitOutput(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    fuzzOneInput(start, count, GitOutputChecks.run)
    return 0
}

// Without libFuzzer (any toolchain, no COINCIDE_FUZZING), the executable replays saved inputs.
#if !COINCIDE_FUZZING
@main
enum ReplayEntry {
    static func main() {
        Replay.main(name: "GitOutputFuzzer", GitOutputChecks.run)
    }
}
#endif
