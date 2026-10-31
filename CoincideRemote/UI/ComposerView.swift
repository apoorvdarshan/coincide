import CoincideRemoteKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The message field with the Mac composer's footer: agent and model, effort, speed, access, mode, photos, send and stop.
struct ComposerView: View {
    let model: ThreadModel
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @State private var photos: [PhotosPickerItem] = []
    @State private var isSending = false
    @State private var isDropTargeted = false
    @FocusState private var focused: Bool

    private var draft: Binding<ComposerDraft> {
        Binding(get: { client.drafts[model.id] ?? ComposerDraft() }, set: { client.drafts[model.id] = $0 })
    }

    private var summary: RemoteThreadSummary? { model.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !draft.wrappedValue.images.isEmpty { attachmentStrip }
            TextField(placeholder, text: draft.text, axis: .vertical)
                .lineLimit(1...8)
                .focused($focused)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .submitLabel(.return)
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .accessibilityLabel(Text("Message"))
            // The Mac composer's footer: its menus scroll sideways under a fade, so they never run under the buttons.
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        if let summary { ComposerControls(thread: summary) }
                    }
                }
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                    }
                }
                PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.body.weight(.medium))
                        .frame(width: 40, height: 44)
                        .contentShape(.rect)
                }
                .foregroundStyle(theme.secondaryInk)
                .accessibilityLabel(Text("Attach Photos"))
                sendButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isDropTargeted ? theme.accent : theme.border, lineWidth: isDropTargeted ? 2 : theme.borderWidth)
        }
        .onDrop(of: [.image], isTargeted: $isDropTargeted) { providers in
            for provider in providers { load(provider) }
            return true
        }
        .onChange(of: photos) { _, items in
            Task { await importPhotos(items) }
        }
        .disabled(!client.isConnected)
    }

    private var placeholder: String {
        model.turn.isRunning
            ? (client.server?.followUpBehavior == "queue" ? String(localized: "Queue a follow-up") : String(localized: "Steer the agent"))
            : summary.map { String(localized: "Ask \(AgentLogo.name($0.selection.provider))") } ?? String(localized: "Ask the agent")
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
            let enabled = !draft.wrappedValue.isEmpty && !isSending
            Button {
                send(alternate: false)
            } label: {
                Group {
                    if isSending {
                        ProgressView().controlSize(.small).tint(theme.onControl)
                    } else {
                        // While a turn runs, the button says where the message goes: into the turn, or after it.
                        Image(systemName: !model.turn.isRunning ? "arrow.up"
                            : client.server?.followUpBehavior == "queue" ? "text.append" : "arrow.turn.down.right")
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
                model.followsBottom = true
            }
            isSending = false
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
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    private var provider: RemoteProvider? { client.provider(thread.selection.provider) }
    private var currentModel: RemoteModel? { provider?.models.first { $0.id == thread.selection.modelID } }

    var body: some View {
        Menu {
            ForEach(client.workspace.providers) { provider in
                if provider.accounts.count > 1 {
                    Menu(provider.name) {
                        ForEach(provider.accounts) { account in
                            Section(account.name) { modelButtons(provider, accountID: account.id) }
                        }
                    }
                } else {
                    Section(provider.name) { modelButtons(provider, accountID: nil) }
                }
            }
        } label: {
            ComposerChip(menu: true) {
                AgentLogo(provider: thread.selection.provider, size: 14)
                Text(thread.selection.modelName).lineLimit(1)
                if let account = thread.selection.accountName { Text("· \(account)").foregroundStyle(theme.secondaryInk) }
            }
        }
        .accessibilityLabel(Text("Model: \(thread.selection.modelName)"))

        if let efforts = currentModel?.efforts, !efforts.isEmpty {
            Menu {
                Picker("Effort", selection: setting(thread.selection.effort ?? "") { RemoteThreadSettings(threadID: thread.id, effort: $0) }) {
                    ForEach(efforts, id: \.self) { Text(Self.effortTitle($0)).tag($0) }
                }
            } label: {
                ComposerChip(menu: true) {
                    Image(systemName: "brain")
                    Text(Self.effortTitle(thread.selection.effort ?? currentModel?.defaultEffort ?? ""))
                }
            }
            .accessibilityLabel(Text("Effort: \(Self.effortTitle(thread.selection.effort ?? currentModel?.defaultEffort ?? ""))"))
        }

        if let speeds = currentModel?.speeds, !speeds.isEmpty {
            Menu {
                Picker(
                    "Speed",
                    selection: setting(thread.selection.speed ?? RemoteThreadSettings.standardSpeed) {
                        RemoteThreadSettings(threadID: thread.id, speed: $0)
                    }
                ) {
                    Text("Standard").tag(RemoteThreadSettings.standardSpeed)
                    ForEach(speeds) { speed in Text(speed.name).tag(speed.id) }
                }
            } label: {
                ComposerChip(menu: true) {
                    Image(systemName: "gauge.with.needle")
                    Text(speeds.first { $0.id == thread.selection.speed }?.name ?? String(localized: "Standard"))
                }
            }
        }

        Menu {
            Picker("Access", selection: setting(thread.accessMode) { RemoteThreadSettings(threadID: thread.id, accessMode: $0) }) {
                Label("Full access", systemImage: "lock.open").tag("fullAccess")
                Label("Ask for approval", systemImage: "lock").tag("approval")
            }
        } label: {
            ComposerChip(menu: true) {
                Image(systemName: thread.accessMode == "fullAccess" ? "lock.open" : "lock")
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
                Text(thread.interactionMode == "plan" ? "Plan" : "Build")
            }
        }
        .accessibilityLabel(Text("Mode: \(thread.interactionMode == "plan" ? String(localized: "Plan") : String(localized: "Build"))"))
        .accessibilityHint(Text("Switches between building and planning"))
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

/// One of the composer's menus as the Mac's footer draws it: borderless, an icon and the current choice, and a small
/// chevron when it opens a menu. A full-height touch target without a capsule around it.
struct ComposerChip<Content: View>: View {
    var menu: Bool
    /// The label's color when it marks something on (Plan mode); the theme's text otherwise.
    var color: Color?
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            content
            if menu {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.tertiaryInk)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(color ?? theme.ink)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}
