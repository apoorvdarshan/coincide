import Foundation

/// Mozilla's Public Suffix List (publicsuffix.org), shipped unmodified as `public_suffix_list.dat` under the Mozilla
/// Public License 2.0 (see THIRD_PARTY_NOTICES.md; `scripts/update-public-suffix-list.sh` refreshes it). Rules from its
/// ICANN and private sections both count, as they do for browsers' cookies, so `github.io` is a suffix that every
/// customer's site sits under and none of them can claim.
///
/// Hosts are ASCII (internationalized labels in their `xn--` form, as WebKit reports them); the list's own
/// internationalized rules are converted with Punycode when it loads.
public nonisolated struct PublicSuffixList: Sendable {
    private let rules: Set<String>
    /// `*.ck` is kept as `ck`: every label directly under it is a suffix.
    private let wildcards: Set<String>
    /// `!www.ck` is kept as `www.ck`: registrable, although a wildcard covers it.
    private let exceptions: Set<String>

    /// Parses the list's text: one rule per line up to the first whitespace, `//` comments, blank lines ignored.
    public init(_ text: String) {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let token = line.split(whereSeparator: \.isWhitespace).first, !token.hasPrefix("//") else { continue }
            var rule = token.lowercased()
            if rule.hasPrefix("!") {
                rule.removeFirst()
                if let ascii = Self.ascii(rule) { exceptions.insert(ascii) }
            } else if rule.hasPrefix("*.") {
                rule.removeFirst(2)
                if let ascii = Self.ascii(rule) { wildcards.insert(ascii) }
            } else if let ascii = Self.ascii(rule) {
                rules.insert(ascii)
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    /// The copy bundled with CoincideKit, or nil when it is missing or doesn't look like the full list. Callers fail
    /// closed without it.
    public static let bundled: PublicSuffixList? = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "public_suffix_list", withExtension: "dat"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let list = PublicSuffixList(text)
        return list.isComplete ? list : nil
    }()

    private final class BundleToken {}

    /// Whether the list has the size and landmarks of the real one, so a truncated file isn't trusted.
    var isComplete: Bool {
        rules.count > 5_000 && wildcards.count > 50 && !exceptions.isEmpty
            && ["com", "co.uk", "github.io"].allSatisfy(rules.contains)
    }

    /// The public suffix of `host`: the longest rule it matches, an exception rule taking precedence, or its last label
    /// when no rule matches (the list's implicit `*`). Nil when `host` isn't a valid ASCII domain.
    public func publicSuffix(of host: String) -> String? {
        guard let labels = Self.labels(host) else { return nil }
        let count = labels.count
        for start in 0..<count where exceptions.contains(labels[start...].joined(separator: ".")) {
            return labels[(start + 1)...].joined(separator: ".")
        }
        for start in 0..<count {
            let suffix = labels[start...].joined(separator: ".")
            if rules.contains(suffix) { return suffix }
            if start + 1 < count, wildcards.contains(labels[(start + 1)...].joined(separator: ".")) { return suffix }
        }
        return labels[count - 1]
    }

    /// The public suffix plus one label (`www.example.co.uk` → `example.co.uk`), or nil when `host` is itself a public
    /// suffix or isn't a valid domain.
    public func registrableDomain(of host: String) -> String? {
        guard let labels = Self.labels(host), let suffix = publicSuffix(of: host) else { return nil }
        let suffixCount = suffix.split(separator: ".").count
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }

    /// Whether `host` is a public suffix, which no site may claim as its own (`com`, `co.uk`, `github.io`).
    public func isPublicSuffix(_ host: String) -> Bool {
        guard let suffix = publicSuffix(of: host) else { return false }
        return suffix == host.lowercased()
    }

    /// The labels of a lowercase ASCII domain: no empty labels (so no leading or trailing dot), at most 253 characters.
    static func labels(_ host: String) -> [String]? {
        let host = host.lowercased()
        guard !host.isEmpty, host.utf8.count <= 253, host.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }) else { return nil }
        return labels
    }

    /// A rule with its internationalized labels in `xn--` form.
    static func ascii(_ rule: String) -> String? {
        var labels: [String] = []
        for label in rule.split(separator: ".", omittingEmptySubsequences: false) {
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                labels.append(String(label))
            } else {
                guard let encoded = Punycode.encode(String(label)) else { return nil }
                labels.append("xn--" + encoded)
            }
        }
        return labels.contains(where: \.isEmpty) ? nil : labels.joined(separator: ".")
    }
}

/// RFC 3492 Punycode encoding of one label, as IDNA uses after its `xn--` prefix. Only for the suffix list's own rules,
/// which are already normalized (lowercase, NFC).
nonisolated enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 0x80

    static func encode(_ input: String) -> String? {
        let points = input.unicodeScalars.map { Int($0.value) }
        var output = String(String.UnicodeScalarView(input.unicodeScalars.filter(\.isASCII)))
        let basic = output.unicodeScalars.count
        var handled = basic
        if basic > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < points.count {
            guard let next = points.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (next - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow, delta <= Int(Int32.max) - product else { return nil }
            delta += product
            n = next
            for point in points {
                if point < n { delta += 1 }
                guard point == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, points: handled + 1, first: handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return output
    }

    private static func digit(_ value: Int) -> Character {
        Character(UnicodeScalar(UInt8(value < 26 ? 0x61 + value : 0x30 + value - 26)))
    }

    private static func adapt(_ delta: Int, points: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / points
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + ((base - tMin + 1) * delta) / (delta + skew)
    }
}
