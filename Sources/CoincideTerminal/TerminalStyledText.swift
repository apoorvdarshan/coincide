import CoincideCore
import Foundation
import SwiftTerm

/// Styled terminal history for restart restoration. It is rebuilt from the
/// emulator's cells rather than recorded from raw PTY bytes, so it can only
/// contain text, newlines, tabs and SGR attribute sequences
/// (`ESC [ digits/;/: m`). Queries, replies, OSC (titles, clipboard, links),
/// DCS/APC, cursor movement and mode changes cannot be represented, so replaying
/// it can never provoke a terminal reply or a program action.
public enum TerminalStyledText {
    public static let lineLimit = 5_000
    public static let byteLimit = 1_048_576
    private static let sgrParameterLimit = 64

    /// Styled history and its plain-text form, captured together.
    public struct History: Equatable, Sendable {
        public let styled: String
        public let plain: String
        public init(styled: String, plain: String) { self.styled = styled; self.plain = plain }
        public static let empty = History(styled: "", plain: "")
    }

    /// Encodes the normal-screen history (not an alternate screen) as SGR text,
    /// plus the same rows without attributes.
    public static func encode(_ snapshot: TerminalContentSnapshot) -> History {
        var styledLines: [String] = [], plainLines: [String] = []
        var styled = "", plain = ""
        // Attributes compare by their SGR form: SwiftTerm has several spellings of "default".
        var lastAttribute = Attribute.empty, lastSGR = reset, currentSGR = reset
        let rows = snapshot.rows
        styledLines.reserveCapacity(rows.count); plainLines.reserveCapacity(rows.count)
        func isBlank(_ cell: TerminalCellSnapshot) -> Bool {
            cell.text.utf8.allSatisfy({ $0 == 0x20 || $0 == 0 }) && isDefault(cell.attribute.bg) && !cell.attribute.style.contains(.inverse)
                && cell.attribute.underlineStyle == .none && !cell.attribute.style.contains(.underline)
        }
        for index in rows.indices {
            let row = rows[index]
            if index > 0, !row.isWrapped {
                if currentSGR != reset { styled += reset; currentSGR = reset }
                styledLines.append(styled); plainLines.append(plain); styled = ""; plain = ""
            }
            let cells = row.cells
            var end = cells.count
            // A soft-wrapped row continues on the next row, so its trailing cells are content.
            let continues = index + 1 < rows.count && rows[index + 1].isWrapped
            while !continues, end > 0, isBlank(cells[end - 1]) { end -= 1 }
            for cell in cells[..<end] where cell.width > 0 {
                if cell.attribute != lastAttribute { lastAttribute = cell.attribute; lastSGR = sgr(cell.attribute) }
                if lastSGR != currentSGR { styled += lastSGR; currentSGR = lastSGR }
                // Cells hold printed characters; a stray control is never written back.
                let text = cell.text.isEmpty || cell.text.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) ? " " : cell.text
                styled += text; plain += text
            }
        }
        if currentSGR != reset { styled += reset }
        styledLines.append(styled); plainLines.append(plain)
        while styledLines.count > 1, let last = plainLines.last, last.isEmpty { styledLines.removeLast(); plainLines.removeLast() }
        return .init(styled: sanitized(bounded(styledLines.suffix(lineLimit).joined(separator: "\n"))),
                     plain: TerminalTabArchive.displayText(plainLines.suffix(lineLimit).joined(separator: "\n")))
    }

    private static func isDefault(_ color: Attribute.Color) -> Bool {
        switch color { case .defaultColor, .defaultInvertedColor: true; default: false }
    }

    /// Keeps the newest complete lines within the byte limit.
    public static func bounded(_ text: String) -> String {
        guard text.utf8.count > byteLimit else { return text }
        var bytes = Array(text.utf8.suffix(byteLimit))
        if let newline = bytes.firstIndex(of: 0x0a) { bytes.removeSubrange(...newline) }
        while let first = bytes.first, first & 0xc0 == 0x80 { bytes.removeFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Removes everything except text, newline/tab and well-formed SGR: C0/C1
    /// controls, DEL and whole non-SGR escape sequences are dropped. Saved
    /// archives must already equal their sanitized form.
    public static func sanitized(_ text: String) -> String {
        let needsWork = text.utf8.contains { ($0 < 0x20 && $0 != 0x0a && $0 != 0x09) || $0 == 0x7f || $0 == 0xc2 }
        guard needsWork else { return text }
        let bytes = Array(text.utf8)
        var output: [UInt8] = []; output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1b {
                if let end = sgrEnd(bytes, at: index) { output.append(contentsOf: bytes[index...end]); index = end + 1 }
                else { index = skipEscape(bytes, at: index) }
                continue
            }
            if (byte < 0x20 && byte != 0x0a && byte != 0x09) || byte == 0x7f { index += 1; continue }
            if byte == 0xc2, index + 1 < bytes.count, (0x80...0x9f).contains(bytes[index + 1]) { index += 2; continue }
            output.append(byte); index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Plain display text for accessibility and older archive readers.
    public static func plainText(_ styled: String) -> String {
        let bytes = Array(sanitized(styled).utf8)
        var output: [UInt8] = []; output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x1b, let end = sgrEnd(bytes, at: index) { index = end + 1; continue }
            output.append(bytes[index]); index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static let reset = "\u{1b}[0m"

    /// The index of the `m` that ends a bounded SGR sequence starting at `start`.
    private static func sgrEnd(_ bytes: [UInt8], at start: Int) -> Int? {
        guard start + 1 < bytes.count, bytes[start + 1] == 0x5b else { return nil }
        var index = start + 2
        while index < bytes.count, index - start <= sgrParameterLimit + 2,
              (0x30...0x39).contains(bytes[index]) || bytes[index] == 0x3b || bytes[index] == 0x3a { index += 1 }
        return index < bytes.count && bytes[index] == 0x6d && index - start <= sgrParameterLimit + 2 ? index : nil
    }

    /// The index after a whole non-SGR escape: CSI through its final byte,
    /// OSC/DCS/APC/PM/SOS through BEL or ST, otherwise ESC and one more byte.
    private static func skipEscape(_ bytes: [UInt8], at start: Int) -> Int {
        var index = start + 1
        guard index < bytes.count else { return index }
        switch bytes[index] {
        case 0x5b:
            index += 1
            while index < bytes.count, !(0x40...0x7e).contains(bytes[index]) { index += 1 }
            return min(bytes.count, index + 1)
        case 0x5d, 0x50, 0x5f, 0x5e, 0x58:
            index += 1
            while index < bytes.count {
                if bytes[index] == 0x07 { return index + 1 }
                if bytes[index] == 0x1b, index + 1 < bytes.count, bytes[index + 1] == 0x5c { return index + 2 }
                index += 1
            }
            return index
        default:
            // Never split a multi-byte character after a lone escape.
            index += 1
            while index < bytes.count, bytes[index] & 0xc0 == 0x80 { index += 1 }
            return index
        }
    }

    static func sgr(_ attribute: Attribute) -> String {
        var codes = ["0"]
        let style = attribute.style
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) || attribute.underlineStyle != .none { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        codes += color(attribute.fg, base: 30, bright: 90, extended: 38)
        codes += color(attribute.bg, base: 40, bright: 100, extended: 48)
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }
    private static func color(_ color: Attribute.Color, base: Int, bright: Int, extended: Int) -> [String] {
        switch color {
        case .ansi256(let code) where code < 8: return [String(base + Int(code))]
        case .ansi256(let code) where code < 16: return [String(bright + Int(code) - 8)]
        case .ansi256(let code): return [String(extended), "5", String(code)]
        case .trueColor(let red, let green, let blue): return [String(extended), "2", String(red), String(green), String(blue)]
        case .defaultColor, .defaultInvertedColor: return []
        }
    }
}
