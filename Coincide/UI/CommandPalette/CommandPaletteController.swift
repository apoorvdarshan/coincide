import AppKit
import CoincideKit

/// The Command-K palette, ported from T3's CommandPalette: a glass panel attached above the main
/// window with fuzzy search across actions, threads, projects and settings, driven from the keyboard.
final class CommandPaletteController {
    static let shared = CommandPaletteController()

    private var panel: PalettePanel?
    private let content = PaletteViewController()
    private var isDismissing = false
    private static let width: CGFloat = 640

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the palette over `window`, or hides it when it is already showing.
    func show(in window: NSWindow?) {
        if isVisible {
            dismiss()
            return
        }
        let parent = window ?? NSApp.mainWindow
        let panel = self.panel ?? makePanel()
        self.panel = panel
        content.windowController = parent?.windowController as? MainWindowController
        content.reset()
        place(panel, over: parent, height: content.preferredHeight)
        parent?.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        content.focusSearchField()
    }

    /// Hides the palette and gives focus back to the window underneath.
    func dismiss() {
        guard let panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Only hand focus back while Coincide is in front; never pull the window forward.
        if NSApp.isActive { parent?.makeKey() }
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel()
        let glass = FlatSurfaceView(style: .floating)
        glass.cornerRadius = 18
        glass.contentView = content.view
        panel.contentView = glass
        panel.onCancel = { [weak self] in self?.content.cancel() }
        panel.onResignKey = { [weak self] in self?.dismiss() }
        content.onRun = { [weak self] action in
            self?.dismiss()
            action()
        }
        content.onHeightChange = { [weak self] height in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            var frame = panel.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        return panel
    }

    private func place(_ panel: NSPanel, over parent: NSWindow?, height: CGFloat) {
        let bounds = parent?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(Self.width, bounds.width - 48)
        // About a sixth of the way down, like T3's dialog.
        let top = bounds.maxY - max(64, bounds.height * 0.16)
        var frame = NSRect(x: bounds.midX - width / 2, y: top - height, width: width, height: height)
        // Keep the palette on the parent's screen, even when the window hangs off it or spans two displays.
        if let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        panel.setFrame(frame, display: false)
        panel.invalidateShadow()
    }
}

/// A borderless panel that can take keyboard focus and closes on Escape or when it loses focus.
/// It stays at the normal window level: as a child window it rides above its parent only, so it
/// never covers other apps.
final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isExcludedFromWindowsMenu = true
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        animationBehavior = .utilityWindow
        title = String(localized: "Command Palette")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// The palette's search field, results and footer.
final class PaletteViewController: NSViewController {
    private enum Row {
        case header(String)
        case item(PaletteItem, ranges: [NSRange])
    }

    weak var windowController: MainWindowController?
    /// Runs an item's action once the palette has closed.
    var onRun: ((@escaping () -> Void) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    private let searchIcon = NSImageView()
    private let backButton = NSButton()
    private let breadcrumb = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let table = PaletteTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint!
    private var menus: [(menu: PaletteMenu, parentQuery: String)] = []
    private var rows: [Row] = []
    /// What the palette lists, built once per opening; typing only re-ranks it.
    private var contents: PaletteContents?

    private static let searchHeight: CGFloat = 52
    private static let footerHeight: CGFloat = 30
    private static let maxListHeight: CGFloat = 440
    private static let emptyListHeight: CGFloat = 76

    private(set) var preferredHeight: CGFloat = 0

    override func loadView() {
        let root = NSView()
        searchIcon.image = Theme.symbol("magnifyingglass", size: 17, weight: .medium)
        searchIcon.contentTintColor = .secondaryLabelColor
        backButton.image = Theme.symbol("chevron.left", size: 13, weight: .semibold)
        backButton.isBordered = false
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.toolTip = String(localized: "Back (⌫)")
        backButton.setAccessibilityLabel(String(localized: "Back"))
        breadcrumb.font = .systemFont(ofSize: 15, weight: .semibold)
        breadcrumb.textColor = .secondaryLabelColor
        breadcrumb.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel(String(localized: "Search commands, projects, and threads"))
        let searchRow = NSStackView(views: [searchIcon, backButton, breadcrumb, field])
        searchRow.spacing = 8
        searchRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.onHover = { [weak self] row in self?.select(row) }
        table.setAccessibilityLabel(String(localized: "Results"))
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        let footerArea = NSLayoutGuide()
        root.addLayoutGuide(footerArea)
        for view: NSView in [searchRow, topSeparator, scrollView, emptyLabel, bottomSeparator, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        listHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.emptyListHeight)
        NSLayoutConstraint.activate([
            searchRow.topAnchor.constraint(equalTo: root.topAnchor),
            searchRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: Self.searchHeight),
            topSeparator.topAnchor.constraint(equalTo: searchRow.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeight,
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bottomSeparator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerArea.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor),
            footerArea.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footerArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.centerYAnchor.constraint(equalTo: footerArea.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
        ])
        view = root
    }

    // MARK: State

    func reset() {
        loadViewIfNeeded()
        contents = PaletteContents(catalog: PaletteCatalog(windowController: windowController))
        menus = []
        field.stringValue = ""
        refresh()
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(field)
    }

    /// Escape: leaves a nested list, else closes the palette.
    func cancel() {
        if menus.isEmpty {
            CommandPaletteController.shared.dismiss()
        } else {
            goBack()
        }
    }

    @objc private func goBack() {
        guard let previous = menus.popLast() else { return }
        focusSearchField()
        setQuery(previous.parentQuery)
    }

    private func refresh() {
        guard let contents else { return }
        let query = field.stringValue
        rangesByID = [:]
        let groups: [PaletteGroup]
        if let menu = menus.last?.menu {
            groups = filter(menu.groups(), query: PaletteSearch.Query(query), limitSecondary: false)
        } else if PaletteCatalog.isPathQuery(query) {
            groups = contents.catalog.folderItems(for: query)
        } else {
            let actionsOnly = query.hasPrefix(">")
            let search = PaletteSearch.Query(actionsOnly ? String(query.dropFirst()) : query)
            let (core, more) = contents.actions
            let actions = PaletteGroup(id: "actions", title: String(localized: "Actions"), items: core + more)
            if search.isEmpty && actionsOnly {
                groups = [actions]
            } else if search.isEmpty {
                // Recent threads sit right under the everyday actions, as in T3; the rest follow.
                groups = [
                    PaletteGroup(id: "actions", title: String(localized: "Actions"), items: core),
                    PaletteGroup(id: "recent", title: String(localized: "Recent Threads"), items: contents.recentThreads),
                    PaletteGroup(id: "more", title: String(localized: "More Actions"), items: more),
                ]
            } else {
                var candidates = [actions]
                if !actionsOnly {
                    candidates += [
                        PaletteGroup(id: "threads", title: String(localized: "Threads"), items: contents.threads),
                        PaletteGroup(id: "projects", title: String(localized: "Projects"), items: contents.projects),
                        PaletteGroup(id: "settings", title: String(localized: "Settings"), items: contents.settings),
                    ]
                }
                groups = filter(candidates, query: search, limitSecondary: !actionsOnly)
            }
        }
        rows = groups.filter { !$0.items.isEmpty }.flatMap { group in
            [Row.header(group.title)] + group.items.map { Row.item($0, ranges: rangesByID[$0.id] ?? []) }
        }
        updateChrome()
        table.reloadData()
        if let first = rows.indices.first(where: isSelectable) { select(first) }
        resize()
    }

    /// Match ranges of the ranked items, for bold highlighting.
    private var rangesByID: [String: [NSRange]] = [:]

    /// Ranks every group's items for the query, keeping the groups and items that match.
    private func filter(_ groups: [PaletteGroup], query: PaletteSearch.Query, limitSecondary: Bool) -> [PaletteGroup] {
        guard !query.isEmpty else { return groups }
        let ranked = PaletteSearch.rank(groups.map { (group: $0, items: $0.items) }) { item, typos in
            item.score(query, typos: typos)
        }
        let threadsMatch = ranked.contains { $0.group.id == "threads" }
        return ranked.map { entry in
            // Next to matching threads, other groups show only their best few, as in T3.
            let limit =
                entry.group.id == "threads"
                ? PaletteCatalog.threadLimit : (limitSecondary && threadsMatch ? PaletteCatalog.secondaryLimit : .max)
            let ordered = entry.items.filter { !$0.item.isSecondary } + entry.items.filter { $0.item.isSecondary }
            var group = entry.group
            group.items = ordered.prefix(limit).map { ranked in
                rangesByID[ranked.item.id] = ranked.match.ranges
                return ranked.item
            }
            return group
        }
    }

    /// Replaces the query, keeping the caret at its end while the field is being edited.
    private func setQuery(_ text: String) {
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        } else {
            field.stringValue = text
        }
        refresh()
    }

    private func updateChrome() {
        let menu = menus.last?.menu
        searchIcon.isHidden = menu != nil
        backButton.isHidden = menu == nil
        breadcrumb.isHidden = menu == nil
        breadcrumb.stringValue = menu?.title ?? ""
        field.placeholderString =
            menu?.placeholder
            ?? (PaletteCatalog.isPathQuery(field.stringValue)
                ? String(localized: "Enter a folder path, e.g. ~/projects/my-app")
                : String(localized: "Search commands, projects, and threads…"))
        var hints = [String(localized: "↑↓ Navigate"), String(localized: "↩ Open")]
        if PaletteCatalog.isPathQuery(field.stringValue) && menu == nil {
            hints = [String(localized: "↑↓ Navigate"), String(localized: "⇥ Complete"), String(localized: "↩ Add Project")]
        }
        if menu != nil { hints.append(String(localized: "⌫ Back")) }
        hints.append(menu == nil ? String(localized: "⎋ Close") : String(localized: "⎋ Back"))
        footer.stringValue = hints.joined(separator: "    ")
        emptyLabel.stringValue =
            field.stringValue.hasPrefix(">")
            ? String(localized: "No matching actions.") : String(localized: "No matching commands, projects, or threads.")
        if PaletteCatalog.isPathQuery(field.stringValue) && menu == nil {
            emptyLabel.stringValue = String(localized: "No folders match this path.")
        }
    }

    private func resize() {
        let content = rows.indices.reduce(CGFloat(0)) { $0 + height(ofRow: $1) } + 8
        let list = rows.isEmpty ? Self.emptyListHeight : min(Self.maxListHeight, content)
        emptyLabel.isHidden = !rows.isEmpty
        listHeight.constant = list
        preferredHeight = Self.searchHeight + 1 + list + 1 + Self.footerHeight
        onHeightChange?(preferredHeight)
    }

    // MARK: Selection

    private func isSelectable(_ row: Int) -> Bool {
        guard rows.indices.contains(row), case .item = rows[row] else { return false }
        return true
    }

    private func select(_ row: Int) {
        guard isSelectable(row), table.selectedRow != row else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        // Keep the group title above the first result visible.
        if row > 0, !isSelectable(row - 1) { table.scrollRowToVisible(row - 1) }
    }

    private func move(by steps: Int) {
        var row = table.selectedRow
        var remaining = abs(steps)
        let direction = steps > 0 ? 1 : -1
        var candidate = row + direction
        while remaining > 0, rows.indices.contains(candidate) {
            if isSelectable(candidate) {
                row = candidate
                remaining -= 1
            }
            candidate += direction
        }
        select(row)
    }

    private func execute(_ row: Int) {
        guard rows.indices.contains(row), case .item(let item, _) = rows[row] else { return }
        switch item.behavior {
        case .submenu(let menu):
            menus.append((menu, field.stringValue))
            setQuery("")
        case .run(let action):
            onRun?(action)
        }
    }

    @objc private func rowClicked() {
        execute(table.clickedRow)
    }

    private func height(ofRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: row == 0 ? 24 : 30
        case .item(let item, _): (item.subtitle ?? "").isEmpty ? 32 : 42
        }
    }
}

/// The palette's lists for one opening, built when first needed.
private final class PaletteContents {
    let catalog: PaletteCatalog
    lazy var actions = catalog.actions()
    lazy var recentThreads = catalog.recentThreads()
    lazy var threads = catalog.allThreads()
    lazy var projects = catalog.projects()
    lazy var settings = catalog.settings()

    init(catalog: PaletteCatalog) {
        self.catalog = catalog
    }
}

// MARK: - Table

extension PaletteViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(ofRow: row) }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isSelectable(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteHeaderCell ?? PaletteHeaderCell(frame: .zero)
            cell.identifier = id
            cell.configure(title)
            return cell
        case .item(let item, let ranges):
            let id = NSUserInterfaceItemIdentifier("item")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteItemCell ?? PaletteItemCell(frame: .zero)
            cell.identifier = id
            cell.configure(item, ranges: ranges)
            return cell
        }
    }
}

// MARK: - Search field

extension PaletteViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            move(by: 8)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            move(by: -8)
        case #selector(NSResponder.insertNewline(_:)):
            execute(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
        case #selector(NSResponder.insertTab(_:)):
            guard table.selectedRow >= 0, case .item(let item, _) = rows[table.selectedRow], let completion = item.completion
            else { return true }
            setQuery(completion)
        case #selector(NSResponder.deleteBackward(_:)):
            // Backspace in an empty nested list goes back, as in T3.
            guard field.stringValue.isEmpty, !menus.isEmpty else { return false }
            goBack()
        default:
            return false
        }
        return true
    }
}
