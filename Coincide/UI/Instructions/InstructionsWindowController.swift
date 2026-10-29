import AppKit
import CoincideKit
import SwiftUI

/// A window with one project's instruction files. Each project gets one window, brought forward when asked again.
final class InstructionsWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: InstructionsWindowController] = [:]

    let model: InstructionsModel

    /// The Instructions window in front, for debug automation.
    static var frontmost: InstructionsWindowController? {
        open.values.first { $0.window?.isKeyWindow == true } ?? open.values.first
    }

    static func show(project: Project) {
        if let existing = open[project.id] {
            existing.showWindow(nil)
            return
        }
        let controller = InstructionsWindowController(project: project)
        open[project.id] = controller
        controller.showWindow(nil)
    }

    private let projectID: UUID

    private init(project: Project) {
        projectID = project.id
        model = InstructionsModel(scope: .project(project.url), projectName: project.name)
        let hosting = NSHostingController(rootView: InstructionsView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Instructions — \(project.name)")
        window.identifier = NSUserInterfaceItemIdentifier("instructions")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.backgroundColor = Theme.contentBackground
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 460)
        window.setContentSize(NSSize(width: 980, height: 640))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Unsaved edits are offered for saving before the window closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty, let file = model.selected else { return true }
        let alert = ThemedAlert()
        alert.messageText = String(localized: "Save changes to \(file.displayName)?")
        alert.informativeText = String(localized: "Your changes are lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            return !model.isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[projectID] = nil
    }
}

extension MainWindowController {
    /// Opens the current project's instruction files.
    @objc func editInstructions(_ sender: Any?) {
        guard let id = currentProjectID, let project = AppStore.shared.project(id), !project.isChats, !project.isBots else {
            SettingsWindowController.shared.show(section: .instructions)
            return
        }
        InstructionsWindowController.show(project: project)
    }
}

/// The global instruction files, as a Settings page.
struct InstructionsSettingsView: View {
    @State private var model = InstructionsModel(scope: .global)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeader(title: String(localized: "Instructions")) {
                SettingsIconTile(symbol: "text.book.closed.fill", color: .teal, size: 44)
            } subtitle: {
                Text("The global instruction files every agent reads, in every project. Open a project's own with File › Edit Instructions.")
            }
            .padding(20)
            Rectangle().fill(Color(nsColor: Theme.surfaceBorder)).frame(height: 1)
            InstructionsView(model: model)
        }
    }
}
