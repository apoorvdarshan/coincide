import Foundation

/// One model request read from a CLI's session log.
public struct LoggedRequest: Sendable, Hashable {
    public var date: Date
    public var model: String?
    public var tokens: TokenTotals
    /// The request's whole prompt, cached or not, which decides long-context pricing.
    public var promptTokens: Int
    /// Identifies a response Claude Code logged more than once (its message and request ids, hashed); 0 for none.
    public var key: UInt64

    public nonisolated init(date: Date, model: String?, tokens: TokenTotals, promptTokens: Int, key: UInt64 = 0) {
        self.date = date
        self.model = model
        self.tokens = tokens
        self.promptTokens = max(0, promptTokens)
        self.key = key
    }
}

/// Reads Claude Code's transcripts (`<config>/projects/<project>/<session>.jsonl`): every assistant line carries its
/// response's `usage`. Claude Code writes one line per content block, repeating the usage with the output count
/// growing, so lines of one response share a key and the scanner keeps the largest counts.
enum ClaudeLogParser {
    /// Cheap checks on the raw line before decoding it: only assistant lines with usage are of interest.
    nonisolated static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        line.contains(#""usage""#) && line.contains(#""assistant""#)
    }

    /// The request a line reports and the session it belongs to, or nil for any other line.
    nonisolated static func request(fromLine data: Data) -> (request: LoggedRequest, sessionID: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else { return nil }
        let model = message["model"] as? String
        // Claude Code's own placeholder replies (errors, interruptions) cost nothing.
        guard model != "<synthetic>" else { return nil }
        guard let date = (object["timestamp"] as? String).flatMap(UsageLogDates.instant) else { return nil }
        func count(_ value: Any?) -> Int { max(0, (value as? NSNumber)?.intValue ?? 0) }
        let cacheWrite = count(usage["cache_creation_input_tokens"])
        let longWrite = count((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
        let output = count(usage["output_tokens"])
        let thinking = count((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
        let tokens = TokenTotals(
            input: count(usage["input_tokens"]), cacheRead: count(usage["cache_read_input_tokens"]), cacheWrite: cacheWrite,
            cacheWriteLong: longWrite, output: output, reasoning: thinking)
        var key: UInt64 = 0
        if let id = message["id"] as? String, !id.isEmpty {
            key = UsageLogHash.fnv1a(id + "\u{0}" + ((object["requestId"] as? String) ?? ""))
        }
        let request = LoggedRequest(date: date, model: model, tokens: tokens, promptTokens: tokens.allInput, key: key)
        return (request, object["sessionId"] as? String)
    }
}

/// Reads Codex's rollouts (`<home>/sessions/YYYY/MM/DD/rollout-….jsonl`): `token_count` events carry the session's
/// running totals, so each request is the growth since the previous event (Codex repeats unchanged totals). The model
/// comes from the latest `turn_context`; the first `session_meta` names the session and the client that ran it.
struct CodexLogParser: Codable, Sendable, Hashable {
    /// The running totals of the last `token_count`: input (with cached and cache-written tokens), cached input,
    /// cache-written input, output (with reasoning) and reasoning.
    var last: [Int]?
    var model: String?
    var sessionID: String?
    /// The client that ran the session (`coincide`, `codex-tui`, `codex_exec`, …).
    var originator: String?
    /// When the session (or fork) began; events a fork copied from its parent are older.
    var startedAt: Date?
    var isFork = false

    nonisolated init() {}

    nonisolated static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        // Every rollout line starts with its timestamp and type; skip the large response items without decoding them.
        let head = UnsafeRawBufferPointer(rebasing: line.prefix(160))
        return head.contains(#""token_count""#) || head.contains(#""turn_context""#) || head.contains(#""session_meta""#)
    }

    /// Takes one line; returns the request it reports, if any.
    nonisolated mutating func consume(_ data: Data) -> LoggedRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = object["payload"] as? [String: Any]
        else { return nil }
        let date = (object["timestamp"] as? String).flatMap(UsageLogDates.instant)
        switch object["type"] as? String {
        case "session_meta":
            // Forks list their parent's metadata after their own; only the first line is this session's.
            guard sessionID == nil else { return nil }
            sessionID = payload["id"] as? String
            originator = payload["originator"] as? String
            startedAt = (payload["timestamp"] as? String).flatMap(UsageLogDates.instant) ?? date
            isFork = payload["forked_from_id"] is String
            return nil
        case "turn_context":
            if let name = payload["model"] as? String, !name.isEmpty { model = name }
            return nil
        case "event_msg":
            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                let total = info["total_token_usage"] as? [String: Any], let date
            else { return nil }
            let current = Self.counts(total)
            let previous = last
            last = current
            // A fork's copy of its parent's history was counted in the parent's own file.
            if isFork, let startedAt, date < startedAt.addingTimeInterval(-1) { return nil }
            let delta: [Int]
            if let previous, zip(current, previous).allSatisfy({ $0 >= $1 }) {
                delta = zip(current, previous).map { $0 - $1 }
            } else if previous != nil {
                // The totals went down (Codex restarted counting): the last request's own usage is all that is new.
                delta = (info["last_token_usage"] as? [String: Any]).map(Self.counts) ?? current
            } else {
                delta = current
            }
            guard delta.contains(where: { $0 > 0 }) else { return nil }
            let prompt = (info["last_token_usage"] as? [String: Any]).map { Self.counts($0)[0] } ?? delta[0]
            return LoggedRequest(date: date, model: model, tokens: Self.totals(delta), promptTokens: prompt)
        default:
            return nil
        }
    }

    private nonisolated static func counts(_ usage: [String: Any]) -> [Int] {
        func count(_ key: String) -> Int { max(0, (usage[key] as? NSNumber)?.intValue ?? 0) }
        return [
            count("input_tokens"), count("cached_input_tokens"), count("cache_write_input_tokens"), count("output_tokens"),
            count("reasoning_output_tokens"),
        ]
    }

    /// OpenAI counts cached and cache-written tokens within the input, and reasoning within the output.
    private nonisolated static func totals(_ counts: [Int]) -> TokenTotals {
        let input = counts[0]
        let cached = min(counts[1], input)
        let written = min(counts[2], input - cached)
        return TokenTotals(
            input: input - cached - written, cacheRead: cached, cacheWrite: written, output: counts[3], reasoning: counts[4])
    }
}

enum UsageLogHash {
    /// 64-bit FNV-1a: stable across launches, unlike `Hasher`, so keys can be kept on disk.
    nonisolated static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash == 0 ? 1 : hash
    }
}

enum UsageLogDates {
    /// `2026-10-21T21:12:11.327Z`, as both CLIs write it, read without a formatter; other forms go through
    /// `UsageLimitDates.instant`.
    nonisolated static func instant(_ text: String) -> Date? {
        var utf8 = text.utf8.makeIterator()
        var digits: [Int] = []
        digits.reserveCapacity(20)
        var fraction = 0.0
        var scale = 0.1
        var inFraction = false
        var position = 0
        while let byte = utf8.next() {
            position += 1
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                if inFraction {
                    fraction += Double(byte - UInt8(ascii: "0")) * scale
                    scale /= 10
                } else {
                    digits.append(Int(byte - UInt8(ascii: "0")))
                }
            case UInt8(ascii: "."):
                inFraction = true
            case UInt8(ascii: "Z"):
                guard position == text.utf8.count, digits.count == 14 else { return UsageLimitDates.instant(text) }
            case UInt8(ascii: "-"), UInt8(ascii: ":"), UInt8(ascii: "T"):
                guard !inFraction else { return UsageLimitDates.instant(text) }
            default:
                return UsageLimitDates.instant(text)
            }
        }
        guard digits.count == 14, text.utf8.last == UInt8(ascii: "Z") else { return UsageLimitDates.instant(text) }
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        let year = number(0..<4)
        let month = number(4..<6)
        let day = number(6..<8)
        let hour = number(8..<10)
        let minute = number(10..<12)
        let second = number(12..<14)
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = Double(days * 86_400 + hour * 3_600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }
}

extension UnsafeRawBufferPointer {
    /// Whether the bytes contain `needle`'s UTF-8 bytes.
    nonisolated func contains(_ needle: StaticString) -> Bool {
        guard let base = baseAddress, count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }
}
