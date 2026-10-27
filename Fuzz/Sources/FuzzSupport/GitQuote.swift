/// Git's C-style path quoting (`quote_c_style` in git's quote.c), used to write git output the way
/// git itself would, so the parsers can be checked against what they should read back.
public enum GitQuote {
    /// `name` quoted the way git prints it, or unchanged when git would not quote it. With
    /// `core.quotePath=true` (git's default) bytes above 0x7F are escaped too; Coincide's patch reads
    /// use `core.quotePath=false`, which leaves UTF-8 as is.
    public static func path(_ name: String, quotePath: Bool) -> String {
        let bytes = Array(name.utf8)
        guard bytes.contains(where: { mustQuote($0, quotePath: quotePath) }) else { return name }
        return quoted(bytes, quotePath: quotePath)
    }

    /// `bytes` in double quotes with escapes, whether or not git would need to quote them. The result
    /// is ASCII when `quotePath` is true.
    public static func quoted(_ bytes: [UInt8], quotePath: Bool) -> String {
        var output: [UInt8] = [UInt8(ascii: "\"")]
        for byte in bytes {
            switch byte {
            case 0x07: output += Array("\\a".utf8)
            case 0x08: output += Array("\\b".utf8)
            case 0x09: output += Array("\\t".utf8)
            case 0x0A: output += Array("\\n".utf8)
            case 0x0B: output += Array("\\v".utf8)
            case 0x0C: output += Array("\\f".utf8)
            case 0x0D: output += Array("\\r".utf8)
            case UInt8(ascii: "\""): output += Array("\\\"".utf8)
            case UInt8(ascii: "\\"): output += Array("\\\\".utf8)
            default:
                if byte < 0x20 || byte == 0x7F || (byte >= 0x80 && quotePath) {
                    output += [
                        UInt8(ascii: "\\"), UInt8(ascii: "0") + (byte >> 6), UInt8(ascii: "0") + (byte >> 3 & 7),
                        UInt8(ascii: "0") + (byte & 7),
                    ]
                } else {
                    output.append(byte)
                }
            }
        }
        output.append(UInt8(ascii: "\""))
        return String(decoding: output, as: UTF8.self)
    }

    private static func mustQuote(_ byte: UInt8, quotePath: Bool) -> Bool {
        byte < 0x20 || byte == 0x7F || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\")
            || (byte >= 0x80 && quotePath)
    }
}
