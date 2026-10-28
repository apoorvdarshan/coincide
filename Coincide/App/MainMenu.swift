import AppKit
import CoincideKit

/// Builds the menu bar in code and fills its project and "Open In" submenus when they open.
/// Coincide commands target the main window controller; standard ones travel the responder chain.
/// Commands the user can rebind (`KeyCommand`) get their shortcuts from `KeyBindingsController`.
final class MainMenu: NSObject, NSMenuDelegate {
    private weak var windowController: MainWindowController?
    private let newThreadInMenu = NSMenu(title: String(localized: "New Thread in Project"))
    private let openInMenu = NSMenu(title: String(localized: "Open In"))

    init(windowController: MainWindowController) {
        self.windowController = windowController
        super.init()
        newThreadInMenu.delegate = self
        openInMenu.delegate = self
    }

    func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(appDelegate)))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(threadMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Help"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        KeyBindingsController.shared.attach(to: main)
        return main
    }

    // MARK: Menus

    private func appMenu(_ appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Coincide")
        menu.addItem(
            standard(String(localized: "About Coincide"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let settings = item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ",")
        settings.target = appDelegate
        menu.addItem(settings)
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        menu.addItem(standard(String(localized: "Hide Coincide"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(
            standard(
                String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(standard(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(standard(String(localized: "Quit Coincide"), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(item(String(localized: "New Thread"), #selector(MainWindowController.newThread(_:)), .newThread))
        let newIn = NSMenuItem(title: newThreadInMenu.title, action: nil, keyEquivalent: "")
        newIn.submenu = newThreadInMenu
        menu.addItem(newIn)
        menu.addItem(item(String(localized: "Add Project…"), #selector(MainWindowController.addProject(_:)), .addProject))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Open in Editor"), #selector(MainWindowController.openInPreferred(_:)), .openInEditor))
        let openIn = NSMenuItem(title: openInMenu.title, action: nil, keyEquivalent: "")
        openIn.submenu = openInMenu
        menu.addItem(openIn)
        menu.addItem(item(String(localized: "Reveal in Finder"), #selector(MainWindowController.revealInFinder(_:)), .revealInFinder))
        menu.addItem(.separator())
        menu.addItem(standard(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(standard(String(localized: "Undo"), Selector(("undo:")), "z"))
        menu.addItem(standard(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(standard(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        menu.addItem(standard(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(standard(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(
            standard(
                String(localized: "Paste and Match Style"), #selector(NSTextView.pasteAsPlainText(_:)), "v",
                [.command, .option, .shift]))
        menu.addItem(standard(String(localized: "Delete"), #selector(NSText.delete(_:))))
        menu.addItem(standard(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenu(title: String(localized: "Find"))
        let finder = #selector(NSResponder.performTextFinderAction(_:))
        find.addItem(standard(String(localized: "Find…"), finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        find.addItem(standard(String(localized: "Find Next"), finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        find.addItem(
            standard(
                String(localized: "Find Previous"), finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue))
        find.addItem(
            standard(
                String(localized: "Use Selection for Find"), finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        find.addItem(.separator())
        find.addItem(item(String(localized: "Search Threads"), #selector(MainWindowController.searchThreads(_:)), .searchThreads))
        menu.addItem(submenu(find))

        let spelling = NSMenu(title: String(localized: "Spelling and Grammar"))
        spelling.addItem(
            standard(String(localized: "Show Spelling and Grammar"), #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(standard(String(localized: "Check Document Now"), #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(
            standard(
                String(localized: "Check Spelling While Typing"), #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spelling.addItem(
            standard(String(localized: "Check Grammar With Spelling"), #selector(NSTextView.toggleGrammarChecking(_:))))
        spelling.addItem(
            standard(
                String(localized: "Correct Spelling Automatically"), #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        menu.addItem(submenu(spelling))

        let substitutions = NSMenu(title: String(localized: "Substitutions"))
        substitutions.addItem(
            standard(String(localized: "Show Substitutions"), #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        substitutions.addItem(.separator())
        let toggles: [(String, Selector)] = [
            (String(localized: "Smart Copy/Paste"), #selector(NSTextView.toggleSmartInsertDelete(_:))),
            (String(localized: "Smart Quotes"), #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
            (String(localized: "Smart Dashes"), #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
            (String(localized: "Smart Links"), #selector(NSTextView.toggleAutomaticLinkDetection(_:))),
            (String(localized: "Data Detectors"), #selector(NSTextView.toggleAutomaticDataDetection(_:))),
            (String(localized: "Text Replacement"), #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
        ]
        for (title, action) in toggles { substitutions.addItem(standard(title, action)) }
        menu.addItem(submenu(substitutions))

        let transformations = NSMenu(title: String(localized: "Transformations"))
        transformations.addItem(standard(String(localized: "Make Upper Case"), #selector(NSResponder.uppercaseWord(_:))))
        transformations.addItem(standard(String(localized: "Make Lower Case"), #selector(NSResponder.lowercaseWord(_:))))
        transformations.addItem(standard(String(localized: "Capitalize"), #selector(NSResponder.capitalizeWord(_:))))
        menu.addItem(submenu(transformations))

        let speech = NSMenu(title: String(localized: "Speech"))
        speech.addItem(standard(String(localized: "Start Speaking"), #selector(NSTextView.startSpeaking(_:))))
        speech.addItem(standard(String(localized: "Stop Speaking"), #selector(NSTextView.stopSpeaking(_:))))
        menu.addItem(submenu(speech))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(item(String(localized: "Hide Sidebar"), #selector(MainWindowController.toggleSidebarPanel(_:)), .toggleSidebar))
        menu.addItem(item(String(localized: "Show Terminal"), #selector(MainWindowController.toggleTerminalPanel(_:)), .toggleTerminal))
        menu.addItem(item(String(localized: "Show Diff"), #selector(MainWindowController.toggleDiffPanel(_:)), .toggleDiff))
        menu.addItem(item(String(localized: "Show Pull Requests"), #selector(MainWindowController.togglePullRequestsPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Command Palette…"), #selector(MainWindowController.showCommandPalette(_:)), .commandPalette))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Increase Font Size"), #selector(MainWindowController.increaseFontSize(_:)), .increaseFontSize))
        // Command-= reaches the same command without Shift while it keeps its default Command-+.
        let equals = item(String(localized: "Increase Font Size"), #selector(MainWindowController.increaseFontSize(_:)), "=")
        equals.identifier = .increaseFontSizeWithoutShift
        equals.isHidden = true
        equals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(equals)
        menu.addItem(
            item(String(localized: "Decrease Font Size"), #selector(MainWindowController.decreaseFontSize(_:)), .decreaseFontSize))
        menu.addItem(item(String(localized: "Reset Font Size"), #selector(MainWindowController.resetFontSize(_:)), .resetFontSize))
        menu.addItem(.separator())
        menu.addItem(
            standard(String(localized: "Show Toolbar"), #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]))
        menu.addItem(
            standard(String(localized: "Customize Toolbar…"), #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(
            standard(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private func threadMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Thread"))
        menu.addItem(item(String(localized: "Stop"), #selector(MainWindowController.stopTurn(_:)), .stopTurn))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Previous Thread"), #selector(MainWindowController.previousThread(_:)), .previousThread))
        menu.addItem(item(String(localized: "Next Thread"), #selector(MainWindowController.nextThread(_:)), .nextThread))
        for index in 1...9 {
            guard let command = KeyCommand.jumpToThread(index) else { continue }
            let jump = item(String(localized: "Go to Thread \(index)"), #selector(MainWindowController.jumpToThread(_:)), command)
            jump.tag = index
            jump.isHidden = true
            jump.allowsKeyEquivalentWhenHidden = true
            menu.addItem(jump)
        }
        menu.addItem(.separator())
        // The composer's pickers (T3's modelPicker.toggle, composer.effort and composer.mode).
        menu.addItem(
            item(String(localized: "Choose Agent and Model…"), #selector(MainWindowController.showModelPicker(_:)), .chooseModel))
        menu.addItem(
            item(String(localized: "Reasoning Effort…"), #selector(MainWindowController.showEffortPicker(_:)), .reasoningEffort))
        menu.addItem(item(String(localized: "Access…"), #selector(MainWindowController.showAccessPicker(_:)), .accessMode))
        // No default: Shift-Tab toggles it in the composer, and as a menu shortcut it would take Shift-Tab from every field.
        menu.addItem(item(String(localized: "Plan Mode"), #selector(MainWindowController.togglePlanMode(_:)), .planMode))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Rename…"), #selector(MainWindowController.renameThread(_:)), .renameThread))
        menu.addItem(item(String(localized: "Pin Thread"), #selector(MainWindowController.togglePinThread(_:)), .pinThread))
        menu.addItem(
            item(String(localized: "Archive Thread"), #selector(MainWindowController.toggleArchiveThread(_:)), .archiveThread))
        menu.addItem(item(String(localized: "Copy Path"), #selector(MainWindowController.copyThreadPath(_:)), .copyThreadPath))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Delete Thread…"), #selector(MainWindowController.deleteThread(_:)), .deleteThread))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(standard(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(standard(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(standard(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: Dynamic submenus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === newThreadInMenu {
            for project in AppStore.shared.projects {
                let entry = item(project.name, #selector(MainWindowController.newThreadInProject(_:)))
                entry.representedObject = project.id
                entry.image = Theme.symbol("folder", size: 13)
                menu.addItem(entry)
            }
            if menu.items.isEmpty {
                let none = NSMenuItem(title: String(localized: "No Projects"), action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
        } else if menu === openInMenu {
            OpenTargets.reload()
            for entry in OpenTargets.menuItems(target: windowController, action: #selector(MainWindowController.openInApp(_:))) {
                menu.addItem(entry)
            }
        }
    }

    // MARK: Helpers

    /// A Coincide command whose shortcut the user sets, sent to the main window controller. `KeyBindingsController`
    /// gives it its shortcut once the menu bar is built.
    private func item(_ title: String, _ action: Selector, _ command: KeyCommand) -> NSMenuItem {
        let item = item(title, action)
        item.identifier = .keyCommand(command)
        return item
    }

    /// A Coincide command with a fixed shortcut, sent to the main window controller.
    private func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = windowController
        return item
    }

    /// A standard command, sent along the responder chain.
    private func standard(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
