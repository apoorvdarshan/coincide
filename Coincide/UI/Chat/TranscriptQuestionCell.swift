import AppKit
import CoincideKit

/// Questions an agent asks the user (Claude's AskUserQuestion, Codex's request_user_input…), as one
/// line of the work log. As in T3 Code they are answered in the question banner above the composer;
/// here the line says it is waiting, and once answered it lists the answers under the line.
final class TranscriptQuestionCell: TranscriptCell {
    private static let answerLineHeight: CGFloat = 20

    private let summary = TranscriptDisclosureHeader()
    private var answerLabels: [NSTextField] = []
    private var item: TranscriptItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(summary)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard let id = row.itemID, let item = host.item(id), let request = item.questions else { return }
        self.item = item
        let font = NSFont.systemFont(ofSize: Theme.fontSize - 1)
        let title = request.title?.nonBlank ?? request.questions.first?.prompt ?? String(localized: "Question")
        let (detail, status): (String?, TranscriptDisclosureHeader.Status) =
            switch (item.status, item.answers) {
            case (.waiting, _): (String(localized: "Waiting for your answer below"), .waiting)
            case (.declined, _): (String(localized: "Not answered"), .declined)
            case (_, nil): (String(localized: "Resolved by the agent"), .completed)
            default: (nil, .completed)
            }
        summary.configure(
            symbol: "questionmark.bubble", symbolColor: item.status == .waiting ? Theme.warning : .secondaryLabelColor,
            title: TranscriptText.inlineLabel(title, font: font, color: .secondaryLabelColor),
            detail: detail, status: status, isExpandable: false, isExpanded: false)

        let lines = Self.answerLines(request, answers: item.answers)
        while answerLabels.count < lines.count {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
            answerLabels.append(label)
        }
        for (index, label) in answerLabels.enumerated() {
            label.isHidden = index >= lines.count
            guard index < lines.count else { continue }
            let (question, answer) = lines[index]
            let text = NSMutableAttributedString(
                string: question + "  ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            text.append(NSAttributedString(string: answer, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            label.attributedStringValue = text
            label.toolTip = "\(question)\n\(answer)"
        }
        setAccessibilityLabel(([title, detail].compactMap { $0 } + lines.map { "\($0.0): \($0.1)" }).joined(separator: ", "))
        needsLayout = true
    }

    /// Each answered question's header (or prompt) and its answer. Secret answers are not stored.
    private static func answerLines(_ request: UserInputRequest, answers: [String: [String]]?) -> [(String, String)] {
        guard let answers else { return [] }
        return request.questions.compactMap { question in
            guard let values = answers[question.id], !values.isEmpty else { return nil }
            return (question.header?.nonBlank ?? question.prompt, values.joined(separator: ", "))
        }
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        guard let id = row.itemID, let item = host.item(id), let request = item.questions else { return 0 }
        let lines = CGFloat(answerLines(request, answers: item.answers).count)
        return TranscriptMetrics.workRowHeight + lines * answerLineHeight + bottomSpacing(for: row)
    }

    override var copyText: String? {
        guard let item, let request = item.questions else { return nil }
        return request.questions.map { question in
            let answer = item.answers?[question.id]?.joined(separator: ", ")
            return [question.prompt, answer].compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    override func layout() {
        super.layout()
        let column = TranscriptMetrics.column(width: bounds.width)
        summary.frame = NSRect(x: column.x, y: 0, width: column.width, height: TranscriptMetrics.workRowHeight)
        var y = TranscriptMetrics.workRowHeight
        for label in answerLabels where !label.isHidden {
            label.frame = NSRect(
                x: column.x + TranscriptMetrics.detailIndent, y: y + 1, width: column.width - TranscriptMetrics.detailIndent,
                height: 18)
            y += Self.answerLineHeight
        }
    }
}
