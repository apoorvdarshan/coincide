import Foundation

public struct WorkspaceContentMatchRange: Codable, Sendable, Equatable {
    /// Zero-based UTF-16 offsets into the original line; end is exclusive.
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}
public struct WorkspaceContentMatch: Codable, Sendable, Equatable {
    public let path: String
    public let lineNumber: Int
    public let lineContent: String
    public let matchRanges: [WorkspaceContentMatchRange]
    public init(path: String, lineNumber: Int, lineContent: String, matchRanges: [WorkspaceContentMatchRange]) {
        self.path = path; self.lineNumber = lineNumber; self.lineContent = lineContent; self.matchRanges = matchRanges
    }
}
public struct WorkspaceContentSearchResult: Codable, Sendable, Equatable {
    public let matches: [WorkspaceContentMatch]
    public let truncated: Bool
    /// Native syntax/engine differences are not fff fallback-result compatibility.
    public let regexFallbackError: String?
    public init(matches: [WorkspaceContentMatch], truncated: Bool, regexFallbackError: String? = nil) {
        self.matches = matches; self.truncated = truncated; self.regexFallbackError = regexFallbackError
    }
}

/// Test overrides can tighten these bounds, never raise the production limits.
struct WorkspaceContentSearchLimits: Sendable {
    let discoveryBudget: Duration, matchingBudget: Duration
    let maximumEntries: Int, maximumFileBytes: Int, maximumTotalBytes: Int
    let maximumLineUTF16: Int, maximumLinesPerFile: Int, maximumRangesPerLine: Int
    init(discoveryBudget: Duration = .seconds(15), matchingBudget: Duration = .milliseconds(250),
         maximumEntries: Int = 25_000, maximumFileBytes: Int = 1_048_576, maximumTotalBytes: Int = 33_554_432,
         maximumLineUTF16: Int = 16_384, maximumLinesPerFile: Int = 100, maximumRangesPerLine: Int = 100) {
        self.discoveryBudget = max(.zero, min(.seconds(15), discoveryBudget))
        self.matchingBudget = max(.zero, min(.milliseconds(250), matchingBudget))
        self.maximumEntries = max(1, min(25_000, maximumEntries))
        self.maximumFileBytes = max(1, min(1_048_576, maximumFileBytes))
        self.maximumTotalBytes = max(1, min(33_554_432, maximumTotalBytes))
        self.maximumLineUTF16 = max(1, min(16_384, maximumLineUTF16))
        self.maximumLinesPerFile = max(1, min(100, maximumLinesPerFile))
        self.maximumRangesPerLine = max(1, min(100, maximumRangesPerLine))
    }
}

enum WorkspaceContentSearch {
    private static let invalidRegex = "This regular expression is invalid or unsupported by the native search engine."
    static func search(root: WorkspaceFileRoot, git: WorkspaceFileGit, query: String, limit: Int,
                       caseSensitive: Bool, wholeWord: Bool, useRegex: Bool,
                       limits: WorkspaceContentSearchLimits) async throws -> WorkspaceContentSearchResult {
        try Task.checkCancellation()
        let expression: NSRegularExpression
        do {
            expression = try .init(pattern: useRegex ? query : NSRegularExpression.escapedPattern(for: query),
                                   options: caseSensitive ? [] : [.caseInsensitive])
        } catch {
            // NSError can include the literal search pattern. Never expose it in diagnostics.
            if useRegex { return .init(matches: [], truncated: false, regexFallbackError: invalidRegex) }
            throw WorkspaceFileError(.operationFailed, "The native text search could not be prepared.")
        }
        let candidates = try await WorkspaceFileWalker.entries(root: root, git: git,
            deadline: ContinuousClock.now + limits.discoveryBudget, maximumEntries: limits.maximumEntries)
        let files = candidates.entries.filter { $0.kind == .file }
        let deadline = ContinuousClock.now + limits.matchingBudget
        var matches: [WorkspaceContentMatch] = [], truncated = candidates.truncated, bytesRead = 0
        for (fileIndex, entry) in files.enumerated() {
            try Task.checkCancellation(); try root.validate()
            guard ContinuousClock.now < deadline, bytesRead < limits.maximumTotalBytes else { truncated = true; break }
            let maximum = min(limits.maximumFileBytes, limits.maximumTotalBytes - bytesRead)
            let document: WorkspaceTextDocument
            do { document = try root.read(entry.path, allowMissing: false, maxBytes: maximum, onRead: { bytesRead += $0 }) }
            catch let error as WorkspaceFileError {
                switch error.failure {
                case .binary, .invalidUTF8: continue
                case .rootReplaced, .closed, .rootMissing, .rootNotDirectory: throw error
                default: truncated = true; continue
                }
            }
            truncated = truncated || document.truncated
            let source = document.contents as NSString
            var cursor = 0, lineNumber = 1, matchingLines = 0
            while cursor < source.length {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { truncated = true; return .init(matches: matches, truncated: truncated) }
                var start = 0, end = 0, contentEnd = 0
                source.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
                guard end > cursor else { throw WorkspaceFileError(.operationFailed, "The native search could not determine a file's line boundaries.") }
                // A preview cutoff is not EOF. Do not manufacture an end-of-line match there.
                if document.truncated, end == source.length, contentEnd == end { truncated = true; break }
                let lineLength = contentEnd - start
                if lineLength > limits.maximumLineUTF16 { truncated = true; cursor = end; lineNumber += 1; continue }
                let line = source.substring(with: NSRange(location: start, length: lineLength))
                let found = try ranges(in: line, expression: expression, wholeWord: wholeWord,
                                       deadline: deadline, maximum: limits.maximumRangesPerLine)
                truncated = truncated || found.truncated
                if !found.ranges.isEmpty {
                    matches.append(.init(path: entry.path, lineNumber: lineNumber, lineContent: line, matchRanges: found.ranges))
                    matchingLines += 1
                    if matches.count == limit {
                        let omitted = end < source.length || fileIndex + 1 < files.count || found.stopped
                        return .init(matches: matches, truncated: truncated || omitted)
                    }
                }
                if found.stopped { return .init(matches: matches, truncated: true) }
                cursor = end; lineNumber += 1
                if matchingLines >= limits.maximumLinesPerFile {
                    if cursor < source.length { truncated = true }
                    break
                }
            }
        }
        try Task.checkCancellation(); try root.validate()
        return .init(matches: matches, truncated: truncated)
    }
    private final class LineResult {
        var ranges: [WorkspaceContentMatchRange] = []
        var truncated = false, stopped = false, internalError = false
    }
    private static func ranges(in line: String, expression: NSRegularExpression, wholeWord: Bool,
                               deadline: ContinuousClock.Instant, maximum: Int) throws -> LineResult {
        let result = LineResult(), source = line as NSString
        // Rejected whole-word candidates can greatly outnumber published matches. Release
        // temporary Foundation match objects after each line rather than at task completion.
        autoreleasepool {
            expression.enumerateMatches(in: line, options: [.reportProgress, .reportCompletion],
                                        range: NSRange(location: 0, length: source.length)) { match, flags, stop in
                if Task.isCancelled || ContinuousClock.now >= deadline {
                    result.truncated = true; result.stopped = true; stop.pointee = true; return
                }
                if flags.contains(.internalError) { result.internalError = true; stop.pointee = true; return }
                guard let match else { return }
                let range = match.range
                guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
                      range.location <= source.length, range.length <= source.length - range.location else { return }
                let value = WorkspaceContentMatchRange(start: range.location, end: NSMaxRange(range))
                if wholeWord && !isWholeWord(value, line: source) { return }
                if result.ranges.count == maximum { result.truncated = true; stop.pointee = true; return }
                result.ranges.append(value)
            }
        }
        try Task.checkCancellation()
        if result.internalError { throw WorkspaceFileError(.operationFailed, "The native regular-expression engine could not complete this search.") }
        return result
    }
    private static func scalar(at offset: Int, in text: NSString) -> Unicode.Scalar? {
        guard offset >= 0, offset < text.length else { return nil }
        let first = text.character(at: offset)
        if (0xd800...0xdbff).contains(first), offset + 1 < text.length {
            let second = text.character(at: offset + 1)
            if (0xdc00...0xdfff).contains(second) { return Unicode.Scalar(0x10000 + (UInt32(first) - 0xd800) * 0x400 + UInt32(second) - 0xdc00) }
        }
        return Unicode.Scalar(first)
    }
    private static func scalar(before offset: Int, in text: NSString) -> Unicode.Scalar? {
        guard offset > 0 else { return nil }
        let last = text.character(at: offset - 1)
        return scalar(at: offset - ((0xdc00...0xdfff).contains(last) ? 2 : 1), in: text)
    }
    private static func word(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        if scalar.value == 95 { return true }
        return switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }
    private static func isWholeWord(_ range: WorkspaceContentMatchRange, line: NSString) -> Bool {
        guard range.end > range.start else { return false }
        let left = range.start == 0 || !word(scalar(before: range.start, in: line)) || !word(scalar(at: range.start, in: line))
        let right = range.end == line.length || !word(scalar(at: range.end, in: line)) || !word(scalar(before: range.end, in: line))
        return left && right
    }
}
