import AppKit
import CoincideKit

/// The branch list behind the branch toolbar: a search field over local and remote branches, and
/// "Create branch" from the search text. Arrow keys move, Return picks, Escape closes.
final class BranchPickerController: NSViewController, ThemedPopupContent, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    enum Mode {
        /// Check out the picked branch (or create one) in the thread's folder.
        case checkout
        /// Pick the branch a new worktree starts from.
        case base
    }

    enum Pick {
        case branch(GitBranch)
        case create(String)
    }

    private enum Row {
        case header(String)
        case branch(GitBranch)
        case create(String)
    }

    var onPick: ((Pick) -> Void)?
    var close: (() -> Void)?
    var onSizeChange: (() -> Void)?

    private let mode: Mode
    private let cwd: URL
    private let selectedName: String?
    private let searchField = NSSearchField()
    private let tableView = ThemedPopupTableView()
    private let footer = NSTextField(labelWithString: "")
    private var list: GitBranchList?
    private var rows: [Row] = []

    init(mode: Mode, cwd: URL, selected: String?) {
        self.mode = mode
        self.cwd = cwd
        selectedName = selected
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        let searchIcon = NSImageView(image: Theme.symbol("magnifyingglass", size: 12) ?? NSImage())
        searchIcon.contentTintColor = .secondaryLabelColor
        searchField.placeholderString =
            mode == .checkout ? String(localized: "Search or create a branch") : String(localized: "Search branches")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        searchField.setAccessibilityLabel(String(localized: "Branch name"))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 28
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(pickClicked)
        tableView.onActivate = { [weak self] in self.map { $0.pick($0.tableView.selectedRow) } }
        tableView.onMove = { [weak self] offset in self?.move(by: offset) }
        tableView.setAccessibilityLabel(String(localized: "Branches"))
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.stringValue = String(localized: "Loading branches…")

        let topDivider = ThemedDivider()
        let bottomDivider = ThemedDivider()
        for view in [searchIcon, searchField, topDivider, scroll, bottomDivider, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 340),
            searchIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            topDivider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeight,
            bottomDivider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),
            footer.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor, constant: 7),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root
        updateSize()
    }

    private lazy var listHeight = tableView.enclosingScrollView!.heightAnchor.constraint(equalToConstant: 0)

    /// Fits the list to its rows, up to ten, so a folder with one branch gets a small popup.
    private func updateSize() {
        let visibleRows = min(max(rows.count, 3), 10)
        listHeight.constant = CGFloat(visibleRows) * tableView.rowHeight + 12
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        onSizeChange?()
    }

    func popupDidOpen() {
        view.window?.makeFirstResponder(searchField)
        guard list == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                list = try await GitService.shared.branches(cwd)
                footer.stringValue =
                    mode == .checkout
                    ? String(localized: "Checking out changes the branch of the project folder.")
                    : String(localized: "The new worktree starts from this branch.")
            } catch {
                list = GitBranchList(isRepository: true)
                footer.stringValue = error.localizedDescription
            }
            rebuild()
        }
    }

    // MARK: Rows

    private func rebuild() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let sanitized = BranchNames.sanitizeNewRefName(query)
        let matches: (GitBranch) -> Bool = { branch in
            guard !query.isEmpty else { return true }
            let name = branch.name.lowercased()
            return name.contains(query) || (!sanitized.isEmpty && name.contains(sanitized))
        }
        let local = list?.local.filter(matches) ?? []
        let remote = list?.remote.filter(matches) ?? []
        rows = []
        if mode == .checkout, !query.isEmpty, !(list?.local.contains { $0.name.lowercased() == sanitized } ?? false) {
            rows.append(.create(BranchNames.sanitizeNewRefName(searchField.stringValue)))
        }
        if !local.isEmpty {
            rows.append(.header(String(localized: "Local")))
            rows += local.map(Row.branch)
        }
        if !remote.isEmpty {
            rows.append(.header(String(localized: "Remote")))
            rows += remote.map(Row.branch)
        }
        tableView.reloadData()
        updateSize()
        if !query.isEmpty, let first = rows.firstIndex(where: { if case .header = $0 { false } else { true } }) {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
        if list != nil, rows.isEmpty {
            footer.stringValue = String(localized: "No matching branches.")
        }
    }

    func controlTextDidChange(_ notification: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            pick(tableView.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            dismissPicker()
        default:
            return false
        }
        return true
    }

    private func move(by offset: Int) {
        var row = tableView.selectedRow
        repeat {
            row += offset
        } while rows.indices.contains(row) && { if case .header = rows[row] { true } else { false } }()
        guard rows.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func pickClicked() { pick(tableView.clickedRow) }

    private func pick(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        let pick: Pick
        switch rows[row] {
        case .header: return
        case .branch(let branch): pick = .branch(branch)
        case .create(let name):
            guard !name.isEmpty else { return }
            pick = .create(name)
        }
        dismissPicker()
        onPick?(pick)
    }

    private func dismissPicker() {
        if let close { close() } else { dismiss(nil) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .header = rows[row] { return ThemedTableRowView(isClickable: false) }
        return ThemedTableRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSView()
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        case .branch(let branch):
            let cell = tableView.makeView(withIdentifier: BranchCell.identifier, owner: nil) as? BranchCell ?? BranchCell()
            cell.configure(branch, isSelected: branch.name == selectedName || (selectedName == nil && branch.isCurrent))
            return cell
        case .create(let name):
            let cell = tableView.makeView(withIdentifier: BranchCell.identifier, owner: nil) as? BranchCell ?? BranchCell()
            cell.configureCreate(name)
            return cell
        }
    }
}

private final class BranchCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("branchCell")

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tagLabel.textColor = .tertiaryLabelColor
        tagLabel.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, nameLabel, NSView(), tagLabel])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ branch: GitBranch, isSelected: Bool) {
        icon.image = Theme.symbol(isSelected ? "checkmark" : branch.isRemote ? "globe" : "arrow.triangle.branch", size: 11)
        icon.contentTintColor = isSelected ? Theme.ink : .secondaryLabelColor
        nameLabel.stringValue = branch.name
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isSelected ? .semibold : .regular)
        var tags: [String] = []
        if branch.isDefault { tags.append(String(localized: "default")) }
        if branch.worktreePath != nil, !branch.isCurrent { tags.append(String(localized: "in a worktree")) }
        tagLabel.stringValue = tags.joined(separator: " · ")
        toolTip = branch.worktreePath.map { String(localized: "Checked out in \($0)") }
        setAccessibilityLabel([branch.name, isSelected ? String(localized: "current") : nil].compactMap { $0 }.joined(separator: ", ")
            + (tags.isEmpty ? "" : ", " + tags.joined(separator: ", ")))
    }

    func configureCreate(_ name: String) {
        icon.image = Theme.symbol("plus", size: 11, weight: .semibold)
        icon.contentTintColor = Theme.ink
        nameLabel.stringValue = String(localized: "Create branch “\(name)”")
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        tagLabel.stringValue = ""
        toolTip = nil
        setAccessibilityLabel(nameLabel.stringValue)
    }
}
