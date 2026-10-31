import Foundation

/// What the shell integration (`ShellIntegration`) reports about prompts and commands, read from the OSC sequences it
/// prints: the prompt's height, the last command line and whether a command is running.
struct TerminalCommandState: Equatable, Sendable {
    /// Lines the current prompt takes; the command is typed on its last.
    var promptLines = 1
    /// The newest command line, once the shell has run one.
    var command: String?
    var isRunning = false
    /// The newest finished command's exit status.
    var exitStatus: Int32?
    /// The shell has marked at least one prompt, so it has the integration.
    var hasMarks = false

    /// Updates for one OSC sequence; false when it isn't one of the integration's.
    @discardableResult
    mutating func apply(code: Int, payload: [UInt8]) -> Bool {
        let text = String(decoding: payload, as: UTF8.self)
        switch code {
        case 133:
            let parts = text.split(separator: ";", omittingEmptySubsequences: false)
            switch parts.first {
            case "A":
                hasMarks = true
                isRunning = false
            case "C":
                isRunning = true
            case "D":
                isRunning = false
                exitStatus = parts.count > 1 ? Int32(parts[1]) : nil
            default:
                return false
            }
        case 1337:
            if text.hasPrefix("CoincidePrompt=") {
                promptLines = max(1, min(50, Int(text.dropFirst("CoincidePrompt=".count)) ?? 1))
            } else if text.hasPrefix("CoincideCommand=") {
                let line = text.dropFirst("CoincideCommand=".count).trimmingCharacters(in: .whitespaces)
                command = line.isEmpty ? nil : String(line.prefix(4_096))
            } else {
                return false
            }
        default:
            return false
        }
        return true
    }
}

/// Finds a command's output in the terminal's text, from the command line the shell integration reported.
enum TerminalCommandOutput {
    /// One logical line of the buffer: physical rows joined where the terminal wrapped them.
    struct Line: Equatable {
        var text: String
        /// The first and last physical rows it spans, in the buffer's coordinates.
        var rows: ClosedRange<Int>
    }

    /// Joins `rows` (text, row number, whether it continues the row before) into logical lines.
    nonisolated static func lines(_ rows: [(text: String, row: Int, isWrapped: Bool)]) -> [Line] {
        var lines: [Line] = []
        for row in rows {
            if row.isWrapped, var last = lines.last, last.rows.upperBound == row.row - 1 {
                last.text += row.text
                last.rows = last.rows.lowerBound...row.row
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(text: row.text, rows: row.row...row.row))
            }
        }
        return lines
    }

    /// The newest run of `command` and what it printed, as "$ command" and the output: everything after the last line
    /// ending with the command line, up to the current prompt (its first of `promptLines` lines holds `cursorRow`'s
    /// prompt) or, while it still runs, up to the cursor. Nil when the command line isn't on screen or in the
    /// scrollback any more.
    nonisolated static func lastOutput(
        lines: [Line], cursorRow: Int, promptLines: Int, command: String, isRunning: Bool
    ) -> String? {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, let cursorLine = lines.lastIndex(where: { $0.rows.lowerBound <= cursorRow }) else { return nil }
        // While idle the cursor sits on the prompt's last line; the prompt starts promptLines - 1 lines above.
        let end = isRunning ? cursorLine + 1 : max(0, cursorLine - (promptLines - 1))
        guard end > 0,
            let start = lines[..<end].lastIndex(where: { trimmed($0.text).hasSuffix(command) })
        else { return nil }
        var output = lines[(start + 1)..<end].map { trimmed($0.text) }
        while output.last?.isEmpty == true { output.removeLast() }
        return (["$ " + command] + output).joined(separator: "\n")
    }

    private nonisolated static func trimmed(_ text: String) -> String {
        String(text.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}
