// swift-tools-version: 6.0

// libFuzzer targets for Coincide's parsers. Each fuzzer is an executable whose sources are symlinks
// to the real files in CoincideKit, so it always tests the current code. See fuzz.sh for building,
// fuzzing and replaying the seed corpora, and CONTRIBUTING.md for when to use which.

import PackageDescription

/// One executable per fuzzer; Sources/<name> holds its harness and symlinks to the CoincideKit files
/// it tests.
let fuzzers = [
    "JSONValueFuzzer",
    "GitOutputFuzzer",
    "DiffParserFuzzer",
    "DiffGeneratorFuzzer",
    "TerminalTextFuzzer",
    "HandoffFuzzer",
]

let package = Package(
    name: "CoincideFuzz",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "FuzzSupport")
    ]
        + fuzzers.map { name in
            .executableTarget(name: name, dependencies: ["FuzzSupport"])
        }
)
