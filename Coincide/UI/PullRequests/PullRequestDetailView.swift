import AppKit
import CoincideKit

/// One pull request, after T3 Code's summary tab: its title, state and branches, review and checks at a glance, the
/// actions (merge, mark ready for review, check out in a new thread), every check, and the description as Markdown.
/// The summary from the list shows at once; checks and the description follow when the detail loads.
final class PullRequestDetailView: NSView {
    /// Asked to merge, with the button to anchor the method menu to.
    var onMerge: ((NSView) -> Void)?
    var onMarkReady: (() -> Void)?
    var onCheckOut: (() -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let titleLabel = WrappingLabel(font: .systemFont(ofSize: 15, weight: .semibold))
    private let stateIcon = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let reviewIcon = NSImageView()
    private let reviewLabel = NSTextField(labelWithString: "")
    private let checksIcon = NSImageView()
    private let checksLabel = NSTextField(labelWithString: "")
    private let conflictIcon = NSImageView()
    private let conflictLabel = NSTextField(labelWithString: "")
    private lazy var reviewLine = line(reviewIcon, reviewLabel)
    private lazy var checksLine = line(checksIcon, checksLabel)
    private lazy var conflictLine = line(conflictIcon, conflictLabel)
    private let actions = FlowingButtonRow()
    private let mergeButton = ThemedButton(title: String(localized: "Merge…"), style: .primary, target: nil, action: nil)
    private let readyButton = ThemedButton(
        title: String(localized: "Mark Ready for Review"), style: .primary, target: nil, action: nil)
    private let checkOutButton = ThemedButton(
        title: String(localized: "Check Out in New Thread"), style: .secondary, target: nil, action: nil)
    private let checksHeader = NSTextField(labelWithString: "")
    private let checksList = NSStackView()
    private let checksNote = NSTextField(labelWithString: "")
    private let descriptionHeader = NSTextField(labelWithString: String(localized: "Description"))
    private let markdown = PullRequestMarkdownView(frame: .zero)
    private let descriptionNote = NSTextField(labelWithString: "")

    /// The pull request shown, so a refresh of the same one keeps the scroll position.
    private var shownNumber: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        titleLabel.textColor = Theme.ink
        for label in [stateLabel, reviewLabel, checksLabel, conflictLabel] {
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        }
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.isSelectable = true
        branchLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        statsLabel.textColor = .secondaryLabelColor
        conflictLabel.textColor = Theme.warning

        mergeButton.target = self
        mergeButton.action = #selector(merge(_:))
        readyButton.target = self
        readyButton.action = #selector(markReady(_:))
        checkOutButton.target = self
        checkOutButton.action = #selector(checkOut(_:))
        checkOutButton.toolTip = String(localized: "Creates a worktree on this pull request’s branch and opens a new thread in it")
        actions.buttons = [mergeButton, readyButton, checkOutButton]

        for header in [checksHeader, descriptionHeader] {
            header.textColor = .secondaryLabelColor
            header.setAccessibilityRole(.staticText)
        }
        checksList.orientation = .vertical
        checksList.alignment = .leading
        checksList.spacing = 0
        for note in [checksNote, descriptionNote] { note.textColor = .tertiaryLabelColor }

        let stateLine = line(stateIcon, stateLabel)
        let checksDivider = ThemedDivider(frame: .zero)
        let descriptionDivider = ThemedDivider(frame: .zero)
        stack.setViews(
            [
                titleLabel, stateLine, branchLabel, statsLabel, reviewLine, checksLine, conflictLine, actions,
                checksDivider, checksHeader, checksList, checksNote, descriptionDivider, descriptionHeader, markdown,
                descriptionNote,
            ], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(10, after: conflictLine)
        stack.setCustomSpacing(16, after: actions)
        stack.setCustomSpacing(14, after: checksDivider)
        stack.setCustomSpacing(16, after: checksList)
        stack.setCustomSpacing(16, after: checksNote)
        stack.setCustomSpacing(14, after: descriptionDivider)
        stack.setCustomSpacing(8, after: descriptionHeader)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Rows that span the column; the rest keep their own width.
        let fullWidth: [NSView] = [
            titleLabel, stateLine, branchLabel, reviewLine, checksLine, conflictLine, actions, checksDivider, checksList,
            descriptionDivider, markdown,
        ]

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        let clip = scrollView.contentView
        NSLayoutConstraint.activate(
            [
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                document.topAnchor.constraint(equalTo: clip.topAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -84),
                checksDivider.heightAnchor.constraint(equalToConstant: 1),
                descriptionDivider.heightAnchor.constraint(equalToConstant: 1),
                stateIcon.widthAnchor.constraint(equalToConstant: 16),
                reviewIcon.widthAnchor.constraint(equalToConstant: 16),
                checksIcon.widthAnchor.constraint(equalToConstant: 16),
                conflictIcon.widthAnchor.constraint(equalToConstant: 16),
            ] + fullWidth.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    /// An icon before a line of text.
    private func line(_ icon: NSImageView, _ label: NSTextField) -> NSStackView {
        let line = NSStackView(views: [icon, label])
        line.spacing = 6
        line.alignment = .centerY
        line.detachesHiddenViews = true
        return line
    }

    // MARK: Showing

    /// The text size setting applies on each showing, so a change to it shows the next time the view updates.
    private func applyFonts() {
        let size = Theme.fontSize
        titleLabel.font = .systemFont(ofSize: size + 2, weight: .semibold)
        for label in [stateLabel, reviewLabel, checksLabel, conflictLabel, checksNote, descriptionNote] {
            label.font = .systemFont(ofSize: size - 1)
        }
        branchLabel.font = .monospacedSystemFont(ofSize: size - 2, weight: .regular)
        statsLabel.font = .monospacedDigitSystemFont(ofSize: size - 2, weight: .regular)
        for header in [checksHeader, descriptionHeader] { header.font = .systemFont(ofSize: size - 2, weight: .semibold) }
    }

    /// Shows `summary`, and once it has loaded, `detail`. While `isBusy` an action runs and the buttons wait.
    func show(_ summary: PullRequestSummary, detail: PullRequestDetail?, isBusy: Bool) {
        applyFonts()
        if shownNumber != summary.number {
            shownNumber = summary.number
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let summary = detail?.summary ?? summary
        titleLabel.stringValue = summary.title

        let state = PullRequestGlyph.state(summary.state, isDraft: summary.isDraft)
        stateIcon.image = state.image()
        stateIcon.contentTintColor = state.color
        let byline =
            summary.author.map { String(localized: "#\(summary.number) by \($0)") } ?? "#\(summary.number)"
        stateLabel.stringValue = "\(state.label) · \(byline)"
        branchLabel.stringValue = "\(summary.headBranch) → \(summary.baseBranch)"
        branchLabel.setAccessibilityLabel(String(localized: "From \(summary.headBranch) into \(summary.baseBranch)"))
        branchLabel.toolTip = branchLabel.accessibilityLabel()

        if let detail, let additions = detail.additions, let deletions = detail.deletions {
            var parts = ["+\(additions)", "−\(deletions)"]
            if let files = detail.changedFiles { parts.append(String(localized: "\(files) files")) }
            statsLabel.stringValue = parts.joined(separator: "  ")
            statsLabel.isHidden = false
        } else {
            statsLabel.isHidden = true
        }

        let review = summary.reviewDecision.map(PullRequestGlyph.review)
        reviewIcon.image = review?.image()
        reviewIcon.contentTintColor = review?.color
        reviewLabel.stringValue = review?.label ?? ""
        reviewLine.isHidden = review == nil

        let checks = summary.checksState.map(PullRequestGlyph.checks)
        checksIcon.image = checks?.image()
        checksIcon.contentTintColor = checks?.color
        checksLabel.stringValue = checks?.label ?? ""
        checksLine.isHidden = checks == nil

        let conflicting = detail?.mergeability == .conflicting && summary.state == .open
        conflictIcon.image = Theme.symbol("exclamationmark.triangle", size: 12, weight: .medium)
        conflictIcon.contentTintColor = Theme.warning
        conflictLabel.stringValue = String(localized: "Conflicts with \(summary.baseBranch)")
        conflictLine.isHidden = !conflicting

        let isOpen = summary.state == .open
        mergeButton.isHidden = !isOpen || summary.isDraft
        readyButton.isHidden = !isOpen || !summary.isDraft
        checkOutButton.isHidden = !isOpen
        actions.isHidden = !isOpen
        for button in [mergeButton, readyButton, checkOutButton] { button.isEnabled = !isBusy }
        actions.buttonsChanged()

        showChecks(detail?.checks)
        showDescription(detail?.body)
    }

    private func showChecks(_ checks: [PullRequestCheck]?) {
        checksList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let count = checks?.count ?? 0
        checksHeader.stringValue = count > 0 ? String(localized: "Checks (\(count))") : String(localized: "Checks")
        guard let checks else {
            checksNote.stringValue = String(localized: "Loading…")
            checksNote.isHidden = false
            checksList.isHidden = true
            return
        }
        checksNote.stringValue = String(localized: "No checks ran on this pull request.")
        checksNote.isHidden = !checks.isEmpty
        checksList.isHidden = checks.isEmpty
        for check in checks {
            let row = PullRequestCheckRow(check)
            checksList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: checksList.widthAnchor).isActive = true
        }
    }

    private func showDescription(_ body: String?) {
        guard let body else {
            markdown.isHidden = true
            descriptionNote.stringValue = String(localized: "Loading…")
            descriptionNote.isHidden = false
            return
        }
        let text = PullRequestBody.displayMarkdown(body)
        markdown.setMarkdown(text)
        markdown.isHidden = text.isEmpty
        descriptionNote.stringValue = String(localized: "No description provided.")
        descriptionNote.isHidden = !text.isEmpty
    }

    // MARK: Actions

    @objc private func merge(_ sender: NSButton) { onMerge?(sender) }

    @objc private func markReady(_ sender: Any?) { onMarkReady?() }

    @objc private func checkOut(_ sender: Any?) { onCheckOut?() }
}

/// The scrolling content, laid out from the top.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
