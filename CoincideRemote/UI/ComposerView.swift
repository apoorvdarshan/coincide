import CoincideRemoteKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The message field with the Mac composer's footer: agent and model, effort, speed, access, mode, photos, send and stop.
struct ComposerView: View {
    let model: ThreadModel
    @Environment(RemoteClient.self) private var client
    @Environment(ProStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var photos: [PhotosPickerItem] = []
    @State private var isSending = false
    @State private var isDropTargeted = false
    @State private var showsPhotos = false
    @State private var showsCamera = false
    @State private var showsFiles = false
    /// Suggestions for the `@` or `/` word being typed, from the Mac.
    @State private var suggestions: [RemoteCompletion] = []
    /// Where a message sent while the turn runs goes, when the user picked other than the Mac's setting.
    @State private var delivery: String?
    @AppStorage("composer.returnSends") private var returnSends = true
    /// Dictation with Apple's on-device recognition.
    @State private var dictation = RemoteDictation()
    /// The message field's focus, which the thread clears when the transcript is tapped.
    var focused: FocusState<Bool>.Binding

    private var draft: Binding<ComposerDraft> {
        Binding(get: { client.drafts[model.id] ?? ComposerDraft() }, set: { client.drafts[model.id] = $0 })
    }

    private var summary: RemoteThreadSummary? { model.summary }

    /// The Mac's follow-up setting, `steer` or `queue`, unless the user picked the other one for this message.
    private var followUp: String { delivery ?? client.server?.followUpBehavior ?? "steer" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !suggestions.isEmpty, completionWord != nil { suggestionList }
            if !draft.wrappedValue.images.isEmpty { attachmentStrip }
            if dictation.isActive { DictationBar(dictation: dictation) }
            // Two lines tall before it grows, with room above them, as the Mac's composer.
            TextField(placeholder, text: draft.text, axis: .vertical)
                .lineLimit(2...8)
                .focused(focused)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .submitLabel(.return)
                .padding(.horizontal, 6)
                .padding(.top, 12)
                .accessibilityLabel(Text("Message"))
                // A hardware keyboard sends with Return, as on the Mac; Shift-Return adds a line.
                .onKeyPress(.return, phases: .down) { press in
                    guard returnSends, !press.modifiers.contains(.shift), !press.modifiers.contains(.option) else { return .ignored }
                    if let first = suggestions.first, completionWord != nil {
                        complete(first)
                    } else {
                        send(alternate: followUp != (client.server?.followUpBehavior ?? "steer"))
                    }
                    return .handled
                }
            // The Mac composer's footer: its menus from the leading edge, then steer or queue, attach and send, which
            // never move. Menus that don't fit with their labels show their symbols (`RemoteLayout.footer`). When even
            // that takes two lines (a phone while the agent works), the speed moves into the model's menu.
            ViewThatFits(in: .horizontal) {
                footer(foldsSpeed: false)
                if let summary, ComposerControls.offersSpeeds(summary, in: client) { footer(foldsSpeed: true) }
            }
            .padding(.horizontal, -ComposerFooterLayout.bleed)
        }
        .task(id: completionWord) { await loadSuggestions() }
        #if DEBUG
        // Screenshots of completions without typing: `-CoincideRemoteDemoDraft "@Sour"`.
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if DemoData.isEnabled, let index = arguments.firstIndex(of: "-CoincideRemoteDemoDraft"), index + 1 < arguments.count {
                draft.wrappedValue.text = arguments[index + 1]
            }
        }
        #endif
        .photosPicker(isPresented: $showsPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in add(data, name: String(localized: "Photo \(draft.wrappedValue.images.count + 1)")) }
                .ignoresSafeArea()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isDropTargeted ? theme.accent : theme.border, lineWidth: isDropTargeted ? 2 : theme.borderWidth)
        }
        .onDrop(of: [.image], isTargeted: $isDropTargeted) { providers in
            guard ProGate.allows() else { return false }
            for provider in providers { load(provider) }
            return true
        }
        .onChange(of: photos) { _, items in
            Task { await importPhotos(items) }
        }
        // A transcript belongs to the thread it was spoken in.
        .onChange(of: model.id) { dictation.cancel() }
        .onDisappear { dictation.cancel() }
        .alert(
            "Dictation stopped", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })
        ) {
            if dictation.needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictation.error ?? "")
        }
        // Typing, sending, stopping, attaching, dictating and the model's menus are actions (`ProGate`): without Coincide
        // Pro a tap anywhere on the composer shows the paywall, and the field never takes focus.
        .overlay {
            if !store.isPro {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { ProGate.allows() }
                    .accessibilityElement()
                    .accessibilityLabel(Text("Message"))
                    .accessibilityHint(Text("Sending messages needs Coincide Pro"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { ProGate.allows() }
            }
        }
        .disabled(!client.isConnected)
    }

    private func footer(foldsSpeed: Bool) -> some View {
        ComposerFooterLayout(inset: ComposerFooterLayout.bleed) {
            if let summary { ComposerControls(thread: summary, foldsSpeed: foldsSpeed) }
            if model.turn.isRunning {
                followUpMenu.layoutValue(key: ComposerFooterRole.self, value: .pinned)
            }
            attachMenu.layoutValue(key: ComposerFooterRole.self, value: .fixed)
            DictationButton(dictation: dictation, draft: draft.text).layoutValue(key: ComposerFooterRole.self, value: .fixed)
            sendButton.layoutValue(key: ComposerFooterRole.self, value: .fixed)
        }
    }

    private var placeholder: String {
        model.turn.isRunning
            ? (followUp == "queue" ? String(localized: "Queue a follow-up") : String(localized: "Steer the agent"))
            : String(localized: "Ask anything. @ files, / commands")
    }

    // MARK: Completions

    /// The `@file` or `/command` word at the end of the message, which the Mac completes.
    private var completionWord: String? {
        let text = draft.wrappedValue.text
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init),
            let first = last.first, first == "@" || (first == "/" && !text.dropLast(last.count).contains(where: { !$0.isWhitespace })),
            !last.contains("\n")
        else { return nil }
        return last
    }

    private func loadSuggestions() async {
        guard let word = completionWord else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        if DemoData.isEnabled {
            suggestions = DemoData.completions(word)
            return
        }
        let request = RemoteRequest.completions(threadID: model.id, trigger: String(word.prefix(1)), query: String(word.dropFirst()))
        if case .completions(let found)? = try? await client.request(request, timeout: .seconds(10)), !Task.isCancelled {
            suggestions = Array(found.prefix(RemoteCompletion.maxResults))
        } else if !Task.isCancelled {
            suggestions = []
        }
    }

    private func complete(_ completion: RemoteCompletion) {
        guard let word = completionWord else { return }
        draft.wrappedValue.text = String(draft.wrappedValue.text.dropLast(word.count)) + completion.insert
        suggestions = []
    }

    /// The Mac's suggestion panel: files with their folders, commands with what they do.
    private var suggestionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(suggestions) { completion in
                    Button { complete(completion) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: Self.symbol(completion.kind))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(theme.secondaryInk)
                                .frame(width: 20)
                            Text(completion.title).font(.subheadline).foregroundStyle(theme.ink).lineLimit(1)
                            if let detail = completion.detail {
                                // A folder path keeps its end; a description its start.
                                Text(detail).font(.caption).foregroundStyle(theme.tertiaryInk).lineLimit(1)
                                    .truncationMode(completion.kind == .file || completion.kind == .folder ? .head : .tail)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(SidebarRowButtonStyle())
                }
            }
        }
        .frame(maxHeight: 44 * 4.5)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: theme.borderWidth) }
        .accessibilityLabel(Text("Suggestions"))
    }

    static func symbol(_ kind: RemoteCompletion.Kind) -> String {
        switch kind {
        case .file: "doc"
        case .folder: "folder"
        case .command: "command"
        case .skill: "sparkles"
        case .unknown: "circle"
        }
    }

    // MARK: Attachments and delivery

    /// Photos, the camera and Files, as the Mac's composer takes pictures from anywhere.
    private var attachMenu: some View {
        Menu {
            Button { showsPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showsCamera = true } label: { Label("Take Photo", systemImage: "camera") }
            }
            Button { showsFiles = true } label: { Label("Files", systemImage: "folder") }
        } label: {
            // Wider when a large text size makes the symbol wider, so it never runs into dictation.
            Image(systemName: "paperclip")
                .font(.body.weight(.medium))
                .padding(.horizontal, 2)
                .frame(minWidth: 40, minHeight: 44)
                .contentShape(.rect)
        }
        .foregroundStyle(theme.secondaryInk)
        .accessibilityLabel(Text("Attach"))
    }

    /// While a turn runs: whether the message goes into it (steer) or waits for it (queue), as the Mac's footer offers.
    private var followUpMenu: some View {
        Menu {
            Picker("Follow-up", selection: Binding(get: { followUp }, set: { delivery = $0 })) {
                Label("Steer", systemImage: "arrow.turn.down.right").tag("steer")
                Label("Queue", systemImage: "text.append").tag("queue")
            }
        } label: {
            ComposerChip(menu: true) {
                Image(systemName: followUp == "queue" ? "text.append" : "arrow.turn.down.right")
            } label: {
                Text(followUp == "queue" ? "Queue" : "Steer")
            }
        }
        .disabled(!model.turn.canSteer && followUp != "queue")
        .accessibilityLabel(followUp == "queue" ? Text("While the agent works: Queue") : Text("While the agent works: Steer"))
    }

    @ViewBuilder private var sendButton: some View {
        if model.turn.isRunning && draft.wrappedValue.isEmpty {
            Button {
                Task { await client.perform(.stop(threadID: model.id)) }
            } label: {
                // Fixed sizes: the symbol has to stay inside its circle at every text size.
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.onControl)
                    .frame(width: 32, height: 32)
                    .background(theme.control, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityLabel(Text("Stop"))
        } else {
            let enabled = !draft.wrappedValue.isEmpty && !isSending && !dictation.isActive
            Button {
                send(alternate: model.turn.isRunning && followUp != (client.server?.followUpBehavior ?? "steer"))
            } label: {
                Group {
                    if isSending {
                        ProgressView().controlSize(.small).tint(theme.onControl)
                    } else {
                        // While a turn runs, the button says where the message goes: into the turn, or after it.
                        Image(systemName: !model.turn.isRunning ? "arrow.up"
                            : followUp == "queue" ? "text.append" : "arrow.turn.down.right")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(enabled ? theme.onControl : theme.tertiaryInk)
                .frame(width: 32, height: 32)
                .background(enabled || isSending ? theme.control : theme.selection, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            .disabled(!enabled)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(model.turn.isRunning ? Text("Send to the running turn") : Text("Send"))
            .contextMenu {
                if model.turn.isRunning {
                    Button(client.server?.followUpBehavior == "queue" ? "Send into the Current Turn" : "Queue for After the Turn") {
                        send(alternate: true)
                    }
                }
            }
            // ⌘. stops even while there's text to send.
            .background {
                if model.turn.isRunning {
                    Button("Stop") { Task { await client.perform(.stop(threadID: model.id)) } }
                        .keyboardShortcut(".", modifiers: .command)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.wrappedValue.images) { image in
                    ZStack(alignment: .topTrailing) {
                        if let uiImage = UIImage(data: image.data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityLabel(Text(image.name))
                        }
                        Button {
                            draft.wrappedValue.images.removeAll { $0.id == image.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel(Text("Remove \(image.name)"))
                    }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 4)
        }
    }

    private func send(alternate: Bool) {
        let current = draft.wrappedValue
        guard !current.isEmpty, !isSending else { return }
        isSending = true
        Task {
            if await client.send(model.id, draft: current, alternate: alternate) {
                client.drafts[model.id] = nil
                photos = []
                delivery = nil
                suggestions = []
                model.followsBottom = true
            }
            isSending = false
        }
    }

    /// Adds a picture as the Mac takes it: JPEG, at most 2000 pixels, ten at most.
    private func add(_ data: Data, name: String) {
        guard let jpeg = ImageShrinker.jpeg(data) else { return }
        var current = client.drafts[model.id] ?? ComposerDraft()
        guard current.images.count < 10 else { return }
        current.images.append(ComposerDraft.Image(name: name, data: jpeg))
        client.drafts[model.id] = current
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls.prefix(10) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= 64 * 1024 * 1024 }) ?? true,
                let data = try? Data(contentsOf: url)
            else { continue }
            add(data, name: url.lastPathComponent)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var images: [ComposerDraft.Image] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = ImageShrinker.jpeg(data) else { continue }
            images.append(ComposerDraft.Image(name: String(localized: "Photo \(index + 1)"), data: jpeg))
        }
        draft.wrappedValue.images = Array((draft.wrappedValue.images.filter { !$0.name.hasPrefix("Photo ") } + images).prefix(10))
    }

    private func load(_ provider: NSItemProvider) {
        let name = provider.suggestedName ?? String(localized: "Dropped image")
        _ = provider.loadDataRepresentation(for: .image) { data, _ in
            guard let data, let jpeg = ImageShrinker.jpeg(data) else { return }
            Task { @MainActor in
                var current = client.drafts[model.id] ?? ComposerDraft()
                guard current.images.count < 10 else { return }
                current.images.append(ComposerDraft.Image(name: name, data: jpeg))
                client.drafts[model.id] = current
            }
        }
    }
}

/// The camera, for a photo to attach.
struct CameraPicker: UIViewControllerRepresentable {
    let take: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { parent.take(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Photos go to the Mac as JPEG, at most 2000 pixels on the long edge, as the Mac's composer imports them.
enum ImageShrinker {
    nonisolated static func jpeg(_ data: Data, maxEdge: CGFloat = 2000) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.85)
    }
}

/// The footer's menus, each a glass button showing the current choice.
struct ComposerControls: View {
    let thread: RemoteThreadSummary
    /// Whether the speed is chosen in the model's menu, as in the Mac's model picker, rather than in a menu of its own:
    /// for a footer that otherwise wouldn't fit on one line. The model's mark then carries the Mac's bolt while the
    /// model runs fast.
    var foldsSpeed = false
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    /// The agent's mark grows with the text beside it.
    @ScaledMetric(relativeTo: .subheadline) private var logoSize: CGFloat = 14
    /// The bolt on the agent's mark while the speed is in its menu and the model runs fast.
    @ScaledMetric(relativeTo: .subheadline) private var boltSize: CGFloat = 9

    private var currentModel: RemoteModel? { Self.model(of: thread, in: client) }

    static func model(of thread: RemoteThreadSummary, in client: RemoteClient) -> RemoteModel? {
        client.provider(thread.selection.provider)?.models.first { $0.id == thread.selection.modelID }
    }

    /// Whether the footer shows a speed menu, which `foldsSpeed` moves into the model's menu.
    static func offersSpeeds(_ thread: RemoteThreadSummary, in client: RemoteClient) -> Bool {
        model(of: thread, in: client)?.speeds.isEmpty == false
    }

    /// The thread's faster speed, nil while it runs at the standard one.
    private var fastSpeed: RemoteSpeed? { currentModel?.speeds.first { $0.id == thread.selection.speed } }
    private var speedTitle: String { fastSpeed?.name ?? String(localized: "Standard") }

    var body: some View {
        Menu {
            if foldsSpeed, let speeds = currentModel?.speeds, !speeds.isEmpty {
                // One row naming the speed, opening its choices, above the agents' models.
                speedPicker(speeds).pickerStyle(.menu)
            }
            ForEach(client.workspace.providers) { provider in
                if provider.accounts.count > 1 {
                    Menu(provider.name) {
                        ForEach(provider.accounts) { account in
                            Section(account.name) { modelButtons(provider, accountID: account.id) }
                        }
                        riskLink(provider)
                    }
                } else {
                    Section(provider.name) {
                        modelButtons(provider, accountID: nil)
                        riskLink(provider)
                    }
                }
            }
        } label: {
            ComposerChip(menu: true) {
                // The bolt sits on the mark's corner, so the menu still keeps its chevron as a symbol.
                let fast = foldsSpeed && fastSpeed != nil
                AgentLogo(provider: thread.selection.provider, size: logoSize)
                    .padding(.trailing, fast ? boltSize * 0.3 : 0)
                    .overlay(alignment: .bottomTrailing) {
                        if fast {
                            Image(systemName: Self.fastSymbol).font(.system(size: boltSize, weight: .heavy))
                                .foregroundStyle(theme.accent)
                                .offset(y: boltSize * 0.2)
                        }
                    }
            } label: {
                Text(thread.selection.modelName)
                if let account = thread.selection.accountName { Text("· \(account)").foregroundStyle(theme.secondaryInk) }
            }
        }
        .accessibilityLabel(Text("Model: \(thread.selection.modelName)"))
        .accessibilityValue(
            foldsSpeed && Self.offersSpeeds(thread, in: client) ? Text("Speed: \(speedTitle)") : Text(verbatim: ""))

        if let efforts = currentModel?.efforts, !efforts.isEmpty {
            Menu {
                Picker("Effort", selection: setting(thread.selection.effort ?? "") { RemoteThreadSettings(threadID: thread.id, effort: $0) }) {
                    ForEach(efforts, id: \.self) { Text(Self.effortTitle($0)).tag($0) }
                }
            } label: {
                ComposerChip(menu: true) {
                    Image(systemName: "brain")
                } label: {
                    Text(Self.effortTitle(thread.selection.effort ?? currentModel?.defaultEffort ?? ""))
                }
            }
            .accessibilityLabel(Text("Effort: \(Self.effortTitle(thread.selection.effort ?? currentModel?.defaultEffort ?? ""))"))
        }

        if !foldsSpeed, let speeds = currentModel?.speeds, !speeds.isEmpty {
            Menu {
                speedPicker(speeds)
            } label: {
                // The Mac's symbols (`ComposerSpeedControl`): a gauge at the standard speed, a bolt when faster.
                ComposerChip(menu: true) {
                    Image(systemName: fastSpeed == nil ? "gauge.with.dots.needle.50percent" : Self.fastSymbol)
                } label: {
                    Text(speedTitle)
                }
            }
            .accessibilityLabel(Text("Speed: \(speedTitle)"))
        }

        Menu {
            Picker("Access", selection: setting(thread.accessMode) { RemoteThreadSettings(threadID: thread.id, accessMode: $0) }) {
                Label("Full access", systemImage: "lock.open").tag("fullAccess")
                Label("Ask for approval", systemImage: "lock").tag("approval")
            }
        } label: {
            ComposerChip(menu: true) {
                Image(systemName: thread.accessMode == "fullAccess" ? "lock.open" : "lock")
            } label: {
                Text(thread.accessMode == "fullAccess" ? "Full access" : "Ask for approval")
            }
        }
        .accessibilityLabel(thread.accessMode == "fullAccess" ? Text("Access: Full access") : Text("Access: Ask for approval"))

        Button {
            let next = thread.interactionMode == "plan" ? "build" : "plan"
            Task { await client.perform(.updateSettings(RemoteThreadSettings(threadID: thread.id, interactionMode: next))) }
        } label: {
            ComposerChip(menu: false, color: thread.interactionMode == "plan" ? theme.accent : nil) {
                Image(systemName: thread.interactionMode == "plan" ? "list.bullet.clipboard" : "hammer")
            } label: {
                Text(thread.interactionMode == "plan" ? "Plan" : "Build")
            }
        }
        .accessibilityLabel(Text("Mode: \(thread.interactionMode == "plan" ? String(localized: "Plan") : String(localized: "Build"))"))
        .accessibilityHint(Text("Switches between building and planning"))
    }

    /// A faster speed, as the Mac marks it.
    static let fastSymbol = "bolt.fill"

    private func speedPicker(_ speeds: [RemoteSpeed]) -> some View {
        Picker(
            "Speed",
            selection: setting(thread.selection.speed ?? RemoteThreadSettings.standardSpeed) {
                RemoteThreadSettings(threadID: thread.id, speed: $0)
            }
        ) {
            Text("Standard").tag(RemoteThreadSettings.standardSpeed)
            ForEach(speeds) { speed in Text(speed.name).tag(speed.id) }
        }
    }

    /// An effort level as the Mac's composer names it (`ComposerMenus.effortTitle`), in the phone's language.
    static func effortTitle(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none", "off": String(localized: "Off")
        case "auto": String(localized: "Auto")
        case "minimal": String(localized: "Minimal")
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh", "extra-high", "extra_high": String(localized: "Extra High")
        case "max", "maximum": String(localized: "Max")
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    /// Under Antigravity's models: its account risk, opening Google's terms.
    @ViewBuilder
    private func riskLink(_ provider: RemoteProvider) -> some View {
        if AntigravityRisk.applies(toProvider: provider.id) {
            Link(destination: AntigravityRisk.termsURL) {
                Label(AntigravityRisk.short, systemImage: "exclamationmark.triangle.fill")
            }
            .accessibilityHint(Text(AntigravityRisk.notice))
        }
    }

    @ViewBuilder
    private func modelButtons(_ provider: RemoteProvider, accountID: String?) -> some View {
        ForEach(provider.models) { model in
            Button {
                let settings = RemoteThreadSettings(threadID: thread.id, provider: provider.id, modelID: model.id, accountID: accountID)
                Task { await client.perform(.updateSettings(settings)) }
            } label: {
                if thread.selection.provider == provider.id && thread.selection.modelID == model.id
                    && (accountID == nil || thread.selection.accountID == accountID || (thread.selection.accountID == nil && accountID == "default"))
                {
                    Label(model.name, systemImage: "checkmark")
                } else {
                    Text(model.name)
                }
            }
            .disabled(!provider.isReady && provider.state != "unknown")
        }
    }

    private func setting(_ current: String, _ make: @escaping (String) -> RemoteThreadSettings) -> Binding<String> {
        Binding(
            get: { current },
            set: { value in
                guard value != current else { return }
                Task { await client.perform(.updateSettings(make(value))) }
            })
    }
}

/// One of the composer's menus as the Mac's footer draws it: borderless, a symbol and the current choice, and a small
/// chevron when it opens a menu. A full-height touch target without a capsule around it, never narrower than 44 points.
/// Offered less room than its label needs, it shows its symbol and chevron, then its symbol alone (its accessibility
/// label still says the choice).
struct ComposerChip<Symbol: View, Label: View>: View {
    var menu: Bool
    /// The label's color when it marks something on (Plan mode); the theme's text otherwise.
    var color: Color?
    @ViewBuilder var symbol: Symbol
    @ViewBuilder var label: Label
    @Environment(\.theme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chip(showsLabel: true, showsChevron: menu)
            chip(showsLabel: false, showsChevron: menu)
            if menu { chip(showsLabel: false, showsChevron: false) }
        }
    }

    /// Each form keeps its own size whatever it's offered, so the footer measures the narrowest one truly
    /// (`ComposerFooterLayout`). A symbol and chevron sit closer and need little padding of their own: the 44-point
    /// frame spaces them, and every menu keeps its chevron at the default text size.
    private func chip(showsLabel: Bool, showsChevron: Bool) -> some View {
        HStack(spacing: showsLabel ? 5 : 3) {
            symbol
            if showsLabel { label }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.tertiaryInk)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(color ?? theme.ink)
        .lineLimit(1)
        .padding(.horizontal, showsLabel ? 6 : 2)
        .frame(minWidth: 44, minHeight: 44)
        .fixedSize()
        .contentShape(.rect)
    }
}

/// What a view in the composer's footer is to `ComposerFooterLayout`.
nonisolated enum ComposerFooterRole: LayoutValueKey {
    /// A menu, placed from the leading edge; it may show its symbol alone or move to another line.
    case chip
    /// Steer or queue: at the trailing end, before attach and send; it may show its symbol alone.
    case pinned
    /// Attach and send or stop: always at the trailing end of the first line, at their own size.
    case fixed

    static let defaultValue = ComposerFooterRole.chip
}

/// The composer's footer, placed by `RemoteLayout.footer`: menus never run under steer, attach or send, at any width or
/// text size.
struct ComposerFooterLayout: Layout {
    /// How far the footer reaches into the composer's padding on each side. Send then sits as far from the composer's
    /// edge as from its bottom, and a 375-point phone has room for every control on one line.
    static let bleed: CGFloat = 4

    /// The menus' own padding already sets them apart, as on the Mac's footer; a 390-point phone keeps the model's name.
    var spacing: CGFloat = 0
    /// Room before the first menu while there is some to spare (`RemoteLayout.footer`): with `bleed`, its symbol lines
    /// up with the message.
    var inset: CGFloat = 0

    /// Offered any width, the footer is as wide as its narrowest single line, so `ViewThatFits` takes the first footer
    /// that fits on one line.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width.isFinite else {
            let sizes = measure(subviews)
            return CGSize(
                width: RemoteLayout.footerMinimumWidth(chips: sizes.chips, pinned: sizes.pinned, fixed: sizes.fixed, spacing: spacing),
                height: sizes.height)
        }
        return footer(width: width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let footer = footer(width: bounds.width, subviews)
        let height = footer.size.height / CGFloat((footer.chips.map(\.line).max() ?? 0) + 1)
        var chips = footer.chips.makeIterator()
        var pins = footer.pinned.makeIterator()
        var fixedX = footer.fixed.minX
        for subview in subviews {
            let placement: CGRect
            switch subview[ComposerFooterRole.self] {
            case .chip: placement = chips.next()?.frame ?? .zero
            case .pinned: placement = pins.next()?.frame ?? .zero
            case .fixed:
                let width = subview.sizeThatFits(.unspecified).width
                placement = CGRect(x: fixedX, y: 0, width: width, height: height)
                fixedX += width + spacing
            }
            subview.place(
                at: CGPoint(x: bounds.minX + placement.minX, y: bounds.minY + placement.midY), anchor: .leading,
                proposal: ProposedViewSize(width: placement.width, height: nil))
        }
    }

    private func footer(width: CGFloat, _ subviews: Subviews) -> RemoteLayout.Footer {
        let sizes = measure(subviews)
        return RemoteLayout.footer(
            width: width, chips: sizes.chips, pinned: sizes.pinned, fixed: sizes.fixed, height: sizes.height, spacing: spacing,
            inset: inset)
    }

    private func measure(_ subviews: Subviews) -> (chips: [RemoteLayout.Chip], pinned: [RemoteLayout.Chip], fixed: CGFloat, height: CGFloat) {
        func chip(_ subview: LayoutSubview) -> RemoteLayout.Chip {
            // Offered a little less than each form needs, a menu shows its next narrower one (`ComposerChip`): its symbol
            // and chevron, then its symbol alone. (Offered no width at all, a menu doesn't report its real width at large
            // sizes.)
            let full = subview.sizeThatFits(.unspecified).width
            var compact = full
            for _ in 0..<2 {
                let narrower = subview.sizeThatFits(ProposedViewSize(width: max(0, compact - 1), height: nil)).width
                guard narrower < compact else { break }
                compact = narrower
            }
            return RemoteLayout.Chip(full: full, compact: compact)
        }
        let fixed = subviews.filter { $0[ComposerFooterRole.self] == .fixed }.map { $0.sizeThatFits(.unspecified).width }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 44
        return (
            subviews.filter { $0[ComposerFooterRole.self] == .chip }.map(chip),
            subviews.filter { $0[ComposerFooterRole.self] == .pinned }.map(chip),
            fixed.reduce(0, +) + spacing * CGFloat(max(0, fixed.count - 1)), max(44, height)
        )
    }
}
