import AppKit
import CoincideKit

/// The toolbar's project scripts (T3 Code's header control): the script run last as a button, beside a menu of every
/// script and ways to add, edit or import them. Without scripts it is a single button offering to add one. Its
/// toolbar item is hidden while no thread is open (`onVisibilityChange`): a toolbar does not lay out again for a
/// hidden view, so the item itself is what hides.
final class ProjectScriptsControl: NSView {
    var threadID: UUID? {
        didSet { refresh() }
    }

    /// Whether a thread with a project is open, so the control has something to show.
    private(set) var isAvailable = false
    var onVisibilityChange: ((Bool) -> Void)?

    private let runButton = ComposerControlButton()
    private let menuButton = ComposerControlButton()
    private let stack = NSStackView()
    private var observation: ObservationToken?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        runButton.target = self
        runButton.action = #selector(runPrimary)
        // In a narrow window the script's name truncates once the thread title has given way (its labels resist at
        // priority 1), so the run status and the right panels' buttons keep their places rather than going to the
        // toolbar's overflow menu.
        runButton.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        runButton.cell?.lineBreakMode = .byTruncatingTail
        runButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        menuButton.menuProvider = { [weak self] in self?.makeMenu() }
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        stack.addArrangedSubview(runButton)
        stack.addArrangedSubview(menuButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        observation = AppStore.shared.observe { [weak self] change in
            if change == .projects { self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(scriptsChanged), name: ProjectScripts.didChangeNotification, object: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Project scripts"))
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.raisedFill.cgColor
        layer?.borderColor = Theme.surfaceBorder.cgColor
        layer?.borderWidth = 1
    }

    @objc private func scriptsChanged() {
        refresh()
    }

    private var project: Project? { ProjectScripts.shared.project(ofThread: threadID) }

    private func refresh() {
        let available = project != nil
        if available != isAvailable {
            isAvailable = available
            onVisibilityChange?(available)
        }
        guard let project else { return }
        if let primary = ProjectScripts.shared.primaryScript(in: project) {
            runButton.isHidden = false
            runButton.configure(title: primary.name, symbolName: primary.icon.symbolName, chevron: false)
            runButton.toolTip = String(localized: "Run \(primary.name): \(primary.command)")
            runButton.setAccessibilityLabel(String(localized: "Run \(primary.name)"))
            menuButton.configure(title: "", symbolName: "", chevron: true)
            menuButton.toolTip = String(localized: "Project scripts")
        } else {
            runButton.isHidden = true
            menuButton.configure(title: "", symbolName: "play.rectangle", chevron: true)
            menuButton.toolTip = String(localized: "Add a project script, such as your dev server or tests")
        }
        menuButton.setAccessibilityLabel(String(localized: "Project scripts"))
        invalidateIntrinsicContentSize()
    }

    @objc private func runPrimary() {
        guard let threadID, let project, let primary = ProjectScripts.shared.primaryScript(in: project) else { return }
        ProjectScripts.shared.run(primary, threadID: threadID)
    }

    private func makeMenu() -> NSMenu? {
        guard let project else { return nil }
        let menu = NSMenu()
        for script in project.scripts {
            let item = ActionMenuItem.make(String(localized: "Run \(script.name)")) { [weak self] in
                guard let threadID = self?.threadID else { return }
                ProjectScripts.shared.run(script, threadID: threadID)
            }
            item.image = Theme.symbol(script.icon.symbolName, size: 12)
            item.subtitle = script.command
            menu.addItem(item)
        }
        if !project.scripts.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ActionMenuItem.make(String(localized: "Add Script…")) { [weak self] in self?.edit(nil, in: project.id) })
        if !project.scripts.isEmpty {
            let edit = NSMenuItem(title: String(localized: "Edit Script"), action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: edit.title)
            for script in project.scripts {
                submenu.addItem(ActionMenuItem.make(script.name) { [weak self] in self?.edit(script, in: project.id) })
            }
            edit.submenu = submenu
            menu.addItem(edit)
        }
        let importable = ProjectScripts.shared.importableT3Scripts(for: project)
        if !importable.isEmpty {
            menu.addItem(
                ActionMenuItem.make(String(localized: "Import \(importable.count) Scripts from t3.json")) {
                    ProjectScripts.shared.importT3Scripts(into: project)
                })
        }
        return menu
    }

    private func edit(_ script: ProjectScript?, in projectID: UUID) {
        guard let host = window?.contentViewController else { return }
        let editor = ProjectScriptEditor(script: script)
        editor.onSave = { ProjectScripts.shared.save($0, in: projectID) }
        editor.onDelete = { ProjectScripts.shared.delete($0, from: projectID) }
        host.presentAsSheet(editor)
    }
}

/// A menu item that runs a closure; the item keeps the closure alive.
enum ActionMenuItem {
    static func make(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(PickerChoice.choose(_:)), keyEquivalent: "")
        let choice = PickerChoice(run)
        item.target = choice
        item.representedObject = choice
        return item
    }
}
