import Foundation
import Testing

@testable import CoincideKit

struct SupportTests {
    @Test func terminalEscapesAreRemoved() {
        let colored = "\u{1B}[1;31mError:\u{1B}[0m bad \u{1B}[?25lthing\u{1B}[K"
        #expect(TerminalText.stripANSI(colored) == "Error: bad thing")
        let link = "see \u{1B}]8;;https://example.com\u{07}the docs\u{1B}]8;;\u{07} or \u{1B}]8;;https://x.y\u{1B}\\here\u{1B}]8;;\u{1B}\\"
        #expect(TerminalText.stripANSI(link) == "see the docs or here")
        #expect(TerminalText.stripANSI("\u{1B}(Bplain\u{1B}=") == "plain")
        #expect(TerminalText.stripANSI("no escapes") == "no escapes")
    }

    @Test func tailsKeepTheLastLines() {
        let stderr = "one\n\n\u{1B}[33mtwo\u{1B}[0m\n  three  \n"
        #expect(TerminalText.tail(stderr, lines: 2, maxLength: 100) == "two\nthree")
        #expect(TerminalText.tail(stderr, lines: 5, maxLength: 7) == "o\nthree")
        #expect(TerminalText.tail(" \n\n", lines: 3, maxLength: 10) == nil)
        #expect(TerminalText.nonEmpty("  x \n") == "x")
        #expect(TerminalText.nonEmpty(" \n") == nil)
        #expect(TerminalText.nonEmpty(nil) == nil)
    }

    @Test func pathsUnderTheWorkingDirectoryAreRelative() {
        let paths = PathDisplay(workingDirectory: "/tmp/project/")
        #expect(paths.relative("/tmp/project/Sources/App.swift") == "Sources/App.swift")
        #expect(paths.relative("/private/tmp/project/README.md") == "README.md")
        #expect(paths.relative("/tmp/project") == ".")
        #expect(paths.relative("/tmp/projects/other") == "/tmp/projects/other")
        #expect(
            OpenCodeTools.title(name: "read", category: .read, input: ["filePath": "/tmp/project/a.swift"], paths: paths)
                == "Read a.swift")
        #expect(OpenCodeTools.title(name: "read", category: .read, input: ["filePath": "/tmp/project/a.swift"]) == "Read /tmp/project/a.swift")
    }

    @Test func idsMustBeWholeNumbers() {
        #expect(JSONValue.number(3).exactInt == 3)
        #expect(JSONValue.number(1.5).exactInt == nil)
        #expect(JSONValue.number(1e20).exactInt == nil)
        #expect(JSONValue.string("3").exactInt == nil)
    }

    @Test func wholeNumbersPastInt64DisplayWithoutTrapping() throws {
        // An agent's JSON-RPC id is matched by its displayText; these used to trap converting to Int64.
        for text in ["1e19", "-9.3e18", "9223372036854775808", "-1e300"] {
            let value = try #require(JSONValue.parse(text))
            #expect(Double(value.displayText) == value.number, "\(text) displays as \(value.displayText)")
        }
        #expect(JSONValue.parse(#"{"id":1e19}"#)?["id"]?.displayText == "1e+19")
        #expect(JSONValue.number(-9_223_372_036_854_775_808).displayText == "-9223372036854775808")
        #expect(JSONValue.number(42).displayText == "42")
        #expect(JSONValue.number(1.5).displayText == "1.5")
    }
}
