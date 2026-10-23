import CoincideCore
import CoincideTerminal
import SwiftUI

struct TerminalPanel: View {
    var terminals: TerminalWorkspaceStore
    let thread: CodingThread
    let canAdd: () -> Bool
    let report: (String) -> Void
    let hide: () -> Void
    @AppStorage(TerminalAppearance.fontSizeKey) private var fontSize = TerminalAppearance.defaultFontSize
    @AppStorage(TerminalAppearance.fontFamilyKey) private var fontFamily = ""
    @AppStorage(TerminalAppearance.themeKey) private var theme = TerminalAppearance.Theme.system.rawValue
    @AppStorage(TerminalAppearance.resumeRestoredShellsKey) private var resumeRestoredShells = true
    @Environment(\.colorScheme) private var colorScheme
    private var appearance: TerminalAppearance { .init(fontFamily: fontFamily, fontSize: fontSize, theme: theme) }
    private var layout: TerminalThreadLayout { terminals.layout(for: thread.id) }
    private var selected: LocalTerminalSession? { terminals.selected(in: thread.id) }
    private var activeGroup: TerminalGroup? { terminals.activeGroup(in: thread.id) }
    private func session(_ id: UUID) -> LocalTerminalSession? { terminals.sessions[thread.id, default: []].first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = terminals.restorationError {
                HStack { Text(error); Spacer(); Button("Dismiss") { terminals.dismissRestorationError() } }
                    .font(.caption).padding(8)
            }
            if let notice = terminals.notice {
                HStack { Label(notice, systemImage: "exclamationmark.circle"); Spacer(); Button("Dismiss") { terminals.notice = nil } }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                    .accessibilityIdentifier("terminal-notice")
            }
            if let group = activeGroup {
                let readiness = terminals.resumeReadiness(for: thread, sessionIDs: group.sessionIDs, canOpen: canAdd(), enabled: resumeRestoredShells)
                TerminalGroupView(group: group, sessions: group.sessionIDs.compactMap(session), selectedID: selected?.id,
                                  appearance: appearance, background: Color(nsColor: appearance.backgroundColor(systemIsDark: colorScheme == .dark)),
                                  select: { terminals.select($0, threadID: thread.id) },
                                  close: { terminals.requestClose($0, threadID: thread.id) },
                                  canResume: { terminals.canResume($0, thread: thread) }, canAdd: canAdd(), resume: resume, add: add)
                    .id(group.id)
                    .task(id: readiness) {
                        guard !Task.isCancelled else { return }
                        terminals.resumeRestoredPanes(readiness, for: thread)
                    }
            } else {
                ContentUnavailableView { Label("Terminal", systemImage: "terminal") }
                actions: { Button("New Terminal") { add() }.disabled(!canAdd() || terminals.isRestoring) }
            }
        }
        .accessibilityIdentifier("terminal-panel")
        .confirmationDialog("Close terminal and stop its running command?", isPresented: Binding(
            get: { terminals.pendingClose?.threadID == thread.id }, set: { if !$0 { terminals.pendingClose = nil } })) {
            Button("Close Terminal", role: .destructive) {
                if let pending = terminals.pendingClose { terminals.close(pending.session, threadID: pending.threadID) }
                terminals.pendingClose = nil
            }
            Button("Cancel", role: .cancel) { terminals.pendingClose = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(layout.groups) { group in tab(group) }
                }
            }.scrollIndicators(.hidden)
            Button { selected?.showFind() } label: { Image(systemName: "magnifyingglass") }
                .help("Find in terminal (⌘F)").accessibilityLabel("Find in terminal").disabled(selected == nil)
            Button { split(.horizontal) } label: { Image(systemName: "rectangle.split.2x1") }
                .help(splitHelp("Split right (⌘D)")).accessibilityLabel("Split terminal right")
                .accessibilityIdentifier("terminal-split-right").disabled(!canSplit)
            Button { split(.vertical) } label: { Image(systemName: "rectangle.split.1x2") }
                .help(splitHelp("Split down (⇧⌘D)")).accessibilityLabel("Split terminal down")
                .accessibilityIdentifier("terminal-split-down").disabled(!canSplit)
            Menu {
                ForEach([10.0, 12.0, 14.0, 16.0, 18.0, 20.0], id: \.self) { size in
                    Button { fontSize = size } label: {
                        if appearance.fontSize == size { Label("\(Int(size)) pt", systemImage: "checkmark") }
                        else { Text("\(Int(size)) pt") }
                    }
                }
            } label: { Image(systemName: "textformat.size") }.help("Terminal text size").accessibilityLabel("Terminal text size")
            Button { add() } label: { Image(systemName: "plus") }.help("New terminal (⌘N in a terminal)")
                .accessibilityLabel("New terminal").accessibilityIdentifier("terminal-new").disabled(!canAdd() || terminals.isRestoring)
            Button(action: hide) { Image(systemName: "chevron.down") }.help("Hide terminal (⌘J)").accessibilityLabel("Hide terminal")
        }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            .coincideSurface(cornerRadius: 0)
    }

    private func tab(_ group: TerminalGroup) -> some View {
        let members = group.sessionIDs.compactMap(session)
        let shown = members.first { $0.id == selected?.id } ?? members.first
        let isActive = group.id == activeGroup?.id
        let running = members.filter(\.isBusy).count
        return HStack(spacing: 5) {
            Button {
                if let shown { terminals.select(shown, threadID: thread.id) }
            } label: {
                HStack(spacing: 4) {
                    if running > 0 { TerminalRunningDot() }
                    Text(shown?.displayTitle ?? "Terminal").lineLimit(1)
                    if members.count > 1 {
                        Image(systemName: group.axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(members.count, format: .number).foregroundStyle(.secondary)
                    }
                }
            }
            .foregroundStyle(isActive ? .primary : .secondary).frame(maxWidth: 200)
            .accessibilityLabel(tabLabel(shown, panes: members.count, running: running))
            .accessibilityIdentifier("terminal-tab-\(group.id.uuidString)")
            Button {
                if let shown { terminals.requestClose(shown, threadID: thread.id) }
            } label: { Image(systemName: "xmark").font(.system(size: 9)) }
            .help("Close terminal (⌘W in a terminal)").accessibilityLabel("Close \(shown?.displayTitle ?? "terminal")")
        }.padding(.horizontal, 8).padding(.vertical, 5)
            .background(isActive ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private func tabLabel(_ session: LocalTerminalSession?, panes: Int, running: Int) -> String {
        var label = session?.displayTitle ?? String(localized: "Terminal")
        if panes > 1 { label += ", " + String(localized: "\(panes) split terminals") }
        if running > 0 { label += ", " + String(localized: "running") }
        return label
    }
    private var canSplit: Bool { canAdd() && terminals.canSplit(in: thread.id) && !terminals.isRestoring }
    private func splitHelp(_ text: String) -> String {
        selected != nil && !terminals.canSplit(in: thread.id)
            ? String(localized: "A terminal group holds at most \(TerminalThreadLayout.maximumPanesPerGroup) terminals.") : text
    }

    private func add() {
        guard canAdd() else { return }
        do { try terminals.add(for: thread) } catch { report(error.localizedDescription) }
    }
    private func split(_ axis: TerminalGroup.Axis) {
        guard canAdd() else { return }
        do { try terminals.split(for: thread, axis: axis) } catch { report(error.localizedDescription) }
    }
    private func resume(_ session: LocalTerminalSession) {
        guard canAdd() else { return }
        do { try terminals.resume(session, thread: thread) } catch { report(error.localizedDescription) }
    }
}

/// One drawer tab's terminals, side by side or stacked.
private struct TerminalGroupView: View {
    let group: TerminalGroup
    let sessions: [LocalTerminalSession]
    let selectedID: UUID?
    let appearance: TerminalAppearance
    let background: Color
    let select: (LocalTerminalSession) -> Void
    let close: (LocalTerminalSession) -> Void
    let canResume: (LocalTerminalSession) -> Bool
    let canAdd: Bool
    let resume: (LocalTerminalSession) -> Void
    let add: () -> Void

    var body: some View {
        if sessions.count <= 1 {
            panes
        } else if group.axis == .horizontal {
            HSplitView { panes }
        } else {
            VSplitView { panes }
        }
    }

    private var panes: some View {
        ForEach(sessions) { session in
            TerminalPaneView(session: session, isSelected: session.id == selectedID, showsHeader: sessions.count > 1,
                             appearance: appearance, background: background,
                             select: { select(session) }, close: { close(session) }, canResume: canResume(session), canAdd: canAdd,
                             resume: { resume(session) }, add: add)
                .frame(minWidth: 160, minHeight: 90)
        }
    }
}

private struct TerminalPaneView: View {
    let session: LocalTerminalSession
    let isSelected: Bool
    let showsHeader: Bool
    let appearance: TerminalAppearance
    let background: Color
    let select: () -> Void
    let close: () -> Void
    let canResume: Bool
    let canAdd: Bool
    let resume: () -> Void
    let add: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 5) {
                    if session.isBusy { TerminalRunningDot() }
                    Button(session.displayTitle, action: select).buttonStyle(.borderless).lineLimit(1)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Spacer(minLength: 4)
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.borderless)
                        .accessibilityLabel("Close \(session.displayTitle)")
                }.font(.caption2).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            }
            NativeTerminalView(session: session, appearance: appearance).id(session.displayGeneration).padding(6)
                .background(background)
            status
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-pane-\(session.id.uuidString)")
    }

    @ViewBuilder private var status: some View {
        switch session.lifecycle {
        case .exited(let code):
            HStack {
                Text(message(code))
                Spacer()
                if !session.isCommand {
                    Button("Start Shell Here", action: resume).disabled(!canResume).accessibilityIdentifier("terminal-resume")
                        .help(canResume ? "Start a fresh shell without replaying saved commands" : "This pane cannot start a shell in the current checkout. Open a new terminal instead.")
                }
                Button("New Terminal", action: add).disabled(!canAdd)
            }.font(.caption).foregroundStyle(.secondary).padding(8)
        case .failed(let message):
            HStack { Text(message); Spacer(); if !session.isCommand { Button("Try Again", action: resume).disabled(!canResume) } }
                .font(.caption).foregroundStyle(.secondary).padding(8)
        case .running, .closing:
            EmptyView()
        }
    }

    private func message(_ code: Int32?) -> String {
        switch session.detachment {
        case .restart: return String(localized: "Saved output. The previous shell is no longer connected.")
        case .idle: return String(localized: "Closed at an idle prompt when this conversation settled. Output kept.")
        case nil:
            if session.isCommand { return code.map { String(localized: "Command exited (\($0)).") } ?? String(localized: "Command stopped.") }
            return code.map { String(localized: "Shell exited (\($0)).") } ?? String(localized: "Shell stopped.")
        }
    }
}

/// A pulsing teal dot for a running terminal process, as T3's indicator.
struct TerminalRunningDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let dot = Circle().fill(Color.teal).frame(width: 6, height: 6).accessibilityHidden(true)
        if reduceMotion { dot } else {
            dot.phaseAnimator([1.0, 0.35]) { content, opacity in content.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.9) }
        }
    }
}

private struct NativeTerminalView: NSViewRepresentable {
    let session: LocalTerminalSession
    let appearance: TerminalAppearance
    func makeNSView(context: Context) -> NSView { session.apply(appearance); return session.view }
    func updateNSView(_ view: NSView, context: Context) { session.apply(appearance) }
}

/// The chat above and a conversation's terminal drawer below, with a draggable
/// divider. Each conversation keeps its own drawer height (T3 stores the
/// terminal height per thread); VSplitView cannot apply a saved height.
struct TerminalDrawerSplit<Main: View, Drawer: View>: View {
    var terminals: TerminalWorkspaceStore
    let threadID: UUID
    let showsDrawer: Bool
    @ViewBuilder let main: Main
    @ViewBuilder let drawer: Drawer
    @State private var dragOrigin: Double?
    @State private var liveHeight: Double?
    @State private var hovering = false
    private static var minimumDrawer: Double { 160 }
    private static var minimumMain: Double { 280 }

    var body: some View {
        GeometryReader { proxy in
            let maximum = max(Self.minimumDrawer, min(TerminalWindowArchive.panelHeightRange.upperBound, proxy.size.height - Self.minimumMain - 1))
            let height = min(maximum, max(Self.minimumDrawer, liveHeight ?? terminals.panelHeight(threadID)))
            VStack(spacing: 0) {
                main.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsDrawer {
                    divider(height: height, maximum: maximum)
                    drawer.frame(maxWidth: .infinity).frame(height: height)
                }
            }
        }
    }

    private func divider(height: Double, maximum: Double) -> some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1).frame(maxWidth: .infinity)
            .overlay {
                Color.clear.frame(height: 9).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let origin = dragOrigin ?? height
                            dragOrigin = origin
                            liveHeight = min(maximum, max(Self.minimumDrawer, origin - value.translation.height))
                        }
                        .onEnded { _ in
                            if let liveHeight { terminals.recordPanelHeight(liveHeight, threadID: threadID) }
                            dragOrigin = nil; liveHeight = nil
                        })
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
            }
            .accessibilityElement()
            .accessibilityLabel("Terminal height")
            .accessibilityValue("\(Int(height)) points")
            .accessibilityIdentifier("terminal-drawer-divider")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: terminals.recordPanelHeight(min(maximum, height + 40), threadID: threadID)
                case .decrement: terminals.recordPanelHeight(max(Self.minimumDrawer, height - 40), threadID: threadID)
                @unknown default: break
                }
            }
            .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
    }
}
