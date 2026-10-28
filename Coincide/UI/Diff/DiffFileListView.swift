import AppKit
import CoincideKit

/// The changed files of the diff: status, path and line counts. Selecting one scrolls the diff to it.
final class DiffFileListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelect: ((Int) -> Void)?
    var rootURL: URL?

    private let scrollView = NSScrollView()
    private let tableView = ThemedMenuTableView()
    private var files: [FileDiff] = []
    private var isSyncingSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedFile)
        tableView.setAccessibilityLabel(String(localized: "Changed files"))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ files: [FileDiff]) {
        let selectedPath = selectedIndex.map { self.files[$0].path }
        self.files = files
        tableView.reloadData()
        if let selectedPath, let index = files.firstIndex(where: { $0.path == selectedPath }) {
            select(index)
        }
    }

    private var selectedIndex: Int? {
        let row = tableView.selectedRow
        return files.indices.contains(row) ? row : nil
    }

    /// Selects a file without telling `onSelect`, to follow the diff as it scrolls.
    func select(_ index: Int) {
        guard files.indices.contains(index), tableView.selectedRow != index else { return }
        isSyncingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        isSyncingSelection = false
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView(inset: 4)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("fileCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffFileCell ?? DiffFileCell()
        cell.identifier = identifier
        cell.configure(files[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let index = selectedIndex else { return }
        onSelect?(index)
    }

    @objc private func openClickedFile() {
        let row = tableView.clickedRow
        guard files.indices.contains(row), files[row].status != .deleted,
            let url = FileActions.url(files[row].path, root: rootURL)
        else { return }
        SafeLinks.openFile(url, inside: rootURL, from: window)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard files.indices.contains(row) else { return }
        FileActions.addItems(to: menu, path: files[row].path, root: rootURL, deleted: files[row].status == .deleted)
    }
}

/// Status badge, file name with its folder, and +/- counts.
final class DiffFileCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.alignment = .center
        badge.font = .monospacedSystemFont(ofSize: max(9, Theme.fontSize - 3), weight: .bold)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countsLabel.setContentHuggingPriority(.required, for: .horizontal)
        for view in [badge, pathLabel, countsLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 16),
            badge.heightAnchor.constraint(equalToConstant: 16),
            pathLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 8),
            countsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ file: FileDiff) {
        let status = DiffColors.status(file.status)
        badge.stringValue = status.letter
        badge.textColor = status.color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = status.color.withAlphaComponent(0.16).cgColor
        }
        pathLabel.attributedStringValue = FileActions.attributedPath(file.path, oldPath: file.oldPath, size: Theme.fontSize - 1)
        countsLabel.attributedStringValue = Self.counts(file)
        toolTip = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        setAccessibilityLabel(
            String(
                localized:
                    "\(file.path), \(DiffColors.statusName(file.status)), \(file.additions) added, \(file.deletions) removed"
            ))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = badge.textColor?.withAlphaComponent(0.16).cgColor
        }
    }

    static func counts(_ file: FileDiff) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .medium)
        guard !file.isBinary else {
            return NSAttributedString(
                string: String(localized: "Binary"), attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let text = NSMutableAttributedString(
            string: "+\(file.additions)", attributes: [.font: font, .foregroundColor: DiffColors.addition])
        text.append(NSAttributedString(string: " "))
        text.append(
            NSAttributedString(string: "−\(file.deletions)", attributes: [.font: font, .foregroundColor: DiffColors.deletion]))
        return text
    }
}
