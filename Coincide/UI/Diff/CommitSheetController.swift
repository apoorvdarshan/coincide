import AppKit
import CoincideKit

/// T3 Code's commit dialog: the branch, which changed files to include, and an optional message.
/// Left blank, the thread's agent writes the message.
final class CommitSheetController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Choice {
        var message: String
        /// Nil when every file is included.
        var paths: [String]?
        var onNewBranch: Bool
    }

    var onCommit: ((Choice) -> Void)?

    private let branch: String?
    private let isDefaultBranch: Bool
    private let files: [ChangedFile]
    private var excluded: Set<String> = []
    private let tableView = NSTableView()
    private let allCheckbox = ThemedCheckbox(label: String(localized: "Files"), target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "")
    private let totalsLabel = NSTextField(labelWithString: "")
    private let messageView = PlaceholderTextView()
    private let commitButton = ThemedButton(title: String(localized: "Commit"), style: .primary, target: nil, action: nil)
    private let newBranchButton = ThemedButton(title: String(localized: "Commit on New Branch"), target: nil, action: nil)

    init(branch: String?, isDefaultBranch: Bool, files: [ChangedFile]) {
        self.branch = branch
        self.isDefaultBranch = isDefaultBranch
        self.files = files
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Commit Changes")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Commit Changes"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString: String(
                localized: "Review and confirm your commit. Leave the message empty to have the agent write one."))
        subtitle.textColor = .secondaryLabelColor

        let branchName = NSTextField(labelWithString: branch ?? String(localized: "(detached HEAD)"))
        branchName.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        branchName.lineBreakMode = .byTruncatingMiddle
        let branchRow = NSStackView(views: [
            NSImageView(image: Theme.symbol("arrow.triangle.branch", size: 12) ?? NSImage()), branchName,
        ])
        branchRow.spacing = 6
        if isDefaultBranch {
            let warning = NSTextField(labelWithString: String(localized: "Default branch"))
            warning.textColor = .systemOrange
            warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            branchRow.addArrangedSubview(warning)
        }

        allCheckbox.target = self
        allCheckbox.action = #selector(toggleAll)
        allCheckbox.allowsMixedState = true
        selectionLabel.textColor = .secondaryLabelColor
        let filesHeader = NSStackView(views: [allCheckbox, selectionLabel, NSView(), totalsLabel])
        filesHeader.spacing = 6

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = 22
        tableView.rowSizeStyle = .custom
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(String(localized: "Files to commit"))
        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .lineBorder
        tableScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true

        let messageLabel = NSTextField(labelWithString: String(localized: "Message"))
        messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        messageView.placeholder = String(localized: "Leave empty to generate a message")
        messageView.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.textContainerInset = NSSize(width: 4, height: 6)
        messageView.isVerticallyResizable = true
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true
        messageView.setAccessibilityLabel(String(localized: "Commit message"))
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .lineBorder
        messageScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let cancel = ThemedButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        newBranchButton.target = self
        newBranchButton.action = #selector(commitOnNewBranch)
        newBranchButton.toolTip = String(localized: "Create a feature branch named after the change, then commit there.")
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitButton.toolTip = String(localized: "Commit (⌘↩)")
        let buttons = NSStackView(views: [NSView(), cancel, newBranchButton, commitButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [
            title, subtitle, branchRow, filesHeader, tableScroll, messageLabel, messageScroll, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(14, after: subtitle)
        stack.setCustomSpacing(14, after: branchRow)
        stack.setCustomSpacing(14, after: tableScroll)
        stack.setCustomSpacing(16, after: messageScroll)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [subtitle, filesHeader, tableScroll, messageScroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
        view = stack
        updateSelection()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(messageView)
    }

    private var selectedPaths: [String] { files.map(\.path).filter { !excluded.contains($0) } }

    private func updateSelection() {
        let selected = files.filter { !excluded.contains($0.path) }
        allCheckbox.state = excluded.isEmpty ? .on : selected.isEmpty ? .off : .mixed
        selectionLabel.stringValue =
            excluded.isEmpty
            ? String(localized: "\(files.count) changed")
            : String(localized: "\(selected.count) of \(files.count)")
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let totals = NSMutableAttributedString(
            string: "+\(selected.reduce(0) { $0 + $1.additions })",
            attributes: [.font: font, .foregroundColor: DiffColors.addition])
        totals.append(NSAttributedString(string: " "))
        totals.append(
            NSAttributedString(
                string: "−\(selected.reduce(0) { $0 + $1.deletions })",
                attributes: [.font: font, .foregroundColor: DiffColors.deletion]))
        totalsLabel.attributedStringValue = totals
        commitButton.isEnabled = !selected.isEmpty
        newBranchButton.isEnabled = !selected.isEmpty
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView(inset: 4)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let identifier = NSUserInterfaceItemIdentifier("commitFile")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CommitFileCell ?? CommitFileCell()
        cell.identifier = identifier
        cell.configure(file: file, included: !excluded.contains(file.path)) { [weak self] included in
            guard let self else { return }
            if included { self.excluded.remove(file.path) } else { self.excluded.insert(file.path) }
            self.updateSelection()
        }
        return cell
    }

    @objc private func toggleAll() {
        excluded = excluded.isEmpty ? Set(files.map(\.path)) : []
        tableView.reloadData()
        updateSelection()
    }

    // MARK: Actions

    private func finish(onNewBranch: Bool) {
        let choice = Choice(
            message: messageView.string, paths: excluded.isEmpty ? nil : selectedPaths, onNewBranch: onNewBranch)
        dismiss(nil)
        onCommit?(choice)
    }

    @objc private func commit() { finish(onNewBranch: false) }
    @objc private func commitOnNewBranch() { finish(onNewBranch: true) }
    @objc private func cancel() { dismiss(nil) }
}

private final class CommitFileCell: NSTableCellView {
    private let checkbox = ThemedCheckbox(label: "", target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private var onToggle: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.target = self
        checkbox.action = #selector(toggle)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countsLabel.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [checkbox, pathLabel, NSView(), countsLabel])
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(file: ChangedFile, included: Bool, onToggle: @escaping (Bool) -> Void) {
        checkbox.state = included ? .on : .off
        checkbox.setAccessibilityLabel(String(localized: "Include \(file.path)"))
        pathLabel.attributedStringValue = FileActions.attributedPath(
            file.path, oldPath: file.oldPath, size: NSFont.systemFontSize - 1)
        pathLabel.alphaValue = included ? 1 : 0.5
        countsLabel.attributedStringValue = DiffFileCell.counts(
            FileDiff(path: file.path, status: file.status, additions: file.additions, deletions: file.deletions))
        self.onToggle = onToggle
    }

    @objc private func toggle() {
        pathLabel.alphaValue = checkbox.state == .on ? 1 : 0.5
        onToggle?(checkbox.state == .on)
    }
}

/// A plain text view that shows a hint while empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(
            at: origin,
            withAttributes: [.font: font ?? .systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
