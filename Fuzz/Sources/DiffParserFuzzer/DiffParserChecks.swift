import Foundation
import FuzzSupport

/// `D` parses the rest of the input as a patch and checks what must hold for any text, `H` does the
/// same for one hunk header, and `r` writes a patch from the input the way `git diff` would (with
/// renames, mode changes, binaries, quoted names) and checks that it parses back to what was written.
enum DiffParserChecks {
    static func run(_ bytes: [UInt8]) {
        guard let first = bytes.first else { return }
        let rest = Array(bytes.dropFirst())
        switch first {
        case UInt8(ascii: "D"): rawPatch(String(decoding: rest, as: UTF8.self))
        case UInt8(ascii: "H"): rawHunkHeader(String(decoding: rest, as: UTF8.self))
        case UInt8(ascii: "r"): roundTrip(FuzzInput(rest))
        default:
            switch first % 3 {
            case 0: rawPatch(String(decoding: rest, as: UTF8.self))
            case 1: rawHunkHeader(String(decoding: rest, as: UTF8.self))
            default: roundTrip(FuzzInput(rest))
            }
        }
    }

    // MARK: Any input

    static func rawPatch(_ patch: String) {
        let files = DiffParser.parse(patch)
        var headers = 0
        for rawLine in patch.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            if line.hasSuffix("\r") { line = line.dropLast() }
            // By scalar, as git writes bytes: a combining mark after the space does not hide the header.
            if line.unicodeScalars.starts(with: "diff --git ".unicodeScalars) { headers += 1 }
        }
        expectEqual(files.count, headers, "one file per `diff --git` line")
        for file in files { checkConsistency(file) }
    }

    static func rawHunkHeader(_ line: String) {
        guard let hunk = DiffParser.hunkHeader(Substring(line)) else { return }
        checkHeaderRoundTrip(hunk)
    }

    /// Line numbers follow from the hunk starts, and the file's counts match its lines.
    private static func checkConsistency(_ file: FileDiff) {
        var additions = 0
        var deletions = 0
        for hunk in file.hunks {
            let pairs = SplitDiffLine.align(hunk.lines)
            let represented = pairs.flatMap { [$0.before, $0.after].compactMap { $0 } }
            expectEqual(Set(represented), Set(hunk.lines.indices), "side-by-side layout preserves every source line")
            for pair in pairs {
                if let index = pair.before { expect(hunk.lines[index].kind != .addition, "no addition on the old side") }
                if let index = pair.after { expect(hunk.lines[index].kind != .deletion, "no deletion on the new side") }
            }
            var oldLine = hunk.oldStart
            var newLine = hunk.newStart
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    expect(line.oldLine == oldLine && line.newLine == newLine, "context line numbers in \(hunk.header)")
                    oldLine &+= 1
                    newLine &+= 1
                case .deletion:
                    expect(line.oldLine == oldLine && line.newLine == nil, "deletion line numbers in \(hunk.header)")
                    oldLine &+= 1
                    deletions += 1
                case .addition:
                    expect(line.oldLine == nil && line.newLine == newLine, "addition line numbers in \(hunk.header)")
                    newLine &+= 1
                    additions += 1
                case .noNewline:
                    expect(line.oldLine == nil && line.newLine == nil, "a no-newline marker has no line numbers")
                }
            }
            checkHeaderRoundTrip(hunk)
        }
        expectEqual(file.additions, additions, "additions of \(file.path)")
        expectEqual(file.deletions, deletions, "deletions of \(file.path)")
    }

    /// `DiffHunk.header` reads back as the same hunk.
    private static func checkHeaderRoundTrip(_ hunk: DiffHunk) {
        guard let reparsed = DiffParser.hunkHeader(Substring(hunk.header)) else {
            fail("header does not parse: \(hunk.header.debugDescription)")
        }
        expect(
            reparsed.oldStart == hunk.oldStart && reparsed.oldCount == hunk.oldCount
                && reparsed.newStart == hunk.newStart && reparsed.newCount == hunk.newCount
                && reparsed.section == hunk.section,
            "header round trip of \(hunk.header.debugDescription)")
    }

    // MARK: Round trip

    static func roundTrip(_ input: FuzzInput) {
        var input = input
        let quotePath = input.bool()
        var lines: [String] = []
        var expected: [FileDiff] = []
        for _ in 0..<input.int(in: 1...4) {
            let file = writeFile(&input, quotePath: quotePath)
            lines += file.lines
            expected.append(file.diff)
        }
        let patch = lines.joined(separator: "\n") + (input.bool() ? "\n" : "")
        let parsed = DiffParser.parse(patch)
        expectEqual(parsed, expected, "parse(\(patch.debugDescription))")
        for file in parsed { checkConsistency(file) }
    }

    /// One file of `git -c core.quotePath=<quotePath> diff --find-renames --src-prefix=a/ --dst-prefix=b/`.
    private static func writeFile(_ input: inout FuzzInput, quotePath: Bool) -> (lines: [String], diff: FileDiff) {
        func name(_ path: String) -> String { GitQuote.path(path, quotePath: quotePath) }
        // git appends a tab to `---`/`+++` lines when the file name contains a space.
        func tab(_ path: String) -> String { path.contains(" ") ? "\t" : "" }

        let path = input.gitPath()
        var file = FileDiff(path: path, status: .modified)
        var lines = ["diff --git \(name("a/" + path)) \(name("b/" + path))"]
        let markers = ["--- \(name("a/" + path))\(tab(path))", "+++ \(name("b/" + path))\(tab(path))"]

        switch input.int(in: 0...7) {
        case 0:
            lines += ["index 1111111..2222222 100644"] + markers
            writeHunks(&input, into: &lines, file: &file)
        case 1:
            file.status = .added
            lines += ["new file mode 100644", "index 0000000..2222222", "--- /dev/null\(tab(path))", markers[1]]
            writeHunk(&input, into: &lines, file: &file, oldStart: 0, newStart: 1, kinds: [.addition])
        case 2:
            // An empty new file has no hunks, so its path comes from the `diff --git` line.
            file.status = .added
            lines += ["new file mode 100644", "index 0000000..e69de29"]
        case 3:
            file.status = .deleted
            lines += ["deleted file mode 100644", "index 1111111..0000000", markers[0], "+++ /dev/null\(tab(path))"]
            writeHunk(&input, into: &lines, file: &file, oldStart: 1, newStart: 0, kinds: [.deletion])
        case 4, 5:
            var oldPath = input.gitPath()
            if oldPath == path { oldPath += "~" }
            file.status = .renamed
            file.oldPath = oldPath
            lines = [
                "diff --git \(name("a/" + oldPath)) \(name("b/" + path))", "similarity index 90%",
                "rename from \(name(oldPath))", "rename to \(name(path))",
            ]
            if input.bool() {
                lines += ["index 1111111..2222222 100644", "--- \(name("a/" + oldPath))\(tab(oldPath))", markers[1]]
                writeHunks(&input, into: &lines, file: &file)
            }
        case 6:
            file.modeChange = "100644 → 100755"
            lines += ["old mode 100644", "new mode 100755"]
            if input.bool() {
                lines += ["index 1111111..2222222"] + markers
                writeHunks(&input, into: &lines, file: &file)
            }
        default:
            file.isBinary = true
            lines.append("index 1111111..2222222 100644")
            if input.bool() {
                lines.append("Binary files \(name("a/" + path)) and \(name("b/" + path)) differ")
            } else {
                lines += ["GIT binary patch", "literal 12", "ScmZp0Xmwb@a$#a;00RI3", "", "literal 0", "HcmV?d00001", ""]
            }
        }
        return (lines, file)
    }

    private static func writeHunks(_ input: inout FuzzInput, into lines: inout [String], file: inout FileDiff) {
        var oldStart = input.int(in: 1...4)
        var newStart = oldStart + input.int(in: 0...3)
        for _ in 0..<input.int(in: 1...3) {
            let hunk = writeHunk(
                &input, into: &lines, file: &file, oldStart: oldStart, newStart: newStart,
                kinds: [.context, .deletion, .addition])
            // Later hunks start past this one, with unchanged lines between them.
            let gap = input.int(in: 1...9)
            oldStart += hunk.oldCount + gap
            newStart += hunk.newCount + gap
        }
    }

    @discardableResult
    private static func writeHunk(
        _ input: inout FuzzInput, into lines: inout [String], file: inout FileDiff, oldStart: Int, newStart: Int,
        kinds: [DiffLine.Kind]
    ) -> DiffHunk {
        var body: [String] = []
        var hunk = DiffHunk(oldStart: oldStart, oldCount: 0, newStart: newStart, newCount: 0)
        var oldLine = oldStart
        var newLine = newStart
        for _ in 0..<input.int(in: 1...8) {
            let text = input.lineText()
            // DiffParser drops the carriage return of a CRLF line.
            let shown = stripCR(text)
            switch input.pick(kinds) {
            case .context:
                body.append(" " + text)
                hunk.lines.append(DiffLine(kind: .context, text: shown, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
                hunk.oldCount += 1
                hunk.newCount += 1
            case .deletion:
                body.append("-" + text)
                hunk.lines.append(DiffLine(kind: .deletion, text: shown, oldLine: oldLine))
                oldLine += 1
                hunk.oldCount += 1
                file.deletions += 1
            default:
                body.append("+" + text)
                hunk.lines.append(DiffLine(kind: .addition, text: shown, newLine: newLine))
                newLine += 1
                hunk.newCount += 1
                file.additions += 1
            }
        }
        if input.int(in: 0...4) == 0 {
            body.append("\\ No newline at end of file")
            hunk.lines.append(DiffLine(kind: .noNewline, text: "\\ No newline at end of file"))
        }
        // git omits a count of 1.
        func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        var header = "@@ -\(range(oldStart, hunk.oldCount)) +\(range(newStart, hunk.newCount)) @@"
        if input.bool() {
            let section = input.lineText()
            header += " " + section
            hunk.section = stripCR(section)
        }
        lines.append(header)
        lines += body
        file.hunks.append(hunk)
        return hunk
    }

    private static func stripCR(_ text: String) -> String {
        text.hasSuffix("\r") ? String(text.dropLast()) : text
    }
}
