/// Reads structured values from a fuzzer's bytes. Once the bytes run out every read returns its
/// smallest value, so any input, however short, produces a valid (if small) test case.
public struct FuzzInput {
    private let bytes: [UInt8]
    private var position = 0

    public init(_ bytes: some Sequence<UInt8>) {
        self.bytes = Array(bytes)
    }

    public var isAtEnd: Bool { position >= bytes.count }

    public mutating func byte() -> UInt8 {
        guard position < bytes.count else { return 0 }
        defer { position += 1 }
        return bytes[position]
    }

    public mutating func bool() -> Bool { byte() & 1 == 1 }

    /// A value in `range`, read from one byte when the range has at most 256 values and two otherwise.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let width = range.upperBound - range.lowerBound + 1
        let raw = width <= 256 ? Int(byte()) : Int(byte()) << 8 | Int(byte())
        return range.lowerBound + raw % width
    }

    public mutating func pick<T>(_ options: [T]) -> T {
        options[int(in: 0...(options.count - 1))]
    }

    /// Up to `maxPieces` pieces of `alphabet`, concatenated.
    public mutating func text(_ alphabet: [String], maxPieces: Int) -> String {
        var result = ""
        for _ in 0..<int(in: 0...maxPieces) { result += pick(alphabet) }
        return result
    }

    /// `count` lowercase hex digits, such as an object id.
    public mutating func hex(_ count: Int) -> String {
        let digits = Array("0123456789abcdef")
        return String((0..<count).map { _ in digits[Int(byte() & 0x0F)] })
    }

    /// Everything not read yet.
    public mutating func rest() -> [UInt8] {
        defer { position = bytes.count }
        return position < bytes.count ? Array(bytes[position...]) : []
    }
}
