import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// The toolbar's buttons for the panels that open on the right: every schedule, the diff, the pull requests and the
/// browser preview. They toggle their panels like tabs of the inspector column, light the open one, and sit at the
/// window's top-right corner whether the column is open or not, clear of the thread title.
@MainActor @Suite(.serialized) struct InspectorPanelButtonsTests {
    /// Takes the buttons' actions in place of the window controller, whose actions also show the window: the tests
    /// never put a window on screen.
    @MainActor final class PanelActions: NSObject {
        let split: MainSplitViewController
        init(split: MainSplitViewController) { self.split = split }
        @objc func toggleDiffPanel(_ sender: Any?) { split.toggleDiffPanel() }
        @objc func togglePullRequestsPanel(_ sender: Any?) { split.togglePullRequestsPanel() }
        @objc func togglePreviewPanel(_ sender: Any?) { split.togglePreviewPanel() }
        @objc func toggleTerminalPanel(_ sender: Any?) { split.toggleTerminalPanel() }
        @objc func toggleSchedulesPanel(_ sender: Any?) { split.toggleSchedulesPanel() }
    }

    /// The main window on a thread of a project with a script, so the toolbar shows everything it can. The window is
    /// laid out and drawn without ever being ordered in: it stays transparent and far offscreen, so nothing shows.
    @MainActor final class Harness {
        let saved = UIState.shared.values
        let folder = TemporaryDirectory("toolbar-panels")
        let store = AppStore.shared
        let savedPlacement = AppStore.shared.settings.terminalPlacement
        let projectID: UUID
        let threadID: UUID
        let controller: MainWindowController
        let actions: PanelActions
        var window: NSWindow { controller.window! }
        var split: MainSplitViewController { controller.splitController }

        init(
            width: CGFloat = 1400, sidebarOpen: Bool = true, title: String = "Toolbar buttons",
            terminal placement: TerminalPlacement = .bottom, threadPanel: UIState.InspectorPanel? = nil,
            state: (inout UIState.Values) -> Void = { _ in }
        ) {
            UIState.shared.update {
                $0.isInspectorOpen = false
                $0.inspectorPanel = .diff
                $0.inspectorFraction = nil
                $0.isSidebarCollapsed = !sidebarOpen
                $0.listWidth = 288
                $0.isTerminalOpen = false
                $0.windowFrame = nil
                $0.threadPanels = [:]
                state(&$0)
            }
            store.updateSettings { $0.terminalPlacement = placement }
            let project = store.addProject(at: folder.url)
            projectID = project.id
            store.updateProject(project.id) {
                $0.scripts = [ProjectScript(name: "Dev Server", command: "npm run dev", icon: .play, runOnWorktreeCreate: false)]
            }
            NotificationCenter.default.post(name: ProjectScripts.didChangeNotification, object: project.id)
            threadID = store.createThread(in: project.id).id
            store.updateThread(threadID) { $0.title = title }
            // The inspector the thread had open, which the window brings back with it.
            if let threadPanel {
                let key = threadID.uuidString
                UIState.shared.update { $0.threadPanels[key] = threadPanel }
            }
            controller = MainWindowController()
            actions = PanelActions(split: controller.splitController)
            window.alphaValue = 0
            controller.panelButtons.target = actions
            controller.open(threadID)
            resize(to: width)
        }

        func resize(to width: CGFloat) {
            window.setFrame(NSRect(x: -20000, y: -20000, width: width, height: 760), display: false)
            settle()
        }

        func settle() {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.contentView?.superview?.displayIfNeeded()
        }

        /// Lets animations and the work they queue finish.
        func wait() async {
            try? await Task.sleep(for: .milliseconds(450))
            settle()
        }

        /// A view's frame in the window.
        func frame(of view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

        var buttons: InspectorPanelButtons { controller.panelButtons }

        /// Whether the toolbar shows `view`, rather than having put its item in the overflow menu.
        func isShown(_ view: NSView) -> Bool { view.window === window && !view.isHiddenOrHasHiddenAncestor && view.frame.width > 0 }

        func close() {
            #expect(!window.isVisible, "a test put the window on screen")
            TerminalSessionManager.shared.terminals(for: threadID).closeAll()
            store.updateSettings { $0.terminalPlacement = savedPlacement }
            window.close()
            store.removeProject(projectID)
            UIState.shared.update { $0 = saved }
        }
    }

    @Test func theButtonsToggleTheirPanelsAndLightTheOpenOne() async {
        let harness = Harness()
        defer { harness.close() }
        let split = harness.controller.splitController
        let buttons = harness.buttons
        #expect(buttons.openPanel == nil)

        buttons.diffButton.performClick(nil)
        await harness.wait()
        #expect(split.isDiffOpen)
        #expect(buttons.openPanel == .diff)
        #expect(buttons.diffButton.isActive && !buttons.pullRequestsButton.isActive && !buttons.previewButton.isActive)
        #expect(buttons.diffButton.isAccessibilitySelected())

        // Another panel's button switches the open column to it.
        buttons.pullRequestsButton.performClick(nil)
        await harness.wait()
        #expect(split.isPullRequestsOpen)
        #expect(buttons.openPanel == .pullRequests)
        #expect(!buttons.diffButton.isActive && !buttons.diffButton.isAccessibilitySelected())

        buttons.previewButton.performClick(nil)
        await harness.wait()
        #expect(split.isPreviewOpen)
        #expect(buttons.openPanel == .preview)

        // The open panel's button closes the column.
        buttons.previewButton.performClick(nil)
        await harness.wait()
        #expect(!split.isInspectorOpen)
        #expect(buttons.openPanel == nil)

        // The menu, the shortcut and the palette toggle the same column, and the buttons follow them too.
        harness.split.toggleDiffPanel()
        await harness.wait()
        #expect(buttons.openPanel == .diff)
        harness.split.toggleDiffPanel()
        await harness.wait()
        #expect(buttons.openPanel == nil)
    }

    /// The clock is always in the group and toggles the Scheduled panel like the other buttons. For a thread with
    /// schedules it reads their next run, and the panel opens on that thread's schedules (This Thread).
    @Test func theClockTogglesTheScheduledPanelAndReadsTheThreadsNextRun() async throws {
        let harness = Harness(title: "Toolbar clock")
        defer { harness.close() }
        await harness.wait()
        let buttons = harness.buttons
        let split = harness.split
        let service = ScheduledTasks.shared
        #expect(harness.isShown(buttons.scheduleButton))
        #expect(buttons.nextRunTitle.isEmpty)
        #expect(buttons.scheduleButton.toolTip == KeyBindingsController.shared.toolTip(String(localized: "Scheduled Tasks"), for: .showSchedules))

        // Without schedules in the thread, the panel opens on every schedule.
        buttons.scheduleButton.performClick(nil)
        await harness.wait()
        #expect(split.isSchedulesOpen)
        #expect(buttons.openPanel == .schedules)
        #expect(buttons.scheduleButton.isActive && buttons.scheduleButton.isAccessibilitySelected())
        #expect(!buttons.diffButton.isActive)
        #expect(split.schedules.filter != .thisThread)
        // Another panel's button switches the column away, and the clock goes dark.
        buttons.diffButton.performClick(nil)
        await harness.wait()
        #expect(split.isDiffOpen && !buttons.scheduleButton.isActive)
        buttons.diffButton.performClick(nil)
        await harness.wait()
        #expect(!split.isInspectorOpen)

        // A schedule in the thread, hours away so it never runs during the test.
        let hour = (Calendar.current.component(.hour, from: Date()) + 12) % 24
        let task = ScheduledTask(
            name: "Toolbar clock check", projectID: harness.projectID, prompt: "Check",
            recurrence: TaskRecurrence(kind: .daily, timeZoneID: TimeZone.current.identifier, hour: hour, minute: 30),
            threadID: harness.threadID)
        try service.scheduler.save(task)
        defer { try? service.delete(task.id) }
        harness.controller.updateSchedules()
        harness.settle()
        let next = try #require(service.nextRun(inThread: harness.threadID))
        #expect(buttons.nextRunTitle == SchedulePresentation.compactTime(next.date))
        #expect(!buttons.nextRunTitle.isEmpty)
        #expect(buttons.scheduleButton.toolTip?.contains("⌥⌘S") == true)
        #expect(buttons.scheduleButton.toolTip?.contains(SchedulePresentation.threadToolTip([task]) ?? "-") == true)
        #expect(abs(harness.frame(of: buttons).width - buttons.intrinsicContentSize.width) <= 0.5)
        #expect(harness.window.frame.width - harness.frame(of: buttons).maxX < 24)

        // Now the panel opens on the thread's schedules, and the filter menu still offers every schedule.
        buttons.scheduleButton.performClick(nil)
        await harness.wait()
        #expect(split.isSchedulesOpen && buttons.openPanel == .schedules)
        #expect(split.schedules.filter == .thisThread)
        #expect(split.schedules.shownTasks.map(\.id) == [task.id])
        buttons.scheduleButton.performClick(nil)
        await harness.wait()
        #expect(!split.isInspectorOpen && buttons.openPanel == nil && !buttons.scheduleButton.isActive)

        try service.delete(task.id)
        harness.controller.updateSchedules()
        #expect(buttons.nextRunTitle.isEmpty)
        #expect(harness.isShown(buttons.scheduleButton))
    }

    @Test func theButtonsAreLabelledAndNameTheirShortcuts() {
        let buttons = InspectorPanelButtons()
        #expect(buttons.diffButton.accessibilityLabel() == String(localized: "Diff"))
        #expect(buttons.pullRequestsButton.accessibilityLabel() == String(localized: "Pull Requests"))
        #expect(buttons.previewButton.accessibilityLabel() == String(localized: "Browser Preview"))
        #expect(buttons.scheduleButton.accessibilityLabel() == String(localized: "Scheduled Tasks"))
        // The clock names ⌥⌘S, the shortcut of View › Show Scheduled Tasks.
        #expect(buttons.scheduleButton.toolTip == KeyBindingsController.shared.toolTip(String(localized: "Scheduled Tasks"), for: .showSchedules))
        #expect(KeyBindingsController.shared.displayString(for: .showSchedules) == "⌥⌘S")
        #expect(buttons.scheduleButton.toolTip?.contains("⌥⌘S") == true)
        #expect(buttons.diffButton.toolTip == KeyBindingsController.shared.toolTip(String(localized: "Diff"), for: .toggleDiff))
        #expect(buttons.pullRequestsButton.toolTip == String(localized: "Pull Requests"))
        #expect(buttons.previewButton.toolTip == String(localized: "Browser Preview"))
        #expect(buttons.accessibilityRole() == .group)
        // Nil targets send the actions up the responder chain, to the window controller, as the menu items do.
        #expect(buttons.diffButton.action == #selector(MainWindowController.toggleDiffPanel(_:)))
        #expect(buttons.pullRequestsButton.action == #selector(MainWindowController.togglePullRequestsPanel(_:)))
        #expect(buttons.previewButton.action == #selector(MainWindowController.togglePreviewPanel(_:)))
        #expect(buttons.scheduleButton.action == #selector(MainWindowController.toggleSchedulesPanel(_:)))
        // The clock comes first, before the diff, and shows even for a thread without schedules.
        #expect(buttons.shownButtons == [buttons.scheduleButton, buttons.diffButton, buttons.pullRequestsButton, buttons.previewButton])
        buttons.showsTerminal = true
        #expect(buttons.shownButtons.last === buttons.terminalButton)
    }

    @Test func theGroupIsAPillAsTallAsTheScriptsControl() {
        let buttons = InspectorPanelButtons()
        buttons.frame.size = buttons.fittingSize
        buttons.layoutSubtreeIfNeeded()
        #expect(buttons.frame.height == ProjectScriptsControl().fittingSize.height)
        #expect(buttons.frame.width == InspectorPanelButtons.buttonWidth * 4 + 2)
        for button in [buttons.scheduleButton, buttons.diffButton, buttons.pullRequestsButton, buttons.previewButton] {
            #expect(button.frame.width == InspectorPanelButtons.buttonWidth)
        }
        // With a thread's next run beside it, the clock widens and the pill with it.
        buttons.showSchedules(nextRun: "10:30", detail: "1 scheduled task")
        buttons.frame.size = buttons.fittingSize
        buttons.layoutSubtreeIfNeeded()
        #expect(buttons.nextRunTitle == "10:30")
        #expect(buttons.scheduleButton.frame.width > InspectorPanelButtons.buttonWidth)
        #expect(abs(buttons.frame.width - buttons.intrinsicContentSize.width) <= 0.5)
        #expect(buttons.diffButton.frame.width == InspectorPanelButtons.buttonWidth)
        #expect(buttons.scheduleButton.toolTip?.hasSuffix("\n1 scheduled task") == true)
        buttons.showSchedules(nextRun: nil, detail: nil)
        #expect(buttons.nextRunTitle.isEmpty)
        #expect(buttons.intrinsicContentSize.width == InspectorPanelButtons.buttonWidth * 4 + 2)
    }

    /// The group stays at the window's top-right corner: after the scripts control while the column is closed, over the
    /// column's top edge while it is open, so opening and closing the column doesn't move it.
    @Test func theGroupStaysAtTheTopRightCornerAsTheInspectorOpensAndCloses() async throws {
        let harness = Harness()
        defer { harness.close() }
        await harness.wait()
        let buttons = harness.buttons
        #expect(harness.isShown(buttons))
        let closed = harness.frame(of: buttons)
        let windowWidth = harness.window.frame.width
        #expect(windowWidth - closed.maxX < 24, "\(closed) is not at the window's right edge (\(windowWidth))")
        #expect(closed.minY > harness.frame(of: harness.controller.splitController.view).maxY - 60, "\(closed) is not in the toolbar")
        let scripts = harness.frame(of: harness.controller.projectScripts)
        #expect(scripts.maxX <= closed.minX)

        harness.split.toggleDiffPanel()
        await harness.wait()
        let open = harness.frame(of: buttons)
        #expect(abs(open.maxX - closed.maxX) <= 1, "\(open) moved from \(closed)")
        #expect(abs(open.midY - closed.midY) <= 1)
        let inspector = harness.frame(of: harness.controller.splitController.inspector.view)
        #expect(open.minX >= inspector.minX, "the group is not over the open inspector")
        // The panel's own header starts below the toolbar, so its controls are never under the group.
        let header = harness.controller.splitController.diff.view.safeAreaRect
        let headerTop = harness.controller.splitController.diff.view.convert(header, to: nil).maxY
        #expect(headerTop <= open.minY + 1, "the diff header (top \(headerTop)) runs under the group \(open)")

        harness.split.togglePreviewPanel()
        await harness.wait()
        let preview = harness.controller.splitController.preview.view
        let previewTop = preview.convert(preview.safeAreaRect, to: nil).maxY
        #expect(previewTop <= open.minY + 1)
        for field in Self.subviews(of: preview, as: NSTextField.self) where field.isEditable {
            #expect(!harness.frame(of: field).intersects(harness.frame(of: buttons)), "the address bar is under the group")
        }
    }

    /// In a narrow window the thread title gives way (it truncates) before anything overlaps it, and the group stays,
    /// with the terminal's button in it too.
    @Test(arguments: [
        (820.0, true, TerminalPlacement.bottom), (820.0, false, .bottom), (1000.0, true, .bottom),
        (820.0, true, .right), (820.0, false, .right), (1000.0, true, .right),
    ])
    func theGroupNeverOverlapsTheThreadTitle(width: CGFloat, sidebarOpen: Bool, placement: TerminalPlacement) async {
        let long = String(repeating: "A very long thread title that goes on ", count: 6)
        let harness = Harness(width: width, sidebarOpen: sidebarOpen, title: long, terminal: placement)
        defer { harness.close() }
        await harness.wait()
        #expect(harness.buttons.shownButtons.count == (placement == .right ? 5 : 4))
        for inspectorOpen in [false, true] {
            if inspectorOpen {
                // The terminal is the widest-reaching case on the right: its panel opens in the column.
                if placement == .right { harness.split.toggleTerminalPanel() } else { harness.split.togglePullRequestsPanel() }
                await harness.wait()
            }
            let title = harness.controller.threadTitle
            let buttons = harness.buttons
            #expect(harness.isShown(buttons), "the group went to the overflow menu at \(width)")
            let group = harness.frame(of: buttons)
            #expect(harness.window.frame.width - group.maxX < 24)
            #expect(abs(group.width - buttons.intrinsicContentSize.width) <= 0.5, "\(group) is not the pill's width")
            // The title truncates rather than going to the toolbar's overflow menu with the scripts.
            #expect(harness.isShown(title), "the title went to the overflow menu at \(width), inspector \(inspectorOpen)")
            let titleFrame = harness.frame(of: title)
            #expect(titleFrame.width >= ThreadTitleView.minimumWidth)
            // The labels truncate inside the title rather than drawing past it.
            // (Their alignment rects: a text field's frame reaches a little past the text it draws.)
            for label in Self.subviews(of: title, as: NSTextField.self) where !label.isHiddenOrHasHiddenAncestor {
                let text = label.superview!.convert(label.alignmentRect(forFrame: label.frame), to: nil)
                #expect(text.maxX <= titleFrame.maxX + 0.5, "\(label.stringValue) runs past the title")
            }
            #expect(titleFrame.maxX <= group.minX, "title \(titleFrame) overlaps \(group) at \(width), inspector \(inspectorOpen)")
            let scripts = harness.controller.projectScripts
            #expect(harness.isShown(scripts), "the scripts went to the overflow menu at \(width), inspector \(inspectorOpen)")
            if harness.isShown(scripts) {
                #expect(titleFrame.maxX <= harness.frame(of: scripts).minX)
            }
        }
    }

    @Test(arguments: [820.0, 1470.0])
    func activeStatusHasRoomForItsContentsAndSpaceBetweenPills(width: CGFloat) async throws {
        let harness = Harness(width: width, title: "Toolbar spacing")
        defer { harness.close() }
        await harness.wait()
        let status = harness.controller.runStatus
        let states: [RunStatusView.State] = [.starting, .running(since: Date().addingTimeInterval(-125), note: nil), .approval(count: 12)]
        for (index, state) in states.enumerated() {
            status.update(state)
            await harness.wait()
            #expect(harness.isShown(status))
            let pill = try #require(status.subviews.first)
            let body = harness.frame(of: pill)
            let scripts = harness.frame(of: harness.controller.projectScripts)
            #expect(body.minX - scripts.maxX >= 8, "The script and status pills touch: \(scripts), \(body)")
            #expect(harness.frame(of: harness.buttons).minX - body.maxX >= 6)
            let label = try #require(Self.subviews(of: status, as: NSTextField.self).first)
            let text = harness.frame(of: label)
            #expect(text.width >= ceil(label.intrinsicContentSize.width) - 1, "The status text is clipped")
            let stop = try #require(Self.subviews(of: status, as: NSButton.self).first)
            let stopFrame = harness.frame(of: stop)
            #expect(stopFrame.width >= 24)
            #expect(body.maxX - stopFrame.maxX >= 9)
            for spinner in Self.subviews(of: status, as: NSProgressIndicator.self) where !spinner.isHidden {
                let icon = harness.frame(of: spinner)
                #expect(icon.minX - body.minX >= 9)
                #expect(abs(icon.midY - body.midY) <= 1)
                // NSTextField's frame extends beyond the text's alignment rect.
                let textInk = label.superview!.convert(label.alignmentRect(forFrame: label.frame), to: nil)
                #expect(textInk.minX - icon.maxX >= 6)
            }
            if let folder = ProcessInfo.processInfo.environment["COINCIDE_TOOLBAR_STATUS_PNG_DIR"] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                harness.window.appearance = NSAppearance(named: .darkAqua)
                try draw(harness.window, to: "\(folder)/toolbar-\(Int(width))-\(index).png")
            }
        }
    }

    /// Draws the window's top, with the column closed and open, narrow and wide, in light and dark and every theme,
    /// when `COINCIDE_TOOLBAR_PNG_DIR` names a folder (`TEST_RUNNER_COINCIDE_TOOLBAR_PNG_DIR` on the command line).
    @Test func rendersTheToolbarForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_TOOLBAR_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let selection = ThemeSelection.shared
        defer { selection.set(dark: AppTheme.defaultDarkID, light: AppTheme.defaultLightID) }
        let layouts: [(CGFloat, Bool, TerminalPlacement)] = [
            (1400, true, .bottom), (820, true, .bottom), (900, false, .bottom), (1400, true, .right), (820, true, .right),
        ]
        for (width, sidebarOpen, placement) in layouts {
            let harness = Harness(
                width: width, sidebarOpen: sidebarOpen, title: "Move the right panel buttons into the toolbar beside the scripts",
                terminal: placement)
            defer { harness.close() }
            await harness.wait()
            let states = placement == .right ? ["closed", "terminal", "diff"] : ["closed", "diff", "pullRequests", "preview"]
            for state in states {
                switch state {
                case "diff": harness.split.toggleDiffPanel()
                case "pullRequests": harness.split.togglePullRequestsPanel()
                case "preview": harness.split.togglePreviewPanel()
                case "terminal": harness.split.toggleTerminalPanel()
                default: break
                }
                await harness.wait()
                for (index, (dark, light)) in zip(AppTheme.dark, AppTheme.light).enumerated() where index < 3 || state == "diff" {
                    selection.set(dark: dark.id, light: light.id)
                    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                        harness.window.appearance = NSAppearance(named: appearance)
                        let theme = name == "dark" ? dark.id : light.id
                        try draw(harness.window, to: "\(folder)/\(placement.rawValue)-\(Int(width))-\(sidebarOpen ? "list" : "nolist")-\(state)-\(theme).png")
                    }
                }
            }
        }
    }

    private func draw(_ window: NSWindow, to path: String) throws {
        let frame = try #require(window.contentView?.superview)
        frame.needsDisplay = true
        for view in Self.subviews(of: frame, as: NSView.self) { view.needsDisplay = true }
        frame.layoutSubtreeIfNeeded()
        // The top of the window: the toolbar and the panels' headers under it.
        let top = NSRect(x: 0, y: frame.bounds.height - 140, width: frame.bounds.width, height: 140)
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: top))
        frame.effectiveAppearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: top, to: rep) }
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private static func subviews<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + subviews(of: $0, as: type) }
    }
}
